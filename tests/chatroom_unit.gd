extends SceneTree

## Unit tests for the Spec #542 chatroom core (no scene, no model, no GPU).
## Run via tests/verify_chatroom_unit.sh. Output contract (parsed by the DoD):
##   CHATROOM_UNIT_OK <name>        one per passing unit
##   CHATROOM_UNIT_FAIL <name>: <why>   any failure (script exits 1)
##   CHATROOM_NEGCTL_OK <name>      negative controls: the harness DOES catch breakage
##
## Each negative control runs a deliberately broken stub through the SAME check
## function the real code passed, and requires the check to fail.

var _failed: int = 0
var _bundle: Dictionary = {}
var _script: Dictionary = {}
var _briefing: Dictionary = {}
var _funnel_cfg: Dictionary = {}
var _persona: Dictionary = {}
var _rules: Dictionary = {}


func _init() -> void:
	_bundle = ChatroomScript.load_bundle()
	_ok("real_bundle_loads", bool(_bundle.get("ok", false)), String(_bundle.get("error", "")))
	if not bool(_bundle.get("ok", false)):
		quit(1)
		return
	_script = _bundle["script"]
	_briefing = _bundle["briefing"]
	_funnel_cfg = _bundle["funnel"]
	_persona = _bundle["persona"]
	_rules = _script["scramble"]

	_u1_to_u8()
	_u9_to_u11()
	_u12_to_u14()
	_u15_to_u21()
	_u24_to_u29()
	_u30_to_u33()
	_u34_to_u36()
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, why: String = "") -> void:
	if cond:
		print("CHATROOM_UNIT_OK " + name)
	else:
		_failed += 1
		print("CHATROOM_UNIT_FAIL %s: %s" % [name, why])


func _neg(name: String, caught: bool) -> void:
	if caught:
		print("CHATROOM_NEGCTL_OK " + name)
	else:
		_failed += 1
		print("CHATROOM_UNIT_FAIL negctl_%s: the broken stub was NOT caught" % name)


func _copy(d: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(d))


func _room(s: Dictionary) -> Dictionary:
	return ChatroomScript.entry_room(s)


## True when some run of 3+ ASCII letters survives outside the reveal words.
func _has_letter_run(text: String, reveal: Array) -> bool:
	var re := RegEx.new()
	re.compile("[A-Za-z]{3,}")
	for m in re.search_all(text):
		if not reveal.has(m.get_string().to_lower()):
			return true
	return false


## --- U1-U8: the script and its named rejections ------------------------------------

func _u1_to_u8() -> void:
	_ok("draft_script_validates", ChatroomScript.validate(_script, _briefing).is_empty(), str(ChatroomScript.validate(_script, _briefing)))

	var s: Dictionary = _copy(_script)
	s["entry_room"] = "nowhere"
	_ok("rejects_missing_entry_room", ChatroomScript.validate(s).has("missing_entry_room"), "")

	s = _copy(_script)
	_room(s)["ambient"]["lines"][0]["voice"] = "ghost"
	_ok("rejects_unknown_voice", ChatroomScript.validate(s).has("unknown_voice"), "")

	s = _copy(_script)
	_room(s)["ambient"]["lines"] = []
	_ok("rejects_empty_ambient", ChatroomScript.validate(s).has("empty_ambient"), "")

	s = _copy(_script)
	for v in _room(s)["voices"]:
		v.erase("slot")
	_ok("rejects_no_handler_slot", ChatroomScript.validate(s).has("no_handler_slot"), "")

	s = _copy(_script)
	_room(s)["voices"][0]["side"] = "neutral"
	_ok("rejects_voice_without_a_known_side", ChatroomScript.validate(s).has("bad_side"), "")

	s = _copy(_script)
	s["handler"]["leave_commands"] = []
	_ok("rejects_no_leave_command", ChatroomScript.validate(s).has("no_leave_command"), "")

	s = _copy(_script)
	_room(s)["ambient"]["lines"][0]["plain"] = "x".repeat(ChatroomScript.MAX_LINE_CHARS + 1)
	_ok("rejects_oversize_line", ChatroomScript.validate(s).has("oversize_line"), "")

	s = _copy(_script)
	s["rooms"] = "not an array"
	_ok("rejects_wrong_type", ChatroomScript.validate(s).has("wrong_type"), "")

	# Negative control: a script missing a required key must fail validation.
	s = _copy(_script)
	s.erase("entry_room")
	_neg("validator_catches_missing_required_key", not ChatroomScript.validate(s).is_empty())


## --- U9-U11: scramble ------------------------------------------------------------------------

func _u9_to_u11() -> void:
	var plain := "relay seven holds the south arc, drift at 0.3"
	var a := ChatroomScript.scramble(plain, 7, _rules)
	var b := ChatroomScript.scramble(plain, 7, _rules)
	var spaces_ok := true
	for i in range(plain.length()):
		if (plain[i] == " ") != (a[i] == " "):
			spaces_ok = false
	_ok("scramble_deterministic_keeps_length_and_spaces", a == b and a.length() == plain.length() and spaces_ok, a)
	var differing := 0
	for seed_value in range(1, 21):
		if ChatroomScript.scramble(plain, seed_value, _rules) != a:
			differing += 1
	_ok("scramble_differs_across_seeds", differing >= 19, "only %d of 20 seeds differed" % differing)
	var leaks := 0
	for seed_value in range(200):
		for ambient_line in _room(_script)["ambient"]["lines"]:
			if _has_letter_run(ChatroomScript.scramble(String(ambient_line["plain"]), seed_value, _rules), []):
				leaks += 1
	_ok("scramble_leaves_no_ascii_letter_run", leaks == 0, "%d leaking emissions" % leaks)
	var with_reveal: Dictionary = _copy(_rules)
	with_reveal["reveal_words"] = ["south"]
	var revealed := ChatroomScript.scramble(plain, 7, with_reveal)
	_ok("scramble_reveal_word_stays_legible", revealed.contains("south") and not revealed.contains("relay"), revealed)
	# Negative control: identity rules (legible_ratio 1) are flagged by the leak detector.
	var identity: Dictionary = _copy(_rules)
	identity["legible_ratio"] = 1.0
	_neg("identity_scramble_flagged_as_leaking", _has_letter_run(ChatroomScript.scramble(plain, 7, identity), []))
	_ok("scramble_ratio_one_equals_plain", ChatroomScript.scramble(plain, 3, identity) == plain, "")

	# Spec #562 A1: the shaped scramble (variable length, wider alphabet, per-speaker lean).
	var sa := ChatroomScript.scramble_line(plain, 7, _rules, "XEN-4")
	_ok("shaped_scramble_deterministic", sa == ChatroomScript.scramble_line(plain, 7, _rules, "XEN-4") and not sa.is_empty(), sa)
	var shaped_lens := {}
	var shaped_leaks := 0
	for seed_value in range(1, 121):
		var t := ChatroomScript.scramble_line(plain, seed_value, _rules, "OBL-17")
		shaped_lens[t.length()] = true
		if _has_letter_run(t, []):
			shaped_leaks += 1
	_ok("shaped_scramble_varies_length_without_letters", shaped_lens.size() >= 20 and shaped_leaks == 0, "%d lengths, %d leaks" % [shaped_lens.size(), shaped_leaks])
	var shaped_reveal := ChatroomScript.scramble_line(plain, 7, with_reveal, "XEN-4")
	_ok("shaped_scramble_reveal_word_stays_legible", shaped_reveal.contains("south") and not shaped_reveal.contains("relay"), shaped_reveal)
	var no_shape: Dictionary = _copy(_rules)
	no_shape.erase("shape")
	_ok("shaped_scramble_without_shape_is_legacy", ChatroomScript.scramble_line(plain, 7, no_shape, "XEN-4") == ChatroomScript.scramble(plain, 7, no_shape), "")
	_neg("shaped_scramble_identity_flagged_as_leaking", _has_letter_run(ChatroomScript.scramble_line(plain, 7, identity, "XEN-4"), []))


## --- U12-U14: responders ----------------------------------------------------------------------

func _u12_to_u14() -> void:
	var r := ChatroomScript.respond(_script, "hello anyone there?", 0)
	_ok("responder_cue_match", not bool(r["fallback"]) and String(r["id"]) == "r_hello", str(r))
	var up := ChatroomScript.respond(_script, "WHO are you", 0)
	_ok("responder_case_insensitive", String(up["id"]) == "r_who", str(up))
	var whole := ChatroomScript.respond(_script, "this is fine", 0)
	_ok("responder_cue_is_whole_word", bool(whole["fallback"]), str(whole))
	var f0 := ChatroomScript.respond(_script, "zzz", 0)
	var f1 := ChatroomScript.respond(_script, "zzz", 1)
	var f0_again := ChatroomScript.respond(_script, "zzz", 0)
	var n: int = _room(_script)["fallback_responses"].size()
	var wrap := ChatroomScript.respond(_script, "zzz", n)
	_ok("fallback_rotation_deterministic", f0 == f0_again and f0 != f1 and wrap == f0, "")


## --- U15-U21: the funnel's model prompt ------------------------------------------------------------

func _prompt_blob(msgs: Array) -> String:
	var blob := ""
	for m in msgs:
		blob += String(m["content"]) + "\n"
	return blob


func _later_fact_text_in_prompt(builder: Callable, stage_index: int) -> int:
	var ids: Array = Funnel.stage_ids(_funnel_cfg)
	var facts: Array = builder.call(_briefing, ids, stage_index)
	var blob := _prompt_blob(ChatroomScript.build_funnel_messages(_persona, _briefing, facts, {}, "KIRN-17", [], "hello", 6))
	var hits := 0
	for f in _briefing["facts"]:
		if ids.find(String(f["from_stage"])) > stage_index and blob.contains(String(f["text"])):
			hits += 1
	return hits


func _u15_to_u21() -> void:
	var ids: Array = Funnel.stage_ids(_funnel_cfg)
	var at_contact := ChatroomScript.facts_available(_briefing, ids, ids.find("contact"))
	var at_launch := ChatroomScript.facts_available(_briefing, ids, ids.find("launch"))
	_ok("facts_available_follow_the_stage", at_contact.size() >= 1 and at_contact.size() < at_launch.size() and at_launch.size() == _briefing["facts"].size(), "%d %d" % [at_contact.size(), at_launch.size()])
	_ok("later_fact_text_absent_from_prompt", _later_fact_text_in_prompt(Callable(ChatroomScript, "facts_available"), ids.find("contact")) == 0 and _later_fact_text_in_prompt(Callable(ChatroomScript, "facts_available"), ids.find("pushback")) == 0, "")
	# Negative control: a builder that hands over every fact is caught.
	var everything := func(briefing: Dictionary, _ids: Array, _stage: int) -> Array:
		return briefing["facts"]
	_neg("prompt_builder_injecting_later_facts", _later_fact_text_in_prompt(everything, ids.find("contact")) > 0)
	var msgs := ChatroomScript.build_funnel_messages(_persona, _briefing, at_contact, {"origin": "the north coast", "doing": ""}, "KIRN-17", [], "hello", 6)
	var blob := _prompt_blob(msgs)
	_ok("prompt_carries_the_operational_note_only_when_filled", blob.contains("origin: the north coast") and not blob.contains("doing:"), "")
	var bare := _prompt_blob(ChatroomScript.build_funnel_messages(_persona, _briefing, at_contact, {}, "KIRN-17", [], "hello", 6))
	_ok("prompt_without_dossier_has_no_note_heading", not bare.contains("YOUR NOTE ON THEM"), "")
	_ok("prompt_names_the_handler_and_lists_fact_ids", blob.contains("KIRN-17") and blob.contains("(f_channel)"), "")
	var history: Array = []
	for i in range(12):
		history.append({"role": "user" if i % 2 == 0 else "assistant", "content": "x".repeat(200 if i % 2 == 0 else 240)})
	var full := ChatroomScript.build_funnel_messages(_persona, _briefing, at_launch, {"origin": "x".repeat(60), "doing": "y".repeat(60)}, "KIRN-17", history, "y".repeat(200), 6)
	var tokens := ChatroomScript.estimate_tokens(full)
	_ok("prompt_estimate_within_budget_all_facts", tokens <= 1100 and full.size() == 2 + 6, "%d tokens, %d messages" % [tokens, full.size()])
	var fat: Array = history.duplicate()
	for i in range(40):
		fat.append({"role": "user", "content": "z".repeat(240)})
	var fat_msgs := ChatroomScript.build_funnel_messages(_persona, _briefing, at_launch, {}, "KIRN-17", fat, "q".repeat(5000), 40)
	_neg("oversize_prompt_flagged", ChatroomScript.estimate_tokens(fat_msgs) > 1100)


## --- U24-U29: entry, command matching, the handler slot --------------------------------------------------

func _accept_cases(fn: Callable) -> bool:
	var cmds: Array = ["enter", "accept", "i accept"]
	var exact: bool = fn.call(cmds, "enter") and fn.call(cmds, "  ACCEPT ") and fn.call(cmds, "i   accept")
	var cyrillic: bool = fn.call(cmds, "\u0435nter")
	var wide: bool = fn.call(cmds, "\uff45\uff4e\uff54\uff45\uff52")
	return exact and not cyrillic and not wide


func _dotted_cases(fn: Callable) -> bool:
	var cmds: Array = ["enter", "accept", "i accept"]
	return fn.call(cmds, "I ACCEPT") and not fn.call(cmds, "\u0130 accept") and not fn.call(["leave"], "l\u0435ave")


func _u24_to_u29() -> void:
	_ok("entry_allowed_only_at_launch", ChatroomScript.entry_allowed(ChatroomScript.ST_LAUNCH) and not ChatroomScript.entry_allowed(ChatroomScript.ST_ROOM) and not ChatroomScript.entry_allowed(ChatroomScript.ST_ENGAGED) and not ChatroomScript.entry_allowed(""), "")
	_ok("lookalike_command_rejected", _accept_cases(Callable(ChatroomScript, "matches_command")), "")
	# Negative control: a matcher that folds Unicode is caught.
	var folding := func(commands: Array, text: String) -> bool:
		var folded := text.replace("\u0435", "e").to_lower()
		for c in commands:
			if folded.strip_edges() == String(c):
				return true
		return false
	_neg("command_stub_folding_unicode", not _accept_cases(folding))

	# Spec #562 D14 (#902): any non-ASCII input is rejected before case folding, and
	# punctuation never counts as part of a command.
	var acc: Array = ["enter", "accept", "i accept"]
	_ok("matches_command_nonascii_rejected", _dotted_cases(Callable(ChatroomScript, "matches_command")), "")
	_ok("matches_command_punctuation_pinned", not ChatroomScript.matches_command(acc, "accept.") and not ChatroomScript.matches_command(acc, "enter!") and not ChatroomScript.matches_command(acc, "i, accept") and ChatroomScript.matches_command(acc, "accept"), "")
	# Negative control: the matcher as it was (engine lower-casing only) is caught.
	var plain_fold := func(commands: Array, text: String) -> bool:
		var parts := text.strip_edges().to_lower().replace("\t", " ").split(" ", false)
		var flat := " ".join(parts)
		for c in commands:
			if flat == String(c):
				return true
		return false
	_neg("matches_command_folding_stub_caught", not _dotted_cases(plain_fold))

	var filled := ChatroomScript.with_handler(_script, "KIRN-17")
	var slot_ok := true
	for r in filled["rooms"]:
		slot_ok = slot_ok and String(ChatroomScript.slot_voice(r).get("handle", "")) == "KIRN-17"
	_ok("with_handler_fills_every_room_and_keeps_the_original", slot_ok and String(ChatroomScript.slot_voice(_room(_script)).get("handle", "")) == "{HANDLER}", "")
	_ok("leave_words_still_match", ChatroomScript.matches_command(_script["handler"]["leave_commands"], "Quit") and ChatroomScript.matches_command(_script["handler"]["leave_commands"], "/exit") and not ChatroomScript.matches_command(_script["handler"]["leave_commands"], "quit now"), "")


## --- U30-U33: the randomized planner -----------------------------------------------------------------------

func _u30_to_u33() -> void:
	var a := ChatroomScript.ambient_plan(_script, 4242, 60)
	var b := ChatroomScript.ambient_plan(_script, 4242, 60)
	_ok("plan_same_seed_identical", a == b and a.size() == 60, "")
	var c := ChatroomScript.ambient_plan(_script, 4243, 60)
	_ok("plan_other_seed_differs", a != c, "")
	var prefix := ChatroomScript.ambient_plan(_script, 4242, 20)
	_ok("plan_is_prefix_stable", prefix == a.slice(0, 20), "")

	var lines: int = _room(_script)["ambient"]["lines"].size()
	var seen: Array = []
	var repeat_inside_bag := false
	for i in range(lines):
		var idx: int = int(a[i]["line"])
		if seen.has(idx):
			repeat_inside_bag = true
		seen.append(idx)
	_ok("no_repeat_before_bag_exhausted", not repeat_inside_bag and seen.size() == lines, "")

	var amb: Dictionary = _room(_script)["ambient"]
	var lo: int = int(amb["interval_ms"][0])
	var hi: int = int(amb["interval_ms"][1])
	var cap: int = int(amb["max_per_minute"])
	var worst_window := 0
	var in_range := true
	for seed_value in range(1, 31):
		var plan := ChatroomScript.ambient_plan(_script, seed_value, 300)
		var times: Array = []
		var t := 0
		for i in range(plan.size()):
			var iv: int = int(plan[i]["interval_ms"])
			if i > 0 and (iv < lo or iv > hi):
				in_range = false
			t += iv
			times.append(t)
		var left := 0
		for right in range(times.size()):
			while int(times[right]) - int(times[left]) >= ChatroomScript.WINDOW_MS:
				left += 1
			worst_window = maxi(worst_window, right - left + 1)
	_ok("intervals_inside_range_and_under_per_minute_cap", in_range and worst_window <= cap, "range=%s worst_window=%d cap=%d" % [in_range, worst_window, cap])
	var distinct: Array = []
	for i in range(1, 30):
		if not distinct.has(int(a[i]["interval_ms"])):
			distinct.append(int(a[i]["interval_ms"]))
	_ok("plan_intervals_vary", distinct.size() >= 10, "%d distinct" % distinct.size())


## --- U34-U36: the bundle ---------------------------------------------------------------------------------

func _u34_to_u36() -> void:
	_ok("bundle_carries_the_funnel_files", _bundle.has("funnel") and _bundle.has("beats") and _bundle.has("names") and not _bundle.has("readiness"), "")
	_ok("bundle_funnel_is_enabled_with_nine_stages", bool(_funnel_cfg.get("enabled", false)) and Funnel.stage_ids(_funnel_cfg).size() == 9, "")
	var bad_brief: Dictionary = _copy(_briefing)
	bad_brief["facts"][0].erase("from_stage")
	_ok("rejects_a_fact_with_no_stage", ChatroomScript.validate(_script, bad_brief).has("wrong_type"), "")
	_neg("validator_catches_a_fact_with_no_stage", not ChatroomScript.validate(_script, bad_brief).is_empty())
	var beats = ChatroomScript.read_json(ChatroomScript.data_dir() + "/funnel_beats.json")
	_ok("beats_file_is_marked_draft", typeof(beats) == TYPE_DICTIONARY and bool(beats.get("draft", false)), "")
