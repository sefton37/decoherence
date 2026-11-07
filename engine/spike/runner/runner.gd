extends Node3D
## Spec #494 spike runner. Builds one chunk with each candidate (GDScript, C++
## GDExtension), checks parity with the same checksum over the returned ArrayMesh,
## then renders each mesh from a fixed camera and samples frame times.
##
## Inputs (environment): SPIKE_RAW (required, raw result path), SPIKE_REGION
## ("xMin,xMax,zMin,zMax", default 0,28,0,28). run_spike.sh wraps this and adds the
## JS baseline + recommendation line; this script never reads or runs anything else.

const SEED := 42            # stalag WORLD_SEED
const EXTENT := 72
const TIMED_RUNS := 5       # after one un-timed warm-up
const FRAME_WARMUP := 30
const FRAME_SAMPLES := 150
const EXT_CLASS := "StalagMesher"
const GDEXTENSION_FILE := "res://ext/stalagspike.gdextension"

var _results := {}


func _ready() -> void:
	var raw_path := OS.get_environment("SPIKE_RAW")
	if raw_path.is_empty():
		push_error("runner: SPIKE_RAW is required")
		get_tree().quit(2)
		return
	var region_str := OS.get_environment("SPIKE_REGION")
	if region_str.is_empty():
		region_str = "0,28,0,28"
	var rv := region_str.split(",")
	if rv.size() != 4:
		push_error("runner: bad SPIKE_REGION '%s'" % region_str)
		get_tree().quit(2)
		return
	var region := { "xMin": float(rv[0]), "xMax": float(rv[1]), "zMin": float(rv[2]), "zMax": float(rv[3]) }

	var ext_loaded := ClassDB.class_exists(EXT_CLASS)
	var meshes := {}
	var candidates := {}

	candidates["gdscript"] = _measure_candidate(
		func() -> ArrayMesh: return StalagMesherGd.new().build(SEED, EXTENT, region.xMin, region.xMax, region.zMin, region.zMax),
		meshes, "gdscript")
	candidates["gdscript"]["class_loaded"] = true

	if ext_loaded:
		candidates["gdextension"] = _measure_candidate(
			func() -> ArrayMesh:
				var m: Object = ClassDB.instantiate(EXT_CLASS)
				return m.call("build", SEED, EXTENT, region.xMin, region.xMax, region.zMin, region.zMax),
			meshes, "gdextension")
	else:
		candidates["gdextension"] = { "tris_base": 0, "centroid_q_sum": [0, 0, 0], "build_ms": [], "build_ms_median": 0.0 }
	candidates["gdextension"]["class_loaded"] = ext_loaded
	candidates["gdextension"]["lib_path"] = _gdextension_lib_path()

	var frame := await _measure_frames(meshes, region)

	var ver := Engine.get_version_info()
	_results = {
		"generated_epoch": Time.get_unix_time_from_system(),
		"godot_version": str(ver.get("string", "")),
		"params": { "seed": SEED, "extent": EXTENT, "region": region },
		"candidates": candidates,
		"csharp": {
			"available": ClassDB.class_exists("CSharpScript"),
			"evidence": "ClassDB.class_exists(CSharpScript)=%s; OS.has_feature(dotnet)=%s on Godot %s" % [
				ClassDB.class_exists("CSharpScript"), OS.has_feature("dotnet"), ver.get("string", "")],
		},
		"frame": frame,
	}
	var f := FileAccess.open(raw_path, FileAccess.WRITE)
	if f == null:
		push_error("runner: cannot open %s" % raw_path)
		get_tree().quit(3)
		return
	f.store_string(JSON.stringify(_results, "  "))
	f.close()
	get_tree().quit(0)


## One un-timed warm-up build, then TIMED_RUNS timed builds. Timing covers parameters in
## to an ArrayMesh with the surface added. Parity is computed afterwards, untimed.
func _measure_candidate(build: Callable, meshes: Dictionary, key: String) -> Dictionary:
	build.call()
	var times: Array[float] = []
	var mesh: ArrayMesh = null
	for r in TIMED_RUNS:
		var t0 := Time.get_ticks_usec()
		mesh = build.call()
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	meshes[key] = mesh
	var sum := SpikeMeshChecksum.compute(mesh)
	return {
		"tris_base": sum["tris"],
		"centroid_q_sum": sum["centroid_q_sum"],
		"build_ms": times,
		"build_ms_median": _median(times),
	}


func _gdextension_lib_path() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(GDEXTENSION_FILE) != OK:
		return ""
	var res_path: String = cfg.get_value("libraries", "linux.release.x86_64", "")
	# Repo-relative, not absolute: the record is committed to a public repo and must not
	# carry this machine's home path. The spike project lives at <repo>/engine/spike/.
	return ("engine/spike/" + res_path.trim_prefix("res://")) if not res_path.is_empty() else ""


func _median(xs: Array[float]) -> float:
	var s := xs.duplicate()
	s.sort()
	var m := s.size() / 2
	return s[m] if s.size() % 2 == 1 else (s[m - 1] + s[m]) / 2.0


## Render each candidate's mesh from one fixed camera at the project resolution
## (vsync off) and sample the frame period.
func _measure_frames(meshes: Dictionary, region: Dictionary) -> Dictionary:
	var headless := DisplayServer.get_name() == "headless"
	var medians := {}
	var p95s := {}
	var gpu_medians := {}
	var cpu_render_medians := {}
	var sampled := 0
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var cam := Camera3D.new()
	add_child(cam)
	var cx: float = (region.xMin + region.xMax) * 0.5
	var cz: float = (region.zMin + region.zMax) * 0.5
	cam.position = Vector3(cx, 30.0, region.zMin - 18.0)
	cam.look_at(Vector3(cx, 5.0, cz))
	cam.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.55, 0.22)

	for key in ["gdscript", "gdextension"]:
		var mi := MeshInstance3D.new()
		mi.mesh = meshes.get(key)
		mi.material_override = mat
		add_child(mi)
		for i in FRAME_WARMUP:
			await get_tree().process_frame
		var deltas: Array[float] = []
		var gpu: Array[float] = []
		var cpu: Array[float] = []
		var last := Time.get_ticks_usec()
		for i in FRAME_SAMPLES:
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			deltas.append((now - last) / 1000.0)
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
			last = now
		medians[key] = _median(deltas)
		var shot := OS.get_environment("SPIKE_SHOT")  # optional: save a PNG per candidate to <dir>
		if not shot.is_empty():
			get_viewport().get_texture().get_image().save_png("%s/%s.png" % [shot, key])
		var sorted := deltas.duplicate()
		sorted.sort()
		p95s[key] = sorted[int(sorted.size() * 0.95)]
		gpu_medians[key] = _median(gpu)
		cpu_render_medians[key] = _median(cpu)
		sampled = deltas.size()
		mi.queue_free()
		await get_tree().process_frame

	return {
		"adapter": RenderingServer.get_video_adapter_name(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"display_driver": DisplayServer.get_name(),
		"headless": headless,
		"resolution": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"vsync": "disabled",
		"frames_warmup": FRAME_WARMUP,
		"frames_sampled": sampled,
		"frame_ms_median": medians,
		"frame_ms_p95": p95s,
		"gpu_render_ms_median": gpu_medians,
		"cpu_render_ms_median": cpu_render_medians,
	}
