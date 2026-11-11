extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #549 real-renderer forest, understory and crown-shadow probe (frozen Stalag prototype, tag
## prototype-final, is the reference). It only MEASURES: tests/verify_stalag_treeview.sh runs it on the
## xvfb display and the DoD's jq judges. Definitions follow the "Probe contracts" section of spec-549.md:
## seating is read back from the MultiMesh buffers the renderer was GIVEN and rayed against the chunk
## meshes handed to the renderer (observer frame), never the placement list; visibility, motion and
## shadows are measured on rendered frames of the same viewport.
##
## Env: TREEVIEW_PROBE_RAW   output JSON path (required)
##      TREEVIEW_SHOTS_DIR   screenshot directory (required)
##      TREEVIEW_ORACLE_DIR  directory written by tools/baseline/js_trees_oracle.mjs (required)
##      TREEVIEW_MUTATE      none | trees_hidden | float | sunk | wind_off | flutter_off | flutter_frozen |
##                           alpha_solid | tint_flat | sync_trees | clock_split | shadows_off | understory_hidden |
##                           tier_swap_render | shrub_flutter_off | u_sprite_flip | u_float
##      TREEVIEW_SKIP        perf (development only: the record then carries zero perf samples)
##      TREEVIEW_PERF_ONLY / TREEVIEW_PERF_ROUNDS / TREEVIEW_PERF_CONFIGS   development only: the perf A/B alone

const WorldModule := preload("res://game/world/world_module.gd")
const MeshRay := preload("res://engine/stalag/tests/mesh_ray.gd")
const RoutePlanner := preload("res://engine/stalag/tests/route_planner.gd")
const TreeAssets := preload("res://game/world/tree_assets.gd")
const UnderstoryAssets := preload("res://game/world/understory_assets.gd")

const WALK_ANCHORS := [Vector2(60, -20), Vector2(104, 10), Vector2(100, 60), Vector2(50, 70), Vector2(0, 40)]
const PERF_WARMUP := 90
const PERF_SAMPLES := 1700
const PERF_ROUNDS := 5
const PERF_VIEWPORT := Vector2i(1920, 1080)  # the default window size of the game
const PERF_STEP_DT := 1.0 / 60.0  # walking time per sampled frame
const PIX_TOL := 4  # per-channel difference (0..255) that counts as a changed pixel
const POSES := 6
const SPRITE_SCALE := 6
const MOVE_DT := 0.4  # seconds between the two frames of a motion pair

var _mutation := "none"
var _raw := ""
var _shots_dir := ""
var _oracle: Dictionary = {}
var _world: Node3D
var _streamer: Node3D
var _walker: Node3D
var _ray: MeshRay
var _cam: Camera3D
var _rec := {}
var _shots: Array = []
var _t_frame_us := 0
var _cpu_last_ms := 0.0
var _perf_vp: SubViewport
var _trees_before_plan := 0
var _understory_before_plan := 0
var _poses: Array = []  # the accepted poses [{pos, fwd, ...}]
var _motion_pose := 0
var _cands: Array = []  # ranked candidates; a candidate becomes a pose only if its rendered frames pass


func _ready() -> void:
	_raw = OS.get_environment("TREEVIEW_PROBE_RAW")
	_shots_dir = OS.get_environment("TREEVIEW_SHOTS_DIR")
	var odir := OS.get_environment("TREEVIEW_ORACLE_DIR")
	var m := OS.get_environment("TREEVIEW_MUTATE")
	_mutation = m if not m.is_empty() else "none"
	if _raw.is_empty() or _shots_dir.is_empty() or odir.is_empty():
		push_error("treeview_probe: TREEVIEW_PROBE_RAW, TREEVIEW_SHOTS_DIR, TREEVIEW_ORACLE_DIR are required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	_oracle = JSON.parse_string(FileAccess.get_file_as_string(odir.path_join("oracle.json")))
	_run()


func _frame() -> void:
	await get_tree().process_frame


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _vp() -> RID:
	return get_viewport().get_viewport_rid()


# ---------------------------------------------------------------- world lifecycle
# trees / understory / shadows: which of the three are built for this world (the perf A/B configurations)
func _spawn_world(trees_on: bool, under_on: bool, shadows_on: bool, offscreen: bool = false) -> void:
	StalagChunkMesher.reset_build_stats()
	StalagFlora.reset_build_stats()
	StalagTrees.reset_build_stats()
	StalagUnderstory.reset_build_stats()
	_ray = MeshRay.new(StalagWorld.get_chunk_m())
	_world = WorldModule.instantiate_world()
	_streamer = _world.get_node("Streamer")
	_walker = _world.get_node("Walker")
	_world.scripted_input = true
	_streamer.trees_enabled = trees_on
	_streamer.understory_enabled = under_on
	_streamer.shadows_enabled = shadows_on and _mutation != "shadows_off"
	_streamer.chunk_built.connect(func(c: Vector2i, v: PackedVector3Array) -> void: _ray.add_chunk(c, v))
	_streamer.trees_attached.connect(func(_c: Vector2i) -> void:
		if not StalagWorld.plan_ready():
			_trees_before_plan += 1)
	_streamer.understory_attached.connect(func(_c: Vector2i) -> void:
		if not StalagWorld.plan_ready():
			_understory_before_plan += 1)
	if _mutation == "sync_trees":
		_streamer.sync_trees = true
	elif _mutation == "float":
		_streamer.trees_y_offset = 0.5
	elif _mutation == "sunk":
		_streamer.trees_y_offset = -0.5
	elif _mutation == "u_float":
		_streamer.understory_y_offset = 0.5
	if offscreen:
		# the perf A/B renders the world into an offscreen viewport of PERF_VIEWPORT (see _perf_rounds)
		_perf_vp = SubViewport.new()
		_perf_vp.size = PERF_VIEWPORT
		_perf_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(_perf_vp)
		RenderingServer.viewport_set_measure_render_time(_perf_vp.get_viewport_rid(), true)  # without it the timer reads 0.0
		_perf_vp.add_child(_world)
	else:
		add_child(_world)
	if trees_on:
		if _mutation == "wind_off":
			_world.trees.disable_wind()
			_world.trees.set_flutter_amp(0.0)
		elif _mutation == "flutter_off":
			_world.trees.set_flutter_amp(0.0)
		elif _mutation == "flutter_frozen":
			_world.trees.set_leaf_rate(0.0)  # every per-cell time term stops: the flutter phase never advances
		elif _mutation == "alpha_solid":
			_world.trees.alpha_solid(true)
		elif _mutation == "tint_flat":
			_world.trees.tint_flat(true)
	if under_on:
		if _mutation == "shrub_flutter_off":
			_world.understory.set_voxel_amps(0.03, 0.0)
		elif _mutation == "u_sprite_flip":
			for m in _world.understory.materials():
				if m.shader.code.find("flip_v") != -1:
					m.set_shader_parameter("flip_v", true)
	if _mutation == "clock_split":
		RenderingServer.frame_pre_draw.connect(func() -> void:
			if _world != null:
				_world.trees.set_time(_world.flora_clock + 0.5))


func _free_world() -> void:
	_streamer.shutdown()
	_world.request_exit()
	_world.get_parent().remove_child(_world)
	_world.queue_free()
	_world = null
	if _perf_vp != null:
		remove_child(_perf_vp)
		_perf_vp.queue_free()
		_perf_vp = null


func _wait_settled(timeout_s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not (_streamer.ring_ready() and _streamer.settled()):
		await _frame()
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			push_error("treeview_probe: ring never settled")
			break
	await _frames(5)
	if _mutation == "tier_swap_render":
		_swap_flower_tiers()
	if _mutation == "tint_flat":
		_flatten_instance_colors()


func _run() -> void:
	var nodes_before := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	RenderingServer.viewport_set_measure_render_time(_vp(), true)
	get_tree().process_frame.connect(func() -> void: _t_frame_us = Time.get_ticks_usec())
	RenderingServer.frame_pre_draw.connect(func() -> void: _cpu_last_ms = (Time.get_ticks_usec() - _t_frame_us) / 1000.0)

	var t_assets := Time.get_ticks_usec()
	var _ta := TreeAssets.new()
	var _ua := UnderstoryAssets.new()
	var assets_load_ms := (Time.get_ticks_usec() - t_assets) / 1000.0

	if not OS.get_environment("TREEVIEW_PERF_ONLY").is_empty():
		# development only: the perf A/B alone (the record carries nothing else)
		var po := await _perf_rounds()
		var pf := FileAccess.open(_raw, FileAccess.WRITE)
		pf.store_string(JSON.stringify({"perf": po["perf"], "adopt": po["adopt"]}))
		pf.close()
		get_tree().quit(0)
		return
	_spawn_world(true, true, true)
	await _wait_settled(240.0)
	print("treeview_probe: ring settled, chunks=%d" % _streamer.loaded_count())
	_rec["ring"] = _ring_stats()
	_rec["seating"] = _seat("Trees", func(n: String) -> bool: return n.ends_with("_trunk"))
	_rec["understory_seating"] = _seat("Understory", func(_n: String) -> bool: return true)
	print("treeview_probe: seating done")
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 600.0
	_cam.environment = _world.get_node("Camera").environment
	add_child(_cam)
	_cam.make_current()
	_walker.visible = false
	_world.flora_clock_frozen = true
	_choose_poses()
	await _visibility_motion_shadows()
	print("treeview_probe: visibility, motion and shadows done")
	_cam.queue_free()
	_rec["look"] = await _look()
	var ul := await _understory_look()
	_rec["understory_look"] = ul
	print("treeview_probe: look done")
	_rec["wind_feed"] = await _wind_feed()
	_rec["shadows"]["distance_limit_m"] = _shadow_distance()
	_rec["lifecycle"] = _lifecycle_live()
	var tris := _ring_tris()
	_free_world()
	await _frames(5)
	_rec["lifecycle"]["nodes_after_shutdown"] = _count_named(get_tree().root, "Trees") + _count_named(get_tree().root, "Understory")

	var perf := {"off": {"samples": 0}, "trees": {"samples": 0}, "shadows": {"samples": 0}, "full": {"samples": 0}}
	var adopt := {"n": 0, "p95_ms": 0.0, "max_ms": 0.0}
	var skip := OS.get_environment("TREEVIEW_SKIP")
	if (_mutation == "none" or _mutation == "sync_trees") and skip != "perf":
		var pr := await _perf_rounds()
		perf = pr["perf"]
		adopt = pr["adopt"]
	perf["ring_tris"] = tris
	perf["adopt"] = adopt
	perf["assets_load_ms"] = assets_load_ms
	_rec["perf"] = perf
	await _frames(5)
	_rec["lifecycle"]["orphans"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_rec["lifecycle"]["node_delta"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - nodes_before
	_rec["shots"] = _shots
	_rec["adapter"] = RenderingServer.get_video_adapter_name()
	_rec["project_name"] = str(ProjectSettings.get_setting("application/config/name"))
	_rec["classes"] = {
		"StalagWorld": ClassDB.class_exists("StalagWorld"), "StalagChunkMesher": ClassDB.class_exists("StalagChunkMesher"),
		"StalagTrees": ClassDB.class_exists("StalagTrees"), "StalagUnderstory": ClassDB.class_exists("StalagUnderstory"),
		"StalagFlora": ClassDB.class_exists("StalagFlora"), "StalagWind": ClassDB.class_exists("StalagWind"),
	}
	_rec["plan"] = {"js_hash": _oracle["plan_hash"], "gd_hash": StalagWorld.plan_hash()}
	var f := FileAccess.open(_raw, FileAccess.WRITE)
	f.store_string(JSON.stringify(_rec))
	f.close()
	get_tree().quit(0)


# ---------------------------------------------------------------- helpers over the live ring
func _roots(name: String) -> Array:
	var out: Array = []
	for c in _streamer.chunk_coords():
		var mi: Node = _streamer.chunk_node(c)
		var root := mi.get_node_or_null(name)
		if root != null:
			out.append([c, mi, root])
	return out


func _count_named(n: Node, nm: String) -> int:
	var c := 1 if n.name == nm else 0
	for ch in n.get_children():
		c += _count_named(ch, nm)
	return c


func _id_of(node_name: String) -> String:
	return node_name.rsplit("_", true, 1)[0] if node_name.find("_") != -1 else node_name


func _set_trees_visible(on: bool) -> void:
	if _mutation == "trees_hidden":
		on = false  # the negative control: the trees are built but never shown
	for item in _roots("Trees"):
		(item[2] as Node3D).visible = on


func _set_understory_visible(on: bool, flowers: bool = true, shrubs: bool = true) -> void:
	if _mutation == "understory_hidden":
		on = false
	for item in _roots("Understory"):
		for n in (item[2] as Node).get_children():
			var is_flower := String(n.name).begins_with("flower-")
			if (is_flower and flowers) or (not is_flower and shrubs):
				(n as Node3D).visible = on


func _mm_sum(root_name: String, keep: Callable) -> int:
	var n := 0
	for item in _roots(root_name):
		for mmi in (item[2] as Node).get_children():
			if keep.call(String(mmi.name)):
				n += (mmi as MultiMeshInstance3D).multimesh.instance_count
	return n


func _ring_stats() -> Dictionary:
	var forms := {}
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			var nm := String(mmi.name)
			if nm.ends_with("_trunk") and (mmi as MultiMeshInstance3D).multimesh.instance_count > 0:
				forms[_id_of(nm)] = true
	var on_main := int(StalagFlora.get_build_stats()["on_main_thread"]) + int(StalagTrees.get_build_stats()["on_main_thread"]) \
		+ int(StalagUnderstory.get_build_stats()["on_main_thread"])
	return {
		"chunks": _streamer.loaded_count(),
		"trees": _mm_sum("Trees", func(n: String) -> bool: return n.ends_with("_trunk")),
		"oracle_trees": int(_oracle["placement"]["ring"]["trees"]),
		"forms_present": forms.size(),
		"flora_instances": _mm_sum("Flora", func(_n: String) -> bool: return true),
		"flowers": _mm_sum("Understory", func(n: String) -> bool: return n.begins_with("flower-")),
		"shrubs": _mm_sum("Understory", func(n: String) -> bool: return not n.begins_with("flower-")),
		"trees_before_plan": _trees_before_plan,
		"understory_before_plan": _understory_before_plan,
		"on_main_thread_builds": on_main,
	}


func _lifecycle_live() -> Dictionary:
	var tree_roots := _roots("Trees")
	var mmi_max := 0
	var shadow_max := 0
	for item in tree_roots:
		var n := 0
		var sh := 0
		for m in (item[2] as Node).get_children():
			if (m as MultiMeshInstance3D).has_meta("cast") and int(m.get_meta("cast")) == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
				sh += 1
			else:
				n += 1
		mmi_max = maxi(mmi_max, n)
		shadow_max = maxi(shadow_max, sh)
	var u_roots := _roots("Understory")
	var u_max := 0
	for item in u_roots:
		u_max = maxi(u_max, (item[2] as Node).get_child_count())
	return {
		"tree_roots": tree_roots.size(),
		"chunks_with_trees_expected": int(_oracle["placement"]["ring"]["chunks_with_trees"]),
		"understory_roots": u_roots.size(),
		"chunks_with_understory_expected": int(_oracle["flowers"]["ring"]["chunks_with"]),
		"mmi_per_chunk_max": mmi_max,  # trunk and crown MultiMeshes (the shadow proxies are counted apart)
		"shadow_mmi_per_chunk_max": shadow_max,
		"understory_mmi_per_chunk_max": u_max,
	}


## 1 m grid of a water mesh's triangles (chunk-local xz) for point-in-triangle tests.
func _water_grid(wnode: MeshInstance3D) -> Dictionary:
	var grid := {}
	if wnode == null or wnode.mesh == null:
		return grid
	var v: PackedVector3Array = (wnode.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for t in range(0, v.size() - 2, 3):
		var x0 := minf(v[t].x, minf(v[t + 1].x, v[t + 2].x))
		var x1 := maxf(v[t].x, maxf(v[t + 1].x, v[t + 2].x))
		var z0 := minf(v[t].z, minf(v[t + 1].z, v[t + 2].z))
		var z1 := maxf(v[t].z, maxf(v[t + 1].z, v[t + 2].z))
		for gx in range(floori(x0), floori(x1) + 1):
			for gz in range(floori(z0), floori(z1) + 1):
				var k := Vector2i(gx, gz)
				if not grid.has(k):
					grid[k] = []
				grid[k].append(t)
	grid["_v"] = v
	return grid


func _in_water(grid: Dictionary, lx: float, lz: float) -> bool:
	if grid.is_empty():
		return false
	var k := Vector2i(floori(lx), floori(lz))
	if not grid.has(k):
		return false
	var v: PackedVector3Array = grid["_v"]
	for t in grid[k]:
		var a := v[t]
		var b := v[t + 1]
		var c := v[t + 2]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-12:
			continue
		var w0 := ((b.z - c.z) * (lx - c.x) + (c.x - b.x) * (lz - c.z)) / d
		var w1 := ((c.z - a.z) * (lx - c.x) + (a.x - c.x) * (lz - c.z)) / d
		if w0 >= 0.0 and w1 >= 0.0 and 1.0 - w0 - w1 >= 0.0:
			return true
	return false


## True when a column next to (x, z) stands on a higher 4-lattice terrace than the column at (x, z).
func _higher_neighbour(x: float, z: float) -> bool:
	var sf: float = StalagWorld.get_sf()
	var lx := x / sf
	var lz := z / sf
	var own: float = floor(StalagWorld.surface_height(lx, lz) / 4.0)
	for d in [[4, 0], [-4, 0], [0, 4], [0, -4], [4, 4], [-4, -4], [4, -4], [-4, 4], [2, 2], [-2, -2], [2, -2], [-2, 2]]:
		if floor(StalagWorld.surface_height(lx + d[0], lz + d[1]) / 4.0) > own:
			return true
	return false


# ---------------------------------------------------------------- seating (read back from the renderer)
# err = origin.y - the rendered surface at the root; floating = err above 2 cm (any instance); buried and
# off-mesh are judged on non-overhung instances; overhung is the meadow's definition verbatim (the
# rendered surface 2 to 45 cm above the root AND an adjacent column on a higher terrace).
func _seat(root_name: String, keep: Callable) -> Dictionary:
	var checked := 0
	var missed := 0
	var floating := 0
	var under := 0
	var overhung := 0
	var overhung_buried_max := 0.0
	var off_exp := 0
	var buried_exp := 0
	var max_err_exp := 0.0
	var per_form := {}
	for item in _roots(root_name):
		var coord: Vector2i = item[0]
		var chunk: Node3D = item[1]
		var wgrid := _water_grid(_streamer.water_node(coord))
		for mmi in (item[2] as Node).get_children():
			var nm := String(mmi.name)
			if not keep.call(nm):
				continue
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			var id := _id_of(nm)
			per_form[id] = int(per_form.get(id, 0)) + mm.instance_count
			for i in range(mm.instance_count):
				var t := mm.get_instance_transform(i)
				var wx := chunk.position.x + t.origin.x
				var wz := chunk.position.z + t.origin.z
				var oy := t.origin.y
				var hit := _ray.height_at(wx, wz, oy + 1.5)
				checked += 1
				if is_nan(hit):
					missed += 1
					continue
				var err := oy - hit
				var over := false
				if hit - oy > 0.02 and hit - oy <= 0.45:
					over = _higher_neighbour(wx, wz)
				if err > 0.02:
					floating += 1
				if over:
					overhung += 1
					overhung_buried_max = maxf(overhung_buried_max, hit - oy)
				else:
					max_err_exp = maxf(max_err_exp, absf(err))
					if absf(err) > 0.02:
						off_exp += 1
					if err < -0.02:
						buried_exp += 1
				if _in_water(wgrid, t.origin.x, t.origin.z):
					under += 1
	var pf := []
	for id in per_form.keys():
		pf.append({"id": id, "n": per_form[id]})
	return {
		"checked": checked, "ray_missed": missed, "max_abs_err_exposed_m": max_err_exp, "off_mesh_exposed": off_exp,
		"buried_exposed": buried_exp, "floating": floating, "under_water": under, "overhung": overhung,
		"overhung_buried_max_m": overhung_buried_max, "per_form": pf,
	}


# ---------------------------------------------------------------- images
func _capture() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _save(img: Image, nm: String) -> void:
	var path := "%s/%s.png" % [_shots_dir, nm]
	img.save_png(path)
	_shots.append({"file": path, "w": img.get_width(), "h": img.get_height()})


# {n, changed, dist_sum, darker, luma_sum, mask}: changed pixels (any channel beyond PIX_TOL) over all
# rows from y0, optionally restricted to a mask; `darker` counts those where `a` is darker than `b`.
func _diff(a: Image, b: Image, y0: int, mask: PackedByteArray = PackedByteArray()) -> Dictionary:
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var changed := 0
	var dist_sum := 0.0
	var darker := 0
	var luma_sum := 0.0
	var use_mask := not mask.is_empty()
	var out_mask := PackedByteArray()
	out_mask.resize(w * h)
	for y in range(y0, h):
		var row := y * w
		for x in range(w):
			var i := (row + x) * 3
			var dr := absi(da[i] - db[i])
			var dg := absi(da[i + 1] - db[i + 1])
			var dbb := absi(da[i + 2] - db[i + 2])
			if dr > PIX_TOL or dg > PIX_TOL or dbb > PIX_TOL:
				if use_mask and mask[row + x] == 0:
					continue
				changed += 1
				out_mask[row + x] = 1
				dist_sum += sqrt(float(dr * dr + dg * dg + dbb * dbb))
				var la := 0.2126 * da[i] + 0.7152 * da[i + 1] + 0.0722 * da[i + 2]
				var lb := 0.2126 * db[i] + 0.7152 * db[i + 1] + 0.0722 * db[i + 2]
				if la < lb:
					darker += 1
				luma_sum += lb - la
	return {"n": (h - y0) * w, "changed": changed, "dist_sum": dist_sum, "darker": darker, "luma_sum": luma_sum, "mask": out_mask}


func _frac(d: Dictionary) -> float:
	return float(d["changed"]) / float(maxi(d["n"], 1))


func _dist(d: Dictionary) -> float:
	return float(d["dist_sum"]) / float(maxi(d["changed"], 1))


func _mask_px(mask: PackedByteArray) -> int:
	var n := 0
	for v in mask:
		n += v
	return n


# ---------------------------------------------------------------- poses
# Candidate eye positions on a 12 m grid, 6 headings, ranked by what the frustum holds (no occlusion
# yet); the six best that are 16 m apart become the poses, each then measured through the rays.
func _items(root_name: String, keep: Callable) -> Array:
	var out: Array = []
	for item in _roots(root_name):
		var chunk: Node3D = item[1]
		for mmi in (item[2] as Node).get_children():
			if not keep.call(String(mmi.name)):
				continue
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			for i in range(mm.instance_count):
				var o := mm.get_instance_transform(i).origin
				out.append(Vector3(chunk.position.x + o.x, o.y, chunk.position.z + o.z))
	return out


func _frustum_count(items: Array, marker: float, pos: Vector3, fwd: Vector3, max_dist: float = 1e9) -> int:
	var th := tan(deg_to_rad(70.0) / 2.0)
	var asp := 1280.0 / 720.0
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd)
	var n := 0
	for p: Vector3 in items:
		var d := p + Vector3(0.0, marker, 0.0) - pos
		var z := d.dot(fwd)
		if z <= 0.05 or z > max_dist:
			continue
		if absf(d.dot(right)) > z * th * asp or absf(d.dot(up)) > z * th:
			continue
		n += 1
	return n


func _choose_poses() -> void:
	var trees := _items("Trees", func(n: String) -> bool: return n.ends_with("_trunk"))
	var flowers := _items("Understory", func(n: String) -> bool: return n.begins_with("flower-"))
	var shrubs := _items("Understory", func(n: String) -> bool: return not n.begins_with("flower-"))
	var cands: Array = []
	for gx in range(-48, 49, 12):
		for gz in range(-48, 49, 12):
			var ground := _ray.height_at(float(gx), float(gz), 200.0)
			if is_nan(ground):
				continue
			for k in range(6):
				var yaw := float(k) * 1.0472 + 0.2
				var fwd := Vector3(cos(yaw), -0.08, sin(yaw)).normalized()
				var pos := Vector3(float(gx), ground + 1.7, float(gz))
				var nt := _frustum_count(trees, 3.0, pos, fwd, 90.0)
				var nf := _frustum_count(flowers, 0.5, pos, fwd, 18.0)
				var ns := _frustum_count(shrubs, 0.5, pos, fwd, 18.0)
				var score := minf(float(nt) / 200.0, minf(float(nf) / 250.0, float(ns) / 70.0))
				cands.append([score, pos, fwd, nt, nf, ns])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	_cands.clear()
	for c in cands:
		var ok := true
		for p in _cands:
			var dp: Vector3 = (p["pos"] as Vector3) - (c[1] as Vector3)
			if Vector2(dp.x, dp.z).length() < 16.0:
				ok = false
				break
		if ok:
			_cands.append({"pos": c[1], "fwd": c[2], "trees": c[3], "flowers": c[4], "shrubs": c[5]})
		if _cands.size() >= 24:
			break
	_poses.clear()


func _place(k: int) -> void:
	_place_dict(_poses[k])


func _place_dict(p: Dictionary) -> void:
	_cam.global_position = p["pos"]
	_cam.look_at(p["pos"] + p["fwd"], Vector3.UP)


func _occluded(from: Vector3, to: Vector3) -> bool:
	var dist := from.distance_to(to)
	var steps := int(dist / 0.5)
	for s in range(1, steps):
		var q := from.lerp(to, float(s) * 0.5 / dist)
		var th := _ray.height_at(q.x, q.z, 1000.0)
		if not is_nan(th) and q.y < th - 0.05:
			return true
	return false


# instances whose marker (root + `marker` m) is in the camera frustum and not occluded by the mesh
# (counted up to `cap`: the contract floors are far below it and every ray costs; the record says so)
func _in_view(items: Array, marker: float, cap: int) -> int:
	var n := 0
	var cpos := _cam.global_position
	for p: Vector3 in items:
		if n >= cap:
			break
		var m := p + Vector3(0.0, marker, 0.0)
		if _cam.is_position_behind(m) or not _cam.is_position_in_frustum(m):
			continue
		if not _occluded(cpos, m):
			n += 1
	return n


func _set_clock(t: float) -> void:
	_world.flora_clock = t


func _feed_all(strength: float) -> void:
	_world.flora.force_strength(strength)
	_world.trees.force_strength(strength)
	_world.understory.force_strength(strength)


func _feed_front(n: Vector2, off: float, pk: float, unlock: bool = false) -> void:
	_world.flora.force_front(n, off, pk, unlock)
	_world.trees.force_front(n, off, pk, unlock)
	_world.understory.force_front(n, off, pk, unlock)


func _moving(masks: Dictionary, ta: float, tb: float) -> Dictionary:
	_set_clock(ta)
	await _frames(3)
	var a := await _capture()
	_set_clock(tb)
	await _frames(3)
	var b := await _capture()
	var out := {}
	for k in masks.keys():
		out[k] = int(_diff(a, b, 0, masks[k])["changed"])
	return out


# sum of the moving pixel counts of every mask over three clock pairs (dt apart)
func _sum_moving(masks: Dictionary, dt: float) -> Dictionary:
	var total := {}
	for k in masks.keys():
		total[k] = 0
	for t0 in [10.0, 25.0, 40.0]:
		var r := await _moving(masks, t0, t0 + dt)
		for k in masks.keys():
			total[k] += r[k]
	return total


func _visibility_motion_shadows() -> void:
	var trees := _items("Trees", func(n: String) -> bool: return n.ends_with("_trunk"))
	var flowers := _items("Understory", func(n: String) -> bool: return n.begins_with("flower-"))
	var shrubs := _items("Understory", func(n: String) -> bool: return not n.begins_with("flower-"))
	var vis := []
	var uvis := []
	var sdiffs := []
	var first_masks := {}
	var best_q := -1.0
	var best_pose := 0
	for cand in _cands:
		if vis.size() >= POSES:
			break
		var k := vis.size()
		_place_dict(cand)
		_set_clock(10.0)
		_water_visible(false)  # the water animates by itself; it would be noise in every shown-against-hidden pair
		_set_trees_visible(true)
		_set_understory_visible(true)
		await _frames(3)
		var shown := await _capture()
		_set_trees_visible(false)
		await _frames(3)
		var no_trees := await _capture()
		_set_trees_visible(true)
		_set_understory_visible(false)
		await _frames(3)
		var no_under := await _capture()
		_set_understory_visible(true)
		_water_visible(true)
		var d_t := _diff(shown, no_trees, 0)
		var d_u := _diff(shown, no_under, 0)
		# a candidate is kept only if its rendered frames show what the poses are for (the floors of the
		# contract with a margin); one that does not is dropped, never tuned
		var tree_ok: bool = _mutation == "trees_hidden" or _frac(d_t) >= 0.06
		var under_ok: bool = _mutation == "understory_hidden" or _frac(d_u) >= 0.02
		if not (tree_ok and under_ok):
			continue
		var in_t := _in_view(trees, 3.0, 300)
		var in_f := _in_view(flowers, 0.5, 400)
		var in_s := _in_view(shrubs, 0.5, 150)
		if (in_t < 60 or in_f < 120 or in_s < 40) and _mutation != "trees_hidden" and _mutation != "understory_hidden":
			continue
		_save(shown, "pose%d_shown" % k)
		_save(no_trees, "pose%d_trees_hidden" % k)
		_save(no_under, "pose%d_understory_hidden" % k)
		vis.append({"name": "pose%d" % k, "in_view": in_t, "in_view_cap": 300, "diff_frac": _frac(d_t), "mean_rgb_dist": _dist(d_t)})
		uvis.append({"name": "pose%d" % k, "flowers_in_view": in_f, "shrubs_in_view": in_s, "in_view_caps": [400, 150],
			"diff_frac": _frac(d_u), "mean_rgb_dist": _dist(d_u)})
		_poses.append(cand)
		# crown shadows: A everything on, S the tree casters off, S2 a frame later still off; the water
		# animates by itself, so it is hidden for these three frames
		_water_visible(false)
		await _frames(3)
		var sa := await _capture()
		_streamer.set_shadows(false)
		await _frames(3)
		var s1 := await _capture()
		await _frames(2)
		var s2 := await _capture()
		_streamer.set_shadows(_mutation != "shadows_off")
		_water_visible(true)
		var d_as := _diff(sa, s1, 0)
		var d_ss := _diff(s1, s2, 0)
		sdiffs.append({"name": "pose%d" % k, "diff_frac": _frac(d_as), "darker_frac": float(d_as["darker"]) / float(maxi(d_as["changed"], 1)),
			"noise_floor_frac": _frac(d_ss), "mean_luma_drop": float(d_as["luma_sum"]) / float(maxi(d_as["changed"], 1))})
		# class masks for the understory: flowers only, shrubs only (the motion pose is the one that holds most)
		_set_understory_visible(false, true, false)
		await _frames(3)
		var no_fl := await _capture()
		_set_understory_visible(true)
		_set_understory_visible(false, false, true)
		await _frames(3)
		var no_sh := await _capture()
		_set_understory_visible(true)
		var m_fl: PackedByteArray = _diff(shown, no_fl, 0)["mask"]
		var m_sh: PackedByteArray = _diff(shown, no_sh, 0)["mask"]
		var m_tr: PackedByteArray = d_t["mask"]
		var q := minf(float(_mask_px(m_tr)) / 20000.0, minf(float(_mask_px(m_fl)) / 5000.0, float(_mask_px(m_sh)) / 5000.0))
		if q > best_q:
			best_q = q
			best_pose = k
			first_masks = {"trees": m_tr, "flowers": m_fl, "shrubs": m_sh}
	_rec["visibility"] = {"poses": vis}
	_rec["understory_visibility"] = {"poses": uvis}
	_rec["shadows"] = _shadow_record(sdiffs)
	if not first_masks.is_empty():
		_motion_pose = best_pose
		_place(best_pose)
		var m := await _motion(first_masks, trees)
		_rec["motion"] = m["trees"]
		_rec["understory_motion"] = m["understory"]


# ---------------------------------------------------------------- motion
# stand 6 m from the nearest tall trunk (a fir, pine, larch or elder pine) to the current pose, looking at
# its middle: the trunks' motion is measured from here, where they fill enough of the frame
func _place_trunk_pose() -> void:
	var from := _cam.global_position
	var best := Vector3.ZERO
	var best_d := 1e18
	for item in _roots("Trees"):
		var chunk: Node3D = item[1]
		for mmi in (item[2] as Node).get_children():
			var nm := String(mmi.name)
			if not nm.ends_with("_trunk") or not (_id_of(nm) in ["boreal-fir", "tall-pine", "northwatch-larch", "elder-pine"]):
				continue
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			for i in range(mm.instance_count):
				var o := mm.get_instance_transform(i).origin
				var p := Vector3(chunk.position.x + o.x, o.y, chunk.position.z + o.z)
				var d := p.distance_to(from)
				if d > 9.0 and d < best_d:
					best_d = d
					best = p
	if best_d > 1e17:
		return
	var dir := Vector3(from.x - best.x, 0.0, from.z - best.z).normalized()
	var pos := best + dir * 6.0
	var ground := _ray.height_at(pos.x, pos.z, best.y + 20.0)
	if is_nan(ground):
		ground = best.y
	_cam.global_position = Vector3(pos.x, ground + 1.6, pos.z)
	_cam.look_at(best + Vector3(0.0, 2.2, 0.0), Vector3.UP)


func _water_visible(on: bool) -> void:
	for w in _streamer.water_nodes():
		(w as Node3D).visible = on


func _set_meadow_visible(on: bool) -> void:
	for item in _roots("Flora"):
		(item[2] as Node3D).visible = on


func _motion(masks: Dictionary, trees: Array) -> Dictionary:
	_water_visible(false)  # the water animates by itself; it is not part of any plant's motion
	var tr: Dictionary = {"mask_px": _mask_px(masks["trees"])}
	var un: Dictionary = {"flower_mask_px": _mask_px(masks["flowers"]), "shrub_mask_px": _mask_px(masks["shrubs"])}

	# ---- the crowns: the meadow and the understory are hidden, so nothing sways behind the leaf gaps
	_set_meadow_visible(false)
	_set_understory_visible(false)
	var tm := {"t": masks["trees"]}
	var windy := await _sum_moving(tm, MOVE_DT)
	tr["windy_moving_px"] = windy["t"]
	var frozen := 0
	for t0 in [10.0, 25.0, 40.0]:
		var r := await _moving(tm, t0, t0)
		frozen += r["t"]
	tr["frozen_moving_px"] = frozen
	_feed_front(Vector2(1, 0), 0.0, 0.0)
	_feed_all(0.0)
	var calm := await _sum_moving(tm, MOVE_DT)
	_feed_all(1.0)
	var gale := await _sum_moving(tm, MOVE_DT)
	_feed_all(-1.0)
	tr["calm_moving_px"] = calm["t"]
	tr["gale_moving_px"] = gale["t"]
	var off := await _sum_moving(tm, MOVE_DT)
	tr["front_off_moving_px"] = off["t"]
	# the wall heads along +x and sits at the mean x of the trees in view within 60 m, so they are under it
	var sx := 0.0
	var sn := 0
	for p: Vector3 in trees:
		if p.distance_to(_cam.global_position) < 60.0 and _cam.is_position_in_frustum(p + Vector3(0.0, 3.0, 0.0)):
			sx += p.x
			sn += 1
	_feed_front(Vector2(1, 0), sx / float(maxi(sn, 1)), 1.0)
	var on := await _sum_moving(tm, MOVE_DT)
	tr["front_on_moving_px"] = on["t"]
	_feed_front(Vector2(1, 0), 0.0, 0.0, true)
	# per-cell flutter alone (no whole-crown lean) and lean alone (no flutter)
	var base_lean: float = TreeAssets.CROWN_WIND_AMP
	_world.trees.set_lean_amp(0.0)
	var flut := await _sum_moving(tm, MOVE_DT)
	_world.trees.set_lean_amp(base_lean)
	tr["flutter_only_moving_px"] = flut["t"]
	var amp_before := 0.18
	_world.trees.set_flutter_amp(0.0)
	var lean := await _sum_moving(tm, MOVE_DT)
	_world.trees.set_flutter_amp(amp_before if _mutation not in ["flutter_off", "wind_off"] else 0.0)
	tr["lean_only_moving_px"] = lean["t"]
	# per-cell tumble ISOLATED: no lean, the field strength pinned (so no gust-amplitude modulation), no
	# front (peak 0 and ripple amplitude 0) and no shimmer. The only time term left is the cell's own
	# flutter, so freezing it (or removing its time term) must take this to zero.
	var base_front_amp := 4.4
	var base_shimmer := 0.35
	_world.trees.set_lean_amp(0.0)
	_world.trees.set_front_amp(0.0)
	_world.trees.set_shimmer(0.0)
	_feed_front(Vector2(1, 0), 0.0, 0.0)
	_feed_all(0.5)
	var iso := await _sum_moving(tm, MOVE_DT)
	_feed_all(-1.0)
	_feed_front(Vector2(1, 0), 0.0, 0.0, true)
	_world.trees.set_lean_amp(base_lean)
	_world.trees.set_front_amp(base_front_amp)
	_world.trees.set_shimmer(base_shimmer)
	tr["flutter_iso_moving_px"] = iso["t"]

	# ---- trunks: crowns, meadow and understory hidden and the shadows off (so a trunk's own shadow, where
	# the grass sways, is not in its mask); trunks shown against trunks hidden; trunks do not sway
	_streamer.set_shadows(false)
	_place_trunk_pose()
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			if String(mmi.name).ends_with("_crown"):
				(mmi as Node3D).visible = false
	await _frames(3)
	var tshown := await _capture()
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			if String(mmi.name).ends_with("_trunk"):
				(mmi as Node3D).visible = false
	await _frames(3)
	var thidden := await _capture()
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			if String(mmi.name).ends_with("_trunk"):
				(mmi as Node3D).visible = true
	var tmask: PackedByteArray = _diff(tshown, thidden, 0)["mask"]
	var tk := await _sum_moving({"k": tmask}, MOVE_DT)
	tr["trunk_mask_px"] = _mask_px(tmask)
	tr["trunk_moving_px"] = tk["k"]
	_streamer.set_shadows(_mutation != "shadows_off")
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			(mmi as Node3D).visible = true
	_place(_motion_pose)

	# ---- the understory: the trees hidden (their motion is not the subject), the meadow shown
	_set_meadow_visible(true)
	_set_understory_visible(true)
	for item in _roots("Trees"):
		(item[2] as Node3D).visible = false
	var um := {"f": masks["flowers"], "s": masks["shrubs"]}
	var uw := await _sum_moving(um, MOVE_DT)
	un["flower_windy_moving_px"] = uw["f"]
	un["shrub_windy_moving_px"] = uw["s"]
	var ufz := {"f": 0, "s": 0}
	for t0 in [10.0, 25.0, 40.0]:
		var r := await _moving(um, t0, t0)
		ufz["f"] += r["f"]
		ufz["s"] += r["s"]
	un["flower_frozen_moving_px"] = ufz["f"]
	un["shrub_frozen_moving_px"] = ufz["s"]
	_feed_front(Vector2(1, 0), 0.0, 0.0)
	_feed_all(0.0)
	var ucalm := await _sum_moving(um, MOVE_DT)
	_feed_all(1.0)
	var ugale := await _sum_moving(um, MOVE_DT)
	_feed_all(-1.0)
	_feed_front(Vector2(1, 0), 0.0, 0.0, true)
	un["flower_calm_moving_px"] = ucalm["f"]
	un["flower_gale_moving_px"] = ugale["f"]
	un["shrub_calm_moving_px"] = ucalm["s"]
	un["shrub_gale_moving_px"] = ugale["s"]
	_world.understory.set_voxel_amps(0.0, 0.0 if _mutation == "shrub_flutter_off" else UnderstoryAssets.AMP_VOXEL_CELL)
	var cell := await _sum_moving({"s": masks["shrubs"]}, MOVE_DT)
	_world.understory.set_voxel_amps(UnderstoryAssets.AMP_VOXEL_LEAN, 0.0)
	var slean := await _sum_moving({"s": masks["shrubs"]}, MOVE_DT)
	_world.understory.set_voxel_amps(UnderstoryAssets.AMP_VOXEL_LEAN, 0.0 if _mutation == "shrub_flutter_off" else UnderstoryAssets.AMP_VOXEL_CELL)
	un["shrub_cell_only_moving_px"] = cell["s"]
	un["shrub_lean_only_moving_px"] = slean["s"]
	for item in _roots("Trees"):
		(item[2] as Node3D).visible = true
	_water_visible(true)
	return {"trees": tr, "understory": un}


# ---------------------------------------------------------------- isolated renders (look)
func _iso_viewport(size: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1.0, 0.0, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.74, 0.84)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	add_child(vp)
	return vp


func _is_bg(r: int, g: int, b: int) -> bool:
	return r > 230 and g < 25 and b > 230


func _iso_sun(vp: SubViewport) -> void:
	var sun := DirectionalLight3D.new()
	var wsun: DirectionalLight3D = _world.get_node("Sun")
	sun.light_color = wsun.light_color
	sun.light_energy = wsun.light_energy
	vp.add_child(sun)
	sun.global_transform = wsun.global_transform


# One mesh lit by the world's sun against a magenta background; returns the image.
func _iso_render(mesh: Mesh, mat: Material, size: int, fov: float, from_dir: Vector3) -> Image:
	var vp := _iso_viewport(Vector2i(size, size))
	_iso_sun(vp)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	vp.add_child(mi)
	var bb: AABB = mesh.get_aabb()
	var cam := Camera3D.new()
	cam.fov = fov
	vp.add_child(cam)
	var ctr := bb.get_center()
	var dist := maxf(bb.size.length() * 1.5, 0.6)
	cam.position = ctr + from_dir.normalized() * dist
	cam.look_at(ctr, Vector3.UP)
	cam.current = true
	await _frames(4)
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	vp.queue_free()
	return img


func _calm(mat: ShaderMaterial) -> ShaderMaterial:
	var m := mat.duplicate() as ShaderMaterial
	m.set_shader_parameter("fog_density", 0.0)
	m.set_shader_parameter("wind_amp", 0.0)
	if m.shader.code.find("u_leaf_amp") != -1:
		m.set_shader_parameter("u_leaf_amp", 0.0)
	if m.shader.code.find("cell_amp") != -1:
		m.set_shader_parameter("cell_amp", 0.0)
	return m


# gap fraction: the share of the solid silhouette (alpha forced on) that shows the background through
# the real cutout; also the mean HSV saturation of the real render's drawn pixels
func _gap_and_sat(mesh: Mesh, mat: ShaderMaterial) -> Dictionary:
	var real := _calm(mat)
	var solid := _calm(mat)
	solid.set_shader_parameter("alpha_solid", 1.0)
	var dir := Vector3(0.0, 0.25, 1.0)
	var a := await _iso_render(mesh, real, 384, 40.0, dir)
	var r := await _iso_render(mesh, solid, 384, 40.0, dir)
	var da := a.get_data()
	var dr := r.get_data()
	var sil := 0
	var gap := 0
	var sat_sum := 0.0
	var drawn := 0
	for i in range(0, da.size(), 3):
		var bg_a := _is_bg(da[i], da[i + 1], da[i + 2])
		var bg_r := _is_bg(dr[i], dr[i + 1], dr[i + 2])
		if not bg_r:
			sil += 1
			if bg_a:
				gap += 1
		if not bg_a:
			drawn += 1
			var rr := da[i] / 255.0
			var gg := da[i + 1] / 255.0
			var bb := da[i + 2] / 255.0
			var mx := maxf(rr, maxf(gg, bb))
			sat_sum += (mx - minf(rr, minf(gg, bb))) / mx if mx > 0.0 else 0.0
	return {"gap": float(gap) / float(maxi(sil, 1)), "sat": sat_sum / float(maxi(drawn, 1))}


func _tex_name(tex: Texture2D) -> String:
	var img := tex.get_image()
	var h := TreeAssets.rgba_sha16(img)
	for t in _world.trees.manifest["leaf_tex"]:
		if t["rgba_sha16"] == h:
			return str(t["id"])
	return "unknown"


func _look() -> Dictionary:
	var ta = _world.trees
	var crown_part: Dictionary = ta.forms["boreal-fir"]["crown"]
	var gs: Dictionary = await _gap_and_sat(crown_part["mesh"], crown_part["material"])
	# trunk luma: the tall pine's trunk lit by the sun, mean linear luma of the drawn pixels
	var tp: Dictionary = ta.forms["tall-pine"]["trunk"]
	var tmat := (tp["material"] as ShaderMaterial).duplicate() as ShaderMaterial
	tmat.set_shader_parameter("fog_density", 0.0)
	var timg := await _iso_render(tp["mesh"], tmat, 256, 40.0, Vector3(0.7, 0.2, 0.9))
	var td := timg.get_data()
	var lsum := 0.0
	var n := 0
	for i in range(0, td.size(), 3):
		if _is_bg(td[i], td[i + 1], td[i + 2]):
			continue
		n += 1
		lsum += 0.2126 * pow(td[i] / 255.0, 2.2) + 0.7152 * pow(td[i + 1] / 255.0, 2.2) + 0.0722 * pow(td[i + 2] / 255.0, 2.2)
	var colors := {}
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			if not String(mmi.name).ends_with("_crown"):
				continue
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			for i in range(mm.instance_count):
				var c := mm.get_instance_color(i)
				colors["%d,%d,%d" % [roundi(c.r * 10000.0), roundi(c.g * 10000.0), roundi(c.b * 10000.0)]] = true
	var tints := {}
	var tex_by_form := {}
	var gap_by_form := {}
	var tint_sat_max := 0.0
	for id in ta.forms.keys():
		if not ta.forms[id].has("crown"):
			continue
		var m: ShaderMaterial = ta.forms[id]["crown"]["material"]
		var tc = m.get_shader_parameter("tint")  # raw linear values, as the prototype passes them
		var tv := Vector3(tc.r, tc.g, tc.b) if tc is Color else Vector3(tc.x, tc.y, tc.z)
		tints["%d,%d,%d" % [roundi(tv.x * 10000.0), roundi(tv.y * 10000.0), roundi(tv.z * 10000.0)]] = true
		tint_sat_max = maxf(tint_sat_max, Color(tv.x, tv.y, tv.z).s)
		tex_by_form[id] = _tex_name(m.get_shader_parameter("leaf_tex"))
		var gf: Dictionary = await _gap_and_sat(ta.forms[id]["crown"]["mesh"], m)
		gap_by_form[id] = gf["gap"]
	var any_mat: ShaderMaterial = ta.materials()[0]
	var code := any_mat.shader.code
	var scissor := 0.0
	var re := RegEx.create_from_string("ALPHA_SCISSOR_THRESHOLD\\s*=\\s*([0-9.]+)")
	var mt := re.search(code)
	if mt != null:
		scissor = float(mt.get_string(1))
	return {
		"crown_gap_frac": gs["gap"], "crown_gap_by_form": gap_by_form, "crown_mean_sat": gs["sat"],
		"crown_material_sat_max": tint_sat_max, "trunk_mean_luma": lsum / float(maxi(n, 1)),
		"instance_colors_distinct": colors.size(), "species_tints_distinct": tints.size(), "alpha_scissor": scissor,
		"double_sided": code.find("cull_disabled") != -1, "crown_wind_amp": float(any_mat.get_shader_parameter("wind_amp")),
		"leaf_texture_by_form": tex_by_form,
	}


func _flatten_instance_colors() -> void:
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			if String(mmi.name).ends_with("_crown"):
				var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
				for i in range(mm.instance_count):
					mm.set_instance_color(i, Color(1, 1, 1, 1))


# tier_swap_render (the negative control): every flower species draws its muted instances with the vivid
# sprite and the reverse
func _swap_flower_tiers() -> void:
	for item in _roots("Understory"):
		var by_id := {}
		for mmi in (item[2] as Node).get_children():
			var nm := String(mmi.name)
			if nm.begins_with("flower-"):
				by_id[nm] = mmi
		for nm in by_id.keys():
			if nm.ends_with("_muted"):
				var other: MultiMeshInstance3D = by_id.get(nm.trim_suffix("_muted") + "_vivid")
				if other != null:
					var tmp = (by_id[nm] as MultiMeshInstance3D).material_override
					(by_id[nm] as MultiMeshInstance3D).material_override = other.material_override
					other.material_override = tmp


func _understory_look() -> Dictionary:
	var ua = _world.understory
	var files := {}
	for sp in ua.manifest["sprites"]:
		files[sp["id"]] = sp["file"]
	var sprites := []
	for id in files.keys():
		var key: String = id
		var f: Dictionary = ua.forms[key]
		var spr: Image = ua.image(files[id])
		var sw := spr.get_width()
		var sh := spr.get_height()
		var vp := _iso_viewport(Vector2i(sw * SPRITE_SCALE, sh * SPRITE_SCALE))
		var mat := (f["material"] as ShaderMaterial).duplicate() as ShaderMaterial
		mat.set_shader_parameter("fog_density", 0.0)
		mat.set_shader_parameter("wind_amp", 0.0)
		var mi := MeshInstance3D.new()
		mi.mesh = f["mesh"]
		mi.material_override = mat
		vp.add_child(mi)
		var bb: AABB = (f["mesh"] as Mesh).get_aabb()
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = bb.size.y
		cam.near = 0.05
		cam.far = 20.0
		vp.add_child(cam)
		cam.position = Vector3(0.0, bb.position.y + bb.size.y / 2.0, 5.0)
		cam.current = true
		await _frames(4)
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		var d := img.get_data()
		var w := img.get_width()
		var inter := 0
		var union := 0
		var inter_f := 0
		var union_f := 0
		for y in range(img.get_height()):
			for x in range(w):
				var i := (y * w + x) * 3
				var drawn := not _is_bg(d[i], d[i + 1], d[i + 2])
				var sx := x / SPRITE_SCALE
				var sy := y / SPRITE_SCALE
				var want := spr.get_pixel(sx, sy).a >= 0.5
				var want_f := spr.get_pixel(sx, sh - 1 - sy).a >= 0.5
				if drawn and want:
					inter += 1
				if drawn or want:
					union += 1
				if drawn and want_f:
					inter_f += 1
				if drawn or want_f:
					union_f += 1
		sprites.append({"id": key, "iou": float(inter) / float(maxi(union, 1)), "iou_flipped": float(inter_f) / float(maxi(union_f, 1))})
		vp.queue_free()
	# tier routing: flower instances whose live material draws the other tier's sprite
	var want_hash := {}
	for sp in ua.manifest["sprites"]:
		want_hash[sp["id"]] = sp["rgba_sha16"]
	var mismatch := 0
	for item in _roots("Understory"):
		for mmi in (item[2] as Node).get_children():
			var nm := String(mmi.name)
			if not nm.begins_with("flower-"):
				continue
			var tier := nm.rsplit("_", true, 1)[1]
			var m: ShaderMaterial = (mmi as MultiMeshInstance3D).material_override
			var h := UnderstoryAssets.rgba_sha16((m.get_shader_parameter("sprite") as Texture2D).get_image())
			if h != want_hash["%s/%s" % [_id_of(nm), tier]]:
				mismatch += (mmi as MultiMeshInstance3D).multimesh.instance_count
	var gaps := []
	for id in ua.decoded.keys():
		var f: Dictionary = ua.forms[id]
		var g: Dictionary = await _gap_and_sat(f["mesh"], f["material"])
		gaps.append(g["gap"])
	var flower_mat: ShaderMaterial = ua.forms["flower-spike-lupine/muted"]["material"]
	var t1_mat: ShaderMaterial = ua.forms["t1-mound-ramp"]["material"]
	var vox_id: String = ua.decoded.keys()[0]
	var vox_mat: ShaderMaterial = ua.forms[vox_id]["material"]
	var scissor := 0.0
	var mt := RegEx.create_from_string("ALPHA_SCISSOR_THRESHOLD\\s*=\\s*([0-9.]+)").search(vox_mat.shader.code)
	if mt != null:
		scissor = float(mt.get_string(1))
	return {
		"sprites": sprites, "tier_routing_mismatch": mismatch,
		"flower_wind_amp": float(flower_mat.get_shader_parameter("wind_amp")),
		"t1_shrub_wind_amp": float(t1_mat.get_shader_parameter("wind_amp")),
		"voxel_shrub_lean_amp": float(vox_mat.get_shader_parameter("wind_amp")),
		"voxel_shrub_cell_amp": float(vox_mat.get_shader_parameter("cell_amp")),
		"voxel_alpha_scissor": scissor, "shrub_gap_frac": gaps,
	}


# ---------------------------------------------------------------- one wind
func _wind_feed() -> Dictionary:
	_world.flora_clock_frozen = false
	var clock_d := 0.0
	var pk_d := 0.0
	var off_d := 0.0
	var axis_d := 0.0
	var cpu_d := 0.0
	var samples := 0
	var tree_mats: Array = _world.trees.materials()
	var flora_mats: Array = _world.flora.materials().filter(func(m: ShaderMaterial) -> bool: return m.shader.code.find("u_time") != -1)
	var under_mats: Array = _world.understory.materials()
	for _i in range(40):
		await _frame()
		var ref: ShaderMaterial = flora_mats[0]
		var t: float = ref.get_shader_parameter("u_time")
		var cpu: Dictionary = StalagWind.current_front(t)
		for group in [tree_mats, flora_mats, under_mats]:
			for m: ShaderMaterial in group:
				clock_d = maxf(clock_d, absf(float(m.get_shader_parameter("u_time")) - t))
				pk_d = maxf(pk_d, absf(float(m.get_shader_parameter("front_pk")) - float(ref.get_shader_parameter("front_pk"))))
				off_d = maxf(off_d, absf(float(m.get_shader_parameter("front_off")) - float(ref.get_shader_parameter("front_off"))))
				var ga: Vector2 = m.get_shader_parameter("gust_axis") if m.get_shader_parameter("gust_axis") != null else Vector2(0.8253356, 0.5646425)
				axis_d = maxf(axis_d, (ga - Vector2(0.8253356, 0.5646425)).length())
				cpu_d = maxf(cpu_d, absf(float(m.get_shader_parameter("front_pk")) - float(cpu["peak"])))
		samples += 1
	return {
		"clock_delta": clock_d, "front_pk_delta": pk_d, "front_off_delta": off_d, "gust_axis_delta": axis_d,
		"front_vs_cpu_delta": cpu_d, "tree_materials": tree_mats.size(), "flora_materials": flora_mats.size(),
		"understory_materials": under_mats.size(), "clock_samples": samples,
	}


# ---------------------------------------------------------------- shadows and triangles
func _tris_of(mesh: Mesh) -> int:
	var arr := (mesh as ArrayMesh).surface_get_arrays(0)
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx != null and (idx as PackedInt32Array).size() > 0:
		return (idx as PackedInt32Array).size() / 3
	return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func _ring_tris() -> Dictionary:
	var trees := 0
	var casters := 0
	var under := 0
	var cache := {}
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			var m := mmi as MultiMeshInstance3D
			if not cache.has(m.multimesh.mesh):
				cache[m.multimesh.mesh] = _tris_of(m.multimesh.mesh)
			var t: int = int(cache[m.multimesh.mesh]) * m.multimesh.instance_count
			var nm := String(m.name)
			if nm.ends_with("_trunk") or nm.ends_with("_crown"):
				trees += t
			if m.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				casters += t
	for item in _roots("Understory"):
		for mmi in (item[2] as Node).get_children():
			var m := mmi as MultiMeshInstance3D
			if not cache.has(m.multimesh.mesh):
				cache[m.multimesh.mesh] = _tris_of(m.multimesh.mesh)
			under += int(cache[m.multimesh.mesh]) * m.multimesh.instance_count
	return {"trees": trees, "understory": under, "shadow_casters": casters}


func _shadow_distance() -> float:
	var d := 0.0
	for id in _world.trees.forms.keys():
		for part in _world.trees.forms[id].values():
			if part["cast"] != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				d = maxf(d, float(part["range_end"]))
	return d


func _shadow_record(pose_diffs: Array) -> Dictionary:
	var proxy := {}
	var trunk := {}
	var crown_cast := 0
	var under_cast := 0
	var tris := 0
	for item in _roots("Trees"):
		for mmi in (item[2] as Node).get_children():
			var m := mmi as MultiMeshInstance3D
			var nm := String(m.name)
			if m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and nm.ends_with("_shadow"):
				proxy[nm] = true
			elif m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON and nm.ends_with("_trunk"):
				trunk[nm] = true
			elif nm.ends_with("_crown") and m.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				crown_cast += 1
	for item in _roots("Understory"):
		for mmi in (item[2] as Node).get_children():
			if (mmi as MultiMeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				under_cast += 1
	tris = _ring_tris()["shadow_casters"]
	# crown materials receive no shadows (render_mode shadows_disabled); the trunks share the rock
	# shader of the meadow, which does receive them (reported apart)
	var receiving := 0
	for m in _world.trees.materials():
		if (m as ShaderMaterial).shader.code.find("shadows_disabled") == -1:
			receiving += 1
	var trunk_mats := {}
	for id in _world.trees.forms.keys():
		trunk_mats[_world.trees.forms[id]["trunk"]["material"]] = true
	var trunk_receiving := 0
	for m in trunk_mats.keys():
		if (m as ShaderMaterial).shader.code.find("shadows_disabled") == -1:
			trunk_receiving += 1
	return {
		"proxy_mmis": proxy.size(), "trunk_casting_mmis": trunk.size(), "crown_full_casting_mmis": crown_cast,
		"understory_casting_mmis": under_cast, "receiving_tree_materials": receiving, "trunk_materials": trunk_mats.size(), "receiving_trunk_materials": trunk_receiving,
		"ring_shadow_tris_submitted": tris, "pose_diffs": pose_diffs,
	}


# ---------------------------------------------------------------- perf A/B
func _wet_within_3m(x: float, z: float) -> bool:
	for gz in range(floori((z - 3.5) / 0.5), floori((z + 3.5) / 0.5) + 1):
		for gx in range(floori((x - 3.5) / 0.5), floori((x + 3.5) / 0.5) + 1):
			if StalagWorld.is_flooded(gx, gz) or StalagWorld.is_river_column(gx, gz):
				return true
	return false


## The walk probe's waypoint rule (geom_v1), restated: the 4 m lattice point nearest each anchor
## with no water within 3 m that the route planner can reach.
func _plan_route(start: Vector2, limit: float) -> Array:
	var route: Array = [start]
	var cur := start
	for slot in range(WALK_ANCHORS.size()):
		var anchor: Vector2 = WALK_ANCHORS[slot]
		var cands: Array = []
		for xi in range(-27, 28):
			for zi in range(-27, 28):
				var c := Vector2(float(xi * 4), float(zi * 4))
				if (slot == 1 or slot == 2) and c.length() < 100.0:
					continue
				cands.append(c)
		cands.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			var da := a.distance_to(anchor)
			var db := b.distance_to(anchor)
			if da != db:
				return da < db
			if a.x != b.x:
				return a.x < b.x
			return a.y < b.y)
		for c in cands:
			if _wet_within_3m(c.x, c.y):
				continue
			var leg: Array = RoutePlanner.plan(cur, [c], limit)
			if leg.is_empty():
				continue
			route.append_array(leg.slice(1))
			cur = leg[leg.size() - 1]
			break
	return route


func _pctl(a: PackedFloat64Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[mini(s.size() - 1, int(floor(p * float(s.size()))))]


## Perf A/B, interleaved: PERF_ROUNDS rounds, each walking the same route once per configuration, the
## configuration order rotated every round so no configuration owns the cold start or the GPU clock
## ramp. A configuration's figures are the MEDIAN over rounds of that round's figures; the per-round
## values are kept in `*_rounds`. Two things keep the number honest on the xvfb display:
##  - the world is rendered into an OFFSCREEN SubViewport of PERF_VIEWPORT (1920x1080, the game's default
##    window) with its own GPU timer (measure_render_time enabled on it), while the window itself is
##    shrunk to 128x72 for the walk. Presenting a large window to xvfb costs about 25 ms a frame whatever
##    the scene is (measured at 1280x720 in the window: frame period 28 to 47 ms with 2.7 to 12 ms of
##    GPU time, SM clock 300 to 765 MHz); the GPU is then idle for most of every frame, the driver drops
##    its clocks, and every configuration reads 20 ms or more of "GPU time" that is the clock state,
##    not the scene (issue #903). The record carries the measured viewport size (`perf.viewport`) and
##    `perf.world_in_viewport` (the world's get_viewport() was the timed SubViewport in every round);
##  - the walker is stepped with a fixed dt per frame, so every configuration samples the same stretch
##    of the route however fast it renders.
## Dev knobs: TREEVIEW_PERF_ROUNDS, TREEVIEW_PERF_CONFIGS (comma list of config names).
func _perf_rounds() -> Dictionary:
	var all_cfg := [["off", false, false, false], ["trees", true, false, false], ["shadows", true, false, true], ["full", true, true, true]]
	var want := OS.get_environment("TREEVIEW_PERF_CONFIGS")
	var cfgs: Array = []
	for c in all_cfg:
		if want.is_empty() or (want.split(",") as PackedStringArray).has(c[0]):
			cfgs.append(c)
	var rounds := PERF_ROUNDS
	if not OS.get_environment("TREEVIEW_PERF_ROUNDS").is_empty():
		rounds = int(OS.get_environment("TREEVIEW_PERF_ROUNDS"))
	if _mutation == "sync_trees":
		# the control only needs the adoption cost of the full world, once
		cfgs = [all_cfg[3]]
		rounds = 1
	var got := {}
	var adopts: Array = []
	var win_size := get_window().size
	var vp_size := Vector2i.ZERO
	var world_in_vp := true  # every round: the world's own viewport IS the timed one (audit 3: an empty timed viewport read 0.005 ms)
	get_window().size = Vector2i(128, 72)
	var win_during := get_window().size  # read back, not assumed
	for r in range(rounds):
		for k in range(cfgs.size()):
			var cfg: Array = cfgs[(k + r) % cfgs.size()]
			_spawn_world(cfg[1], cfg[2], cfg[3], true)
			await _wait_settled(240.0)
			var res: Dictionary = await _perf_walk()
			vp_size = _perf_vp.size  # what was actually rendered into, read back from the node
			world_in_vp = world_in_vp and _world != null and _world.is_inside_tree() and _world.get_viewport() == _perf_vp
			if not got.has(cfg[0]):
				got[cfg[0]] = []
			(got[cfg[0]] as Array).append(res["frame"])
			if cfg[0] == "full":
				adopts.append(res["adopt"])
			_free_world()
			await _frames(5)
			print("treeview_probe: perf round %d %s gpu_p95=%.2f cpu_p95=%.3f" % [r, cfg[0], res["frame"]["render_gpu_p95_ms"], res["frame"]["cpu_p95_ms"]])
	get_window().size = win_size
	var perf := {"viewport": [vp_size.x, vp_size.y], "window": [win_during.x, win_during.y], "world_in_viewport": world_in_vp}
	for name in got.keys():
		var fr: Array = got[name]
		var n := 0
		var imax := 0
		var cp := PackedFloat64Array()
		var cm := PackedFloat64Array()
		var gp := PackedFloat64Array()
		for f in fr:
			n += int(f["samples"])
			imax = maxi(imax, int(f["instances_max"]))
			cp.append(f["cpu_p95_ms"])
			cm.append(f["cpu_max_ms"])
			gp.append(f["render_gpu_p95_ms"])
		perf[name] = {"samples": n, "rounds": fr.size(), "cpu_p95_ms": _pctl(cp, 0.5), "cpu_max_ms": _pctl(cm, 0.5),
			"render_gpu_p95_ms": _pctl(gp, 0.5), "instances_max": imax,
			"gpu_p95_rounds": Array(gp), "cpu_p95_rounds": Array(cp)}
	var adopt := {"n": 0, "p95_ms": 0.0, "max_ms": 0.0}
	if not adopts.is_empty():
		var ap := PackedFloat64Array()
		var am := PackedFloat64Array()
		for a in adopts:
			adopt["n"] = int(adopt["n"]) + int(a["n"])
			ap.append(a["p95_ms"])
			am.append(a["max_ms"])
		adopt["p95_ms"] = _pctl(ap, 0.5)
		adopt["max_ms"] = _pctl(am, 1.0)
	return {"perf": perf, "adopt": adopt}


func _perf_walk() -> Dictionary:
	_world.flora_clock_frozen = false
	var route := _plan_route(Vector2(_walker.pos.x, _walker.pos.z), StalagWorld.get_half_extent_m() - 1.0)
	await _frames(10)
	for _i in range(PERF_WARMUP):
		await _frame()
	_streamer.trees_adopt_ms.clear()
	_walker.set_process(false)  # the probe steps the walker itself (below)
	var cpu := PackedFloat64Array()
	var gpu := PackedFloat64Array()
	var inst_max := 0
	var idx := 1
	while idx < route.size() and cpu.size() < PERF_SAMPLES:
		await _frame()
		var p2 := Vector2(_walker.pos.x, _walker.pos.z)
		var to: Vector2 = (route[idx] as Vector2) - p2
		while to.length() < 0.6 and idx < route.size() - 1:
			idx += 1
			to = (route[idx] as Vector2) - p2
		_walker.input_move = to.normalized()
		_walker.step(PERF_STEP_DT)  # one fixed walking step per frame: the path never depends on the frame time
		cpu.append(_cpu_last_ms)
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_perf_vp.get_viewport_rid() if _perf_vp != null else _vp()))
		inst_max = maxi(inst_max, int(_streamer.flora_instances) + int(_streamer.tree_instances) + int(_streamer.understory_instances))
	_walker.input_move = Vector2.ZERO
	_walker.set_process(true)
	var ad := PackedFloat64Array(_streamer.trees_adopt_ms)
	return {
		"frame": {"samples": cpu.size(), "cpu_p95_ms": _pctl(cpu, 0.95), "cpu_max_ms": _pctl(cpu, 1.0),
			"render_gpu_p95_ms": _pctl(gpu, 0.95), "instances_max": inst_max},
		"adopt": {"n": ad.size(), "p95_ms": _pctl(ad, 0.95), "max_ms": _pctl(ad, 1.0)},
	}
