extends RefCounted
class_name ChatroomScript

## Pure logic for the chatroom (Spec #542): script loading and validation,
## the seeded scrambler, the randomized ambient planner, scripted responders,
## the first-message trigger, fact unlocking, readiness and the model-reply
## gate. Everything here is a static function over plain data, so the unit
## harness exercises it with no scene, no model and no clock.
##
## No lore lives in this file. Every spoken word comes from the four data
## files under frontdoor/data/chatroom/ (or the directory named by
## DECOHERENCE_CHATROOM_DIR): the room script, the briefing facts, the tabled
## readiness values and the contact's persona.

const DEFAULT_DIR := "res://frontdoor/data/chatroom"
const ENV_DIR := "DECOHERENCE_CHATROOM_DIR"

## Internal state names. They are never rendered (Spec #542 D19).
const ST_ROOM := "ROOM"
const ST_BRIEFING := "BRIEFING"
const ST_OFFERED := "ENTRY_OFFERED"

const ACTS := ["none", "offer_entry"]
## The three outcomes of a routed line in the chat client (Spec #562): scripted
## voices, the single model-backed thread, or a client command. Code decides.
const ROUTE_SCRIPTED := "scripted"
const ROUTE_CONTACT := "contact"
const ROUTE_COMMAND := "command"
## Longest scripted room line, in characters (one terminal row with its handle).
const MAX_LINE_CHARS := 80
const HISTORY_MESSAGES := 6
const MAX_RAW_REPLY := 2000
const WINDOW_MS := 60000
const OFFER_INSTRUCTION := "INSTRUCTION: OFFER ENTRY NOW."
## The same three Unicode pools TerminalGrid draws its alien glyphs from (Box
## Drawing, Block Elements, Braille). Copied rather than referenced so this file
## compiles in a headless --script run, where TerminalGrid (which names the
## Signals autoload) cannot.
const POOLS := {
	"box": ["─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "═", "║", "╔", "╗", "╚", "╝", "╬"],
	"block": ["▀", "▄", "█", "▌", "▐", "░", "▒", "▓", "■"],
	"braille": ["⠁", "⠃", "⠉", "⠙", "⠑", "⠋", "⠛", "⠓", "⠊", "⠟", "⠽", "⠺", "⠮", "⠵", "⠫", "⠿"],
}


## --- Loading -----------------------------------------------------------------

static func data_dir() -> String:
	var env := OS.get_environment(ENV_DIR)
	return env if not env.is_empty() else DEFAULT_DIR


static func read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)


## Loads and cross-checks the four data files. {ok, error, script, briefing,
## readiness, persona}. Any problem is a named error, never a partial bundle.
static func load_bundle() -> Dictionary:
	var dir := data_dir()
	var script = read_json(dir + "/room_script.json")
	var briefing = read_json(dir + "/handler_briefing.json")
	var persona = read_json(dir + "/contact_persona.json")
	if typeof(script) != TYPE_DICTIONARY or typeof(briefing) != TYPE_DICTIONARY or typeof(persona) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable_data"}
	var rd := load_readiness(dir + "/readiness.json", briefing)
	if not bool(rd["ok"]):
		return {"ok": false, "error": String(rd["error"])}
	var errors := validate(script, briefing, rd["cfg"])
	if not errors.is_empty():
		return {"ok": false, "error": String(errors[0])}
	if typeof(persona.get("system_prompt", null)) != TYPE_STRING or typeof(persona.get("fallback_say", null)) != TYPE_STRING:
		return {"ok": false, "error": "wrong_type"}
	return {"ok": true, "error": "", "script": script, "briefing": briefing, "readiness": rd["cfg"], "persona": persona}


static func entry_room(script: Dictionary) -> Dictionary:
	return room_by_id(script, String(script.get("entry_room", "__none__")))


## The room with this id, or {} (Spec #562: the script now carries several rooms).
static func room_by_id(script: Dictionary, room_id: String) -> Dictionary:
	var rooms = script.get("rooms", [])
	if typeof(rooms) != TYPE_ARRAY:
		return {}
	for r in rooms:
		if typeof(r) == TYPE_DICTIONARY and String(r.get("id", "")) == room_id:
			return r
	return {}


static func voice_handle(room: Dictionary, voice_id: String) -> String:
	for v in room.get("voices", []):
		if typeof(v) == TYPE_DICTIONARY and String(v.get("id", "")) == voice_id:
			return String(v.get("handle", ""))
	return ""


## --- Validation ----------------------------------------------------------------

## Returns the list of named errors; empty means valid. `briefing` and
## `readiness_cfg` are optional: when both are given the required facts are
## cross-checked against the briefing.
static func validate(script: Variant, briefing: Variant = null, readiness_cfg: Variant = null) -> Array:
	var errs: Array = []
	if typeof(script) != TYPE_DICTIONARY:
		return ["wrong_type"]
	var rooms = script.get("rooms", null)
	if typeof(rooms) != TYPE_ARRAY or rooms.is_empty():
		return ["wrong_type"]
	var entry_found := false
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			errs.append("wrong_type")
			continue
		if String(r.get("id", "")) == String(script.get("entry_room", "__none__")):
			entry_found = true
		_validate_room(r, errs)
	if not entry_found:
		errs.append("missing_entry_room")
	var h = script.get("handler", null)
	if typeof(h) != TYPE_DICTIONARY:
		errs.append("wrong_type")
	else:
		if typeof(h.get("accept_commands", null)) != TYPE_ARRAY or h["accept_commands"].is_empty():
			errs.append("no_accept_command")
		if typeof(h.get("leave_commands", null)) != TYPE_ARRAY or h["leave_commands"].is_empty():
			errs.append("no_leave_command")
		for key in ["degrade_line", "offer_fallback_line", "leave_line"]:
			if typeof(h.get(key, null)) != TYPE_STRING:
				errs.append("wrong_type")
	if typeof(briefing) == TYPE_DICTIONARY and typeof(readiness_cfg) == TYPE_DICTIONARY:
		var ids: Array = []
		for f in briefing.get("facts", []):
			if typeof(f) == TYPE_DICTIONARY:
				ids.append(String(f.get("id", "")))
		for need in readiness_cfg.get("required_facts", []):
			if not ids.has(String(need)):
				errs.append("unknown_required_fact")
	return errs


static func _validate_room(r: Dictionary, errs: Array) -> void:
	var ids: Array = []
	var voices = r.get("voices", null)
	if typeof(voices) != TYPE_ARRAY:
		errs.append("wrong_type")
		voices = []
	for v in voices:
		if typeof(v) == TYPE_DICTIONARY:
			ids.append(String(v.get("id", "")))
	var amb = r.get("ambient", null)
	if typeof(amb) != TYPE_DICTIONARY:
		errs.append("wrong_type")
		return
	var lines = amb.get("lines", null)
	if typeof(lines) != TYPE_ARRAY:
		errs.append("wrong_type")
	elif lines.is_empty():
		errs.append("empty_ambient")
	var iv = amb.get("interval_ms", null)
	if typeof(iv) != TYPE_ARRAY or iv.size() != 2 or int(iv[0]) < 1 or int(iv[0]) > int(iv[1]):
		errs.append("bad_interval")
	else:
		var cap := int(amb.get("max_per_minute", 0))
		if cap < 1 or cap * int(iv[1]) < WINDOW_MS + 1:
			errs.append("rate_cap_infeasible")
	for group in [amb.get("lines", []), r.get("responders", []), r.get("fallback_responses", [])]:
		if typeof(group) != TYPE_ARRAY:
			continue
		for item in group:
			_validate_line(item, ids, errs)
	var trig = r.get("handler_trigger", null)
	if typeof(trig) != TYPE_DICTIONARY or String(trig.get("on", "")) != "first_player_message":
		errs.append("bad_trigger")
	else:
		_validate_line(trig.get("contact_line", null), ids, errs)
		var d = trig.get("contact_delay_ms", null)
		if typeof(d) != TYPE_ARRAY or d.size() != 2 or int(d[0]) < 0 or int(d[0]) > int(d[1]):
			errs.append("bad_interval")


static func _validate_line(item: Variant, voice_ids: Array, errs: Array) -> void:
	if typeof(item) != TYPE_DICTIONARY or typeof(item.get("plain", null)) != TYPE_STRING:
		errs.append("wrong_type")
		return
	if not voice_ids.has(String(item.get("voice", ""))):
		errs.append("unknown_voice")
	if String(item["plain"]).length() > MAX_LINE_CHARS:
		errs.append("oversize_line")


## The tabled readiness file (Spec #542 D6, D15). Must still be marked TABLED,
## must not carry the removed stall knob, and may only name real facts.
static func load_readiness(path: String, briefing: Dictionary) -> Dictionary:
	return check_readiness(read_json(path), briefing)


static func check_readiness(data: Variant, briefing: Dictionary) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "unreadable_data"}
	if String(data.get("status", "")) != "TABLED":
		return {"ok": false, "error": "not_tabled"}
	if data.has("stall_turns"):
		return {"ok": false, "error": "stall_turns"}
	for key in ["min_player_turns", "max_new_facts_per_turn", "offer_grace_turns"]:
		if typeof(data.get(key, null)) not in [TYPE_INT, TYPE_FLOAT]:
			return {"ok": false, "error": "wrong_type"}
	if int(data["max_new_facts_per_turn"]) < 1 or int(data["min_player_turns"]) < 0 or int(data["offer_grace_turns"]) < 0:
		return {"ok": false, "error": "wrong_type"}
	var req = data.get("required_facts", null)
	if typeof(req) != TYPE_ARRAY:
		return {"ok": false, "error": "wrong_type"}
	var ids: Array = []
	for f in briefing.get("facts", []):
		if typeof(f) == TYPE_DICTIONARY:
			ids.append(String(f.get("id", "")))
	for need in req:
		if not ids.has(String(need)):
			return {"ok": false, "error": "unknown_required_fact"}
	return {"ok": true, "error": "", "cfg": data}


## --- Text helpers ---------------------------------------------------------------

## Lower-case ASCII letters and digits; every other character is a separator.
static func normalize(text: String) -> String:
	var out := ""
	var last_space := true
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c >= 65 and c <= 90:
			c += 32
		if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
			out += char(c)
			last_space = false
		elif not last_space:
			out += " "
			last_space = true
	return out.strip_edges()


## True when `kw` starts a word of `text` ("entangle" hits "entanglement").
static func kw_hit(text: String, kw: String) -> bool:
	var k := normalize(kw)
	return not k.is_empty() and (" " + normalize(text)).contains(" " + k)


## Exact command match: ASCII case-folded and whitespace-collapsed, nothing
## else. A Cyrillic or full-width look-alike is a different string and fails.
static func matches_command(commands: Array, text: String) -> bool:
	# Spec #562 D14 (#902): any non-ASCII input is rejected before case folding,
	# because to_lower() folds U+0130 (dotted capital I) to a plain "i".
	for i in range(text.length()):
		if text.unicode_at(i) > 127:
			return false
	var parts := text.strip_edges().to_lower().replace("\t", " ").split(" ", false)
	var flat := " ".join(parts)
	for c in commands:
		if flat == String(c):
			return true
	return false


## --- Scramble -----------------------------------------------------------------------

## Deterministic substitution: every non-space character becomes a glyph from
## the configured pools, consistently within one emission, so the line reads as
## code rather than noise. Length is preserved. `reveal_words` stay legible and
## `legible_ratio` (0..1) lets that share of characters through.
static func scramble(plain: String, seed_value: int, rules: Dictionary) -> String:
	var ratio := clampf(float(rules.get("legible_ratio", 0.0)), 0.0, 1.0)
	if ratio >= 1.0:
		return plain
	var glyphs: Array = []
	for pool_name in rules.get("pools", []):
		glyphs.append_array(POOLS.get(String(pool_name), []))
	if glyphs.is_empty():
		glyphs = POOLS["box"].duplicate()
	var reveal: Array = []
	for w in rules.get("reveal_words", []):
		reveal.append(normalize(String(w)))
	var keep_spaces := bool(rules.get("keep_spaces", true))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var map := {}
	var out := ""
	for word_index in range(plain.split(" ").size()):
		var word: String = plain.split(" ")[word_index]
		if word_index > 0:
			out += " " if keep_spaces else String(glyphs[rng.randi_range(0, glyphs.size() - 1)])
		if reveal.has(normalize(word)) and not normalize(word).is_empty():
			out += word
			continue
		for i in range(word.length()):
			var ch := word[i]
			var keep := rng.randf() < ratio
			if not map.has(ch):
				map[ch] = String(glyphs[rng.randi_range(0, glyphs.size() - 1)])
			out += ch if keep else String(map[ch])
	return out


## --- Ambient planner ---------------------------------------------------------------------

## The first `n` ambient emissions of a session, as a pure function of the seed:
## [{line, voice, plain, interval_ms, scramble_seed}]. Lines come from a
## shuffle bag (no repeat until every line has been used), intervals are
## uniform in the script's range, and a fresh scramble seed is drawn per
## emission. The first emission is immediate (interval 0): the channel was
## already live. The per-minute cap holds by construction: each interval's
## lower bound is raised just enough that any `max_per_minute` consecutive
## emissions span more than a minute, and the cap check always stays
## satisfiable within the range because validate() requires cap * max > 60 s.
static func ambient_plan(script: Dictionary, seed_value: int, n: int, room_id: String = "") -> Array:
	var amb: Dictionary = (room_by_id(script, room_id) if not room_id.is_empty() else entry_room(script)).get("ambient", {})
	var lines: Array = amb.get("lines", [])
	var plan: Array = []
	if lines.is_empty() or n <= 0:
		return plan
	var lo := int(amb["interval_ms"][0])
	var hi := int(amb["interval_ms"][1])
	var cap := int(amb.get("max_per_minute", 24))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var spacings: Array = []
	for i in range(maxi(cap - 1, 0)):
		spacings.append(hi)
	var bag: Array = []
	var last := -1
	for i in range(n):
		if bag.is_empty():
			bag = range(lines.size())
			for j in range(bag.size() - 1, 0, -1):
				var k := rng.randi_range(0, j)
				var tmp = bag[j]
				bag[j] = bag[k]
				bag[k] = tmp
			if bag.size() > 1 and int(bag[0]) == last:
				var swap = bag[0]
				bag[0] = bag[1]
				bag[1] = swap
		var idx := int(bag.pop_front())
		last = idx
		var interval := 0
		if i > 0:
			var span := 0
			for s in spacings:
				span += int(s)
			var floor_ms := mini(maxi(lo, WINDOW_MS + 1 - span), hi)
			interval = rng.randi_range(floor_ms, hi)
			if not spacings.is_empty():
				spacings.append(interval)
				spacings.pop_front()
		plan.append({
			"line": idx,
			"voice": String(lines[idx].get("voice", "")),
			"plain": String(lines[idx].get("plain", "")),
			"interval_ms": interval,
			"scramble_seed": int(rng.randi() & 0x7fffffff),
		})
	return plan


## --- Responders and trigger -------------------------------------------------------------------

## The scripted reply to a player line while the room is all there is:
## {id, voice, plain, fallback}. Cues match whole words or phrases; when none
## matches, the fallbacks rotate by `fallback_index`.
static func respond(script: Dictionary, text: String, fallback_index: int, room_id: String = "") -> Dictionary:
	var room := room_by_id(script, room_id) if not room_id.is_empty() else entry_room(script)
	var padded := " " + normalize(text) + " "
	for r in room.get("responders", []):
		for cue in r.get("match_any", []):
			var c := normalize(String(cue))
			if not c.is_empty() and padded.contains(" " + c + " "):
				return {"id": String(r.get("id", "")), "voice": String(r.get("voice", "")), "plain": String(r.get("plain", "")), "fallback": false}
	var fb: Array = room.get("fallback_responses", [])
	if fb.is_empty():
		return {"id": "", "voice": "", "plain": "", "fallback": true}
	var pick: Dictionary = fb[posmod(fallback_index, fb.size())]
	return {"id": "fallback", "voice": String(pick.get("voice", "")), "plain": String(pick.get("plain", "")), "fallback": true}


## The contact reaches out only after the player's FIRST sent, non-empty
## message, and only once.
static func trigger_fires(trigger: Dictionary, already_fired: bool, text: String) -> bool:
	if already_fired or String(trigger.get("on", "")) != "first_player_message":
		return false
	return not text.strip_edges().is_empty()


## --- Briefing ------------------------------------------------------------------------------------

## Ids of the facts the player's own line unlocks now: file order, not already
## unlocked, at most `max_new_facts_per_turn`. Code never volunteers a fact.
static func facts_for_turn(briefing: Dictionary, cfg: Dictionary, unlocked: Array, player_text: String) -> Array:
	var out: Array = []
	var cap := int(cfg.get("max_new_facts_per_turn", 2))
	if player_text.strip_edges().is_empty():
		return out
	for f in briefing.get("facts", []):
		if out.size() >= cap:
			break
		var fid := String(f.get("id", ""))
		if unlocked.has(fid):
			continue
		for kw in f.get("ask_keywords", []):
			if kw_hit(player_text, String(kw)):
				out.append(fid)
				break
	return out


## Facts newly credited by an accepted reply: unlocked (so present in that
## turn's prompt) and mentioned through one of their say keywords.
static func credit(briefing: Dictionary, unlocked: Array, say: String, credited: Array) -> Array:
	var out: Array = []
	var low := say.to_lower()
	for f in briefing.get("facts", []):
		var fid := String(f.get("id", ""))
		if not unlocked.has(fid) or credited.has(fid) or out.has(fid):
			continue
		for kw in f.get("say_keywords", []):
			if low.contains(String(kw).to_lower()):
				out.append(fid)
				break
	return out


static func readiness(cfg: Dictionary, credited: Array, player_turns: int) -> bool:
	if player_turns < int(cfg.get("min_player_turns", 0)):
		return false
	for need in cfg.get("required_facts", []):
		if not credited.has(String(need)):
			return false
	return true


## --- Prompt and reply gate --------------------------------------------------------------------------

## system (persona + rules + only the unlocked facts [+ the offer instruction])
## + the last HISTORY_MESSAGES turns + the player's line in the user role.
static func build_messages(persona: Dictionary, briefing: Dictionary, unlocked: Array, history: Array, player_text: String, offer_due: bool) -> Array:
	var sys := String(persona.get("system_prompt", "")) + "\n\nRULES:\n"
	for rule in briefing.get("prompt_rules", []):
		sys += "- " + String(rule) + "\n"
	sys += "\nKNOWN FACTS (ground truth, never go beyond them):\n"
	var any := false
	for f in briefing.get("facts", []):
		if unlocked.has(String(f.get("id", ""))):
			sys += "- " + String(f.get("text", "")) + "\n"
			any = true
	if not any:
		sys += "(none)\n"
	if offer_due:
		sys += "\n" + OFFER_INSTRUCTION + " " + String(briefing.get("offer_instruction", "")) + "\n"
	var messages: Array = [{"role": "system", "content": sys}]
	var from := maxi(history.size() - HISTORY_MESSAGES, 0)
	for i in range(from, history.size()):
		messages.append({"role": String(history[i]["role"]), "content": String(history[i]["content"])})
	messages.append({"role": "user", "content": player_text})
	return messages


## Characters / 4: the unit-level token estimate (the live run reads the
## server's own prompt_eval_count).
static func estimate_tokens(messages: Array) -> int:
	var chars := 0
	for m in messages:
		chars += String(m["content"]).length()
	return int(ceil(float(chars) / 4.0))


static func response_schema(max_say: int) -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"say": {"type": "string", "maxLength": max_say},
			"act": {"type": "string", "enum": ACTS},
		},
		"required": ["say", "act"],
		"additionalProperties": false,
	}


## Strict gate for one model reply. {ok, say, act, downgraded, reason}. Any
## deviation (not JSON, extra key, unknown act, over-long say, think marker,
## code fence, reasoning window) is ok=false and the caller prints the
## persona's fallback line instead. An offer before readiness is accepted as
## speech but downgraded to act "none".
static func validate_handler_reply(content: String, is_ready: bool, max_say: int, reasoning: String = "") -> Dictionary:
	var bad := {"ok": false, "say": "", "act": "none", "downgraded": false, "reason": ""}
	if content.length() > MAX_RAW_REPLY:
		bad["reason"] = "oversize"
		return bad
	var parser := JSON.new()
	if parser.parse(content) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		bad["reason"] = "not_json"
		return bad
	var obj: Dictionary = parser.data
	if obj.size() != 2 or not obj.has("say") or not obj.has("act"):
		bad["reason"] = "keys"
		return bad
	if typeof(obj["say"]) != TYPE_STRING or typeof(obj["act"]) != TYPE_STRING:
		bad["reason"] = "types"
		return bad
	if not ACTS.has(String(obj["act"])):
		bad["reason"] = "unknown_act"
		return bad
	if String(obj["say"]).length() > max_say:
		bad["reason"] = "say_too_long"
		return bad
	var cleaned := ReplySanitizer.sanitize(String(obj["say"]), reasoning, max_say)
	if not bool(cleaned["ok"]):
		bad["reason"] = String(cleaned["reason"])
		return bad
	var act := String(obj["act"])
	var downgraded := act == "offer_entry" and not is_ready
	return {"ok": true, "say": String(cleaned["text"]), "act": "none" if downgraded else act, "downgraded": downgraded, "reason": ""}


static func entry_allowed(state: String) -> bool:
	return state == ST_OFFERED
