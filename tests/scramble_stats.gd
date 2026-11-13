extends SceneTree

## Spec #562 A1: measures the scrambled ambient traffic over a seeded sample and
## checks that every glyph the scrambler can draw exists in the chat font.
## Run via tests/verify_scramble_stats.sh (headless, no scene, no model, no GPU).
##
## The sample is SAMPLE_PER_ROOM ambient emissions from every room of the shipped
## room_script.json, planned with a fixed seed, scrambled once with the shipped
## rules ("shaped") and once with the pre-A1 rules (braille, box, block; no shape;
## the old length-preserving scramble()) as the "legacy" baseline.
## Output: one line "SCRAMBLE_STATS <json>" (and the same JSON to $OUT_FILE).

const SEED := 20261112
const SAMPLE_PER_ROOM := 200
const FONT_PATH := "res://assets/fonts/DejaVuSansMono.ttf"
const FONT_SIZE := 16
var _contact: String = ""

var _bundle: Dictionary = {}


func _init() -> void:
	_bundle = ChatroomScript.load_bundle()
	if not bool(_bundle.get("ok", false)):
		print("SCRAMBLE_STATS_FAIL load: %s" % String(_bundle.get("error", "")))
		quit(1)
		return
	# The handler's handle is generated per player: take the one a session would draw.
	var statics: Array = []
	for r in _bundle["script"]["rooms"]:
		for v in r["voices"]:
			if String(v.get("slot", "")) != "handler":
				statics.append(String(v["handle"]))
	_contact = HandlerNames.generate(_bundle["names"], SEED, statics)
	var script: Dictionary = ChatroomScript.with_handler(_bundle["script"], _contact)
	var shaped: Dictionary = script["scramble"]
	var legacy: Dictionary = shaped.duplicate(true)
	legacy.erase("shape")
	legacy["pools"] = ["braille", "box", "block"]

	var lines_new: Array = []
	var lines_old: Array = []
	for room in script["rooms"]:
		var plan := ChatroomScript.ambient_plan(script, SEED, SAMPLE_PER_ROOM, String(room["id"]))
		for e in plan:
			var handle := ChatroomScript.voice_handle(room, String(e["voice"]))
			var plain := String(e["plain"])
			var sd := int(e["scramble_seed"])
			lines_new.append({"handle": handle, "text": ChatroomScript.scramble_line(plain, sd, shaped, handle), "plain": plain, "seed": sd})
			lines_old.append({"handle": handle, "text": ChatroomScript.scramble(plain, sd, legacy), "plain": plain, "seed": sd})

	var out := {
		"seed": SEED,
		"sample": lines_new.size(),
		"shaped": _measure(lines_new, shaped),
		"legacy": _measure(lines_old, legacy),
		"font": _font_check(shaped),
		"reveal": _reveal_check(shaped),
		"determinism": _determinism(script, shaped),
	}
	var text := JSON.stringify(out)
	print("SCRAMBLE_STATS " + text)
	var path := OS.get_environment("OUT_FILE")
	if not path.is_empty():
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
	quit(0)


func _measure(lines: Array, rules: Dictionary) -> Dictionary:
	var lens: Array = []
	var toks: Array = []
	var hist := {}
	var cls := {}
	var distinct_lines := {}
	var leaks := 0
	var multi_class := 0
	var per := {}
	var re := RegEx.new()
	re.compile("[A-Za-z]{3,}")
	var burst := 0
	var longl := 0
	var wraps := 0
	for l in lines:
		var t: String = l["text"]
		lens.append(t.length())
		var tk := t.split(" ", false).size()
		toks.append(tk)
		if tk <= 4:
			burst += 1
		if tk >= 14:
			longl += 1
		if t.length() > 64:
			wraps += 1
		distinct_lines[t] = true
		if re.search(t) != null:
			leaks += 1
		var in_line := {}
		for i in range(t.length()):
			var c := t[i]
			if c == " ":
				continue
			hist[c] = int(hist.get(c, 0)) + 1
			var k := ChatroomScript.glyph_class(c)
			cls[k] = int(cls.get(k, 0)) + 1
			in_line[k] = true
		if in_line.size() >= 2:
			multi_class += 1
		var h: String = l["handle"]
		if not per.has(h):
			per[h] = {"lens": [], "toks": [], "burst": 0, "long": 0, "lead": {}}
		per[h]["lens"].append(t.length())
		per[h]["toks"].append(tk)
		per[h]["burst"] = int(per[h]["burst"]) + (1 if tk <= 4 else 0)
		per[h]["long"] = int(per[h]["long"]) + (1 if tk >= 14 else 0)
		var counts := {}
		for i in range(t.length()):
			if t[i] != " ":
				var kk := ChatroomScript.glyph_class(t[i])
				counts[kk] = int(counts.get(kk, 0)) + 1
		var lead := ""
		var best := -1
		for kk in counts:
			if int(counts[kk]) > best:
				best = int(counts[kk])
				lead = String(kk)
		per[h]["lead"][lead] = int(per[h]["lead"].get(lead, 0)) + 1
	var n := lines.size()
	var per_out := {}
	for h in per:
		var pl: Array = per[h]["lens"]
		per_out[h] = {
			"n": pl.size(),
			"median_len": _pct(pl, 0.5),
			"mean_len": snappedf(_mean(pl), 0.01),
			"burst_share": snappedf(float(per[h]["burst"]) / pl.size(), 0.001),
			"long_share": snappedf(float(per[h]["long"]) / pl.size(), 0.001),
			"lead_class": _top_key(per[h]["lead"]),
		}
	var shares := {}
	var total_glyphs := 0
	for k in cls:
		total_glyphs += int(cls[k])
	for k in cls:
		shares[String(k)] = snappedf(float(cls[k]) / maxf(total_glyphs, 1), 0.001)
	var hist_top: Array = []
	var keys := hist.keys()
	keys.sort_custom(func(a, b): return int(hist[a]) > int(hist[b]))
	for k in keys.slice(0, 12):
		hist_top.append("%s:%d" % [k, hist[k]])
	return {
		"lines": n,
		"distinct_lines": distinct_lines.size(),
		"distinct_glyphs": hist.size(),
		"glyph_classes_used": cls.size(),
		"class_share": shares,
		"top_glyphs": hist_top,
		"len": {"min": _pct(lens, 0.0), "p10": _pct(lens, 0.1), "median": _pct(lens, 0.5), "p90": _pct(lens, 0.9), "max": _pct(lens, 1.0), "stdev": snappedf(_stdev(lens), 0.01), "mean": snappedf(_mean(lens), 0.01)},
		"tokens": {"min": _pct(toks, 0.0), "median": _pct(toks, 0.5), "max": _pct(toks, 1.0), "burst_share": snappedf(float(burst) / n, 0.001), "long_share": snappedf(float(longl) / n, 0.001)},
		"wrap_share": snappedf(float(wraps) / n, 0.001),
		"multi_class_line_share": snappedf(float(multi_class) / n, 0.001),
		"ascii_letter_run_lines": leaks,
		"per_speaker": per_out,
		"speaker_envelope": _envelope(per_out),
	}


## Does the contact's handle sit inside the range the other handles span?
func _envelope(per: Dictionary) -> Dictionary:
	var res := {"handles": per.size(), "contact_present": per.has(_contact)}
	if not per.has(_contact):
		return res
	var metrics := ["mean_len", "burst_share", "long_share"]
	var inside := true
	var spread := {}
	for m in metrics:
		var lo := INF
		var hi := -INF
		for h in per:
			if h == _contact:
				continue
			lo = minf(lo, float(per[h][m]))
			hi = maxf(hi, float(per[h][m]))
		var v := float(per[_contact][m])
		spread[m] = {"others_min": lo, "others_max": hi, "contact": v}
		if v < lo or v > hi:
			inside = false
	var leads := {}
	for h in per:
		if h != _contact:
			leads[per[h]["lead_class"]] = true
	res["contact_inside_others_range"] = inside
	res["contact_lead_class_shared"] = leads.has(per[_contact]["lead_class"])
	res["spread"] = spread
	return res


## Every glyph in every shipped pool: in the font, same advance as a letter.
func _font_check(rules: Dictionary) -> Dictionary:
	var f: Font = load(FONT_PATH)
	var missing: Array = []
	var bad_advance: Array = []
	var blank: Array = []
	var seen := {}
	var ref := f.get_char_size(0x4D, FONT_SIZE).x if f != null else 0.0
	for pool in rules.get("pools", []):
		for g in ChatroomScript.POOLS[String(pool)]:
			var cp := String(g).unicode_at(0)
			seen[String(g)] = true
			if f == null or not f.has_char(cp):
				missing.append(String(g))
			elif absf(f.get_char_size(cp, FONT_SIZE).x - ref) > 0.01:
				bad_advance.append(String(g))
			elif not _has_outline(f, cp):
				blank.append(String(g))
	# control: the pre-A1 braille pool is known to be absent from this font
	var control_missing := 0
	for g in ChatroomScript.POOLS["braille"]:
		if f == null or not f.has_char(String(g).unicode_at(0)):
			control_missing += 1
	# control: a space is in the font and has no outline, so the outline test flags it
	var control_blank := f != null and f.has_char(0x20) and not _has_outline(f, 0x20)
	return {"glyphs_checked": seen.size(), "missing": missing, "bad_advance": bad_advance, "blank": blank, "control_space_flagged_blank": control_blank, "control_braille_missing": control_missing, "font_loaded": f != null}


## True when the font draws something for the codepoint: its outline has points.
func _has_outline(f: Font, cp: int) -> bool:
	var ts := TextServerManager.get_primary_interface()
	var rid: RID = f.get_rids()[0]
	var idx := ts.font_get_glyph_index(rid, FONT_SIZE, cp, 0)
	if idx == 0:
		return false
	var c: Dictionary = ts.font_get_glyph_contours(rid, FONT_SIZE, idx)
	return (c.get("points", PackedVector3Array()) as PackedVector3Array).size() > 0


func _reveal_check(rules: Dictionary) -> Dictionary:
	var with_reveal: Dictionary = rules.duplicate(true)
	with_reveal["reveal_words"] = ["south"]
	var kept := 0
	var leaked_other := 0
	for s in range(1, 41):
		var t := ChatroomScript.scramble_line("relay seven holds the south arc, drift at 0.3", s, with_reveal, "XEN-4")
		if t.contains("south"):
			kept += 1
		if t.contains("relay") or t.contains("holds"):
			leaked_other += 1
	return {"trials": 40, "kept": kept, "leaked_other_words": leaked_other}


func _determinism(script: Dictionary, rules: Dictionary) -> Dictionary:
	var plain := "the translation cache is cold, repeat the last frame"
	var same := 0
	var diff := 0
	var a := ChatroomScript.scramble_line(plain, 7, rules, "XEN-4")
	for i in range(20):
		if ChatroomScript.scramble_line(plain, 7, rules, "XEN-4") == a:
			same += 1
		if ChatroomScript.scramble_line(plain, 100 + i, rules, "XEN-4") != a:
			diff += 1
	return {"repeat_identical": same, "other_seeds_differ": diff, "of": 20}


func _pct(a: Array, q: float) -> int:
	var s := a.duplicate()
	s.sort()
	return int(s[mini(int(q * s.size()), s.size() - 1)])


func _mean(a: Array) -> float:
	var t := 0.0
	for x in a:
		t += float(x)
	return t / maxf(a.size(), 1)


func _stdev(a: Array) -> float:
	var m := _mean(a)
	var v := 0.0
	for x in a:
		v += (float(x) - m) * (float(x) - m)
	return sqrt(v / maxf(a.size(), 1))


func _top_key(d: Dictionary) -> String:
	var best := -1
	var key := ""
	for k in d:
		if int(d[k]) > best:
			best = int(d[k])
			key = String(k)
	return key
