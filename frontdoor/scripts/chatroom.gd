extends Node
class_name Chatroom

## The chatroom node (Spec #542). `chat` lands the player in a channel of
## scrambled traffic that differs every session (seeded; the seed is pinned by
## DECOHERENCE_CHATROOM_SEED in tests). Nothing in here explains itself: no
## prompt, no hint, no progress surface. The first message the player sends is
## answered by a scripted voice; shortly after, one more ordinary voice in the
## room reaches out in clear text, and from then on that voice talks to the
## player through the local model, one structured call per turn.
##
## Code decides everything that matters: which facts the model may state (only
## those the player's own words unlocked), when the player is ready, whether the
## offer is honoured, and whether the exact accept word was typed. The model
## contributes wording and, at most, a proposal that code can downgrade.
##
## This node is the sole consumer of the shell's CHAT-state pass-through; the
## shell stays the only emitter on the player-line channel.
##
## Spec #562: the room is now several rooms and the direct messages between the
## player and the people in them. This node still owns every rule (the ambient
## planner, presence, the scripted replies, the first-message trigger, the
## briefing turn, the entry gate); it writes into a ChatModel that the chat
## client draws. Only the one thread where the contact spoke may reach the model.

enum Beat { AMBIENT, RESPONDER, CONTACT, PRESENCE, DM }

var state: String = ""

## The rooms, buffers and unread state the chat client draws (Spec #562).
var model: ChatModel = null

var _terminal: TerminalGrid = null
var _llm: LlmClient = null
var _shell: ShellController = null
var _bundle: Dictionary = {}
var _loaded: bool = false
var _inside: bool = false
var _seed: int = 0
var _rng := RandomNumberGenerator.new()

var _rules: Dictionary = {}
var _ui_strings: Dictionary = {}
var _dm_script: Dictionary = {}
var _rooms_rt: Dictionary = {}
var _dm_pending: Array = []
var _dm_bags: Dictionary = {}
var _dm_rng := RandomNumberGenerator.new()
var _banner_pending: bool = true
var _first_buffer: String = ""
var _contact_target: String = ""

var _trigger_fired: bool = false
var _contact_pending: bool = false
var _contact_at_ms: int = 0
var _contact_done: bool = false
var _fallback_i: int = 0

var _unlocked: Array = []
var _credited: Array = []
var _player_turns: int = 0
var _history: Array = []
var _ready_flag: bool = false
var _due_turns: int = 0
var _busy: bool = false
var _queue: Array = []
var _epoch: int = 0

## Probe-facing records (never rendered): every voice row the room wrote, the
## last prompt sent, the last reply verdict, and counters.
var emission_log: Array = []
var last_messages: Array = []
var last_verdict: Dictionary = {}
var ready_at_turn: int = -1
var accepted_replies: int = 0
var rejected_replies: int = 0
var degraded_turns: int = 0
var contact_ms: int = -1
var opened_ms: int = -1
var lines_received: int = 0


func setup(terminal_grid: TerminalGrid, llm: LlmClient, shell: ShellController) -> void:
	_terminal = terminal_grid
	_llm = llm
	_shell = shell
	_bundle = ChatroomScript.load_bundle()
	_loaded = bool(_bundle.get("ok", false))
	if _loaded:
		_rules = _bundle["script"].get("scramble", {})
	_load_client_data()
	_seed = _draw_seed()
	_reseed()
	if not Signals.chat_opened.is_connected(_on_chat_opened):
		Signals.chat_opened.connect(_on_chat_opened)
	if not Signals.submit_player_line.is_connected(_on_player_line):
		Signals.submit_player_line.connect(_on_player_line)


## One seed per session: the env value when set, otherwise fresh randomness.
func _draw_seed() -> int:
	var env := OS.get_environment("DECOHERENCE_CHATROOM_SEED")
	if env.is_valid_int():
		return env.to_int()
	var fresh := RandomNumberGenerator.new()
	fresh.randomize()
	return int(fresh.randi() & 0x7fffffff)


func _reseed() -> void:
	_rng.seed = _seed ^ 0x5bd1e995
	_dm_rng.seed = _seed ^ 0x2c1b3c6d
	_dm_pending = []
	_dm_bags = {}
	_banner_pending = true
	_first_buffer = ""
	_contact_target = ""
	_build_session()


## The words the client draws itself and the direct-message replies are data too.
func _load_client_data() -> void:
	var ui = ChatroomScript.read_json(ChatroomScript.data_dir() + "/client_ui.json")
	_ui_strings = ui.get("strings", {}) if typeof(ui) == TYPE_DICTIONARY else {}
	var dms = ChatroomScript.read_json(ChatroomScript.data_dir() + "/dm_script.json")
	_dm_script = dms if typeof(dms) == TYPE_DICTIONARY else {}


func ui_string(key: String) -> String:
	return String(_ui_strings.get(key, ""))


## A fresh model and per-room clocks for this seed: the player's own handle comes
## from the seed, every room starts with its whole cast present.
func _build_session() -> void:
	model = ChatModel.new()
	_rooms_rt = {}
	if not _loaded:
		return
	var script := room_script()
	model.setup(script, "NODE-%04d" % (_seed % 10000), String(script.get("entry_room", "")))
	for rid in model.room_order:
		var rt := RandomNumberGenerator.new()
		rt.seed = _seed ^ (String(rid).hash() & 0x7fffffff) ^ 0x1f123bb5
		_rooms_rt[rid] = {"plan": [], "plan_i": 0, "next_ms": 0, "pres_rng": rt, "next_pres_ms": 0}


func session_handle() -> String:
	return model.self_handle if model != null else ""


func session_seed() -> int:
	return _seed


func loaded() -> bool:
	return _loaded


func room_script() -> Dictionary:
	return _bundle.get("script", {})


func entry_allowed() -> bool:
	return ChatroomScript.entry_allowed(state)


func unlocked_facts() -> Array:
	return _unlocked.duplicate()


func credited_facts() -> Array:
	return _credited.duplicate()


func player_turns() -> int:
	return _player_turns


func is_busy() -> bool:
	return _busy


func is_inside() -> bool:
	return _inside


func contact_handle() -> String:
	var room := ChatroomScript.entry_room(room_script())
	return ChatroomScript.voice_handle(room, String(room.get("handler_trigger", {}).get("contact_line", {}).get("voice", "")))


## Test hook (probes only): a fresh session, optionally with a pinned seed. Any
## reply still in flight is dropped.
func reset_session(new_seed: int = -1) -> void:
	_epoch += 1
	_seed = new_seed if new_seed >= 0 else _draw_seed()
	state = ""
	_inside = false
	_trigger_fired = false
	_contact_pending = false
	_contact_done = false
	_fallback_i = 0
	_unlocked = []
	_credited = []
	_player_turns = 0
	_history = []
	_ready_flag = false
	_due_turns = 0
	_busy = false
	_queue = []
	emission_log = []
	last_messages = []
	last_verdict = {}
	ready_at_turn = -1
	accepted_replies = 0
	rejected_replies = 0
	degraded_turns = 0
	contact_ms = -1
	opened_ms = -1
	lines_received = 0
	_reseed()
	Signals.chat_model_changed.emit()


## --- Entering and leaving --------------------------------------------------------------

func _on_chat_opened() -> void:
	if not _loaded:
		_terminal.write_line("CHANNEL UNAVAILABLE.", Palette.ORANGE)
		Signals.chatroom_left.emit()
		return
	var room := ChatroomScript.entry_room(room_script())
	_inside = true
	if state.is_empty():
		state = ChatroomScript.ST_ROOM
	var now := Time.get_ticks_msec()
	if _banner_pending:
		_banner_pending = false
		for line in room.get("banner", []):
			_push(String(room["id"]), _row(ChatModel.ROW_PRESENCE, "", String(line)))
	for rid in model.room_order:
		_rooms_rt[rid]["next_ms"] = now
		_rooms_rt[rid]["next_pres_ms"] = now + _rooms_rt[rid]["pres_rng"].randi_range(18000, 42000)
	opened_ms = now
	Signals.chat_model_changed.emit()
	Signals.chatroom_opened.emit()


func _leave() -> void:
	_epoch += 1
	_busy = false
	_queue = []
	_inside = false
	_terminal.write_line(String(room_script().get("handler", {}).get("leave_line", "")), Palette.TEAL)
	Signals.chatroom_left.emit()


## --- Player input -------------------------------------------------------------------------

## The only consumer of the shell's CHAT-state pass-through.
func _on_player_line(text: String) -> void:
	if not _inside:
		return
	lines_received += 1
	var limits: Dictionary = room_script().get("limits", {})
	var cleaned := IntentRouter.sanitize_input(text, int(limits.get("max_input_chars", 200)))
	var handler: Dictionary = room_script().get("handler", {})
	if ChatroomScript.matches_command(handler.get("leave_commands", []), cleaned):
		_leave()
		return
	if cleaned.is_empty():
		return
	var buffer := model.active
	if ChatModel.route_for(buffer, cleaned, _route_state()) == ChatroomScript.ROUTE_COMMAND:
		_run_command(ChatModel.parse_command(cleaned))
		return
	if state == ChatroomScript.ST_OFFERED and _on_contact_thread(buffer) and ChatroomScript.matches_command(handler.get("accept_commands", []), cleaned):
		_grant()
		return
	_deliver(buffer, ChatModel.ROW_SELF, cleaned)


func _grant() -> void:
	Signals.chatroom_entry_granted.emit()
	if _shell != null and _shell.current_state_name() == "WORLD":
		_inside = false


## --- Routing (code decides which lines may reach the model) --------------------------------------

## The thread that may use the model: the buffer where the contact spoke, and the
## direct message with that person, once the contact has spoken.
func _threads() -> Array:
	var out: Array = []
	if not _contact_target.is_empty():
		out.append(_contact_target)
	out.append(ChatModel.dm_id(contact_handle()))
	return out


func _route_state() -> Dictionary:
	return {"reached": _contact_done, "threads": _threads()}


func _on_contact_thread(buffer: String) -> bool:
	return _contact_done and _threads().has(buffer)


## One spoken line in `buffer`: it is echoed as the player's own row, then goes to
## the model-backed thread or to a scripted voice, and the first sent message
## anywhere starts the contact timer exactly once.
func _deliver(buffer: String, kind: String, text: String) -> void:
	_push(buffer, _row(kind, model.self_handle, text))
	if ChatModel.route_for(buffer, "x", _route_state()) == ChatroomScript.ROUTE_CONTACT:
		_queue.append({"text": text, "buffer": buffer})
		_pump()
	else:
		_scripted_reply(buffer, text)
	_note_message(buffer, text)


func _run_command(p: Dictionary) -> void:
	var active := model.active
	match String(p["kind"]):
		"join":
			var rid := model.room_id_for(String(p["name"]))
			if rid.is_empty():
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("no_such_channel")))
				return
			if model.join(rid):
				_rooms_rt[rid]["next_ms"] = Time.get_ticks_msec()
				_push(rid, _row(ChatModel.ROW_PRESENCE, "", ui_string("joined_line").replace("{name}", model.self_handle)))
			model.switch_to(rid)
			Signals.chat_model_changed.emit()
		"part":
			if model.open_order().size() <= 1:
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("last_buffer")))
				return
			if model.is_room(active):
				_push(active, _row(ChatModel.ROW_PRESENCE, "", ui_string("left_line").replace("{name}", model.self_handle)))
			model.part(active)
			Signals.chat_model_changed.emit()
		"list":
			for e in model.directory():
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("list_line").replace("{name}", String(e["name"])).replace("{count}", str(e["count"]))))
		"who":
			for h in model.roster(active):
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("who_line").replace("{name}", String(h))))
		"msg":
			if _is_self_name(String(p["name"])):
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("self_message")))
				return
			var handle := model.find_handle(String(p["name"]))
			if handle.is_empty():
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("no_such_user")))
				return
			model.open_dm(handle)
			model.switch_to(ChatModel.dm_id(handle))
			Signals.chat_model_changed.emit()
			if not String(p["body"]).is_empty():
				_deliver(ChatModel.dm_id(handle), ChatModel.ROW_SELF, String(p["body"]))
		"me":
			if not String(p["body"]).is_empty():
				_deliver(active, ChatModel.ROW_ACTION, String(p["body"]))
		"clear":
			model.clear_rows(active)
			Signals.chat_model_changed.emit()
		"quit":
			_leave()
		_:
			_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("unknown_command")))


## The player's own handle is not a voice in any room, so find_handle() never
## returns it; /msg to self is matched by name instead.
func _is_self_name(name: String) -> bool:
	return name.strip_edges().to_upper() == model.self_handle


## --- The rooms ---------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _inside or not _loaded:
		return
	var now := Time.get_ticks_msec()
	if _contact_pending and now >= _contact_at_ms:
		_fire_contact(now)
	for rid in model.room_order:
		var rt: Dictionary = _rooms_rt[rid]
		if bool(model.rooms[rid]["joined"]) and now >= int(rt["next_ms"]):
			_emit_ambient(String(rid), now)
		if now >= int(rt["next_pres_ms"]):
			_presence_tick(String(rid), now)
	_deliver_dm_replies(now)


func _plan_seed(room_id: String) -> int:
	if room_id == String(room_script().get("entry_room", "")):
		return _seed
	return _seed ^ (room_id.hash() & 0x7fffffff)


func _ensure_plan(room_id: String, upto: int) -> void:
	var rt: Dictionary = _rooms_rt[room_id]
	if rt["plan"].size() <= upto:
		rt["plan"] = ChatroomScript.ambient_plan(room_script(), _plan_seed(room_id), maxi(64, rt["plan"].size() * 2), room_id)


func _emit_ambient(room_id: String, now: int) -> void:
	var rt: Dictionary = _rooms_rt[room_id]
	_ensure_plan(room_id, int(rt["plan_i"]) + 1)
	if rt["plan"].is_empty():
		rt["next_ms"] = now + 60000
		return
	var entry: Dictionary = rt["plan"][rt["plan_i"]]
	rt["plan_i"] = int(rt["plan_i"]) + 1
	_write_voice(String(entry["voice"]), String(entry["plain"]), int(entry["scramble_seed"]), Beat.AMBIENT, room_id)
	_ensure_plan(room_id, int(rt["plan_i"]))
	var room := ChatroomScript.room_by_id(room_script(), room_id)
	var slowed := _contact_done and room_id == _contact_target
	var rate := float(room.get("ambient", {}).get("rate_after_contact", 1.0)) if slowed else 1.0
	var delay := int(float(rt["plan"][rt["plan_i"]]["interval_ms"]) / maxf(rate, 0.01))
	rt["next_ms"] = now + delay
	emission_log[emission_log.size() - 1]["next_delay_ms"] = delay
	emission_log[emission_log.size() - 1]["rate"] = rate


## One scripted join or leave in a room. Rooms the player has not joined only shift
## their member count; a joined room also shows the line.
func _presence_tick(room_id: String, now: int) -> void:
	var rt: Dictionary = _rooms_rt[room_id]
	rt["next_pres_ms"] = now + rt["pres_rng"].randi_range(18000, 42000)
	var ev := model.presence_step(room_id, rt["pres_rng"])
	if ev.is_empty() or not bool(model.rooms[room_id]["joined"]):
		Signals.chat_model_changed.emit()
		return
	var line_key := "joined_line" if String(ev["kind"]) == "join" else "left_line"
	_push(room_id, _row(ChatModel.ROW_PRESENCE, "", ui_string(line_key).replace("{name}", String(ev["handle"]))))
	emission_log.append({"t_ms": Time.get_ticks_msec(), "beat": int(Beat.PRESENCE), "voice": "", "handle": String(ev["handle"]), "plain": "", "row": ui_string(line_key).replace("{name}", String(ev["handle"])), "buffer": room_id, "kind": String(ev["kind"])})


## --- Rows --------------------------------------------------------------------------------------------

func _clock() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(t["hour"]), int(t["minute"])]


func _row(kind: String, handle: String, text: String, clear: bool = true) -> Dictionary:
	return {"kind": kind, "handle": handle, "text": text, "t": _clock(), "clear": clear}


## Writes one row into a buffer and echoes it to the rendered-line channel, the
## same echo the terminal gives its own rows (the player's own lines excepted).
func _push(buffer_id: String, row: Dictionary) -> void:
	model.add_row(buffer_id, row)
	if String(row["kind"]) != ChatModel.ROW_SELF:
		Signals.line_rendered.emit(ChatModel.plain_line(row))
	Signals.chat_model_changed.emit()


## Writes one voice row into a room (or the entry room). Ambient and responder
## rows are scrambled and dim; the contact's rows are clear text.
func _write_voice(voice_id: String, plain: String, scramble_seed: int, beat: int, room_id: String = "") -> void:
	var rid := room_id if not room_id.is_empty() else String(room_script().get("entry_room", ""))
	var room := ChatroomScript.room_by_id(room_script(), rid)
	_say_voice(rid, ChatroomScript.voice_handle(room, voice_id), voice_id, plain, scramble_seed, beat)


func _say_voice(buffer_id: String, handle: String, voice_id: String, plain: String, scramble_seed: int, beat: int) -> void:
	var clear := beat == Beat.CONTACT
	var body := plain if clear else ChatroomScript.scramble(plain, scramble_seed, _rules)
	# Somebody who is not in the room has to arrive before they can speak in it.
	if model.is_room(buffer_id) and model.set_present(buffer_id, handle) and bool(model.rooms[buffer_id]["joined"]):
		_push(buffer_id, _row(ChatModel.ROW_PRESENCE, "", ui_string("joined_line").replace("{name}", handle)))
	var row := "<%s> %s" % [handle, body]
	_push(buffer_id, _row(ChatModel.ROW_VOICE, handle, body, clear))
	emission_log.append({"t_ms": Time.get_ticks_msec(), "beat": int(beat), "voice": voice_id, "handle": handle, "plain": plain, "row": row, "buffer": buffer_id})


## Before the contact: a scripted voice answers in the room; a direct message to an
## ordinary person is answered later from that person's own pool. The contact has
## no scripted reply.
func _scripted_reply(buffer: String, text: String) -> void:
	var script := room_script()
	if model.is_room(buffer):
		var res := ChatroomScript.respond(script, text, _fallback_i, buffer)
		if bool(res["fallback"]):
			_fallback_i += 1
		_write_voice(String(res["voice"]), String(res["plain"]), int(_rng.randi() & 0x7fffffff), Beat.RESPONDER, buffer)
	elif model.is_dm(buffer):
		var handle := String(model.buffers[buffer]["title"])
		if handle != contact_handle():
			_schedule_dm_reply(handle)


func _schedule_dm_reply(handle: String) -> void:
	var pool: Array = _dm_script.get("replies", {}).get(handle, [])
	if pool.is_empty() or _dm_rng.randf() < float(_dm_script.get("silence_ratio", 0.0)):
		return
	var bag: Array = _dm_bags.get(handle, [])
	if bag.is_empty():
		bag = range(pool.size())
		for j in range(bag.size() - 1, 0, -1):
			var k := _dm_rng.randi_range(0, j)
			var tmp = bag[j]
			bag[j] = bag[k]
			bag[k] = tmp
	var pick := int(bag.pop_front())
	_dm_bags[handle] = bag
	var d: Array = _dm_script.get("reply_delay_ms", [1200, 4000])
	_dm_pending.append({
		"at": Time.get_ticks_msec() + _dm_rng.randi_range(int(d[0]), int(d[1])),
		"handle": handle,
		"plain": String(pool[pick].get("plain", "")),
		"seed": int(_dm_rng.randi() & 0x7fffffff),
		"epoch": _epoch,
	})


## A reply that lands in a direct message the player has since closed reopens it.
func _deliver_dm_replies(now: int) -> void:
	var due: Array = []
	for item in _dm_pending:
		if now >= int(item["at"]):
			due.append(item)
	for item in due:
		_dm_pending.erase(item)
		if int(item["epoch"]) != _epoch:
			continue
		model.open_dm(String(item["handle"]))
		_say_voice(ChatModel.dm_id(String(item["handle"])), String(item["handle"]), "", String(item["plain"]), int(item["seed"]), Beat.DM)


## The first sent message anywhere starts the contact timer, exactly once. A refused
## command, an empty line or unsent typing never reaches this point.
func _note_message(buffer: String, text: String) -> void:
	var script := room_script()
	var room := ChatroomScript.room_by_id(script, buffer) if model.is_room(buffer) else ChatroomScript.entry_room(script)
	var trigger: Dictionary = room.get("handler_trigger", {})
	if ChatroomScript.trigger_fires(trigger, _trigger_fired, text):
		_trigger_fired = true
		_first_buffer = buffer
		var d: Array = trigger["contact_delay_ms"]
		_contact_pending = true
		_contact_at_ms = Time.get_ticks_msec() + _rng.randi_range(int(d[0]), int(d[1]))


## Where the contact speaks: the buffer of the first message when that was a room
## or the contact's own direct message; otherwise the entry room.
func _contact_buffer() -> String:
	var script := room_script()
	var entry := String(script.get("entry_room", ""))
	var fb := _first_buffer
	if model.is_dm(fb) and String(model.buffers[fb]["title"]) == contact_handle():
		model.open_dm(contact_handle())
		return fb
	if not model.is_room(fb) or not bool(model.rooms[fb]["joined"]):
		fb = entry
	if not bool(model.rooms[fb]["joined"]):
		var open_rooms: Array = model.open_order().filter(func(id): return model.is_room(String(id)))
		if open_rooms.is_empty():
			model.join(fb)
		else:
			fb = String(open_rooms[0])
	return fb


func _fire_contact(now: int) -> void:
	var target := _contact_buffer()
	var room := ChatroomScript.room_by_id(room_script(), target) if model.is_room(target) else ChatroomScript.entry_room(room_script())
	var line: Dictionary = room["handler_trigger"]["contact_line"]
	_contact_pending = false
	_contact_done = true
	_contact_target = target
	contact_ms = now
	state = ChatroomScript.ST_BRIEFING
	_say_voice(target, contact_handle(), String(line["voice"]), String(line["plain"]), 0, Beat.CONTACT)
	Signals.chatroom_handler_found.emit()


## --- The briefing turn ---------------------------------------------------------------------------

func _pump() -> void:
	if _busy or _queue.is_empty() or not _inside:
		return
	_busy = true
	var item: Dictionary = _queue.pop_front()
	var text: String = item["text"]
	var buffer: String = item["buffer"]
	var cfg: Dictionary = _bundle["readiness"]
	var briefing: Dictionary = _bundle["briefing"]
	var new_ids := ChatroomScript.facts_for_turn(briefing, cfg, _unlocked, text)
	var unlocked_now: Array = _unlocked.duplicate()
	unlocked_now.append_array(new_ids)
	var offer_due := _ready_flag and state == ChatroomScript.ST_BRIEFING
	var messages := ChatroomScript.build_messages(_bundle["persona"], briefing, unlocked_now, _history, text, offer_due)
	last_messages = messages
	var limits: Dictionary = room_script().get("limits", {})
	var options := {
		"thinking": false,
		"temperature": 0.3,
		"seed": 542,
		"max_tokens": 160,
		"schema": ChatroomScript.response_schema(int(limits.get("say_max_chars", 240))),
		"timeout_ms": 12000,
		"reasoning_probe": Callable(self, "_on_reasoning"),
	}
	_reasoning_seen = ""
	_llm.complete_structured(messages, options, _on_turn_done.bind(_epoch, text, new_ids, offer_due, buffer))


var _reasoning_seen: String = ""


## The client hands over whatever reasoning text the server attached (empty when
## thinking is off); it is used only to reject a reply that repeats it.
func _on_reasoning(reasoning: String) -> void:
	_reasoning_seen = reasoning


## Bound method, never a lambda (lambdas capture by value).
func _on_turn_done(result: Dictionary, epoch: int, text: String, new_ids: Array, offer_due: bool, buffer: String) -> void:
	if epoch != _epoch:
		return
	_busy = false
	var script := room_script()
	var handler: Dictionary = script.get("handler", {})
	var persona: Dictionary = _bundle["persona"]
	if not bool(result.get("ok", false)):
		# Transport failure: state unchanged, the player may simply send again.
		degraded_turns += 1
		last_verdict = {"ok": false, "reason": "transport:" + String(result.get("error", ""))}
		_push(buffer, _row(ChatModel.ROW_SYSTEM, "", String(handler.get("degrade_line", ""))))
		_pump()
		return
	_player_turns += 1
	_unlocked.append_array(new_ids)
	if offer_due:
		_due_turns += 1
	var limits: Dictionary = script.get("limits", {})
	var verdict := ChatroomScript.validate_handler_reply(String(result.get("content", "")), offer_due, int(limits.get("say_max_chars", 240)), _reasoning_seen)
	last_verdict = verdict
	if not bool(verdict["ok"]):
		rejected_replies += 1
		_say_voice(buffer, contact_handle(), "", String(persona.get("fallback_say", "")), 0, Beat.CONTACT)
	else:
		accepted_replies += 1
		var say := String(verdict["say"])
		_say_voice(buffer, contact_handle(), "", say, 0, Beat.CONTACT)
		_history.append({"role": "user", "content": text})
		_history.append({"role": "assistant", "content": say})
		_credited.append_array(ChatroomScript.credit(_bundle["briefing"], _unlocked, say, _credited))
		Signals.handler_reply_complete.emit(say)
	_settle_offer(bool(verdict["ok"]) and String(verdict["act"]) == "offer_entry", offer_due, buffer, String(handler.get("offer_fallback_line", "")))
	_ready_flag = ChatroomScript.readiness(_bundle["readiness"], _credited, _player_turns)
	if _ready_flag and ready_at_turn < 0:
		ready_at_turn = _player_turns
	_pump()


## The offer: honoured when the model proposed it on a due turn; if it still has
## not offered after the grace turns, code speaks the script's own offer line.
func _settle_offer(model_offered: bool, offer_due: bool, buffer: String, fallback_line: String) -> void:
	if state != ChatroomScript.ST_BRIEFING or not offer_due:
		return
	var grace := int(_bundle["readiness"].get("offer_grace_turns", 1))
	if model_offered:
		state = ChatroomScript.ST_OFFERED
	elif _due_turns > grace:
		_say_voice(buffer, contact_handle(), "", fallback_line, 0, Beat.CONTACT)
		state = ChatroomScript.ST_OFFERED
	if state == ChatroomScript.ST_OFFERED:
		Signals.chatroom_entry_offered.emit()
