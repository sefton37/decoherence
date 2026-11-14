extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 581 S1 render probe: boots the REAL world scene (streamer, walker, follow camera, homestead, the
## Avatar view node) on a real renderer and MEASURES. It never judges: the DoD's jq does. Every claim is
## measured in the observer's frame or from the live scene tree:
##   - the wiring is read from the running tree (view nodes, the body's parent, capsules left behind);
##   - seating is compared with down-rays against the triangles handed to the renderer (mesh_ray.gd);
##   - animation is read from the joint nodes' rotations while the walker really walks;
##   - visibility is a hide-the-body differential: the pixels inside the body's projected rectangle that
##     change when only the body is hidden, with the world frozen (per-channel tolerance 4);
##   - cost is the view's own per-frame update time plus the renderer's draw calls and primitives for the
##     same frozen frame with the body shown and hidden.
## Mutations are negative controls whose records must FAIL the same predicates:
##   none     the player's own view
##   hidden   the body is hidden before every capture
##   capsule  the old placeholder capsule and visor are put back instead of the avatar
##   frozen   the gait is stopped and every joint is zeroed
##   float    the body is lifted half a metre off the ground
##
## Env: OUT_DIR (required), MUTATION (default none), COLONIST (default probe-colonist-1)
## Writes avatar.json (none) or avatar_<mutation>.json and the shots under OUT_DIR.

const WorldModule := preload("res://game/world/world_module.gd")
const MeshRay := preload("res://engine/stalag/tests/mesh_ray.gd")
const AvatarBody := preload("res://game/avatar/avatar_body.gd")

const MUTATIONS := ["none", "hidden", "capsule", "frozen", "float"]
const SHOT_IDS := ["handoff_idle", "follow_walk_mid", "follow_run", "close_min_boom", "side_walk", "front_idle"]
const PIX_TOL := 4
const SETTLE_FRAMES := 60
const RING_TIMEOUT_S := 240.0
const SEGMENT_FRAMES := 60
const COST_MIN_CALLS := 1000
const COST_MAX_FRAMES := 3000
const OLD_CAPSULE_R := 0.27
const OLD_CAPSULE_H := 1.7

var _mutation := "none"
var _out := ""
var _colonist := "probe-colonist-1"
var _world: Node3D
var _walker: Node3D
var _cam: Camera3D
var _view: Node3D
var _ray: MeshRay
var _layout := {}
var _rest := {}  # joint name -> [rotation, position] captured from the freshly built body (the frozen control)
var _capsule: Node3D
var _vp := Vector2(1280, 720)


func _ready() -> void:
	_out = OS.get_environment("OUT_DIR")
	var m := OS.get_environment("MUTATION")
	_mutation = m if not m.is_empty() else "none"
	var c := OS.get_environment("COLONIST")
	if not c.is_empty():
		_colonist = c
	if _out.is_empty() or not (_mutation in MUTATIONS):
		push_error("avatar_probe: OUT_DIR is required and MUTATION must be one of %s" % [MUTATIONS])
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _frame() -> void:
	await get_tree().process_frame


func _frames(n: int) -> void:
	for _i in range(n):
		await _frame()


func _run() -> void:
	_ray = MeshRay.new(StalagWorld.get_chunk_m())
	_world = WorldModule.instantiate_world()
	if _world == null:
		push_error("avatar_probe: world scene unavailable")
		get_tree().quit(3)
		return
	var streamer: Node3D = _world.get_node("Streamer")
	_walker = _world.get_node("Walker")
	_cam = _world.get_node("Camera")
	_world.scripted_input = true
	_world.colonist_id = _colonist
	streamer.chunk_built.connect(func(c: Vector2i, v: PackedVector3Array) -> void: _ray.add_chunk(c, v))
	add_child(_world)
	var t0 := Time.get_ticks_msec()
	while not streamer.settled():
		await _frame()
		if (Time.get_ticks_msec() - t0) / 1000.0 > RING_TIMEOUT_S:
			push_error("avatar_probe: the streamed ring never settled")
			break
	_world.flora_clock_frozen = true
	_layout = _world.homestead_layout
	_view = _find_view(_world)
	_vp = get_viewport().get_visible_rect().size
	if _view != null and _view.body() != null:
		for k in _view.joint_nodes().keys():
			var n: Node3D = _view.joint_nodes()[k]
			_rest[k] = [n.rotation, n.position]
	await _frames(SETTLE_FRAMES)

	_apply_mutation_start()
	await _frames(3)

	var rec := {
		"generated_epoch": int(Time.get_unix_time_from_system()),
		"mutation": _mutation,
		"headless": DisplayServer.get_name() == "headless",
		"colonist_id": _colonist,
		"template_default_preset": String(AvatarBody.load_template("res://game/avatar/avatar_template.json").get("default_preset", "")),
	}
	rec["wired"] = _measure_wired()
	rec["body"] = _measure_body_idle()
	rec["ground"] = {"truth": "mesh_ray", "idle": _measure_ground_idle(), "walk": {}}
	var route := _choose_route()
	var walk := await _walk_octagon(route)
	walk["anim"]["walk"]["stride_len_m"] = await _measure_stride_line()
	rec["ground"]["walk"] = walk["ground"]
	rec["facing"] = walk["facing"]
	rec["anim"] = walk["anim"]
	rec["body"]["half_width_walk_max_m"] = walk["half_width_walk_max_m"]
	rec["anim"]["idle"] = await _measure_idle_anim()
	rec["route"] = {"centre_x": route["centre"].x, "centre_z": route["centre"].y, "clearance_m": route["clearance_m"]}
	rec["shots"] = await _take_shots(route)
	rec["articulation"] = await _measure_articulation(route)
	rec["cost"] = await _measure_cost(route)
	var fname := "avatar.json" if _mutation == "none" else "avatar_%s.json" % _mutation
	var f := FileAccess.open(_out.path_join(fname), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec, "  "))
	f.close()
	print("avatar_probe: wrote ", fname)
	get_tree().quit(0)


# ------------------------------------------------------------------ scene helpers
func _find_view(n: Node) -> Node3D:
	var s = n.get_script()
	if s is Script and String((s as Script).resource_path).ends_with("game/avatar/avatar_view.gd"):
		return n as Node3D
	for ch in n.get_children():
		var r := _find_view(ch)
		if r != null:
			return r
	return null


func _host() -> Node3D:
	return _walker.body_node()


## The avatar's body node, or null when the avatar is not in the tree (the capsule control).
func _avatar_body() -> Node3D:
	if _view == null:
		return null
	var b: Node3D = _view.body()
	return b if (b != null and b.is_inside_tree()) else null


func _meshes(n: Node, acc: Array) -> Array:
	if n is MeshInstance3D:
		acc.append(n)
	for ch in n.get_children():
		_meshes(ch, acc)
	return acc


func _count_nodes(n: Node) -> int:
	var k := 1
	for ch in n.get_children():
		k += _count_nodes(ch)
	return k


## World-space box of a node's meshes.
func _world_aabb(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in _meshes(n, []):
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## [min_x, max_x, min_y, max_y] of the body's meshes, in the body's own frame (local) or the world's.
func _extents(body: Node3D, local: bool) -> Array:
	var inv := body.global_transform.affine_inverse()
	var lo_x := INF
	var hi_x := -INF
	var lo_y := INF
	var hi_y := -INF
	for mi: MeshInstance3D in _meshes(body, []):
		var bb: AABB = mi.mesh.get_aabb()
		var xf: Transform3D = (inv * mi.global_transform) if local else mi.global_transform
		var c: Vector3 = xf * bb.get_center()
		var h: Vector3 = bb.size * 0.5
		var ex: float = absf(xf.basis.x.x) * h.x + absf(xf.basis.y.x) * h.y + absf(xf.basis.z.x) * h.z
		var ey: float = absf(xf.basis.x.y) * h.x + absf(xf.basis.y.y) * h.y + absf(xf.basis.z.y) * h.z
		lo_x = minf(lo_x, c.x - ex)
		hi_x = maxf(hi_x, c.x + ex)
		lo_y = minf(lo_y, c.y - ey)
		hi_y = maxf(hi_y, c.y + ey)
	return [lo_x, hi_x, lo_y, hi_y]


func _make_capsule() -> Node3D:
	var root := Node3D.new()
	root.name = "OldCapsule"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.35, 0.10)
	mat.roughness = 0.8
	var trunk := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = OLD_CAPSULE_R
	cap.height = OLD_CAPSULE_H
	trunk.mesh = cap
	trunk.material_override = mat
	trunk.position = Vector3(0.0, OLD_CAPSULE_H * 0.5, 0.0)
	root.add_child(trunk)
	var visor := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.36, 0.14, 0.20)
	visor.mesh = box
	var vmat := StandardMaterial3D.new()
	vmat.albedo_color = Color(0.10, 0.12, 0.18)
	visor.material_override = vmat
	visor.position = Vector3(0.0, OLD_CAPSULE_H * 0.82, -OLD_CAPSULE_R)
	root.add_child(visor)
	return root


func _put_capsule(on: bool) -> void:
	if on and _capsule == null:
		_capsule = _make_capsule()
		_host().add_child(_capsule)
	elif not on and _capsule != null:
		_host().remove_child(_capsule)
		_capsule.free()
		_capsule = null


func _zero_joints() -> void:
	if _view == null or _view.body() == null:
		return
	for k in _view.joint_nodes().keys():
		var n: Node3D = _view.joint_nodes()[k]
		n.rotation = Vector3.ZERO
		if k == "pelvis":
			n.position = _rest[k][1]


func _apply_mutation_start() -> void:
	if _mutation == "capsule":
		var b := _avatar_body()
		if b != null:
			b.get_parent().remove_child(b)
			b.free()
			_view._body = null  # the view has nothing left to pose
		_put_capsule(true)
	elif _mutation == "frozen":
		_view.set_process(false)
		_zero_joints()
	elif _mutation == "float":
		_walker.body_offset_y = 0.5


func _show_body(on: bool) -> void:
	var b := _avatar_body()
	if b != null:
		b.visible = on and _mutation != "hidden"


# ------------------------------------------------------------------ wiring and body
func _measure_wired() -> Dictionary:
	var views := 0
	for n in _all_nodes(_world, []):
		var s = n.get_script()
		if s is Script and String((s as Script).resource_path).ends_with("game/avatar/avatar_view.gd"):
			views += 1
	var host := _host()
	var caps := 0
	var old_visors := 0
	for mi: MeshInstance3D in _meshes(host, []):
		if mi.mesh is CapsuleMesh:
			caps += 1
		elif mi.mesh is BoxMesh and ((mi.mesh as BoxMesh).size - Vector3(0.36, 0.14, 0.20)).length() < 0.001:
			old_visors += 1
	var b := _avatar_body()
	return {
		"view_nodes": views,
		"attached_under_walker_body": b != null and b.get_parent() == host,
		"capsules_left": caps,
		"old_visor_boxes_left": old_visors,
		"root_yaw_rad": b.rotation.y if b != null else 0.0,
		"preset": _view.preset_id() if _view != null else "",
		"measured_from": "scene_tree",
	}


func _all_nodes(n: Node, acc: Array) -> Array:
	acc.append(n)
	for ch in n.get_children():
		_all_nodes(ch, acc)
	return acc


func _measure_body_idle() -> Dictionary:
	var b := _avatar_body()
	if b == null:
		return {"height_m": 0.0, "half_width_idle_m": 0.0, "half_width_walk_max_m": 0.0, "front_ok": false, "tris": 0, "mesh_instances": 0, "node_count": 0}
	var e := _extents(b, true)
	var tris := 0
	var ms := _meshes(b, [])
	for mi: MeshInstance3D in ms:
		tris += mi.mesh.get_faces().size() / 3
	var visor := b.find_child("visor", true, false) as Node3D
	return {
		"height_m": float(e[3]) - float(e[2]),
		"half_width_idle_m": maxf(absf(float(e[0])), absf(float(e[1]))),
		"half_width_walk_max_m": 0.0,
		"front_ok": visor != null and (b.global_transform.affine_inverse() * visor.global_position).z < -0.01,
		"tris": tris,
		"mesh_instances": ms.size(),
		"node_count": _count_nodes(b),
	}


func _ground_at(x: float, z: float, y: float) -> float:
	return _ray.height_at(x, z, y + 1.0)


func _lowest_world_y() -> float:
	var b := _avatar_body()
	if b != null:
		return float(_extents(b, false)[2])
	var e := _world_aabb(_host())
	return e.position.y


func _measure_ground_idle() -> Dictionary:
	var g := _ground_at(_walker.pos.x, _walker.pos.z, _walker.pos.y)
	return {"lowest_minus_ground_m": (_lowest_world_y() - g) if not is_nan(g) else 99.0}


# ------------------------------------------------------------------ the walk
func _joint(name: String) -> Node3D:
	if _view == null or _view.body() == null:
		return null
	return _view.joint_nodes().get(name)


## The route every walking measurement uses: an octagon of side OCT_SIDE_M on the Foundation Slab, in the
## clearest spot (farthest from the pod and the items, inside the slab). The slab is flat and cleared of
## meadow and trees, so the shots are not hidden behind foliage; seating is therefore measured on flat
## ground, where the walker has no footprint hover of its own to inherit.
const OCT_SIDE_M := 2.2
const OCT_R := 2.88  ## circumradius of an octagon with that side
const SEGMENT_S := 0.5
const WALK_FRAMES_MIN := 330
const HIP_FRAMES_MIN := 260
const TURN_SETTLE_S := 0.2  ## after a change of heading the body needs this long to have turned
const SLAB_MARGIN_M := 0.8


func _obstacles() -> Array:
	var out: Array = []
	if _layout.is_empty():
		return out
	out.append([Vector2(float(_layout["pod"]["x"]), float(_layout["pod"]["z"])), float(_layout["pod"]["footprint_r_m"])])
	for it in _layout["items"]:
		out.append([Vector2(float(it["x"]), float(it["z"])), float(it["footprint_r_m"])])
	return out


## Distance from p to the nearest obstacle's rim (negative inside one), and to the slab edge.
func _clearance(p: Vector2) -> float:
	var c := INF
	for o in _obstacles():
		c = minf(c, p.distance_to(o[0]) - float(o[1]))
	var hx := float(_layout["slab"]["half_x_m"])
	var hz := float(_layout["slab"]["half_z_m"])
	c = minf(c, minf(hx - absf(p.x), hz - absf(p.y)))
	return c


func _choose_route() -> Dictionary:
	var best := -INF
	var centre := Vector2.ZERO
	var lim := minf(float(_layout["slab"]["half_x_m"]), float(_layout["slab"]["half_z_m"])) - SLAB_MARGIN_M - OCT_R
	var steps := 8
	for ix in range(steps + 1):
		for iz in range(steps + 1):
			var c := Vector2(lerpf(-lim, lim, float(ix) / float(steps)), lerpf(-lim, lim, float(iz) / float(steps)))
			var worst := INF
			for j in range(8):
				var v0 := c + Vector2(cos(TAU * float(j) / 8.0), sin(TAU * float(j) / 8.0)) * OCT_R
				var v1 := c + Vector2(cos(TAU * float(j + 1) / 8.0), sin(TAU * float(j + 1) / 8.0)) * OCT_R
				for k in range(8):
					worst = minf(worst, _clearance(v0.lerp(v1, float(k) / 7.0)))
			if worst > best:
				best = worst
				centre = c
	return {"centre": centre, "clearance_m": best}


## The i-th vertex of the route and the heading of the edge that leaves it.
func _vertex(route: Dictionary, i: int) -> Vector2:
	var c: Vector2 = route["centre"]
	return c + Vector2(cos(TAU * float(i) / 8.0), sin(TAU * float(i) / 8.0)) * OCT_R


func _edge_dir(route: Dictionary, i: int) -> Vector2:
	return (_vertex(route, i + 1) - _vertex(route, i)).normalized()


func _stand_at(p: Vector2, face: Vector2) -> void:
	_walker.teleport(Vector3(p.x, _world._ground_at(p.x, p.y), p.y), true)
	_walker.face_direction(face)


## Walks the octagon (as many laps as it takes to collect enough frames): the walker really walks, so the
## view reads real displacement, and every frame the rig is read back from the scene tree.
func _walk_octagon(route: Dictionary) -> Dictionary:
	var samples := 0
	var within := 0
	var sink_max := 0.0
	var float_max := 0.0
	var face_err_max := 0.0
	var face_frames := 0
	var crab := 0
	var headings := 0
	var walking_frames := 0
	var hw_max := 0.0
	var hip: Array = []
	var dist: Array = []
	_stand_at(_vertex(route, 0), _edge_dir(route, 0))
	await _frames(5)
	var prev: Vector3 = _walker.pos
	var laps := 0
	while (walking_frames < WALK_FRAMES_MIN or hip.size() < HIP_FRAMES_MIN) and laps < 14:
		laps += 1
		for k in range(8):
			var dir := _edge_dir(route, k)
			_walker.input_move = dir
			_walker.input_run = false
			headings += 1
			var t_seg := 0.0
			while t_seg < SEGMENT_S:
				await _frame()
				var dt := get_process_delta_time()
				t_seg += dt
				var p: Vector3 = _walker.pos
				var d := Vector2(p.x - prev.x, p.z - prev.z)
				prev = p
				var speed := d.length() / maxf(dt, 1e-4)
				var b := _avatar_body()
				var gr := _ground_at(p.x, p.z, p.y)
				var low := _lowest_world_y()
				if not is_nan(gr):
					var diff := low - gr
					samples += 1
					if absf(diff) <= 0.08:
						within += 1
					sink_max = maxf(sink_max, maxf(0.0, -diff))
					float_max = maxf(float_max, maxf(0.0, diff))
				if b != null:
					var e := _extents(b, true)
					hw_max = maxf(hw_max, maxf(absf(float(e[0])), absf(float(e[1]))))
				if speed >= 2.5:
					walking_frames += 1
					if t_seg >= TURN_SETTLE_S:
						var fwd := -(_host().global_transform.basis.z)
						var err := absf(Vector2(fwd.x, fwd.z).angle_to(d))
						face_frames += 1
						face_err_max = maxf(face_err_max, err)
						if err > 0.5:
							crab += 1
					var leg := _joint("leg_l")
					if leg != null and speed >= 3.5 and speed <= 5.5 and t_seg >= TURN_SETTLE_S:
						hip.append(leg.rotation.x)
						dist.append(d.length())
	_walker.input_move = Vector2.ZERO
	var swing := _p2p(hip)
	return {
		"ground": {"samples": samples, "within_0p08_frac": float(within) / float(maxi(samples, 1)), "sink_max_m": sink_max, "float_max_m": float_max},
		"facing": {"headings_tested": headings, "walking_frames": walking_frames, "max_face_err_rad": face_err_max,
			"crab_frac": float(crab) / float(maxi(face_frames, 1))},
		"anim": {"measured_from": "scene_tree_joint_rotations",
			"walk": {"leg_swing_p2p_rad": swing, "stride_len_m": 0.0, "frames": hip.size()}},
		"half_width_walk_max_m": hw_max,
	}


## One straight walk across the flat slab (the walker does not collide with the homestead, only with the
## ground), long enough for several full cycles: the metres walked per cycle of the left hip.
func _measure_stride_line() -> float:
	var half := float(_layout["slab"]["half_x_m"]) - 0.4
	_stand_at(Vector2(-half, 0.0), Vector2.RIGHT)
	await _frames(5)
	_walker.input_move = Vector2.RIGHT
	_walker.input_run = false
	var hip: Array = []
	var dist: Array = []
	var prev: Vector3 = _walker.pos
	var t := 0.0
	while _walker.pos.x < half - 0.3 and t < 6.0:
		await _frame()
		var dt := get_process_delta_time()
		t += dt
		var p: Vector3 = _walker.pos
		var d := Vector2(p.x - prev.x, p.z - prev.z).length()
		prev = p
		var leg := _joint("leg_l")
		if leg != null and d / maxf(dt, 1e-4) >= 3.5 and t >= 0.4:
			hip.append(leg.rotation.x)
			dist.append(d)
	_walker.input_move = Vector2.ZERO
	return _stride(hip, dist)


## Metres per gait cycle, from rising crossings of the left hip angle through its mean.
func _stride(hip: Array, dist: Array) -> float:
	if hip.size() < 8:
		return 0.0
	var m := 0.0
	for v in hip:
		m += float(v)
	m /= float(hip.size())
	var cum := [0.0]
	for d in dist:
		cum.append(float(cum[cum.size() - 1]) + float(d))
	var first := -1
	var last := -1
	var n := 0
	for i in range(1, hip.size()):
		if float(hip[i - 1]) < m and float(hip[i]) >= m:
			if first < 0:
				first = i
			last = i
			n += 1
	if n < 2:
		return 0.0
	return (float(cum[last]) - float(cum[first])) / float(n - 1)


func _measure_idle_anim() -> Dictionary:
	_walker.input_move = Vector2.ZERO
	await _frames(45)  # the stop settles in a quarter of a second
	var hip: Array = []
	var breath: Array = []
	for _i in range(200):
		await _frame()
		var leg := _joint("leg_l")
		var torso := _joint("torso")
		if leg != null and torso != null:
			hip.append(leg.rotation.x)
			breath.append(torso.position.y)
	return {"leg_swing_p2p_rad": _p2p(hip), "breath_p2p_m": _p2p(breath), "frames": hip.size()}


static func _p2p(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in a:
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
	return hi - lo


# ------------------------------------------------------------------ captures
func _grab() -> Image:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


## Screen rectangle of a world box (edges clipped at the near plane) and whether at least half is on screen.
func _project(box: AABB) -> Dictionary:
	var inv := _cam.global_transform.affine_inverse()
	var th := tan(deg_to_rad(_cam.fov) * 0.5)
	var w := _vp.x
	var h := _vp.y
	var asp := w / h
	var near := 0.1
	var cs: Array = []
	for i in range(8):
		cs.append(inv * box.get_endpoint(i))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in range(8):
		for bit in [1, 2, 4]:
			if (i & bit) != 0:
				continue
			var p: Vector3 = cs[i]
			var q: Vector3 = cs[i | bit]
			var zp := -p.z - near
			var zq := -q.z - near
			if zp < 0.0 and zq < 0.0:
				continue
			if zp < 0.0:
				p = p + (q - p) * (-zp / (zq - zp))
			elif zq < 0.0:
				q = q + (p - q) * (-zq / (zp - zq))
			for e: Vector3 in [p, q]:
				var sx: float = w * 0.5 + (e.x / -e.z) / (th * asp) * w * 0.5
				var sy: float = h * 0.5 - (e.y / -e.z) / th * h * 0.5
				lo = Vector2(minf(lo.x, sx), minf(lo.y, sy))
				hi = Vector2(maxf(hi.x, sx), maxf(hi.y, sy))
	if lo.x == INF:
		return {"in_viewport": false, "rect": Rect2i()}
	var full := Rect2(lo, hi - lo)
	var inside := full.intersection(Rect2(Vector2.ZERO, Vector2(w, h)))
	var share := inside.get_area() / maxf(full.get_area(), 1.0)
	var pix := Rect2i(Vector2i(inside.position.floor()), Vector2i(inside.size.ceil())).intersection(Rect2i(0, 0, int(w), int(h)))
	return {"in_viewport": share >= 0.5, "rect": pix}


## Changed pixels (any channel off by more than PIX_TOL) inside rect, and the mean luma difference over them.
static func _diff_in(a: Image, b: Image, rect: Rect2i) -> Vector2:
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var n := 0
	var sum := 0.0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		var row := y * w
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var i := (row + x) * 3
			var dr: int = absi(da[i] - db[i])
			var dg: int = absi(da[i + 1] - db[i + 1])
			var dbl: int = absi(da[i + 2] - db[i + 2])
			if dr > PIX_TOL or dg > PIX_TOL or dbl > PIX_TOL:
				n += 1
				sum += absf(0.2126 * float(da[i] - db[i]) + 0.7152 * float(da[i + 1] - db[i + 1]) + 0.0722 * float(da[i + 2] - db[i + 2])) / 255.0
	return Vector2(float(n), sum / float(maxi(n, 1)))


func _freeze(on: bool) -> void:
	_walker.set_process(not on)
	_cam.set_process(not on)
	if _view != null and _mutation != "frozen":
		_view.set_process(not on)


## Measures the body now, with the world frozen: avatar shown vs hidden, avatar vs the old capsule, and the
## visor and vitals parts. Returns the shown image through rec["_img"].
func _judge(id: String) -> Dictionary:
	_freeze(true)
	_show_body(true)
	var b := _avatar_body()
	var rec := {"id": id, "file": "", "in_viewport": false, "changed_px": 0, "rect_px": 0, "fill_ratio": 0.0, "ring_contrast": 0.0,
		"vs_capsule_diff_frac": 0.0, "parts": {"visor_changed_px": 0, "vitals_changed_px": 0}}
	var a := await _grab()
	var rect_a := Rect2i()
	if b != null:
		var proj := _project(_world_aabb(b))
		rect_a = proj["rect"]
		rec["in_viewport"] = proj["in_viewport"]
		b.visible = false
		var hid := await _grab()
		_show_body(true)
		if rect_a.size.x > 0 and rect_a.size.y > 0:
			var st := _diff_in(a, hid, rect_a)
			rec["changed_px"] = int(st.x)
			rec["rect_px"] = rect_a.get_area()
			rec["fill_ratio"] = st.x / float(maxi(rect_a.get_area(), 1))
			rec["ring_contrast"] = st.y
		for part in ["visor", "vitals"]:
			var pn := b.find_child(part, true, false) as Node3D
			if pn != null and b.visible:
				var pr := _project(_world_aabb(pn))
				var was := pn.visible
				pn.visible = false
				var img2 := await _grab()
				pn.visible = was
				if pr["rect"].size.x > 0 and pr["rect"].size.y > 0:
					rec["parts"][part + "_changed_px"] = int(_diff_in(a, img2, pr["rect"]).x)
		# The same frame with the old capsule drawn in the body's place.
		b.visible = false
		_put_capsule(true)
		var capimg := await _grab()
		var cproj := _project(_world_aabb(_capsule))
		_put_capsule(false)
		_show_body(true)
		var uni: Rect2i = rect_a.merge(cproj["rect"])
		rec["vs_capsule_diff_frac"] = _diff_in(a, capimg, uni).x / float(maxi(uni.get_area(), 1))
	else:
		# The capsule control: the frame IS the capsule, so it is compared with a second capture of itself.
		var cproj2 := _project(_world_aabb(_capsule))
		var again := await _grab()
		var uni2: Rect2i = cproj2["rect"]
		rec["in_viewport"] = cproj2["in_viewport"]
		rec["vs_capsule_diff_frac"] = _diff_in(a, again, uni2).x / float(maxi(uni2.get_area(), 1))
	rec["_img"] = a
	_freeze(false)
	return rec


## Puts the camera on the side of the walker that the direction points to (a unit vector on the ground), at
## this boom, through the real follow camera.
func _cam_toward(dir_xz: Vector2, dist: float) -> void:
	_cam.yaw = atan2(dir_xz.x, dir_xz.y)
	_cam.pitch = 0.40
	_cam.dist = dist
	_cam.target = _walker
	_cam.follow(_walker.pos)


func _face_xz() -> Vector2:
	var fwd := -(_host().global_transform.basis.z)
	return Vector2(fwd.x, fwd.z).normalized()


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await _frame()
		t += get_process_delta_time()


## Of eight compass directions (the walker's own, unit vectors), the one whose camera spot at this boom
## has the most room around it. `perp_of` (a unit vector) restricts the choice to its two perpendiculars.
func _freest_dir(at: Vector2, dist: float, perp_of: Vector2 = Vector2.ZERO) -> Vector2:
	var best := -INF
	var pick := Vector2.RIGHT
	var ground_reach := dist * cos(0.40)
	for k in range(8):
		var d := Vector2(cos(TAU * float(k) / 8.0), sin(TAU * float(k) / 8.0))
		if perp_of != Vector2.ZERO and absf(d.dot(perp_of)) > 0.3:
			continue
		# The whole sight line from the body to the camera, and a little past it, must be clear.
		var room := INF
		for step in range(1, 7):
			room = minf(room, _clearance(at + d * ground_reach * float(step) / 5.0))
		if room > best:
			best = room
			pick = d
	return pick


## The edge of the route whose camera spot is the freest once the walker has walked `travel` metres along it,
## with the camera behind it (kind "behind") or beside it (kind "side"). Returns {edge, cam_dir}.
func _best_edge(route: Dictionary, kind: String, dist: float, travel: float) -> Dictionary:
	var best := -INF
	var pick := {"edge": 0, "cam_dir": -_edge_dir(route, 0)}
	var reach := dist * cos(0.40)
	for k in range(8):
		var d := _edge_dir(route, k)
		var at := _vertex(route, k) + d * travel
		var dirs: Array = [-d] if kind == "behind" else [Vector2(-d.y, d.x), Vector2(d.y, -d.x)]
		for cd in dirs:
			var room := INF
			for step in range(0, 7):
				room = minf(room, _clearance(at + cd * reach * float(step) / 5.0))
			if room > best:
				best = room
				pick = {"edge": k, "cam_dir": cd}
	return pick


func _take_shots(route: Dictionary) -> Array:
	var results: Array = []
	var dir_a := float(_layout["handoff"]["dir_angle"])

	# 1 hand-off, idle: the camera exactly as the world left it for the player's arrival.
	var hx := float(_layout["handoff"]["x"])
	var hz := float(_layout["handoff"]["z"])
	_stand_at(Vector2(hx, hz), Vector2(cos(dir_a), sin(dir_a)))
	_cam.yaw = float(_layout["handoff"]["yaw"]) + deg_to_rad(float(_world.HANDOFF_CAM_YAW_DEG))
	_cam.dist = float(_world.HANDOFF_BOOM_M)
	_cam.pitch = 0.40
	_cam.target = _walker
	await _wait(0.8)
	results.append(await _judge("handoff_idle"))

	# 2 walking and 3 running along the route, the follow camera behind.
	var w2 := _best_edge(route, "behind", 5.0, 1.6)
	var d0 := _edge_dir(route, int(w2["edge"]))
	_stand_at(_vertex(route, int(w2["edge"])), d0)
	_walker.input_move = d0
	_walker.input_run = false
	_cam_toward(w2["cam_dir"], 5.0)
	await _wait(0.4)
	results.append(await _judge("follow_walk_mid"))
	var w3 := _best_edge(route, "behind", 5.0, 2.2)
	var d2 := _edge_dir(route, int(w3["edge"]))
	_stand_at(_vertex(route, int(w3["edge"])), d2)
	_walker.input_move = d2
	_walker.input_run = true
	_cam_toward(w3["cam_dir"], 5.0)
	await _wait(0.5)
	results.append(await _judge("follow_run"))
	_walker.input_run = false

	# 4 idle in the clearest spot, the camera in front at the closest boom the follow camera allows.
	var c: Vector2 = route["centre"]
	_walker.input_move = Vector2.ZERO
	var f4 := _freest_dir(c, float(_cam.MIN_DIST))
	_stand_at(c, f4)
	_cam_toward(f4, float(_cam.MIN_DIST))
	await _wait(0.8)
	results.append(await _judge("close_min_boom"))

	# 5 walking, seen from the side (the freer of the two sides, on the edge with the most room).
	var w5 := _best_edge(route, "side", 3.5, 1.6)
	var d4 := _edge_dir(route, int(w5["edge"]))
	_stand_at(_vertex(route, int(w5["edge"])), d4)
	_walker.input_move = d4
	_cam_toward(w5["cam_dir"], 3.5)
	await _wait(0.4)
	results.append(await _judge("side_walk"))
	_walker.input_move = Vector2.ZERO

	# 6 standing, seen from the front.
	var f6 := _freest_dir(c, 3.5)
	_stand_at(c, f6)
	_cam_toward(f6, 3.5)
	await _wait(0.8)
	results.append(await _judge("front_idle"))

	var shot_dir := _out.path_join("shots" if _mutation == "none" else "shots_" + _mutation)
	DirAccess.make_dir_recursive_absolute(shot_dir)
	for i in range(results.size()):
		var img: Image = results[i]["_img"]
		results[i].erase("_img")
		var path := shot_dir.path_join("%d_%s.png" % [i + 1, SHOT_IDS[i]])
		img.save_png(path)
		results[i]["file"] = path
	return results


## Three held phases of the stride seen from the side, the world frozen: the pixels that change between
## them, as a share of the body's rectangle.
func _measure_articulation(route: Dictionary) -> Dictionary:
	_walker.input_move = Vector2.ZERO
	_walker.input_run = false
	var c: Vector2 = route["centre"]
	var face := _freest_dir(c, 3.5)
	_stand_at(c, face)
	_cam_toward(_freest_dir(c, 3.5, face), 3.5)
	await _wait(0.8)
	_freeze(true)
	_show_body(true)
	var imgs: Array = []
	var rects: Array = []
	var phases := [0, 0.25, 0.5]
	var b := _avatar_body()
	for ph in phases:
		if _view != null and b != null:
			_view.hold_pose(float(ph), true)
			if _mutation == "frozen":
				_zero_joints()
		imgs.append(await _grab())
		rects.append(_project(_world_aabb(b))["rect"] if b != null else Rect2i())
	var uni: Rect2i = rects[0]
	for rc in rects:
		uni = uni.merge(rc)
	# The body's own pixels: what changes in that rectangle when only the body is hidden.
	var body_px := 0.0
	if b != null and uni.get_area() > 0:
		var shown_vis := b.visible
		b.visible = false
		var hid := await _grab()
		b.visible = shown_vis
		body_px = _diff_in(imgs[0], hid, uni).x
	var pairs: Array = []
	var worst := INF
	for pr in [[0, 1], [0, 2], [1, 2]]:
		var frac := _diff_in(imgs[pr[0]], imgs[pr[1]], uni).x / maxf(body_px, 1.0) if uni.get_area() > 0 else 0.0
		pairs.append({"a": phases[pr[0]], "b": phases[pr[1]], "diff_frac": frac})
		worst = minf(worst, frac)
	if _view != null:
		_view.release_pose()
	_freeze(false)
	return {"phases": phases, "phase_diff_frac": worst, "pairs": pairs, "body_px": body_px, "pose_source": "hold_pose"}


func _rid_set(b: Node3D) -> Dictionary:
	var s := {}
	for mi: MeshInstance3D in _meshes(b, []):
		s[mi.mesh.get_instance_id()] = true
		if mi.material_override != null:
			s[mi.material_override.get_instance_id()] = true
	return s


func _measure_cost(route: Dictionary) -> Dictionary:
	var b := _avatar_body()
	var nodes0 := _count_nodes(b) if b != null else 0
	var res0 := _rid_set(b) if b != null else {}
	# Run the walk until the view has been timed for enough frames (bounded, so a disabled view cannot hang the probe).
	var spent := 0
	var k := 0
	_stand_at(_vertex(route, 0), _edge_dir(route, 0))
	# A control whose view is switched off (frozen) or has no body (capsule) is never timed, so it must not wait for samples.
	var timed: bool = _view != null and _view.body() != null and _view.is_processing()
	while timed and spent < COST_MAX_FRAMES and int(_view.stats()["calls"]) < COST_MIN_CALLS:
		_walker.input_move = _edge_dir(route, k % 8)
		_walker.input_run = (k % 3) == 2
		var t_seg := 0.0
		while t_seg < SEGMENT_S:
			await _frame()
			t_seg += get_process_delta_time()
			spent += 1
		k += 1
	_walker.input_move = Vector2.ZERO
	_walker.input_run = false
	await _frames(45)
	var st: Dictionary = _view.stats() if _view != null else {"calls": 0, "mean_us": 0.0, "p95_us": 0.0, "max_us": 0.0}
	var b2 := _avatar_body()
	var nodes1 := _count_nodes(b2) if b2 != null else 0
	var res1 := _rid_set(b2) if b2 != null else {}
	# The same frozen frame with the body shown and then hidden: what the body adds to the renderer's work.
	_freeze(true)
	_show_body(true)
	await _grab()
	await _grab()
	var calls_on := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var prims_on := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	if b2 != null:
		b2.visible = false
	await _grab()
	await _grab()
	var calls_off := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var prims_off := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	_show_body(true)
	_freeze(false)
	var tris := 0
	var meshes := 0
	if b2 != null:
		for mi: MeshInstance3D in _meshes(b2, []):
			tris += mi.mesh.get_faces().size() / 3
			meshes += 1
	return {
		"update_us": {"calls": int(st["calls"]), "mean": float(st["mean_us"]), "p95": float(st["p95_us"]), "max": float(st["max_us"])},
		"subtree_nodes_stable": nodes0 == nodes1,
		"resources_stable": res0.keys() == res1.keys(),
		"tris": tris,
		"mesh_instances": meshes,
		"draw_calls_added": int(calls_on) - int(calls_off),
		"prims_added": int(prims_on) - int(prims_off),
		"ab": "same_frozen_frame_shown_vs_hidden",
	}
