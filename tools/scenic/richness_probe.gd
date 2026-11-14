extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 580 richness probe. Loads the REAL world scene (res://game/world/world.tscn) exactly as
## tools/scenic/scenic_shots.gd does, puts a probe Camera3D at each of the three fixed poses in
## tools/scenic/bench_poses.json, and MEASURES. It has no content of its own: it never builds a mesh or a
## multimesh, it only reads what the game's streamer loaded. The frames are rendered with the game's OWN
## default look (sun, sky and fog untouched); tools/scenic/post.py (mode `richness`) reads the saved PNGs for
## the pixel statistics, judges the bars in richness_bars.json and writes richness.json.
##
## Per pose it records: loaded chunks and instance counts (read from the streamer), primitives, draw calls and
## video memory (read from the RenderingServer), and geometric far metrics from rays and instances:
##   far_ground_p90_m      90th percentile of the distance where a frame ray first meets ground, counting only
##                         hits that fog hides at most 80 percent (opacity 1 - exp(-(density * d)^2))
##   tree_far_p95_m        95th percentile of the distance of drawn trees in the frustum, same fog filter
##   unloaded_visible_hit  frame-grid rays whose fog-visible ground hit lies in a chunk that is not loaded
##   species_ge10          forms with at least 10 drawn instances in the frustum
##   bare_near_frac        share of ground hits within 100 m with no flora or understory instance within 1.5 m
## "Drawn" honours the game's own distance cull (visibility_range_end on a chunk's multimesh).
##
## Env: RICH_OUT (required) output dir; RICH_VIEW near|far|vista (default near); RICH_MUTATE none|thin.

const RichnessMetrics := preload("res://tools/scenic/richness_metrics.gd")
const WORLD_SCENE := "res://game/world/world.tscn"
const DEFAULT_POSES := "res://tools/scenic/bench_poses.json"
const EDGE_POSES := "res://tools/scenic/edge_poses.json"
const WIND_CLOCK := 3.0  ## the fixed wind clock of every pose
const WATER_TIME := 40.0  ## the fixed value the water shader reads instead of TIME
const FAR_M := 1200.0
const WORLD_HALF_M := 112.0
const FOCUS_AHEAD_M := 30.0
const GPU_FRAMES := 21
const AB_ROUNDS := 8
const NEAR_CHEB := 2  ## the near ring, for the interleaved GPU comparison

var _out := ""
var _view := "near"
var _mutate := "none"
var _size := Vector2i(1600, 900)
var _world: Node
var _streamer
var _walker
var _vp: SubViewport
var _pc: Camera3D


func _ready() -> void:
	_run()


func _fail(msg: String) -> void:
	push_error("richness_probe: " + msg)
	get_tree().quit(2)


func _frames(n: int) -> void:
	for _i in range(n):
		await RenderingServer.frame_post_draw


func _run() -> void:
	_out = OS.get_environment("RICH_OUT")
	_view = OS.get_environment("RICH_VIEW")
	if _view.is_empty():
		_view = "near"
	_mutate = OS.get_environment("RICH_MUTATE")
	if _mutate.is_empty():
		_mutate = "none"
	if _out.is_empty() or not ClassDB.class_exists("StalagWorld"):
		_fail("RICH_OUT is required and the engine must be loaded")
		return
	if not ["near", "far", "vista"].has(_view) or not ["none", "thin", "noskirt"].has(_mutate):
		_fail("bad RICH_VIEW or RICH_MUTATE")
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var doc = JSON.parse_string(FileAccess.get_file_as_string(DEFAULT_POSES))
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("poses"):
		_fail("cannot read the bench poses")
		return
	_size = Vector2i(int(doc["size"][0]), int(doc["size"][1]))

	get_viewport().disable_3d = true  # the window itself draws nothing; the SubViewport below does
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_pc = Camera3D.new()
	_pc.far = FAR_M
	_vp.add_child(_pc)
	RenderingServer.viewport_set_measure_render_time(_vp.get_viewport_rid(), true)

	var edge_doc = JSON.parse_string(FileAccess.get_file_as_string(EDGE_POSES))
	if typeof(edge_doc) != TYPE_DICTIONARY or not edge_doc.has("poses"):
		_fail("cannot read the edge poses")
		return
	var poses: Array = []
	var edge_poses: Array = []
	var backdrop := {}
	var fog := {}
	var tint := {}
	for p in doc["poses"]:
		if not await _load_world():
			return
		if fog.is_empty():
			fog = _fog_of_world()
			tint = _tint_of_world()
		poses.append(await _measure(p, float(fog["density"])))
		if backdrop.is_empty():
			backdrop = _backdrop_of_world()
		await _unload_world()
	for p in edge_doc["poses"]:
		if not await _load_world():
			return
		edge_poses.append(await _measure_edge(p))
		await _unload_world()

	var raw := {
		"headless": DisplayServer.get_name() == "headless",
		"display": OS.get_environment("DISPLAY"),
		"adapter": RenderingServer.get_video_adapter_name(),
		"godot_version": str(Engine.get_version_info()["string"]),
		"view": _view,
		"mutate": _mutate,
		"fog": fog,
		"tint": tint,
		"poses": poses,
		"edge_poses": edge_poses,
		"backdrop": backdrop,
	}
	var f := FileAccess.open(_out.path_join("raw.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(raw, "\t"))
	f.close()
	get_tree().quit(0)


# ---------------------------------------------------------------- the world
func _load_world() -> bool:
	_world = (load(WORLD_SCENE) as PackedScene).instantiate()
	_world.scripted_input = true
	_world.flora_clock = WIND_CLOCK
	_world.flora_clock_frozen = true
	if _view != "near" and not ("view_distance" in _world):
		_fail("the world has no view_distance property; only RICH_VIEW=near can be measured")
		return false
	if "view_distance" in _world:
		_world.view_distance = _view
	if _mutate == "noskirt":
		if not ("backdrop_enabled" in _world):
			_fail("the world has no backdrop_enabled property")
			return false
		_world.backdrop_enabled = false  # the negative control: the same view level without the ring
	if _mutate == "thin":
		# the streamer's own switches: no trees, no meadow, no understory (the negative control)
		var st = _world.get_node("Streamer")
		st.flora_enabled = false
		st.trees_enabled = false
		st.understory_enabled = false
	add_child(_world)
	_streamer = _world.streamer
	_walker = _world.walker
	var guard := 0
	while not _streamer.ring_ready() and guard < 6000:
		await get_tree().process_frame
		guard += 1
	if not _streamer.ring_ready():
		_fail("the world never became ready")
		return false
	guard = 0
	while _world.has_method("backdrop_ready") and not _world.backdrop_ready() and guard < 3000:
		await get_tree().process_frame  # the backdrop ring builds a few columns per frame
		guard += 1
	_freeze_water_time()
	await _settle()
	return true


## What the loaded world's backdrop ring holds (nothing at `near`, and nothing in the noskirt control).
func _backdrop_of_world() -> Dictionary:
	var b = _world.backdrop if "backdrop" in _world else null
	if b == null:
		return {"present": false, "tris": 0, "trees": 0, "water_cells": 0, "nodes": 0, "done": true, "collision_nodes": 0, "step_ms_max": 0.0, "build_ms_total": 0.0}
	return {"present": true, "tris": b.tris, "trees": b.trees, "water_cells": b.water_cells, "nodes": b.get_child_count(), "done": b.is_done(), "collision_nodes": _count_collision(b), "step_ms_max": snappedf(b.step_ms_max, 0.01), "build_ms_total": snappedf(b.build_ms_total, 0.1)}


## Collision objects anywhere under `n` (the ring is visual only: there must be none).
func _count_collision(n: Node) -> int:
	var k := 1 if n is CollisionObject3D else 0
	for c in n.get_children():
		k += _count_collision(c)
	return k


## An edge pose: the camera stands near the edge of the footprint and looks out. Three frames are saved for
## post.py: the normal one, one with every water mesh hidden (the water pixels are what changes) and one with the
## whole world hidden (pure sky), from which it counts the gap below the horizon and the floating water pixels.
func _measure_edge(p: Dictionary) -> Dictionary:
	var cam_xz: Array = p["cam"]
	var hd := deg_to_rad(float(p["heading_deg"]))
	var pitch_down := atan((0.5 - float(p["horizon_frac"])) * 2.0 * tan(deg_to_rad(float(p["fov_deg"])) * 0.5))
	var dir := Vector3(sin(hd) * cos(pitch_down), -sin(pitch_down), cos(hd) * cos(pitch_down))
	var half_m := WORLD_HALF_M - 8.0
	_teleport(clampf(float(cam_xz[0]), -half_m, half_m), clampf(float(cam_xz[1]), -half_m, half_m))
	await _settle()
	var ground: float = StalagWorld.ground_envelope_at(float(cam_xz[0]), float(cam_xz[1]), INF)
	var cam_pos := Vector3(float(cam_xz[0]), ground + float(p["height_m"]), float(cam_xz[1]))
	_pc.fov = float(p["fov_deg"])
	_pc.environment = _world.cam.environment
	_pc.global_position = cam_pos
	_pc.look_at(cam_pos + dir * 100.0, Vector3.UP)
	_pc.current = true
	_walker.body_node().visible = false
	await _frames(3)
	var id := str(p["id"])
	var img: Image = await _grab()
	img.save_png(_out.path_join("%s.png" % id))
	var waters: Array = _streamer.water_nodes()
	waters.append_array(get_tree().get_nodes_in_group("backdrop_water"))
	var prev := []
	for w in waters:
		prev.append(w.visible)
		w.visible = false
	var no_water: Image = await _grab()
	no_water.save_png(_out.path_join("%s-nowater.png" % id))
	for i in range(waters.size()):
		waters[i].visible = prev[i]
	_world.visible = false
	var sky: Image = await _grab()
	sky.save_png(_out.path_join("%s-sky.png" % id))
	_world.visible = true
	var fwd_flat := Vector3(-_pc.global_basis.z.x, 0.0, -_pc.global_basis.z.z)
	var far_pt := _pc.global_position + fwd_flat.normalized() * 100000.0
	var row := _pc.unproject_position(far_pt).y
	return {
		"id": id,
		"png": _out.path_join("%s.png" % id),
		"nowater_png": _out.path_join("%s-nowater.png" % id),
		"sky_png": _out.path_join("%s-sky.png" % id),
		"horizon_row_px": snappedf(row, 0.1),
	}


## The water shader animates from the engine's TIME, which differs on every run. Swap it for a uniform that holds
## one fixed value, so the same pose is the same picture (as tools/scenic/scenic_shots.gd does). The edit is
## made on the shader's text and checked: if the shader changes shape the run fails instead of going noisy.
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


func _unload_world() -> void:
	_streamer.shutdown()
	_world.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _settle() -> void:
	var guard := 0
	while guard < 3000:
		await get_tree().process_frame
		guard += 1
		if _streamer.focus_chunk() == _streamer.chunk_of(_walker.pos) and _streamer.settled():
			break
	var prev: Vector3 = _walker.pos
	var still := 0
	var g2 := 0
	while still < 6 and g2 < 600:
		await get_tree().process_frame
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


## The fog the live materials really carry (the grass material is the terrain's own).
func _fog_of_world() -> Dictionary:
	var mat: ShaderMaterial = _world.grass_mat
	var d = mat.get_shader_parameter("fog_density")
	if d == null:
		d = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), "fog_density")
	var density := float(d)
	return {"density": snappedf(density, 0.00001), "visible_limit_m": snappedf(RichnessMetrics.visible_limit_m(density), 0.01)}


## The living species' crown tints, read from the live materials' `tint` uniform.
func _tint_of_world() -> Dictionary:
	var hues: Array = []
	var sat_min := 1.0
	for m in _world.trees.materials():
		var c: Color = m.get_shader_parameter("tint")
		hues.append(c.h * 360.0)
		sat_min = minf(sat_min, c.s)
	hues.sort()
	var spread := 0.0
	var families := {}
	if not hues.is_empty():
		var biggest: float = (hues[0] + 360.0) - hues[hues.size() - 1]
		for i in range(1, hues.size()):
			biggest = maxf(biggest, hues[i] - hues[i - 1])
		spread = 360.0 - biggest
		for h in hues:
			families[int(floor(h / 15.0))] = true
	return {
		"living_species": hues.size(),
		"hue_spread_deg": snappedf(spread, 0.01),
		"hue_families": families.size(),
		"sat_min": snappedf(sat_min if not hues.is_empty() else 0.0, 0.0001),
	}


# ---------------------------------------------------------------- one pose
func _measure(p: Dictionary, density: float) -> Dictionary:
	var cam_xz: Array = p["cam"]
	var hd := deg_to_rad(float(p["heading_deg"]))
	var pitch_down := atan((0.5 - float(p["horizon_frac"])) * 2.0 * tan(deg_to_rad(float(p["fov_deg"])) * 0.5))
	var dir := Vector3(sin(hd) * cos(pitch_down), -sin(pitch_down), cos(hd) * cos(pitch_down))
	var half_m := WORLD_HALF_M - 8.0
	var ahead := [clampf(float(cam_xz[0]) + sin(hd) * FOCUS_AHEAD_M, -half_m, half_m), clampf(float(cam_xz[1]) + cos(hd) * FOCUS_AHEAD_M, -half_m, half_m)]
	_teleport(float(ahead[0]), float(ahead[1]))
	await _settle()

	var ground: float = StalagWorld.ground_envelope_at(float(cam_xz[0]), float(cam_xz[1]), INF)
	var cam_pos := Vector3(float(cam_xz[0]), ground + float(p["height_m"]), float(cam_xz[1]))
	_pc.fov = float(p["fov_deg"])
	_pc.environment = _world.cam.environment
	_pc.global_position = cam_pos
	_pc.look_at(cam_pos + dir * 100.0, Vector3.UP)
	_pc.current = true
	_walker.body_node().visible = false
	await _frames(3)

	var img: Image = await _grab()
	var id := str(p["id"])
	img.save_png(_out.path_join("%s.png" % id))
	var rid := _vp.get_viewport_rid()
	var prims := int(RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME))
	var calls := int(RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
	var vram_mb := float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0

	var rec := {
		"id": id,
		"png": _out.path_join("%s.png" % id),
		"chunks": _streamer.loaded_count(),
		"trees": _streamer.tree_instances,
		"flora": _streamer.flora_instances,
		"understory": _streamer.understory_instances,
		"prims": prims,
		"draw_calls": calls,
		"vram_mb": snappedf(vram_mb, 0.01),
	}
	rec.merge(RichnessMetrics.new(_pc, _streamer, _size).measure(density))
	var gpu: Dictionary = await _gpu(rec)
	rec.merge(gpu)
	return rec


func _grab() -> Image:
	await _frames(2)
	return _vp.get_texture().get_image()


# ---------------------------------------------------------------- GPU time (reported, never gated)
func _gpu_ms() -> float:
	return float(RenderingServer.viewport_get_measured_render_time_gpu(_vp.get_viewport_rid()))


func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[s.size() / 2])


## Median GPU milliseconds of the pose as loaded, and (for far and vista) an interleaved A/B against the same
## pose with the chunks beyond the near ring hidden and the flora cull lifted, i.e. what `near` would draw.
func _gpu(_rec: Dictionary) -> Dictionary:
	var a: Array = []
	for _i in range(GPU_FRAMES):
		await _frames(1)
		a.append(_gpu_ms())
	var out := {"gpu_ms_median": snappedf(_median(a), 0.001), "gpu_ab_ratio": null}
	if _view == "near":
		return out
	var hidden: Array = []
	var ranged: Array = []
	for coord in _streamer.chunk_coords():
		var node: Node3D = _streamer.chunk_node(coord)
		if maxi(absi(coord.x - _streamer.focus_chunk().x), absi(coord.y - _streamer.focus_chunk().y)) > NEAR_CHEB:
			hidden.append(node)
		else:
			for g in node.get_children():
				for m in g.get_children():
					if m is MultiMeshInstance3D and (m as MultiMeshInstance3D).visibility_range_end > 0.0 and str(g.name) != "Trees":
						ranged.append([m, (m as MultiMeshInstance3D).visibility_range_end])
	var va: Array = []
	var vb: Array = []
	for _r in range(AB_ROUNDS):
		await _frames(2)
		va.append(_gpu_ms())
		for h in hidden:
			h.visible = false
		for e in ranged:
			e[0].visibility_range_end = 0.0
		await _frames(2)
		vb.append(_gpu_ms())
		for h in hidden:
			h.visible = true
		for e in ranged:
			e[0].visibility_range_end = e[1]
	var mb := _median(vb)
	out["gpu_ab_ratio"] = snappedf(_median(va) / mb, 0.001) if mb > 0.0 else null
	return out
