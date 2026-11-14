extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 577 S2a scenic render probe. Loads the REAL world scene (res://game/world/world.tscn) exactly as
## engine/stalag/tests/world_probe.gd does, moves a probe Camera3D through the authored shots in
## tools/scenic/shots.json, sets the world's sun, sky and fog per shot, and saves each frame untouched
## (the PNG is the raw 1600x900 viewport; nothing is painted or edited). It only MEASURES: tools/scenic/post.py
## computes the pixel statistics, decides pass/fail against thresholds.json and writes the manifest.
##
## Every number that a gate or a pick leans on is read back from the node or the pixels, never from the
## author's tags: fov from the Camera3D, sun elevation from the DirectionalLight3D basis, camera clearance
## from the engine's ground query, water coverage from a water-hidden vs water-shown differential, and the
## river-bank flag from rays marched through the frame against the engine's river columns.
##
## Determinism: each shot gets a FRESH world (so the chunk set never depends on the shot before it), the wind
## clock is frozen, and the water shader's TIME is replaced by a fixed uniform (see _freeze_water_time).
##
## Env: SCENIC_OUT (required) output dir; SCENIC_ONLY (optional) a shot id, a comma list of ids, @first or
##      @control; SCENIC_SHOTS (optional) a shots.json path (default: the one next to this script).
##
## Spec 580: every shot names a `view_distance` (near, far or vista: the game's own levels, set on the world scene
## before it loads), and a shot with "mutate": "thin" turns the streamer's trees, meadow and understory off (a
## control that must FAIL the richness floors). The far and species metrics are read with
## tools/scenic/richness_metrics.gd against the shot's own fog.

const WORLD_SCENE := "res://game/world/world.tscn"
const SKY_SHADER := "res://tools/scenic/scenic_sky.gdshader"
const DEFAULT_SHOTS := "res://tools/scenic/shots.json"
const HomesteadView := preload("res://game/homestead/homestead_view.gd")
const RichnessMetrics := preload("res://tools/scenic/richness_metrics.gd")

const WATER_TIME := 40.0  ## the fixed value the water shader reads instead of TIME
const WIND_CLOCK := 3.0  ## the fixed wind clock of every shot
const FAR_M := 1200.0
## River measurement: a coarse ray grid, marched against the engine's ground.
const RIVER_COLS := 64
const RIVER_ROWS := 36
const RIVER_RANGE_M := 200.0
const RIVER_NEAR_M := 2.5
const RIVER_MIN_RAYS := 8
const RIVER_MAX_FOG := 0.8  ## rays that land where fog already hides 80 percent do not count as "in frame"
const WORLD_HALF_M := 112.0
const FOCUS_AHEAD_M := 30.0
## Spec 580: a shot may not clear the haze below the game's own farthest view level (its `vista` fog), so a
## picture is never "farther" than the game can draw. A flat control is exempt (it is meant to look wrong).
const MIN_FOG_DENSITY := 0.005

var _out := ""
var _size := Vector2i(1600, 900)
var _world: Node
var _streamer
var _walker
var _vp: SubViewport
var _pc: Camera3D
var _water_shader_ok := false


func _ready() -> void:
	_run()


func _fail(msg: String) -> void:
	push_error("scenic_shots: " + msg)
	get_tree().quit(2)


func _frames(n: int) -> void:
	for _i in range(n):
		await RenderingServer.frame_post_draw


# ---------------------------------------------------------------- the run
func _run() -> void:
	_out = OS.get_environment("SCENIC_OUT")
	if _out.is_empty() or not ClassDB.class_exists("StalagWorld"):
		_fail("SCENIC_OUT is required and the engine must be loaded")
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var shots_path := OS.get_environment("SCENIC_SHOTS")
	if shots_path.is_empty():
		shots_path = DEFAULT_SHOTS
	var doc = JSON.parse_string(FileAccess.get_file_as_string(shots_path))
	if typeof(doc) != TYPE_DICTIONARY or not doc.has("shots"):
		_fail("cannot read shots from " + shots_path)
		return
	_size = Vector2i(int(doc["size"][0]), int(doc["size"][1]))
	var chosen := _select(doc["shots"], OS.get_environment("SCENIC_ONLY"))
	if chosen.is_empty():
		_fail("SCENIC_ONLY matched no shot")
		return

	get_viewport().disable_3d = true  # the window itself draws nothing; the SubViewport below does
	_vp = SubViewport.new()
	_vp.size = _size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_pc = Camera3D.new()
	_pc.far = FAR_M
	_vp.add_child(_pc)

	var records: Array = []
	for s in chosen:
		await _load_world(s)
		records.append(await _shoot(s))
		await _unload_world()

	var raw := {
		"headless": DisplayServer.get_name() == "headless",
		"display": OS.get_environment("DISPLAY"),
		"adapter": RenderingServer.get_video_adapter_name(),
		"godot_version": str(Engine.get_version_info()["string"]),
		"scene": WORLD_SCENE,
		"water_time_frozen": _water_shader_ok,
		"shots": records,
	}
	var f := FileAccess.open(_out.path_join("raw.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(raw, "\t"))
	f.close()
	get_tree().quit(0)


## SCENIC_ONLY: empty = every shot; @first = the first non-control shot; @control = the control;
## otherwise a shot id or a comma list of ids.
func _select(all: Array, only: String) -> Array:
	if only.is_empty():
		return all
	var out: Array = []
	if only == "@first":
		for s in all:
			if not bool(s.get("control", false)):
				out.append(s)
				break
		return out
	if only == "@control":
		for s in all:
			if bool(s.get("control", false)):
				out.append(s)
		return out
	var ids := only.split(",", false)
	for s in all:
		if ids.has(str(s["id"])):
			out.append(s)
	return out


# ---------------------------------------------------------------- the world
func _load_world(s: Dictionary) -> void:
	_world = (load(WORLD_SCENE) as PackedScene).instantiate()
	_world.scripted_input = true
	_world.flora_clock = WIND_CLOCK
	_world.flora_clock_frozen = true
	_world.view_distance = str(s.get("view_distance", "near"))
	if str(s.get("mutate", "none")) == "thin":
		# the streamer's own switches: no trees, no meadow, no understory (the negative control)
		var st = _world.get_node("Streamer")
		st.flora_enabled = false
		st.trees_enabled = false
		st.understory_enabled = false
	add_child(_world)
	_streamer = _world.streamer
	_walker = _world.walker
	var guard := 0
	while not _streamer.ring_ready() and guard < 3000:
		await get_tree().process_frame
		guard += 1
	if not _streamer.ring_ready():
		_fail("the world never became ready")
		return
	guard = 0
	while _world.has_method("backdrop_ready") and not _world.backdrop_ready() and guard < 3000:
		await get_tree().process_frame  # the backdrop ring builds a few columns per frame
		guard += 1
	_freeze_water_time()
	await _settle()


func _unload_world() -> void:
	_streamer.shutdown()
	_world.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## The water shader animates from the engine's TIME, which differs on every run. Swap it for a uniform that
## holds one fixed value, so the same shot is the same picture. The edit is made on the shader's text and
## checked: if the shader changes shape the run fails instead of silently going nondeterministic.
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
	_water_shader_ok = true


## Waits until the ring around the focus is adopted, nothing is in flight, and the walker is at rest.
func _settle() -> void:
	var guard := 0
	while guard < 1500:
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


# ---------------------------------------------------------------- one shot
func _shoot(s: Dictionary) -> Dictionary:
	var cam_xz: Array = s["cam"]
	if not bool(s.get("control", false)) and float(s["fog"]["density"]) < MIN_FOG_DENSITY:
		_fail("shot %s clears the haze below the game's own vista fog (%s)" % [str(s["id"]), str(MIN_FOG_DENSITY)])
		return {}
	# the pose is authored as a heading (0 = +z, 90 = +x) and where the horizon should sit in the frame
	# (0 = top edge, 1 = bottom edge, negative = above the frame); the pitch follows from the lens
	var hd := deg_to_rad(float(s["heading_deg"]))
	var pitch_down := atan((0.5 - float(s["horizon_frac"])) * 2.0 * tan(deg_to_rad(float(s["fov_deg"])) * 0.5))
	var dir := Vector3(sin(hd) * cos(pitch_down), -sin(pitch_down), cos(hd) * cos(pitch_down))
	# the streamer ring is centred where the lens is looking (30 m ahead unless the shot says otherwise)
	var half_m := WORLD_HALF_M - 8.0
	var ahead := [clampf(float(cam_xz[0]) + sin(hd) * FOCUS_AHEAD_M, -half_m, half_m), clampf(float(cam_xz[1]) + cos(hd) * FOCUS_AHEAD_M, -half_m, half_m)]
	var focus: Array = s.get("focus", ahead)
	_teleport(float(focus[0]), float(focus[1]))
	await _settle()

	# the camera
	var ground: float = StalagWorld.ground_envelope_at(float(cam_xz[0]), float(cam_xz[1]), INF)
	var cam_pos := Vector3(float(cam_xz[0]), ground + float(s["height_m"]), float(cam_xz[1]))
	_pc.fov = float(s["fov_deg"])
	_pc.environment = _world.cam.environment
	_pc.global_position = cam_pos
	_pc.look_at(cam_pos + dir * 100.0, Vector3.UP)
	_pc.current = true
	_walker.body_node().visible = false
	var fwd_flat := Vector3(-_pc.global_basis.z.x, 0.0, -_pc.global_basis.z.z)

	_apply_look(s, fwd_flat)
	await _frames(3)

	# the frame as the viewer sees it, and again with the water hidden (water_frac is measured, not claimed)
	var with_img: Image = await _grab()
	var nodes: Array = _streamer.water_nodes()
	nodes.append_array(get_tree().get_nodes_in_group("backdrop_water"))
	var prev := []
	for w in nodes:
		prev.append(w.visible)
		w.visible = false
	var without_img: Image = await _grab()
	for i in range(nodes.size()):
		nodes[i].visible = prev[i]
	var water_frac := _changed_frac(with_img, without_img)
	# Spec 580 S4: the frame with the whole world hidden is pure sky; post.py counts the gap below the horizon and
	# the floating water pixels from these three frames (saved as aux-*, which the shot-* globs never see).
	_world.visible = false
	var sky_img: Image = await _grab()
	_world.visible = true

	var id := str(s["id"])
	with_img.save_png(_out.path_join("shot-%s.png" % id))
	without_img.save_png(_out.path_join("aux-%s-nowater.png" % id))
	sky_img.save_png(_out.path_join("aux-%s-sky.png" % id))

	var d_sun: Vector3 = _sun().global_basis.z  # points toward the sun
	var rec := {
		"id": id,
		"control": bool(s.get("control", false)),
		"subject": str(s["subject"]),
		"river_authored": bool(s["river_bank_in_frame"]),
		"cam_pos": [snappedf(_pc.global_position.x, 0.001), snappedf(_pc.global_position.y, 0.001), snappedf(_pc.global_position.z, 0.001)],
		"fov_deg": snappedf(_pc.fov, 0.001),
		"sun_elevation_deg": snappedf(rad_to_deg(asin(clampf(d_sun.y, -1.0, 1.0))), 0.001),
		"clearance_m": snappedf(_pc.global_position.y - StalagWorld.ground_envelope_at(_pc.global_position.x, _pc.global_position.z, INF), 0.001),
		"png_w": with_img.get_width(),
		"png_h": with_img.get_height(),
		"water_frac": snappedf(water_frac, 0.0001),
		"horizon_y_frac": _horizon_y_frac(fwd_flat),
		"fog_density": snappedf(float(s["fog"]["density"]), 0.0001),
		"view_distance": str(s.get("view_distance", "near")),
		"horizon_row_px": snappedf(_pc.unproject_position(_pc.global_position + fwd_flat.normalized() * 100000.0).y, 0.1),
	}
	var dens := float(s["fog"]["density"])
	if dens > 0.0:  # fog off (density 0) is only the flat control; its far content is bounded by the world
		rec.merge(RichnessMetrics.new(_pc, _streamer, _size).measure(dens))
	else:
		rec.merge(RichnessMetrics.new(_pc, _streamer, _size).measure(MIN_FOG_DENSITY))
	rec.merge(_river_rays(float(s["fog"]["density"])))
	rec["homestead_in_frame"] = _homestead_in_frame()
	return rec


func _sun() -> DirectionalLight3D:
	return _world.sun


func _grab() -> Image:
	await _frames(2)
	return _vp.get_texture().get_image()


## Fraction of pixels whose largest channel differs by more than 8 (the probe's own water differential).
func _changed_frac(a_img: Image, b_img: Image) -> float:
	var a := a_img.duplicate()
	var b := b_img.duplicate()
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	a.resize(a.get_width() / 2, a.get_height() / 2, Image.INTERPOLATE_NEAREST)
	b.resize(b.get_width() / 2, b.get_height() / 2, Image.INTERPOLATE_NEAREST)
	var da: PackedByteArray = a.get_data()
	var db: PackedByteArray = b.get_data()
	var n: int = da.size() / 3
	var changed := 0
	for i in range(n):
		var o := i * 3
		if absi(da[o] - db[o]) > 8 or absi(da[o + 1] - db[o + 1]) > 8 or absi(da[o + 2] - db[o + 2]) > 8:
			changed += 1
	return float(changed) / float(n)


# ---------------------------------------------------------------- the look: sun, ambient, sky, fog
func _col(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


func _apply_look(s: Dictionary, fwd_flat: Vector3) -> void:
	var sun_j: Dictionary = s["sun"]
	var env: Environment = _world.cam.environment
	# sun: elevation above the horizon, azimuth relative to where the camera looks (0 = into the lens)
	var elev := deg_to_rad(float(sun_j["elev_deg"]))
	var head := atan2(fwd_flat.x, fwd_flat.z)
	var az := head + deg_to_rad(float(sun_j["rel_azimuth_deg"]))
	var to_sun := Vector3(sin(az) * cos(elev), sin(elev), cos(az) * cos(elev)).normalized()
	var sun := _sun()
	sun.global_position = Vector3(0.0, 50.0, 0.0)
	sun.look_at(sun.global_position - to_sun, Vector3.UP)
	sun.light_color = _col(sun_j["color"])
	sun.light_energy = float(sun_j["energy"])
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = float(s.get("shadow_m", 400.0))
	# ambient and tone
	var amb: Dictionary = s["ambient"]
	env.ambient_light_color = _col(amb["color"])
	env.ambient_light_energy = float(amb["energy"])
	env.tonemap_mode = int(s.get("tonemap", 0))
	env.tonemap_exposure = float(s.get("exposure", 1.0))
	env.glow_enabled = float(s.get("glow", 0.0)) > 0.0
	if env.glow_enabled:
		env.glow_intensity = float(s["glow"])
		env.glow_bloom = 0.0
		env.glow_hdr_threshold = float(s.get("glow_threshold", 1.1))
	# sky (null = the game's own sky, untouched)
	if s["sky"] != null:
		var sk: Dictionary = s["sky"]
		var m := ShaderMaterial.new()
		m.shader = load(SKY_SHADER)
		m.set_shader_parameter("horizon_color", _col(sk["horizon"]))
		m.set_shader_parameter("zenith_color", _col(sk["zenith"]))
		m.set_shader_parameter("sun_color", _col(sk["sun_color"]))
		m.set_shader_parameter("sun_dir", to_sun)
		m.set_shader_parameter("sun_size", float(sk.get("sun_size", 0.016)))
		m.set_shader_parameter("glow_strength", float(sk.get("glow_strength", 0.35)))
		m.set_shader_parameter("glow_power", float(sk.get("glow_power", 14.0)))
		env.sky.sky_material = m
	# fog: every shader that carries haze_color takes the shot's haze and density (density 0 = fog off)
	var fog: Dictionary = s["fog"]
	var seen := {}
	_collect_fog_materials(_world, seen)
	for m in seen.values():
		var mat: ShaderMaterial = m
		mat.set_shader_parameter("haze_color", _col(fog["haze"]))
		mat.set_shader_parameter("fog_density", float(fog["density"]))
		# keep the moss and rock shading oriented to THIS sun, as the game does for its own
		if _has_uniform(mat, "sun_xz"):
			mat.set_shader_parameter("sun_xz", Vector2(to_sun.x, to_sun.z))


func _has_uniform(mat: ShaderMaterial, uname: String) -> bool:
	if mat.shader == null:
		return false
	for u in mat.shader.get_shader_uniform_list():
		if str(u["name"]) == uname:
			return true
	return false


func _note_material(m: Material, out: Dictionary) -> void:
	var cur := m
	while cur != null:
		if cur is ShaderMaterial and _has_uniform(cur as ShaderMaterial, "haze_color"):
			out[cur.get_instance_id()] = cur
		cur = cur.next_pass


func _note_mesh(mesh: Mesh, out: Dictionary) -> void:
	if mesh == null:
		return
	for i in range(mesh.get_surface_count()):
		_note_material(mesh.surface_get_material(i), out)


func _collect_fog_materials(n: Node, out: Dictionary) -> void:
	if n is GeometryInstance3D:
		_note_material((n as GeometryInstance3D).material_override, out)
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			_note_mesh(mi.mesh, out)
			for i in range(mi.get_surface_override_material_count()):
				_note_material(mi.get_surface_override_material(i), out)
		elif n is MultiMeshInstance3D:
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm != null:
				_note_mesh(mm.mesh, out)
	for c in n.get_children():
		_collect_fog_materials(c, out)


# ---------------------------------------------------------------- measurements read from the frame
## Where the horizon line sits in the frame, 0 = top, 1 = bottom; null when it is off screen.
func _horizon_y_frac(fwd_flat: Vector3) -> Variant:
	if fwd_flat.length() < 1e-4:
		return null
	var far_pt := _pc.global_position + fwd_flat.normalized() * 100000.0
	if _pc.is_position_behind(far_pt):
		return null
	var p := _pc.unproject_position(far_pt)
	var y := p.y / float(_size.y)
	if y < 0.0 or y > 1.0:
		return null
	return snappedf(y, 0.0001)


## Marches a coarse grid of pixel rays against the engine's ground. A ray that lands within RIVER_NEAR_M of a
## river column (inside the world, within RIVER_RANGE_M, where fog still leaves it visible) counts as a river
## bank in frame. Trees and mesas that would hide the bank are ignored on purpose: the flag errs toward true.
func _river_rays(density: float) -> Dictionary:
	var hits := 0
	var range_m := RIVER_RANGE_M
	if density > 0.0:
		range_m = minf(range_m, sqrt(-log(1.0 - RIVER_MAX_FOG)) / density)
	var o := _pc.global_position
	for r in range(RIVER_ROWS):
		for c in range(RIVER_COLS):
			var px := Vector2((float(c) + 0.5) / float(RIVER_COLS) * float(_size.x), (float(r) + 0.5) / float(RIVER_ROWS) * float(_size.y))
			var d := _pc.project_ray_normal(px)
			var t := 0.5
			while t < range_m:
				var p := o + d * t
				if absf(p.x) > WORLD_HALF_M or absf(p.z) > WORLD_HALF_M:
					break
				if p.y < StalagWorld.ground_envelope_at(p.x, p.z, INF):
					if _near_river(p.x, p.z):
						hits += 1
					break
				t += 0.5 if t < 40.0 else 1.0
	return {"river_rays": hits, "river_rays_total": RIVER_COLS * RIVER_ROWS, "river_measured": hits >= RIVER_MIN_RAYS}


func _near_river(x: float, z: float) -> bool:
	var gx0 := floori(x / 0.5)
	var gz0 := floori(z / 0.5)
	var rc := int(RIVER_NEAR_M / 0.5)
	for dz in range(-rc, rc + 1, 2):
		for dx in range(-rc, rc + 1, 2):
			if StalagWorld.is_river_column(gx0 + dx, gz0 + dz):
				return true
	return false


## True when any point of the homestead's bounding box lies inside the camera frustum (occlusion ignored).
func _homestead_in_frame() -> bool:
	var hs: Node3D = _world.homestead
	if hs == null:
		return false
	var box: AABB = HomesteadView.world_aabb(hs)
	for ix in range(5):
		for iy in range(3):
			for iz in range(5):
				var p := box.position + Vector3(box.size.x * float(ix) / 4.0, box.size.y * float(iy) / 2.0, box.size.z * float(iz) / 4.0)
				if _pc.is_position_in_frustum(p):
					return true
	return false
