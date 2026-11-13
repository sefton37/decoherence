extends RefCounted
class_name ChatroomScript

## Pure logic for the chatroom (Spec #542, reworked by Spec #573): script
## loading and validation, the seeded scrambler, the randomized ambient planner,
## scripted responders and the funnel's model prompt. Everything here is a static
## function over plain data, so the unit harness exercises it with no scene, no
## model and no clock.
##
## No lore lives in this file. Every spoken word comes from the data files under
## frontdoor/data/chatroom/ (or the directory named by DECOHERENCE_CHATROOM_DIR):
## the room script, the briefing facts, the persona, and the funnel's mechanics,
## beats and name parts.

const DEFAULT_DIR := "res://frontdoor/data/chatroom"
const ENV_DIR := "DECOHERENCE_CHATROOM_DIR"

## Internal state names. They are never rendered (Spec #542 D19).
const ST_ROOM := "ROOM"
const ST_ENGAGED := "ENGAGED"
const ST_LAUNCH := "LAUNCH"

## The three outcomes of a routed line in the chat client (Spec #562): scripted
## voices, the single model-backed thread, or a client command. Code decides.
const ROUTE_SCRIPTED := "scripted"
const ROUTE_CONTACT := "contact"
const ROUTE_COMMAND := "command"
## Longest scripted room line, in characters (one terminal row with its handle).
const MAX_LINE_CHARS := 80
const WINDOW_MS := 60000
## The same three Unicode pools TerminalGrid draws its alien glyphs from (Box
## Drawing, Block Elements, Braille). Copied rather than referenced so this file
## compiles in a headless --script run, where TerminalGrid (which names the
## Signals autoload) cannot.
const POOLS := {
	"box": ["─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "═", "║", "╔", "╗", "╚", "╝", "╬"],
	"block": ["▀", "▄", "█", "▌", "▐", "░", "▒", "▓", "■"],
	"braille": ["⠁", "⠃", "⠉", "⠙", "⠑", "⠋", "⠛", "⠓", "⠊", "⠟", "⠽", "⠺", "⠮", "⠵", "⠫", "⠿"],
	# Spec #562 A1: wider alphabet, every glyph present in the chat font
	# (DejaVuSansMono, advance equal to a letter's; tests/scramble_stats.gd checks
	# it). The braille pool above is NOT in that font and is left out of the shipped
	# rules. No ASCII letters in any class, so the leak detectors stay meaningful.
	"box_heavy": ["╭", "╮", "╯", "╰", "┏", "┓", "┗", "┛", "━", "┃", "╠", "╣", "╦", "╩", "╟", "╢", "╤", "╧", "╪", "╫", "╒", "╓", "╕", "╖", "╘", "╙", "╛", "╜", "┠", "┨", "┯", "┷", "┿", "╂", "╋"],
	"block_fine": ["▁", "▂", "▃", "▅", "▆", "▇", "▉", "▊", "▋", "▍", "▎", "▏", "▖", "▗", "▘", "▙", "▚", "▛", "▜", "▝", "▞", "▟", "◼", "▪", "▫", "▬", "▮"],
	"punct": [",", ".", "!", "#", "$", "%", "&", "*", "+", "/", ":", ";", "<", "=", ">", "?", "@", "\\", "^", "~", "|"],
	"symbol": ["¤", "§", "¶", "†", "‡", "•", "◊", "○", "●", "◦", "¬", "±", "×", "÷", "∞", "∂", "∑", "∆", "∇", "√", "∫", "≈", "≠", "≡", "≤", "≥", "◆", "◇", "□", "▲", "▼", "◄", "►", "⌐", "⌂", "∩", "∪", "∈", "∅", "∴", "⊕", "⊗"],
	"digit": ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
	"letterlike": ["λ", "ξ", "ψ", "ω", "Σ", "Δ", "Ω", "Π", "Φ", "Ψ", "θ", "μ", "π", "φ", "γ", "δ", "ζ"],
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


## Loads and cross-checks the data files. {ok, error, script, briefing, persona,
## funnel, beats, names}. Any problem is a named error, never a partial bundle.
static func load_bundle() -> Dictionary:
	var dir := data_dir()
	var script = read_json(dir + "/room_script.json")
	var briefing = read_json(dir + "/handler_briefing.json")
	var persona = read_json(dir + "/contact_persona.json")
	var funnel = read_json(dir + "/funnel.json")
	var beats = read_json(dir + "/funnel_beats.json")
	var names = read_json(dir + "/funnel_names.json")
	for d in [script, briefing, persona, funnel, beats, names]:
		if typeof(d) != TYPE_DICTIONARY:
			return {"ok": false, "error": "unreadable_data"}
	var errors := validate(script, briefing)
	if not errors.is_empty():
		return {"ok": false, "error": String(errors[0])}
	if typeof(persona.get("system_prompt", null)) != TYPE_STRING or typeof(persona.get("fallback_say", null)) != TYPE_STRING:
		return {"ok": false, "error": "wrong_type"}
	if typeof(funnel.get("stages", null)) != TYPE_ARRAY or typeof(beats.get("beats", null)) != TYPE_ARRAY or typeof(names.get("onsets", null)) != TYPE_ARRAY:
		return {"ok": false, "error": "wrong_type"}
	return {"ok": true, "error": "", "script": script, "briefing": briefing, "persona": persona, "funnel": funnel, "beats": beats["beats"], "names": names}


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

## Returns the list of named errors; empty means valid. `briefing` is optional:
## when given, every fact must name a stage the funnel has.
static func validate(script: Variant, briefing: Variant = null) -> Array:
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
		if typeof(h.get("leave_commands", null)) != TYPE_ARRAY or h["leave_commands"].is_empty():
			errs.append("no_leave_command")
		for key in ["degrade_line", "leave_line"]:
			if typeof(h.get(key, null)) != TYPE_STRING:
				errs.append("wrong_type")
	if typeof(briefing) == TYPE_DICTIONARY:
		for f in briefing.get("facts", []):
			if typeof(f) != TYPE_DICTIONARY or typeof(f.get("id", null)) != TYPE_STRING or typeof(f.get("from_stage", null)) != TYPE_STRING:
				errs.append("wrong_type")
	return errs


static func _validate_room(r: Dictionary, errs: Array) -> void:
	var ids: Array = []
	var voices = r.get("voices", null)
	if typeof(voices) != TYPE_ARRAY:
		errs.append("wrong_type")
		voices = []
	var slots := 0
	for v in voices:
		if typeof(v) == TYPE_DICTIONARY:
			ids.append(String(v.get("id", "")))
			if String(v.get("slot", "")) == "handler":
				slots += 1
			if not ["empire", "faction"].has(String(v.get("side", ""))):
				errs.append("bad_side")
	if slots != 1:
		errs.append("no_handler_slot")
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


static func _validate_line(item: Variant, voice_ids: Array, errs: Array) -> void:
	if typeof(item) != TYPE_DICTIONARY or typeof(item.get("plain", null)) != TYPE_STRING:
		errs.append("wrong_type")
		return
	if not voice_ids.has(String(item.get("voice", ""))):
		errs.append("unknown_voice")
	if String(item["plain"]).length() > MAX_LINE_CHARS:
		errs.append("oversize_line")


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


## Spec #562 A1: the shaped scramble used for every scrambled voice row (ambient,
## scripted replies, direct-message replies). Unlike scramble() it does NOT keep
## the plain line's length: the plain only seeds the alphabet of the code. Per
## emission it draws a length class (a very short burst, a mid line or a long
## multi-clause line), a token-length range, one to three glyph classes, and a
## class for each token. `speaker` bends the draw (see speaker_profile) the same
## way for every handle. All knobs live in rules["shape"] (room_script.json); a
## rules dictionary without "shape", or with legible_ratio > 0, falls back to
## scramble(). reveal_words stay legible, one token each, and are never cut.
static func scramble_line(plain: String, seed_value: int, rules: Dictionary, speaker: String = "") -> String:
	var shape = rules.get("shape", null)
	if typeof(shape) != TYPE_DICTIONARY or float(rules.get("legible_ratio", 0.0)) > 0.0:
		return scramble(plain, seed_value, rules)
	var classes: Array = []
	for pool_name in rules.get("pools", []):
		if POOLS.has(String(pool_name)):
			classes.append(String(pool_name))
	if classes.is_empty():
		return scramble(plain, seed_value, rules)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var prof := speaker_profile(speaker, rules)
	# length class, leaned by the speaker
	var lens: Array = shape.get("length_classes", [])
	var weights: Array = []
	for c in lens:
		weights.append(maxf(float(c.get("weight", 1.0)) * maxf(1.0 + float(prof["bias"]) * float(c.get("lean", 0.0)), 0.05), 0.0))
	var pick: Dictionary = lens[_weighted(rng, weights)] if not lens.is_empty() else {"tokens": [5, 10]}
	var tok_n := rng.randi_range(int(pick["tokens"][0]), int(pick["tokens"][1]))
	# token-length range: the speaker's habit most of the time
	var ranges: Array = shape.get("token_len_ranges", [[2, 7]])
	var rng_i := int(prof["range"]) % ranges.size() if rng.randf() < float(shape.get("speaker", {}).get("habit_share", 0.6)) else rng.randi_range(0, ranges.size() - 1)
	var tl_lo := int(ranges[rng_i][0])
	var tl_hi := int(ranges[rng_i][1])
	# glyph classes of this message
	var cw: Array = []
	for name in classes:
		var w := float(shape.get("class_weights", {}).get(name, 1.0))
		if name == String(prof["primary"]):
			w *= float(shape.get("speaker", {}).get("affinity_boost", 1.0))
		cw.append(w)
	var count_w: Array = shape.get("class_count_weights", [1.0])
	var k := mini(_weighted(rng, count_w) + 1, classes.size())
	var chosen: Array = []
	for i in range(k):
		var at := _weighted(rng, cw)
		chosen.append(classes[at])
		cw[at] = 0.0
		if _sum(cw) <= 0.0:
			break
	# the plain line supplies the source characters and the reveal words
	var reveal: Array = []
	for w in rules.get("reveal_words", []):
		reveal.append(normalize(String(w)))
	var words: PackedStringArray = plain.split(" ", false)
	var alphabet: Array = []
	var reveals: Array = []
	for wi in range(words.size()):
		var word: String = words[wi]
		if reveal.has(normalize(word)) and not normalize(word).is_empty():
			reveals.append([wi, word])
			continue
		for i in range(word.length()):
			if not alphabet.has(word[i]):
				alphabet.append(word[i])
	if alphabet.is_empty():
		alphabet.append("x")
	tok_n = maxi(tok_n, reveals.size())
	var slots: Array = []
	slots.resize(tok_n)
	for rv in reveals:
		var p := mini(int(float(rv[0]) / float(maxi(words.size(), 1)) * tok_n), tok_n - 1)
		while slots[p] != null:
			p = (p + 1) % tok_n
		slots[p] = String(rv[1])
	var stick := float(shape.get("lead_class_share", 0.7))
	var map := {}
	var clause_toks: Array = shape.get("clause_tokens", [3, 7])
	var marks: Array = shape.get("clause_marks", [","])
	var mark := String(marks[rng.randi_range(0, marks.size() - 1)])
	var multi_clause := tok_n > int(clause_toks[1])
	var next_mark := rng.randi_range(int(clause_toks[0]), int(clause_toks[1]))
	var out_tokens: Array = []
	for t in range(tok_n):
		if slots[t] != null:
			out_tokens.append(String(slots[t]))
			continue
		var cls := String(chosen[0]) if rng.randf() < stick else String(chosen[rng.randi_range(0, chosen.size() - 1)])
		var pool: Array = POOLS[cls]
		var tok := ""
		for i in range(rng.randi_range(tl_lo, tl_hi)):
			var ch := String(alphabet[rng.randi_range(0, alphabet.size() - 1)])
			var key := ch + "|" + cls
			if not map.has(key):
				map[key] = String(pool[rng.randi_range(0, pool.size() - 1)])
			tok += String(map[key])
		if multi_clause and t + 1 == next_mark and t + 1 < tok_n:
			tok += mark
			next_mark += rng.randi_range(int(clause_toks[0]), int(clause_toks[1]))
		out_tokens.append(tok)
	var max_chars := int(shape.get("max_chars", 200))
	var out := " ".join(PackedStringArray(out_tokens))
	while out.length() > max_chars and out_tokens.size() > 1 and not reveal.has(normalize(String(out_tokens[-1]))):
		out_tokens.pop_back()
		out = " ".join(PackedStringArray(out_tokens))
	return out


## A speaker's tendencies, a pure function of the handle and the rules: `bias`
## (-spread..spread, leans bursts against long lines), `range` (index of the
## token-length range they favour) and `primary` (the glyph class they favour).
## Every handle goes through the same function; nobody has a hand-set profile.
static func speaker_profile(speaker: String, rules: Dictionary) -> Dictionary:
	var shape: Dictionary = rules.get("shape", {})
	var sp: Dictionary = shape.get("speaker", {})
	if speaker.is_empty():
		return {"bias": 0.0, "range": 0, "primary": ""}
	var h := (String(sp.get("salt", "")) + speaker).hash()
	var u := float(h & 0xffff) / 65535.0
	var classes: Array = rules.get("pools", [])
	return {
		"bias": (u * 2.0 - 1.0) * float(sp.get("length_bias_spread", 0.0)),
		"range": (h >> 16) & 0xff,
		"primary": String(classes[((h >> 24) & 0xff) % classes.size()]) if not classes.is_empty() else "",
	}


static func _weighted(rng: RandomNumberGenerator, weights: Array) -> int:
	var total := _sum(weights)
	if total <= 0.0:
		return 0
	var r := rng.randf() * total
	for i in range(weights.size()):
		r -= float(weights[i])
		if r < 0.0:
			return i
	return weights.size() - 1


static func _sum(a: Array) -> float:
	var t := 0.0
	for x in a:
		t += float(x)
	return t


## The pool name a glyph belongs to (first match), "" when it is in none.
static func glyph_class(ch: String) -> String:
	for name in POOLS:
		if (POOLS[name] as Array).has(ch):
			return String(name)
	return ""


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


## --- The funnel's model prompt ---------------------------------------------------------------------

## The briefing facts whose stage has been reached (file order).
static func facts_available(briefing: Dictionary, stage_ids: Array, stage_index: int) -> Array:
	var out: Array = []
	for f in briefing.get("facts", []):
		var at := stage_ids.find(String(f.get("from_stage", "")))
		if at >= 0 and at <= stage_index:
			out.append(f)
	return out


## system (persona + rules + only the facts available at this stage + the
## operational note) + the last `history_turns` messages + the player's line.
## `dossier` is {field: value} and only ever appears as the operational note.
static func build_funnel_messages(persona: Dictionary, briefing: Dictionary, facts: Array, dossier: Dictionary, handler_name: String, history: Array, player_text: String, history_turns: int) -> Array:
	var sys := String(persona.get("system_prompt", "")) + "\n\nYour name on this channel is " + handler_name + ".\n\nRULES:\n"
	for rule in briefing.get("prompt_rules", []):
		sys += "- " + String(rule) + "\n"
	sys += "\nKNOWN FACTS (ground truth, never go beyond them):\n"
	if facts.is_empty():
		sys += "(none)\n"
	for f in facts:
		sys += "- (%s) %s\n" % [String(f.get("id", "")), String(f.get("text", ""))]
	var note := ""
	for k in dossier:
		if not String(dossier[k]).is_empty():
			note += "- %s: %s\n" % [String(k), String(dossier[k])]
	if not note.is_empty():
		sys += "\nYOUR NOTE ON THEM (what they told you):\n" + note
	var messages: Array = [{"role": "system", "content": sys}]
	var from := maxi(history.size() - history_turns, 0)
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


## A copy of the script with the handler slot's handle filled in.
static func with_handler(script: Dictionary, handler_name: String) -> Dictionary:
	var out: Dictionary = script.duplicate(true)
	for r in out.get("rooms", []):
		for v in r.get("voices", []):
			if String(v.get("slot", "")) == "handler":
				v["handle"] = handler_name
	return out


## The handle of the slot voice in a room, "" when the room has none.
static func slot_voice(room: Dictionary) -> Dictionary:
	for v in room.get("voices", []):
		if typeof(v) == TYPE_DICTIONARY and String(v.get("slot", "")) == "handler":
			return v
	return {}


static func entry_allowed(state: String) -> bool:
	return state == ST_LAUNCH
