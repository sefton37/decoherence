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

enum Beat { AMBIENT, RESPONDER, CONTACT }

var state: String = ""

var _terminal: TerminalGrid = null
var _llm: LlmClient = null
var _shell: ShellController = null
var _bundle: Dictionary = {}
var _loaded: bool = false
var _inside: bool = false
var _seed: int = 0
var _rng := RandomNumberGenerator.new()

var _plan: Array = []
var _plan_i: int = 0
var _next_ambient_ms: int = 0
var _rules: Dictionary = {}

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
	_plan = []
	_plan_i = 0


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
	_reseed()
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
	_terminal.write_line(String(room.get("title", "")), Palette.ORANGE)
	for line in room.get("banner", []):
		_terminal.write_line(String(line), Palette.TEAL)
	_next_ambient_ms = Time.get_ticks_msec()
	opened_ms = _next_ambient_ms
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
	if state == ChatroomScript.ST_OFFERED and ChatroomScript.matches_command(handler.get("accept_commands", []), cleaned):
		_grant()
		return
	if state == ChatroomScript.ST_ROOM:
		_room_message(cleaned)
	else:
		_queue.append(cleaned)
		_pump()


func _grant() -> void:
	Signals.chatroom_entry_granted.emit()
	if _shell != null and _shell.current_state_name() == "WORLD":
		_inside = false


## --- The room ---------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _inside or not _loaded:
		return
	var now := Time.get_ticks_msec()
	if _contact_pending and now >= _contact_at_ms:
		_fire_contact(now)
	if now >= _next_ambient_ms:
		_emit_ambient(now)


func _ensure_plan(upto: int) -> void:
	if _plan.size() <= upto:
		_plan = ChatroomScript.ambient_plan(room_script(), _seed, maxi(64, _plan.size() * 2))


func _emit_ambient(now: int) -> void:
	_ensure_plan(_plan_i + 1)
	if _plan.is_empty():
		_next_ambient_ms = now + 60000
		return
	var entry: Dictionary = _plan[_plan_i]
	_plan_i += 1
	_write_voice(String(entry["voice"]), String(entry["plain"]), int(entry["scramble_seed"]), Beat.AMBIENT)
	_ensure_plan(_plan_i)
	var room := ChatroomScript.entry_room(room_script())
	var rate := float(room.get("ambient", {}).get("rate_after_contact", 1.0)) if _contact_done else 1.0
	var delay := int(float(_plan[_plan_i]["interval_ms"]) / maxf(rate, 0.01))
	_next_ambient_ms = now + delay
	emission_log[emission_log.size() - 1]["next_delay_ms"] = delay
	emission_log[emission_log.size() - 1]["rate"] = rate


## Writes one voice row. Ambient and responder rows are scrambled and dim; the
## contact's rows are clear text in the normal terminal colour.
func _write_voice(voice_id: String, plain: String, scramble_seed: int, beat: int) -> void:
	var room := ChatroomScript.entry_room(room_script())
	var handle := ChatroomScript.voice_handle(room, voice_id)
	var body := plain if beat == Beat.CONTACT else ChatroomScript.scramble(plain, scramble_seed, _rules)
	var row := "<%s> %s" % [handle, body]
	var color = Palette.TEAL if beat == Beat.CONTACT else Palette.TEAL_DIM
	var cps: float = _shell.text_cps() if (_shell != null and beat == Beat.CONTACT) else 0.0
	# The terminal wraps at a fixed column, mid-word; a clear-text line is wrapped
	# at word boundaries here instead, continuation lines indented past the handle.
	var shown: Array = _wrap_words(row, _terminal.max_cols - 1, handle.length() + 3) if beat == Beat.CONTACT else [row]
	for piece in shown:
		if cps > 0.0:
			_terminal.write_line_typed(String(piece), color, cps)
		else:
			_terminal.write_line(String(piece), color)
	emission_log.append({"t_ms": Time.get_ticks_msec(), "beat": int(beat), "voice": voice_id, "handle": handle, "plain": plain, "row": row})


static func _wrap_words(text: String, cols: int, indent: int) -> Array:
	var lines: Array = []
	var cur := ""
	for word in text.split(" ", false):
		if cur.is_empty():
			cur = word
		elif cur.length() + 1 + word.length() <= cols:
			cur += " " + word
		else:
			lines.append(cur)
			cur = " ".repeat(indent) + word
	lines.append(cur)
	return lines


## Before the contact: a scripted voice answers; the first non-empty message
## also starts the contact timer, exactly once.
func _room_message(text: String) -> void:
	var script := room_script()
	var room := ChatroomScript.entry_room(script)
	var res := ChatroomScript.respond(script, text, _fallback_i)
	if bool(res["fallback"]):
		_fallback_i += 1
	_write_voice(String(res["voice"]), String(res["plain"]), int(_rng.randi() & 0x7fffffff), Beat.RESPONDER)
	var trigger: Dictionary = room.get("handler_trigger", {})
	if ChatroomScript.trigger_fires(trigger, _trigger_fired, text):
		_trigger_fired = true
		var d: Array = trigger["contact_delay_ms"]
		_contact_pending = true
		_contact_at_ms = Time.get_ticks_msec() + _rng.randi_range(int(d[0]), int(d[1]))


func _fire_contact(now: int) -> void:
	var room := ChatroomScript.entry_room(room_script())
	var line: Dictionary = room["handler_trigger"]["contact_line"]
	_contact_pending = false
	_contact_done = true
	contact_ms = now
	state = ChatroomScript.ST_BRIEFING
	_write_voice(String(line["voice"]), String(line["plain"]), 0, Beat.CONTACT)
	Signals.chatroom_handler_found.emit()


## --- The briefing turn ---------------------------------------------------------------------------

func _pump() -> void:
	if _busy or _queue.is_empty() or not _inside:
		return
	_busy = true
	var text: String = _queue.pop_front()
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
	_llm.complete_structured(messages, options, _on_turn_done.bind(_epoch, text, new_ids, offer_due))


var _reasoning_seen: String = ""


## The client hands over whatever reasoning text the server attached (empty when
## thinking is off); it is used only to reject a reply that repeats it.
func _on_reasoning(reasoning: String) -> void:
	_reasoning_seen = reasoning


## Bound method, never a lambda (lambdas capture by value).
func _on_turn_done(result: Dictionary, epoch: int, text: String, new_ids: Array, offer_due: bool) -> void:
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
		_terminal.write_line(String(handler.get("degrade_line", "")), Palette.ORANGE)
		_pump()
		return
	_player_turns += 1
	_unlocked.append_array(new_ids)
	if offer_due:
		_due_turns += 1
	var limits: Dictionary = script.get("limits", {})
	var verdict := ChatroomScript.validate_handler_reply(String(result.get("content", "")), offer_due, int(limits.get("say_max_chars", 240)), _reasoning_seen)
	last_verdict = verdict
	var voice_id := String(ChatroomScript.entry_room(script)["handler_trigger"]["contact_line"]["voice"])
	if not bool(verdict["ok"]):
		rejected_replies += 1
		_write_voice(voice_id, String(persona.get("fallback_say", "")), 0, Beat.CONTACT)
	else:
		accepted_replies += 1
		var say := String(verdict["say"])
		_write_voice(voice_id, say, 0, Beat.CONTACT)
		_history.append({"role": "user", "content": text})
		_history.append({"role": "assistant", "content": say})
		_credited.append_array(ChatroomScript.credit(_bundle["briefing"], _unlocked, say, _credited))
		Signals.handler_reply_complete.emit(say)
	_settle_offer(bool(verdict["ok"]) and String(verdict["act"]) == "offer_entry", offer_due, voice_id)
	_ready_flag = ChatroomScript.readiness(_bundle["readiness"], _credited, _player_turns)
	if _ready_flag and ready_at_turn < 0:
		ready_at_turn = _player_turns
	_pump()


## The offer: honoured when the model proposed it on a due turn; if it still has
## not offered after the grace turns, code speaks the script's own offer line.
func _settle_offer(model_offered: bool, offer_due: bool, voice_id: String) -> void:
	if state != ChatroomScript.ST_BRIEFING or not offer_due:
		return
	var grace := int(_bundle["readiness"].get("offer_grace_turns", 1))
	if model_offered:
		state = ChatroomScript.ST_OFFERED
	elif _due_turns > grace:
		_write_voice(voice_id, String(room_script().get("handler", {}).get("offer_fallback_line", "")), 0, Beat.CONTACT)
		state = ChatroomScript.ST_OFFERED
	if state == ChatroomScript.ST_OFFERED:
		Signals.chatroom_entry_offered.emit()
