extends Node
## Spec #501 walk probe: drives the REAL world scene (streamer + walker + follow camera)
## in the MAIN project on a real renderer, and MEASURES. It never judges: the DoD's jq
## does. Output schema is the "verify_stalag_walk.sh" contract in spec-501.md.
##
## Env: STALAG_PROBE_RAW   output JSON path (required)
##      STALAG_SHOTS_DIR   screenshot directory (required)
##      STALAG_MUTATE      none | sync_build | float | sink (negative controls: they must
##                         make the matching detector fire)
##
## Ground truth for float / sink / no-ground / camera-underground is an INDEPENDENT
## down-ray (mesh_ray.gd) against the triangle arrays handed to the renderer for each
## chunk -- not the controller's own occupancy query. All ray work is done AFTER the walk
## so it cannot pollute the frame-cost samples.

const WorldModule := preload("res://game/world/world_module.gd")
const RoutePlanner := preload("res://engine/stalag/tests/route_planner.gd")
const MeshRay := preload("res://engine/stalag/tests/mesh_ray.gd")
const MeshStats := preload("res://engine/stalag/tests/mesh_stats.gd")

const WARMUP_FRAMES := 90
const BASELINE_FRAMES := 700
const WALK_TARGETS := [Vector2(60, -20), Vector2(104, 10), Vector2(100, 60), Vector2(50, 70), Vector2(0, 40)]
const WINDOW_S := 1.0
const WALK_TIMEOUT_S := 240.0
const SHOT_W := 1280
const SHOT_H := 720

var _mutation := "none"
var _raw_path := ""
var _shots_dir := ""
var _world: Node3D
var _streamer: Node3D
var _walker: Node3D
var _cam: Camera3D
var _ray: MeshRay
var _rec := {}

# frame cost samples (ms)
var _frame_baseline := PackedFloat64Array()
var _frame_walk := PackedFloat64Array()
# DIAGNOSTIC (not what DoD-12 reads): scene-tree cost of the frame, process_frame -> frame_pre_draw
# (all _process work, excluding draw and present), recorded next to each spec-metric sample.
var _cpu_baseline := PackedFloat64Array()
var _cpu_walk := PackedFloat64Array()
var _walk_marks: Array = []  # per walk frame: [loads, unloads] (to attribute cpu spikes)
var _t_frame_start_us := 0
var _cpu_last_ms := 0.0

# per-frame walk rows: [t, x, y, z, body_y, grounded, speed, cam_x, cam_y, cam_z, boom]
var _rows: Array = []
var _route: Array = []
var _edge_max_abs := 0.0
var _min_feet_y := 1e9
var _ctrl := {}


func _ready() -> void:
	_raw_path = OS.get_environment("STALAG_PROBE_RAW")
	_shots_dir = OS.get_environment("STALAG_SHOTS_DIR")
	var m := OS.get_environment("STALAG_MUTATE")
	_mutation = m if not m.is_empty() else "none"
	if _raw_path.is_empty() or _shots_dir.is_empty():
		push_error("walk_probe: STALAG_PROBE_RAW and STALAG_SHOTS_DIR are required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	_run()


func _frame() -> void:
	await get_tree().process_frame


func _frame_cost_ms() -> float:
	var proc := (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	return proc + RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())


func _run() -> void:
	StalagChunkMesher.reset_build_stats()
	_ray = MeshRay.new(StalagWorld.get_chunk_m())
	_world = WorldModule.instantiate_world()
	if _world == null:
		push_error("walk_probe: world scene unavailable")
		get_tree().quit(3)
		return
	_streamer = _world.get_node("Streamer")
	_walker = _world.get_node("Walker")
	_cam = _world.get_node("Camera")
	_world.scripted_input = true
	_streamer.chunk_built.connect(func(c: Vector2i, v: PackedVector3Array) -> void: _ray.add_chunk(c, v))
	if _mutation == "sync_build":
		_streamer.sync_build = true
	add_child(_world)
	if _mutation == "float":
		_walker.body_offset_y = 0.8
	elif _mutation == "sink":
		_walker.body_offset_y = -0.3
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	get_tree().process_frame.connect(func() -> void: _t_frame_start_us = Time.get_ticks_usec())
	RenderingServer.frame_pre_draw.connect(func() -> void: _cpu_last_ms = (Time.get_ticks_usec() - _t_frame_start_us) / 1000.0)

	print("walk_probe: waiting for the streamed ring (mutation=%s)" % _mutation)
	await _wait_ring(120.0)
	print("walk_probe: ring ready, loaded=%d" % _streamer.loaded_count())
	await _phase_baseline()
	print("walk_probe: baseline done")
	await _phase_walk()
	print("walk_probe: walk done, rows=%d" % _rows.size())
	await _phase_controller_tests()
	await _phase_camera_tests()
	print("walk_probe: scripted tests done")
	_collect_stream_stats()
	_post_analysis()
	print("walk_probe: analysis done")
	await _phase_shots()
	await _finish()


func _wait_ring(timeout_s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not _streamer.ring_ready() or _streamer.pending_count() > 0:
		await _frame()
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			push_error("walk_probe: ring never became ready")
			break


# ---------------------------------------------------------------- baseline
func _phase_baseline() -> void:
	_walker.input_move = Vector2.ZERO
	for _i in range(WARMUP_FRAMES):
		await _frame()
	for _i in range(BASELINE_FRAMES):
		await _frame()
		_frame_baseline.append(_frame_cost_ms())
		_cpu_baseline.append(_cpu_last_ms)


# ---------------------------------------------------------------- walk
func _phase_walk() -> void:
	var limit := StalagWorld.get_half_extent_m() - 1.0
	_route = RoutePlanner.plan(Vector2(_walker.pos.x, _walker.pos.z), WALK_TARGETS, limit)
	if _route.is_empty():
		push_error("walk_probe: could not plan a route")
		return
	var idx := 1
	var t := 0.0
	var win_t := 0.0
	var win_dist := 0.0
	var windows := 0
	var wedge := 0
	var route_len := 0.0
	var max_r := 0.0
	var y_min := 1e9
	var y_max := -1e9
	var max_speed := 0.0
	var prev := Vector2(_walker.pos.x, _walker.pos.z)
	var last_us := Time.get_ticks_usec()
	var boom_min := 1e9
	var boom_max := 0.0
	while idx < _route.size() and t < WALK_TIMEOUT_S:
		await _frame()
		var now_us := Time.get_ticks_usec()
		var dt := minf((now_us - last_us) / 1e6, 0.1)
		last_us = now_us
		var p2 := Vector2(_walker.pos.x, _walker.pos.z)
		var to: Vector2 = (_route[idx] as Vector2) - p2
		while to.length() < 0.6 and idx < _route.size() - 1:
			idx += 1
			to = (_route[idx] as Vector2) - p2
		if idx >= _route.size() - 1 and to.length() < 0.6:
			break
		_walker.input_move = to.normalized()
		# Mouse-look sweep through the real input pipeline: pitch hits both limits.
		var ev := InputEventMouseMotion.new()
		ev.relative = Vector2(cos(t * 0.5) * 4.0, cos(t * 0.52) * 9.0)
		Input.parse_input_event(ev)

		t += dt
		var step := p2.distance_to(prev)
		prev = p2
		route_len += step
		win_dist += step
		win_t += dt
		if win_t >= WINDOW_S:
			windows += 1
			if win_dist < 0.5 * _walker.WALK_SPEED * win_t:
				wedge += 1
			win_t = 0.0
			win_dist = 0.0
		max_r = maxf(max_r, p2.length())
		y_min = minf(y_min, _walker.pos.y)
		y_max = maxf(y_max, _walker.pos.y)
		var spd: float = _walker.speed_xz()
		max_speed = maxf(max_speed, spd)
		_edge_max_abs = maxf(_edge_max_abs, maxf(absf(_walker.pos.x), absf(_walker.pos.z)))
		_min_feet_y = minf(_min_feet_y, _walker.pos.y)
		var boom: float = _cam.boom_length(_walker.pos)
		boom_min = minf(boom_min, boom)
		boom_max = maxf(boom_max, boom)
		var body: Node3D = _walker.body_node()
		_rows.append([t, _walker.pos.x, _walker.pos.y, _walker.pos.z, body.global_position.y, 1 if _walker.on_ground else 0, spd, _cam.global_position.x, _cam.global_position.y, _cam.global_position.z, boom])
		_frame_walk.append(_frame_cost_ms())
		_cpu_walk.append(_cpu_last_ms)
		_walk_marks.append([_streamer.stats["loads"], _streamer.stats["unloads"]])
	_ctrl["route_len_m"] = route_len
	_ctrl["max_radius_m"] = max_r
	_ctrl["y_range_m"] = y_max - y_min
	_ctrl["avg_speed_mps"] = route_len / maxf(t, 1e-6)
	_ctrl["max_speed_mps"] = max_speed
	_ctrl["windows_checked"] = windows
	_ctrl["wedge_windows"] = wedge
	_ctrl["walk_time_s"] = t
	_rec["camera_boom"] = {"min": boom_min, "max": boom_max}
	_walker.input_move = Vector2.ZERO


# ---------------------------------------------------------------- controller scripted tests
func _ground(x: float, z: float) -> float:
	return StalagWorld.ground_envelope_at(x, z, INF)


func _place(x: float, z: float) -> void:
	_walker.teleport(Vector3(x, _ground(x, z), z), true)
	_cam.follow(_walker.pos)


func _settle(frames: int) -> void:
	for _i in range(frames):
		await _frame()


## Holds `dir` for up to max_s; returns when `stop` (a Callable returning bool) is true.
func _drive(dir: Vector2, max_s: float, stop: Callable) -> float:
	var t := 0.0
	var last_us := Time.get_ticks_usec()
	_walker.input_move = dir
	while t < max_s:
		await _frame()
		var now_us := Time.get_ticks_usec()
		t += minf((now_us - last_us) / 1e6, 0.1)
		last_us = now_us
		_track()
		if stop.call():
			break
	_walker.input_move = Vector2.ZERO
	return t


func _track() -> void:
	_edge_max_abs = maxf(_edge_max_abs, maxf(absf(_walker.pos.x), absf(_walker.pos.z)))
	_min_feet_y = minf(_min_feet_y, _walker.pos.y)


func _phase_controller_tests() -> void:
	await _test_stepup()
	await _test_wall()
	await _test_jump()
	await _test_edge()
	_ctrl["grounded_samples"] = 0  # filled by _post_analysis


func _test_stepup() -> void:
	var site := Vector2.ZERO
	var rise := 0.0
	var found := false
	for xi in range(-40, 40):
		for zi in range(-40, 40):
			var x := xi * 0.5
			var z := zi * 0.5
			var h0 := _ground(x - 0.5, z)
			var a := _ground(x, z)
			var b := _ground(x + 1.0, z)
			if absf(a - h0) <= 0.05 and b - h0 >= 0.9 and b - h0 <= 1.0 and not StalagWorld.blocked_between(x - 0.5, z, h0 + 1.05, h0 + 1.7):
				site = Vector2(x, z)
				rise = b - h0
				found = true
				break
		if found:
			break
	var climbed := false
	if found:
		_place(site.x - 0.5, site.y)
		await _settle(30)
		var y0: float = _walker.pos.y
		var goal_x := site.x + 1.6
		await _drive(Vector2(1, 0), 4.0, func() -> bool: return _walker.pos.x >= goal_x)
		await _settle(20)
		climbed = _walker.pos.x >= site.x + 1.0 and _walker.pos.y >= y0 + rise - 0.06
	_ctrl["stepup"] = {"rise_m": rise, "climbed": climbed, "site": [site.x, site.y], "found": found}


func _test_wall() -> void:
	# The demo mesa in front of spawn: a 2 m tall block whose west face is a wall.
	var sx := 0.0
	var sz := 0.0
	_place(sx, sz)
	await _settle(30)
	var base_y: float = _walker.pos.y
	var top_y := _ground(5.0, 0.0)
	await _drive(Vector2(1, 0), 4.0, func() -> bool: return false)
	var x_end: float = _walker.pos.x
	var y_end: float = _walker.pos.y
	await _settle(10)
	# still held against the wall for another second: it must not creep through
	await _drive(Vector2(1, 0), 1.0, func() -> bool: return false)
	var x_after: float = _walker.pos.x
	_ctrl["wall"] = {
		"height_m": top_y - base_y,
		"blocked": x_after < 5.0 and (_walker.pos.y - base_y) <= _walker.MAX_STEP + 0.05 and absf(x_after - x_end) < 0.05,
		"base_y": base_y,
		"feet_y": _walker.pos.y,
		"x_stop": x_after,
		"z": _walker.pos.z,
		"y_rise_m": y_end - base_y,
		"max_penetration_m": 0.0,  # filled by _post_analysis against the mesh front plane
	}


func _test_jump() -> void:
	# a flat patch near spawn: the 9 sample points within 3 cm
	var spot := Vector2(0.0, -6.0)
	var best := 1e9
	for xi in range(-30, 30):
		for zi in range(-30, 30):
			var x := xi * 0.5
			var z := zi * 0.5
			var lo := 1e9
			var hi := -1e9
			for dx in [-0.6, 0.0, 0.6]:
				for dz in [-0.6, 0.0, 0.6]:
					var h := _ground(x + dx, z + dz)
					lo = minf(lo, h)
					hi = maxf(hi, h)
			if hi - lo < best and absf(x) + absf(z) > 8.0 and hi - lo <= 0.03:
				best = hi - lo
				spot = Vector2(x, z)
				if best <= 0.0:
					break
		if best <= 0.0:
			break
	_place(spot.x, spot.y)
	await _settle(40)
	var y0: float = _walker.pos.y
	var apex := 0.0
	var air_t := 0.0
	var landed := false
	var land_y := y0
	var left_ground := false
	_walker.input_jump = true
	var last_us := Time.get_ticks_usec()
	var guard := 0
	while guard < 400:
		guard += 1
		await _frame()
		var now_us := Time.get_ticks_usec()
		var dt := minf((now_us - last_us) / 1e6, 0.1)
		last_us = now_us
		_walker.input_jump = false
		if not _walker.on_ground:
			left_ground = true
			air_t += dt
			apex = maxf(apex, _walker.pos.y - y0)
		elif left_ground:
			landed = true
			land_y = _walker.pos.y
			break
	_ctrl["jump"] = {"apex_m": apex, "landed": landed, "air_s": air_t, "land_err_m": absf(land_y - y0), "spot": [spot.x, spot.y]}


func _test_edge() -> void:
	# Push into the east edge from the far end of the planned route.
	var start := Vector2(100.0, 10.0)
	if not _route.is_empty():
		var far: Vector2 = _route[0]
		for p in _route:
			if (p as Vector2).x > far.x:
				far = p
		start = far
	_place(start.x, start.y)
	await _settle(30)
	await _drive(Vector2(1, 0), 8.0, func() -> bool: return false)
	var x_east: float = _walker.pos.x
	# and into the north-south walls from there for good measure
	await _drive(Vector2(0, 1), 8.0, func() -> bool: return false)
	var z_north: float = _walker.pos.z
	_ctrl["edge_probe"] = {"x_reached": x_east, "z_reached": z_north}


# ---------------------------------------------------------------- camera tests
func _phase_camera_tests() -> void:
	_place(0.0, 0.0)
	await _settle(10)
	var yaw0: float = _cam.yaw
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(200, 0)
	Input.parse_input_event(ev)
	await _settle(3)
	var yaw_delta := absf(_cam.yaw - yaw0)
	var up := InputEventMouseMotion.new()
	up.relative = Vector2(0, 100000)
	Input.parse_input_event(up)
	await _settle(3)
	var pitch_hi: float = _cam.pitch
	var down := InputEventMouseMotion.new()
	down.relative = Vector2(0, -100000)
	Input.parse_input_event(down)
	await _settle(3)
	var pitch_lo: float = _cam.pitch
	_rec["camera_mouse"] = {
		"yaw_delta": yaw_delta,
		"pitch_hi": pitch_hi,
		"pitch_lo": pitch_lo,
		"clamped": is_equal_approx(pitch_hi, _cam.PITCH_MAX) and is_equal_approx(pitch_lo, _cam.PITCH_MIN),
	}
	_cam.pitch = 0.4


# ---------------------------------------------------------------- stats & analysis
func _collect_stream_stats() -> void:
	var ms := StalagChunkMesher.get_build_stats()
	var mi_count := 0
	for ch in _streamer.get_children():
		if ch is MeshInstance3D:
			mi_count += 1
	var st: Dictionary = _streamer.stats
	_rec["streaming"] = {
		"mesher": "StalagChunkMesher" if int(ms["builds"]) >= int(st["loads"]) and int(ms["builds"]) > 0 else "unknown",
		"mesher_builds": ms["builds"],
		"boundaries_crossed": st["boundaries_crossed"],
		"cap": _streamer.cap(),
		"max_loaded": st["max_loaded"],
		"loads": st["loads"],
		"unloads": st["unloads"],
		"build_on_main_thread": ms["on_main_thread"],
		"loaded_end": _streamer.loaded_count(),
		"mesh_instances_end": mi_count,
	}


func _post_analysis() -> void:
	# --- independent ground truth over every recorded walk frame
	var no_ground := 0
	var floats := 0
	var sinks := 0
	var grounded := 0
	var underground := 0
	var cam_checked := 0
	for r in _rows:
		var x: float = r[1]
		var z: float = r[3]
		var body_y: float = r[4]
		var g: int = r[5]
		var h := _ray.height_at(x, z, body_y + 1.0)
		if is_nan(h):
			no_ground += 1
		else:
			if g == 1:
				grounded += 1
				if body_y - h > 0.5:
					floats += 1
			if body_y - h < -0.05:
				sinks += 1
		var ch := _ray.height_at(r[7], r[9], r[8] + 20.0)
		if not is_nan(ch):
			cam_checked += 1
			if ch > r[8] + 0.02:
				underground += 1
	_ctrl["grounded_samples"] = grounded
	_ctrl["no_ground_frames"] = no_ground
	_ctrl["float_violations"] = floats
	_ctrl["sink_violations"] = sinks
	_ctrl["edge"] = {"max_abs_m": _edge_max_abs, "min_y_m": _min_feet_y}
	# --- wall penetration: horizontal rays along the facing direction, at body-band heights and
	# across the body width, against the rendered mesh. Penetration = how far the body circle's
	# leading edge sits beyond the first mesh surface the ray meets.
	var w: Dictionary = _ctrl["wall"]
	var pen := 0.0
	var front_x := INF
	for hy in [1.1, 1.4, 1.65]:
		for dz in [-0.25, 0.0, 0.25]:
			var edge: float = w["x_stop"] + sqrt(maxf(0.0, _walker.BODY_RADIUS * _walker.BODY_RADIUS - dz * dz))
			var hit := _ray.first_hit_x(w["x_stop"] - _walker.BODY_RADIUS, w["x_stop"] + 2.0, w["feet_y"] + hy, w["z"] + dz)
			if hit < INF:
				front_x = minf(front_x, hit)
				pen = maxf(pen, edge - hit)
	w["front_plane_x"] = front_x
	w["max_penetration_m"] = maxf(0.0, pen)
	_ctrl["wall"] = w
	_rec["controller"] = _ctrl
	var cam: Dictionary = _rec["camera_mouse"]
	var boom: Dictionary = _rec["camera_boom"]
	_rec["camera"] = {
		"dist_min": boom["min"],
		"dist_max": boom["max"],
		"yaw_after_mouse_rad": cam["yaw_delta"],
		"pitch_clamped": cam["clamped"],
		"underground_frac": float(underground) / maxf(1.0, float(_rows.size())),
		"frames_checked": cam_checked,
	}
	var fb := _frame_stats(_frame_baseline)
	var fw := _frame_stats(_frame_walk)
	var cb := _frame_stats(_cpu_baseline)
	var cw := _frame_stats(_cpu_walk)
	for k in ["p95_ms", "max_ms", "mean_ms"]:
		fb["cpu_" + k] = cb[k]
		fw["cpu_" + k] = cw[k]
	# the five costliest walk frames and whether a chunk was adopted/freed around them
	var order: Array = range(_cpu_walk.size())
	order.sort_custom(func(a: int, b: int) -> bool: return _cpu_walk[a] > _cpu_walk[b])
	var spikes: Array = []
	for i in order.slice(0, 5):
		var prev: Array = _walk_marks[maxi(0, i - 1)]
		var cur: Array = _walk_marks[i]
		spikes.append({"frame": i, "cpu_ms": _cpu_walk[i], "chunk_loaded_this_frame": cur[0] != prev[0], "chunk_unloaded_this_frame": cur[1] != prev[1]})
	fw["cpu_worst_frames"] = spikes
	_rec["frame"] = {
		"baseline": fb,
		"walk": fw,
		"metric": "samples = TIME_PROCESS + TIME_PHYSICS_PROCESS + viewport CPU render time (spec-501 contract); cpu_* = process_frame to frame_pre_draw, scene-tree work only (diagnostic)",
	}
	_check_placement()


func _max_comp(v: Vector3) -> float:
	return maxf(v.x, maxf(v.y, v.z))


func _frame_stats(a: PackedFloat64Array) -> Dictionary:
	if a.is_empty():
		return {"samples": 0, "p95_ms": 0.0, "max_ms": 0.0, "mean_ms": 0.0}
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	return {"samples": s.size(), "p95_ms": s[mini(s.size() - 1, int(ceil(0.95 * s.size())) - 1)], "max_ms": s[s.size() - 1], "mean_ms": sum / s.size()}


## Streamed chunk nodes vs a direct engine build of the same region (content + placement).
func _check_placement() -> void:
	var coords: Array = _streamer.chunk_coords()
	var fc: Vector2i = _streamer.chunk_of(_walker.pos)
	coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - fc).length_squared() < (b - fc).length_squared())
	var chunk_m: float = StalagWorld.get_chunk_m()
	var checked := 0
	var mismatch := 0
	var err := 0.0
	var picks: Array = []
	for i in [0, 1, 2, coords.size() / 2, coords.size() - 1]:
		if i >= 0 and i < coords.size() and not picks.has(coords[i]):
			picks.append(coords[i])
	for c in picks:
		var mi: MeshInstance3D = _streamer.chunk_node(c)
		var arrays: Array = mi.mesh.surface_get_arrays(0)
		var local: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var xf := mi.global_transform
		var world_v := PackedVector3Array()
		world_v.resize(local.size())
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for k in range(local.size()):
			var p := xf * local[k]
			world_v[k] = p
			lo = lo.min(p)
			hi = hi.max(p)
		var x0: float = c.x * chunk_m
		var z0: float = c.y * chunk_m
		var direct := StalagChunkMesher.build_region_arrays(x0, x0 + chunk_m, z0, z0 + chunk_m)
		var db: PackedVector3Array = direct["base"]["vertices"]
		var dc: PackedVector3Array = direct["caps"]["vertices"]
		var dall := PackedVector3Array()
		dall.append_array(db)
		dall.append_array(dc)
		var dlo := Vector3(INF, INF, INF)
		var dhi := Vector3(-INF, -INF, -INF)
		for p2 in dall:
			dlo = dlo.min(p2)
			dhi = dhi.max(p2)
		var same := world_v.size() == dall.size() and MeshStats.centroid_q_sum(world_v) == MeshStats.centroid_q_sum(dall)
		checked += 1
		if not same:
			mismatch += 1
		err = maxf(err, maxf(_max_comp((lo - dlo).abs()), _max_comp((hi - dhi).abs())))
	var st: Dictionary = _rec["streaming"]
	st["chunk_checked"] = checked
	st["chunk_mismatch"] = mismatch
	st["placement_err_m"] = err
	_rec["streaming"] = st


# ---------------------------------------------------------------- screenshots
func _phase_shots() -> void:
	var screens: Array = []
	# background reference: hide the terrain and the body, read a sky pixel
	_streamer.visible = false
	_walker.body_node().visible = false
	_place(0.0, 0.0)
	_cam.yaw = _world.SPAWN_YAW
	await _settle(6)
	var sky := _grab().get_pixel(8, 8)
	_streamer.visible = true
	_walker.body_node().visible = true

	# 1) the spawn view
	_place(0.0, 0.0)
	_cam.yaw = _world.SPAWN_YAW
	_walker.face_direction(Vector2(_cam.forward_xz().x, _cam.forward_xz().z))
	_streamer.set_focus(_walker.pos)
	await _wait_ring(60.0)
	await _settle(30)
	screens.append(await _capture("screen_1_spawn", sky))

	# 2) walking across a chunk boundary
	var chunk_m: float = StalagWorld.get_chunk_m()
	var bx := chunk_m  # first +x boundary east of spawn
	_place(bx - 6.0, 0.0)
	await _settle(30)
	_walker.input_move = Vector2(1, 0)
	var t0 := Time.get_ticks_msec()
	while _walker.pos.x < bx + 0.6 and Time.get_ticks_msec() - t0 < 15000:
		await _frame()
	await _settle(4)
	screens.append(await _capture("screen_2_boundary", sky, true))

	# 3) ridged terrain far out: the planned route's far point, looking back toward spawn
	var far: Vector2 = Vector2(100, 10)
	for p in _route:
		if (p as Vector2).length() > far.length() and absf((p as Vector2).x) < 106.0:
			far = p
	_walker.input_move = Vector2.ZERO
	_place(far.x, far.y)
	_cam.yaw = PI / 2.0
	_walker.face_direction(Vector2(_cam.forward_xz().x, _cam.forward_xz().z))
	_streamer.set_focus(_walker.pos)
	await _wait_ring(60.0)
	await _settle(40)
	screens.append(await _capture("screen_3_ridged", sky))
	_rec["screens"] = screens


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	return img


## Freeze the world, grab the frame with the body shown and again hidden, and measure.
## When `keep_moving` the walker keeps its stride pose (frozen, not zeroed).
func _capture(shot_name: String, sky: Color, keep_moving: bool = false) -> Dictionary:
	_walker.process_mode = Node.PROCESS_MODE_DISABLED
	_cam.process_mode = Node.PROCESS_MODE_DISABLED
	_streamer.process_mode = Node.PROCESS_MODE_DISABLED
	if not keep_moving:
		_walker.input_move = Vector2.ZERO
	await _settle(3)
	var with_body := _grab()
	var path := "%s/%s.png" % [_shots_dir, shot_name]
	with_body.save_png(path)
	_walker.body_node().visible = false
	await _settle(3)
	var without := _grab()
	_walker.body_node().visible = true
	var w := with_body.get_width()
	var h := with_body.get_height()
	var a := with_body.get_data()
	var b := without.get_data()
	var diff_px := 0
	var non_bg := 0
	var lower_total := 0
	var seen := {}
	var sky_r := int(round(sky.r * 255.0))
	var sky_g := int(round(sky.g * 255.0))
	var sky_b := int(round(sky.b * 255.0))
	for y in range(h):
		for x in range(w):
			var o := (y * w + x) * 3
			var r := a[o]
			var g := a[o + 1]
			var bl := a[o + 2]
			if absi(r - b[o]) > 8 or absi(g - b[o + 1]) > 8 or absi(bl - b[o + 2]) > 8:
				diff_px += 1
			if y >= h / 2:
				lower_total += 1
				if absi(r - sky_r) > 6 or absi(g - sky_g) > 6 or absi(bl - sky_b) > 6:
					non_bg += 1
			if (x & 3) == 0 and (y & 3) == 0:
				seen[(r << 16) | (g << 8) | bl] = true
	var rec := {
		"file": path,
		"w": w,
		"h": h,
		"lower_nonbg_frac": float(non_bg) / maxf(1.0, float(lower_total)),
		"distinct_colors": seen.size(),
		"body_diff_px": diff_px,
		"pos": [_walker.pos.x, _walker.pos.y, _walker.pos.z],
	}
	_walker.process_mode = Node.PROCESS_MODE_INHERIT
	_cam.process_mode = Node.PROCESS_MODE_INHERIT
	_streamer.process_mode = Node.PROCESS_MODE_INHERIT
	return rec


# ---------------------------------------------------------------- finish
func _finish() -> void:
	_walker.input_move = Vector2.ZERO
	_world.request_exit()
	remove_child(_world)
	_world.queue_free()
	for _i in range(5):
		await _frame()
	var st: Dictionary = _rec["streaming"]
	st["orphan_nodes_end"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_rec["streaming"] = st
	_rec["generated_epoch"] = Time.get_unix_time_from_system()
	_rec["mutation"] = _mutation
	_rec["headless"] = DisplayServer.get_name() == "headless"
	_rec["adapter"] = RenderingServer.get_video_adapter_name()
	_rec["project_name"] = str(ProjectSettings.get_setting("application/config/name"))
	_rec["classes"] = {"StalagWorld": ClassDB.class_exists("StalagWorld"), "StalagChunkMesher": ClassDB.class_exists("StalagChunkMesher")}
	_rec["scale"] = {"sf": StalagWorld.get_sf()}
	_rec.erase("camera_mouse")
	_rec.erase("camera_boom")
	var f := FileAccess.open(_raw_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(_rec))
	f.close()
	get_tree().quit(0)
