extends Node
## Spec #517 world probe: the REAL renderer (not headless) loads the main project's world
## scene and measures what the player sees. It only MEASURES -- tests/verify_stalag_world.sh
## merges the oracle's JS-side numbers and the DoD's jq judges.
##
## Env: STALAG_WORLD_RAW      output JSON path (required)
##      STALAG_WORLD_ORACLE   directory written by tools/baseline/js_world_oracle.mjs (required)
##      STALAG_SHOTS_DIR      screenshot directory (required)
##      STALAG_MUTATE         none | water_off | water_sunk | tint_match | no_skin | no_fog | no_shadow | hole_punch
##
## Pixel metrics run on a half-size copy of the frame (the saved PNG is full size).

const MeshRay = preload("res://engine/stalag/tests/mesh_ray.gd")
const WORLD_SCENE := "res://game/world/world.tscn"
const TERRAIN_SHADER := "res://engine/stalag/shaders/stalag_terrain.gdshader"

var _mutation := "none"
var _shots_dir := ""
var _world: Node
var _streamer
var _walker
var _cam
var _sun: DirectionalLight3D
var _ray
var _rec := {}
var _first_load_plan_ready := false
var _first_load_seen := false
var _loads_before_ready := 0
var _probe_cam: Camera3D


func _ready() -> void:
	_run()


func _fail(msg: String) -> void:
	push_error("world_probe: " + msg)
	get_tree().quit(2)


# ---------------------------------------------------------------- frame helpers
func _frames(n: int) -> void:
	for _i in range(n):
		await RenderingServer.frame_post_draw


## Waits until the ring around the focus is adopted, nothing is in flight, and every
## chunk's water is attached; then applies the water mutations to whatever exists.
func _settle() -> void:
	var guard := 0
	while guard < 1500:
		await get_tree().process_frame
		guard += 1
		if _streamer.focus_chunk() == _streamer.chunk_of(_walker.pos) and _streamer.settled():
			break
	# the walker must be at rest too (a frame diff must not be a falling camera)
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
	_apply_node_mutations()


func _apply_node_mutations() -> void:
	for w in _streamer.water_nodes():
		w.visible = _mutation != "water_off"
		w.position = Vector3(0.0, -3.0 if _mutation == "water_sunk" else 0.0, 0.0)


func _grab() -> Image:
	await _frames(2)
	return get_viewport().get_texture().get_image()


func _small(img: Image) -> Image:
	var c := img.duplicate()
	c.convert(Image.FORMAT_RGB8)
	c.resize(img.get_width() / 2, img.get_height() / 2, Image.INTERPOLATE_NEAREST)
	return c


## Fraction of pixels whose max channel changed by more than 8, the mean RGB distance over
## those pixels, and mean(B) - mean(R) over them in frame `with_`.
func _diff(with_: Image, without: Image) -> Dictionary:
	var a := _small(with_).get_data()
	var b := _small(without).get_data()
	var n := a.size() / 3
	var changed := 0
	var dist_sum := 0.0
	var b_sum := 0.0
	var r_sum := 0.0
	for i in range(n):
		var o := i * 3
		var dr := absi(a[o] - b[o])
		var dg := absi(a[o + 1] - b[o + 1])
		var db := absi(a[o + 2] - b[o + 2])
		if dr > 8 or dg > 8 or db > 8:
			changed += 1
			dist_sum += sqrt(float(dr * dr + dg * dg + db * db))
			b_sum += a[o + 2]
			r_sum += a[o]
	return {
		"px": changed,
		"frac": float(changed) / float(n),
		"mean_rgb_dist": dist_sum / float(changed) if changed > 0 else 0.0,
		"blue_minus_red": (b_sum - r_sum) / float(changed) if changed > 0 else 0.0,
	}


func _distinct_colors(img: Image) -> int:
	var d := _small(img).get_data()
	var seen := {}
	var i := 0
	while i + 2 < d.size():
		seen[(d[i] << 16) | (d[i + 1] << 8) | d[i + 2]] = true
		i += 3
	return seen.size()


## Renders the current view with the water shown and hidden; returns the diff dictionary.
func _water_diff() -> Dictionary:
	var with_img: Image = await _grab()
	var nodes: Array = _streamer.water_nodes()
	var prev := []
	for w in nodes:
		prev.append(w.visible)
		w.visible = false
	var without_img: Image = await _grab()
	for i in range(nodes.size()):
		nodes[i].visible = prev[i]
	var d := _diff(with_img, without_img)
	d["image"] = with_img
	return d


# ---------------------------------------------------------------- world helpers
func _teleport(x: float, z: float, yaw: float, pitch: float) -> void:
	var y: float = StalagWorld.ground_floor(x, z, 200.0)
	_walker.teleport(Vector3(x, y, z), true)
	_cam.yaw = yaw
	_cam.pitch = pitch
	_cam.follow(_walker.pos)


func _yaw_toward(dx: float, dz: float) -> float:
	return atan2(-dx, -dz)


## Still water: LAKE or SPRING column; flowing: RIVER or FALL column.
func _wet(gx: int, gz: int, kind: String) -> bool:
	if kind == "still":
		return StalagWorld.is_flooded(gx, gz)
	if kind == "course":
		return StalagWorld.is_river_column(gx, gz)
	return StalagWorld.is_flooded(gx, gz) or StalagWorld.is_river_column(gx, gz)


## Nearest wet column of `kind` to world (x, z), within `radius_m`: {dist, x, z} or {dist: INF}.
func _nearest_water(x: float, z: float, kind: String, radius_m: float) -> Dictionary:
	var gx0 := floori(x / 0.5)
	var gz0 := floori(z / 0.5)
	var rc := int(radius_m / 0.5)
	var best := INF
	var bx := 0.0
	var bz := 0.0
	for dz in range(-rc, rc + 1):
		for dx in range(-rc, rc + 1):
			var d2 := float(dx * dx + dz * dz)
			if d2 >= best * best * 4.0 or d2 > float(rc * rc):
				continue
			if _wet(gx0 + dx, gz0 + dz, kind):
				var d := sqrt(d2) * 0.5
				if d < best:
					best = d
					bx = (gx0 + dx + 0.5) * 0.5
					bz = (gz0 + dz + 0.5) * 0.5
	return {"dist": best, "x": bx, "z": bz}


func _save(img: Image, name: String) -> String:
	var path := _shots_dir.path_join(name + ".png")
	img.save_png(path)
	return path


# ---------------------------------------------------------------- the run
func _run() -> void:
	var raw := OS.get_environment("STALAG_WORLD_RAW")
	var odir := OS.get_environment("STALAG_WORLD_ORACLE")
	_shots_dir = OS.get_environment("STALAG_SHOTS_DIR")
	_mutation = OS.get_environment("STALAG_MUTATE")
	if _mutation.is_empty():
		_mutation = "none"
	if raw.is_empty() or odir.is_empty() or _shots_dir.is_empty() or not ClassDB.class_exists("StalagWorld"):
		_fail("STALAG_WORLD_RAW / STALAG_WORLD_ORACLE / STALAG_SHOTS_DIR required and the engine must be loaded")
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	var of := FileAccess.open(odir.path_join("oracle.json"), FileAccess.READ)
	var oracle: Dictionary = JSON.parse_string(of.get_as_text())
	of.close()

	_rec = {
		"mutation": _mutation,
		"headless": DisplayServer.get_name() == "headless",
		"adapter": RenderingServer.get_video_adapter_name(),
		"project_name": str(ProjectSettings.get_setting("application/config/name")),
		"classes": {
			"StalagWorld": ClassDB.class_exists("StalagWorld"),
			"StalagChunkMesher": ClassDB.class_exists("StalagChunkMesher"),
		},
		"scale": {"sf": StalagWorld.get_sf()},
	}

	# ---- the world, exactly as the shell loads it
	_ray = MeshRay.new(StalagWorld.get_chunk_m())
	StalagChunkMesher.reset_build_stats()
	_world = (load(WORLD_SCENE) as PackedScene).instantiate()
	_world.scripted_input = true
	add_child(_world)
	_streamer = _world.streamer
	_walker = _world.walker
	_cam = _world.cam
	_sun = _world.sun
	_streamer.chunk_built.connect(func(c: Vector2i, v: PackedVector3Array) -> void: _ray.add_chunk(c, v))
	_streamer.chunk_loaded.connect(func(_c: Vector2i) -> void:
		if not _first_load_seen:
			_first_load_seen = true
			_first_load_plan_ready = StalagWorld.plan_ready())
	_apply_world_mutations()

	var guard := 0
	while not _streamer.ring_ready() and guard < 3000:
		await get_tree().process_frame
		guard += 1
	if not _streamer.ring_ready():
		_fail("the world never became ready")
		return
	await _settle()

	_rec["plan"] = {
		"ready_before_first_chunk": _first_load_plan_ready,
		"solve_on_main_thread": not StalagWorld.plan_solved_off_main_thread(),
		"js_hash": oracle["plan"]["hash"],
		"gd_hash": StalagWorld.plan_hash(),
	}
	var stats: Dictionary = StalagChunkMesher.get_build_stats()
	_rec["water_build_on_main"] = int(stats["on_main_thread"])

	_rec["ground"] = await _measure_ground()
	_rec["water"] = _measure_water()
	_rec["skin"] = await _measure_skin(oracle)
	_rec["sky"] = await _measure_sky()
	_rec["fog"] = await _measure_fog()
	_rec["shadow"] = await _measure_shadow()
	_rec["shots"] = await _measure_shots()
	_rec["sweep"] = await _measure_sweep()
	var total_hits := 0
	for v in _hole_views:
		total_hits += int(v["hits"])
	_rec["holes"] = {"loaded_radius_m": _loaded_radius_min, "hits": total_hits, "per_view": _hole_views}

	# ---- shutdown: every water node must go with its chunk
	_streamer.shutdown()
	await get_tree().process_frame
	_rec["water"]["nodes_after_shutdown"] = _count_named(get_tree().root, "Water")

	var f := FileAccess.open(raw, FileAccess.WRITE)
	f.store_string(JSON.stringify(_rec))
	f.close()
	get_tree().quit(0)


func _apply_world_mutations() -> void:
	match _mutation:
		"no_skin":
			var flat := Image.create(16, 16, false, Image.FORMAT_RGBA8)
			flat.fill(Color(0.30, 0.55, 0.22))
			var t := ImageTexture.create_from_image(flat)
			for m in [_world.grass_mat, _world.dirt_mat]:
				m.set_shader_parameter("tile", t)
				m.set_shader_parameter("use_skin", false)
		"no_fog":
			for m in [_world.grass_mat, _world.dirt_mat, _world.water_mat]:
				m.set_shader_parameter("use_fog", false)
		"no_shadow":
			_sun.shadow_enabled = false
		"tint_match":
			var img: Image = (_world.grass_mat.get_shader_parameter("tile") as Texture2D).get_image()
			img.convert(Image.FORMAT_RGBA8)
			var sum := Vector3.ZERO
			for y in range(img.get_height()):
				for x in range(img.get_width()):
					var c := img.get_pixel(x, y)
					sum += Vector3(c.r, c.g, c.b)
			sum /= float(img.get_width() * img.get_height())
			var avg := Color(sum.x, sum.y, sum.z)
			for k in ["tint1", "tint2", "tint3", "tint4", "foam", "w_hi"]:
				_world.water_mat.set_shader_parameter(k, avg)
			# a translucent sheet of the terrain's own average colour: it stays on screen but
			# no longer contrasts with what is under it
			_world.water_mat.set_shader_parameter("water_alpha", 0.45)


# ---------------------------------------------------------------- ground
func _hT(cx: int, cz: int) -> float:
	return floorf(StalagWorld.surface_height(cx, cz) / 4.0) * 4.0


## A column whose neighbours (both lattice cosets, one step out) stand no higher than it. A higher
## neighbour's overhanging faces can legitimately cover a lower column's centre, so only open
## columns are a fair ground truth for "the rendered surface here is the engine's carved height".
func _unoccluded(cx: int, cz: int) -> bool:
	var own := _hT(cx, cz)
	for o in [[4, 0], [-4, 0], [0, 4], [0, -4], [4, 4], [4, -4], [-4, 4], [-4, -4], [2, 2], [2, -2], [-2, 2], [-2, -2]]:
		if _hT(cx + o[0], cz + o[1]) > own:
			return false
	return true


func _measure_ground() -> Dictionary:
	# Stand in the carved country (a chunk the plan cuts into heavily) so that hundreds of the
	# sampled columns sit on carved ground; the ring of chunks around the walker is what is sampled.
	_teleport(42.0, -70.0, 0.0, 0.4)
	await _settle()
	var rng := RandomNumberGenerator.new()
	rng.seed = 517
	var carved: Array = []
	var flat: Array = []
	for _i in range(60000):
		var gx := rng.randi_range(-50, 200)
		var gz := rng.randi_range(-215, -5)
		var cx := 4 * gx
		var cz := 4 * gz
		var base := StalagWorld.surface_height_base(cx, cz)
		var h := StalagWorld.surface_height(cx, cz)
		var is_carved := absf(base - h) > 2.0
		if (is_carved and carved.size() >= 1200) or (not is_carved and flat.size() >= 1200):
			continue
		if not _unoccluded(cx, cz):
			continue
		if is_carved:
			carved.append([cx, cz, h])
		else:
			flat.append([cx, cz, h])
		if carved.size() >= 1200 and flat.size() >= 1200:
			break
	var samples := carved + flat
	var max_err := 0.0
	var worst: Array = []
	for s in samples:
		var x: float = s[0] * StalagWorld.get_sf()
		var z: float = s[1] * StalagWorld.get_sf()
		var expect: float = (floorf(float(s[2]) / 4.0) * 4.0 + 2.0) * StalagWorld.get_sf()
		var hit: float = _ray.height_at(x, z, 200.0)
		var err := 99.0 if is_nan(hit) else absf(hit - expect)
		if err > 0.05 and worst.size() < 4:
			worst.append([s[0], s[1], expect, hit, _ray.has_chunk(Vector2i(floori(x / 28.0), floori(z / 28.0)))])
		max_err = maxf(max_err, err)
	return {"samples": samples.size(), "carved_samples": carved.size(), "max_err_m": max_err, "worst": worst}


# ---------------------------------------------------------------- water
func _count_named(n: Node, name: String) -> int:
	var c := 1 if n.name == name else 0
	for ch in n.get_children():
		c += _count_named(ch, name)
	return c


func _measure_water() -> Dictionary:
	var chunk_m: float = StalagWorld.get_chunk_m()
	var nodes := 0
	var expected := 0
	var tris := 0
	var err := 0.0
	var buried := 0
	var checked := 0
	var chunk_set := {}
	for c in _streamer.chunk_coords():
		chunk_set[_streamer.chunk_node(c)] = true
		var x0: float = c.x * chunk_m
		var z0: float = c.y * chunk_m
		var direct := StalagChunkMesher.build_water_arrays(x0, x0 + chunk_m, z0, z0 + chunk_m)
		var want_tris: int = direct["tris"]
		var w = _streamer.water_node(c)
		if want_tris > 0:
			expected += 1
		if w == null:
			continue
		nodes += 1
		var arrays: Array = w.mesh.surface_get_arrays(0)
		var local: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		tris += local.size() / 3
		var xf: Transform3D = w.global_transform
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		var world_v := PackedVector3Array()
		world_v.resize(local.size())
		for k in range(local.size()):
			var p: Vector3 = xf * local[k]
			world_v[k] = p
			lo = lo.min(p)
			hi = hi.max(p)
		var dv: PackedVector3Array = direct["vertices"]
		var dlo := Vector3(INF, INF, INF)
		var dhi := Vector3(-INF, -INF, -INF)
		for p2 in dv:
			dlo = dlo.min(p2)
			dhi = dhi.max(p2)
		if dv.size() != local.size():
			err = maxf(err, 99.0)
		elif dv.size() > 0:
			err = maxf(err, maxf(_maxc((lo - dlo).abs()), _maxc((hi - dhi).abs())))
		# buried: a sample of the rendered triangles against the rendered terrain above them
		var step := maxi(1, (world_v.size() / 3) / 120)
		var t := 0
		while t + 2 < world_v.size():
			var cen := (world_v[t] + world_v[t + 1] + world_v[t + 2]) / 3.0
			var top: float = _ray.height_at(cen.x, cen.z, 200.0)
			checked += 1
			if not is_nan(top) and cen.y < top - 0.05:
				buried += 1
			t += 3 * step
	var orphans := 0
	for w2 in _all_water_nodes(get_tree().root):
		if not chunk_set.has(w2.get_parent()):
			orphans += 1
	var top_level := 0
	for ch in _streamer.get_children():
		if ch is MeshInstance3D:
			top_level += 1
	var st: Dictionary = StalagChunkMesher.get_build_stats()
	return {
		"nodes": nodes,
		"expected_nodes": expected,
		"orphans": orphans,
		"on_main_thread": int(_rec.get("water_build_on_main", 0)),
		"placement_err_m": err,
		"tris": tris,
		"buried_frac": float(buried) / float(maxi(checked, 1)),
		"buried_checked": checked,
		"top_level_mesh_instances_end": top_level,
		"loaded_end": _streamer.loaded_count(),
		"nodes_after_shutdown": -1,
		"direct_builds_on_main": int(st["on_main_thread"]),
	}


func _maxc(v: Vector3) -> float:
	return maxf(maxf(v.x, v.y), v.z)


func _all_water_nodes(n: Node) -> Array:
	var out: Array = []
	if n.name == "Water" and n is MeshInstance3D:
		out.append(n)
	for ch in n.get_children():
		out.append_array(_all_water_nodes(ch))
	return out


# ---------------------------------------------------------------- skin
func _tile_hash(tex: Texture2D) -> String:
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	return ctx.finish().hex_encode().substr(0, 12)


func _measure_skin(oracle: Dictionary) -> Dictionary:
	_teleport(0.0, 0.0, _world.SPAWN_YAW, 0.4)
	await _settle()
	var with_img: Image = await _grab()
	var mats := [_world.grass_mat, _world.dirt_mat]
	var prev: Array = []
	for m in mats:
		prev.append(m.get_shader_parameter("use_skin"))
		m.set_shader_parameter("use_skin", false)
	var flat_img: Image = await _grab()
	for i in range(mats.size()):
		mats[i].set_shader_parameter("use_skin", prev[i])
	var d := _diff(with_img, flat_img)
	return {
		"grass_tile_js_hash": oracle["tiles"]["grass_hash"],
		"grass_tile_gd_hash": _tile_hash(_world.grass_mat.get_shader_parameter("tile")),
		"dirt_tile_js_hash": oracle["tiles"]["dirt_hash"],
		"dirt_tile_gd_hash": _tile_hash(_world.dirt_mat.get_shader_parameter("tile")),
		"diff_frac": d["frac"],
	}


# ---------------------------------------------------------------- sky
func _probe_camera() -> Camera3D:
	if _probe_cam == null:
		_probe_cam = Camera3D.new()
		_probe_cam.fov = 70.0
		_probe_cam.far = 600.0
		add_child(_probe_cam)
	_probe_cam.environment = _cam.environment
	return _probe_cam


func _centre_pixel(img: Image) -> Color:
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)


func _measure_sky() -> Dictionary:
	var pc := _probe_camera()
	_streamer.visible = false
	_walker.body_node().visible = false
	pc.current = true
	pc.global_position = Vector3(0, 200, 0)
	pc.global_basis = Basis(Vector3.RIGHT, -PI / 2.0 + 0.001) # straight down: dir.y = -1, the horizon colour
	var down: Image = await _grab()
	pc.global_basis = Basis(Vector3.RIGHT, PI / 2.0 - 0.001) # straight up: the zenith colour
	var up: Image = await _grab()
	pc.current = false
	_cam.current = true
	_streamer.visible = true
	_walker.body_node().visible = true
	var hz := _centre_pixel(down)
	var zn := _centre_pixel(up)
	# the prototype's constants (index.html HAZE_COLOR 0xaacce0, SKY_ZENITH 0x5a96d0)
	var he := maxf(absf(hz.r8 - 0xaa), maxf(absf(hz.g8 - 0xcc), absf(hz.b8 - 0xe0)))
	var ze := maxf(absf(zn.r8 - 0x5a), maxf(absf(zn.g8 - 0x96), absf(zn.b8 - 0xd0)))
	return {"horizon_err": he, "zenith_err": ze, "horizon_rgb": [hz.r8, hz.g8, hz.b8], "zenith_rgb": [zn.r8, zn.g8, zn.b8]}


# ---------------------------------------------------------------- fog
func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


## Fog factor at distance d from pixels: a dark reference patch rendered with the terrain shader,
## fog on and off, against the haze colour; solved per channel in linear light.
func _fog_at(d: float) -> float:
	var shader := load(TERRAIN_SHADER) as Shader
	var dark := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	dark.fill(Color(0.10, 0.20, 0.12))
	var tex := ImageTexture.create_from_image(dark)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("tile", tex)
	mat.set_shader_parameter("use_fog", _mutation != "no_fog")
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(6, 6)
	quad.mesh = qm
	quad.material_override = mat
	add_child(quad)
	var pc := _probe_camera()
	_streamer.visible = false
	_walker.body_node().visible = false
	pc.current = true
	pc.global_position = Vector3(0, 300, 0)
	pc.global_basis = Basis.IDENTITY
	quad.global_position = Vector3(0, 300, -d)
	quad.global_basis = Basis.IDENTITY
	var on: Image = await _grab()
	mat.set_shader_parameter("use_fog", false)
	var off: Image = await _grab()
	pc.current = false
	_cam.current = true
	_streamer.visible = true
	_walker.body_node().visible = true
	quad.queue_free()
	var p_on := _centre_pixel(on)
	var p_off := _centre_pixel(off)
	var haze := Color(0xaa / 255.0, 0xcc / 255.0, 0xe0 / 255.0)
	var fs := []
	for ch in range(3):
		var lo := _lin(p_off[ch])
		var lh := _lin(haze[ch])
		var ln := _lin(p_on[ch])
		fs.append((ln - lo) / (lh - lo))
	return (fs[0] + fs[1] + fs[2]) / 3.0


func _measure_fog() -> Dictionary:
	var f60 := await _fog_at(60.0)
	var f150 := await _fog_at(150.0)
	return {"f60": f60, "f150": f150}


# ---------------------------------------------------------------- shadow
func _measure_shadow() -> Dictionary:
	_teleport(0.0, 0.0, _world.SPAWN_YAW, 0.4)
	await _settle()
	var was := _sun.shadow_enabled
	_sun.shadow_enabled = _mutation != "no_shadow"
	var on: Image = await _grab()
	_sun.shadow_enabled = false
	var off: Image = await _grab()
	_sun.shadow_enabled = was
	var d := _diff(on, off)
	return {"diff_frac": d["frac"]}


# ---------------------------------------------------------------- selection rule geom_v1
## Every stand is chosen ONCE from geometry (Spec #517 A4.3); a frame is measured once at it. There
## is no retry and no pixel feedback, so a mutation run takes exactly the stands of the clean run.
## tools/baseline/js_world_oracle.mjs computes shot_plan by the same written rule from the plan
## arrays; the DoD requires the two to agree.
const COL_M := 0.5
const FOOT_HALF := 111.0

func _col_center(g: int) -> float:
	return (float(g) + 0.5) * COL_M


func _is_still(gx: int, gz: int) -> bool:
	return StalagWorld.is_flooded(gx, gz)


func _is_course(gx: int, gz: int) -> bool:
	return StalagWorld.is_river_column(gx, gz)


## The still body L: the largest 4-connected component of still columns whose centres lie within
## 111 m on both axes; the first one met in (gz, gx) order wins ties. Returns {xs, zs} (centres).
func _still_body() -> Dictionary:
	var lo := -224
	var n := 448
	var seen := PackedByteArray()
	seen.resize(n * n)
	var best_x := PackedFloat64Array()
	var best_z := PackedFloat64Array()
	for gz in range(lo, lo + n):
		for gx in range(lo, lo + n):
			if absf(_col_center(gx)) > FOOT_HALF or absf(_col_center(gz)) > FOOT_HALF:
				continue
			var idx := (gz - lo) * n + (gx - lo)
			if seen[idx] == 1 or not _is_still(gx, gz):
				continue
			var cx := PackedFloat64Array()
			var cz := PackedFloat64Array()
			var stack: Array = [Vector2i(gx, gz)]
			seen[idx] = 1
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				cx.append(_col_center(c.x))
				cz.append(_col_center(c.y))
				for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = c.x + o.x
					var nz: int = c.y + o.y
					if nx < lo or nz < lo or nx >= lo + n or nz >= lo + n:
						continue
					if absf(_col_center(nx)) > FOOT_HALF or absf(_col_center(nz)) > FOOT_HALF:
						continue
					var ni := (nz - lo) * n + (nx - lo)
					if seen[ni] == 1 or not _is_still(nx, nz):
						continue
					seen[ni] = 1
					stack.append(Vector2i(nx, nz))
			if cx.size() > best_x.size():
				best_x = cx
				best_z = cz
	return {"xs": best_x, "zs": best_z}


const SHORE_R_M := 8.0  # the DoD bar requires the water within 8 m of the stand


## Quantised ground height (m) of the world at (x, z): the terrace-snapped carved surface.
func _hm(x: float, z: float) -> float:
	var sf: float = StalagWorld.get_sf()
	return floorf(StalagWorld.surface_height(x / sf, z / sf) / 4.0) * 4.0 * sf


## Shore: a RAISED VANTAGE over the largest still body (Kel ruling 2026-11-08). Candidates are
## integer-metre points with |x|,|z| <= 100 whose column is neither still water nor river and whose
## nearest SHORELINE column centre (an L column with a 4-neighbour outside L) is at least 2 m and at
## most SHORE_R_M = 8 m away. Highest quantised ground first (ties: smaller x, then smaller z);
## the first candidate with line of sight to the centroid of L (an eye 2.2 m above its ground, a
## target 0.1 m above the ground at the centroid, 50 samples, none with quantised ground above the
## line minus 0.05 m) is the stand: one stand, no retry. The view aims at the centroid of L.
## tools/baseline/js_world_oracle.mjs computes the same rule from the plan arrays.
func _shore_plan(body: Dictionary) -> Dictionary:
	var xs: PackedFloat64Array = body["xs"]
	var zs: PackedFloat64Array = body["zs"]
	var n := xs.size()
	var inl := {}
	for i in range(n):
		inl[floori(xs[i] / COL_M) * 4096 + floori(zs[i] / COL_M)] = true
	var sx := PackedFloat64Array()
	var sz := PackedFloat64Array()
	var cx := 0.0
	var cz := 0.0
	for i in range(n):
		cx += xs[i]
		cz += zs[i]
		var gx := floori(xs[i] / COL_M)
		var gz := floori(zs[i] / COL_M)
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if not inl.has((gx + o.x) * 4096 + gz + o.y):
				sx.append(xs[i])
				sz.append(zs[i])
				break
	cx /= float(n)
	cz /= float(n)
	var cands: Array = []
	for x in range(-100, 101):
		for z in range(-100, 101):
			var fx := float(x)
			var fz := float(z)
			var near_bound := false
			for i in range(sx.size()):
				if absf(sx[i] - fx) <= SHORE_R_M and absf(sz[i] - fz) <= SHORE_R_M:
					near_bound = true
					break
			if not near_bound:
				continue
			var cgx := floori(fx / COL_M)
			var cgz := floori(fz / COL_M)
			if _is_still(cgx, cgz) or _is_course(cgx, cgz):
				continue
			var nearest := INF
			for i in range(sx.size()):
				var dx := sx[i] - fx
				var dz := sz[i] - fz
				nearest = minf(nearest, dx * dx + dz * dz)
			var dist := sqrt(nearest)
			if dist < 2.0 or dist > SHORE_R_M:
				continue
			cands.append([_hm(fx, fz), fx, fz, dist])
	cands.sort_custom(func(a, b) -> bool:
		if a[0] != b[0]:
			return a[0] > b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	var y1 := _hm(cx, cz) + 0.1
	for c in cands:
		var y0: float = c[0] + 2.2
		var clear := true
		for i in range(1, 50):
			var t := float(i) / 50.0
			if _hm(c[1] + (cx - c[1]) * t, c[2] + (cz - c[2]) * t) > y0 + (y1 - y0) * t - 0.05:
				clear = false
				break
		if clear:
			return {"stand": Vector2(c[1], c[2]), "aim": Vector2(cx, cz), "dist_m": c[3], "height_m": c[0], "candidates": cands.size()}
	return {}


## Sweep: the water column (still or river) nearest the spawn, ties by lowest gz then gx; the stand is
## on the line from the spawn at max(0, d - 12), stepped back toward the spawn in 0.5 m while wet.
func _sweep_plan() -> Dictionary:
	var best_d := INF
	var tgt := Vector2.ZERO
	for gz in range(-224, 224):
		for gx in range(-224, 224):
			var cxm := _col_center(gx)
			var czm := _col_center(gz)
			if absf(cxm) > FOOT_HALF or absf(czm) > FOOT_HALF:
				continue
			var d2 := cxm * cxm + czm * czm
			if d2 >= best_d * best_d:
				continue
			if _is_still(gx, gz) or _is_course(gx, gz):
				best_d = sqrt(d2)
				tgt = Vector2(cxm, czm)
	var r := maxf(0.0, best_d - 12.0)
	var stand := tgt * (r / best_d)
	while r > 0.0 and (_is_still(floori(stand.x / COL_M), floori(stand.y / COL_M)) or _is_course(floori(stand.x / COL_M), floori(stand.y / COL_M))):
		r = maxf(0.0, r - 0.5)
		stand = tgt * (r / best_d)
	return {"stand": stand, "dist_to_water_m": stand.distance_to(tgt), "toward": tgt}


## Dry standing points on rings of the given radii around (wx, wz): nearest the origin first,
## ties by smaller x then smaller z.
func _ring_points(wx: float, wz: float, radii: Array, angles: int) -> Array:
	var out: Array = []
	for r in radii:
		for ai in range(angles):
			var a := float(ai) * TAU / float(angles)
			var x: float = wx + cos(a) * float(r)
			var z: float = wz + sin(a) * float(r)
			var gx := floori(x / 0.5)
			var gz := floori(z / 0.5)
			if StalagWorld.is_flooded(gx, gz) or StalagWorld.is_river_column(gx, gz):
				continue
			if absf(x) > 100.0 or absf(z) > 100.0:
				continue
			out.append(Vector2(x, z))
	out.sort_custom(func(p: Vector2, q: Vector2) -> bool:
		if not is_equal_approx(p.length(), q.length()):
			return p.length() < q.length()
		if p.x != q.x:
			return p.x < q.x
		return p.y < q.y)
	return out


## True when the straight line from an eye 2.2 m above the ground at `from` to the ground at
## `to` clears the terrain in between (the engine's own ground query, not the renderer's).
func _line_clear(from: Vector2, to: Vector2) -> bool:
	var y0: float = StalagWorld.ground_floor(from.x, from.y, 200.0) + 2.2
	var y1: float = StalagWorld.ground_floor(to.x, to.y, 200.0) + 0.1
	for i in range(1, 50):
		var t := float(i) / 50.0
		var p := from.lerp(to, t)
		var gy: float = StalagWorld.ground_floor(p.x, p.y, 200.0)
		if gy > lerpf(y0, y1, t) - 0.05:
			return false
	return true


# ---------------------------------------------------------------- holes (sky where ground exists)
var _hole_views: Array = []
var _loaded_radius_min := INF


## Largest r (in 7 m steps, to 140 m) such that every chunk of the WORLD touching the square of
## half-size r around the walker is loaded (the footprint is +-112 m; there is no chunk beyond it).
func _loaded_radius() -> float:
	var r := 0.0
	while r < 140.0:
		var nr := r + 7.0
		var ok := true
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var p: Vector3 = _walker.pos + Vector3(sx * nr, 0.0, sz * nr)
				if absf(p.x) > StalagWorld.get_half_extent_m() - 0.01 or absf(p.z) > StalagWorld.get_half_extent_m() - 0.01:
					continue
				if _streamer.chunk_node(_streamer.chunk_of(p)) == null:
					ok = false
		if not ok:
			break
		r = nr
	return r


## One view: every grid pixel below the horizon that shows SKY (it equals the sky-only render of
## the same view to within 3/255) is marched along its camera ray, 0.5 m steps to 50 m, against the
## engine's ground (the centre-point surface, ground_envelope_at); a ray that enters engine ground
## inside the footprint while the pixel shows sky is a hole -- ground the engine has and the mesh
## does not draw. Beyond the +-111 m footprint the engine's ground query is unbounded but no mesh
## exists by design, so those rays are counted apart (outside_footprint), not as holes. The
## footprint-max query ground_floor is NOT used here: next to a step it reports a neighbour's
## height up to a metre above the surface under the ray and flags legitimate sky.
## Mutation hole_punch hides the focus chunk's terrain.
func _hole_view(name: String) -> void:
	var punched = null
	if _mutation == "hole_punch":
		punched = _streamer.chunk_node(_streamer.focus_chunk())
		if punched != null:
			punched.visible = false
	var frame: Image = await _grab()
	_streamer.visible = false
	_walker.body_node().visible = false
	var sky_img: Image = await _grab()
	_streamer.visible = true
	_walker.body_node().visible = true
	if punched != null:
		punched.visible = true
	var cam3: Camera3D = get_viewport().get_camera_3d()
	var w := frame.get_width()
	var h := frame.get_height()
	var fwd := Vector3(-sin(_cam.yaw), 0.0, -cos(_cam.yaw))
	var hz: Vector2 = cam3.unproject_position(cam3.global_position + fwd * 100000.0)
	var samples := 0
	var hits := 0
	var first_hit := []
	var outside := 0
	for yy in range(clampi(int(hz.y) + 8, 0, h - 1), h, 16):
		for xx in range(8, w, 16):
			samples += 1
			var a := frame.get_pixel(xx, yy)
			var b := sky_img.get_pixel(xx, yy)
			if absf(a.r - b.r) >= 0.012 or absf(a.g - b.g) >= 0.012 or absf(a.b - b.b) >= 0.012:
				continue
			var o := cam3.project_ray_origin(Vector2(xx, yy))
			var d := cam3.project_ray_normal(Vector2(xx, yy))
			var t := 0.5
			while t < 50.0:
				var p := o + d * t
				if p.y < StalagWorld.ground_envelope_at(p.x, p.z, INF):
					if absf(p.x) > FOOT_HALF or absf(p.z) > FOOT_HALF:
						outside += 1
					else:
						hits += 1
						if first_hit.is_empty():
							first_hit = [snappedf(p.x, 0.1), snappedf(p.y, 0.1), snappedf(p.z, 0.1)]
					break
				t += 0.5
	_loaded_radius_min = minf(_loaded_radius_min, _loaded_radius())
	_hole_views.append({"name": name, "samples": samples, "hits": hits, "outside_footprint": outside, "first_hit": first_hit})


# ---------------------------------------------------------------- sweep + shots
## The sweep stands at the planned point 12 m short of the nearest water and turns through eight
## 45 degree yaws; each yaw is a measured view and a hole view.
func _measure_sweep() -> Dictionary:
	var plan := _sweep_plan()
	var stand: Vector2 = plan["stand"]
	_teleport(stand.x, stand.y, 0.0, 0.35)
	await _settle()
	var steps := 8
	var best := 0.0
	for i in range(steps):
		_cam.yaw = float(i) * TAU / float(steps)
		_cam.follow(_walker.pos)
		var d := await _water_diff()
		best = maxf(best, d["frac"])
		await _hole_view("sweep%d" % i)
	return {
		"yaw_steps": steps,
		"max_water_diff_frac": best,
		"stand": [snappedf(stand.x, 0.01), snappedf(stand.y, 0.01)],
		"dist_to_water_m": snappedf(plan["dist_to_water_m"], 0.01),
	}


func _shot_record(name: String, d: Dictionary, body_dist: float, stand: Vector2) -> Dictionary:
	var img: Image = d["image"]
	var path := _save(img, name)
	return {
		"name": name,
		"file": path,
		"w": img.get_width(),
		"h": img.get_height(),
		"distinct_colors": _distinct_colors(img),
		"water_diff_px": d["px"],
		"water_diff_frac": d["frac"],
		"mean_rgb_dist": d["mean_rgb_dist"],
		"blue_minus_red": d["blue_minus_red"],
		"body_dist_m": minf(body_dist, 9999.0),
		"selection": {"rule": "geom_v1", "rank": 0, "stand": [snappedf(stand.x, 0.01), snappedf(stand.y, 0.01)]},
	}


## One stand, one frame: teleport, settle, measure the water diff once, then the hole view.
func _take_shot(name: String, p: Vector2, yaw: float, pitch: float, body_dist: float) -> Dictionary:
	_teleport(p.x, p.y, yaw, pitch)
	await _settle()
	var d := await _water_diff()
	var rec := _shot_record(name, d, body_dist, p)
	await _hole_view(name)
	return rec


func _measure_shots() -> Array:
	var shots: Array = []
	# spawn: where the player enters, default view
	_teleport(0.0, 0.0, _world.SPAWN_YAW, 0.4)
	await _settle()
	var d0 := await _water_diff()
	shots.append(_shot_record("spawn", d0, _nearest_water(0.0, 0.0, "any", 60.0)["dist"], Vector2.ZERO))
	await _hole_view("spawn")

	# shore: the planned bank stand on the still body, aimed at the centroid of its near columns
	var body := _still_body()
	_rec["still_body_cols"] = (body["xs"] as PackedFloat64Array).size()
	var sp := _shore_plan(body)
	if sp.is_empty():
		_fail("no shore stand")
		return shots
	var shore_p: Vector2 = sp["stand"]
	var aim: Vector2 = sp["aim"]
	_rec["shore_plan"] = {"rule": "raised_vantage", "radius_m": SHORE_R_M, "stand": [shore_p.x, shore_p.y], "aim": [snappedf(aim.x, 0.01), snappedf(aim.y, 0.01)], "dist_m": snappedf(sp["dist_m"], 0.01), "height_m": sp["height_m"], "candidates": sp["candidates"]}
	var shore_near := _nearest_water(shore_p.x, shore_p.y, "still", 60.0)
	shots.append(await _take_shot("shore", shore_p, _yaw_toward(aim.x - shore_p.x, aim.y - shore_p.y), 0.40, shore_near["dist"]))

	# river: the first dry ring point (nearest the origin) around the nearest flowing water that has
	# flowing water within 10 m
	var river := _nearest_water(0.0, 0.0, "course", 80.0)
	var river_p := Vector2.ZERO
	var river_near := {}
	for p in _ring_points(river["x"], river["z"], [4.0, 6.0, 8.0], 16):
		var nr := _nearest_water(p.x, p.y, "course", 60.0)
		if nr["dist"] <= 10.0:
			river_p = p
			river_near = nr
			break
	shots.append(await _take_shot("river", river_p, _yaw_toward(river_near["x"] - river_p.x, river_near["z"] - river_p.y), 0.40, river_near["dist"]))

	# distant: water seen from 30 m or more. Dry grid points whose nearest water (any kind) is
	# 30.5 to 46 m away and in plain sight, highest above that water first (ties by x, then z);
	# the first one is the stand.
	var far: Array = []
	for gzm in range(-96, 97, 4):
		for gxm in range(-96, 97, 4):
			var px := float(gxm)
			var pz := float(gzm)
			if StalagWorld.is_flooded(floori(px / 0.5), floori(pz / 0.5)) or StalagWorld.is_river_column(floori(px / 0.5), floori(pz / 0.5)):
				continue
			var nw := _nearest_water(px, pz, "any", 46.0)
			if nw["dist"] < 30.5 or nw["dist"] > 46.0:
				continue
			if not _line_clear(Vector2(px, pz), Vector2(nw["x"], nw["z"])):
				continue
			var rise: float = StalagWorld.ground_floor(px, pz, 200.0) - StalagWorld.ground_floor(nw["x"], nw["z"], 200.0)
			far.append([rise, Vector2(px, pz), nw])
	far.sort_custom(func(a, b) -> bool:
		if a[0] != b[0]:
			return a[0] > b[0]
		var pa: Vector2 = a[1]
		var pb: Vector2 = b[1]
		if pa.x != pb.x:
			return pa.x < pb.x
		return pa.y < pb.y)
	if far.is_empty():
		_fail("no distant stand")
		return shots
	var fp: Vector2 = far[0][1]
	var fn: Dictionary = far[0][2]
	shots.append(await _take_shot("distant", fp, _yaw_toward(fn["x"] - fp.x, fn["z"] - fp.y), 0.62, fn["dist"]))
	return shots
