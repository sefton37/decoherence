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
var _cfg: Dictionary = {}
var _persona: Dictionary = {}
var _rules: Dictionary = {}

const LAZY := ["ok", "hmm", "interesting", "go on", "right", "and then", "uh huh", "sure", "continue", "yes", "no", "maybe", "alright", "fine", "noted", "okay then", "hello again", "thanks", "cool", "nice"]


func _init() -> void:
	_bundle = ChatroomScript.load_bundle()
	_ok("real_bundle_loads", bool(_bundle.get("ok", false)), String(_bundle.get("error", "")))
	if not bool(_bundle.get("ok", false)):
		quit(1)
		return
	_script = _bundle["script"]
	_briefing = _bundle["briefing"]
	_cfg = _bundle["readiness"]
	_persona = _bundle["persona"]
	_rules = _script["scramble"]

	_u1_to_u8()
	_u9_to_u11()
	_u12_to_u14()
	_u15_to_u17()
	_u18_to_u21()
	_u22_to_u23_and_negctl()
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
	_ok("draft_script_validates", ChatroomScript.validate(_script, _briefing, _cfg).is_empty(), str(ChatroomScript.validate(_script, _briefing, _cfg)))

	var s: Dictionary = _copy(_script)
	s["entry_room"] = "nowhere"
	_ok("rejects_missing_entry_room", ChatroomScript.validate(s).has("missing_entry_room"), "")

	s = _copy(_script)
	_room(s)["ambient"]["lines"][0]["voice"] = "ghost"
	_ok("rejects_unknown_voice", ChatroomScript.validate(s).has("unknown_voice"), "")

	s = _copy(_script)
	_room(s)["ambient"]["lines"] = []
	_ok("rejects_empty_ambient", ChatroomScript.validate(s).has("empty_ambient"), "")

	var cfg: Dictionary = _copy(_cfg)
	cfg["required_facts"] = ["f_entanglement", "f_does_not_exist"]
	_ok("rejects_unknown_required_fact", ChatroomScript.validate(_script, _briefing, cfg).has("unknown_required_fact"), "")

	s = _copy(_script)
	s["handler"]["accept_commands"] = []
	_ok("rejects_no_accept_command", ChatroomScript.validate(s).has("no_accept_command"), "")

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


## --- U15-U17: the first-message trigger ---------------------------------------------------------

func _u15_to_u17() -> void:
	var trig: Dictionary = _room(_script)["handler_trigger"]
	_ok("trigger_false_before_any_message", not ChatroomScript.trigger_fires(trig, false, ""), "")
	_ok("trigger_false_for_empty_or_whitespace", not ChatroomScript.trigger_fires(trig, false, "   \t") and not ChatroomScript.trigger_fires(trig, false, ""), "")
	_ok("trigger_true_for_first_message_never_twice", ChatroomScript.trigger_fires(trig, false, "hi") and not ChatroomScript.trigger_fires(trig, true, "hi again"), "")


## --- U18-U21: unlocking ---------------------------------------------------------------------------

func _locked_text_in_prompt(builder: Callable, unlocked: Array) -> int:
	var msgs: Array = builder.call(_persona, _briefing, unlocked, [], "hello", false)
	var blob := ""
	for m in msgs:
		blob += String(m["content"]) + "\n"
	var hits := 0
	for f in _briefing["facts"]:
		if not unlocked.has(String(f["id"])) and blob.contains(String(f["text"])):
			hits += 1
	return hits


func _u18_to_u21() -> void:
	_ok("empty_line_unlocks_nothing", ChatroomScript.facts_for_turn(_briefing, _cfg, [], "").is_empty() and ChatroomScript.facts_for_turn(_briefing, _cfg, [], "   ").is_empty(), "")
	_ok("locked_fact_text_absent_from_prompt", _locked_text_in_prompt(Callable(ChatroomScript, "build_messages"), ["f_entanglement"]) == 0, "")
	# Negative control: a prompt builder that injects every fact is caught.
	var leaky := func(persona: Dictionary, briefing: Dictionary, _unlocked: Array, history: Array, text: String, due: bool) -> Array:
		var all_ids: Array = []
		for f in briefing["facts"]:
			all_ids.append(String(f["id"]))
		return ChatroomScript.build_messages(persona, briefing, all_ids, history, text, due)
	_neg("prompt_builder_injecting_locked_facts", _locked_text_in_prompt(leaky, ["f_entanglement"]) > 0)

	var one := ChatroomScript.facts_for_turn(_briefing, _cfg, [], "what is the proxy exactly")
	_ok("ask_keyword_unlocks_exactly_its_fact", one == ["f_proxy"], str(one))
	var again := ChatroomScript.facts_for_turn(_briefing, _cfg, ["f_proxy"], "what is the proxy exactly")
	_ok("unlocked_fact_not_unlocked_twice", again.is_empty(), str(again))

	var unlocked: Array = []
	var offered := false
	var credited: Array = []
	for i in range(20):
		unlocked.append_array(ChatroomScript.facts_for_turn(_briefing, _cfg, unlocked, LAZY[i % LAZY.size()]))
		if ChatroomScript.readiness(_cfg, credited, i + 1):
			offered = true
	_ok("twenty_lazy_lines_unlock_nothing_and_no_offer", unlocked.is_empty() and not offered, str(unlocked))

	var many := ChatroomScript.facts_for_turn(_briefing, _cfg, [], "what is the entanglement, who is the colonist, how do orders work, what is my job")
	_ok("at_most_two_new_facts_per_turn", many.size() == 2, str(many))


## --- U22-U23: readiness and credit ------------------------------------------------------------------

func _readiness_cases(fn: Callable) -> bool:
	var all: Array = _cfg["required_facts"].duplicate()
	var min_turns: int = int(_cfg["min_player_turns"])
	var full_but_early: bool = fn.call(_cfg, all, min_turns - 1)
	var full_and_late: bool = fn.call(_cfg, all, min_turns)
	var missing_one: bool = fn.call(_cfg, all.slice(1), min_turns + 5)
	return (not full_but_early) and full_and_late and (not missing_one)


func _u22_to_u23_and_negctl() -> void:
	_ok("readiness_needs_every_required_fact_and_min_turns", _readiness_cases(Callable(ChatroomScript, "readiness")), "")
	# Negative control: a stub that ignores the minimum turn count is caught.
	var ignores_turns := func(cfg: Dictionary, credited: Array, _turns: int) -> bool:
		for need in cfg["required_facts"]:
			if not credited.has(String(need)):
				return false
		return true
	_neg("readiness_stub_ignoring_min_turns", not _readiness_cases(ignores_turns))

	var quiet := ChatroomScript.credit(_briefing, ["f_proxy"], "I will not say anything useful here.", [])
	var loud := ChatroomScript.credit(_briefing, ["f_proxy"], "The colonist is the proxy.", [])
	var locked := ChatroomScript.credit(_briefing, [], "The colonist is the proxy.", [])
	_ok("reply_without_say_keyword_does_not_credit", quiet.is_empty() and loud == ["f_proxy"] and locked.is_empty(), "%s %s %s" % [quiet, loud, locked])


## --- U24-U29: the reply gate, entry and the prompt budget -----------------------------------------------

func _reply(say: String, act: String) -> String:
	return JSON.stringify({"say": say, "act": act})


func _downgrade_cases(fn: Callable) -> bool:
	var early: Dictionary = fn.call(_reply("come through", "offer_entry"), false, 240)
	var due: Dictionary = fn.call(_reply("come through", "offer_entry"), true, 240)
	return bool(early["ok"]) and String(early["act"]) == "none" and String(due["act"]) == "offer_entry"


func _accept_cases(fn: Callable) -> bool:
	var cmds: Array = _script["handler"]["accept_commands"]
	var exact: bool = fn.call(cmds, "enter") and fn.call(cmds, "  ACCEPT ") and fn.call(cmds, "i   accept")
	var cyrillic: bool = fn.call(cmds, "еnter")
	var wide: bool = fn.call(cmds, "ｅｎｔｅｒ")
	return exact and not cyrillic and not wide


func _dotted_cases(fn: Callable) -> bool:
	var cmds: Array = _script["handler"]["accept_commands"]
	return fn.call(cmds, "I ACCEPT") and not fn.call(cmds, "\u0130 accept") and not fn.call(["leave"], "l\u0435ave")


func _u24_to_u29() -> void:
	var good := ChatroomScript.validate_handler_reply(_reply("The link holds.", "none"), false, 240)
	_ok("valid_reply_accepted", bool(good["ok"]) and String(good["say"]) == "The link holds." and String(good["act"]) == "none", str(good))

	var cases := {
		"non_json": "The link holds.",
		"extra_key": JSON.stringify({"say": "x", "act": "none", "extra": 1}),
		"unknown_act": _reply("x", "teleport"),
		"over_long": _reply("a".repeat(241), "none"),
		"think_marker": _reply("<think>plan</think> hello", "none"),
		"code_fence": _reply("```run```", "none"),
		"missing_say": JSON.stringify({"act": "none"}),
		"wrong_types": JSON.stringify({"say": 5, "act": "none"}),
	}
	var all_rejected := true
	var survivors: Array = []
	for k in cases:
		if bool(ChatroomScript.validate_handler_reply(String(cases[k]), true, 240)["ok"]):
			all_rejected = false
			survivors.append(k)
	_ok("malformed_replies_rejected", all_rejected, str(survivors))

	_ok("offer_before_readiness_downgraded", _downgrade_cases(Callable(ChatroomScript, "validate_handler_reply")), "")
	# Negative control: a validator that trusts act unconditionally is caught.
	var trusting := func(content: String, _ready: bool, _max: int) -> Dictionary:
		var obj = JSON.parse_string(content)
		return {"ok": true, "act": String(obj["act"]), "say": String(obj["say"])}
	_neg("reply_validator_trusting_act", not _downgrade_cases(trusting))

	_ok("entry_allowed_only_in_entry_offered", ChatroomScript.entry_allowed(ChatroomScript.ST_OFFERED) and not ChatroomScript.entry_allowed(ChatroomScript.ST_ROOM) and not ChatroomScript.entry_allowed(ChatroomScript.ST_BRIEFING) and not ChatroomScript.entry_allowed(""), "")

	_ok("lookalike_accept_rejected", _accept_cases(Callable(ChatroomScript, "matches_command")), "")
	# Negative control: an accept matcher that folds Unicode is caught.
	var folding := func(commands: Array, text: String) -> bool:
		var folded := text.replace("е", "e").to_lower()
		for c in commands:
			if folded.strip_edges() == String(c):
				return true
		return false
	_neg("accept_stub_folding_unicode", not _accept_cases(folding))

	# Spec #562 D14 (#902): any non-ASCII input is rejected before case folding, and
	# punctuation never counts as part of a command.
	var acc: Array = _script["handler"]["accept_commands"]
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

	var all_ids: Array = []
	for f in _briefing["facts"]:
		all_ids.append(String(f["id"]))
	var history: Array = []
	for i in range(ChatroomScript.HISTORY_MESSAGES * 2):
		history.append({"role": "user" if i % 2 == 0 else "assistant", "content": "x".repeat(200 if i % 2 == 0 else 240)})
	var msgs := ChatroomScript.build_messages(_persona, _briefing, all_ids, history, "y".repeat(200), true)
	var tokens := ChatroomScript.estimate_tokens(msgs)
	_ok("prompt_estimate_within_budget_all_facts", tokens <= 1100 and msgs.size() == 2 + ChatroomScript.HISTORY_MESSAGES, "%d tokens, %d messages" % [tokens, msgs.size()])
	# Negative control: an oversize prompt is flagged by the same budget check.
	var fat: Array = history.duplicate()
	for i in range(40):
		fat.append({"role": "user", "content": "z".repeat(240)})
	var fat_msgs := ChatroomScript.build_messages(_persona, _briefing, all_ids, fat, "q".repeat(5000), true)
	_neg("oversize_prompt_flagged", ChatroomScript.estimate_tokens(fat_msgs) > 1100)


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


## --- U34-U36: the tabled readiness file ----------------------------------------------------------------------

func _u34_to_u36() -> void:
	var good := ChatroomScript.check_readiness(_copy(_cfg), _briefing)
	var not_tabled: Dictionary = _copy(_cfg)
	not_tabled["status"] = "DECIDED"
	var stall: Dictionary = _copy(_cfg)
	stall["stall_turns"] = 6
	var unknown: Dictionary = _copy(_cfg)
	unknown["required_facts"] = ["f_nope"]
	var r1 := ChatroomScript.check_readiness(not_tabled, _briefing)
	var r2 := ChatroomScript.check_readiness(stall, _briefing)
	var r3 := ChatroomScript.check_readiness(unknown, _briefing)
	var on_disk := ChatroomScript.load_readiness(ChatroomScript.data_dir() + "/readiness.json", _briefing)
	_ok("load_readiness_rejects_untabled_stall_and_unknown_fact", bool(good["ok"]) and bool(on_disk["ok"]) and String(r1["error"]) == "not_tabled" and String(r2["error"]) == "stall_turns" and String(r3["error"]) == "unknown_required_fact", "%s %s %s" % [r1, r2, r3])

	var empty_required: Dictionary = _copy(_cfg)
	empty_required["required_facts"] = []
	var min_turns: int = int(empty_required["min_player_turns"])
	_ok("empty_required_list_ready_once_min_turns_pass", ChatroomScript.readiness(empty_required, [], min_turns) and not ChatroomScript.readiness(empty_required, [], min_turns - 1), "")

	var unlocked: Array = []
	var credited: Array = []
	var ready_ever := false
	for i in range(20):
		unlocked.append_array(ChatroomScript.facts_for_turn(_briefing, _cfg, unlocked, LAZY[i % LAZY.size()]))
		credited.append_array(ChatroomScript.credit(_briefing, unlocked, "I will not say anything useful here.", credited))
		if ChatroomScript.readiness(_cfg, credited, i + 1):
			ready_ever = true
	_ok("placeholder_required_facts_never_ready_after_twenty_lazy_turns", not ready_ever, "")
