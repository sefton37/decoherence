extends RefCounted
class_name Funnel

## The recruitment funnel's stage machine (Spec #573). Code owns the stage
## order, the dwell and idle clocks, the consent and refusal words and the
## legibility curve; the model only fills words inside a stage and can never move
## one. Pure: every time is a `now` (milliseconds) passed in, the only randomness
## is a seeded generator owned by the instance, and nothing here reads a file or
## the scene. `Chatroom` feeds it player lines and polls it for what to say.
##
## Stages (ids and order are data, funnel.json): lurk, contact, qualify, pushback,
## dm, pitch, ask, rename, launch. A stage moves only forward and only by one.
## Every spoken word is a beat in funnel_beats.json.

const KIND_OPEN := "open"
const KIND_CALLBACK := "callback"
const KIND_LAUNCH := "launch"
const OUT_REFUSED := "refused"
const OUT_LAPSED := "lapsed"
const OUT_LAUNCHED := "launched"
## Pause after a line (or a reply) before the model's line is followed by the next beat.
const AFTER_LINE_MS := 600

var stage: int = 0
var outcome: String = ""
var accepted: bool = false
var handle: String = ""
var started: bool = false
var inert: bool = false

## Probe-facing records (never rendered): every stage entered, in order, the
## moves the machine refused, and counters.
var transitions: Array = []
var rejected_moves: int = 0
var idle_fired: int = 0
var idle_lapse_followups: int = 0
var redirects_used: int = 0
var withheld_used: int = 0

var _cfg: Dictionary = {}
var _beats: Array = []
var _ids: Array = []
var _rng := RandomNumberGenerator.new()
var _beat_i: int = 0
var _next_at: int = -1
var _waiting: bool = false
var _wait_since: int = 0
var _busy_until: int = 0
var _idle_n: int = 0
var _turns: int = 0
var _reask_due: bool = false
var _asked: bool = false
var _pending_ask: String = ""
var _slots: Dictionary = {}
var _cycle: Dictionary = {}


func setup(cfg: Dictionary, beats: Array, seed_value: int) -> void:
	_cfg = cfg
	_beats = beats
	_ids = []
	for s in cfg.get("stages", []):
		_ids.append(String(s.get("id", "")))
	_rng.seed = seed_value ^ 0x7f4a7c15
	reset()


## Back to the lurk stage with nothing said. Slots and beats are kept.
func reset() -> void:
	stage = 0
	outcome = ""
	accepted = false
	handle = ""
	started = false
	inert = false
	transitions = []
	rejected_moves = 0
	idle_fired = 0
	idle_lapse_followups = 0
	redirects_used = 0
	withheld_used = 0
	_cycle = {}
	_slots = {}
	_clear_stage_state()


func _clear_stage_state() -> void:
	_beat_i = 0
	_next_at = -1
	_waiting = false
	_wait_since = 0
	_busy_until = 0
	_idle_n = 0
	_turns = 0
	_reask_due = false
	_asked = false
	_pending_ask = ""


## --- Static helpers over the data -----------------------------------------------------

static func stage_ids(cfg: Dictionary) -> Array:
	var out: Array = []
	for s in cfg.get("stages", []):
		out.append(String(s.get("id", "")))
	return out


## Share of an Empire voice's rows that read in clear text at this stage; the
## other factions never do.
static func legible_ratio(cfg: Dictionary, stage_index: int, side: String) -> float:
	if side != "empire":
		return float(cfg.get("faction_legible_ratio", 0.0))
	var stages: Array = cfg.get("stages", [])
	if stage_index < 0 or stage_index >= stages.size():
		return 0.0
	return float(stages[stage_index].get("legible_ratio", 0.0))


## Evenly spread draw: of the first n rows at ratio r, exactly floor(n*r+phase)
## are legible (so a measured fraction tracks the ratio to within 1/n). `phase`
## in [0,1) keeps different voices and sessions from reading in lock-step.
static func row_legible(ratio: float, k: int, phase: float) -> bool:
	if ratio <= 0.0:
		return false
	if ratio >= 1.0:
		return true
	return floori(float(k + 1) * ratio + phase) > floori(float(k) * ratio + phase)


## ASCII only, case folded, whitespace collapsed. Any other character makes the
## whole line "not ASCII" and the caller treats it as no match (look-alikes lose).
static func ascii_flat(text: String) -> String:
	var out := ""
	var last_space := true
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c > 127:
			return "\u0000"
		if c >= 65 and c <= 90:
			c += 32
		if c == 9 or c == 10 or c == 13 or c == 32:
			if not last_space:
				out += " "
				last_space = true
			continue
		out += char(c)
		last_space = false
	return out.strip_edges()


## "yes" (a whole-message match of consent_yes), "refuse" (a whole-message or a
## leading-phrase match of refuse) or "other". Consent never matches on a prefix:
## a message that carries anything more than a listed word is not a yes.
static func classify(cfg: Dictionary, text: String) -> String:
	var flat := ascii_flat(text)
	if flat == "\u0000" or flat.is_empty():
		return "other"
	for y in cfg.get("consent_yes", []):
		if flat == ascii_flat(String(y)):
			return "yes"
	for r in cfg.get("refuse", []):
		var p := ascii_flat(String(r))
		if p.is_empty() or not flat.begins_with(p):
			continue
		if flat.length() == p.length():
			return "refuse"
		var next := flat.unicode_at(p.length())
		var is_word := (next >= 97 and next <= 122) or (next >= 48 and next <= 57)
		if not is_word:
			return "refuse"
	return "other"


## {ok, handle, reason}. `taken` and `reserved` are compared ASCII case-insensitively.
static func validate_handle(cfg: Dictionary, text: String, taken: Array, reserved: Array) -> Dictionary:
	var h: Dictionary = cfg.get("handle", {})
	var t := text.strip_edges()
	if t.is_empty():
		return {"ok": false, "handle": "", "reason": "empty"}
	for i in range(t.length()):
		var c := t.unicode_at(i)
		if c > 127:
			return {"ok": false, "handle": "", "reason": "non_ascii"}
		if c == 32 or c == 9:
			return {"ok": false, "handle": "", "reason": "space"}
	if t.length() < int(h.get("min_len", 3)):
		return {"ok": false, "handle": "", "reason": "short"}
	if t.length() > int(h.get("max_len", 16)):
		return {"ok": false, "handle": "", "reason": "long"}
	var re := RegEx.new()
	re.compile(String(h.get("pattern", "^[A-Za-z0-9_-]+$")))
	if re.search(t) == null:
		return {"ok": false, "handle": "", "reason": "chars"}
	var up := t.to_upper()
	for r in reserved:
		if String(r).to_upper() == up:
			return {"ok": false, "handle": "", "reason": "reserved"}
	for x in taken:
		if String(x).to_upper() == up:
			return {"ok": false, "handle": "", "reason": "taken"}
	return {"ok": true, "handle": t, "reason": ""}


## --- Slots and beats ----------------------------------------------------------------------

## Values for {designation} {handler} {handle} {origin} {doing}; empty ones are unresolved.
func set_slots(slots: Dictionary) -> void:
	_slots = slots.duplicate()


func set_slot(key: String, value: String) -> void:
	_slots[key] = value


func render(plain: String) -> String:
	var out := plain
	for k in _slots:
		out = out.replace("{" + String(k) + "}", String(_slots[k]))
	return out


func unresolved(plain: String) -> bool:
	var re := RegEx.new()
	re.compile("\\{([a-z_]+)\\}")
	for m in re.search_all(plain):
		if String(_slots.get(m.get_string(1), "")).is_empty():
			return true
	return false


func stage_id() -> String:
	return String(_ids[stage]) if stage >= 0 and stage < _ids.size() else ""


func index_of(id: String) -> int:
	return _ids.find(id)


func typing_ms(text: String) -> int:
	return int(float(text.length()) * float(_cfg.get("typing_ms_per_char", 55)))


func _stage_cfg(i: int) -> Dictionary:
	var stages: Array = _cfg.get("stages", [])
	return stages[i] if i >= 0 and i < stages.size() else {}


func _dwell(i: int) -> int:
	var d: Array = _stage_cfg(i).get("dwell_ms", [0, 0])
	return _rng.randi_range(int(d[0]), int(d[1]))


## All beats of a kind in file order, optionally for one stage id.
func beats_of(kind: String, stage_name: String = "") -> Array:
	var out: Array = []
	for b in _beats:
		if String(b.get("kind", "")) == kind and (stage_name.is_empty() or String(b.get("stage", "")) == stage_name):
			out.append(b)
	return out


## The next beat of a kind for this stage, cycling through them. Falls back to
## any stage's beats of that kind when this stage has none.
func pick(kind: String, stage_name: String = "") -> Dictionary:
	var name := stage_name if not stage_name.is_empty() else stage_id()
	var pool := beats_of(kind, name)
	if pool.is_empty():
		pool = beats_of(kind)
	if pool.is_empty():
		return {}
	var key := kind + "|" + name
	var i := int(_cycle.get(key, 0))
	_cycle[key] = i + 1
	return pool[i % pool.size()]


func fallback_beat() -> Dictionary:
	var pool := beats_of("ack", stage_id())
	if pool.is_empty():
		pool = beats_of("ack")
	return pool[0] if not pool.is_empty() else {}


## The line she says when she steps away (a refusal or a lapse).
func disengage_beat(at_stage: String) -> Dictionary:
	var pool := beats_of("disengage", at_stage)
	if pool.is_empty():
		pool = beats_of("disengage")
	return pool[0] if not pool.is_empty() else {}


## The next scripted beat of the current stage, without moving past it. Callbacks
## whose slots are empty and questions the dossier already answers are skipped.
func _peek_script() -> Dictionary:
	var name := stage_id()
	var i := _beat_i
	var skip := 0
	while true:
		var seen := 0
		var found: Dictionary = {}
		for b in _beats:
			if String(b.get("stage", "")) != name:
				continue
			var k := String(b.get("kind", ""))
			if k != KIND_OPEN and k != KIND_CALLBACK and k != KIND_LAUNCH:
				continue
			if seen == i:
				found = b
				break
			seen += 1
		if found.is_empty():
			return {}
		var plain := String(found.get("plain", ""))
		var asks := String(found.get("asks", ""))
		var skipped := unresolved(plain) or (not asks.is_empty() and not String(_slots.get(asks, "")).is_empty())
		if not skipped:
			_beat_i = i
			return found
		i += 1
	return {}


## --- Entering the funnel ----------------------------------------------------------------

## The player's first sent message: the contact timer starts, exactly once.
func note_first_message(now: int) -> bool:
	if started:
		return false
	started = true
	_next_at = now + _dwell(maxi(stage, 1))
	return true


## Restart a funnel that was left mid-way: the stage comes from the saved profile.
func resume_at(stage_name: String) -> void:
	var i := index_of(stage_name)
	if i < 0:
		return
	_clear_stage_state()
	stage = i
	transitions.append([maxi(i - 1, 0), i])
	if stage_name == "launch" or stage_name == "rename":
		accepted = true


## A player who has launched before: nothing more is ever said (decision D8).
func mark_inert() -> void:
	_clear_stage_state()
	stage = _ids.size() - 1
	accepted = true
	started = true
	inert = true
	outcome = OUT_LAUNCHED


## After a refusal or a lapse: a new handler approaches once the player speaks.
func reapproach(now: int) -> void:
	outcome = ""
	accepted = false
	handle = ""
	_clear_stage_state()
	stage = 0
	started = true
	_next_at = now + _dwell(1)


func entry_allowed() -> bool:
	return not inert and stage == _ids.size() - 1 and accepted and not handle.is_empty() and outcome != OUT_REFUSED and outcome != OUT_LAPSED


func active() -> bool:
	return started and outcome.is_empty()


func pending_wait() -> bool:
	return _waiting


## When the current wait began (the end of the line that is being answered).
func wait_since() -> int:
	return _wait_since


## --- Time and lines -----------------------------------------------------------------------------

## The chatroom tells the funnel when a line it put in the handler's mouth (a model
## reply, a withhold line, the rename line) will have finished typing.
func note_line(end_ms: int) -> void:
	_busy_until = maxi(_busy_until, end_ms)
	if _next_at >= 0:
		_next_at = maxi(_next_at, end_ms + AFTER_LINE_MS)
	if _waiting:
		_wait_since = maxi(_wait_since, end_ms)


## The player was away for `delta` ms with the clock still running: move every
## pending time forward by it, so nothing she was about to say fires on return.
func shift_time(delta: int) -> void:
	if _next_at >= 0:
		_next_at += delta
	_busy_until += delta
	_wait_since += delta


func _enter(i: int, now: int) -> void:
	transitions.append([stage, i])
	stage = i
	_beat_i = 0
	_idle_n = 0
	_turns = 0
	_waiting = false
	_reask_due = false
	_asked = false
	_pending_ask = ""
	_next_at = maxi(now, _busy_until) + _dwell(i)


func _say(beat: Dictionary, now: int, where: String) -> Dictionary:
	var text := render(String(beat.get("plain", "")))
	var typing := typing_ms(text)
	_busy_until = maxi(_busy_until, now) + typing
	return {"act": "say", "beat_id": String(beat.get("id", "")), "kind": String(beat.get("kind", "")), "text": text, "stage": stage_id(), "typing_ms": typing, "end_ms": _busy_until, "where": where}


## What to do now, if anything: {} or {act: "say"|"disengage"|"launch", ...}.
func poll(now: int) -> Dictionary:
	if not started or not outcome.is_empty():
		return {}
	if _next_at >= 0 and now >= _next_at and now >= _busy_until:
		return _speak_next(now)
	if _waiting and now >= _busy_until and now - maxi(_wait_since, _busy_until) >= int(_stage_cfg(stage).get("idle_ms", 30000)):
		return _idle(now)
	return {}


func _speak_next(now: int) -> Dictionary:
	_next_at = -1
	if stage == 0:
		_enter(1, now)
		_next_at = -1
	if _reask_due:
		_reask_due = false
		var re := pick("reask", stage_id())
		if not re.is_empty():
			var act := _say(re, now, "thread")
			_waiting = true
			_asked = true
			_wait_since = int(act["end_ms"])
			return act
	var b := _peek_script()
	if b.is_empty():
		return _finish_stage(now)
	_beat_i += 1
	var act := _say(b, now, "thread")
	_pending_ask = String(b.get("asks", ""))
	if bool(b.get("wait", false)):
		_waiting = true
		_asked = true
		_wait_since = int(act["end_ms"])
	else:
		_next_at = int(act["end_ms"]) + _dwell(stage)
	return act


func _finish_stage(now: int) -> Dictionary:
	if stage >= _ids.size() - 1:
		if outcome.is_empty():
			outcome = OUT_LAUNCHED
			return {"act": "launch", "stage": stage_id()}
		return {}
	_enter(stage + 1, now)
	return {}


func _idle(now: int) -> Dictionary:
	var cfg := _stage_cfg(stage)
	if _idle_n < int(cfg.get("max_idle_followups", 1)):
		var pool := beats_of("idle_followup", stage_id())
		if pool.is_empty():
			pool = beats_of("idle_followup")
		_idle_n += 1
		idle_fired += 1
		var beat: Dictionary = pool[(_idle_n - 1) % pool.size()] if not pool.is_empty() else {}
		if beat.is_empty():
			_wait_since = now
			return {}
		var act := _say(beat, now, "thread")
		_wait_since = int(act["end_ms"])
		return act
	if bool(cfg.get("advance_on_idle", false)):
		_waiting = false
		_next_at = maxi(now, _busy_until) + _dwell(stage)
		return {}
	idle_lapse_followups = _idle_n
	var at := stage_id()
	outcome = OUT_LAPSED
	_waiting = false
	_next_at = -1
	var dis := disengage_beat(at)
	if dis.is_empty():
		return {"act": "disengage", "why": "lapsed", "stage": at}
	var out := _say(dis, now, "thread")
	out["act"] = "disengage"
	out["why"] = "lapsed"
	return out


## --- The player speaks -------------------------------------------------------------------------------

## `where` is "thread" (the handler's current thread), "other" (anywhere else) or
## "dm" is never passed: the chatroom maps the DM to "thread" from the dm stage on.
## Returns {kind}: "none", "model" (one model reply, then the script goes on),
## "answer" (field, value: a qualify answer; a model reply follows), "withhold"
## (beat), "redirect" (beat), "consent", "refuse", "handle_ok" (handle),
## "handle_bad" (reason, beat), "reapproach".
func on_player(text: String, now: int, where: String, taken: Array = [], reserved: Array = []) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {"kind": "none"}
	if not outcome.is_empty():
		if outcome == OUT_LAUNCHED:
			return {"kind": "none"}
		return {"kind": "reapproach"} if where == "other" else {"kind": "none"}
	if not started:
		return {"kind": "none"}
	var name := stage_id()
	if where == "other":
		if name == "dm" and redirects_used < int(_cfg.get("max_redirects", 2)):
			redirects_used += 1
			var beat := pick("redirect", "dm")
			if not beat.is_empty():
				return {"kind": "redirect", "beat": beat}
		return {"kind": "none"}
	if stage == 0:
		return {"kind": "none"}
	_turns += 1
	# Consent and refusal are read here, in code, and only where they mean something.
	if stage >= index_of("pushback") and stage < index_of("rename"):
		var verdict := classify(_cfg, t)
		if verdict == "refuse":
			outcome = OUT_REFUSED
			_waiting = false
			_next_at = -1
			return {"kind": "refuse", "stage": name}
		if name == "ask" and verdict == "yes" and _asked:
			accepted = true
			_enter(index_of("rename"), now)
			return {"kind": "consent"}
	if name == "ask" and _asked:
		_waiting = false
		_reask_due = true
		_next_at = maxi(now, _busy_until) + _dwell(stage)
		return {"kind": "model"}
	if name == "rename" and _asked:
		var v := validate_handle(_cfg, t, taken, reserved)
		if bool(v["ok"]):
			handle = String(v["handle"])
			_enter(index_of("launch"), now)
			return {"kind": "handle_ok", "handle": handle}
		rejected_moves += 1
		return {"kind": "handle_bad", "reason": String(v["reason"]), "beat": pick("handle_invalid", "rename")}
	if name == "launch":
		return {"kind": "none"}
	var reaction := {"kind": "model"}
	if name == "qualify" and _waiting and not _pending_ask.is_empty():
		reaction = {"kind": "answer", "field": _pending_ask, "value": t}
		_pending_ask = ""
	elif name == "pushback" and _is_where_what(t):
		withheld_used += 1
		reaction = {"kind": "withhold", "beat": pick("withhold", "pushback")}
	if _waiting:
		if name == "pushback" and _turns < int(_cfg.get("pushback_min_turns", 1)):
			return reaction
		_waiting = false
		if _peek_script().is_empty():
			_finish_stage(now)
		else:
			_next_at = maxi(now, _busy_until) + _dwell(stage)
	return reaction


func _is_where_what(text: String) -> bool:
	var flat := " " + ChatroomScript.normalize(text) + " "
	for c in _cfg.get("where_what_cues", []):
		var n := ChatroomScript.normalize(String(c))
		if not n.is_empty() and flat.contains(" " + n + " "):
			return true
	return false


## Counts a move the machine refused (a probe or a unit calls this to record one).
func note_rejected() -> void:
	rejected_moves += 1
