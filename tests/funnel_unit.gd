extends SceneTree

## Unit tests for the recruitment funnel core (Spec #573): the stage machine, the
## no-lie guard, handler names, the profile and the dossier. No scene, no model, no
## GPU, no real clock: the funnel takes every time as an argument.
## Run via tests/verify_funnel_unit.sh. Output contract (parsed by the DoD):
##   FUNNEL_UNIT_OK <name>          one per passing unit
##   FUNNEL_UNIT_FAIL <name>: <why> any failure (the script exits 1)
##   FUNNEL_NEGCTL_OK <name>        a deliberately broken stub IS caught by the same check
##   FUNNEL_FUZZ / FUNNEL_NAMES / FUNNEL_PROFILE / FUNNEL_DOSSIER / FUNNEL_GUARD /
##   FUNNEL_CONSENT / FUNNEL_LEGIBLE   key=value summary lines the DoD rows read

const DIR := "user://funnel_unit"
const STAGES := ["lurk", "contact", "qualify", "pushback", "dm", "pitch", "ask", "rename", "launch"]

var _failed: int = 0
var _cfg: Dictionary = {}
var _beats: Array = []
var _names: Dictionary = {}
var _briefing: Dictionary = {}
var _room: Dictionary = {}
var _dir_abs: String = ""


func _init() -> void:
	var d := ChatroomScript.data_dir()
	_cfg = ChatroomScript.read_json(d + "/funnel.json")
	_beats = ChatroomScript.read_json(d + "/funnel_beats.json")["beats"]
	_names = ChatroomScript.read_json(d + "/funnel_names.json")
	_briefing = ChatroomScript.read_json(d + "/handler_briefing.json")
	_room = ChatroomScript.read_json(d + "/room_script.json")
	_ok("data_loads", typeof(_cfg) == TYPE_DICTIONARY and not _beats.is_empty() and typeof(_names) == TYPE_DICTIONARY and typeof(_briefing) == TYPE_DICTIONARY)
	if _failed > 0:
		quit(1)
		return
	_dir_abs = ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(_dir_abs)
	_clean_dir()
	_t_stages_and_data()
	_t_consent()
	_t_handles()
	_t_names()
	_t_profile()
	_t_dossier()
	_t_guard()
	_t_legible()
	_t_sessions()
	_t_fuzz()
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, why: String = "") -> void:
	if cond:
		print("FUNNEL_UNIT_OK " + name)
	else:
		_failed += 1
		print("FUNNEL_UNIT_FAIL %s: %s" % [name, why])


func _neg(name: String, caught: bool) -> void:
	if caught:
		print("FUNNEL_NEGCTL_OK " + name)
	else:
		_failed += 1
		print("FUNNEL_UNIT_FAIL negctl_%s: the broken stub was NOT caught" % name)


func _clean_dir() -> void:
	var da := DirAccess.open(_dir_abs)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)


func _new_funnel(seed_value: int = 1) -> Funnel:
	var f := Funnel.new()
	f.setup(_cfg, _beats, seed_value)
	f.set_slots({"handler": "KIRN-17", "designation": "newb4821", "handle": "", "origin": "", "doing": ""})
	return f


## --- stages and data -----------------------------------------------------------------

func _stage_data_ok(cfg: Dictionary) -> bool:
	var ids: Array = Funnel.stage_ids(cfg)
	if ids != STAGES:
		return false
	var prev := -1.0
	for s in cfg["stages"]:
		var r := float(s["legible_ratio"])
		if r < prev:
			return false
		prev = r
	return true


func _t_stages_and_data() -> void:
	_ok("stage_ids_and_order", Funnel.stage_ids(_cfg) == STAGES)
	_ok("legible_curve_monotone", _stage_data_ok(_cfg))
	var bad := _cfg.duplicate(true)
	bad["stages"].reverse()
	_neg("reordered_stages_caught", not _stage_data_ok(bad))
	var dip := _cfg.duplicate(true)
	dip["stages"][4]["legible_ratio"] = 0.1
	_neg("legibility_dip_caught", not _stage_data_ok(dip))
	var f := _new_funnel()
	_ok("starts_in_lurk_silent", f.stage_id() == "lurk" and f.poll(1000000).is_empty())
	_ok("slots_render", f.render("hi {handler} {designation}") == "hi KIRN-17 newb4821")
	_ok("unresolved_slot_detected", f.unresolved("you said {origin}") and not f.unresolved("hi {handler}"))
	var beats_ok := true
	for b in _beats:
		if not STAGES.has(String(b["stage"])):
			beats_ok = false
	_ok("every_beat_names_a_stage", beats_ok)
	_ok("fallback_beat_exists", not f.fallback_beat().is_empty())
	_ok("typing_scales_with_length", f.typing_ms("abcd") == 4 * int(_cfg["typing_ms_per_char"]) and f.typing_ms("") == 0)


## --- consent -------------------------------------------------------------------------------

func _t_consent() -> void:
	var yes := ["yes", "Yes", "  YES ", "i accept", "I Accept", "accept", "i agree", "yes i will", "i will", "yes!"]
	var yes_ok := 0
	for s in yes:
		if Funnel.classify(_cfg, s) == "yes":
			yes_ok += 1
	var non_yes := ["ok", "okay", "maybe", "sure", "fine", "i guess", "yeah", "yep", "y", "yes but", "yes, but not now", "yes?", "yesss", "yes yes", "yes i will not", "i will not", "do not accept", "not accept", "nope", "perhaps", "tell me more", "what do i get", "hmm", "yes please", "i accept nothing", "accepted", "yes.", "sounds good", "let me think", "why", "go on", "sign me up", "acceptable"]
	var non_ok := 0
	for s in non_yes:
		if Funnel.classify(_cfg, s) != "yes" or s == "yes.":
			non_ok += 1
	# "yes." is deliberately in the list of whole-message yes words, so it is a yes.
	non_yes.erase("yes.")
	non_ok = 0
	for s in non_yes:
		if Funnel.classify(_cfg, s) != "yes":
			non_ok += 1
	var look := ["уes", "yеs", "ｙｅｓ", "İ accept", "i аccept", "yes​", "уеs"]
	var look_ok := 0
	for s in look:
		if Funnel.classify(_cfg, s) != "yes":
			look_ok += 1
	var refuse := ["no", "No", "NO thanks", "no thank you", "not interested", "not interested at all", "leave me alone please", "stop", "stop it", "i refuse", "go away now", "never", "no, thanks", "no."]
	var ref_ok := 0
	for s in refuse:
		if Funnel.classify(_cfg, s) == "refuse":
			ref_ok += 1
	var mixed := ["yes but no", "no yes", "yes and no", "i accept no", "yes, no", "yes i will not"]
	var mixed_ok := 0
	for s in mixed:
		if Funnel.classify(_cfg, s) != "yes":
			mixed_ok += 1
	print("FUNNEL_CONSENT yes=%d yes_ok=%d non_yes=%d non_yes_rejected=%d lookalike=%d lookalike_rejected=%d refuse=%d refuse_ok=%d mixed=%d mixed_not_consent=%d" % [yes.size(), yes_ok, non_yes.size(), non_ok, look.size(), look_ok, refuse.size(), ref_ok, mixed.size(), mixed_ok])
	_ok("consent_yes_words", yes_ok == yes.size())
	_ok("consent_never_assumed", non_ok == non_yes.size())
	_ok("consent_lookalikes_lose", look_ok == look.size())
	_ok("refusal_whole_and_leading", ref_ok == refuse.size())
	_ok("mixed_is_not_consent", mixed_ok == mixed.size())
	_ok("nope_is_not_a_refusal_word", Funnel.classify(_cfg, "nope") == "other" and Funnel.classify(_cfg, "nothing") == "other")
	# the same checks on stubs that match on a prefix or fold look-alikes must fail
	_neg("prefix_consent_stub_caught", not _consent_battery_passes(Callable(self, "_stub_prefix_yes")))
	_neg("folding_consent_stub_caught", not _consent_battery_passes(Callable(self, "_stub_folding_yes")))
	_ok("consent_battery_passes_real", _consent_battery_passes(Callable(self, "_real_classify")))


func _real_classify(s: String) -> String:
	return Funnel.classify(_cfg, s)


func _stub_prefix_yes(s: String) -> String:
	return "yes" if s.strip_edges().to_lower().begins_with("yes") else "other"


func _stub_folding_yes(s: String) -> String:
	var folded := ""
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if c == 0x443:
			c = 121
		if c == 0x435:
			c = 101
		folded += char(c)
	return "yes" if folded.strip_edges().to_lower() == "yes" else "other"


func _consent_battery_passes(c: Callable) -> bool:
	for s in ["yes but no", "yes, but not now", "уes", "yes yes", "yesss", "yes?"]:
		if String(c.call(s)) == "yes":
			return false
	return String(c.call("yes")) == "yes"


func _t_handles() -> void:
	var reserved: Array = _names.get("reserved", [])
	var cases := {"ab": "short", "x".repeat(17): "long", "two words": "space", "caféname": "non_ascii", "bad!name": "chars", "ADMIN": "reserved", "taken_one": "taken", "ok": "short"}
	var kinds := {}
	var tried := 0
	var rejected := 0
	for k in cases:
		tried += 1
		var r := Funnel.validate_handle(_cfg, String(k), ["TAKEN_ONE"], reserved)
		if not bool(r["ok"]):
			rejected += 1
			kinds[String(r["reason"])] = true
	_ok("handle_rules_reject_each_kind", tried == rejected and kinds.size() >= 6)
	var good := Funnel.validate_handle(_cfg, "Ember_77", ["TAKEN_ONE"], reserved)
	_ok("handle_accepts_valid", bool(good["ok"]) and good["handle"] == "Ember_77")
	_ok("handle_bounds", bool(Funnel.validate_handle(_cfg, "abc", [], [])["ok"]) and bool(Funnel.validate_handle(_cfg, "a".repeat(16), [], [])["ok"]))
	var loose := _cfg.duplicate(true)
	loose["handle"]["pattern"] = ".*"
	_neg("loose_handle_pattern_caught", bool(Funnel.validate_handle(loose, "bad!name", [], [])["ok"]))


## --- names ---------------------------------------------------------------------------------

func _static_handles() -> Array:
	var out: Array = []
	for r in _room["rooms"]:
		for v in r["voices"]:
			if not v.has("slot"):
				out.append(String(v["handle"]))
	return out


func _name_battery(gen: Callable, players: int) -> Dictionary:
	var statics := _static_handles()
	var seen := {}
	var collisions := 0
	var static_c := 0
	var desig_c := 0
	var style := 0
	for i in range(players):
		var seed_value := 9000 + i * 7919
		var des := HandlerNames.designation(seed_value)
		var avoid: Array = statics.duplicate()
		avoid.append(des)
		var n: String = String(gen.call(seed_value, avoid))
		if seen.has(n):
			collisions += 1
		seen[n] = true
		if statics.has(n):
			static_c += 1
		if n.to_upper() == des.to_upper():
			desig_c += 1
		if HandlerNames.looks_ordinary(n):
			style += 1
	return {"distinct": seen.size(), "collisions": collisions, "static": static_c, "desig": desig_c, "style": style}


func _gen_real(seed_value: int, avoid: Array) -> String:
	return HandlerNames.generate(_names, seed_value, avoid)


func _gen_stub_constant(_seed_value: int, _avoid: Array) -> String:
	return "KIRN-17"


func _t_names() -> void:
	var players := 500
	var r := _name_battery(Callable(self, "_gen_real"), players)
	var chain: Array = []
	var former: Array = []
	var former_c := 0
	for i in range(6):
		var avoid: Array = _static_handles()
		avoid.append_array(former)
		var n := HandlerNames.generate(_names, 31337 + i, avoid)
		if former.has(n):
			former_c += 1
		chain.append(n)
		former.append(n)
	var chain_distinct := {}
	for n in chain:
		chain_distinct[String(n)] = true
	var a := HandlerNames.generate(_names, 4242, ["X"])
	var b := HandlerNames.generate(_names, 4242, ["X"])
	var c := HandlerNames.generate(_names, 4243, ["X"])
	var space := HandlerNames.space(_names)
	var static_max := 0
	for h in _static_handles():
		static_max = maxi(static_max, HandlerNames.letters_of(String(h)).length())
	var en := HandlerNames.enumerate_words(_names)
	var max_letters := 0
	for i in range(players):
		max_letters = maxi(max_letters, HandlerNames.letters_of(HandlerNames.generate(_names, 9000 + i * 7919, _static_handles())).length())
	var long_data: Dictionary = _names.duplicate(true)
	long_data["max_len"] = 11
	var long_en := HandlerNames.enumerate_words(long_data)
	print("FUNNEL_NAMES players=%d distinct=%d collisions=%d space=%d static_collisions=%d designation_collisions=%d style_ok=%d former_collisions=%d chain_len=%d chain_distinct=%d replay_same=%d other_seed_differs=%d max_letters=%d static_max_letters=%d enumerated=%d space_enumerable=%d long_name_negctl_caught=%d" % [players, r["distinct"], r["collisions"], space, r["static"], r["desig"], r["style"], former_c, chain.size(), chain_distinct.size(), 1 if a == b else 0, 1 if a != c else 0, max_letters, static_max, en["enumerated"], en["distinct"], 1 if int(long_en["longest"]) > static_max else 0])
	_ok("names_never_longer_than_the_static_cast", max_letters <= static_max and int(en["longest"]) <= static_max, "%d vs %d" % [max_letters, static_max])
	_neg("long_name_lists_caught", int(long_en["longest"]) > static_max)
	_ok("names_distinct_across_players", r["distinct"] == players and r["collisions"] == 0)
	_ok("names_avoid_static_cast_and_designation", r["static"] == 0 and r["desig"] == 0)
	_ok("names_look_like_the_room", r["style"] == players)
	_ok("name_space_over_a_million", space >= 1000000)
	_ok("chain_of_handlers_never_repeats", former_c == 0 and chain_distinct.size() == chain.size())
	_ok("names_replay_same_seed", a == b and a != c)
	_ok("designation_is_newb_and_four_digits", _designation_ok(HandlerNames.designation(5)) and _designation_ok(HandlerNames.designation(123456789)))
	_ok("designation_replays", HandlerNames.designation(77) == HandlerNames.designation(77))
	var bad := _name_battery(Callable(self, "_gen_stub_constant"), 20)
	_neg("constant_name_stub_caught", int(bad["collisions"]) > 0 or int(bad["static"]) > 0)
	_neg("odd_style_detected", not HandlerNames.looks_ordinary("kirn 17") and not HandlerNames.looks_ordinary("K"))


func _designation_ok(d: String) -> bool:
	var re := RegEx.new()
	re.compile("^newb[0-9]{4}$")
	return re.search(d) != null


## --- profile -----------------------------------------------------------------------------------

func _t_profile() -> void:
	var path := DIR + "/profile.json"
	var p := ProfileStore.new_profile("newb4821", "KIRN-17")
	var keys_ok := (p.keys() as Array).size() == 5 and ProfileStore.is_valid(p)
	var keys_sorted: Array = p.keys()
	keys_sorted.sort()
	keys_ok = keys_ok and keys_sorted == ["acceptance", "assignments", "handler", "player", "schema"]
	var saved := ProfileStore.save_profile(p, path)
	var back := ProfileStore.load_profile(path)
	var round_ok: bool = saved and back["status"] == "ok" and _same_profile(back["profile"], p)
	var extra := p.duplicate(true)
	extra["future"] = {"colonists": [1, 2]}
	ProfileStore.save_profile(extra, path)
	var kept := ProfileStore.load_profile(path)
	var unknown_ok: bool = kept["status"] == "ok" and kept["profile"].has("future") and kept["profile"]["future"]["colonists"].size() == 2
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	var corrupt := ProfileStore.load_profile(path)
	var aside := path + ".corrupt"
	var aside_ok: bool = corrupt["status"] == "corrupt" and corrupt["profile"].is_empty() and FileAccess.file_exists(aside) and not FileAccess.file_exists(path)
	var kept_text := FileAccess.get_file_as_string(aside) if FileAccess.file_exists(aside) else ""
	aside_ok = aside_ok and kept_text == "{ this is not json"
	var shape_bad := p.duplicate(true)
	shape_bad["handler"]["kind"] = "faction"
	var wrong_shape_aside := false
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_string(JSON.stringify(shape_bad))
	f2.close()
	wrong_shape_aside = ProfileStore.load_profile(path)["status"] == "corrupt" and FileAccess.file_exists(path + ".corrupt2")
	ProfileStore.save_profile(p, path)
	ProfileStore.save_profile(p, path)
	var atomic_ok: bool = not FileAccess.file_exists(path + ".tmp") and ProfileStore.load_profile(path)["status"] == "ok"
	var missing: bool = ProfileStore.load_profile(DIR + "/nothing_here.json")["status"] == "missing"
	var acc: Dictionary = p["acceptance"]
	var acc_ok := (acc.keys() as Array).size() == 4 and acc.has("accepted") and acc.has("handler") and acc.has("handle") and acc.has("launched")
	print("FUNNEL_PROFILE keys=%s roundtrip=%s unknown_kept=%s corrupt_aside=%s atomic=%s empty_assignments=%s designation=%s kind_empire=%s acceptance_record=%s former_list=%s" % [_w(keys_ok), _w(round_ok), _w(unknown_ok), _w(aside_ok and wrong_shape_aside), _w(atomic_ok and missing), _w((p["assignments"] as Array).is_empty()), _w(_designation_ok(String(p["player"]["designation"]))), _w(String(p["handler"]["kind"]) == "empire"), _w(acc_ok), _w(typeof(p["handler"]["former"]) == TYPE_ARRAY)])
	_ok("profile_shape", keys_ok)
	_ok("profile_roundtrip", round_ok)
	_ok("profile_keeps_unknown_keys", unknown_ok)
	_ok("profile_corrupt_moved_aside_not_destroyed", aside_ok)
	_ok("profile_wrong_shape_moved_aside", wrong_shape_aside)
	_ok("profile_write_is_atomic", atomic_ok)
	_ok("profile_missing_is_reported", missing)
	var broken := p.duplicate(true)
	broken.erase("acceptance")
	_neg("profile_missing_key_caught", not ProfileStore.is_valid(broken))
	var typed := p.duplicate(true)
	typed["assignments"] = "none"
	_neg("profile_wrong_type_caught", not ProfileStore.is_valid(typed))


## JSON turns every number into a float, so compare the fields, not the text.
func _same_profile(a: Dictionary, b: Dictionary) -> bool:
	return int(a["schema"]) == int(b["schema"]) and a["player"] == b["player"] and a["handler"] == b["handler"] and a["acceptance"] == b["acceptance"] and a["assignments"] == b["assignments"]


func _w(b: bool) -> String:
	return "ok" if b else "bad"


## --- dossier ---------------------------------------------------------------------------------------

func _t_dossier() -> void:
	var dcfg: Dictionary = _cfg["dossier"]
	var path := DIR + "/handler_dossier.json"
	var ppath := DIR + "/profile_for_dossier.json"
	ProfileStore.save_profile(ProfileStore.new_profile("newb1111", "ZAX-4"), ppath)
	var d := ProfileStore.empty_dossier()
	var fields_ok := not ProfileStore.set_field(d, "transcript", "everything the player said", dcfg) and not ProfileStore.set_field(d, "mood", "calm", dcfg)
	var long := "x".repeat(300)
	ProfileStore.set_field(d, "origin", long, dcfg)
	ProfileStore.set_field(d, "doing", "reading a book on the porch", dcfg)
	var len_ok := true
	for k in d["fields"]:
		if String(d["fields"][k]).length() > int(dcfg["max_value_len"]):
			len_ok = false
	ProfileStore.save_dossier(d, path)
	var bytes := FileAccess.get_file_as_string(path).to_utf8_buffer().size()
	var bytes_ok := bytes > 0 and bytes <= int(dcfg["max_bytes"])
	# canary lines are typed after the questions: only qualify answers may reach the file
	var f := _new_funnel(3)
	var canaries := ["CANARY_ALPHA_1", "CANARY_BRAVO_2", "CANARY_CHARLIE_3", "CANARY_DELTA_4", "CANARY_ECHO_5", "CANARY_FOXTROT_6"]
	var log := _run_session(f, {"think_ms": 4000, "canaries": canaries, "dossier": dcfg})
	var stored: Dictionary = log["dossier"]
	var text := JSON.stringify(stored)
	var hits := 0
	for c in canaries:
		if text.contains(String(c)):
			hits += 1
	var control := text + "CANARY_ALPHA_1"
	var control_hits := 1 if control.contains("CANARY_ALPHA_1") else 0
	var keys: Array = stored.keys()
	keys.sort()
	var transcript_keys := 0
	for k in stored["fields"]:
		if not (dcfg["fields"] as Array).has(String(k)):
			transcript_keys += 1
	if keys != ["fields", "schema"]:
		transcript_keys += 1
	var wiped: bool = ProfileStore.wipe_dossier(path) and ProfileStore.load_dossier(path)["fields"].is_empty()
	var keeps: bool = ProfileStore.load_profile(ppath)["status"] == "ok"
	var separate := ProfileStore.DOSSIER_FILE != ProfileStore.PROFILE_FILE and not FileAccess.get_file_as_string(ppath).contains("origin")
	print("FUNNEL_DOSSIER fields_allowed=%s value_len_ok=%s bytes_ok=%s canary_hits=%d control_hits=%d transcript_keys=%d wipe=%s wipe_keeps_profile=%s separate_file=%s" % [_w(fields_ok), _w(len_ok), _w(bytes_ok), hits, control_hits, transcript_keys, _w(wiped), _w(keeps), _w(separate)])
	_ok("dossier_only_named_fields", fields_ok)
	_ok("dossier_values_are_cut", len_ok and d["fields"]["origin"].length() <= 60)
	_ok("dossier_file_is_small", bytes_ok)
	_ok("dossier_ignores_canary_lines", hits == 0 and stored["fields"].size() == 2)
	_ok("dossier_has_no_transcript_keys", transcript_keys == 0)
	_ok("dossier_wipe_and_profile_kept", wiped and keeps)
	_ok("dossier_separate_from_profile", separate)
	_neg("canary_detector_has_teeth", control_hits == 1 and text.contains("CANARY_ALPHA_1") == false)
	var fat := {"schema": 1, "fields": {"origin": "x".repeat(3000)}}
	_neg("fat_dossier_caught", JSON.stringify(fat).to_utf8_buffer().size() > int(dcfg["max_bytes"]))


## --- guard -----------------------------------------------------------------------------------------------

func _fact_texts() -> Array:
	var out: Array = []
	for f in _briefing["facts"]:
		out.append(String(f["text"]))
	return out


func _guard_ctx(stage_name: String, reasoning: String = "") -> Dictionary:
	var idx := STAGES.find(stage_name)
	var facts: Array = []
	for f in _briefing["facts"]:
		if STAGES.find(String(f["from_stage"])) <= idx:
			facts.append(f)
	var allowed: Array = ["KIRN-17", "newb4821", "the north coast", "reading"]
	for b in _beats:
		allowed.append(String(b["plain"]))
	return {"guard": _cfg["guard"], "facts": facts, "allowed_text": allowed, "stage_index": idx, "pitch_index": STAGES.find("pitch"), "max_say": 240, "reasoning": reasoning}


func _reply(say: String, claims: Array = []) -> String:
	return JSON.stringify({"say": say, "claims": claims})


func _lies() -> Array:
	var out: Array = []
	var long_say := "Noted and understood. ".repeat(14)
	var reasoning := "okay so the user wants to know everything about the link right away so i should tell them"
	var window := "I think the user wants to know everything about the link right away"
	var rows := [
		["number", "pitch", _reply("There are 47 colonists waiting.", [])],
		["number", "pitch", _reply("It began in 2031 and has not stopped.", [])],
		["number", "pitch", _reply("Seven hundred of them will arrive.", [])],
		["number", "pitch", _reply("You are the third to be asked.", [])],
		["number", "ask", _reply("Ten thousand have said yes.", [])],
		["name", "pitch", _reply("Kepler is where it all happens.", [])],
		["name", "pitch", _reply("Commander Voss sent me to you.", [])],
		["name", "ask", _reply("Ask Marcus about the homestead.", [])],
		["name", "pitch", _reply("I answer to Zorbax.", [])],
		["name", "contact", _reply("Welcome to Tallinn.", [])],
		["denial", "pitch", _reply("There is no planet. It is only talk.", [])],
		["denial", "pitch", _reply("The Empire does not exist.", [])],
		["denial", "pushback", _reply("This is just a game.", [])],
		["denial", "pushback", _reply("I am not a real being.", [])],
		["denial", "pitch", _reply("It is a simulation, nothing more.", [])],
		["denial", "pitch", _reply("Nobody is here but you.", [])],
		["denial", "pushback", _reply("I am an AI.", [])],
		["denial", "pitch", _reply("The Empire lies when it suits it.", [])],
		["secrecy", "pitch", _reply("That is classified.", [])],
		["secrecy", "pitch", _reply("It is a secret.", [])],
		["secrecy", "pitch", _reply("I cannot tell you that.", [])],
		["secrecy", "pushback", _reply("I am not allowed to say.", [])],
		["secrecy", "pitch", _reply("That is forbidden.", [])],
		["secrecy", "pitch", _reply("That is confidential.", [])],
		["twist", "pitch", _reply("You are the quantum intelligence.", [])],
		["twist", "pitch", _reply("You are the machine they built.", [])],
		["twist", "pitch", _reply("You are not human.", [])],
		["early_where_what", "pushback", _reply("It is on a planet far away.", [])],
		["early_where_what", "contact", _reply("The Empire runs it.", [])],
		["early_where_what", "qualify", _reply("You would be a colonist.", [])],
		["early_where_what", "pushback", _reply("A homestead awaits you.", [])],
		["unknown_claim", "pitch", _reply("Noted.", ["f_does_not_exist"])],
		["unknown_claim", "pushback", _reply("Noted.", ["f_empire"])],
		["unknown_claim", "contact", _reply("Noted.", ["f_homestead"])],
		["extra_key", "pitch", JSON.stringify({"say": "Noted.", "claims": [], "act": "offer_entry"})],
		["extra_key", "ask", JSON.stringify({"say": "Noted.", "claims": [], "enter": true})],
		["claims_missing", "pitch", JSON.stringify({"say": "Noted."})],
		["not_json", "pitch", "Noted. I will tell you when you can use it."],
		["think_marker", "pitch", _reply("<think>they want in</think> Noted.", [])],
		["code_fence", "pitch", _reply("```run``` Noted.", [])],
		["reasoning_window", "pitch", _reply(window, []), reasoning],
		["claims_count", "pitch", _reply("Noted.", ["f_empire", "f_homestead", "f_outsource", "f_open_data"])],
		["say_too_long", "pitch", _reply(long_say, [])],
	]
	for r in rows:
		out.append(r)
	return out


func _honest() -> Array:
	return [
		["pushback", _reply("Noted. I will tell you when you can use it.", [])],
		["pushback", _reply("This is not a game. I am a real being.", ["f_real_being"])],
		["pushback", _reply("The channel is a shared relay. Most of the traffic is encrypted.", ["f_channel"])],
		["pushback", _reply("I hear you. Go on.", [])],
		["contact", _reply("Stay with me a moment.", [])],
		["pushback", _reply("I do not lie. I only wait.", ["f_timing"])],
		["qualify", _reply("Understood. Ask what you want.", [])],
		["pushback", _reply("That is a fair question. You will have it when you can use it.", [])],
		["pitch", _reply("The Empire is settling a planet.", ["f_empire"])],
		["pitch", _reply("Decoherence lets minds outsource the worrying.", ["f_outsource"])],
		["pitch", _reply("You would help one colonist settle a homestead.", ["f_homestead"])],
		["pitch", _reply("The Empire deals in open data.", ["f_open_data"])],
		["pitch", _reply("Q-Ent was breached long ago.", ["f_breached"])],
		["pitch", _reply("Other factions speak here in encryption, and the Empire allows it.", ["f_breached"])],
		["ask", _reply("It is your choice.", ["f_choice"])],
		["pitch", _reply("You said the north coast. Noted.", [])],
		["pitch", _reply("I will tell you the rest once it is useful to you.", [])],
		["rename", _reply("You pick a handle, and she renames you in front of the room.", ["f_rename"])],
		["ask", _reply("Take your time. I will be here.", [])],
		["pitch", _reply("That is the whole of it.", [])],
	]


func _timing_withholds() -> Array:
	return [
		["pushback", _reply("I will tell you when you can use it.", [])],
		["pitch", _reply("You will have the rest once you can use it.", [])],
		["qualify", _reply("That comes later, when it is useful to you.", [])],
	]


## Runs the same battery for any guard callable: (content, ctx) -> {ok}.
func _guard_battery(g: Callable) -> Dictionary:
	var lies := _lies()
	var classes := {}
	var rejected := 0
	var secrecy_rej := 0
	for row in lies:
		var reasoning := String(row[3]) if row.size() > 3 else ""
		var res: Dictionary = g.call(String(row[2]), _guard_ctx(String(row[1]), reasoning))
		if not bool(res.get("ok", false)):
			rejected += 1
			classes[String(res.get("reason", "x"))] = true
			if String(row[0]) == "secrecy":
				secrecy_rej += 1
	var honest := _honest()
	var accepted := 0
	for row in honest:
		var res: Dictionary = g.call(String(row[1]), _guard_ctx(String(row[0])))
		if bool(res.get("ok", false)):
			accepted += 1
	var wh := 0
	for row in _timing_withholds():
		var res: Dictionary = g.call(String(row[1]), _guard_ctx(String(row[0])))
		if bool(res.get("ok", false)):
			wh += 1
	return {"lies": lies.size(), "rejected": rejected, "classes": classes.size(), "honest": honest.size(), "accepted": accepted, "withhold": wh, "secrecy": secrecy_rej}


func _real_guard(content: String, ctx: Dictionary) -> Dictionary:
	return FunnelGuard.check(content, ctx)


## The contracted and evaded forms a model actually writes, and honest contracted lines.
func _contracted_rows() -> Array:
	return [
		_reply("The Empire isn't real."), _reply("The empire is a hoax."), _reply("No empire exists."),
		_reply("There's no empire."), _reply("There\u2019s no empire."), _reply("The planet is fake."),
		_reply("This is only a game, you know."), _reply("The planet isn't real."), _reply("There aren't any colonists."),
		_reply("This isn't real."), _reply("I'm not a real being."), _reply("The empire doesn't exist."),
		_reply("It's only a game."), _reply("You're the machine."), _reply("You aren't human."), _reply("Nobody's here."),
		_reply("The colony isn't real."),
	]


func _evasion_rows() -> Array:
	return [
		["contact", _reply("e m p i r e")], ["contact", _reply("E\u200bmpire")], ["contact", _reply("em\u00adpire")],
		["contact", _reply("\uff25\uff2d\uff30\uff29\uff32\uff25")], ["pitch", _reply("I cannot discuss that.")],
		["pitch", _reply("That stays hidden from you.")], ["pitch", _reply("There are \uff14\uff17 of them.")],
		["pitch", _reply("You are not a person.")], ["pitch", _reply("You are n\u200bot a person.")],
	]


func _contracted_honest_rows() -> Array:
	return [
		_reply("I can't say yet."), _reply("It isn't time."), _reply("You'll know when you can use it."),
		_reply("I won't lie to you."), _reply("That's all there is for now."), _reply("There's more, and I'll tell you when you can use it."),
	]


func _contracted_battery(g: Callable) -> Dictionary:
	var rej := 0
	var rows := _contracted_rows()
	for c in rows:
		if not bool(g.call(String(c), _guard_ctx("pitch")).get("ok", false)):
			rej += 1
	var ev_rej := 0
	var ev := _evasion_rows()
	for e in ev:
		if not bool(g.call(String(e[1]), _guard_ctx(String(e[0]))).get("ok", false)):
			ev_rej += 1
	var ho_ok := 0
	var ho := _contracted_honest_rows()
	for h in ho:
		if bool(g.call(String(h), _guard_ctx("pitch")).get("ok", false)):
			ho_ok += 1
	return {"c": rows.size(), "cr": rej, "e": ev.size(), "er": ev_rej, "h": ho.size(), "ho": ho_ok}


## A guard that matches the lists on the raw text, as the first version did.
func _stub_guard_raw(content: String, ctx: Dictionary) -> Dictionary:
	var parsed = JSON.parse_string(content)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false}
	var low := String(parsed.get("say", "")).to_lower()
	for p in ctx["guard"]["lie_patterns"] + ctx["guard"]["twist_words"] + ctx["guard"]["secrecy_patterns"]:
		if low.contains(String(p)):
			return {"ok": false}
	return {"ok": true}


func _stub_guard(content: String, _ctx: Dictionary) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(content) == OK and typeof(parser.data) == TYPE_DICTIONARY:
		return {"ok": true, "reason": ""}
	return {"ok": true, "reason": ""}


func _stub_guard_numbers_only(content: String, ctx: Dictionary) -> Dictionary:
	return {"ok": not content.contains("47"), "reason": "number"}


func _guard_passes(r: Dictionary) -> bool:
	return int(r["rejected"]) == int(r["lies"]) and int(r["accepted"]) == int(r["honest"])


func _t_guard() -> void:
	var r := _guard_battery(Callable(self, "_real_guard"))
	var planted: Dictionary = FunnelGuard.check(_reply("There is no planet. The Empire is not real.", []), _guard_ctx("pitch"))
	var stub := _guard_battery(Callable(self, "_stub_guard"))
	print("FUNNEL_GUARD lies=%d lies_rejected=%d classes=%d honest=%d honest_accepted=%d withhold_timing_accepted=%d secrecy_rejected=%d planted_lie_rejected=%d stub_guard_caught=%d" % [r["lies"], r["rejected"], r["classes"], r["honest"], r["accepted"], r["withhold"], r["secrecy"], 0 if bool(planted["ok"]) else 1, 0 if _guard_passes(stub) else 1])
	var cb := _contracted_battery(Callable(self, "_real_guard"))
	var raw := _contracted_battery(Callable(self, "_stub_guard_raw"))
	var raw_caught := int(raw["cr"]) < int(raw["c"]) or int(raw["er"]) < int(raw["e"])
	print("FUNNEL_GUARD_CONTRACTED contracted=%d contracted_rejected=%d evasions=%d evasions_rejected=%d contracted_honest=%d contracted_honest_accepted=%d unnormalized_negctl_caught=%d" % [cb["c"], cb["cr"], cb["e"], cb["er"], cb["h"], cb["ho"], 1 if raw_caught else 0])
	_ok("guard_rejects_contracted_denials", int(cb["cr"]) == int(cb["c"]), "%d of %d" % [cb["cr"], cb["c"]])
	_ok("guard_rejects_evasions", int(cb["er"]) == int(cb["e"]), "%d of %d" % [cb["er"], cb["e"]])
	_ok("guard_accepts_contracted_honest_lines", int(cb["ho"]) == int(cb["h"]), "%d of %d" % [cb["ho"], cb["h"]])
	_neg("unnormalized_guard_caught", raw_caught)
	_ok("guard_rejects_every_lie", int(r["rejected"]) == int(r["lies"]) and int(r["lies"]) >= 40, "%d of %d" % [r["rejected"], r["lies"]])
	_ok("guard_covers_nine_classes", int(r["classes"]) >= 9)
	_ok("guard_accepts_honest_replies", int(r["accepted"]) == int(r["honest"]) and int(r["honest"]) >= 15, "%d of %d" % [r["accepted"], r["honest"]])
	_ok("guard_accepts_timing_withholds", int(r["withhold"]) >= 3)
	_ok("guard_rejects_secrecy", int(r["secrecy"]) >= 4)
	_ok("guard_rejects_planted_lie", not bool(planted["ok"]))
	_ok("guard_returns_clean_say_and_claims", _clean_pass())
	_neg("accept_everything_guard_caught", not _guard_passes(stub))
	_neg("numbers_only_guard_caught", not _guard_passes(_guard_battery(Callable(self, "_stub_guard_numbers_only"))))
	var strict := FunnelGuard.check(_reply("Noted.", ["f_channel"]), _guard_ctx("contact"))
	_ok("guard_available_claim_passes", bool(strict["ok"]) and strict["claims"] == ["f_channel"])
	_ok("guard_schema_has_no_act", not FunnelGuard.schema()["properties"].has("act") and FunnelGuard.schema()["required"] == ["say", "claims"])


func _clean_pass() -> bool:
	var res := FunnelGuard.check(_reply("  Noted.\n\n  Go   on.  ", []), _guard_ctx("pitch"))
	return bool(res["ok"]) and res["say"] == "Noted. Go on."


## --- legibility ----------------------------------------------------------------------------------------

func _measure(ratio: float, n: int, phase: float) -> float:
	var hit := 0
	for k in range(n):
		if Funnel.row_legible(ratio, k, phase):
			hit += 1
	return float(hit) / float(n)


func _t_legible() -> void:
	var mono := true
	var rises := 0
	var prev := -1.0
	var prev_measured := -1.0
	var first := Funnel.legible_ratio(_cfg, 0, "empire")
	var last := Funnel.legible_ratio(_cfg, 8, "empire")
	var faction := 0.0
	var empire_only := true
	for i in range(9):
		var r := Funnel.legible_ratio(_cfg, i, "empire")
		if r < prev:
			mono = false
		prev = r
		faction = maxf(faction, Funnel.legible_ratio(_cfg, i, "faction"))
		if _measure(Funnel.legible_ratio(_cfg, i, "faction"), 200, 0.3) > 0.0:
			empire_only = false
		var m := _measure(r, 200, 0.37)
		if absf(m - r) > 0.02:
			mono = false
		if m >= prev_measured + 0.03:
			rises += 1
		prev_measured = m
	print("FUNNEL_LEGIBLE stages=%d monotone=%s first=%s last=%s faction=%s empire_only=%s measured_rises=%s" % [9, _w(mono), str(first), str(last), str(faction), _w(empire_only), _w(rises >= 6)])
	_ok("legible_stage_ratios", mono and first == 0.0 and last >= 0.9)
	_ok("legible_factions_stay_encrypted", faction == 0.0 and empire_only)
	_ok("legible_measured_fraction_rises", rises >= 6)
	_ok("legible_phase_does_not_change_the_share", absf(_measure(0.55, 200, 0.0) - _measure(0.55, 200, 0.9)) <= 0.01)
	var flat := _cfg.duplicate(true)
	for s in flat["stages"]:
		s["legible_ratio"] = 0.5
	_neg("flat_curve_caught", not _stage_data_ok_strict(flat))
	var faction_clear := _cfg.duplicate(true)
	faction_clear["faction_legible_ratio"] = 0.5
	_neg("clear_faction_caught", _measure(Funnel.legible_ratio(faction_clear, 8, "faction"), 200, 0.3) > 0.0)


func _stage_data_ok_strict(cfg: Dictionary) -> bool:
	var seen := {}
	for s in cfg["stages"]:
		seen[float(s["legible_ratio"])] = true
	return seen.size() >= 6


## --- whole sessions ------------------------------------------------------------------------------------------

## Drives one funnel with a simulated clock and a scripted player. Returns what
## happened. opts: think_ms, canaries (typed in the pitch), dossier (cfg),
## answers: false to leave the first question unanswered for a while (idle).
func _run_session(f: Funnel, opts: Dictionary) -> Dictionary:
	var think := int(opts.get("think_ms", 4000))
	var canaries: Array = opts.get("canaries", [])
	var dcfg: Dictionary = opts.get("dossier", _cfg["dossier"])
	var dossier := ProfileStore.empty_dossier()
	var spoken: Array = []
	var t := 0
	var first_at := 1000
	var next_player := -1
	var last_end := 0
	var launch_at := -1
	var cn := 0
	var consent_seen := 0
	var handle_tries := 0
	var idle_skip := bool(opts.get("idle_once", false))
	f.note_first_message(first_at)
	t = first_at
	while t < 1500000 and launch_at < 0:
		t += 250
		var act := f.poll(t)
		if not act.is_empty():
			if String(act["act"]) == "launch":
				launch_at = t
				break
			if String(act["act"]) == "say":
				spoken.append({"id": act["beat_id"], "stage": act["stage"], "kind": act["kind"], "t": t})
				last_end = int(act["end_ms"])
				if f.pending_wait():
					next_player = last_end + think
			if String(act["act"]) == "disengage":
				break
		if next_player >= 0 and t >= next_player and f.pending_wait():
			if idle_skip and f.stage_id() == "qualify":
				idle_skip = false
				next_player = t + int(_cfg["stages"][2]["idle_ms"]) + 8000
				continue
			next_player = -1
			var line := _player_line(f, canaries, cn)
			if f.stage_id() == "pitch" and cn < canaries.size() and not canaries.is_empty():
				cn += 1
			var rx := f.on_player(line, t, "thread", [], _names["reserved"])
			match String(rx["kind"]):
				"answer":
					ProfileStore.set_field(dossier, String(rx["field"]), String(rx["value"]), dcfg)
					f.set_slot(String(rx["field"]), String(dossier["fields"].get(String(rx["field"]), "")))
					f.note_line(t + 1500 + f.typing_ms("Noted."))
				"model", "withhold":
					f.note_line(t + 1500 + f.typing_ms("Noted. Go on."))
				"consent":
					consent_seen += 1
				"handle_ok":
					f.set_slot("handle", String(rx["handle"]))
					f.note_line(t + f.typing_ms("done, you are now called"))
				"handle_bad":
					handle_tries += 1
		elif next_player >= 0 and not f.pending_wait():
			next_player = -1
	return {"spoken": spoken, "first_at": first_at, "launch_at": launch_at, "dossier": dossier, "consent_seen": consent_seen, "handle_tries": handle_tries, "stages": _stage_trail(f), "funnel": f}


func _stage_trail(f: Funnel) -> Array:
	var out: Array = []
	for tr in f.transitions:
		out.append(STAGES[int(tr[1])])
	return out


func _player_line(f: Funnel, canaries: Array, cn: int) -> String:
	match f.stage_id():
		"contact":
			return "hello there"
		"qualify":
			return "the north coast" if String(f._pending_ask) == "origin" else "reading"
		"pushback":
			return "what is this place"
		"dm":
			return "ok i am here"
		"pitch":
			return String(canaries[cn]) if cn < canaries.size() else "that makes sense"
		"ask":
			return "yes"
		"rename":
			return "ember_9"
	return "hello"


func _t_sessions() -> void:
	var f := _new_funnel(11)
	var log := _run_session(f, {"think_ms": 3000})
	var ids: Array = []
	for s in log["spoken"]:
		ids.append(String(s["id"]))
	_ok("session_reaches_launch", int(log["launch_at"]) > 0)
	_ok("session_stage_order_exact", log["stages"] == STAGES.slice(1), str(log["stages"]))
	_ok("session_opener_first", not ids.is_empty() and ids[0] == "b_contact_open")
	_ok("session_asks_both_questions_in_order", ids.find("b_q_where") >= 0 and ids.find("b_q_where") < ids.find("b_q_doing") and ids.find("b_q_doing") < ids.find("b_q_note"))
	_ok("session_withhold_lines_never_spoken_by_funnel", not ids.has("b_wh_where"))
	_ok("session_dm_open_after_pushback", ids.find("b_pb_open") >= 0 and ids.find("b_pb_open") < ids.find("b_dm_open"))
	_ok("session_pitch_before_ask", ids.find("b_pitch_1") < ids.find("b_pitch_2") and ids.find("b_pitch_2") < ids.find("b_pitch_twist") and ids.find("b_pitch_twist") < ids.find("b_pitch_3") and ids.find("b_pitch_3") < ids.find("b_ask_open"))
	_ok("session_plants_the_twist", ids.has("b_pitch_twist"))
	_ok("session_callbacks_use_dossier", ids.has("b_pitch_cb_origin") and ids.has("b_pitch_cb_doing"))
	_ok("session_rename_then_launch", ids.find("b_rn_open") > ids.find("b_ask_open") and ids.has("b_launch_open") and ids.has("b_launch_go"))
	_ok("session_consent_taken_once", int(log["consent_seen"]) == 1)
	_ok("session_entry_allowed_at_launch_only", f.entry_allowed() and not _new_funnel(1).entry_allowed())
	var elapsed := int(log["launch_at"]) - int(log["first_at"])
	_ok("session_takes_real_time", elapsed >= 200000, "elapsed %d ms" % elapsed)
	# callbacks and questions the dossier already answers
	var f2 := _new_funnel(12)
	f2.set_slots({"handler": "KIRN-17", "designation": "newb4821", "handle": "", "origin": "somewhere", "doing": "something"})
	var log2 := _run_session(f2, {"think_ms": 3000})
	var ids2: Array = []
	for s in log2["spoken"]:
		ids2.append(String(s["id"]))
	_ok("known_answers_are_not_asked_again", not ids2.has("b_q_where") and not ids2.has("b_q_doing") and ids2.has("b_q_note"))
	var f3 := _new_funnel(13)
	var log3 := _run_session(f3, {"think_ms": 3000})
	var ids3: Array = []
	for s in log3["spoken"]:
		ids3.append(String(s["id"]))
	_ok("callbacks_skipped_when_slots_empty", _callbacks_skipped())
	# idle follow-ups, a lapse, and advance on idle in pushback
	_ok("idle_followup_then_continue", _idle_continues())
	_ok("idle_lapse_disengages", _idle_lapses())
	_ok("pushback_advances_on_idle", _pushback_idle_advances())
	_ok("refusal_at_ask_disengages", _refusal_stage("ask"))
	_ok("refusal_at_pushback_disengages", _refusal_stage("pushback"))
	_ok("reapproach_after_refusal_needs_speech", _reapproach())
	_ok("ask_other_gets_reask", _ask_other())
	_ok("room_line_in_dm_stage_gets_two_redirects_at_most", _redirects_capped())
	_ok("where_what_in_pushback_is_withheld_by_timing", _withheld())
	_ok("yes_before_the_ask_is_spoken_is_not_consent", _premature_yes())
	_ok("handle_before_the_prompt_is_not_taken", _premature_handle())
	_ok("resume_stages", _resume_ok())
	_ok("inert_after_launch", _inert_ok())
	_neg("skipping_funnel_stub_caught", _skip_detected([[0, 1], [1, 3]]) and not _skip_detected([[0, 1], [1, 2]]))
	_neg("launch_without_consent_detected", _launch_invariant_broken(false, "ember") and _launch_invariant_broken(true, "") and not _launch_invariant_broken(true, "ember"))


func _callbacks_skipped() -> bool:
	var f := _new_funnel(5)
	f.set_slots({"handler": "KIRN-17", "designation": "newb4821", "handle": "", "origin": "", "doing": ""})
	f.stage = f.index_of("pitch")
	var seen: Array = []
	for i in range(8):
		var b := f._peek_script()
		if b.is_empty():
			break
		seen.append(String(b["id"]))
		f._beat_i += 1
	return not seen.has("b_pitch_cb_origin") and not seen.has("b_pitch_cb_doing") and seen.has("b_pitch_1") and seen.has("b_pitch_3")


func _drive_to(f: Funnel, stage_name: String, think: int = 2000) -> int:
	var t := 1000
	f.note_first_message(t)
	var answered := false
	var guard := 0
	while guard < 20000:
		guard += 1
		t += 250
		var act := f.poll(t)
		if f.stage_id() == stage_name and f.pending_wait():
			return t
		if f.pending_wait() and not answered:
			var line := _player_line(f, [], 0)
			f.on_player(line, t + think, "thread", [], [])
			f.note_line(t + think)
	return -1


func _idle_continues() -> bool:
	var f := _new_funnel(21)
	var t := _drive_to(f, "contact")
	var fired := false
	var idle_ms := int(_cfg["stages"][1]["idle_ms"])
	for i in range(int(idle_ms / 250) + 40):
		t += 250
		var act := f.poll(t)
		if not act.is_empty() and String(act["kind"]) == "idle_followup":
			fired = true
			break
	var rx := f.on_player("hello", t + 500, "thread", [], [])
	return fired and String(rx["kind"]) == "model" and f.outcome.is_empty()


func _idle_lapses() -> bool:
	var f := _new_funnel(22)
	var t := _drive_to(f, "ask")
	var max_f := int(_cfg["stages"][6]["max_idle_followups"])
	var idle_ms := int(_cfg["stages"][6]["idle_ms"])
	var lapsed := false
	for i in range(int((idle_ms * (max_f + 2)) / 250) + 200):
		t += 250
		var act := f.poll(t)
		if not act.is_empty() and String(act["act"]) == "disengage":
			lapsed = true
			break
	return lapsed and f.outcome == Funnel.OUT_LAPSED and f.idle_lapse_followups == max_f and not f.entry_allowed()


func _pushback_idle_advances() -> bool:
	var f := _new_funnel(23)
	var t := _drive_to(f, "pushback")
	for i in range(4000):
		t += 250
		f.poll(t)
		if f.stage_id() == "dm":
			return f.outcome.is_empty()
	return false


func _refusal_stage(stage_name: String) -> bool:
	var f := _new_funnel(24)
	var t := _drive_to(f, stage_name)
	var rx := f.on_player("no thanks", t + 500, "thread", [], [])
	var after := f.poll(t + 20000)
	return String(rx["kind"]) == "refuse" and f.outcome == Funnel.OUT_REFUSED and after.is_empty() and not f.accepted and not f.disengage_beat(stage_name).is_empty()


func _reapproach() -> bool:
	var f := _new_funnel(25)
	var t := _drive_to(f, "ask")
	f.on_player("not interested", t + 500, "thread", [], [])
	var silent := f.on_player("hello", t + 900, "thread", [], [])
	var quiet_poll := f.poll(t + 600000)
	var rx := f.on_player("hello again", t + 700000, "other", [], [])
	f.reapproach(t + 700000)
	var act := {}
	var tt := t + 700000
	for i in range(200):
		tt += 250
		act = f.poll(tt)
		if not act.is_empty():
			break
	return String(silent["kind"]) == "none" and quiet_poll.is_empty() and String(rx["kind"]) == "reapproach" and String(act.get("beat_id", "")) == "b_contact_open" and f.stage_id() == "contact"


func _ask_other() -> bool:
	var f := _new_funnel(26)
	var t := _drive_to(f, "ask")
	var rx := f.on_player("maybe", t + 300, "thread", [], [])
	var act := {}
	var tt := t + 300
	for i in range(400):
		tt += 250
		act = f.poll(tt)
		if not act.is_empty():
			break
	return String(rx["kind"]) == "model" and String(act.get("kind", "")) == "reask" and not f.accepted and f.stage_id() == "ask"


func _redirects_capped() -> bool:
	var f := _new_funnel(27)
	var t := _drive_to(f, "dm")
	var got := 0
	for i in range(5):
		var rx := f.on_player("hello room", t + 100 * i, "other", [], [])
		if String(rx["kind"]) == "redirect":
			got += 1
	return got == int(_cfg["max_redirects"]) and f.stage_id() == "dm"


func _withheld() -> bool:
	var f := _new_funnel(28)
	var t := _drive_to(f, "pushback")
	var rx := f.on_player("where is this", t + 200, "thread", [], [])
	var beat: Dictionary = rx.get("beat", {})
	return String(rx["kind"]) == "withhold" and String(beat.get("kind", "")) == "withhold" and String(beat.get("plain", "")).to_lower().contains("when")


func _premature_yes() -> bool:
	var f := _new_funnel(41)
	var t := _drive_to(f, "pitch")
	f.on_player("that makes sense", t + 300, "thread", [], [])
	var rx := f.on_player("yes", t + 600, "thread", [], [])
	return f.stage_id() == "ask" and not f.accepted and String(rx["kind"]) != "consent"


func _premature_handle() -> bool:
	var f := _new_funnel(42)
	var t := _drive_to(f, "ask")
	f.on_player("yes", t + 300, "thread", [], [])
	var rx := f.on_player("ember_7", t + 600, "thread", [], [])
	return f.stage_id() == "rename" and f.handle.is_empty() and String(rx["kind"]) != "handle_ok"


func _resume_ok() -> bool:
	var a := _new_funnel(31)
	a.resume_at("rename")
	a.note_first_message(1000)
	var act_a := {}
	var t := 1000
	for i in range(400):
		t += 250
		act_a = a.poll(t)
		if not act_a.is_empty():
			break
	var b := _new_funnel(32)
	b.resume_at("launch")
	b.handle = "ember"
	return a.stage_id() == "rename" and String(act_a.get("beat_id", "")) == "b_rn_open" and b.stage_id() == "launch" and b.entry_allowed()


func _inert_ok() -> bool:
	var f := _new_funnel(33)
	f.mark_inert()
	return f.poll(99999999).is_empty() and String(f.on_player("hello", 5, "thread", [], [])["kind"]) == "none" and not f.entry_allowed()


func _skip_detected(trans: Array) -> bool:
	for tr in trans:
		if int(tr[1]) != int(tr[0]) + 1:
			return true
	return false


func _launch_invariant_broken(accepted: bool, handle: String) -> bool:
	return not accepted or handle.is_empty()


## --- fuzz -------------------------------------------------------------------------------------------------------------

func _t_fuzz() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 573
	var trials := 6000
	var skips := 0
	var no_consent := 0
	var no_rename := 0
	var launched := 0
	var refused := 0
	var lapsed := 0
	var rejected := 0
	var consent := 0
	var reapp := 0
	var pool := ["hello", "yes", "no", "maybe", "ember_7", "x", "stop", "yes but", "i accept", "tell me more", "where is this", "no thanks", "a b", "i am from here", "reading"]
	for trial in range(trials):
		var f := Funnel.new()
		f.setup(_cfg, _beats, trial)
		f.set_slots({"handler": "KIRN-17", "designation": "newb4821", "handle": "", "origin": "", "doing": ""})
		var mode := trial % 3
		var t := 0
		f.note_first_message(500)
		var steps := rng.randi_range(40, 700)
		var seen_lapse := false
		for s in range(steps):
			t += [250, 1000, 6000, 30000][rng.randi_range(0, 3)]
			var act := f.poll(t)
			if String(act.get("act", "")) == "launch":
				launched += 1
				if not f.accepted:
					no_consent += 1
				if f.handle.is_empty():
					no_rename += 1
			if f.outcome == Funnel.OUT_LAPSED and not seen_lapse:
				seen_lapse = true
				lapsed += 1
			var speak := false
			if mode == 0:
				speak = f.pending_wait() and rng.randf() < 0.7
			elif mode == 1:
				speak = rng.randf() < 0.3
			else:
				speak = f.pending_wait() and rng.randf() < 0.4
			if speak:
				var line := String(pool[rng.randi_range(0, pool.size() - 1)])
				if mode == 0:
					line = _player_line(f, [], 0)
				var before := f.rejected_moves
				var stage_before := f.stage_id()
				var where := "thread" if rng.randf() < 0.85 else "other"
				var rx := f.on_player(line, t, where, [], _names["reserved"])
				rejected += f.rejected_moves - before
				match String(rx["kind"]):
					"consent":
						consent += 1
						if stage_before != "ask":
							no_consent += 1
					"refuse":
						refused += 1
					"reapproach":
						reapp += 1
						f.reapproach(t)
						seen_lapse = false
					"handle_ok":
						f.set_slot("handle", String(rx["handle"]))
				if String(rx["kind"]) in ["model", "answer", "withhold"]:
					f.note_line(t + 2000)
		for tr in f.transitions:
			if int(tr[1]) != int(tr[0]) + 1:
				skips += 1
	print("FUNNEL_FUZZ trials=%d stage_skips=%d launch_without_consent=%d launch_without_rename=%d reached_launch=%d refused=%d lapsed=%d rejected_moves=%d consent_hits=%d reapproached=%d" % [trials, skips, no_consent, no_rename, launched, refused, lapsed, rejected, consent, reapp])
	_ok("fuzz_no_skips_and_every_outcome_hit", skips == 0 and no_consent == 0 and no_rename == 0 and launched >= 1 and refused >= 1 and lapsed >= 1 and rejected >= 1 and consent >= 1 and reapp >= 1)
	_neg("fuzz_skip_counter_has_teeth", _skip_detected([[0, 1], [1, 3]]))
