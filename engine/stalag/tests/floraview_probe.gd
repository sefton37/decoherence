extends Node
## Spec #545 real-renderer flora probe. It only MEASURES: tests/verify_stalag_floraview.sh runs it
## on the xvfb display and the DoD's jq judges. Definitions follow the "Probe contracts" section of
## spec-545.md: seating is read back from the MultiMesh buffers the renderer was GIVEN and rayed
## against the chunk meshes handed to the renderer (observer frame), never the placement list.
##
## Env: FLORAVIEW_PROBE_RAW   output JSON path (required)
##      FLORAVIEW_SHOTS_DIR   screenshot directory (required)
##      FLORAVIEW_ORACLE_DIR  directory written by tools/baseline/js_flora_oracle.mjs (required)
##      FLORAVIEW_MUTATE      none | flora_hidden | float | sunk | wind_off | sprite_flip | rock_srgb | sync_flora

const WorldModule := preload("res://game/world/world_module.gd")
const MeshRay := preload("res://engine/stalag/tests/mesh_ray.gd")
const RoutePlanner := preload("res://engine/stalag/tests/route_planner.gd")

const WALK_ANCHORS := [Vector2(60, -20), Vector2(104, 10), Vector2(100, 60), Vector2(50, 70), Vector2(0, 40)]
const PERF_WARMUP := 90
const PERF_SAMPLES := 1700
const PIX_TOL := 4  # per-channel difference (0..255) that counts as a changed pixel
const POSES := 6
const SPRITE_SCALE := 6

var _mutation := "none"
var _raw := ""
var _shots_dir := ""
var _oracle_dir := ""
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
var _flora_before_plan := 0


func _ready() -> void:
	_raw = OS.get_environment("FLORAVIEW_PROBE_RAW")
	_shots_dir = OS.get_environment("FLORAVIEW_SHOTS_DIR")
	_oracle_dir = OS.get_environment("FLORAVIEW_ORACLE_DIR")
	var m := OS.get_environment("FLORAVIEW_MUTATE")
	_mutation = m if not m.is_empty() else "none"
	if _raw.is_empty() or _shots_dir.is_empty() or _oracle_dir.is_empty():
		push_error("floraview_probe: FLORAVIEW_PROBE_RAW, FLORAVIEW_SHOTS_DIR, FLORAVIEW_ORACLE_DIR are required")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	_oracle = JSON.parse_string(FileAccess.get_file_as_string(_oracle_dir.path_join("oracle.json")))
	_run()


func _frame() -> void:
	await get_tree().process_frame


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _vp() -> RID:
	return get_viewport().get_viewport_rid()


# ---------------------------------------------------------------- world lifecycle
func _spawn_world(flora_on: bool) -> void:
	StalagChunkMesher.reset_build_stats()
	StalagFlora.reset_build_stats()
	_ray = MeshRay.new(StalagWorld.get_chunk_m())
	_world = WorldModule.instantiate_world()
	_streamer = _world.get_node("Streamer")
	_walker = _world.get_node("Walker")
	_world.scripted_input = true
	_streamer.flora_enabled = flora_on
	_streamer.chunk_built.connect(func(c: Vector2i, v: PackedVector3Array) -> void: _ray.add_chunk(c, v))
	_streamer.flora_attached.connect(func(_c: Vector2i) -> void:
		if not StalagWorld.plan_ready():
			_flora_before_plan += 1)
	if _mutation == "sync_flora":
		_streamer.sync_flora = true
	elif _mutation == "float":
		_streamer.flora_y_offset = 0.5
	elif _mutation == "sunk":
		_streamer.flora_y_offset = -0.5
	add_child(_world)
	if flora_on:
		if _mutation == "wind_off":
			_world.flora.disable_wind()
		elif _mutation == "sprite_flip":
			_world.flora.sprites_flipped(true)
		elif _mutation == "rock_srgb":
			_world.flora.rocks_srgb(true)


func _free_world() -> void:
	_streamer.shutdown()
	_world.request_exit()
	remove_child(_world)
	_world.queue_free()
	_world = null


func _wait_settled(timeout_s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not (_streamer.ring_ready() and _streamer.settled()):
		await _frame()
		if (Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			push_error("floraview_probe: ring never settled")
			break
	await _frames(5)


func _run() -> void:
	var nodes_before := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	RenderingServer.viewport_set_measure_render_time(_vp(), true)
	get_tree().process_frame.connect(func() -> void: _t_frame_us = Time.get_ticks_usec())
	RenderingServer.frame_pre_draw.connect(func() -> void: _cpu_last_ms = (Time.get_ticks_usec() - _t_frame_us) / 1000.0)

	_spawn_world(true)
	await _wait_settled(180.0)
	print("floraview_probe: ring settled, chunks=%d" % _streamer.loaded_count())
	_rec["ring"] = _ring_stats()
	_rec["seating"] = _seating()
	print("floraview_probe: seating done")
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 600.0
	_cam.environment = _world.get_node("Camera").environment
	add_child(_cam)
	_cam.make_current()
	_walker.visible = false
	_world.flora_clock_frozen = true
	await _visibility_and_motion()
	print("floraview_probe: visibility and motion done")
	_cam.queue_free()
	_rec["sprites"] = await _sprites()
	_rec["rocks"] = await _rocks()
	print("floraview_probe: sprites and rocks done")
	var lc := _lifecycle_live()
	_free_world()
	await _frames(5)
	_rec["lifecycle"] = lc
	_rec["lifecycle"]["nodes_after_shutdown"] = _count_named(get_tree().root, "Flora")

	var on: Dictionary = {}
	if _mutation == "none" or _mutation == "sync_flora":
		_spawn_world(true)
		await _wait_settled(180.0)
		on = await _perf_walk()
		_free_world()
		await _frames(5)
		_spawn_world(false)
		await _wait_settled(180.0)
		var off: Dictionary = await _perf_walk()
		_free_world()
		await _frames(5)
		_rec["perf"] = {"on": on["frame"], "off": off["frame"], "adopt": on["adopt"]}
		print("floraview_probe: perf done")
	else:
		# Mutations that do not touch the frame budget skip the long A/B; the DoD reads perf only
		# from the unmutated run (and from sync_flora, whose detector is the adoption cost).
		_rec["perf"] = {"on": {"samples": 0}, "off": {"samples": 0}, "adopt": {"n": 0, "p95_ms": 0.0, "max_ms": 0.0}}
	await _frames(5)
	_rec["lifecycle"]["orphans"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_rec["lifecycle"]["node_delta"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - nodes_before
	_rec["shots"] = _shots
	_rec["adapter"] = RenderingServer.get_video_adapter_name()
	_rec["project_name"] = str(ProjectSettings.get_setting("application/config/name"))
	_rec["classes"] = {
		"StalagWorld": ClassDB.class_exists("StalagWorld"), "StalagChunkMesher": ClassDB.class_exists("StalagChunkMesher"),
		"StalagFlora": ClassDB.class_exists("StalagFlora"), "StalagWind": ClassDB.class_exists("StalagWind"),
	}
	_rec["plan"] = {"js_hash": _oracle["plan_hash"], "gd_hash": StalagWorld.plan_hash()}
	var f := FileAccess.open(_raw, FileAccess.WRITE)
	f.store_string(JSON.stringify(_rec))
	f.close()
	get_tree().quit(0)


# ---------------------------------------------------------------- helpers over the live ring
func _flora_roots() -> Array:
	var out: Array = []
	for c in _streamer.chunk_coords():
		var mi: Node = _streamer.chunk_node(c)
		var root := mi.get_node_or_null("Flora")
		if root != null:
			out.append([c, mi, root])
	return out


func _count_named(n: Node, nm: String) -> int:
	var c := 1 if n.name == nm else 0
	for ch in n.get_children():
		c += _count_named(ch, nm)
	return c


func _set_flora_visible(on: bool) -> void:
	if _mutation == "flora_hidden":
		on = false  # the negative control: the flora is built but never shown
	for item in _flora_roots():
		(item[2] as Node3D).visible = on


func _ring_stats() -> Dictionary:
	var inst := 0
	var forms := {}
	var expected := 0
	var oracle_counts: Dictionary = _oracle["placement"]["chunks"]["counts"]
	for item in _flora_roots():
		for mmi in (item[2] as Node).get_children():
			var n: int = (mmi as MultiMeshInstance3D).multimesh.instance_count
			inst += n
			if n > 0:
				forms[mmi.name] = true
	for c in _streamer.chunk_coords():
		expected += int(oracle_counts.get("%d,%d" % [c.x, c.y], 0))
	var st: Dictionary = StalagFlora.get_build_stats()
	return {
		"chunks": _streamer.loaded_count(), "instances": inst, "oracle_instances": expected,
		"forms_present": forms.size(), "flora_before_plan": _flora_before_plan,
		"on_main_thread_builds": int(st["on_main_thread"]),
	}


func _lifecycle_live() -> Dictionary:
	var roots := _flora_roots().size()
	var expected := 0
	var oracle_counts: Dictionary = _oracle["placement"]["chunks"]["counts"]
	for c in _streamer.chunk_coords():
		if int(oracle_counts.get("%d,%d" % [c.x, c.y], 0)) > 0:
			expected += 1
	return {"flora_roots": roots, "chunks_with_flora_expected": expected}


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


# ---------------------------------------------------------------- seating (DOD-17)
func _seating() -> Dictionary:
	var checked := 0
	var missed := 0
	var max_err := 0.0
	var off_mesh := 0
	var floating := 0
	var buried := 0
	var under := 0
	var per_form := {}
	var overhung := 0
	var overhung_buried_max := 0.0
	var off_exp := 0
	var buried_exp := 0
	var max_err_exp := 0.0
	var off_by := {}  # diagnostics: failures per form
	var buried_by := {}
	var extent := {}
	for id in _world.flora.forms.keys():
		var bb: AABB = (_world.flora.forms[id]["mesh"] as Mesh).get_aabb()
		extent[id] = [bb.position.y, bb.end.y]
	var cm: float = StalagWorld.get_chunk_m()
	for item in _flora_roots():
		var coord: Vector2i = item[0]
		var chunk: Node3D = item[1]
		var wgrid := _water_grid(_streamer.water_node(coord))
		for mmi in (item[2] as Node).get_children():
			var id := String(mmi.name)
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			var ext: Array = extent[id]
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
				var err := absf(oy - hit)
				max_err = maxf(max_err, err)
				var sc := t.basis.y.y
				var is_buried: bool = oy + ext[1] * sc <= hit
				# Overhung: the rendered surface at the root is 2 to 45 cm above it AND an adjacent column
				# stands on a higher terrace (the prototype's lid rule accepts such lids). Judged from the
				# column's own terrace, never from the instance height, so a shifted instance stays exposed.
				var over := false
				if hit - oy > 0.02 and hit - oy <= 0.45:
					over = _higher_neighbour(wx, wz)
				if over:
					overhung += 1
					overhung_buried_max = maxf(overhung_buried_max, hit - oy)
				else:
					max_err_exp = maxf(max_err_exp, err)
					if err > 0.02:
						off_exp += 1
					if is_buried:
						buried_exp += 1
				if err > 0.02:
					off_mesh += 1
					off_by[id] = int(off_by.get(id, 0)) + 1
				if oy + ext[0] * sc > hit + 0.02:
					floating += 1
				if is_buried:
					buried += 1
					buried_by[id] = int(buried_by.get(id, 0)) + 1
				if _in_water(wgrid, t.origin.x, t.origin.z):
					under += 1
	var pf := []
	for id in per_form.keys():
		pf.append({"id": id, "n": per_form[id]})
	return {
		"checked": checked, "ray_missed": missed, "max_abs_err_m": max_err, "off_mesh": off_mesh,
		"floating": floating, "buried": buried, "under_water": under, "per_form": pf,
		"off_mesh_by_form": off_by, "buried_by_form": buried_by,
		"overhung": overhung, "overhung_buried_max_m": overhung_buried_max,
		"off_mesh_exposed": off_exp, "buried_exposed": buried_exp, "max_abs_err_exposed_m": max_err_exp,
	}


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


## Changed pixels between two same-size images over the rows from y0 down; optionally restricted
## to a mask (PackedByteArray of 0/1, one per pixel). Returns {n, changed, dist_sum}.
func _diff(a: Image, b: Image, y0: int, mask: PackedByteArray = PackedByteArray()) -> Dictionary:
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var changed := 0
	var dist_sum := 0.0
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
	return {"n": (h - y0) * w, "changed": changed, "dist_sum": dist_sum, "mask": out_mask}


# ---------------------------------------------------------------- poses
func _gather_targets() -> Array:
	# Dense meadow cells (4 m bins) in the central 3 x 3 chunks, away from water.
	var bins := {}
	for item in _flora_roots():
		var c: Vector2i = item[0]
		if absi(c.x) > 1 or absi(c.y) > 1:
			continue
		var chunk: Node3D = item[1]
		for mmi in (item[2] as Node).get_children():
			var id := String(mmi.name)
			if not id.begins_with("tuft") and not id.begins_with("cover"):
				continue
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			for i in range(0, mm.instance_count, 2):
				var o := mm.get_instance_transform(i).origin
				var wx := chunk.position.x + o.x
				var wz := chunk.position.z + o.z
				var k := Vector2i(floori(wx / 4.0), floori(wz / 4.0))
				bins[k] = int(bins.get(k, 0)) + 1
	var water_pts: Array = []
	for c in _streamer.chunk_coords():
		var w: MeshInstance3D = _streamer.water_node(c)
		if w == null:
			continue
		var v: PackedVector3Array = (w.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var chunk2: Node3D = _streamer.chunk_node(c)
		for j in range(0, v.size(), 7):
			water_pts.append(Vector2(chunk2.position.x + v[j].x, chunk2.position.z + v[j].z))
	var keys := bins.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if bins[a] != bins[b]:
			return bins[a] > bins[b]
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	var picked: Array = []
	for clearance in [45.0, 25.0, 10.0, 0.0]:
		picked.clear()
		for k in keys:
			var p := Vector2((k.x + 0.5) * 4.0, (k.y + 0.5) * 4.0)
			var ok := true
			for q in water_pts:
				if p.distance_to(q) < clearance:
					ok = false
					break
			if not ok:
				continue
			var far_enough := true
			for pk in picked:
				if (pk as Vector2).distance_to(p) < 10.0:
					far_enough = false
					break
			if far_enough:
				picked.append(p)
			if picked.size() >= POSES:
				break
		if picked.size() >= POSES:
			break
	return picked


func _place_cam(target: Vector2, k: int) -> void:
	var yaw := 0.35 + float(k) * 1.0472
	var cx := target.x + cos(yaw) * 4.5
	var cz := target.y + sin(yaw) * 4.5
	var ground := _ray.height_at(cx, cz, 60.0)
	var gt := _ray.height_at(target.x, target.y, 60.0)
	if is_nan(ground):
		ground = gt
	if is_nan(gt):
		gt = ground
	_cam.global_position = Vector3(cx, ground + 1.5, cz)
	_cam.look_at(Vector3(target.x, gt + 0.15, target.y), Vector3.UP)


func _set_clock(t: float) -> void:
	_world.flora_clock = t


func _visibility_and_motion() -> void:
	var targets := _gather_targets()
	var poses := []
	var first_mask := PackedByteArray()
	var first_pose := -1
	for k in range(targets.size()):
		_place_cam(targets[k], k)
		_set_clock(10.0)
		_set_flora_visible(true)
		await _frames(3)
		var shown := await _capture()
		_set_flora_visible(false)
		await _frames(3)
		var hidden := await _capture()
		_set_flora_visible(true)
		_save(shown, "pose%d_shown" % k)
		_save(hidden, "pose%d_hidden" % k)
		var h2: int = shown.get_height() / 2
		var d := _diff(shown, hidden, h2)
		var pose := {"name": "pose%d" % k, "diff_frac": float(d["changed"]) / float(maxi(d["n"], 1)),
				"mean_rgb_dist": float(d["dist_sum"]) / float(maxi(d["changed"], 1))}
		var full: Dictionary = _diff(shown, hidden, 0)  # roots anywhere in the frame, not only the lower half
		var rv := _roots_visible(full["mask"], shown.get_width(), shown.get_height())
		pose["in_view"] = rv["in_view"]
		pose["root_visible_frac"] = rv["frac"]
		poses.append(pose)
		if first_pose < 0:
			first_pose = k
			first_mask = full["mask"]
	_rec["visibility"] = {"poses": poses}
	if first_pose >= 0:
		_place_cam(targets[first_pose], first_pose)
		_rec["motion"] = await _motion(first_mask)
	else:
		_rec["motion"] = {"mask_px": 0}


## Share of in-view, unoccluded instance roots whose neighbourhood changed between flora shown and
## hidden (mask = changed pixels of the pose). The neighbourhood is a 10 cm disc around the root,
## projected to pixels (at least 3 px); at most the 600 nearest candidates within 14 m are tested.
func _roots_visible(mask: PackedByteArray, w: int, h: int) -> Dictionary:
	var cpos := _cam.global_position
	var cands: Array = []
	for item in _flora_roots():
		var chunk: Node3D = item[1]
		for mmi in (item[2] as Node).get_children():
			var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
			for i in range(mm.instance_count):
				var o := mm.get_instance_transform(i).origin
				var p := Vector3(chunk.position.x + o.x, o.y, chunk.position.z + o.z)
				var d := cpos.distance_to(p)
				if d <= 14.0:
					cands.append([d, p])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var in_view := 0
	var seen := 0
	var right := _cam.global_transform.basis.x
	for c in cands:
		if in_view >= 600:
			break
		var p: Vector3 = c[1]
		var root := p + Vector3(0.0, 0.05, 0.0)
		if not _cam.is_position_in_frustum(root) or _cam.is_position_behind(root):
			continue
		if _occluded(cpos, root):
			continue
		var sp := _cam.unproject_position(root)
		var rad := maxi(3, roundi(sp.distance_to(_cam.unproject_position(root + right * 0.10))))
		var px := roundi(sp.x)
		var py := roundi(sp.y)
		if px < rad or py < rad or px >= w - rad or py >= h - rad:
			continue
		in_view += 1
		var hit := false
		for dy in range(-rad, rad + 1):
			for dx in range(-rad, rad + 1):
				if dx * dx + dy * dy <= rad * rad and mask[(py + dy) * w + px + dx] == 1:
					hit = true
					break
			if hit:
				break
		if hit:
			seen += 1
	return {"in_view": in_view, "frac": float(seen) / float(maxi(in_view, 1))}


func _occluded(from: Vector3, to: Vector3) -> bool:
	var n := int(from.distance_to(to) / 0.5)
	for s in range(1, n):
		var q := from.lerp(to, float(s) / float(n))
		var th := _ray.height_at(q.x, q.z, 1000.0)
		if not is_nan(th) and th > q.y + 0.05:
			return true
	return false


# ---------------------------------------------------------------- motion (DOD-20)
func _moving_px(mask: PackedByteArray, ta: float, tb: float) -> int:
	_set_clock(ta)
	await _frames(3)
	var a := await _capture()
	_set_clock(tb)
	await _frames(3)
	var b := await _capture()
	return int(_diff(a, b, 0, mask)["changed"])


func _sum_moving(mask: PackedByteArray, dt: float) -> int:
	var total := 0
	for t0 in [10.0, 25.0, 40.0]:
		total += await _moving_px(mask, t0, t0 + dt)
	return total


func _motion(mask: PackedByteArray) -> Dictionary:
	var mask_px := 0
	for v in mask:
		mask_px += v
	var fl = _world.flora
	var out := {"mask_px": mask_px}
	out["windy_moving_px"] = await _sum_moving(mask, 3.0)
	var frozen := 0
	for t0 in [10.0, 25.0, 40.0]:
		frozen += await _moving_px(mask, t0, t0)
	out["frozen_moving_px"] = frozen
	fl.force_front(Vector2(1, 0), 0.0, 0.0)
	fl.force_strength(0.0)
	out["calm_moving_px"] = await _sum_moving(mask, 3.0)
	fl.force_strength(1.0)
	out["gale_moving_px"] = await _sum_moving(mask, 3.0)
	fl.force_strength(-1.0)
	out["front_off_moving_px"] = await _sum_moving(mask, 3.0)
	# the wall sits on the camera, heading along +x
	var cpos := _cam.global_position
	fl.force_front(Vector2(1, 0), cpos.x, 1.0)
	out["front_on_moving_px"] = await _sum_moving(mask, 3.0)
	fl.force_front(Vector2(1, 0), 0.0, 0.0, true)
	return out


# ---------------------------------------------------------------- isolated renders (DOD-19)
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


func _sprites() -> Array:
	var out := []
	if not _world.flora.forms.has("tuft-billboard-baseline"):
		return out
	for id in _world.flora.billboard_ids():
		var f: Dictionary = _world.flora.forms[id]
		var spr: Image = f["sprite"]
		var sw := spr.get_width()
		var sh := spr.get_height()
		var vp := _iso_viewport(Vector2i(sw * SPRITE_SCALE, sh * SPRITE_SCALE))
		var mat: ShaderMaterial = (f["material"] as ShaderMaterial).duplicate()
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
		out.append({"id": id, "iou": float(inter) / float(maxi(union, 1)), "iou_flipped": float(inter_f) / float(maxi(union_f, 1))})
		vp.queue_free()
	return out


func _rocks() -> Dictionary:
	var rendered := 0
	var luma_sum := 0.0
	var sat_sum := 0.0
	var px_total := 0
	for id in _world.flora.ROCKS:
		var f: Dictionary = _world.flora.forms[id]
		var vp := _iso_viewport(Vector2i(256, 256))
		var sun := DirectionalLight3D.new()
		var wsun: DirectionalLight3D = _world.get_node("Sun")
		sun.light_color = wsun.light_color
		sun.light_energy = wsun.light_energy
		vp.add_child(sun)
		sun.global_transform = wsun.global_transform
		var mat: ShaderMaterial = (f["material"] as ShaderMaterial).duplicate()
		mat.set_shader_parameter("fog_density", 0.0)
		var mi := MeshInstance3D.new()
		mi.mesh = f["mesh"]
		mi.material_override = mat
		vp.add_child(mi)
		var bb: AABB = (f["mesh"] as Mesh).get_aabb()
		var cam := Camera3D.new()
		cam.fov = 40.0
		vp.add_child(cam)
		var ctr := bb.get_center()
		var dist := maxf(bb.size.length() * 1.6, 0.6)
		cam.position = ctr + Vector3(0.7, 0.6, 0.9).normalized() * dist
		cam.look_at(ctr, Vector3.UP)
		cam.current = true
		await _frames(4)
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		var d := img.get_data()
		var n := 0
		var lsum := 0.0
		var ssum := 0.0
		for i in range(0, d.size(), 3):
			if _is_bg(d[i], d[i + 1], d[i + 2]):
				continue
			n += 1
			var r := d[i] / 255.0
			var g := d[i + 1] / 255.0
			var b := d[i + 2] / 255.0
			lsum += 0.2126 * r + 0.7152 * g + 0.0722 * b
			var mx := maxf(r, maxf(g, b))
			ssum += (mx - minf(r, minf(g, b))) / mx if mx > 0.0 else 0.0
		if n >= 100:
			rendered += 1
		luma_sum += lsum
		sat_sum += ssum
		px_total += n
		vp.queue_free()
	return {"forms_rendered": rendered, "mean_luma": luma_sum / float(maxi(px_total, 1)), "mean_sat": sat_sum / float(maxi(px_total, 1))}


# ---------------------------------------------------------------- perf A/B (DOD-21)
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


func _perf_walk() -> Dictionary:
	_world.flora_clock_frozen = false
	var route := _plan_route(Vector2(_walker.pos.x, _walker.pos.z), StalagWorld.get_half_extent_m() - 1.0)
	await _frames(10)
	for _i in range(PERF_WARMUP):
		await _frame()
	_streamer.flora_adopt_ms.clear()
	var cpu := PackedFloat64Array()
	var gpu := PackedFloat64Array()
	var inst_max := 0
	var idx := 1
	var last_us := Time.get_ticks_usec()
	while idx < route.size() and cpu.size() < PERF_SAMPLES:
		await _frame()
		var now_us := Time.get_ticks_usec()
		last_us = now_us
		var p2 := Vector2(_walker.pos.x, _walker.pos.z)
		var to: Vector2 = (route[idx] as Vector2) - p2
		while to.length() < 0.6 and idx < route.size() - 1:
			idx += 1
			to = (route[idx] as Vector2) - p2
		_walker.input_move = to.normalized()
		cpu.append(_cpu_last_ms)
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_vp()))
		inst_max = maxi(inst_max, int(_streamer.flora_instances))
	_walker.input_move = Vector2.ZERO
	var ad := PackedFloat64Array(_streamer.flora_adopt_ms)
	var frame := {
		"samples": cpu.size(), "cpu_p95_ms": _pctl(cpu, 0.95), "cpu_max_ms": _pctl(cpu, 1.0),
		"render_gpu_p95_ms": _pctl(gpu, 0.95), "instances_max": inst_max,
	}
	return {"frame": frame, "adopt": {"n": ad.size(), "p95_ms": _pctl(ad, 0.95), "max_ms": _pctl(ad, 1.0)}}
