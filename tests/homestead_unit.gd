extends SceneTree
## SPDX-License-Identifier: AGPL-3.0-only
## Unit and fuzz harness for the homestead site generator (Spec 576 slice S1). No scene, no engine
## class, no GPU: the generator is a pure function of (site seed, two data files). It runs the same
## fixed set of colonist ids, hashes every layout, and writes ONE record the DoD's jq reads, named
## unit_run_N.json inside OUT_DIR (N is UNIT_RUN; tests/verify_homestead_unit.sh runs this three
## times, in three processes, and merges the records into unit.json).
## The record carries measurements only; the DoD judges. Every detector has a negative control that
## must fire (a clock or global-RNG mutation, planted layout violations), so a broken checker cannot
## pass silently.
##
## Env: OUT_DIR (required), UNIT_RUN (default 1)

const HomesteadSite := preload("res://game/homestead/homestead_site.gd")
const TEMPLATE_PATH := "res://game/homestead/data/site_template.json"
const EQUIPMENT_PATH := "res://game/homestead/data/starter_equipment.json"
const IDS := 220
const FUZZ_TRIALS := 2000
const YAW_BIN_DEG := 2.0

var _fail := 0


static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}


static func _flat(_x: float, _z: float) -> float:
	return 0.0


func _check(name: String, ok: bool, why: String = "") -> void:
	if ok:
		print("HOMESTEAD_UNIT_OK ", name)
	else:
		_fail += 1
		print("HOMESTEAD_UNIT_FAIL ", name, ": ", why)


static func _layout(seed_v: int, tpl: Dictionary, eq: Dictionary) -> Dictionary:
	return HomesteadSite.generate(seed_v, tpl, eq, _flat)


## A deep copy, so a mutation never leaks into the base data.
static func _copy(d: Dictionary) -> Dictionary:
	return d.duplicate(true)


## What a clock-reading generator would do: shift one pose by the wall clock, then digest.
static func _digest_with_clock(layout: Dictionary) -> String:
	var l := _copy(layout)
	l["items"][0]["x"] = float(l["items"][0]["x"]) + float(Time.get_ticks_usec() % 997) * 0.001 + 0.001
	return HomesteadSite.layout_digest(l)


## What a global-RNG generator would do: shift one pose by a global random draw, then digest.
static func _digest_with_global_rng(layout: Dictionary) -> String:
	var l := _copy(layout)
	l["items"][0]["x"] = float(l["items"][0]["x"]) + randf() + 0.001
	return HomesteadSite.layout_digest(l)


func _init() -> void:
	var out_dir := OS.get_environment("OUT_DIR")
	if out_dir.is_empty():
		print("HOMESTEAD_UNIT_FAIL setup: OUT_DIR is required")
		quit(2)
		return
	var run_ix := OS.get_environment("UNIT_RUN")
	if run_ix.is_empty():
		run_ix = "1"
	var tpl := _load_json(TEMPLATE_PATH)
	var eq := _load_json(EQUIPMENT_PATH)
	_check("data_loaded", not tpl.is_empty() and not eq.is_empty(), "a data file is missing or invalid")
	if tpl.is_empty() or eq.is_empty():
		quit(1)
		return
	var rec := {}

	# --- determinism over a fixed id set; the run digest is hashed over every layout digest
	var digests := PackedStringArray()
	var seen := {}
	for i in range(IDS):
		var lay := _layout(HomesteadSite.site_seed_for("colonist-%04d" % i), tpl, eq)
		var dg := HomesteadSite.layout_digest(lay) if not lay.is_empty() else "NO_LAYOUT"
		digests.append(dg)
		seen[dg] = true
	var run_digest := ",".join(digests).sha256_text().substr(0, 16)
	var again := PackedStringArray()
	for i in range(IDS):
		var lay2 := _layout(HomesteadSite.site_seed_for("colonist-%04d" % i), tpl, eq)
		again.append(HomesteadSite.layout_digest(lay2) if not lay2.is_empty() else "NO_LAYOUT")
	rec["ids_tested"] = IDS
	rec["distinct_digests"] = seen.size()
	rec["run_digest"] = run_digest
	rec["same_id_twice_in_process_equal"] = (digests == again)
	_check("distinct_digests", seen.size() == IDS and not seen.has("NO_LAYOUT"), "%d distinct of %d" % [seen.size(), IDS])
	_check("same_id_twice", digests == again, "a second pass differs")

	# --- seed known answers: FNV-1a 32-bit
	var kat := {"empty": HomesteadSite.site_seed_for(""), "a": HomesteadSite.site_seed_for("a")}
	kat["matches"] = (int(kat["empty"]) == 2166136261 and int(kat["a"]) == 3826002220)
	rec["seed_kat"] = kat
	_check("seed_kat", bool(kat["matches"]), str(kat))
	_check("default_seed_matches_id", int(tpl["default_site_seed"]) == HomesteadSite.site_seed_for(HomesteadSite.DEFAULT_COLONIST_ID), "default_site_seed is stale")

	# --- the data drives the result
	var base_seed := HomesteadSite.site_seed_for("colonist-0007")
	var base := _layout(base_seed, tpl, eq)
	var eq_less := _copy(eq)
	eq_less["items"].pop_back()
	var less := _layout(base_seed, tpl, eq_less)
	var tpl_big := _copy(tpl)
	tpl_big["slab"]["half_x_m"] = 5.2
	tpl_big["slab"]["half_z_m"] = 5.2
	var big := _layout(base_seed, tpl_big, eq)
	var big_ok := false
	if not big.is_empty():
		var bc := HomesteadSite.check_layout(big, tpl_big)
		big_ok = int(bc["violations"]["total"]) == 0 and is_equal_approx(float(big["slab"]["half_x_m"]), 5.2)
	var tpl_cone := _copy(tpl)
	tpl_cone["view_cone_deg"] = 35
	var coned := _layout(base_seed, tpl_cone, eq)
	var cone_changes := not coned.is_empty() and HomesteadSite.layout_digest(coned) != HomesteadSite.layout_digest(base)
	var cone_ok := false
	if not coned.is_empty():
		cone_ok = int(HomesteadSite.check_layout(coned, tpl_cone)["violations"]["total"]) == 0
	rec["data_driven"] = {
		"item_removed_count": less.get("items", []).size(),
		"slab_resized_respected": big_ok,
		"cone_edit_changes_layout": cone_changes and cone_ok,
	}
	_check("data_item_removed", less.get("items", []).size() == 7, "got %d items" % less.get("items", []).size())
	_check("data_slab_resized", big_ok, "resized slab is not respected")
	_check("data_cone_edit", cone_changes and cone_ok, "a narrower cone did not change a valid layout")

	# --- negative controls for the determinism detector itself
	var c1 := _digest_with_clock(base)
	OS.delay_usec(1500)
	var c2 := _digest_with_clock(base)
	var g1 := _digest_with_global_rng(base)
	var g2 := _digest_with_global_rng(base)
	rec["neg"] = {"clock_mutation_detected": c1 != c2, "global_rng_mutation_detected": g1 != g2}
	_check("neg_clock", c1 != c2, "a clock-dependent digest was not detected")
	_check("neg_global_rng", g1 != g2, "a global-RNG-dependent digest was not detected")

	# --- fuzz: the generator against the checker, over many seeds
	var viol := {"total": 0, "out_of_slab": 0, "overlap": 0, "door_blocked": 0, "item_not_in_cone": 0,
		"item_behind_pod": 0, "handoff_off_slab": 0, "ring_off_slab": 0}
	var hits := {"pairs_checked": 0, "door_paths_checked": 0, "cone_checks": 0}
	var yaw_bins := {}
	var orders := {}
	var no_layout := 0
	for t in range(FUZZ_TRIALS):
		var lay3 := _layout(HomesteadSite.site_seed_for("fuzz-%d" % t), tpl, eq)
		if lay3.is_empty():
			no_layout += 1
			viol["total"] = int(viol["total"]) + 1
			continue
		var res := HomesteadSite.check_layout(lay3, tpl)
		for k in viol.keys():
			viol[k] = int(viol[k]) + int(res["violations"][k])
		for k in hits.keys():
			hits[k] = int(hits[k]) + int(res["hits"][k])
		yaw_bins[int(floor(rad_to_deg(float(lay3["pod"]["yaw"])) / YAW_BIN_DEG))] = true
		orders[",".join(HomesteadSite.item_order_by_bearing(lay3))] = true
	rec["fuzz"] = {
		"trials": FUZZ_TRIALS, "no_layout": no_layout, "violations": viol,
		"hits": {"pairs_checked": hits["pairs_checked"], "door_paths_checked": hits["door_paths_checked"],
			"cone_checks": hits["cone_checks"], "distinct_pod_yaw_bins": yaw_bins.size(),
			"distinct_item_orders": orders.size()},
	}
	_check("fuzz_no_violations", int(viol["total"]) == 0, str(viol))

	# --- the checker catches each planted violation, and passes the clean control
	var nc := {}
	nc["clean_control_passes"] = int(HomesteadSite.check_layout(base, tpl)["violations"]["total"]) == 0
	nc["planted_overlap_detected"] = _planted(base, tpl, "overlap")
	nc["planted_out_of_slab_detected"] = _planted(base, tpl, "out_of_slab")
	nc["planted_door_blocked_detected"] = _planted(base, tpl, "door_blocked")
	nc["planted_behind_pod_detected"] = _planted(base, tpl, "item_behind_pod")
	nc["planted_out_of_cone_detected"] = _planted(base, tpl, "item_not_in_cone")
	nc["planted_ring_off_slab_detected"] = _planted(base, tpl, "ring_off_slab")
	rec["neg_checker"] = nc
	for k in nc.keys():
		_check("neg_checker_" + String(k), bool(nc[k]), "the checker missed it")

	# --- every shape in the data stays inside its declared footprint circle
	var shapes_ok := true
	for it in eq["items"]:
		var far := HomesteadSite.shape_reach_m(it["shape"])
		if far > float(it["footprint_r_m"]) + 0.005:
			shapes_ok = false
			print("HOMESTEAD_UNIT_FAIL shape_fit: ", it["id"], " reaches ", far, " > ", it["footprint_r_m"])
	_check("shapes_fit_footprint", shapes_ok)

	rec["failures"] = _fail
	var f := FileAccess.open(out_dir.path_join("unit_run_%s.json" % run_ix), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec))
	f.close()
	print("HOMESTEAD_UNIT_DONE failures=", _fail, " digest=", run_digest)
	quit(0 if _fail == 0 else 1)


## Plants one violation into a copy of a clean layout and reports whether the checker counted it.
static func _planted(layout: Dictionary, tpl: Dictionary, kind: String) -> bool:
	var l := _copy(layout)
	var it0: Dictionary = l["items"][0]
	var it1: Dictionary = l["items"][1]
	var pod: Dictionary = l["pod"]
	var hand: Dictionary = l["handoff"]
	if kind == "overlap":
		it1["x"] = it0["x"]
		it1["z"] = it0["z"]
	elif kind == "out_of_slab":
		it0["x"] = float(l["slab"]["half_x_m"]) + 0.5
	elif kind == "door_blocked":
		var door: Dictionary = l["door"]
		it0["x"] = (float(door["x"]) + float(hand["x"])) * 0.5
		it0["z"] = (float(door["z"]) + float(hand["z"])) * 0.5
	elif kind == "item_behind_pod":
		var dx := float(pod["x"]) - float(hand["x"])
		var dz := float(pod["z"]) - float(hand["z"])
		var dl := sqrt(dx * dx + dz * dz)
		var far := float(pod["footprint_r_m"]) + float(it0["footprint_r_m"]) + 0.6
		it0["x"] = float(pod["x"]) + dx / dl * far
		it0["z"] = float(pod["z"]) + dz / dl * far
	elif kind == "item_not_in_cone":
		var ang := float(hand["dir_angle"]) + deg_to_rad(float(tpl["view_cone_deg"]) + 25.0)
		it0["x"] = float(hand["x"]) + cos(ang) * 2.5
		it0["z"] = float(hand["z"]) + sin(ang) * 2.5
	elif kind == "ring_off_slab":
		l["rings"][0]["x"] = float(l["slab"]["half_x_m"]) + 0.2
	var res := HomesteadSite.check_layout(l, tpl)
	return int(res["violations"][kind]) >= 1
