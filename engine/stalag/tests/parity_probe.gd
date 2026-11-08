extends SceneTree
## Spec #501 parity probe: builds regions with the engine (StalagChunkMesher) and writes
## measurements. It only MEASURES -- tests/verify_stalag_parity.sh pairs these with the
## fresh JS oracle and the DoD jq does the judging.
##
## Env: STALAG_PARITY_RAW      output JSON path (required)
##      STALAG_PARITY_REGIONS  "xMin,xMax,zMin,zMax;..." (required)
##      STALAG_PARITY_NEG      region to shift for the negative control ("x0,x1,z0,z1")
##      STALAG_PARITY_SHIFT_M  shift in metres applied along x (default 0.5)
##      STALAG_PARITY_THREADS  concurrent builds for the reentrancy check (default 4)

const MeshStats = preload("res://engine/stalag/tests/mesh_stats.gd")


func _region(s: String) -> Dictionary:
	var p := s.split(",")
	return {"xMin": float(p[0]), "xMax": float(p[1]), "zMin": float(p[2]), "zMax": float(p[3])}


func _build(r: Dictionary) -> Dictionary:
	return StalagChunkMesher.build_region_arrays(r["xMin"], r["xMax"], r["zMin"], r["zMax"])


func _thread_job(r: Dictionary, slot: int, out: Array) -> void:
	out[slot] = _build(r)


func _initialize() -> void:
	var raw := OS.get_environment("STALAG_PARITY_RAW")
	var regions_env := OS.get_environment("STALAG_PARITY_REGIONS")
	if raw.is_empty() or regions_env.is_empty() or not ClassDB.class_exists("StalagChunkMesher"):
		push_error("parity_probe: STALAG_PARITY_RAW / STALAG_PARITY_REGIONS required and StalagChunkMesher must be loaded")
		quit(2)
		return
	var out := {"regions": [], "neg_control": {}, "thread_safety": {}}
	var first: Dictionary = {}
	for s in regions_env.split(";", false):
		var reg := _region(s)
		var t0 := Time.get_ticks_usec()
		var arrays := _build(reg)
		var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var m := MeshStats.measure(arrays, reg)
		m["build_ms"] = build_ms
		out["regions"].append({"region": reg, "gd": m})
		if first.is_empty():
			first = reg
			out["thread_ref"] = m

	# Negative control: the same region shifted along x must NOT reproduce the unshifted numbers.
	var neg_s := OS.get_environment("STALAG_PARITY_NEG")
	var neg_reg := _region(neg_s) if not neg_s.is_empty() else first
	var shift := 0.5
	if not OS.get_environment("STALAG_PARITY_SHIFT_M").is_empty():
		shift = float(OS.get_environment("STALAG_PARITY_SHIFT_M"))
	var shifted := {"xMin": neg_reg["xMin"] + shift, "xMax": neg_reg["xMax"] + shift, "zMin": neg_reg["zMin"], "zMax": neg_reg["zMax"]}
	out["neg_control"] = {"region": neg_reg, "shift_m": shift, "gd_shifted": MeshStats.measure(_build(shifted), shifted)}

	# Reentrancy: N concurrent builds of one region must all equal a single build.
	var n := 4
	if not OS.get_environment("STALAG_PARITY_THREADS").is_empty():
		n = int(OS.get_environment("STALAG_PARITY_THREADS"))
	var results: Array = []
	results.resize(n)
	var ids: Array = []
	for i in range(n):
		ids.append(WorkerThreadPool.add_task(_thread_job.bind(first, i, results)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	var single: Dictionary = out["thread_ref"]
	var equal := true
	var distinct_threads := 0
	for i in range(n):
		var m := MeshStats.measure(results[i], first)
		for key in ["tris_base", "tris_caps", "centroid_q_sum_base", "centroid_q_sum_caps"]:
			if m[key] != single[key]:
				equal = false
		distinct_threads += 1
	out["thread_safety"] = {"threads": distinct_threads, "equal": equal, "region": first}
	out.erase("thread_ref")

	var f := FileAccess.open(raw, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	quit(0)
