extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 582 S1 horizon probe. Loads the REAL world scene (res://game/world/world.tscn) exactly as the richness
## probe does and measures how far the game really shows terrain. It has no content of its own: it never builds a
## mesh, a tile or a tree; the far terrain it measures is the one the world scene built.
##
## Env: HZ_OUT (required)  output dir
##      HZ_VIEW            near | far | vista | horizon (default horizon)
##      HZ_ATMO            classic | clear | amber (default clear)
##      HZ_MODE            measure (the five poses, depth, budgets, far terrain checks) | sheet (the contact sheet)
##      HZ_MUTATE          none | nolod | flat | norelief | fogwall | noclouds | seam | noatmo (the negative controls)
##
## measure writes raw.json, <pose>.png, <pose>-depth.png and <pose>-sky.png: the frame, the same frame drawn by
## tools/scenic/depth_pass.gdshader (linear view distance in the RGB bits, white = sky), and the frame with the
## world hidden (pure sky). tools/scenic/post.py (modes horizon and sheet) reads those, computes every pixel metric
## in the observer's frame, judges the bars in horizon_bars.json and writes horizon.json or sheet.json.
## Frame statistics that need the engine (primitives, draw calls, video memory, GPU time, the far terrain's height
## error against ground_envelope_at, coverage, trees against the engine's own placements, the 1,000 m traverse)
## are read here.

const WORLD_SCENE := "res://game/world/world.tscn"
const POSES := "res://tools/scenic/horizon_poses.json"
const DEPTH_SHADER := "res://tools/scenic/depth_pass.gdshader"
const WIND_CLOCK := 3.0  ## the fixed wind clock of every pose
const WATER_TIME := 40.0  ## the fixed value the water shader reads instead of TIME
const GPU_FRAMES := 21
const MAX_FOG := 0.8
const ERR_SAMPLES := 200
const TRAVERSE_STEPS := 61
const TRAVERSE_STEP_M := 16.7
const TRAVERSE_FRAMES_MAX := 120
const DEPTH_RANGE_M := 4000.0
## The finite ceiling of every ground_envelope_at truth call. An unbounded ceiling (INF) starts the engine's scan at
## lattice 60 and returns -inf above 7.5 m, so it would silently mis-measure any mountain (Spec 582 finding L).
const TRUTH_CEIL_M := 400.0
const RELIEF_INNER_M := 346.0  ## the highland ring of the relief records: Chebyshev distance from the origin
const RELIEF_OUTER_M := 840.0
const RELIEF_SAMPLES := 600
const RELIEF_GRID_M := 4.0  ## the grid of the engine's own maximum over the ring (every tile vertex lies on it)
const RELIEF_WINDOW_M := 100.0
const WINDOW_MIN_VERTS := 16  ## a relief window counts when at least this many tile vertices lie in it
const FOOT_HALF_M := 104.0  ## a pose's focus is clamped this far from the origin (the walkable footprint is 112)

var _out := ""
var _view := "horizon"
var _atmo := "clear"
var _mode := "measure"
var _mutate := "none"
var _size := Vector2i(1600, 900)
var _world: Node
var _streamer
var _walker
var _far: Node3D
var _vp: SubViewport
var _pc: Camera3D
var _step_ms_max := 0.0
var _adopt_ms_max := 0.0
var _build_ms_total := 0.0
var _step_list: Array = []
var _adopt_list: Array = []
var _stats_on := true  ## the far terrain's build timing is collected for the first world only (and the traverse)
var _depth_mat: ShaderMaterial
var _depth_tree_mat: ShaderMaterial


func _ready() -> void:
	_run()


func _fail(msg: String) -> void:
	push_error("horizon_probe: " + msg)
	get_tree().quit(2)


func _frames(n: int) -> void:
	for _i in range(n):
		await RenderingServer.frame_post_draw


func _run() -> void:
	_out = OS.get_environment("HZ_OUT")
	_view = OS.get_environment("HZ_VIEW") if not OS.get_environment("HZ_VIEW").is_empty() else "horizon"
	_atmo = OS.get_environment("HZ_ATMO") if not OS.get_environment("HZ_ATMO").is_empty() else "clear"
	_mode = OS.get_environment("HZ_MODE") if not OS.get_environment("HZ_MODE").is_empty() else "measure"
	_mutate = OS.get_environment("HZ_MUTATE") if not OS.get_environment("HZ_MUTATE").is_empty() else "none"
	if _out.is_empty() or not ClassDB.class_exists("StalagWorld"):
		_fail("HZ_OUT is required and the engine must be loaded")
		return
	if not ["near", "far", "vista", "horizon"].has(_view) or not ["classic", "clear", "amber"].has(_atmo) or not ["measure", "sheet"].has(_mode) \
			or not ["none", "nolod", "flat", "norelief", "fogwall", "noclouds", "seam", "noatmo"].has(_mutate):
		_fail("bad HZ_VIEW, HZ_ATMO, HZ_MODE or HZ_MUTATE")
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var doc = JSON.parse_string(FileAccess.get_file_as_string(POSES))
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("poses"):
		_fail("cannot read the horizon poses")
		return
	_size = Vector2i(int(doc["size"][0]), int(doc["size"][1]))
	get_viewport().disable_3d = true  # the window itself draws nothing; the SubViewport below does
	_vp = SubViewport.new()
	_vp.size = _size
	# The probe's viewport draws only while a frame is being taken (_grab and the GPU timing). Everything else, the
	# far terrain's build and adoption included, is timed with the GPU idle: a mesh upload that waits for a busy
	# card is the card's time (the card is shared), not the far terrain's main-thread cost.
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_pc = Camera3D.new()
	_vp.add_child(_pc)
	RenderingServer.viewport_set_measure_render_time(_vp.get_viewport_rid(), true)
	_depth_mat = ShaderMaterial.new()
	_depth_mat.shader = load(DEPTH_SHADER)
	_depth_mat.set_shader_parameter("range_m", DEPTH_RANGE_M)
	_depth_tree_mat = _depth_mat.duplicate()
	_depth_tree_mat.set_shader_parameter("tree_pass", true)
	if _mode == "sheet":
		await _run_sheet(doc["poses"])
	else:
		await _run_measure(doc["poses"])


# ---------------------------------------------------------------- the world
func _load_world(view: String, atmo: String, mutate: String) -> bool:
	_world = (load(WORLD_SCENE) as PackedScene).instantiate()
	_world.scripted_input = true
	_world.flora_clock = WIND_CLOCK
	_world.flora_clock_frozen = true
	if not ("view_distance" in _world) or not ("atmosphere" in _world):
		_fail("the world has no view_distance or atmosphere property")
		return false
	_world.view_distance = view
	_world.atmosphere_from_level = false  # the probe names the preset itself
	_world.atmosphere = atmo
	_world.atmosphere_enabled = mutate != "noatmo"
	_world.far_terrain_enabled = mutate != "nolod"
	_world.far_terrain_flat = mutate == "flat"
	add_child(_world)
	_streamer = _world.streamer
	_walker = _world.walker
	_far = _world.far_terrain
	if _far != null:
		_far.manual_step = true  # this probe times the two halves of the far terrain's frame itself
		_far.norelief_mutation = mutate == "norelief"
	if mutate == "fogwall":
		_world.fog_override = 0.012
		_world._apply_view()
	if mutate == "noclouds":
		var sm = _world.cam.environment.sky.sky_material
		if sm is ShaderMaterial:
			sm.set_shader_parameter("cloud_cover", 0.0)
	if mutate == "seam":
		_far.set_fog(float(_far_density()), Color(0.1, 0.12, 0.05))
	var guard := 0
	while not _streamer.ring_ready() and guard < 6000:
		await _pump()
		guard += 1
	if not _streamer.ring_ready():
		_fail("the world never became ready")
		return false
	guard = 0
	while not _world.far_terrain_ready() and guard < 6000:
		await _pump()
		guard += 1
	if not _world.far_terrain_ready():
		_fail("the far terrain never finished building")
		return false
	_freeze_water_time()
	await _settle()
	return true


func _far_density() -> float:
	var d = _world.grass_mat.get_shader_parameter("fog_density")
	if d == null:
		d = RenderingServer.shader_get_parameter_default(_world.grass_mat.shader.get_rid(), "fog_density")
	return float(d)


## One frame of waiting in which the far terrain's two halves are driven and timed here.
func _pump() -> void:
	if _far != null and is_instance_valid(_far):
		var t0 := Time.get_ticks_usec()
		_far.adopt_pending()
		var t1 := Time.get_ticks_usec()
		_far.build_some()
		var t2 := Time.get_ticks_usec()
		var step := float(t2 - t0) / 1000.0
		if _stats_on:
			_adopt_ms_max = maxf(_adopt_ms_max, float(t1 - t0) / 1000.0)
			_step_ms_max = maxf(_step_ms_max, step)
			_build_ms_total += step
			_step_list.append(step)
			_adopt_list.append(float(t1 - t0) / 1000.0)
	await get_tree().process_frame


func _unload_world() -> void:
	if _far != null and is_instance_valid(_far):
		_far.manual_step = true
	_streamer.shutdown()
	_world.queue_free()
	_far = null
	await get_tree().process_frame
	await get_tree().process_frame


func _settle() -> void:
	var guard := 0
	while guard < 3000:
		await _pump()
		guard += 1
		if _streamer.focus_chunk() == _streamer.chunk_of(_walker.pos) and _streamer.settled() and _world.far_terrain_ready():
			break
	var prev: Vector3 = _walker.pos
	var still := 0
	var g2 := 0
	while still < 6 and g2 < 600:
		await _pump()
		g2 += 1
		if _walker.pos.distance_to(prev) < 1e-5:
			still += 1
		else:
			still = 0
		prev = _walker.pos
	await _frames(3)


func _teleport(x: float, z: float) -> void:
	var y: float = StalagWorld.ground_floor(x, z, 200.0)
	_walker.teleport(Vector3(x, y, z), true)


## The water shader animates from the engine's TIME, which differs on every run. Swap it for a uniform that holds
## one fixed value (the same edit tools/scenic/richness_probe.gd makes, checked the same way).
func _freeze_water_time() -> void:
	var mat: ShaderMaterial = _world.water_mat
	var code: String = mat.shader.code
	if code.count("float t = TIME;") != 1 or code.count("void fragment()") != 1 or code.find("scenic_time") != -1:
		_fail("the water shader no longer has the expected TIME line; update _freeze_water_time")
		return
	code = code.replace("float t = TIME;", "float t = scenic_time;")
	code = code.replace("void fragment()", "uniform float scenic_time = 0.0;\nvoid fragment()")
	var sh := Shader.new()
	sh.code = code
	mat.shader = sh
	mat.set_shader_parameter("scenic_time", WATER_TIME)


func _grab() -> Image:
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await _frames(3)
	var img := _vp.get_texture().get_image()
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return img


# ---------------------------------------------------------------- one pose
## Puts the probe camera at a pose and returns the pose's camera position. The walker (and so the streamer and the
## far terrain) stands at the camera's own spot, clamped to the walkable footprint.
func _go_to_pose(p: Dictionary) -> Vector3:
	var cam_xz: Array = p["cam"]
	var hd := deg_to_rad(float(p["heading_deg"]))
	var pitch_down := atan((0.5 - float(p["horizon_frac"])) * 2.0 * tan(deg_to_rad(float(p["fov_deg"])) * 0.5))
	var dir := Vector3(sin(hd) * cos(pitch_down), -sin(pitch_down), cos(hd) * cos(pitch_down))
	_teleport(clampf(float(cam_xz[0]), -FOOT_HALF_M, FOOT_HALF_M), clampf(float(cam_xz[1]), -FOOT_HALF_M, FOOT_HALF_M))
	await _settle()
	var ground: float = StalagWorld.ground_envelope_at(float(cam_xz[0]), float(cam_xz[1]), TRUTH_CEIL_M)
	var cam_pos := Vector3(float(cam_xz[0]), ground + float(p["height_m"]), float(cam_xz[1]))
	_pc.far = _world.cam.far
	_pc.fov = float(p["fov_deg"])
	_pc.environment = _world.cam.environment
	_pc.global_position = cam_pos
	_pc.look_at(cam_pos + dir * 100.0, Vector3.UP)
	_pc.current = true
	_walker.body_node().visible = false
	var avatar := _world.get_node_or_null("Avatar")
	if avatar != null:
		avatar.visible = false
	await _frames(2)
	return cam_pos


func _measure_pose(p: Dictionary, with_depth: bool) -> Dictionary:
	var cam_pos: Vector3 = await _go_to_pose(p)
	var id := str(p["id"])
	var img: Image = await _grab()
	img.save_png(_out.path_join("%s.png" % id))
	var rid := _vp.get_viewport_rid()
	var prims := int(RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME))
	var calls := int(RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
	var vram_mb := float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0
	var rec := {
		"id": id,
		"gated": bool(p["gated"]),
		"png": _out.path_join("%s.png" % id),
		"chunks": _streamer.loaded_count(),
		"prims": prims,
		"draw_calls": calls,
		"vram_mb": snappedf(vram_mb, 0.01),
		"cam_pos": [snappedf(cam_pos.x, 0.001), snappedf(cam_pos.y, 0.001), snappedf(cam_pos.z, 0.001)],
	}
	if with_depth:
		rec["tree_far_p95_m"] = _tree_far_p95(_far_density())
		var gpu: Array = []
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		await _frames(2)
		for _i in range(GPU_FRAMES):
			await _frames(1)
			gpu.append(float(RenderingServer.viewport_get_measured_render_time_gpu(rid)))
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		rec["gpu_ms"] = snappedf(_median(gpu), 0.001)
		# the sky-only frame: the whole world hidden
		_world.visible = false
		var sky: Image = await _grab()
		sky.save_png(_out.path_join("%s-sky.png" % id))
		_world.visible = true
		rec["sky_png"] = _out.path_join("%s-sky.png" % id)
		var fwd_flat := Vector3(-_pc.global_basis.z.x, 0.0, -_pc.global_basis.z.z)
		# the camera, for the pixel metrics that turn a row into an angle or a world height
		rec["fov_deg"] = float(p["fov_deg"])
		rec["cam_fwd_y"] = snappedf(-_pc.global_basis.z.y, 0.000001)
		rec["cam_up_y"] = snappedf(_pc.global_basis.y.y, 0.000001)
		rec["horizon_row_px"] = snappedf(_pc.unproject_position(_pc.global_position + fwd_flat.normalized() * 100000.0).y, 0.1)
		# the depth frame
		var dimg: Image = await _depth_frame()
		dimg.save_png(_out.path_join("%s-depth.png" % id))
		rec["depth_png"] = _out.path_join("%s-depth.png" % id)
		# instrument check: pixels in the lower frame whose ray meets the engine's ground within 120 m; the depth frame
		# must agree with that distance where nothing stands in front, and must never read FARTHER than it
		var samples: Array = []
		for gy in range(6):
			for gx in range(12):
				var px := Vector2i(int((float(gx) + 0.5) / 12.0 * float(_size.x)), int(_size.y * (0.62 + 0.06 * float(gy))))
				var hit := _ground_hit_distance(cam_pos, _pc.project_ray_normal(Vector2(px)))
				if hit > 0.0 and hit < (54.0 if _view == "near" else 120.0):
					samples.append({"x": px.x, "y": px.y, "ground_m": snappedf(hit, 0.01)})
		rec["depth_check"] = samples
	return rec


## The 99th percentile of a list of milliseconds (0 when empty).
func _p99(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var v := a.duplicate()
	v.sort()
	return float(v[int(floor(0.99 * float(v.size() - 1)))])


func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[s.size() / 2])


## The frame again with every surface drawn by the depth shader against a white background.
func _depth_frame() -> Image:
	var saved: Array = []
	_override(_world, saved)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1, 1, 1)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	var prev_env := _pc.environment
	_pc.environment = env
	var img: Image = await _grab()
	_pc.environment = prev_env
	for e in saved:
		(e[0] as GeometryInstance3D).material_override = e[1]
	return img


func _override(n: Node, saved: Array) -> void:
	if n is GeometryInstance3D:
		var prev: Material = (n as GeometryInstance3D).material_override
		saved.append([n, prev])
		if _far != null and is_instance_valid(_far) and prev != null and prev == _far.tree_material():
			_depth_tree_mat.set_shader_parameter("sprite_cone", prev.get_shader_parameter("sprite_cone"))
			_depth_tree_mat.set_shader_parameter("sprite_round", prev.get_shader_parameter("sprite_round"))
			(n as GeometryInstance3D).material_override = _depth_tree_mat
		else:
			(n as GeometryInstance3D).material_override = _depth_mat
	for c in n.get_children():
		_override(c, saved)


## Distance along a ray to the engine's ground (the rendered surface), by marching and bisecting.
func _ground_hit_distance(origin: Vector3, dir: Vector3) -> float:
	var t := 0.0
	var step := 1.0
	var prev_t := 0.0
	while t < 3000.0:
		var p := origin + dir * t
		if p.y < float(StalagWorld.ground_envelope_at(p.x, p.z, TRUTH_CEIL_M)):
			var lo := prev_t
			var hi := t
			for _i in range(24):
				var mid := (lo + hi) * 0.5
				var q := origin + dir * mid
				if q.y < float(StalagWorld.ground_envelope_at(q.x, q.z, TRUTH_CEIL_M)):
					hi = mid
				else:
					lo = mid
			return hi
		prev_t = t
		t += step
		step = minf(step * 1.01, 4.0)
	return -1.0


## 95th percentile of the distance of the far terrain's drawn tree impostors inside the frustum, counting only
## those that fog hides at most 80 percent (the loaded chunks' own trees lie within 100 m and are a small share).
func _tree_far_p95(density: float) -> float:
	if _far == null or not is_instance_valid(_far):
		return 0.0
	var d: Array = []
	var origin := _pc.global_position
	for p in _far.drawn_tree_positions():
		var dist := origin.distance_to(p)
		var f := 1.0 - exp(-pow(density * dist, 2.0))
		if f <= MAX_FOG and _pc.is_position_in_frustum(p + Vector3(0.0, 4.0, 0.0)):
			d.append(dist)
	if d.is_empty():
		return 0.0
	d.sort()
	return snappedf(float(d[int(floor(0.95 * float(d.size() - 1)))]), 0.01)


# ---------------------------------------------------------------- measure mode
func _run_measure(pose_list: Array) -> void:
	var poses: Array = []
	var lod := {"present": false, "levels": [], "tris": 0}
	var hash_text := ""
	var fog := {}
	# Every pose gets a fresh world: the chunks a pose holds are the ring a player who entered there would hold, not
	# the leftovers of the pose before (the streamer unloads one chunk beyond its ring).
	for i in range(pose_list.size()):
		_stats_on = i == 0
		if not await _load_world(_view, _atmo, _mutate):
			return
		_stats_on = false
		var rec: Dictionary = await _measure_pose(pose_list[i], true)
		poses.append(rec)
		if i == 0 and _far != null:
			hash_text = _far.state_hash()
		if i < pose_list.size() - 1:
			await _unload_world()
	fog = _fog_of_world()
	if _far != null:
		lod = await _lod_record(hash_text)
	var gpu: Array = []
	for p in poses:
		gpu.append(float(p["gpu_ms"]))
	var raw := {
		"headless": DisplayServer.get_name() == "headless",
		"display": OS.get_environment("DISPLAY"),
		"adapter": RenderingServer.get_video_adapter_name(),
		"godot_version": str(Engine.get_version_info()["string"]),
		"xdg_data_home": OS.get_environment("XDG_DATA_HOME"),
		"view": _view,
		"atmosphere": _atmo,
		"mutate": _mutate,
		"size": [_size.x, _size.y],
		"gpu_ms_median": snappedf(_median(gpu), 0.001),
		"fog": fog,
		"lod": lod,
		"poses": poses,
	}
	var f := FileAccess.open(_out.path_join("raw.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(raw, "\t"))
	f.close()
	get_tree().quit(0)


func _fog_of_world() -> Dictionary:
	var density := _far_density()
	return {"density": snappedf(density, 0.00001), "f50_m": snappedf(sqrt(log(2.0)) / density, 0.01), "visible_limit_m": snappedf(sqrt(-log(1.0 - MAX_FOG)) / density, 0.01)}


## Everything about the far terrain that needs the engine: heights against the engine's own surface, coverage,
## the trees against the engine's own placements, the build cost and a 1,000 m traverse.
func _lod_record(hash_text: String) -> Dictionary:
	var lr := int(_streamer.load_radius)
	var levels: Array = _far.levels_info(lr)
	var rng := RandomNumberGenerator.new()
	rng.seed = 582
	var all_err: Array = []
	for l in range(levels.size()):
		var errs: Array = []
		var w: Rect2 = _far.window_rect(l)
		var inner: Rect2 = _far.window_rect(l - 1) if l > 0 else Rect2()
		var tries := 0
		while errs.size() < ERR_SAMPLES and tries < 20000:
			tries += 1
			var x := rng.randf_range(w.position.x, w.end.x)
			var z := rng.randf_range(w.position.y, w.end.y)
			if l > 0 and inner.has_point(Vector2(x, z)):
				continue
			if l == 0 and _chunk_loaded(x, z):
				continue
			var mh: float = _far.mesh_height_at(l, x, z)
			if is_nan(mh):
				continue
			var truth: float = StalagWorld.ground_envelope_at(x, z, TRUTH_CEIL_M)
			errs.append(absf(mh - truth))
		errs.sort()
		var sum := 0.0
		for e in errs:
			sum += float(e)
		levels[l]["err_samples"] = errs.size()
		levels[l]["err_mean_m"] = snappedf(sum / float(maxi(errs.size(), 1)), 0.0001)
		levels[l]["err_p95_m"] = snappedf(float(errs[int(floor(0.95 * float(errs.size() - 1)))]) if not errs.is_empty() else 999.0, 0.0001)
		all_err.append_array(errs)
	var tot := 0.0
	for e in all_err:
		tot += float(e)
	var tiers: Array = _far.tier_info()
	var tris := 0
	for lv in levels:
		tris += int(lv["tris"])
	var real_checked := 0
	var real_ok := 0
	for c in _far.real_chunks():
		if real_checked >= 6:
			break
		var built: PackedVector3Array = _far.real_positions(c)
		if built.is_empty():
			continue
		real_checked += 1
		var fresh := _engine_real_positions(c)
		if fresh == built:
			real_ok += 1
	var rec := {
		"present": true,
		"levels": levels,
		"radius_m": levels[levels.size() - 1]["outer_m"],
		"tris": tris,
		"build_ms_total": snappedf(_build_ms_total, 0.01),
		"step_ms_max": snappedf(_step_ms_max, 0.01),
		"step_ms_p99": snappedf(_p99(_step_list), 0.01),
		"adopt_ms_max": snappedf(_adopt_ms_max, 0.01),
		"adopt_ms_p99": snappedf(_p99(_adopt_list), 0.01),
		"collision_nodes": _far.count_collision(),
		"height_truth": "ground_envelope_at",
		"height_samples": all_err.size(),
		"height_err_mean_m": snappedf(tot / float(maxi(all_err.size(), 1)), 0.0001),
		"relief": _relief_record(rng),
		"rock": _rock_record(),
		"hash": hash_text,
		"coverage_gaps": _far.coverage_gaps(8.0),
		"overlap_frac": snappedf(_far.overlap_frac(7.0), 0.0001),
		"trees": {
			"tiers": tiers,
			"instances_total": _far.tree_total(),
			"real_checked_chunks": real_checked,
			"real_match": snappedf(float(real_ok) / float(maxi(real_checked, 1)), 0.0001),
			"hashed_instances": int(tiers[1]["instances"]),
		},
	}
	rec["traverse"] = await _traverse()
	return rec


## Relief in the highland ring (Chebyshev 346 to 840 m): the far terrain's height against the engine's rendered
## surface at random points (truth = ground_envelope_at with a finite ceiling), the tallest vertex of the tiles
## against the engine's own tallest height over the same covered ground, and the 90th percentile of tile relief
## (highest minus lowest vertex) per 100 m window.
func _relief_record(rng: RandomNumberGenerator) -> Dictionary:
	var errs: Array = []
	var tries := 0
	while errs.size() < RELIEF_SAMPLES and tries < 40000:
		tries += 1
		var x := rng.randf_range(-RELIEF_OUTER_M, RELIEF_OUTER_M)
		var z := rng.randf_range(-RELIEF_OUTER_M, RELIEF_OUTER_M)
		if maxf(absf(x), absf(z)) < RELIEF_INNER_M:
			continue
		var mh := _ring_mesh_height(x, z)
		if is_nan(mh):
			continue
		errs.append(absf(mh - float(StalagWorld.ground_envelope_at(x, z, TRUTH_CEIL_M))))
	errs.sort()
	var sum := 0.0
	for e in errs:
		sum += float(e)
	# the engine's tallest height over the ground the tiles cover there
	var engine_max := -1000.0
	var g := -RELIEF_OUTER_M
	while g <= RELIEF_OUTER_M:
		var gz := -RELIEF_OUTER_M
		while gz <= RELIEF_OUTER_M:
			if maxf(absf(g), absf(gz)) >= RELIEF_INNER_M and not is_nan(_ring_mesh_height(g, gz)):
				engine_max = maxf(engine_max, float(StalagWorld.surface_height(g / 0.125, gz / 0.125)) * 0.125)
			gz += RELIEF_GRID_M
		g += RELIEF_GRID_M
	var tile_max := -1000.0
	var cells := {}
	for l in [1, 2]:
		var rows: Dictionary = _far.vertex_rows(l, RELIEF_INNER_M)
		var xs: PackedFloat32Array = rows["x"]
		var zs: PackedFloat32Array = rows["z"]
		var hs: PackedFloat32Array = rows["h"]
		for i in range(hs.size()):
			tile_max = maxf(tile_max, hs[i])
			var key := Vector2i(floori(xs[i] / RELIEF_WINDOW_M), floori(zs[i] / RELIEF_WINDOW_M))
			if not cells.has(key):
				cells[key] = [hs[i], hs[i], 0]
			var c: Array = cells[key]
			c[0] = minf(c[0], hs[i])
			c[1] = maxf(c[1], hs[i])
			c[2] += 1
	var reliefs: Array = []
	for key in cells.keys():
		var c: Array = cells[key]
		if int(c[2]) >= WINDOW_MIN_VERTS:
			reliefs.append(float(c[1]) - float(c[0]))
	reliefs.sort()
	return {
		"samples": errs.size(),
		"truth_max_surface_m": TRUTH_CEIL_M,
		"engine_max_m": snappedf(engine_max, 0.01),
		"tile_max_m": snappedf(tile_max, 0.01),
		"err_mean_m": snappedf(sum / float(maxi(errs.size(), 1)), 0.0001),
		"err_p95_m": snappedf(float(errs[int(floor(0.95 * float(errs.size() - 1)))]) if not errs.is_empty() else 999.0, 0.0001),
		"window_p90_m": snappedf(float(reliefs[int(floor(0.9 * float(reliefs.size() - 1)))]) if not reliefs.is_empty() else 0.0, 0.01),
		"windows": reliefs.size(),
	}


## The height of the finest built tile beyond the full-detail ring at a point (NAN when no tile of level 2 or 3 covers it).
func _ring_mesh_height(x: float, z: float) -> float:
	for l in [1, 2]:
		var mh: float = _far.mesh_height_at(l, x, z)
		if not is_nan(mh):
			return mh
	return NAN


## Slope-derived rock facing of the outermost level (l3) beyond 346 m: the mean rock weight of the built vertex
## colours on steep vertices (normal y at most 0.8) and on flat ones (at least 0.97). rock_w is the Euclidean distance of
## the colour from the rock colour, against the distance of the high-ground colour from it, clamped to 0..1.
func _rock_record() -> Dictionary:
	var rows: Dictionary = _far.vertex_rows(2, RELIEF_INNER_M)
	var nys: PackedFloat32Array = rows["ny"]
	var cols: PackedColorArray = rows["col"]
	var rock: Color = _far.GROUND_ROCK
	var high: Color = _far.GROUND_HIGH
	var span := _rgb_dist(high, rock)
	var steep_n := 0
	var flat_n := 0
	var steep_sum := 0.0
	var flat_sum := 0.0
	for i in range(nys.size()):
		var w := clampf(1.0 - _rgb_dist(cols[i], rock) / span, 0.0, 1.0)
		if nys[i] <= 0.8:
			steep_n += 1
			steep_sum += w
		elif nys[i] >= 0.97:
			flat_n += 1
			flat_sum += w
	return {
		"level": "l3",
		"steep_n": steep_n,
		"flat_n": flat_n,
		"steep_rock_mean": snappedf(steep_sum / float(maxi(steep_n, 1)), 0.0001),
		"flat_rock_mean": snappedf(flat_sum / float(maxi(flat_n, 1)), 0.0001),
	}


func _rgb_dist(a: Color, b: Color) -> float:
	return sqrt((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b))


func _chunk_loaded(x: float, z: float) -> bool:
	var cm := StalagWorld.get_chunk_m()
	return _streamer.chunk_node(Vector2i(floori(x / cm), floori(z / cm))) != null


## The engine's own placements for a footprint chunk, as the far terrain should have kept them (dead forms left out).
func _engine_real_positions(c: Vector2i) -> PackedVector3Array:
	var out := PackedVector3Array()
	var d: Dictionary = StalagTrees.place_chunk(c.x, c.y)
	for id in d.keys():
		if ["standing-snag", "cut-stump"].has(id):
			continue
		var a: PackedFloat64Array = d[id]
		for q in range(a.size() / 14):
			out.append(Vector3(a[q * 14], a[q * 14 + 1] - 0.2, a[q * 14 + 2]))
	return out


## The focus walks 1,000 m east in steps; the streamer follows (inside the grid) and the far terrain re-plans. After
## every step the workers finish; the probe records the longest main-thread step, the longest adoption and the
## number of sample points that nothing covers.
func _traverse() -> Dictionary:
	_world.set_process(false)  # the probe drives the focus itself
	var step_max := 0.0
	var adopt_max := 0.0
	var step_all: Array = []
	var adopt_all: Array = []
	var gap_max := 0
	var steps := 0
	var x := 0.0
	for _i in range(TRAVERSE_STEPS):
		var pos := Vector3(x, 0.0, 0.0)
		_streamer.set_focus(pos)
		var tf0 := Time.get_ticks_usec()
		_far.set_focus(pos)  # the re-plan runs here on the main thread, once per chunk crossing
		var focus_ms := float(Time.get_ticks_usec() - tf0) / 1000.0
		step_max = maxf(step_max, focus_ms)
		step_all.append(focus_ms)
		var guard := 0
		while guard < TRAVERSE_FRAMES_MAX:
			var t0 := Time.get_ticks_usec()
			_far.adopt_pending()
			var t1 := Time.get_ticks_usec()
			_far.build_some()
			var t2 := Time.get_ticks_usec()
			adopt_max = maxf(adopt_max, float(t1 - t0) / 1000.0)
			step_max = maxf(step_max, float(t2 - t0) / 1000.0)
			step_all.append(float(t2 - t0) / 1000.0)
			adopt_all.append(float(t1 - t0) / 1000.0)
			await get_tree().process_frame
			guard += 1
			if _far.is_done() and _streamer.pending_count() == 0 and _streamer.settled():
				break
		gap_max = maxi(gap_max, _far.coverage_gaps(16.0))
		steps += 1
		x += TRAVERSE_STEP_M
	return {"steps": steps, "distance_m": snappedf(x - TRAVERSE_STEP_M, 0.1), "step_ms_max": snappedf(step_max, 0.01), "step_ms_p99": snappedf(_p99(step_all), 0.01), "adopt_ms_max": snappedf(adopt_max, 0.01), "adopt_ms_p99": snappedf(_p99(adopt_all), 0.01), "gap_max": gap_max}


# ---------------------------------------------------------------- sheet mode
## Three presets at the four gated poses (twelve frames), and the classic preset against the same frame with the
## atmosphere code bypassed (the control that shows applying `classic` changes nothing).
func _run_sheet(pose_list: Array) -> void:
	var gated: Array = []
	for p in pose_list:
		if bool(p["gated"]):
			gated.append(p)
	var cells: Array = []
	for preset in ["classic", "clear", "amber"]:
		if not await _load_world("horizon", preset, "none"):
			return
		for p in gated:
			var cam_pos: Vector3 = await _go_to_pose(p)
			var img: Image = await _grab()
			var path := _out.path_join("sheet-%s-%s.png" % [preset, p["id"]])
			img.save_png(path)
			cells.append({"preset": preset, "pose_id": str(p["id"]), "png": path, "cam_x": snappedf(cam_pos.x, 0.01)})
		await _unload_world()
	if not await _load_world("horizon", "classic", "noatmo"):
		return
	var noatmo_cells: Array = []
	for p in gated:
		await _go_to_pose(p)
		var img2: Image = await _grab()
		var path2 := _out.path_join("sheet-noatmo-%s.png" % p["id"])
		img2.save_png(path2)
		noatmo_cells.append({"preset": "noatmo", "pose_id": str(p["id"]), "png": path2})
	var raw := {
		"headless": DisplayServer.get_name() == "headless",
		"display": OS.get_environment("DISPLAY"),
		"adapter": RenderingServer.get_video_adapter_name(),
		"godot_version": str(Engine.get_version_info()["string"]),
		"size": [_size.x, _size.y],
		"cells": cells,
		"noatmo_cells": noatmo_cells,
	}
	var f := FileAccess.open(_out.path_join("raw.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(raw, "\t"))
	f.close()
	get_tree().quit(0)
