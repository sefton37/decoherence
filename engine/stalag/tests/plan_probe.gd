extends SceneTree
## Spec #517 plan probe (headless, no GPU). It only MEASURES -- tests/verify_stalag_plan.sh
## pairs it with the fresh JS oracle and the DoD's jq does the judging.
##
## Env: STALAG_PLAN_RAW      output JSON path (required)
##      STALAG_PLAN_ORACLE   directory written by tools/baseline/js_world_oracle.mjs (required)
##      STALAG_PLAN_MUTATE   none | carve_off | flood_off | water_shift
##
## Record: {plan{...}, queries{functions[7], surface_height}, terrain{regions[], neg_control,
##          thread_safety}, water{regions[], seam, neg_control, thread_safety}} (the wrapper adds
##          generated_epoch, mutation, headless and the JS side).

const MeshStats = preload("res://engine/stalag/tests/mesh_stats.gd")

const ARRAYS := [
	["carve", "plan_carve.bin"], ["waterTw", "plan_waterTw.bin"], ["waterType", "plan_waterType.bin"],
	["flowX", "plan_flowX.bin"], ["flowZ", "plan_flowZ.bin"],
	["bedTargetLat", "plan_bedTargetLat.bin"], ["bankTargetLat", "plan_bankTargetLat.bin"],
]

var _mutation := "none"
var _water_shift_m := 0.0


func _fail(msg: String) -> void:
	push_error("plan_probe: " + msg)
	quit(2)


func _region(r: Dictionary, dx: float = 0.0) -> Dictionary:
	return {"xMin": float(r["xMin"]) + dx, "xMax": float(r["xMax"]) + dx, "zMin": float(r["zMin"]), "zMax": float(r["zMax"])}


func _initialize() -> void:
	var raw := OS.get_environment("STALAG_PLAN_RAW")
	var odir := OS.get_environment("STALAG_PLAN_ORACLE")
	_mutation = OS.get_environment("STALAG_PLAN_MUTATE")
	if _mutation.is_empty():
		_mutation = "none"
	if raw.is_empty() or odir.is_empty() or not ClassDB.class_exists("StalagWorld"):
		_fail("STALAG_PLAN_RAW / STALAG_PLAN_ORACLE required and StalagWorld must be loaded")
		return
	var of := FileAccess.open(odir.path_join("oracle.json"), FileAccess.READ)
	if of == null:
		_fail("cannot read oracle.json")
		return
	var oracle: Dictionary = JSON.parse_string(of.get_as_text())
	of.close()

	var out := {}
	# ---- the solve: started here, runs on a worker; the main thread only polls.
	StalagWorld.start_plan()
	var polls := 0
	while StalagWorld.plan_status() == 1:
		polls += 1
		OS.delay_msec(20)
	if StalagWorld.plan_status() != 2:
		_fail("plan solve failed: " + StalagWorld.plan_error())
		return
	var counts := StalagWorld.plan_type_counts()
	var arrays_out := []
	for a in ARRAYS:
		var f := FileAccess.open(odir.path_join(a[1]), FileAccess.READ)
		if f == null:
			_fail("cannot read " + a[1])
			return
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var cmp: Dictionary = StalagWorld.compare_plan_array(a[0], bytes)
		arrays_out.append(cmp)
	out["plan"] = {
		"seed": StalagWorld.get_seed(),
		"dim": StalagWorld.plan_dim(),
		"g0": StalagWorld.plan_g0(),
		"js_hash": oracle["plan"]["hash"],
		"gd_hash": StalagWorld.plan_hash(),
		"solve_ms": StalagWorld.plan_solve_ms(),
		"solve_on_main_thread": not StalagWorld.plan_solved_off_main_thread(),
		"main_thread_polls": polls,
		"type_counts_js": oracle["plan"]["type_counts"],
		"type_counts_gd": Array(counts),
		"arrays": arrays_out,
	}

	# ---- mutations act on the queries after the plan is published
	if _mutation == "carve_off" or _mutation == "flood_off":
		StalagWorld.set_mutation(_mutation)
	elif _mutation == "water_shift":
		_water_shift_m = 0.5

	out["queries"] = _queries(oracle["query_samples"])
	if _has_section("terrain"):
		out["terrain"] = _terrain(oracle)
	if _has_section("water"):
		out["water"] = _water(oracle)

	var fw := FileAccess.open(raw, FileAccess.WRITE)
	fw.store_string(JSON.stringify(out))
	fw.close()
	quit(0)


func _has_section(name: String) -> bool:
	if name == "terrain":
		return ClassDB.class_has_method("StalagChunkMesher", "build_region_arrays")
	return ClassDB.class_has_method("StalagChunkMesher", "build_water_arrays")


# ---------------------------------------------------------------- queries
func _queries(qs: Dictionary) -> Dictionary:
	var cols: Array = qs["columns"]
	var dry := StalagWorld.water_dry_sentinel()
	var funcs := []
	var wl: Array = qs["waterLevelAt"]
	var cl: Array = qs["courseLevelAt"]
	var specs := [
		["waterLevelAt", "waterLevelAt"], ["isFlooded", "isFlooded"], ["courseLevelAt", "courseLevelAt"],
		["courseFallTopAt", "courseFallTopAt"], ["isRiverColumn", "isRiverColumn"],
		["getStrahlerOrder", "getStrahlerOrder"], ["getFlowDir", "getFlowDir"],
	]
	for sp in specs:
		var name: String = sp[0]
		var want: Array = qs[sp[1]]
		var n := cols.size()
		var wet_n := 0
		var mismatch := 0
		for i in range(n):
			var gx := int(cols[i][0])
			var gz := int(cols[i][1])
			# wet_n counts samples ON a wet plan column (a lake/spring or a river/fall column),
			# so a query that is dry-valued by design (courseFallTopAt away from a fall) still
			# has 200+ wet-column samples and a real chance to disagree.
			if int(wl[i]) != dry or int(cl[i]) != dry:
				wet_n += 1
			var got
			match name:
				"waterLevelAt":
					got = StalagWorld.water_level_at(gx, gz)
				"isFlooded":
					got = 1 if StalagWorld.is_flooded(gx, gz) else 0
				"courseLevelAt":
					got = StalagWorld.course_level_at(gx, gz)
				"courseFallTopAt":
					got = StalagWorld.course_fall_top_at(gx, gz)
				"isRiverColumn":
					got = 1 if StalagWorld.is_river_column(gx, gz) else 0
				"getStrahlerOrder":
					got = StalagWorld.get_strahler_order(gx, gz)
				_:
					var fd := StalagWorld.get_flow_dir(gx, gz)
					var w = want[i]
					if w == null:
						got = Vector2.ZERO
						if fd != Vector2.ZERO:
							mismatch += 1
					else:
						if fd.x != float(w[0]) or fd.y != float(w[1]):
							mismatch += 1
					continue
			if int(got) != int(want[i]):
				mismatch += 1
		funcs.append({"name": name, "n": n, "wet_n": wet_n, "mismatch": mismatch})

	var sh: Dictionary = qs["surfaceHeight"]
	var addrs: Array = sh["addrs"]
	var vals: Array = sh["values"]
	var carved_n := 0
	var a_n := 0
	var b_n := 0
	var sh_mismatch := 0
	for i in range(addrs.size()):
		var cx := int(addrs[i][0])
		var cz := int(addrs[i][1])
		var got_h := StalagWorld.surface_height(cx, cz)
		if absf(got_h - float(vals[i])) > 1e-6:
			sh_mismatch += 1
		if absf(StalagWorld.surface_height_base(cx, cz) - float(vals[i])) > 1e-9:
			carved_n += 1
		if posmod(cx, 4) == 0 and posmod(cz, 4) == 0:
			a_n += 1
		elif posmod(cx, 4) == 2 and posmod(cz, 4) == 2:
			b_n += 1
	return {
		"functions": funcs,
		"surface_height": {"n": addrs.size(), "carved_n": carved_n, "coset_a_n": a_n, "coset_b_n": b_n, "mismatch": sh_mismatch},
	}


# ---------------------------------------------------------------- terrain
func _terrain_measure(reg: Dictionary) -> Dictionary:
	var arrays := StalagChunkMesher.build_region_arrays(reg["xMin"], reg["xMax"], reg["zMin"], reg["zMax"])
	var m := MeshStats.measure(arrays, reg)
	m["grass_tris"] = arrays["grass_tris"]
	m["dirt_tris"] = arrays["dirt_tris"]
	m["uv_q_sum"] = Array(arrays["uv_q_sum"])
	return m


func _terrain_job(reg: Dictionary, slot: int, out: Array) -> void:
	out[slot] = _terrain_measure(reg)


func _terrain(oracle: Dictionary) -> Dictionary:
	var regions := []
	var first: Dictionary = {}
	for r in oracle["terrain_regions"]:
		var reg := _region(r["region"])
		if first.is_empty():
			first = reg
		regions.append({"region": reg, "gd": _terrain_measure(reg)})
	# Negative control: the first region shifted along x must not reproduce the unshifted numbers.
	var shifted := _region(first, 0.5)
	var neg := {"region": first, "shift_m": 0.5, "gd_shifted": _terrain_measure(shifted)}
	# Reentrancy: N concurrent builds of one region must all equal a single build.
	var n := 4
	var single := _terrain_measure(first)
	var results: Array = []
	results.resize(n)
	var ids: Array = []
	for i in range(n):
		ids.append(WorkerThreadPool.add_task(_terrain_job.bind(first, i, results)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	var equal := true
	for i in range(n):
		if JSON.stringify(results[i]) != JSON.stringify(single):
			equal = false
	return {"regions": regions, "neg_control": neg, "thread_safety": {"threads": n, "equal": equal, "region": first}}


# ---------------------------------------------------------------- water
func _water_measure(reg: Dictionary) -> Dictionary:
	var w := StalagChunkMesher.build_water_arrays(reg["xMin"], reg["xMax"], reg["zMin"], reg["zMax"])
	var v: PackedVector3Array = w["vertices"]
	if _water_shift_m != 0.0:
		# negative control (mutation water_shift): the whole water mesh displaced by one cell
		for i in range(v.size()):
			v[i] = v[i] + Vector3(_water_shift_m, 0.0, 0.0)
	var depth: PackedFloat32Array = w["depth"]
	var flow: PackedVector2Array = w["flow"]
	var depth_q := 0
	for i in range(depth.size()):
		depth_q += floori(depth[i] * 1e4 + 0.5)
	var flow_tris := 0
	var t := 0
	while t + 2 < flow.size():
		if flow[t] != Vector2.ZERO:
			flow_tris += 1
		t += 3
	return {
		"tris": v.size() / 3,
		"centroid_q_sum": MeshStats.centroid_q_sum(v),
		"depth_q_sum": depth_q,
		"flow_nonzero_tris": flow_tris,
	}


func _water_job(reg: Dictionary, slot: int, out: Array) -> void:
	out[slot] = _water_measure(reg)


func _water(oracle: Dictionary) -> Dictionary:
	var regions := []
	var first: Dictionary = {}
	var seam: Dictionary = {}
	for r in oracle["water_regions"]:
		var reg := _region(r["region"])
		if first.is_empty() and r["kind"] == "lake":
			first = reg
		if r["kind"] == "seam":
			seam = reg
		regions.append({"kind": r["kind"], "region": _region(r["region"]), "gd": _water_measure(reg)})
	# Seam: the two halves of the straddling region must add up to the whole.
	var mid := (float(seam["xMin"]) + float(seam["xMax"])) * 0.5
	var left := {"xMin": seam["xMin"], "xMax": mid, "zMin": seam["zMin"], "zMax": seam["zMax"]}
	var right := {"xMin": mid, "xMax": seam["xMax"], "zMin": seam["zMin"], "zMax": seam["zMax"]}
	var seam_out := {
		"full_tris": _water_measure(seam)["tris"],
		"left_tris": _water_measure(left)["tris"],
		"right_tris": _water_measure(right)["tris"],
	}
	# Negative control: the seam region shifted half its width (14 m) along x must not reproduce
	# the unshifted numbers. (A 7 m shift is not enough in every world: when the water inside
	# the seam region sits in the middle of it, the shifted window holds the same triangles.)
	var shifted := _region(seam, 14.0)
	var neg := {"region": seam, "shift_m": 14.0, "gd_shifted": _water_measure(shifted)}
	var n := 4
	var single := _water_measure(first)
	var results: Array = []
	results.resize(n)
	var ids: Array = []
	for i in range(n):
		ids.append(WorkerThreadPool.add_task(_water_job.bind(first, i, results)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	var equal := true
	for i in range(n):
		if JSON.stringify(results[i]) != JSON.stringify(single):
			equal = false
	return {"regions": regions, "seam": seam_out, "neg_control": neg, "thread_safety": {"threads": n, "equal": equal, "region": first}}
