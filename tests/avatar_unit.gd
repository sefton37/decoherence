extends SceneTree
## SPDX-License-Identifier: AGPL-3.0-only
## Unit and fuzz harness for the player avatar (Spec 581, slice S1). No window and no GPU: the body is
## built from primitives and posed by a pure gait function, so everything is measured from the built scene
## tree (mesh triangles, joint nodes, foot marker nodes) and never from the data that produced it.
## It writes ONE record, unit_run_N.json inside OUT_DIR (N is UNIT_RUN); tests/verify_avatar_unit.sh runs
## this in two separate processes and merges the records into unit.json. The record carries measurements
## only; the DoD's jq judges. Every detector has a negative control that must fire: a planted violation
## for each fuzz check, a planted stride 1.6 times too long for the skate measure, and a recoloured copy
## for the silhouette measure.
##
## Env: OUT_DIR (required), UNIT_RUN (default 1), FUZZ_TRIALS (default 1600)

const AvatarBody := preload("res://game/avatar/avatar_body.gd")
const AvatarGait := preload("res://game/avatar/avatar_gait.gd")
const TEMPLATE_PATH := "res://game/avatar/avatar_template.json"
const REQUIRED := ["head", "torso", "arm_l", "arm_r", "leg_l", "leg_r", "foot_l", "foot_r", "visor", "vitals"]
const GRID_X := 100  ## front silhouette raster: 1 cm cells, x from -0.5 to 0.5 m
const GRID_Y := 180  ## and y from -0.02 to 1.78 m
const GRID_X0 := -0.5
const GRID_Y0 := -0.02
const CELL_M := 0.01
const POP_RAD := 1.0  ## a joint may not change by more than this in one frame (frames of at most 1/30 s)
const FUZZ_FRAMES := 60

var _fail := 0
var _tpl := {}
var _rng := RandomNumberGenerator.new()


func _check(name: String, ok: bool, why: String = "") -> void:
	if ok:
		print("AVATAR_UNIT_OK ", name)
	else:
		_fail += 1
		print("AVATAR_UNIT_FAIL ", name, " ", why)


func _initialize() -> void:
	# The root window joins the tree only after this call returns, and global transforms need the tree.
	await process_frame
	var out_dir := OS.get_environment("OUT_DIR")
	var run_ix := OS.get_environment("UNIT_RUN")
	if run_ix.is_empty():
		run_ix = "1"
	if out_dir.is_empty():
		push_error("avatar_unit: OUT_DIR is required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	_tpl = AvatarBody.load_template(TEMPLATE_PATH)
	if _tpl.is_empty():
		push_error("avatar_unit: template did not load")
		quit(3)
		return
	var trials := int(OS.get_environment("FUZZ_TRIALS")) if not OS.get_environment("FUZZ_TRIALS").is_empty() else 1600

	var rec := {"generated_epoch": int(Time.get_unix_time_from_system()), "mutation": "none"}
	var builds: Array = []
	var rasters := {}
	for p in _tpl["presets"]:
		var m := _measure_build(_tpl, String(p["id"]))
		rasters[String(p["id"])] = m.raster
		builds.append(m.rec)
	rec["builds"] = builds
	rec["distinct"] = _measure_distinct(rasters)
	rec["gait"] = _measure_gait()
	rec["determinism"] = _measure_determinism()
	var fz := _fuzz(trials)
	rec["fuzz"] = fz
	rec["neg_checker"] = _neg_checker()
	_check("fuzz_clean", int(fz["violations"]["total"]) == 0, str(fz["violations"]))

	var f := FileAccess.open(out_dir.path_join("unit_run_%s.json" % run_ix), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec))
	f.close()
	print("AVATAR_UNIT_DONE failures=", _fail, " digest=", rec["determinism"]["runs_digest"][0])
	quit(0 if _fail == 0 else 1)


# ------------------------------------------------------------------ building and measuring a body
func _add_body(tpl: Dictionary, pid: String) -> Node3D:
	var c: Dictionary = tpl.duplicate(true)
	c["preset_id"] = pid
	var body := AvatarBody.build(c)
	root.add_child(body)
	return body


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


## World-space extents of a node's meshes: [min_x, max_x, min_y, max_y] from the exact box of each
## transformed mesh bounding box.
static func _extents(meshes: Array) -> Array:
	var lo_x := INF
	var hi_x := -INF
	var lo_y := INF
	var hi_y := -INF
	for mi: MeshInstance3D in meshes:
		var bb: AABB = mi.mesh.get_aabb()
		var xf: Transform3D = mi.global_transform
		var c: Vector3 = xf * bb.get_center()
		var h: Vector3 = bb.size * 0.5
		var ex: float = absf(xf.basis.x.x) * h.x + absf(xf.basis.y.x) * h.y + absf(xf.basis.z.x) * h.z
		var ey: float = absf(xf.basis.x.y) * h.x + absf(xf.basis.y.y) * h.y + absf(xf.basis.z.y) * h.z
		lo_x = minf(lo_x, c.x - ex)
		hi_x = maxf(hi_x, c.x + ex)
		lo_y = minf(lo_y, c.y - ey)
		hi_y = maxf(hi_y, c.y + ey)
	return [lo_x, hi_x, lo_y, hi_y]


static func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _measure_build(tpl: Dictionary, pid: String) -> Dictionary:
	var body := _add_body(tpl, pid)
	var js := AvatarBody.joints(body)
	var ms := _meshes(body, [])
	var ext := _extents(ms)
	var tris := 0
	var caps := 0
	var textured := 0
	var seen := {}
	for mi: MeshInstance3D in ms:
		tris += mi.mesh.get_faces().size() / 3
		if mi.mesh is CapsuleMesh:
			caps += 1
		var mat := mi.material_override
		if mat is BaseMaterial3D and not seen.has(mat):
			seen[mat] = true
			var bm := mat as BaseMaterial3D
			if bm.albedo_texture != null or bm.emission_texture != null or bm.normal_texture != null:
				textured += 1
	var missing: Array = []
	var found: Array = []
	for n in REQUIRED:
		if js.has(n):
			found.append(n)
		else:
			missing.append(n)
	found.sort()
	var head_ext := _extents(_meshes(js["head"], [])) if js.has("head") else [0.0, 0.0, 0.0, 1.0]
	var visor_nodes := 0
	var vitals_nodes := 0
	for n in _all_nodes(body, []):
		if String(n.name).begins_with("visor"):
			visor_nodes += 1
		if String(n.name).begins_with("vitals"):
			vitals_nodes += 1
	var shell_luma := 0.0
	var chest := body.find_child("chest", true, false)
	if chest is MeshInstance3D and (chest as MeshInstance3D).material_override is BaseMaterial3D:
		shell_luma = _luma(((chest as MeshInstance3D).material_override as BaseMaterial3D).albedo_color)
	var front_ok := js.has("visor") and (js["visor"] as Node3D).global_position.z < body.global_position.z - 0.01
	var ras := _raster_front(ms)
	var bbox := _raster_bbox(ras)
	var height := float(ext[3]) - float(ext[2])
	var rec := {
		"id": pid,
		"height_m": height,
		"head_frac": (float(head_ext[3]) - float(head_ext[2])) / height,
		"half_width_idle_m": maxf(absf(float(ext[0])), absf(float(ext[1]))),
		"lowest_y_m": float(ext[2]),
		"tris": tris,
		"mesh_instances": ms.size(),
		"node_count": _count_nodes(body),
		"capsule_meshes": caps,
		"textures_loaded": textured,
		"missing_joints": missing,
		"joints_found": found,
		"front_ok": front_ok,
		"visor_nodes": visor_nodes,
		"vitals_nodes": vitals_nodes,
		"shell_luma": shell_luma,
		"silhouette_w_over_h": float(bbox.x) * CELL_M / maxf(float(bbox.y) * CELL_M, 0.001),
	}
	body.queue_free()
	root.remove_child(body)
	body.free()
	print("AVATAR_UNIT_BUILD ", pid, " h=%.3f hw=%.3f tris=%d meshes=%d" % [height, rec["half_width_idle_m"], tris, ms.size()])
	_check("build_" + pid, missing.is_empty() and caps == 0, str(missing))
	return {"rec": rec, "raster": ras}


func _all_nodes(n: Node, acc: Array) -> Array:
	acc.append(n)
	for ch in n.get_children():
		_all_nodes(ch, acc)
	return acc


# ------------------------------------------------------------------ silhouettes
## Front silhouette: every mesh triangle projected onto the x-y plane and filled into a 1 cm raster.
func _raster_front(ms: Array) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(GRID_X * GRID_Y)
	for mi: MeshInstance3D in ms:
		var xf: Transform3D = mi.global_transform
		var f: PackedVector3Array = mi.mesh.get_faces()
		var i := 0
		while i + 2 < f.size():
			var a: Vector3 = xf * f[i]
			var b: Vector3 = xf * f[i + 1]
			var c: Vector3 = xf * f[i + 2]
			_fill_tri(g, Vector2(a.x, a.y), Vector2(b.x, b.y), Vector2(c.x, c.y))
			i += 3
	return g


static func _fill_tri(g: PackedByteArray, a: Vector2, b: Vector2, c: Vector2) -> void:
	var x0 := int(floor((minf(a.x, minf(b.x, c.x)) - GRID_X0) / CELL_M))
	var x1 := int(floor((maxf(a.x, maxf(b.x, c.x)) - GRID_X0) / CELL_M))
	var y0 := int(floor((minf(a.y, minf(b.y, c.y)) - GRID_Y0) / CELL_M))
	var y1 := int(floor((maxf(a.y, maxf(b.y, c.y)) - GRID_Y0) / CELL_M))
	var den := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if absf(den) < 1e-12:
		return
	for gy in range(maxi(y0, 0), mini(y1, GRID_Y - 1) + 1):
		var py := GRID_Y0 + (float(gy) + 0.5) * CELL_M
		for gx in range(maxi(x0, 0), mini(x1, GRID_X - 1) + 1):
			var px := GRID_X0 + (float(gx) + 0.5) * CELL_M
			var l1 := ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / den
			var l2 := ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / den
			var l3 := 1.0 - l1 - l2
			if l1 >= -0.02 and l2 >= -0.02 and l3 >= -0.02:
				g[gy * GRID_X + gx] = 1


static func _raster_bbox(g: PackedByteArray) -> Vector2i:
	var x0 := GRID_X
	var x1 := -1
	var y0 := GRID_Y
	var y1 := -1
	for gy in range(GRID_Y):
		for gx in range(GRID_X):
			if g[gy * GRID_X + gx] != 0:
				x0 = mini(x0, gx)
				x1 = maxi(x1, gx)
				y0 = mini(y0, gy)
				y1 = maxi(y1, gy)
	if x1 < 0:
		return Vector2i.ZERO
	return Vector2i(x1 - x0 + 1, y1 - y0 + 1)


static func _iou(a: PackedByteArray, b: PackedByteArray) -> float:
	var inter := 0
	var uni := 0
	for i in range(a.size()):
		var ai := a[i] != 0
		var bi := b[i] != 0
		if ai and bi:
			inter += 1
		if ai or bi:
			uni += 1
	return float(inter) / float(maxi(uni, 1))


func _measure_distinct(rasters: Dictionary) -> Dictionary:
	var ids: Array = rasters.keys()
	var pairs: Array = []
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			pairs.append({"a": ids[i], "b": ids[j], "iou": _iou(rasters[ids[i]], rasters[ids[j]])})
	var pid: String = String(_tpl["default_preset"])
	var again := _raster_of(_tpl, pid)
	var tinted: Dictionary = _tpl.duplicate(true)
	for k in tinted["colors"].keys():
		tinted["colors"][k] = "#a15c2e"
	var recoloured := _raster_of(tinted, pid)
	var d := {"pairs": pairs, "self_iou": _iou(rasters[pid], again), "recolour_iou": _iou(rasters[pid], recoloured)}
	for p in pairs:
		print("AVATAR_UNIT_IOU ", p["a"], " ", p["b"], " ", "%.3f" % p["iou"])
	_check("silhouettes_distinct", pairs.all(func(p): return p["iou"] <= 0.85), str(pairs))
	return d


func _raster_of(tpl: Dictionary, pid: String) -> PackedByteArray:
	var body := _add_body(tpl, pid)
	var r := _raster_front(_meshes(body, []))
	root.remove_child(body)
	body.free()
	return r


# ------------------------------------------------------------------ the rig under a scripted stream
## One scripted frame: distance travelled on the ground, frame time, grounded.
class Frame:
	var d := 0.0
	var dt := 1.0 / 60.0
	var grounded := true

	func _init(d_: float, dt_: float, g_: bool = true) -> void:
		d = d_
		dt = dt_
		grounded = g_


func _frames(speed: float, seconds: float, dt: float, grounded: bool = true) -> Array:
	var out: Array = []
	for _i in range(int(round(seconds / dt))):
		out.append(Frame.new(speed * dt, dt, grounded))
	return out


class Rig:
	var body: Node3D
	var js := {}
	var meshes: Array = []
	var cfg := {}
	var state := {}
	var feet_meshes: Array = []


func _make_rig(tpl: Dictionary, pid: String, cfg_override: Dictionary = {}) -> Rig:
	var r := Rig.new()
	r.body = _add_body(tpl, pid)
	r.js = AvatarBody.joints(r.body)
	r.meshes = _meshes(r.body, [])
	r.cfg = AvatarBody.gait_cfg(tpl, pid)
	for k in cfg_override.keys():
		r.cfg[k] = cfg_override[k]
	r.state = AvatarGait.initial_state()
	return r


func _free_rig(r: Rig) -> void:
	root.remove_child(r.body)
	r.body.free()


## Advances the state one frame, applies the pose to the rig and returns the pose.
func _advance(r: Rig, f: Frame, pose_cfg: Dictionary = {}) -> Dictionary:
	AvatarGait.step(r.state, r.cfg, f.d, f.dt, f.grounded)
	var pose := AvatarGait.pose(r.state, r.cfg if pose_cfg.is_empty() else pose_cfg)
	AvatarBody.apply_pose(r.js, pose)
	return pose


func _foot_world(r: Rig, side: String) -> Vector3:
	return (r.js["foot_" + side] as Node3D).global_position


static func _p2p(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for v in a:
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
	return hi - lo


static func _mean(a: Array) -> float:
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(maxi(a.size(), 1))


static func _corr(a: Array, b: Array) -> float:
	var ma := _mean(a)
	var mb := _mean(b)
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for i in range(a.size()):
		var da: float = float(a[i]) - ma
		var db: float = float(b[i]) - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	if saa < 1e-12 or sbb < 1e-12:
		return 0.0
	return sab / sqrt(saa * sbb)


## Metres walked per gait cycle, read from the rig: the distance between rising crossings of the left hip
## angle through its own mean.
func _stride_from_hip(hip: Array, dist_per_frame: float) -> float:
	var m := _mean(hip)
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
	return float(last - first) * dist_per_frame / float(n - 1)


## Stance-foot slip: for each contiguous stretch where a foot marker is on the ground, the foot's net
## travel on the ground over the stretch divided by the body's travel over the same stretch.
func _skate(tpl: Dictionary, pid: String, speed: float, planted_scale: float) -> Dictionary:
	var r := _make_rig(tpl, pid)
	var pose_cfg: Dictionary = r.cfg.duplicate()
	pose_cfg["stride_len_m"] = float(r.cfg["stride_len_m"]) * planted_scale
	pose_cfg["run_stride_len_m"] = float(r.cfg["run_stride_len_m"]) * planted_scale
	var dt := 1.0 / 120.0
	var d := speed * dt
	var warm := int(1.0 / dt)
	var body_z := 0.0
	var ratios: Array = []
	var stance_samples := 0
	var runs := {"l": [], "r": []}
	var open := {"l": [], "r": []}
	var n := int(8.0 / dt)
	for i in range(n):
		_advance(r, Frame.new(d, dt), pose_cfg if planted_scale != 1.0 else {})
		body_z -= d
		r.body.position.z = body_z
		if i < warm:
			continue
		for s in ["l", "r"]:
			var fw := _foot_world(r, s)
			if fw.y <= 0.003:
				stance_samples += 1
				(open[s] as Array).append(Vector2(fw.z, body_z))
			elif not (open[s] as Array).is_empty():
				(runs[s] as Array).append((open[s] as Array).duplicate())
				(open[s] as Array).clear()
	# A stretch still open at the end, and one cut by the warm-up, are not whole stances: only closed runs count.
	for s in ["l", "r"]:
		var rs: Array = runs[s]
		for k in range(1, rs.size()):  # the first closed stretch may be cut by the warm-up
			var seg: Array = rs[k]
			var foot_travel := absf(float((seg[seg.size() - 1] as Vector2).x) - float((seg[0] as Vector2).x))
			var body_travel := absf(float((seg[seg.size() - 1] as Vector2).y) - float((seg[0] as Vector2).y))
			if body_travel > 0.2:
				ratios.append(foot_travel / body_travel)
	_free_rig(r)
	return {"samples": stance_samples, "ratios": ratios, "max": (ratios.max() if not ratios.is_empty() else 999.0)}


func _measure_gait() -> Dictionary:
	var pid := String(_tpl["default_preset"])
	var r := _make_rig(_tpl, pid)
	var dt := 1.0 / 60.0
	var cfgg: Dictionary = r.cfg
	# walk 4.5 m/s for 15 s, run 7 m/s for 15 s, settle, then idle
	var hip_l: Array = []
	var hip_r: Array = []
	var arm_l: Array = []
	var run_hip_l: Array = []
	var ext_hw := 0.0
	var foot_lo := INF
	var foot_hi := -INF
	var samples := 0
	var warm := 90
	var walk_d := 4.5 * dt
	var i := 0
	for f in _frames(4.5, 15.0, dt):
		var pose := _advance(r, f)
		if i >= warm:
			hip_l.append(pose["hip_l"])
			hip_r.append(pose["hip_r"])
			arm_l.append(pose["arm_l"])
		if i >= warm:
			var e := _extents(r.meshes)
			ext_hw = maxf(ext_hw, maxf(absf(float(e[0])), absf(float(e[1]))))
			var fy := minf(_foot_world(r, "l").y, _foot_world(r, "r").y)
			foot_lo = minf(foot_lo, fy)
			foot_hi = maxf(foot_hi, fy)
			samples += 1
		i += 1
	var stride_walk := _stride_from_hip(hip_l, walk_d)
	var leg_p2p := _p2p(hip_l)
	var arm_p2p := _p2p(arm_l)
	var lr := _corr(hip_l, hip_r)
	var al := _corr(arm_l, hip_l)
	i = 0
	var run_d := 7.0 * dt
	var warm_run := 120
	for f in _frames(7.0, 15.0, dt):
		var pose := _advance(r, f)
		if i >= warm_run:
			run_hip_l.append(pose["hip_l"])
		if i >= warm_run:
			var e2 := _extents(r.meshes)
			ext_hw = maxf(ext_hw, maxf(absf(float(e2[0])), absf(float(e2[1]))))
			var fy2 := minf(_foot_world(r, "l").y, _foot_world(r, "r").y)
			foot_lo = minf(foot_lo, fy2)
			foot_hi = maxf(foot_hi, fy2)
			samples += 1
		i += 1
	var stride_run := _stride_from_hip(run_hip_l, run_d)

	# Stop: from a walk, the time until the pose is back at the idle pose.
	var idle_pose := AvatarGait.pose(AvatarGait.initial_state(), cfgg)
	var settle_dt := 1.0 / 240.0
	var settle_s := -1.0
	var t := 0.0
	for _k in range(240):
		var pz := _advance(r, Frame.new(0.0, settle_dt))
		t += settle_dt
		if _pose_gap(pz, idle_pose) <= 0.02:
			settle_s = t
			break
	# Idle: settled, then 600 frames standing still.
	var idle_hip: Array = []
	var idle_breath: Array = []
	for f in _frames(0.0, 10.0, dt):
		var pi := _advance(r, f)
		idle_hip.append(pi["hip_l"])
		idle_breath.append((r.js["torso"] as Node3D).position.y)
	# Airborne: a walk, then 60 airborne frames that still travel: the cycle must not advance.
	var air_delta := 0.0
	for f in _frames(4.5, 1.0, dt):
		_advance(r, f)
	var before := float(r.state["phase_total"])
	for f in _frames(4.5, 1.0, dt, false):
		var b := float(r.state["phase_total"])
		_advance(r, f)
		air_delta += absf(float(r.state["phase_total"]) - b)
	var wall_delta := 0.0
	for f in _frames(4.5, 1.0, dt):
		_advance(r, f)
	for f in _frames(0.0, 1.0, dt):  # pushing into a wall: no displacement
		var b2 := float(r.state["phase_total"])
		_advance(r, f)
		wall_delta += absf(float(r.state["phase_total"]) - b2)
	_free_rig(r)

	var sk_walk := _skate(_tpl, pid, 4.5, 1.0)
	var sk_run := _skate(_tpl, pid, 7.0, 1.0)
	var sk_planted := _skate(_tpl, pid, 4.5, 1.6)
	var skate := {
		"stance_samples": int(sk_walk["samples"]) + int(sk_run["samples"]),
		"walk_ratio": float(sk_walk["max"]),
		"run_ratio": float(sk_run["max"]),
		"planted_stride_x1p6_ratio": float(sk_planted["max"]),
		"measured_from": "rig_foot_nodes",
	}
	print("AVATAR_UNIT_SKATE walk=%.3f run=%.3f planted=%.3f" % [skate["walk_ratio"], skate["run_ratio"], skate["planted_stride_x1p6_ratio"]])
	_check("skate_bites", float(skate["planted_stride_x1p6_ratio"]) >= 0.35)
	return {
		"samples": hip_l.size() + run_hip_l.size(),
		"stride_len_walk_m": stride_walk,
		"stride_len_run_m": stride_run,
		"leg_swing_p2p_rad": leg_p2p,
		"arm_swing_p2p_rad": arm_p2p,
		"leg_lr_corr": lr,
		"arm_leg_corr": al,
		"idle_leg_p2p_rad": _p2p(idle_hip),
		"idle_breath_p2p_m": _p2p(idle_breath),
		"airborne_phase_delta": air_delta,
		"wall_phase_delta": wall_delta,
		"stop_settle_s": settle_s,
		"skate": skate,
		"extent": {
			"samples": samples,
			"half_width_max_m": ext_hw,
			"lowest_foot_y_min_m": foot_lo,
			"lowest_foot_y_max_m": foot_hi,
		},
	}


static func _pose_gap(a: Dictionary, b: Dictionary) -> float:
	var g := 0.0
	for k in ["hip_l", "hip_r", "knee_l", "knee_r", "arm_l", "arm_r", "elbow_l", "elbow_r", "lean", "twist"]:
		g = maxf(g, absf(float(a[k]) - float(b[k])))
	g = maxf(g, absf(float(a["pelvis_y"]) - float(b["pelvis_y"])) * 2.0)
	return g


# ------------------------------------------------------------------ determinism
func _digest_run(pid: String, speed: float) -> String:
	var r := _make_rig(_tpl, pid)
	var buf := PackedFloat64Array()
	for mi: MeshInstance3D in r.meshes:
		var xf: Transform3D = mi.global_transform
		for v in mi.mesh.get_faces():
			var w: Vector3 = xf * v
			buf.append(w.x)
			buf.append(w.y)
			buf.append(w.z)
		var mat := mi.material_override
		if mat is BaseMaterial3D:
			var c := (mat as BaseMaterial3D).albedo_color
			buf.append(c.r + c.g * 3.0 + c.b * 7.0)
	var dt := 1.0 / 60.0
	for f in _frames(speed, 4.0, dt) + _frames(0.0, 1.0, dt) + _frames(speed * 0.5, 1.0, dt, false) + _frames(speed, 2.0, dt):
		var pose := _advance(r, f)
		for k in pose.keys():
			buf.append(float(pose[k]))
	_free_rig(r)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.to_byte_array())
	return ctx.finish().hex_encode()


func _measure_determinism() -> Dictionary:
	var pid := String(_tpl["default_preset"])
	var runs: Array = []
	for _i in range(3):
		runs.append(_digest_run(pid, 4.5))
	var other_input := _digest_run(pid, 6.0)
	var other_preset := ""
	for p in _tpl["presets"]:
		if String(p["id"]) != pid:
			other_preset = _digest_run(String(p["id"]), 4.5)
			break
	var d := {
		"runs_digest": runs,
		"same_input_equal": runs[0] == runs[1] and runs[1] == runs[2],
		"input_changes_digest": other_input != runs[0],
		"preset_changes_digest": other_preset != runs[0],
	}
	_check("deterministic", d["same_input_equal"] and d["input_changes_digest"] and d["preset_changes_digest"])
	return d


# ------------------------------------------------------------------ the frame checker and the fuzz
## One checked frame, as plain numbers: what the rig and the pose said after the step.
func _frame_record(r: Rig, pose: Dictionary, f: Frame, stride: float, phase_before: float) -> Dictionary:
	var e := _extents(r.meshes)
	return {
		"hip_l": pose["hip_l"], "hip_r": pose["hip_r"], "knee_l": pose["knee_l"], "knee_r": pose["knee_r"],
		"arm_l": pose["arm_l"], "arm_r": pose["arm_r"], "elbow_l": pose["elbow_l"], "elbow_r": pose["elbow_r"],
		"lean": pose["lean"], "twist": pose["twist"], "pelvis_y": pose["pelvis_y"],
		"half_width": maxf(absf(float(e[0])), absf(float(e[1]))),
		"foot_y_min": minf(_foot_world(r, "l").y, _foot_world(r, "r").y),
		"phase_delta": float(r.state["phase_total"]) - phase_before,
		"expected_delta": f.d / stride if f.grounded else 0.0,
		"grounded": f.grounded,
		"dt": f.dt,
	}


## Reads two consecutive records and returns the names of the checks that failed. No fuzz state in here,
## so the same function judges the real stream and the planted one.
func _judge(prev: Dictionary, cur: Dictionary, lim: Dictionary) -> Array:
	var bad: Array = []
	for k in cur.keys():
		var v = cur[k]
		if v is float and (is_nan(v) or is_inf(v)):
			bad.append("nan")
			break
	var hip_max := float(lim["hip_limit_rad"])
	var knee_max := float(lim["knee_limit_rad"])
	if absf(float(cur["hip_l"])) > hip_max or absf(float(cur["hip_r"])) > hip_max:
		bad.append("hip_limit")
	if float(cur["knee_l"]) < -0.001 or float(cur["knee_r"]) < -0.001 or float(cur["knee_l"]) > knee_max or float(cur["knee_r"]) > knee_max:
		bad.append("knee_limit")
	if float(cur["half_width"]) > float(lim["collision_half_width_m"]):
		bad.append("extent")
	if cur["grounded"] and absf(float(cur["phase_delta"]) - float(cur["expected_delta"])) > 1e-5:
		bad.append("phase_jump")
	if float(cur["foot_y_min"]) < -0.02:
		bad.append("foot_below_ground")
	if not cur["grounded"] and absf(float(cur["phase_delta"])) > 0.0:
		bad.append("airborne_advance")
	if not prev.is_empty() and float(cur["dt"]) <= 1.0 / 30.0 + 1e-6:
		var pop := false
		for k in ["hip_l", "hip_r", "knee_l", "knee_r", "arm_l", "arm_r", "elbow_l", "elbow_r", "lean", "twist"]:
			if absf(float(cur[k]) - float(prev[k])) > POP_RAD:
				pop = true
		if absf(float(cur["pelvis_y"]) - float(prev["pelvis_y"])) > 0.25:
			pop = true
		if pop:
			bad.append("frame_pop")
	return bad


func _fuzz(trials: int) -> Dictionary:
	_rng.seed = 581
	var rigs: Array = []
	var lims: Array = []
	for p in _tpl["presets"]:
		var rg := _make_rig(_tpl, String(p["id"]))
		rigs.append(rg)
		lims.append({
			"hip_limit_rad": rg.cfg["hip_limit_rad"], "knee_limit_rad": rg.cfg["knee_limit_rad"],
			"collision_half_width_m": _tpl["collision_half_width_m"],
		})
	var viol := {"total": 0, "nan": 0, "hip_limit": 0, "knee_limit": 0, "extent": 0, "phase_jump": 0,
		"foot_below_ground": 0, "airborne_advance": 0, "frame_pop": 0}
	var hits := {"pose_checks": 0, "speed_changes": 0, "stops": 0, "airborne_spans": 0, "run_frames": 0, "walk_frames": 0}
	var dts := [1.0 / 144.0, 1.0 / 90.0, 1.0 / 60.0, 1.0 / 45.0, 1.0 / 30.0]
	var frames := 0
	for t in range(trials):
		var rg: Rig = rigs[t % rigs.size()]
		var lim: Dictionary = lims[t % rigs.size()]
		rg.state = AvatarGait.initial_state()
		var prev := {}
		var mode := 0
		var left := 0
		var speed := 0.0
		var grounded := true
		var prev_speed := 0.0
		var prev_grounded := true
		for fi in range(FUZZ_FRAMES):
			if left <= 0:
				var u := _rng.randf()
				mode = 0 if u < 0.35 else (1 if u < 0.65 else (2 if u < 0.8 else 3))
				left = _rng.randi_range(5, 25)
				grounded = mode != 3
				if mode == 0:
					speed = _rng.randf_range(2.0, 5.5)
				elif mode == 1:
					speed = _rng.randf_range(6.0, 8.0)
				elif mode == 2:
					speed = 0.0
				else:
					speed = _rng.randf_range(0.0, 7.0)
			left -= 1
			var dt: float = dts[_rng.randi_range(0, dts.size() - 1)]
			var fr := Frame.new(speed * dt, dt, grounded)
			if absf(speed - prev_speed) > 0.5 and fi > 0:
				hits["speed_changes"] += 1
			if speed == 0.0 and prev_speed > 0.0 and grounded:
				hits["stops"] += 1
			if not grounded and prev_grounded and fi > 0:
				hits["airborne_spans"] += 1
			if grounded and speed >= 6.0:
				hits["run_frames"] += 1
			elif grounded and speed > 0.25:
				hits["walk_frames"] += 1
			prev_speed = speed
			prev_grounded = grounded
			var pb := float(rg.state["phase_total"])
			var pose := _advance(rg, fr)
			var rec := _frame_record(rg, pose, fr, float(rg.state["stride"]), pb)
			var bad := _judge(prev, rec, lim)
			hits["pose_checks"] += 1
			frames += 1
			for b in bad:
				viol[b] += 1
				viol["total"] += 1
				if viol["total"] <= 6:
					print("AVATAR_UNIT_VIOLATION ", b, " trial=", t, " frame=", fi, " speed=", speed, " grounded=", grounded, " dt=", dt, " prev=", prev, " cur=", rec)
			prev = rec
	for rg in rigs:
		_free_rig(rg)
	print("AVATAR_UNIT_FUZZ trials=%d frames=%d violations=%s hits=%s" % [trials, frames, viol, hits])
	return {"trials": trials, "frames": frames, "violations": viol, "hits": hits}


## Each fuzz check must fire on a planted violation and stay quiet on the clean record it was cut from.
func _neg_checker() -> Dictionary:
	var rg := _make_rig(_tpl, String(_tpl["default_preset"]))
	var lim := {"hip_limit_rad": rg.cfg["hip_limit_rad"], "knee_limit_rad": rg.cfg["knee_limit_rad"],
		"collision_half_width_m": _tpl["collision_half_width_m"]}
	var prev := {}
	var cur := {}
	var f_walk: Frame = Frame.new(4.5 / 60.0, 1.0 / 60.0)
	for _i in range(90):
		var pb := float(rg.state["phase_total"])
		var pose := _advance(rg, f_walk)
		prev = cur
		cur = _frame_record(rg, pose, f_walk, float(rg.state["stride"]), pb)
	var clean := _judge(prev, cur, lim).is_empty()
	var out := {"clean_control_passes": clean}
	out["planted_nan_detected"] = _planted(prev, cur, lim, "nan")
	out["planted_hip_limit_detected"] = _planted(prev, cur, lim, "hip_limit")
	out["planted_extent_detected"] = _planted(prev, cur, lim, "extent")
	out["planted_phase_jump_detected"] = _planted(prev, cur, lim, "phase_jump")
	out["planted_foot_below_ground_detected"] = _planted(prev, cur, lim, "foot_below_ground")
	out["planted_airborne_advance_detected"] = _planted(prev, cur, lim, "airborne_advance")
	out["planted_frame_pop_detected"] = _planted(prev, cur, lim, "frame_pop")
	_free_rig(rg)
	for k in out.keys():
		_check("neg_" + k, out[k] == true, k)
	return out


func _planted(prev: Dictionary, cur: Dictionary, lim: Dictionary, kind: String) -> bool:
	var c := cur.duplicate()
	if kind == "nan":
		c["hip_l"] = NAN
	elif kind == "hip_limit":
		c["hip_r"] = float(lim["hip_limit_rad"]) + 0.2
	elif kind == "extent":
		c["half_width"] = float(lim["collision_half_width_m"]) + 0.05
	elif kind == "phase_jump":
		c["phase_delta"] = float(c["phase_delta"]) + 0.3
	elif kind == "foot_below_ground":
		c["foot_y_min"] = -0.1
	elif kind == "airborne_advance":
		c["grounded"] = false
		c["phase_delta"] = 0.05
	elif kind == "frame_pop":
		c["knee_l"] = float(prev["knee_l"]) + 2.0
		c["dt"] = 1.0 / 60.0
	return kind in _judge(prev, c, lim)
