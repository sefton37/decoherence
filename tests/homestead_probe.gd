extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 576 S1 render probe: boots the REAL world scene (streamer, walker, follow camera, the
## homestead) on a real renderer and MEASURES. It never judges: the DoD's jq does.
## Measurements are taken in the observer's frame wherever the claim is visual:
##   - the player's entry pose is read from the live walker and camera;
##   - every built object is measured from the scene tree and compared with the generator's layout;
##   - the slab is compared against the rendered chunk triangles (independent down-rays) AND the
##     engine query; flora is counted from the MultiMesh instances the renderer holds;
##   - each shot's subject is judged by a hide-one-subject differential: the pixels inside its
##     projected rectangle that change when only that subject is hidden (per-channel tolerance 4,
##     wind clock frozen). A subject occluded, off screen or never drawn scores zero.
## MUTATION=hidden hides the whole homestead before every capture; the same predicates must FAIL.
##
## Env: OUT_DIR (required), MUTATION (none | hidden), COLONIST (default probe-colonist-1)
## Writes site.json (or site_hidden.json), the stills, and contact_sheet.png (none only).

const WorldModule := preload("res://game/world/world_module.gd")
const MeshRay := preload("res://engine/stalag/tests/mesh_ray.gd")
const HomesteadSite := preload("res://game/homestead/homestead_site.gd")
const HomesteadView := preload("res://game/homestead/homestead_view.gd")

const SHOT_W := 1280
const SHOT_H := 720
const PIX_TOL := 4
const SETTLE_FRAMES := 60
const RING_TIMEOUT_S := 240.0
const SHOT_IDS := ["aerial", "slab_oblique", "pod_door", "equipment", "handoff_pov", "approach"]
const APPROACH_FOV_DEG := 30.0
const LATTICE := 2  ## whole-frame statistics read every second pixel in each direction
const CELL := 0.5

var _mutation := "none"
var _out := ""
var _colonist := "probe-colonist-1"
var _world: Node3D
var _streamer: Node3D
var _walker: Node3D
var _cam: Camera3D
var _ray: MeshRay
var _layout := {}
var _tpl := {}
var _eq := {}
var _top := 0.0
var _hs: Node3D
var _entry_yaw := 0.0
var _entry_pitch := 0.0


func _ready() -> void:
	_out = OS.get_environment("OUT_DIR")
	var m := OS.get_environment("MUTATION")
	_mutation = m if not m.is_empty() else "none"
	var c := OS.get_environment("COLONIST")
	if not c.is_empty():
		_colonist = c
	if _out.is_empty() or not (_mutation == "none" or _mutation == "hidden"):
		push_error("homestead_probe: OUT_DIR is required and MUTATION must be none or hidden")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _frame() -> void:
	await get_tree().process_frame


func _flat(_x: float, _z: float) -> float:
	return 0.0


func _run() -> void:
	_ray = MeshRay.new(StalagWorld.get_chunk_m())
	_world = WorldModule.instantiate_world()
	if _world == null:
		push_error("homestead_probe: world scene unavailable")
		get_tree().quit(3)
		return
	_streamer = _world.get_node("Streamer")
	_walker = _world.get_node("Walker")
	_cam = _world.get_node("Camera")
	_world.scripted_input = true
	_world.colonist_id = _colonist
	_streamer.chunk_built.connect(func(c: Vector2i, v: PackedVector3Array) -> void: _ray.add_chunk(c, v))
	add_child(_world)
	var t0 := Time.get_ticks_msec()
	while not _streamer.settled():
		await _frame()
		if (Time.get_ticks_msec() - t0) / 1000.0 > RING_TIMEOUT_S:
			push_error("homestead_probe: the streamed ring never settled")
			break
	_world.flora_clock_frozen = true
	_layout = _world.homestead_layout
	_tpl = _world.homestead_template
	_eq = _world.homestead_equipment
	_hs = _world.homestead
	if _layout.is_empty() or _hs == null:
		push_error("homestead_probe: the world built no homestead")
		get_tree().quit(4)
		return
	_top = float(_layout["slab"]["y"])

	var rec := {
		"mutation": _mutation,
		"headless": DisplayServer.get_name() == "headless",
		"colonist_id": _colonist,
		"site_seed": HomesteadSite.site_seed_for(_colonist),
		"layout_digest": HomesteadSite.layout_digest(_layout),
		"slab": {"half_x_m": _layout["slab"]["half_x_m"], "half_z_m": _layout["slab"]["half_z_m"]},
	}
	var fresh_tpl := HomesteadSite.load_json("res://game/homestead/data/site_template.json")
	var fresh_eq := HomesteadSite.load_json("res://game/homestead/data/starter_equipment.json")
	var again := HomesteadSite.generate(HomesteadSite.site_seed_for(_colonist), fresh_tpl, fresh_eq, _flat)
	rec["unit_digest_for_colonist"] = HomesteadSite.layout_digest(again) if not again.is_empty() else "NO_LAYOUT"

	rec["entry"] = await _measure_entry()
	_entry_yaw = _cam.yaw
	_entry_pitch = _cam.pitch
	rec["handoff_camera"] = await _measure_handoff_camera()
	rec["view"] = _measure_view()
	rec["terrain"] = _measure_terrain()
	rec["flora"] = _measure_flora()
	rec["pad"] = _measure_pad()
	print("homestead_probe: structure measured, taking shots")
	var shots := await _take_shots(rec)
	rec["shots"] = shots

	var fname := "site.json" if _mutation == "none" else "site_hidden.json"
	var f := FileAccess.open(_out.path_join(fname), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec, "  "))
	f.close()
	print("homestead_probe: wrote ", fname)
	get_tree().quit(0)


# ------------------------------------------------------------------ entry
func _measure_entry() -> Dictionary:
	var hand: Dictionary = _layout["handoff"]
	var settled := 0
	for _i in range(SETTLE_FRAMES):
		await _frame()
		var d := Vector2(_walker.pos.x - float(hand["x"]), _walker.pos.z - float(hand["z"])).length()
		if _walker.on_ground and d <= 0.05:
			settled += 1
		else:
			settled = 0
	var gx: float = _walker.pos.x
	var gz: float = _walker.pos.z
	var g := _ray.height_at(gx, gz, _walker.pos.y + 1.0)
	var hx := float(_layout["slab"]["half_x_m"])
	var hz := float(_layout["slab"]["half_z_m"])
	return {
		"walker": {"grounded": bool(_walker.on_ground), "x": gx, "y": _walker.pos.y, "z": gz},
		"pos_err_m": Vector2(gx - float(hand["x"]), gz - float(hand["z"])).length(),
		"yaw_err_rad": absf(angle_difference(float(hand["yaw"]), _walker.body_node().rotation.y)),
		"camera_yaw_offset_rad": angle_difference(float(hand["yaw"]), _cam.yaw),
		"feet_above_ground_m": (_walker.pos.y - g) if not is_nan(g) else 99.0,
		"settled_frames": settled,
		"handoff_on_slab": absf(float(hand["x"])) <= hx and absf(float(hand["z"])) <= hz,
	}


# ------------------------------------------------------------------ the entry camera against the pod (Spec 576 A2)
## How many of the top 200 rows of the frame are flat: nearly uniform across (per-channel range <= 35/255, so a
## dithered flat surface still counts). A frame of trees and sky has none; a camera pressed against a plain
## wall has most of them.
const BAND_ROWS := 200
const BAND_RANGE := 35


static func _top_band_rows(img: Image) -> int:
	var d := img.get_data()
	var w := img.get_width()
	var n := 0
	for y in range(BAND_ROWS):
		var lo := [255, 255, 255]
		var hi := [0, 0, 0]
		for x in range(0, w, LATTICE):
			var i := (y * w + x) * 3
			for c in range(3):
				lo[c] = mini(lo[c], d[i + c])
				hi[c] = maxi(hi[c], d[i + c])
		if hi[0] - lo[0] <= BAND_RANGE and hi[1] - lo[1] <= BAND_RANGE and hi[2] - lo[2] <= BAND_RANGE:
			n += 1
	return n


## Where a camera position stands against the pod's volume (a cylinder of the skirt's radius, up to the roof top):
## {inside, clearance}. Clearance is the distance to that volume, 0 inside it.
func _pod_clearance(c: Vector3) -> Dictionary:
	var pod: Node3D = _hs.get_node("Pod")
	var rs := float(_layout["pod"]["footprint_r_m"]) * HomesteadView.SKIRT_RATIO
	var bottom := pod.global_position.y
	var top := bottom + float(_layout["pod"]["height_m"])
	var dh := maxf(Vector2(c.x - pod.global_position.x, c.z - pod.global_position.z).length() - rs, 0.0)
	var dy := maxf(maxf(c.y - top, bottom - c.y), 0.0)
	return {"inside": dh == 0.0 and dy == 0.0, "clearance": sqrt(dh * dh + dy * dy)}


func _measure_handoff_camera() -> Dictionary:
	_show_homestead(true)
	var cam_at := _cam.global_position
	var frame := await _grab()
	frame.save_png(_out.path_join("entry_frame.png" if _mutation == "none" else "entry_frame_hidden.png"))
	var here := _pod_clearance(cam_at)
	var rows := _top_band_rows(frame)
	# Negative control: a camera forced into the pod, close to its back wall (what the defective pose, straight
	# behind the colonist, ended up looking at); the same detectors must fire on it.
	var pod: Node3D = _hs.get_node("Pod")
	var dir_a := float(_layout["handoff"]["dir_angle"])
	var back := Vector3(cos(dir_a), 0.0, sin(dir_a))
	var in_roof := pod.global_position - back * 0.75 + Vector3(0.0, 1.6, 0.0)
	_cam.target = null
	_cam.global_position = in_roof
	_cam.look_at(in_roof - back, Vector3.UP)
	var bad_frame := await _grab()
	bad_frame.save_png(_out.path_join("entry_negctl.png" if _mutation == "none" else "entry_negctl_hidden.png"))
	var bad := _pod_clearance(in_roof)
	var bad_rows := _top_band_rows(bad_frame)
	_cam.target = _walker
	_cam.yaw = _entry_yaw
	_cam.pitch = _entry_pitch
	_cam.follow(_walker.pos)
	await _frame()
	return {
		"camera": [cam_at.x, cam_at.y, cam_at.z],
		"inside_pod_volume": here["inside"], "min_clearance_to_pod_m": here["clearance"],
		"top_band_uniform_rows": rows,
		"negctl_inside": bad["inside"], "negctl_top_band_rows": bad_rows,
		"negctl_camera_in_roof_detected": bool(bad["inside"]) and bad_rows >= 20,
		"frame": _out.path_join("entry_frame.png" if _mutation == "none" else "entry_frame_hidden.png"),
	}


# ------------------------------------------------------------------ view (scene tree)
static func _reach_of(mi: MeshInstance3D) -> float:
	# Farthest horizontal reach of one part from the item's origin (parts carry no rotation).
	var p := mi.position
	if mi.mesh is BoxMesh:
		var s: Vector3 = (mi.mesh as BoxMesh).size
		return sqrt(pow(absf(p.x) + s.x * 0.5, 2.0) + pow(absf(p.z) + s.z * 0.5, 2.0))
	if mi.mesh is CylinderMesh:
		return Vector2(p.x, p.z).length() + (mi.mesh as CylinderMesh).bottom_radius
	if mi.mesh is SphereMesh:
		return Vector2(p.x, p.z).length() + (mi.mesh as SphereMesh).radius
	return 99.0


## First hit distance of a ray against every mesh box under `root` (AABB in each mesh's own frame,
## exact for the box meshes the walls and door are), or INF.
static func _ray_hit(root: Node3D, from: Vector3, to: Vector3) -> float:
	var dir := to - from
	var len := dir.length()
	dir = dir / len
	var best := INF
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var inv := mi.global_transform.affine_inverse()
		var o := inv * from
		var d := inv.basis * dir
		var box := mi.get_aabb()
		var t_near := 0.0
		var t_far := len
		var hit := true
		for ax in range(3):
			var lo: float = box.position[ax]
			var hi: float = box.position[ax] + box.size[ax]
			if absf(d[ax]) < 1e-9:
				if o[ax] < lo or o[ax] > hi:
					hit = false
					break
			else:
				var t1: float = (lo - o[ax]) / d[ax]
				var t2: float = (hi - o[ax]) / d[ax]
				t_near = maxf(t_near, minf(t1, t2))
				t_far = minf(t_far, maxf(t1, t2))
				if t_near > t_far:
					hit = false
					break
		if hit and t_near < best:
			best = t_near
	return best


func _measure_view() -> Dictionary:
	var v := {"measured_from": "scene_tree"}
	var slab_n := 0
	var pod_n := 0
	var slab_node: MeshInstance3D = null
	var pod_node: Node3D = null
	for c in _hs.get_children():
		if c.name == "Slab":
			slab_n += 1
			slab_node = c
		elif c.name == "Pod":
			pod_n += 1
			pod_node = c
	var rings: Node = _hs.get_node("Rings")
	var items: Node = _hs.get_node("Items")
	v["slab"] = slab_n
	v["pod"] = pod_n
	v["rings"] = rings.get_child_count()
	v["items"] = items.get_child_count()
	var top := slab_node.global_position.y + (slab_node.mesh as BoxMesh).size.y * 0.5
	v["slab_top_y"] = top

	var max_err := 0.0
	var all_match := true
	var ring_list: Array = _layout["rings"]
	for i in range(ring_list.size()):
		var rn: Node3D = rings.get_node_or_null("Ring_%d" % i)
		if rn == null:
			all_match = false
			continue
		max_err = maxf(max_err, Vector2(rn.global_position.x - float(ring_list[i]["x"]), rn.global_position.z - float(ring_list[i]["z"])).length())
	max_err = maxf(max_err, Vector2(pod_node.global_position.x - float(_layout["pod"]["x"]), pod_node.global_position.z - float(_layout["pod"]["z"])).length())
	var aabb_ok := true
	var seat_gap := 0.0
	var buried := 0.0
	var hx := float(_layout["slab"]["half_x_m"])
	var hz := float(_layout["slab"]["half_z_m"])
	for it in _layout["items"]:
		var n: Node3D = items.get_node_or_null("Item_" + String(it["id"]))
		if n == null:
			all_match = false
			aabb_ok = false
			continue
		max_err = maxf(max_err, Vector2(n.global_position.x - float(it["x"]), n.global_position.z - float(it["z"])).length())
		var reach := 0.0
		for p in n.get_children():
			reach = maxf(reach, _reach_of(p as MeshInstance3D))
		var r := float(it["footprint_r_m"])
		if reach > r + 0.02:
			aabb_ok = false
		if absf(n.global_position.x) + r > hx or absf(n.global_position.z) + r > hz:
			aabb_ok = false
		var box := HomesteadView.world_aabb(n)
		seat_gap = maxf(seat_gap, box.position.y - top)
		buried = maxf(buried, top - box.position.y)
	v["positions_match_layout"] = all_match
	v["max_position_err_m"] = max_err
	v["items_aabb_ok"] = aabb_ok
	v["items_seated_max_gap_m"] = seat_gap
	v["items_buried_max_m"] = buried

	# Pod: door open by angle, clear ray through the doorway, back wall blocks the opposite ray.
	var door: Node3D = pod_node.get_node("DoorPanel")
	var closed_dir := Vector3(0.0, 0.0, -1.0)
	var open_dir := door.transform.basis * closed_dir
	var door_deg := rad_to_deg(acos(clampf(closed_dir.dot(open_dir), -1.0, 1.0)))
	v["pod_door_open_deg"] = door_deg
	v["pod_door_open"] = door_deg >= 45.0
	var out_dir := pod_node.global_transform.basis * Vector3(1.0, 0.0, 0.0)
	var centre := pod_node.global_position
	var r_pod := float(_layout["pod"]["footprint_r_m"])
	var clear := true
	var blocked_back := true
	for h in [0.5, 1.0, 1.5, 1.9]:
		var c3 := centre + Vector3(0.0, h, 0.0)
		if _ray_hit(pod_node, c3 + out_dir * (r_pod + 2.5), c3) != INF:
			clear = false
		if _ray_hit(pod_node, c3, c3 - out_dir * (r_pod + 2.5)) == INF:
			blocked_back = false
	v["pod_door_clear_ray"] = clear
	v["pod_back_wall_blocks_ray"] = blocked_back
	v["pod_height_m"] = HomesteadView.world_aabb(pod_node).size.y
	return v


# ------------------------------------------------------------------ terrain: slab against mesh and query
func _measure_terrain() -> Dictionary:
	var hx := float(_layout["slab"]["half_x_m"])
	var hz := float(_layout["slab"]["half_z_m"])
	var n := 21
	var top_minus := -INF
	var ground_minus := -INF
	var q_top_minus := -INF
	var q_ground_minus := -INF
	var delta := 0.0
	var samples := 0
	var missing := 0
	for i in range(n):
		for j in range(n):
			var x := -hx + 2.0 * hx * float(i) / float(n - 1)
			var z := -hz + 2.0 * hz * float(j) / float(n - 1)
			var gm := _ray.height_at(x, z, 1000.0)
			var gq: float = StalagWorld.ground_envelope_at(x, z, INF)
			if is_nan(gm) or gq == -INF:
				missing += 1
				continue
			samples += 1
			top_minus = maxf(top_minus, _top - gm)
			ground_minus = maxf(ground_minus, gm - _top)
			q_top_minus = maxf(q_top_minus, _top - gq)
			q_ground_minus = maxf(q_ground_minus, gq - _top)
			delta = maxf(delta, absf(gm - gq))
	return {
		"truth": "mesh_ray", "samples": samples, "missing": missing,
		"top_minus_ground_max_m": top_minus, "ground_minus_top_max_m": ground_minus,
		"engine_query_top_minus_ground_max_m": q_top_minus, "engine_query_ground_minus_top_max_m": q_ground_minus,
		"mesh_vs_engine_max_delta_m": delta,
	}


# ------------------------------------------------------------------ flora: instances the renderer holds
func _instances(root_name: String, keep: Callable) -> Array:
	var out: Array = []
	for c in _streamer.chunk_coords():
		var mi: MeshInstance3D = _streamer.chunk_node(c)
		var root: Node = mi.get_node_or_null(root_name)
		if root == null:
			continue
		for n in root.get_children():
			var m := n as MultiMeshInstance3D
			if m == null or not keep.call(String(m.name)):
				continue
			var mm := m.multimesh
			for i in range(mm.instance_count):
				var o := mm.get_instance_transform(i).origin
				out.append(Vector2(mi.position.x + o.x, mi.position.z + o.z))
	return out


static func _count_in(points: Array, cx: float, cz: float, hx: float, hz: float) -> int:
	var n := 0
	for p in points:
		if absf(p.x - cx) <= hx and absf(p.y - cz) <= hz:
			n += 1
	return n


func _measure_flora() -> Dictionary:
	var margin := float(_tpl["pad_margin_m"])
	var hx := float(_layout["slab"]["half_x_m"]) + margin
	var hz := float(_layout["slab"]["half_z_m"]) + margin
	var meadow := _instances("Flora", func(_n: String) -> bool: return true)
	var trees := _instances("Trees", func(n: String) -> bool: return n.ends_with("_trunk"))
	var under := _instances("Understory", func(_n: String) -> bool: return true)
	var area := 4.0 * hx * hz
	# Control: the same-size square, at the first fixed offset that holds plenty of meadow.
	var ctl_meadow := 0
	var ctl_at := [0.0, 0.0]
	for off in [Vector2(20, 0), Vector2(-20, 0), Vector2(0, 20), Vector2(0, -20), Vector2(30, 30), Vector2(-30, 30), Vector2(30, -30), Vector2(-30, -30)]:
		var cnt := _count_in(meadow, off.x, off.y, hx, hz)
		if cnt >= 50:
			ctl_meadow = cnt
			ctl_at = [off.x, off.y]
			break
		ctl_meadow = maxi(ctl_meadow, cnt)
	return {
		"margin_m": margin,
		"footprint": {"area_m2": area, "meadow": _count_in(meadow, 0.0, 0.0, hx, hz),
			"trees": _count_in(trees, 0.0, 0.0, hx, hz), "understory": _count_in(under, 0.0, 0.0, hx, hz)},
		"control": {"same_area_m2": area, "meadow": ctl_meadow, "at": ctl_at},
		"chunks_scanned": _streamer.chunk_coords().size(),
		"totals": {"meadow": meadow.size(), "trees": trees.size(), "understory": under.size()},
	}


# ------------------------------------------------------------------ pad (Spec 576 A1)
static func _h(x: float, z: float) -> float:
	return StalagWorld.ground_envelope_at(x, z, INF)


## Height spread over a square of half-width `half` centred at (cx, cz), sampled at cell centres.
static func _spread(cx: float, cz: float, half: float) -> Dictionary:
	var steps := int(ceil(2.0 * half / CELL))
	var lo := INF
	var hi := -INF
	var wet := 0
	for i in range(steps):
		for j in range(steps):
			var x := cx - half + (float(i) + 0.5) * (2.0 * half / float(steps))
			var z := cz - half + (float(j) + 0.5) * (2.0 * half / float(steps))
			var h := _h(x, z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			var gx := int(floor(x / CELL))
			var gz := int(floor(z / CELL))
			if StalagWorld.is_flooded(gx, gz) or StalagWorld.is_river_column(gx, gz):
				wet += 1
	return {"samples": steps * steps, "spread": hi - lo, "wet": wet}


## Terrain column height (m) of 0.5 m column (gx, gz): the engine's terraced surface at the column centre.
static func _col_h(gx: int, gz: int) -> float:
	return floor(StalagWorld.surface_height(4.0 * gx + 2.0, 4.0 * gz + 2.0) / 4.0) * 4.0 * 0.125


## Largest height difference between neighbouring columns over the square of half-width `reach` metres.
static func _col_step(reach: float) -> float:
	var n := int(round(reach / CELL))
	var worst := 0.0
	for gz in range(-n, n):
		for gx in range(-n, n):
			if gx + 1 < n:
				worst = maxf(worst, absf(_col_h(gx + 1, gz) - _col_h(gx, gz)))
			if gz + 1 < n:
				worst = maxf(worst, absf(_col_h(gx, gz + 1) - _col_h(gx, gz)))
	return worst


func _measure_pad() -> Dictionary:
	var need := maxf(float(_layout["slab"]["half_x_m"]), float(_layout["slab"]["half_z_m"])) + float(_tpl["pad_margin_m"])
	var blend := float(_tpl["pad_blend_m"])
	var s := _spread(0.0, 0.0, need)
	# The flat square the terrain really holds: grow in cell steps while every cell stays level.
	var h0 := _h(CELL * 0.5, CELL * 0.5)
	var half := 0.0
	while half < 12.0:
		var k := half + CELL
		var level := true
		for i in range(int(round(2.0 * k / CELL))):
			var t := -k + (float(i) + 0.5) * CELL
			for fixed in [-k + CELL * 0.5, k - CELL * 0.5]:
				if absf(_h(t, fixed) - h0) > 0.01 or absf(_h(fixed, t) - h0) > 0.01:
					level = false
		if not level:
			break
		half = k
	# Steps between neighbouring cells across the pad and its blend band, then over the whole window the
	# engine levels (pad plus blend): every 0.5 m neighbour pair, by the engine query.
	var engine_half: float = StalagWorld.pad_half_m()
	var engine_blend: float = StalagWorld.pad_blend_m()
	var reach := half + blend
	var cells := int(2.0 * reach / CELL)
	var max_step := 0.0
	for i in range(cells):
		for j in range(cells):
			var x := -reach + (float(i) + 0.5) * CELL
			var z := -reach + (float(j) + 0.5) * CELL
			if i + 1 < cells:
				max_step = maxf(max_step, absf(_h(x + CELL, z) - _h(x, z)))
			if j + 1 < cells:
				max_step = maxf(max_step, absf(_h(x, z + CELL) - _h(x, z)))
	var window := engine_half + engine_blend
	var wcells := int(2.0 * window / CELL)
	var wstep := 0.0
	var over := 0
	for i in range(wcells):
		for j in range(wcells):
			var wx := -window + (float(i) + 0.5) * CELL
			var wz := -window + (float(j) + 0.5) * CELL
			if i + 1 < wcells:
				var dx := absf(_h(wx + CELL, wz) - _h(wx, wz))
				wstep = maxf(wstep, dx)
				over += 1 if dx > 0.5 + 1e-6 else 0
			if j + 1 < wcells:
				var dz := absf(_h(wx, wz + CELL) - _h(wx, wz))
				wstep = maxf(wstep, dz)
				over += 1 if dz > 0.5 + 1e-6 else 0
	# Negative control: the same-size square at fixed offsets well outside the pad; the smallest spread.
	var ctl := INF
	for off in [Vector2(18, 0), Vector2(-18, 0), Vector2(0, 18), Vector2(0, -18), Vector2(18, 18), Vector2(-18, 18), Vector2(18, -18), Vector2(-18, -18)]:
		ctl = minf(ctl, float(_spread(off.x, off.y, need)["spread"]))
	return {
		"samples": s["samples"], "half_m": half, "need_half_m": need, "spread_m": s["spread"], "wet_cols": s["wet"],
		"trees_inside": _count_in(_instances("Trees", func(n: String) -> bool: return n.ends_with("_trunk")), 0.0, 0.0, need, need),
		"blend_band_m": blend, "blend_max_step_m": max_step, "negctl_unflattened_spread_m": ctl,
		"blend_window_m": window, "blend_max_step_full_window_m": wstep, "samples_full_window": wcells * wcells, "pairs_over_half_m": over,
		"blend_max_column_step_m": _col_step(reach), "blend_max_envelope_step_m": max_step,
		"blend_max_column_step_full_window_m": _col_step(window), "blend_max_envelope_step_full_window_m": wstep,
		"blend_envelope_pairs_over_half_m": over,
		"engine_half_m": engine_half, "engine_blend_m": engine_blend,
		"engine_blend_cols_from_template": is_equal_approx(engine_blend, blend) and is_equal_approx(engine_half, need),
	}


# ------------------------------------------------------------------ shots
func _grab() -> Image:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _show_homestead(on: bool) -> void:
	_hs.visible = on and _mutation != "hidden"


func _place(at: Vector3, look: Vector3) -> void:
	_cam.target = null
	_cam.global_position = at
	_cam.look_at(look, Vector3.UP)


## Screen rectangle of a world box (edges clipped at the near plane, so a box the camera stands inside
## or beside still projects), and whether at least half of it is on screen.
func _project(box: AABB) -> Dictionary:
	var inv := _cam.global_transform.affine_inverse()
	var th := tan(deg_to_rad(_cam.fov) * 0.5)
	var asp := float(SHOT_W) / float(SHOT_H)
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
				var sx: float = SHOT_W * 0.5 + (e.x / -e.z) / (th * asp) * SHOT_W * 0.5
				var sy: float = SHOT_H * 0.5 - (e.y / -e.z) / th * SHOT_H * 0.5
				lo = Vector2(minf(lo.x, sx), minf(lo.y, sy))
				hi = Vector2(maxf(hi.x, sx), maxf(hi.y, sy))
	if lo.x == INF:
		return {"in_viewport": false, "rect": Rect2i()}
	var full := Rect2(lo, hi - lo)
	var inside := full.intersection(Rect2(Vector2.ZERO, Vector2(SHOT_W, SHOT_H)))
	var share := inside.get_area() / maxf(full.get_area(), 1.0)
	var pix := Rect2i(Vector2i(inside.position.floor()), Vector2i(inside.size.ceil())).intersection(Rect2i(0, 0, SHOT_W, SHOT_H))
	# On screen: at least half the box is in frame, or the part in frame is itself large (a box the camera stands over).
	return {"in_viewport": share >= 0.5 or inside.get_area() >= 0.01 * SHOT_W * SHOT_H, "rect": pix}


static func _changed_in(a: Image, b: Image, rect: Rect2i) -> int:
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var n := 0
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		var row := y * w
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var i := (row + x) * 3
			if absi(da[i] - db[i]) > PIX_TOL or absi(da[i + 1] - db[i + 1]) > PIX_TOL or absi(da[i + 2] - db[i + 2]) > PIX_TOL:
				n += 1
	return n


static func _luma_stats(img: Image) -> Dictionary:
	var d := img.get_data()
	var w := img.get_width()
	var h := img.get_height()
	var sum := 0.0
	var sq := 0.0
	var n := 0
	for y in range(0, h, LATTICE):
		for x in range(0, w, LATTICE):
			var i := (y * w + x) * 3
			var l := (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255.0
			sum += l
			sq += l * l
			n += 1
	var mean := sum / float(n)
	return {"mean": mean, "std": sqrt(maxf(sq / float(n) - mean * mean, 0.0))}


static func _diff_frac(a: Image, b: Image) -> float:
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var changed := 0
	var n := 0
	for y in range(0, h, LATTICE):
		for x in range(0, w, LATTICE):
			var i := (y * w + x) * 3
			n += 1
			if absi(da[i] - db[i]) > PIX_TOL or absi(da[i + 1] - db[i + 1]) > PIX_TOL or absi(da[i + 2] - db[i + 2]) > PIX_TOL:
				changed += 1
	return float(changed) / float(n)


## Judges one camera pose: the capture as the player would see it, the hide-one-subject differential
## for each named subject, and the whole-homestead differential. Returns {img, rec}.
func _judge(shot_id: String, subjects: Array) -> Dictionary:
	_show_homestead(true)
	var a := await _grab()
	var rec := {"id": shot_id, "subjects": []}
	for path in subjects:
		var node: Node3D = _hs.get_node_or_null(path)
		if node == null:
			rec["subjects"].append({"name": path, "in_viewport": false, "changed_px": 0})
			continue
		var proj := _project(HomesteadView.world_aabb(node))
		var was := node.visible
		node.visible = false
		var b := await _grab()
		node.visible = was
		var changed := 0
		if proj["rect"].size.x > 0 and proj["rect"].size.y > 0:
			changed = _changed_in(a, b, proj["rect"])
		rec["subjects"].append({"name": path, "in_viewport": proj["in_viewport"], "changed_px": changed})
	var whole := _project(HomesteadView.world_aabb(_hs))
	_hs.visible = false
	var hidden := await _grab()
	_show_homestead(true)
	var whole_changed := 0
	if whole["rect"].size.x > 0 and whole["rect"].size.y > 0:
		whole_changed = _changed_in(a, hidden, whole["rect"])
	rec["homestead_diff_frac"] = float(whole_changed) / float(SHOT_W * SHOT_H)
	var stats := _luma_stats(a)
	rec["mean_luma"] = stats["mean"]
	rec["luma_std"] = stats["std"]
	return {"img": a, "rec": rec}


## The weakest subject of a judged shot (changed pixels; zero when off screen): what a pose is picked on.
static func _score(rec: Dictionary) -> int:
	var worst := 1 << 30
	for s in rec["subjects"]:
		worst = mini(worst, int(s["changed_px"]) if s["in_viewport"] else 0)
	return worst


func _take_shots(rec: Dictionary) -> Array:
	var dir_a := float(_layout["handoff"]["dir_angle"])
	var dir := Vector3(cos(dir_a), 0.0, sin(dir_a))
	var side := Vector3(-dir.z, 0.0, dir.x)
	var y0 := _top
	var hand: Dictionary = _layout["handoff"]
	var door: Dictionary = _layout["door"]
	var fan := Vector3.ZERO
	for it in _layout["items"]:
		fan += Vector3(float(it["x"]), 0.0, float(it["z"]))
	fan = fan / float(_layout["items"].size())
	var item_paths: Array = []
	for it in _layout["items"]:
		item_paths.append("Items/Item_" + String(it["id"]))
	var results: Array = []
	var images: Array = []
	_walker.visible = false  # the colonist's body is only in the hand-off view

	# 1 aerial: from behind the pod, high, looking down at the pad.
	_place(Vector3(0.0, y0 + 26.0, 0.0) - dir * 22.0, Vector3(0.0, y0 + 0.5, 0.0))
	var r := await _judge("aerial", ["Slab", "Pod", "Rings"])
	results.append(r["rec"])
	images.append(r["img"])
	# 2 slab oblique: from the side, five metres up.
	_place(Vector3(0.0, y0 + 5.0, 0.0) + side * 9.5, Vector3(0.0, y0 + 0.6, 0.0) + dir * 0.8)
	r = await _judge("slab_oblique", ["Slab", "Pod", "Rings", "Items/Item_cold_fusion_pod", "Items/Item_portable_crafting_pod", "Items/Item_solar_cell_panel"])
	results.append(r["rec"])
	images.append(r["img"])
	# 3 pod door: from the front of the doorway.
	var door_at := Vector3(float(door["x"]), y0, float(door["z"]))
	_place(door_at + dir * 2.6 + side * 1.1 + Vector3(0.0, 1.7, 0.0), door_at + Vector3(0.0, 1.0, 0.0))
	r = await _judge("pod_door", ["Pod", "Pod/DoorPanel"])
	results.append(r["rec"])
	images.append(r["img"])
	# 4 equipment row: high over the whole fan, from the first of four sides where every item shows.
	var eq_best := {}
	var eq_score := -1
	var eq_poses := [side * 7.0 - dir * 1.0, -side * 7.0 - dir * 1.0, -dir * 7.5, dir * 2.0 + side * 6.0]
	for k in range(eq_poses.size()):
		_place(Vector3(fan.x, y0 + 5.5, fan.z) + eq_poses[k], Vector3(fan.x, y0 + 0.4, fan.z))
		var cand := await _judge("equipment", item_paths)
		var sc := _score(cand["rec"])
		if sc > eq_score:
			eq_score = sc
			eq_best = cand
			eq_best["rec"]["pose_index"] = k
		if eq_score >= 120:
			break
	results.append(eq_best["rec"])
	images.append(eq_best["img"])
	# 5 hand-off point of view: the real follow camera, as the player enters.
	_walker.visible = true
	_cam.target = _walker
	_cam.yaw = _entry_yaw
	_cam.pitch = _entry_pitch
	_cam.follow(_walker.pos)
	for _i in range(3):
		await _frame()
	r = await _judge("handoff_pov", ["Slab"] + item_paths)
	results.append(r["rec"])
	images.append(r["img"])
	# 6 approach: from 25 m out, the best of eight bearings (clockwise from behind the pod) where the pod shows.
	_walker.visible = false
	_cam.fov = APPROACH_FOV_DEG  # a long lens: at 25 m the pod would otherwise be a speck
	var best_ix := -1
	var best_key := -INF  # a hidden-control run can score every bearing -1.0; the first (lowest index) is kept
	var pick: Dictionary = {}
	for k in range(8):
		var az := atan2(-dir.z, -dir.x) + float(k) * TAU / 8.0
		var at := Vector3(cos(az) * 25.0, 0.0, sin(az) * 25.0)
		var gy: float = StalagWorld.ground_envelope_at(at.x, at.z, INF)
		_place(Vector3(at.x, gy + 2.2, at.z), Vector3(0.0, y0 + 1.2, 0.0))
		var cand2 := await _judge("approach", ["Pod"])
		# A bearing counts only if the pod shows; among those, the one where the homestead fills most of the frame.
		var key := float(cand2["rec"]["homestead_diff_frac"]) if _score(cand2["rec"]) >= 120 else -1.0 + float(cand2["rec"]["homestead_diff_frac"])
		if key > best_key:
			best_key = key
			best_ix = k
			pick = cand2
	_cam.fov = 70.0
	pick["rec"]["bearing_index"] = best_ix
	results.append(pick["rec"])
	images.append(pick["img"])

	# Files, per-shot statistics, pairwise distinctness and the contact sheet.
	var shot_dir := _out.path_join("shots" if _mutation == "none" else "shots_hidden")
	DirAccess.make_dir_recursive_absolute(shot_dir)
	for i in range(results.size()):
		var path := shot_dir.path_join("%d_%s.png" % [i + 1, SHOT_IDS[i]])
		(images[i] as Image).save_png(path)
		results[i]["file"] = path
	var min_diff := INF
	for i in range(images.size()):
		for j in range(i + 1, images.size()):
			min_diff = minf(min_diff, _diff_frac(images[i], images[j]))
	rec["resolution"] = [images[0].get_width(), images[0].get_height()]
	rec["pairwise_min_diff_frac"] = min_diff
	var sheet := Image.create(1920, 720, false, Image.FORMAT_RGB8)
	for i in range(images.size()):
		var tile: Image = (images[i] as Image).duplicate()
		tile.resize(640, 360, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(tile, Rect2i(0, 0, 640, 360), Vector2i((i % 3) * 640, (i / 3) * 360))
	var sheet_name := "contact_sheet.png" if _mutation == "none" else "contact_sheet_hidden.png"
	sheet.save_png(_out.path_join(sheet_name))
	rec["sheet"] = {"w": sheet.get_width(), "h": sheet.get_height(), "order": SHOT_IDS.duplicate(), "file": _out.path_join(sheet_name)}
	return results
