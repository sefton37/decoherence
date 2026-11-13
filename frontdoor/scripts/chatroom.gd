extends Node
class_name Chatroom

## The chatroom node (Spec #542, reworked by Spec #573). `chat` lands the player
## in a channel of scrambled traffic that differs every session (seeded; the seed
## is pinned by DECOHERENCE_CHATROOM_SEED in tests). Nothing in here explains
## itself: no prompt, no hint, no progress surface. The player is a lurker named
## newb plus four digits. The first message they send is answered by a scripted
## voice; after it, one ordinary-looking Empire voice in the room, the player's
## handler, reaches out in clear text and leads a conversation that code owns
## stage by stage (Funnel): qualify, "this is not a game", a move to a direct
## message, the pitch, the ask, a handle she renames the player to, and the launch.
##
## Code decides everything that matters: the stage order and its clocks, whether a
## reply is a clear yes, the rename and the single launch. The model only writes
## {say, claims} inside a stage, and every reply passes FunnelGuard or the stage's
## authored fallback beat is spoken instead. Every authored word is data
## (funnel_beats.json).
##
## This node is the sole consumer of the shell's CHAT-state pass-through; the
## shell stays the only emitter on the player-line channel. All timers read one
## clock, now_ms(), so a probe can run the whole funnel on a simulated clock.

enum Beat { AMBIENT, RESPONDER, CONTACT, PRESENCE, DM }

## The environment variable that pins a session (replay) in tests.
const SEED_ENV := "DECOHERENCE_CHATROOM_SEED"

var state: String = ""

## The rooms, buffers and unread state the chat client draws (Spec #562).
var model: ChatModel = null
## The recruitment funnel's stage machine (Spec #573); read by probes.
var funnel: Funnel = null

var _terminal: TerminalGrid = null
var _llm: LlmClient = null
var _shell: ShellController = null
var _bundle: Dictionary = {}
var _script_rt: Dictionary = {}
var _loaded: bool = false
var _inside: bool = false
var _seed: int = 0
var _rng := RandomNumberGenerator.new()
var _lat_rng := RandomNumberGenerator.new()

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
var _thread_buf: String = ""
var _contact_done: bool = false

var _funnel_on: bool = false
## The HANDLER module's data (Spec #575): tables, rules, ui and route, read again on every reset.
var _hdata: Dictionary = {}
var _profile: Dictionary = {}
var _dossier: Dictionary = {}
var _handler_name: String = ""
var _designation: String = ""
var _outbox: Array = []
var _outbox_end: int = 0
var _launch_pending: bool = false
var _left_ms: int = -1
var _leg_k: Dictionary = {}
var _leg_phase: float = 0.0

var _sim: bool = false
var _sim_ms: int = 0

var _history: Array = []
var _busy: bool = false
var _queue: Array = []
var _epoch: int = 0

## Probe-facing records (never rendered): every voice row the room wrote, the
## last prompt sent, the last reply verdict, and counters.
var emission_log: Array = []
var last_messages: Array = []
var last_verdict: Dictionary = {}
var last_prompt_stage: int = -1
var accepted_replies: int = 0
var rejected_replies: int = 0
var degraded_turns: int = 0
var model_requests: int = 0
var contact_ms: int = -1
var opened_ms: int = -1
var lines_received: int = 0
var first_message_ms: int = -1
var grant_ms: int = -1


func setup(terminal_grid: TerminalGrid, llm: LlmClient, shell: ShellController) -> void:
	_terminal = terminal_grid
	_llm = llm
	_shell = shell
	_bundle = ChatroomScript.load_bundle()
	_loaded = bool(_bundle.get("ok", false))
	if _loaded:
		_rules = _bundle["script"].get("scramble", {})
	_load_client_data()
	_hdata = ProfileStore.load_handler_data()
	_seed = _draw_seed()
	_reseed()
	if not Signals.chat_opened.is_connected(_on_chat_opened):
		Signals.chat_opened.connect(_on_chat_opened)
	if not Signals.submit_player_line.is_connected(_on_player_line):
		Signals.submit_player_line.connect(_on_player_line)
	# Spec #578: time spent under the pause menu is not the player's (the tree stood still, the clock did not).
	if not PauseMenu.closed.is_connected(_on_pause_closed):
		PauseMenu.closed.connect(_on_pause_closed)


## The one clock every timer in this node reads. A probe switches it to a
## simulated clock (sim_enable) and advances it by hand; in play it is the engine's.
func now_ms() -> int:
	return _sim_ms if _sim else Time.get_ticks_msec()


## Moves every pending time forward by `ms`: the funnel's own clocks, the outbox and the
## direct-message replies, so nothing she was about to say fires the moment the player returns.
func _shift_queues(ms: int) -> void:
	funnel.shift_time(ms)
	_outbox_end += ms
	for item in _outbox:
		item["due"] = int(item["due"]) + ms
	for item in _dm_pending:
		item["at"] = int(item["at"]) + ms


## The pause menu closed after `paused_msec` of a stopped tree: a room the player is in moves all of
## its timers forward by that much, the ambient and presence ones included. A room the player is not
## in is covered by its own away clock when the player comes back.
func _on_pause_closed(paused_msec: int) -> void:
	if not _inside or paused_msec <= 0:
		return
	_shift_queues(paused_msec)
	for rid in model.room_order:
		_rooms_rt[rid]["next_ms"] = int(_rooms_rt[rid]["next_ms"]) + paused_msec
		_rooms_rt[rid]["next_pres_ms"] = int(_rooms_rt[rid]["next_pres_ms"]) + paused_msec


## Test hook (probes only): run every timer on a simulated clock.
func sim_enable(start_ms: int = 0) -> void:
	_sim = true
	_sim_ms = start_ms


func sim_advance(ms: int) -> void:
	_sim_ms += ms


func sim_enabled() -> bool:
	return _sim


## One seed per session: the env value when set, otherwise fresh randomness.
func _draw_seed() -> int:
	var env := OS.get_environment(SEED_ENV)
	if env.is_valid_int():
		return env.to_int()
	var fresh := RandomNumberGenerator.new()
	fresh.randomize()
	return int(fresh.randi() & 0x7fffffff)


func _reseed() -> void:
	_rng.seed = _seed ^ 0x5bd1e995
	_dm_rng.seed = _seed ^ 0x2c1b3c6d
	_lat_rng.seed = _seed ^ 0x6a09e667
	_leg_phase = float((_seed ^ 0x1b873593) & 0xffff) / 65536.0
	_dm_pending = []
	_dm_bags = {}
	_banner_pending = true
	_first_buffer = ""
	_contact_target = ""
	_thread_buf = ""
	_contact_done = false
	_load_identity()
	_build_session()


## The words the client draws itself and the direct-message replies are data too.
func _load_client_data() -> void:
	var ui = ChatroomScript.read_json(ChatroomScript.data_dir() + "/client_ui.json")
	_ui_strings = ui.get("strings", {}) if typeof(ui) == TYPE_DICTIONARY else {}
	var dms = ChatroomScript.read_json(ChatroomScript.data_dir() + "/dm_script.json")
	_dm_script = dms if typeof(dms) == TYPE_DICTIONARY else {}


func ui_string(key: String) -> String:
	return String(_ui_strings.get(key, ""))


## The player's designation and the handler's name, from the saved profile or, on a
## first launch, drawn from the session seed and saved. A damaged profile is moved
## aside by the store and replaced.
func _load_identity() -> void:
	_profile = {}
	if not _loaded:
		return
	var loaded := ProfileStore.load_profile()
	if String(loaded["status"]) == "ok":
		_profile = loaded["profile"]
	else:
		var designation := HandlerNames.designation(_seed)
		var avoid: Array = _static_handles()
		avoid.append(designation)
		var name := HandlerNames.generate(_bundle["names"], _seed, avoid)
		_profile = ProfileStore.new_profile(designation, name)
		ProfileStore.save_profile(_profile)
	_designation = String(_profile["player"]["designation"])
	_handler_name = String(_profile["handler"]["name"])
	_dossier = ProfileStore.load_dossier()


## Handles of the voices that are not the generated one.
func _static_handles() -> Array:
	var out: Array = []
	for r in _bundle["script"].get("rooms", []):
		for v in r.get("voices", []):
			if String(v.get("slot", "")) != "handler":
				out.append(String(v.get("handle", "")))
	return out


## A fresh model, per-room clocks and a fresh funnel for this seed. The player's own
## handle is the designation until a handle has been chosen; every room starts with
## its whole cast present.
func _build_session() -> void:
	model = ChatModel.new()
	_rooms_rt = {}
	funnel = null
	if not _loaded:
		return
	_script_rt = ChatroomScript.with_handler(_bundle["script"], _handler_name)
	var script := room_script()
	var acc: Dictionary = _profile["acceptance"]
	var self_handle := _designation
	if bool(acc["accepted"]) and not String(acc["handle"]).is_empty():
		self_handle = String(acc["handle"])
	model.setup(script, self_handle, String(script.get("entry_room", "")))
	for rid in model.room_order:
		var rt := RandomNumberGenerator.new()
		rt.seed = _seed ^ (String(rid).hash() & 0x7fffffff) ^ 0x1f123bb5
		_rooms_rt[rid] = {"plan": [], "plan_i": 0, "next_ms": 0, "pres_rng": rt, "next_pres_ms": 0}
	_funnel_on = bool(_bundle["funnel"].get("enabled", false))
	funnel = Funnel.new()
	funnel.setup(_bundle["funnel"], _bundle["beats"], _seed)
	_refresh_slots()
	if bool(acc["launched"]):
		funnel.mark_inert()
	elif bool(acc["accepted"]):
		if String(acc["handle"]).is_empty():
			funnel.resume_at("rename")
		else:
			funnel.resume_at("launch")
			funnel.handle = String(acc["handle"])


func _refresh_slots() -> void:
	var fields: Dictionary = _dossier.get("fields", {})
	funnel.set_slots({
		"handler": _handler_name,
		"designation": _designation,
		"handle": String(_profile["player"]["handle"]) if not _profile.is_empty() else "",
		"origin": String(fields.get("origin", "")),
		"doing": String(fields.get("doing", "")),
	})


func session_handle() -> String:
	return model.self_handle if model != null else ""


func session_seed() -> int:
	return _seed


func loaded() -> bool:
	return _loaded


func room_script() -> Dictionary:
	return _script_rt if not _script_rt.is_empty() else _bundle.get("script", {})


func entry_allowed() -> bool:
	return ChatroomScript.entry_allowed(state) and funnel != null and funnel.entry_allowed()


func is_busy() -> bool:
	return _busy


func is_inside() -> bool:
	return _inside


## The generated Empire handler's name in this session.
func contact_handle() -> String:
	return _handler_name


func profile_snapshot() -> Dictionary:
	return _profile.duplicate(true)


func dossier_snapshot() -> Dictionary:
	return _dossier.duplicate(true)


func funnel_enabled() -> bool:
	return _funnel_on


## Test hook (probes only): a fresh session, optionally with a pinned seed. Any
## reply still in flight is dropped. The saved profile and dossier are removed
## unless `keep_profile` (a fresh install each time, as the tests expect).
func reset_session(new_seed: int = -1, keep_profile: bool = false) -> void:
	_epoch += 1
	_seed = new_seed if new_seed >= 0 else _draw_seed()
	state = ""
	_inside = false
	_history = []
	_busy = false
	_queue = []
	_outbox = []
	_outbox_end = 0
	_launch_pending = false
	_left_ms = -1
	_leg_k = {}
	emission_log = []
	last_messages = []
	last_verdict = {}
	accepted_replies = 0
	rejected_replies = 0
	degraded_turns = 0
	model_requests = 0
	contact_ms = -1
	opened_ms = -1
	lines_received = 0
	first_message_ms = -1
	grant_ms = -1
	# The data files are read again, so a copy named by DECOHERENCE_CHATROOM_DIR takes effect.
	_bundle = ChatroomScript.load_bundle()
	_loaded = bool(_bundle.get("ok", false))
	if _loaded:
		_rules = _bundle["script"].get("scramble", {})
	_load_client_data()
	_hdata = ProfileStore.load_handler_data()
	if not keep_profile:
		for path in [ProfileStore.PROFILE_FILE, ProfileStore.DOSSIER_FILE]:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
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
	var now := now_ms()
	if _left_ms >= 0:
		# Time spent outside the room does not count against the player.
		var away := now - _left_ms
		_left_ms = -1
		_shift_queues(away)
	if _banner_pending:
		_banner_pending = false
		for line in room.get("banner", []):
			_push(String(room["id"]), _row(ChatModel.ROW_PRESENCE, "", String(line)))
		if _funnel_on and not funnel.inert:
			for b in funnel.beats_of("open", "lurk"):
				_push(String(room["id"]), _row(ChatModel.ROW_PRESENCE, "", funnel.render(String(b["plain"]))))
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
	_left_ms = now_ms()
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
	_deliver(buffer, ChatModel.ROW_SELF, cleaned)


## --- Routing (code decides which lines may reach the model) --------------------------------------

## The buffers that may use the model: before the direct message the buffer where the
## handler spoke and her direct message; from the direct message on, only that.
func _threads() -> Array:
	var out: Array = []
	if not _funnel_on or funnel == null or not _contact_done or not funnel.active():
		return out
	if funnel.stage < funnel.index_of("dm") and not _contact_target.is_empty():
		out.append(_contact_target)
	out.append(ChatModel.dm_id(_handler_name))
	return out


func _route_state() -> Dictionary:
	return {"reached": _contact_done, "threads": _threads()}


## One spoken line in `buffer`: it is echoed as the player's own row, then goes to the
## funnel thread or to a scripted voice, and the first sent message anywhere starts
## the contact timer exactly once.
func _deliver(buffer: String, kind: String, text: String) -> void:
	_push(buffer, _row(kind, model.self_handle, text))
	var handled := false
	if _funnel_on and not _loaded_inert():
		var on_thread := ChatModel.route_for(buffer, "x", _route_state()) == ChatroomScript.ROUTE_CONTACT
		if on_thread and funnel.stage < funnel.index_of("dm"):
			_thread_buf = buffer
		# Where she answers and which stage the line belongs to are fixed before the funnel
		# moves on: the reply to a room line stays in the room even if the stage advances.
		var target := _handler_buffer()
		var at_stage := funnel.stage
		var rx := funnel.on_player(text, now_ms(), "thread" if on_thread else "other", _taken_names(), _bundle["names"].get("reserved", []))
		handled = _apply_reaction(rx, buffer, text, on_thread, target, at_stage)
	if not handled:
		_scripted_reply(buffer, text)
	_note_message(buffer, text)


func _loaded_inert() -> bool:
	return funnel == null or funnel.inert


func _taken_names() -> Array:
	var out: Array = model.known_handles()
	out.append(_designation)
	out.append(_handler_name)
	return out


## What the funnel decided about the player's line. True when the line was a turn in
## the handler's thread (no scripted voice answers it).
func _apply_reaction(rx: Dictionary, buffer: String, text: String, on_thread: bool, target: String, at_stage: int) -> bool:
	match String(rx["kind"]):
		"model":
			_start_model(text, target, at_stage)
			return true
		"answer":
			_remember(String(rx["field"]), String(rx["value"]))
			_start_model(text, target, at_stage)
			return true
		"withhold":
			_enqueue_line(target, funnel.render(String(rx["beat"].get("plain", ""))), "withhold")
			return true
		"redirect":
			_enqueue_line(buffer, funnel.render(String(rx["beat"].get("plain", ""))), "redirect")
			return false
		"consent":
			_profile["acceptance"]["accepted"] = true
			_profile["acceptance"]["handler"] = _handler_name
			ProfileStore.save_profile(_profile)
			return true
		"refuse":
			_begin_disengage(String(rx.get("stage", funnel.stage_id())), target)
			return true
		"handle_ok":
			_begin_rename(String(rx["handle"]))
			return true
		"handle_bad":
			_enqueue_line(_handler_buffer(), funnel.render(String(rx["beat"].get("plain", ""))), "handle_invalid")
			return true
		"reapproach":
			funnel.reapproach(now_ms())
			_first_buffer = buffer
			return false
	return on_thread


func _remember(field: String, value: String) -> void:
	if ProfileStore.set_field(_dossier, field, value, _bundle["funnel"]["dossier"]):
		ProfileStore.save_dossier(_dossier)
	_refresh_slots()


## /forget: the dossier file and the in-memory copy go, and so does the model's short
## conversation history, so nothing she knew about the player is left to repeat.
func _forget() -> void:
	ProfileStore.wipe_dossier()
	_dossier = ProfileStore.empty_dossier()
	_history = []
	_refresh_slots()
	if _funnel_on and funnel.active() and _contact_done:
		var beat := funnel.pick("forget", "qualify")
		if not beat.is_empty():
			_enqueue_line(_handler_buffer(), funnel.render(String(beat["plain"])), "forget")


func _run_command(p: Dictionary) -> void:
	var active := model.active
	match String(p["kind"]):
		"join":
			var rid := model.room_id_for(String(p["name"]))
			if rid.is_empty():
				_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("no_such_channel")))
				return
			if model.join(rid):
				_rooms_rt[rid]["next_ms"] = now_ms()
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
		"forget":
			_forget()
		"quit":
			_leave()
		_:
			_push(active, _row(ChatModel.ROW_SYSTEM, "", ui_string("unknown_command")))


## The player's own handle is not a voice in any room, so find_handle() never
## returns it; /msg to self is matched by name instead.
func _is_self_name(name: String) -> bool:
	return name.strip_edges().to_upper() == model.self_handle.to_upper()


## --- The rooms ---------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _inside or not _loaded:
		return
	var now := now_ms()
	if _funnel_on and funnel != null:
		_pump_outbox(now)
		if not _busy and _outbox.size() < 3:
			var act := funnel.poll(now)
			if not act.is_empty():
				_perform(act)
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
	var room := ChatroomScript.room_by_id(room_script(), room_id)
	# While she is working with the player, the handler's own traffic stops.
	var quiet_handler := _funnel_on and funnel.active() and String(entry["voice"]) == String(ChatroomScript.slot_voice(room).get("id", "-"))
	if not quiet_handler:
		_write_voice(String(entry["voice"]), String(entry["plain"]), int(entry["scramble_seed"]), Beat.AMBIENT, room_id)
	_ensure_plan(room_id, int(rt["plan_i"]))
	var rate := 1.0
	var delay := int(float(rt["plan"][rt["plan_i"]]["interval_ms"]) / maxf(rate, 0.01))
	rt["next_ms"] = now + delay
	if not quiet_handler:
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
	emission_log.append({"t_ms": now_ms(), "beat": int(Beat.PRESENCE), "voice": "", "handle": String(ev["handle"]), "plain": "", "row": ui_string(line_key).replace("{name}", String(ev["handle"])), "buffer": room_id, "kind": String(ev["kind"])})


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
## rows are scrambled and dim; the handler's own rows are clear text.
func _write_voice(voice_id: String, plain: String, scramble_seed: int, beat: int, room_id: String = "") -> void:
	var rid := room_id if not room_id.is_empty() else String(room_script().get("entry_room", ""))
	var room := ChatroomScript.room_by_id(room_script(), rid)
	_say_voice(rid, ChatroomScript.voice_handle(room, voice_id), voice_id, plain, scramble_seed, beat)


func _say_voice(buffer_id: String, handle: String, voice_id: String, plain: String, scramble_seed: int, beat: int, extra: Dictionary = {}) -> void:
	var clear := beat == Beat.CONTACT
	var body := plain
	if not clear:
		clear = _row_legible(handle)
		if not clear:
			body = ChatroomScript.scramble_line(plain, scramble_seed, _rules, handle)
	# Somebody who is not in the room has to arrive before they can speak in it.
	if model.is_room(buffer_id) and model.set_present(buffer_id, handle) and bool(model.rooms[buffer_id]["joined"]):
		_push(buffer_id, _row(ChatModel.ROW_PRESENCE, "", ui_string("joined_line").replace("{name}", handle)))
	var row := "<%s> %s" % [handle, body]
	_push(buffer_id, _row(ChatModel.ROW_VOICE, handle, body, clear))
	var entry := {"t_ms": now_ms(), "beat": int(beat), "voice": voice_id, "handle": handle, "plain": plain, "row": row, "buffer": buffer_id, "clear": clear, "stage": funnel.stage_id() if funnel != null else ""}
	entry.merge(extra)
	emission_log.append(entry)


## Clearance: an Empire voice's row reads in clear text for the share of rows the
## stage allows; every other voice stays encrypted. The draw is spread evenly, so a
## measured share tracks the ratio, and it is seeded, so a replay is the same.
func _row_legible(handle: String) -> bool:
	if not _funnel_on or funnel == null or model.side_of(handle) != "empire":
		return false
	var ratio := Funnel.legible_ratio(_bundle["funnel"], funnel.stage, "empire")
	var k := int(_leg_k.get(funnel.stage, 0))
	_leg_k[funnel.stage] = k + 1
	return Funnel.row_legible(ratio, k, _leg_phase)


## Before the handler speaks: a scripted voice answers in the room; a direct message to
## an ordinary person is answered later from that person's own pool. After the
## launch her direct message is answered from the authored done pool.
func _scripted_reply(buffer: String, text: String) -> void:
	var script := room_script()
	if model.is_room(buffer):
		var res := ChatroomScript.respond(script, text, _fallback_i, buffer)
		if bool(res["fallback"]):
			_fallback_i += 1
		_write_voice(String(res["voice"]), String(res["plain"]), int(_rng.randi() & 0x7fffffff), Beat.RESPONDER, buffer)
	elif model.is_dm(buffer):
		var handle := String(model.buffers[buffer]["title"])
		if handle == _handler_name:
			if _funnel_on and funnel.inert:
				var beat := funnel.pick("done_reply", "launch")
				if not beat.is_empty():
					_enqueue_line(buffer, funnel.render(String(beat["plain"])), "done_reply")
			return
		_schedule_dm_reply(handle)


var _fallback_i: int = 0


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
		"at": now_ms() + _dm_rng.randi_range(int(d[0]), int(d[1])),
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
	if not _funnel_on or funnel == null or text.strip_edges().is_empty():
		return
	if funnel.note_first_message(now_ms()):
		_first_buffer = buffer
		first_message_ms = now_ms()


## Where the handler first speaks: the buffer of the first message when that was a room
## or her own direct message; otherwise the entry room.
func _contact_buffer() -> String:
	var script := room_script()
	var entry := String(script.get("entry_room", ""))
	var fb := _first_buffer
	if model.is_dm(fb) and String(model.buffers[fb]["title"]) == _handler_name:
		model.open_dm(_handler_name)
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


## --- The funnel speaks ----------------------------------------------------------------------------

## Where the handler's lines go: her direct message from the dm stage on, the buffer
## where she first spoke before it.
func _handler_buffer() -> String:
	if funnel.stage >= funnel.index_of("dm"):
		return ChatModel.dm_id(_handler_name)
	return _thread_buf if not _thread_buf.is_empty() else _contact_target


## Puts a line in the handler's mouth: it is typed for a time proportional to its
## length and appears when that time is up. Lines never overlap.
func _enqueue_line(buffer: String, text: String, fkind: String, then: String = "", extra: Dictionary = {}, due_override: int = -1, delay_ms: int = 0) -> void:
	var now := now_ms()
	var due := due_override if due_override >= 0 else maxi(now + delay_ms, _outbox_end) + funnel.typing_ms(text)
	_outbox_end = maxi(_outbox_end, due)
	_outbox.append({"due": due, "buffer": buffer, "text": text, "fkind": fkind, "then": then, "extra": extra, "epoch": _epoch})
	funnel.note_line(due)


func _pump_outbox(now: int) -> void:
	var ready: Array = []
	for item in _outbox:
		if now >= int(item["due"]):
			ready.append(item)
	ready.sort_custom(func(a, b): return int(a["due"]) < int(b["due"]))
	for item in ready:
		_outbox.erase(item)
		if int(item["epoch"]) != _epoch:
			continue
		_deliver_line(item)
	if _launch_pending and _outbox.is_empty():
		_launch_pending = false
		_launch_interim()


func _deliver_line(item: Dictionary) -> void:
	var buffer := String(item["buffer"])
	if buffer.begins_with(ChatModel.DM_PREFIX) and not model.buffers.has(buffer):
		model.open_dm(buffer.substr(ChatModel.DM_PREFIX.length()))
	if buffer.is_empty() or not model.buffers.has(buffer):
		buffer = _contact_buffer()
	var extra: Dictionary = {"fkind": String(item["fkind"])}
	extra.merge(item["extra"])
	var then := String(item["then"])
	if then == "contact":
		_contact_target = buffer
		_thread_buf = buffer
		_contact_done = true
		contact_ms = now_ms()
		state = ChatroomScript.ST_ENGAGED
	_say_voice(buffer, _handler_name, "", String(item["text"]), 0, Beat.CONTACT, extra)
	if then == "contact":
		Signals.chatroom_handler_found.emit()
	elif then == "swap":
		_swap_handler()
	elif then == "rename":
		_apply_rename(String(item["extra"].get("handle", "")))


## What the funnel asked for now: an authored beat, a lapse or the launch.
func _perform(act: Dictionary) -> void:
	match String(act["act"]):
		"say", "disengage":
			var stage := String(act["stage"])
			var fkind := String(act["kind"]) if act.has("kind") else "disengage"
			var buffer := ""
			if funnel.index_of(stage) >= funnel.index_of("dm"):
				buffer = ChatModel.dm_id(_handler_name)
			elif not _contact_done:
				buffer = _contact_buffer()
			else:
				buffer = _thread_buf if not _thread_buf.is_empty() else _contact_target
			var then := ""
			if String(act["act"]) == "disengage":
				then = "swap"
			elif stage == "contact" and not _contact_done:
				then = "contact"
			_enqueue_line(buffer, String(act["text"]), fkind, then, {"beat_id": String(act.get("beat_id", ""))}, int(act["end_ms"]))
		"launch":
			if _outbox.is_empty():
				_launch_interim()
			else:
				_launch_pending = true


## The player said no (or never answered): she says her goodbye and steps away.
func _begin_disengage(at_stage: String, target: String) -> void:
	var beat := funnel.disengage_beat(at_stage)
	var text := funnel.render(String(beat.get("plain", ""))) if not beat.is_empty() else ""
	if text.is_empty():
		_swap_handler()
		return
	_enqueue_line(target, text, "disengage", "swap", {"beat_id": String(beat.get("id", ""))})


## The handler leaves every room and a new generated Empire handler takes her place.
## The new one approaches only when the player speaks in a room again.
func _swap_handler() -> void:
	var old := _handler_name
	var former: Array = _profile["handler"]["former"]
	former.append(old)
	var avoid: Array = _static_handles()
	avoid.append(_designation)
	avoid.append_array(former)
	var fresh := HandlerNames.generate(_bundle["names"], _seed ^ (former.size() * 0x1b873593), avoid)
	_handler_name = fresh
	var present_in := model.swap_voice(old, fresh)
	for r in _script_rt.get("rooms", []):
		for v in r.get("voices", []):
			if String(v.get("slot", "")) == "handler":
				v["handle"] = fresh
	for rid in model.room_order:
		if not bool(model.rooms[rid]["joined"]):
			continue
		if present_in.has(rid):
			_push(rid, _row(ChatModel.ROW_PRESENCE, "", ui_string("left_line").replace("{name}", old)))
		_push(rid, _row(ChatModel.ROW_PRESENCE, "", ui_string("joined_line").replace("{name}", fresh)))
	_profile["handler"]["name"] = fresh
	_profile["acceptance"]["accepted"] = false
	_profile["acceptance"]["handler"] = ""
	ProfileStore.save_profile(_profile)
	_contact_done = false
	_contact_target = ""
	_thread_buf = ""
	state = ChatroomScript.ST_ROOM
	_refresh_slots()
	emission_log.append({"t_ms": now_ms(), "beat": int(Beat.PRESENCE), "voice": "", "handle": fresh, "plain": "", "row": "", "buffer": "", "kind": "swap", "old": old})
	Signals.chat_model_changed.emit()


## Consent was a clear yes and the player chose a handle: she says it, and then the
## roster, the nav label, the room presence line and the profile change together.
func _begin_rename(new_handle: String) -> void:
	funnel.set_slot("handle", new_handle)
	var beat := funnel.pick("rename_do", "rename")
	var text := funnel.render(String(beat.get("plain", "")))
	_enqueue_line(_handler_buffer(), text, "rename_do", "rename", {"handle": new_handle, "beat_id": String(beat.get("id", ""))})


func _apply_rename(new_handle: String) -> void:
	var old := model.self_handle
	model.rename_self(new_handle)
	for rid in model.room_order:
		if bool(model.rooms[rid]["joined"]):
			_push(rid, _row(ChatModel.ROW_PRESENCE, "", ui_string("renamed_line").replace("{old}", old).replace("{new}", new_handle)))
	_profile["player"]["handle"] = new_handle
	_profile["acceptance"]["handle"] = new_handle
	ProfileStore.save_profile(_profile)
	_refresh_slots()
	Signals.chat_model_changed.emit()


## The end of the funnel (Spec #573 D9, replaced by Spec #575): the only place that
## emits the entry signal. The player's colonist is assigned here, once, before the
## signal; the shell re-checks entry_allowed() and opens the HANDLER module. The signal
## keeps its name, and now means "entry to the module".
func _launch_interim() -> void:
	state = ChatroomScript.ST_LAUNCH
	_profile["acceptance"]["launched"] = true
	ProfileStore.save_profile(_profile)
	ensure_colonist()
	grant_ms = now_ms()
	Signals.chatroom_entry_granted.emit()
	if _shell != null and _shell.current_state_name() in ["WORLD", "HANDLER"]:
		_inside = false
	funnel.mark_inert()
	state = ChatroomScript.ST_ROOM


## --- The HANDLER module (Spec #575) ----------------------------------------------------------

## The module's data files: {ok, dir, tables, rules, ui, route}.
func handler_data() -> Dictionary:
	return _hdata


## True once the funnel is finished: the player's file is open to them (the module unlocks).
func handler_unlocked() -> bool:
	return not _profile.is_empty() and bool(_profile["acceptance"]["launched"])


## The assigned colonist (the first assignment), or {} when none is stored.
func colonist() -> Dictionary:
	var a: Array = _profile.get("assignments", [])
	return a[0] if a.size() > 0 and typeof(a[0]) == TYPE_DICTIONARY else {}


func colonist_id() -> String:
	return String(colonist().get("fields", {}).get("colonist_id", ""))


## Generates the colonist when the profile has none, replaces a stored one only if it fails
## validation (an acceptance of the old one is cleared), and saves what changed. True when a
## valid colonist is stored afterwards.
func ensure_colonist() -> bool:
	if not handler_unlocked() or not bool(_hdata.get("ok", false)):
		return false
	var res := ColonistGen.ensure(_profile, _hdata["tables"], _hdata["rules"])
	if bool(res["regenerated"]):
		_profile = res["profile"]
		ProfileStore.save_profile(_profile)
	return not colonist().is_empty()


## The Launch press: records the acceptance of the mission before anything is entered. {ok,
## assignment_id}. A colonist that no longer validates is not accepted.
func accept_mission() -> Dictionary:
	if not handler_unlocked() or not bool(_hdata.get("ok", false)) or colonist().is_empty():
		return {"ok": false, "assignment_id": ""}
	if not ColonistGen.validate(colonist(), _hdata["tables"], _hdata["rules"], false).is_empty():
		return {"ok": false, "assignment_id": ""}
	_profile["acceptance"]["mission_accepted"] = true
	ProfileStore.save_profile(_profile)
	return {"ok": true, "assignment_id": colonist_id()}


## --- The model turn ------------------------------------------------------------------------------------

func _start_model(text: String, target: String, at_stage: int) -> void:
	_queue.append({"text": text, "buffer": target, "stage": at_stage})
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty() or not _inside or _llm == null:
		return
	_busy = true
	var item: Dictionary = _queue.pop_front()
	var text: String = item["text"]
	var briefing: Dictionary = _bundle["briefing"]
	var fcfg: Dictionary = _bundle["funnel"]
	var at_stage: int = int(item["stage"])
	var facts := ChatroomScript.facts_available(briefing, Funnel.stage_ids(fcfg), at_stage)
	var messages := ChatroomScript.build_funnel_messages(_bundle["persona"], briefing, facts, _dossier.get("fields", {}), _handler_name, _history, text, int(fcfg.get("history_turns", 6)))
	last_messages = messages
	last_prompt_stage = at_stage
	var mcfg: Dictionary = fcfg.get("model", {})
	var options := {
		"thinking": false,
		"temperature": float(mcfg.get("temperature", 0.3)),
		"seed": int(mcfg.get("seed", 573)),
		"max_tokens": int(mcfg.get("max_tokens", 160)),
		"schema": FunnelGuard.schema(int(mcfg.get("say_max_chars", 240)), int(mcfg.get("claims_max", 3))),
		"timeout_ms": int(mcfg.get("timeout_ms", 12000)),
		"reasoning_probe": Callable(self, "_on_reasoning"),
	}
	_reasoning_seen = ""
	model_requests += 1
	_llm.complete_structured(messages, options, _on_turn_done.bind(_epoch, text, facts, String(item["buffer"]), at_stage))


var _reasoning_seen: String = ""


## The client hands over whatever reasoning text the server attached (empty when
## thinking is off); it is used only to reject a reply that repeats it.
func _on_reasoning(reasoning: String) -> void:
	_reasoning_seen = reasoning


## Bound method, never a lambda (lambdas capture by value).
func _on_turn_done(result: Dictionary, epoch: int, text: String, facts: Array, buffer: String, at_stage: int) -> void:
	if epoch != _epoch:
		return
	_busy = false
	var handler: Dictionary = room_script().get("handler", {})
	var fcfg: Dictionary = _bundle["funnel"]
	var latency := 0
	if _sim:
		var lat: Array = fcfg.get("sim", {}).get("model_latency_ms", [900, 2600])
		latency = _lat_rng.randi_range(int(lat[0]), int(lat[1]))
	if not bool(result.get("ok", false)):
		# Transport failure: the funnel goes on with its authored words.
		degraded_turns += 1
		last_verdict = {"ok": false, "reason": "transport:" + String(result.get("error", ""))}
		_push(buffer, _row(ChatModel.ROW_SYSTEM, "", String(handler.get("degrade_line", ""))))
		_speak_fallback(buffer, latency)
		_pump()
		return
	var allowed: Array = [_handler_name, _designation, model.self_handle]
	for b in _bundle["beats"]:
		allowed.append(String(b.get("plain", "")))
	allowed.append_array((_dossier.get("fields", {}) as Dictionary).values())
	var ctx := {
		"guard": fcfg["guard"],
		"facts": facts,
		"allowed_text": allowed,
		"stage_index": at_stage,
		"pitch_index": funnel.index_of("pitch"),
		"max_say": int(fcfg.get("model", {}).get("say_max_chars", 240)),
		"reasoning": _reasoning_seen,
	}
	var verdict := FunnelGuard.check(String(result.get("content", "")), ctx)
	last_verdict = verdict
	if not bool(verdict["ok"]):
		rejected_replies += 1
		_speak_fallback(buffer, latency)
	else:
		accepted_replies += 1
		var say := String(verdict["say"])
		_enqueue_line(buffer, say, "model", "", {"claims": verdict["claims"]}, -1, latency)
		_history.append({"role": "user", "content": text})
		_history.append({"role": "assistant", "content": say})
		Signals.handler_reply_complete.emit(say)
	_pump()


## The stage's own words stand in for a reply that was rejected or never came.
func _speak_fallback(buffer: String, latency: int) -> void:
	var beat := funnel.fallback_beat()
	var say := funnel.render(String(beat.get("plain", String(_bundle["persona"].get("fallback_say", ""))))) if not beat.is_empty() else String(_bundle["persona"].get("fallback_say", ""))
	_enqueue_line(buffer, say, "fallback", "", {"beat_id": String(beat.get("id", ""))}, -1, latency)
