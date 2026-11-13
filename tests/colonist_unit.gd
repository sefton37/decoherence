extends SceneTree

## Unit tests for the HANDLER module core (Spec #575): the colonist generator, its
## validator, the frozen-until-invalid store rule, the view model and the layout. No
## scene, no model, no GPU, no clock: every function under test takes its inputs as
## arguments. Run via tests/verify_colonist_unit.sh. Output contract (parsed by the DoD):
##   COLONIST_UNIT_OK <name>           one per passing unit
##   COLONIST_UNIT_FAIL <name>: <why>  any failure (the script exits 1)
##   COLONIST_NEGCTL_OK <name>         a deliberately broken stub IS caught by the same check
##   COLONIST_DET / FUZZ / NEGCTL / PROV / ADULT / STORE   key=value summary lines the DoD reads

const CTX := {"handler": "KIRN-17", "handle": "Ember_77"}
const SCRATCH := "user://colonist_unit_profile.json"

var _failed: int = 0
var _t: Dictionary = {}
var _r: Dictionary = {}
var _ui: Dictionary = {}
var _route: Dictionary = {}


func _init() -> void:
	var data := ProfileStore.load_handler_data()
	_t = data.get("tables", {})
	_r = data.get("rules", {})
	_ui = data.get("ui", {})
	_route = data.get("route", {})
	_ok("data_loads", bool(data.get("ok", false)) and not _t.is_empty() and not _r.is_empty() and not _ui.is_empty() and not _route.is_empty(), "handler data missing")
	if _failed > 0:
		quit(1)
		return
	_t_seed()
	_t_dossier_shape()
	_t_rules_hold()
	_t_provenance_units()
	_t_validate_units()
	_t_ensure_units()
	_t_view_and_layout()
	_s_det()
	_s_fuzz()
	_s_negctl()
	_s_prov()
	_s_adult()
	_s_store()
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, why: String = "") -> void:
	if cond:
		print("COLONIST_UNIT_OK " + name)
	else:
		_failed += 1
		print("COLONIST_UNIT_FAIL %s: %s" % [name, why])


func _neg(name: String, caught: bool) -> void:
	if caught:
		print("COLONIST_NEGCTL_OK " + name)
	else:
		_failed += 1
		print("COLONIST_UNIT_FAIL negctl_%s: the broken stub was NOT caught" % name)


func _gen(seed_value: int) -> Dictionary:
	var g := ColonistGen.generate_ex(seed_value, _t, _r, CTX)
	return g["dossier"] if bool(g.get("ok", false)) else {}


func _clean() -> Dictionary:
	return _gen(ColonistGen.seed_for("newb4821", "KIRN-17"))


## --- seed ---------------------------------------------------------------------------------------------

func _t_seed() -> void:
	var a := ColonistGen.seed_for("newb4821", "KIRN-17")
	_ok("seed_is_stable", a == ColonistGen.seed_for("newb4821", "KIRN-17") and a >= 0, "seed changed between calls")
	_ok("seed_differs_by_designation", a != ColonistGen.seed_for("newb4822", "KIRN-17"), "same seed for two designations")
	_ok("seed_differs_by_handler", a != ColonistGen.seed_for("newb4821", "KIRN-18"), "same seed for two handlers")
	_ok("seed_not_symmetric", ColonistGen.seed_for("ab", "cd") != ColonistGen.seed_for("abc", "d"), "the join is ambiguous")


## --- the dossier ------------------------------------------------------------------------------------

func _t_dossier_shape() -> void:
	var d := _clean()
	_ok("generate_succeeds", not d.is_empty(), "no dossier")
	var f: Dictionary = d.get("fields", {})
	var ids := ColonistGen.field_ids(_r)
	_ok("rules_name_22_fields", ids.size() == 22, "rules name %d fields" % ids.size())
	var missing := 0
	for id in ids:
		if not f.has(id):
			missing += 1
	_ok("dossier_has_every_rule_field", missing == 0 and f.size() == ids.size(), "%d missing, %d present" % [missing, f.size()])
	var sections: Array = []
	for s in _r["sections"]:
		sections.append(String(s["id"]))
	var strays := 0
	for fd in _r["fields"]:
		if not sections.has(String(fd["section"])):
			strays += 1
	_ok("every_field_is_in_a_section", strays == 0, "%d fields in no section" % strays)
	_ok("template_version_recorded", int(d.get("template_version", 0)) == int(_r["template_version"]), "version missing")
	var cid := String(f.get("colonist_id", ""))
	_ok("colonist_id_has_prefix", cid.begins_with(String(_r["id_prefix"])) and cid.length() > String(_r["id_prefix"]).length(), cid)
	_ok("handler_fields_from_context", String(f["handler_of_record"]) == "KIRN-17" and String(f["assisted_by"]) == "Ember_77", "profile fields not carried")
	_ok("same_seed_same_dossier", JSON.stringify(d) == JSON.stringify(_clean()), "two runs differ")
	_ok("different_seed_different_dossier", JSON.stringify(d) != JSON.stringify(_gen(ColonistGen.seed_for("newb9999", "KIRN-17"))), "two seeds agree")


func _t_rules_hold() -> void:
	var bad_age := 0
	var bad_years := 0
	var bad_prof := 0
	var bad_hub := 0
	var bad_trait := 0
	var bad_slot := 0
	var bad_service := 0
	for i in range(300):
		var d := _gen(ColonistGen.seed_for("newb%d" % (2000 + i), "H-%d" % i))
		var f: Dictionary = d["fields"]
		var age := int(f["age"])
		if age < int(_r["age"]["min"]) or age > int(_r["age"]["max"]):
			bad_age += 1
		var yrs := int(f["years_resident"])
		if yrs < int(_r["years_resident"]["min"]) or yrs > age - int(_r["years_resident"]["arrival_age_min"]):
			bad_years += 1
		var prof := {}
		for p in _t["professions"]:
			if String(p["label"]) == String(f["profession"]):
				prof = p
		if prof.is_empty() or age < int(prof["min_age"]):
			bad_prof += 1
		var kind := ""
		for h in _t["hubs"]:
			if String(h["name"]) == String(f["hub"]):
				kind = String(h["kind"])
		if prof.is_empty() or not (prof["hub_kinds"] as Array).has(kind):
			bad_hub += 1
		var tl: Array = [String(f["trait_1"]), String(f["trait_2"]), String(f["trait_3"])]
		if tl[0] == tl[1] or tl[0] == tl[2] or tl[1] == tl[2]:
			bad_trait += 1
		for a in tl:
			for b in tl:
				for tr in _t["traits"]:
					if String(tr["label"]) == a and (tr["excludes"] as Array).has(b):
						bad_trait += 1
		if String(f["bio"]).contains("{") or String(f["bio"]).contains("}") or String(f["bio"]).length() < 40:
			bad_slot += 1
		if String(f["service_status"]) != String(_r["service"]["status"]) or String(f["specialization"]) != String(_r["service"]["specialization"]):
			bad_service += 1
	_ok("age_within_rule", bad_age == 0, "%d out of range" % bad_age)
	_ok("years_within_rule", bad_years == 0, "%d violate the years rule" % bad_years)
	_ok("profession_fits_age", bad_prof == 0, "%d too young for the work" % bad_prof)
	_ok("profession_fits_hub_kind", bad_hub == 0, "%d do not fit the hub kind" % bad_hub)
	_ok("traits_distinct_and_compatible", bad_trait == 0, "%d trait violations" % bad_trait)
	_ok("bio_has_no_unresolved_slot", bad_slot == 0, "%d bios with a bare slot or no text" % bad_slot)
	_ok("service_and_specialization_constants", bad_service == 0, "%d violate the service rule" % bad_service)


func _t_provenance_units() -> void:
	var d := _clean()
	var f: Dictionary = d["fields"]
	var src: Dictionary = d["src"]
	var unsourced := 0
	for id in ColonistGen.field_ids(_r):
		if not src.has(id) or not (src[id] as Dictionary).has("kind"):
			unsourced += 1
	_ok("every_field_has_a_source", unsourced == 0, "%d unsourced" % unsourced)
	var off := 0
	for fd in _r["fields"]:
		if String(fd["src_kind"]) == "table":
			var s: Dictionary = src[String(fd["id"])]
			if ColonistGen.table_entry_text(_t, String(s["table"]), int(s["index"])) != String(f[String(fd["id"])]):
				off += 1
	_ok("table_values_equal_their_table_entry", off == 0, "%d fields differ from their table entry" % off)
	_ok("bio_rerenders_from_its_templates", ColonistGen.render_bio(d, _t) == String(f["bio"]), "re-render differs")
	var parts: Array = src["bio"]["parts"]
	_ok("bio_parts_follow_rules_order", parts.size() == (_r["bio_parts"] as Array).size() and String(parts[0]["part"]) == String(_r["bio_parts"][0]), "part order")
	var pair := ColonistGen.generate_ex(7, _t, _r, CTX)
	_ok("generate_reports_its_rejections", (pair["rejects"] as Dictionary).has("age") and (pair["rejects"] as Dictionary).has("slot"), "no rejection counters")


func _t_validate_units() -> void:
	var d := _clean()
	_ok("validate_passes_a_clean_colonist_strict", ColonistGen.validate(d, _t, _r, true).is_empty(), str(ColonistGen.validate(d, _t, _r, true)))
	_ok("validate_passes_a_clean_colonist_lenient", ColonistGen.validate(d, _t, _r, false).is_empty(), str(ColonistGen.validate(d, _t, _r, false)))
	var minor := d.duplicate(true)
	minor["fields"]["age"] = 17
	_ok("validate_flags_a_minor", ColonistGen.validate(minor, _t, _r, true).has("age") and ColonistGen.validate(minor, _t, _r, false).has("age"), "age 17 passed")
	var open := d.duplicate(true)
	open["fields"]["bio"] = "{given_name} is here."
	_ok("validate_flags_a_bare_slot", ColonistGen.validate(open, _t, _r, false).has("slot"), "a bare slot passed")
	var gone := d.duplicate(true)
	gone["fields"].erase("orientation")
	_ok("validate_flags_a_missing_field", ColonistGen.validate(gone, _t, _r, false).has("field_set"), "a missing field passed")
	var longer := d.duplicate(true)
	longer["fields"]["private_line"] = "x".repeat(int(_r["intimate_max_len"]) + 1)
	_ok("validate_flags_an_overlong_intimate_value", ColonistGen.validate(longer, _t, _r, false).has("intimate_len"), "an overlong value passed")
	_ok("validate_ignores_non_dossier", not ColonistGen.validate({}, _t, _r, false).is_empty(), "an empty dictionary passed")


## --- the store rule ---------------------------------------------------------------------------------

func _profile() -> Dictionary:
	var p := ProfileStore.new_profile("newb4821", "KIRN-17")
	p["player"]["handle"] = "Ember_77"
	p["acceptance"] = {"accepted": true, "handler": "KIRN-17", "handle": "Ember_77", "launched": true}
	return p


func _t_ensure_units() -> void:
	var e := ColonistGen.ensure(_profile(), _t, _r)
	_ok("ensure_generates_when_empty", bool(e["regenerated"]) and (e["profile"]["assignments"] as Array).size() == 1, "nothing generated")
	var stored: Dictionary = e["profile"]
	var again := ColonistGen.ensure(stored, _t, _r)
	_ok("ensure_keeps_a_valid_colonist", not bool(again["regenerated"]) and JSON.stringify(again["profile"]["assignments"]) == JSON.stringify(stored["assignments"]), "a valid colonist was replaced")
	var t2: Dictionary = _t.duplicate(true)
	(t2["given_names"] as Array).append("Zzyzx")
	var r2: Dictionary = _r.duplicate(true)
	r2["template_version"] = int(_r["template_version"]) + 1
	var frozen := ColonistGen.ensure(stored, t2, r2)
	_ok("ensure_freezes_against_data_edits", not bool(frozen["regenerated"]) and JSON.stringify(frozen["profile"]["assignments"]) == JSON.stringify(stored["assignments"]), "a data edit changed the colonist")
	var bad: Dictionary = stored.duplicate(true)
	bad["assignments"][0]["fields"]["age"] = 15
	bad["acceptance"]["mission_accepted"] = true
	var fixed := ColonistGen.ensure(bad, _t, _r)
	_ok("ensure_regenerates_a_tampered_colonist", bool(fixed["regenerated"]) and ColonistGen.validate(fixed["profile"]["assignments"][0], _t, _r, true).is_empty(), "tamper survived")
	_ok("ensure_clears_acceptance_when_it_regenerates", bool(fixed["cleared_acceptance"]) and not bool(fixed["profile"]["acceptance"].get("mission_accepted", false)), "a stale acceptance survived")
	var kept: Dictionary = stored.duplicate(true)
	kept["acceptance"]["mission_accepted"] = true
	var k2 := ColonistGen.ensure(kept, _t, _r)
	_ok("ensure_keeps_acceptance_when_valid", not bool(k2["regenerated"]) and bool(k2["profile"]["acceptance"].get("mission_accepted", false)), "acceptance lost")
	var two: Dictionary = stored.duplicate(true)
	two["assignments"].append(two["assignments"][0].duplicate(true))
	var one := ColonistGen.ensure(two, _t, _r)
	_ok("ensure_collapses_extra_assignments", (one["profile"]["assignments"] as Array).size() == 1, "extra assignments kept")
	var keys: Dictionary = stored.duplicate(true)
	keys["future_key"] = {"a": 1}
	keys["player"]["future_player_key"] = "x"
	var kk := ColonistGen.ensure(keys, _t, _r)
	_ok("ensure_keeps_unknown_keys", kk["profile"].has("future_key") and kk["profile"]["player"].has("future_player_key"), "unknown keys dropped")
	_ok("mission_accepted_helper", not ProfileStore.mission_accepted(stored) and ProfileStore.mission_accepted(kept), "helper wrong")
	_ok("new_profile_shape_unchanged", (ProfileStore.new_profile("a", "b")["acceptance"].keys() as Array).size() == 4, "573 shape moved")


## --- the view model and the layout ------------------------------------------------------------------

func _t_view_and_layout() -> void:
	var p := _profile()
	var ens := ColonistGen.ensure(p, _t, _r, CTX)
	p = ens["profile"]
	var view := HandlerView.build(p, {"origin": "the north coast", "doing": "stacking shelves"}, _ui, _r)
	var dossier_rows := 0
	for sec in view["dossier"]:
		dossier_rows += (sec["rows"] as Array).size()
	_ok("view_has_every_dossier_field", dossier_rows == ColonistGen.field_ids(_r).size(), "%d rows" % dossier_rows)
	_ok("view_profile_has_nine_fields", (view["profile"] as Array).size() == 9, "%d profile rows" % (view["profile"] as Array).size())
	_ok("view_title_carries_handle", String(view["handle"]) == "Ember_77", String(view["handle"]))
	var lines := HandlerView.dossier_lines(view, 60)
	var wide := 0
	for l in lines:
		if String(l["t"]).length() > 60:
			wide += 1
	_ok("dossier_lines_fit_the_pane", wide == 0 and lines.size() > dossier_rows, "%d lines too wide" % wide)
	var plines := HandlerView.profile_lines(view, 38)
	var pwide := 0
	var stacked_kinds := 0
	for l in plines:
		if String(l["t"]).length() > 38:
			pwide += 1
		if String(l["kind"]) == "label" or String(l["kind"]) == "value":
			stacked_kinds += 1
	_ok("narrow_profile_pane_stacks_its_fields", pwide == 0 and stacked_kinds == plines.size() and plines.size() >= 18, "%d wide, %d stacked of %d" % [pwide, stacked_kinds, plines.size()])
	var wide_profile := HandlerView.profile_lines(view, 90)
	_ok("wide_profile_pane_sits_side_by_side", String(wide_profile[0]["kind"]) == "field" and wide_profile.size() < plines.size(), "side by side expected")
	var hostile := HandlerView.wrap_text("{x}{y}" + "Q".repeat(70) + " {braces}", 20)
	var over := 0
	for l in hostile:
		if String(l).length() > 20:
			over += 1
	_ok("wrap_breaks_a_hostile_word", over == 0 and hostile.size() >= 4, "%d rows over, %d rows" % [over, hostile.size()])
	_ok("wrap_keeps_braces_literal", " ".join(PackedStringArray(hostile)).contains("{braces}"), "braces changed")
	_ok("max_scroll_math", HandlerView.max_scroll(40, 31) == 9 and HandlerView.max_scroll(10, 31) == 0, "scroll bound")
	var cell := ChatLayout.CELL_W
	var overlaps := 0
	var oob := 0
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(1920 / 1, 1080)]:
		var lay := HandlerLayout.compute(size.x, size.y, 20)
		overlaps += HandlerLayout.overlap_count(HandlerLayout.rect_list(lay))
		oob += HandlerLayout.out_of_bounds_count(HandlerLayout.rect_list(lay), int(lay["cols"]), int(lay["rows"]))
	_ok("layout_has_no_overlap_or_overflow", overlaps == 0 and oob == 0, "%d overlaps, %d out of bounds" % [overlaps, oob])
	var l1 := HandlerLayout.compute(1280, 720, 20)
	_ok("layout_cell_grid_is_the_chat_grid", int(l1["cols"]) == 1280 / cell and int(l1["rows"]) == 720 / ChatLayout.CELL_H, "grid differs")
	_ok("layout_full_tier_panes", String(l1["tier"]) == "full" and (l1["dossier"] as Rect2i).size.x >= 60 and (l1["profile"] as Rect2i).size.x >= 34, "pane widths")
	var lo := HandlerLayout.compute(1000, 600, 20)
	_ok("layout_folds_below_the_minimum", String(lo["tier"]) != "full" and ((lo["profile"] as Rect2i).size.x == 0 or (lo["dossier"] as Rect2i).size.x == 0), "did not fold")
	var big := HandlerLayout.compute(1920, 1080, 20)
	_ok("layout_scales_with_the_canvas", int(big["cols"]) == 192 and int(big["rows"]) == 54, "%d x %d" % [int(big["cols"]), int(big["rows"])])
	var shifted := HandlerLayout.compute(1920, 1080, 20)
	var d: Rect2i = shifted["dossier"]
	shifted["dossier"] = Rect2i(d.position.x + 5, d.position.y, d.size.x, d.size.y)
	_neg("layout_overlap_counter_has_teeth", HandlerLayout.overlap_count(HandlerLayout.rect_list(shifted)) > 0)
	var wide_lines := [{"t": "x".repeat(61), "kind": "field", "id": ""}]
	var counted := 0
	for l in wide_lines:
		if String(l["t"]).length() > 60:
			counted += 1
	_neg("line_width_check_has_teeth", counted == 1)


## --- summary: determinism ---------------------------------------------------------------------------

func _s_det() -> void:
	var pairs := 500
	var equal := 0
	var seen := {}
	for i in range(pairs):
		var des := "newb%d" % (1000 + i * 7)
		var hn := "HNDL-%d" % (i * 13 + 1)
		var s := ColonistGen.seed_for(des, hn)
		var a := JSON.stringify(_gen(s))
		var b := JSON.stringify(_gen(s))
		var c := JSON.stringify(_gen(ColonistGen.seed_for(des, hn)))
		if a == b and b == c and a != "{}":
			equal += 1
		seen[a.sha256_text()] = true
	var sens := 1
	for i in range(50):
		var x := JSON.stringify(_gen(ColonistGen.seed_for("newb%d" % (500 + i), "HNDL-9")))
		var y := JSON.stringify(_gen(ColonistGen.seed_for("newc%d" % (500 + i), "HNDL-9")))
		if x == y:
			sens = 0
	print("COLONIST_DET pairs=%d repeat3_equal=%d distinct_colonists=%d seed_sensitive=%d" % [pairs, equal, seen.size(), sens])
	_ok("determinism_summary", equal == pairs and seen.size() >= int(pairs * 0.99) and sens == 1, "det")


## --- summary: fuzz ----------------------------------------------------------------------------------

func _s_fuzz() -> void:
	var trials := 5000
	var violations := 0
	var complete := 0
	var hits := {"age": 0, "years": 0, "profession_age": 0, "trait_exclusion": 0, "hub_kind": 0, "slot": 0}
	var ids := ColonistGen.field_ids(_r)
	for i in range(trials):
		var g := ColonistGen.generate_ex(ColonistGen.seed_for("fz%d" % i, "FZ-%d" % (i % 97)), _t, _r, CTX)
		if not bool(g.get("ok", false)):
			continue
		var d: Dictionary = g["dossier"]
		var ok := true
		for id in ids:
			if not (d["fields"] as Dictionary).has(id):
				ok = false
		if ok:
			complete += 1
		if not ColonistGen.validate(d, _t, _r, true).is_empty():
			violations += 1
		for k in hits:
			hits[k] += int(g["rejects"].get(k, 0))
	print("COLONIST_FUZZ trials=%d violations=%d colonists_complete=%d hit_age=%d hit_years=%d hit_profession_age=%d hit_trait_exclusion=%d hit_hub_kind=%d hit_slot=%d" % [trials, violations, complete, hits["age"], hits["years"], hits["profession_age"], hits["trait_exclusion"], hits["hub_kind"], hits["slot"]])
	_ok("fuzz_summary", violations == 0 and complete == trials and int(hits["age"]) > 0 and int(hits["years"]) > 0 and int(hits["profession_age"]) > 0 and int(hits["trait_exclusion"]) > 0 and int(hits["hub_kind"]) > 0 and int(hits["slot"]) > 0, "fuzz")
	_neg("fuzz_validator_has_teeth", not ColonistGen.validate(_planted_age(), _t, _r, true).is_empty())


## --- summary: planted violations --------------------------------------------------------------------

func _planted_age() -> Dictionary:
	var d := _clean().duplicate(true)
	d["fields"]["age"] = 17
	return d


func _plants() -> Array:
	var out: Array = []
	var d := _clean()
	var make := func(owner: String, edit: Callable) -> void:
		var c := d.duplicate(true)
		edit.call(c)
		out.append({"owner": owner, "dossier": c})
	make.call("age", func(c): c["fields"]["age"] = 17)
	make.call("age", func(c): c["fields"]["age"] = int(_r["age"]["max"]) + 1)
	make.call("years", func(c):
		c["fields"]["age"] = 30
		c["fields"]["years_resident"] = 30)
	make.call("years", func(c): c["fields"]["years_resident"] = 0)
	make.call("profession_age", func(c):
		c["fields"]["age"] = 22
		c["fields"]["years_resident"] = 2
		c["fields"]["profession"] = "shift controller")
	make.call("hub_kind", func(c): c["fields"]["profession"] = "survey runner")
	make.call("trait_exclusion", func(c):
		c["fields"]["trait_1"] = "cautious"
		c["fields"]["trait_2"] = "reckless"
		c["fields"]["trait_3"] = "warm")
	make.call("trait_count", func(c):
		c["fields"]["trait_1"] = "warm"
		c["fields"]["trait_2"] = "warm"
		c["fields"]["trait_3"] = "wry")
	make.call("slot", func(c): c["fields"]["bio"] = String(c["fields"]["bio"]) + " {unresolved}")
	make.call("bio", func(c): c["fields"]["bio"] = "A free text sentence the templates never produced.")
	make.call("intimate_set", func(c): c["fields"]["orientation"] = "not a member of the closed set")
	make.call("service", func(c): c["fields"]["service_status"] = "conscript")
	make.call("specialization", func(c): c["fields"]["specialization"] = "farming")
	make.call("field_set", func(c): c["fields"].erase("history_band"))
	make.call("src", func(c): c["fields"]["given_name"] = "Nonesuch")
	return out


func _s_negctl() -> void:
	var plants := _plants()
	var detected := 0
	var matched := 0
	for p in plants:
		var v := ColonistGen.validate(p["dossier"], _t, _r, true)
		if not v.is_empty():
			detected += 1
		if v.has(String(p["owner"])):
			matched += 1
	var clean := 1 if ColonistGen.validate(_clean(), _t, _r, true).is_empty() else 0
	print("COLONIST_NEGCTL planted=%d detected=%d rule_id_match=%d clean_passes=%d" % [plants.size(), detected, matched, clean])
	_ok("negctl_summary", plants.size() >= 14 and detected == plants.size() and matched == plants.size() and clean == 1, "negctl")
	# the same check with the owning rule removed from the validator would miss its plant
	var r2: Dictionary = _r.duplicate(true)
	r2["age"]["min"] = 0
	_neg("age_rule_removed_misses_the_minor", not ColonistGen.validate(_planted_age(), _t, r2, true).has("age"))


## --- summary: provenance ----------------------------------------------------------------------------

func _s_prov() -> void:
	var n := 3000
	var unsourced := 0
	var off := 0
	var rerender := 0
	var free := 0
	var kinds := ["table", "range", "derived", "rule", "profile", "assembly"]
	for i in range(n):
		var d := _gen(ColonistGen.seed_for("pv%d" % i, "PV-%d" % (i % 31)))
		var src: Dictionary = d["src"]
		for fd in _r["fields"]:
			var id := String(fd["id"])
			if not src.has(id):
				unsourced += 1
				continue
			var kind := String(src[id].get("kind", ""))
			if not kinds.has(kind):
				free += 1
			if kind == "table" and ColonistGen.table_entry_text(_t, String(src[id]["table"]), int(src[id]["index"])) != String(d["fields"][id]):
				off += 1
		if ColonistGen.render_bio(d, _t) == String(d["fields"]["bio"]):
			rerender += 1
	print("COLONIST_PROV colonists=%d unsourced_fields=%d value_not_in_table=%d bio_rerender_equal=%d free_text_fields=%d" % [n, unsourced, off, rerender, free])
	_ok("prov_summary", unsourced == 0 and off == 0 and rerender == n and free == 0, "prov")


## --- summary: adults and the closed sets ------------------------------------------------------------

func _s_adult() -> void:
	var trials := 5000
	var min_age := 1000
	var under := 0
	var out_of_set := 0
	var len_max := 0
	for i in range(trials):
		var d := _gen(ColonistGen.seed_for("ad%d" % i, "AD-%d" % (i % 53)))
		var f: Dictionary = d["fields"]
		min_age = mini(min_age, int(f["age"]))
		if int(f["age"]) < 21:
			under += 1
		for k in ["relationship_status", "orientation", "history_band", "private_line"]:
			if not (_t["intimate"][k] as Array).has(String(f[k])):
				out_of_set += 1
			len_max = maxi(len_max, String(f[k]).length())
	var minor_caught := 1 if ColonistGen.validate(_planted_age(), _t, _r, true).has("age") else 0
	print("COLONIST_ADULT trials=%d min_age=%d under_min=%d intimate_out_of_set=%d intimate_len_max=%d control_minor_detected=%d" % [trials, min_age, under, out_of_set, len_max, minor_caught])
	_ok("adult_summary", min_age >= 21 and under == 0 and out_of_set == 0 and len_max <= 60 and minor_caught == 1, "adult")


## --- summary: the store -----------------------------------------------------------------------------

func _s_store() -> void:
	var p: Dictionary = ColonistGen.ensure(_profile(), _t, _r, CTX)["profile"]
	ProfileStore.save_profile(p, SCRATCH)
	var back := ProfileStore.load_profile(SCRATCH)
	var roundtrip := 1 if String(back["status"]) == "ok" and JSON.stringify(back["profile"]) == JSON.stringify(JSON.parse_string(JSON.stringify(p))) else 0
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))
	var regen: Dictionary = ColonistGen.generate_ex(ColonistGen.seed_for("newb4821", "KIRN-17"), _t, _r, CTX)["dossier"]
	var regen_equal := 1 if JSON.stringify(regen) == JSON.stringify(p["assignments"][0]) else 0
	var t2: Dictionary = _t.duplicate(true)
	(t2["family_names"] as Array).append("Zzyzx")
	var r2: Dictionary = _r.duplicate(true)
	r2["template_version"] = int(_r["template_version"]) + 1
	var frozen := ColonistGen.ensure(p, t2, r2)
	var frozen_ok := 1 if not bool(frozen["regenerated"]) and JSON.stringify(frozen["profile"]["assignments"][0]) == JSON.stringify(p["assignments"][0]) else 0
	var bad: Dictionary = p.duplicate(true)
	bad["assignments"][0]["fields"]["age"] = 15
	bad["acceptance"]["mission_accepted"] = true
	var tamper_detected := 1 if not ColonistGen.validate(bad["assignments"][0], _t, _r, false).is_empty() else 0
	var fixed := ColonistGen.ensure(bad, _t, _r, CTX)
	var tamper_valid := 1 if bool(fixed["regenerated"]) and ColonistGen.validate(fixed["profile"]["assignments"][0], _t, _r, true).is_empty() else 0
	var cleared := 1 if bool(fixed["cleared_acceptance"]) and not ProfileStore.mission_accepted(fixed["profile"]) else 0
	var kept: Dictionary = p.duplicate(true)
	kept["acceptance"]["mission_accepted"] = true
	var k2 := ColonistGen.ensure(kept, _t, _r, CTX)
	var kept_ok := 1 if not bool(k2["regenerated"]) and ProfileStore.mission_accepted(k2["profile"]) else 0
	print("COLONIST_STORE roundtrip_equal=%d regen_equal_stored=%d frozen_kept_on_template_change=%d tamper_detected=%d tamper_regenerated_valid=%d accepted_cleared_on_regen=%d accepted_kept_when_valid=%d assignments_len=%d" % [roundtrip, regen_equal, frozen_ok, tamper_detected, tamper_valid, cleared, kept_ok, (k2["profile"]["assignments"] as Array).size()])
	_ok("store_summary", roundtrip == 1 and regen_equal == 1 and frozen_ok == 1 and tamper_detected == 1 and tamper_valid == 1 and cleared == 1 and kept_ok == 1, "store")
