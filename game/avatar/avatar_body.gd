extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 581 S1 -- builds the player's body (the AV3 "Open Ledger" direction: an Empire white soft-shell suit
## that broadcasts its wearer's vitals, a dark visor, faceless for now) from the template data.
## Provenance: procedural primitives only (boxes, cylinders and spheres sized in code from the data file);
## no imported mesh, texture, rig or clip, and nothing ported from elsewhere. The look is entirely in
## avatar_template.json: change a preset there and the body changes.
##
## The result is one Node3D "AvatarBody" whose origin is on the ground under the feet and whose front is -Z
## (the walker's convention). Joint and marker nodes the probes and the view rely on:
##   pelvis, torso, head, arm_l, arm_r, elbow_l, elbow_r, leg_l, leg_r, knee_l, knee_r, ankle_l, ankle_r,
##   foot_l and foot_r (markers on the SOLE under each ankle), visor (the dark glass), vitals (the group of
##   emissive strips; its meta "material" is the shared strip material).
## Every joint rotates about X only (swing), except the torso, which also twists about Y.

const AvatarGait := preload("res://game/avatar/avatar_gait.gd")
const ANKLE_RATIO := 0.985  ## standing, the legs are this fraction of their full length (a slight knee bend)
const NECK_M := 0.045
const SEG := 10  ## radial segments of every cylinder
const SPHERE_RADIAL := 12
const SPHERE_RINGS := 6


static func load_template(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}


## The preset dictionary with this id (the default preset when the id is not in the template).
static func preset_of(tpl: Dictionary, pid: String) -> Dictionary:
	var first := {}
	for p in tpl["presets"]:
		if first.is_empty():
			first = p
		if String(p["id"]) == pid:
			return p
	for p in tpl["presets"]:
		if String(p["id"]) == String(tpl["default_preset"]):
			return p
	return first


## The flat dictionary AvatarGait reads: the template's gait block plus this preset's leg geometry.
static func gait_cfg(tpl: Dictionary, pid: String) -> Dictionary:
	var p := preset_of(tpl, pid)
	var g: Dictionary = (tpl["gait"] as Dictionary).duplicate()
	var hip_y := float(p["leg_frac"]) * float(tpl["height_m"])
	var ah := float(g["ankle_height_m"])
	var leg := (hip_y - ah) / ANKLE_RATIO
	g["hip_y"] = hip_y
	g["leg_l1"] = leg * 0.52
	g["leg_l2"] = leg * 0.48
	return g


static func _col(h: String) -> Color:
	return Color.html(h)


static func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


static func _mi(name: String, mesh: Mesh, mat: Material, pos: Vector3, scl: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scl
	return mi


static func _box(name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	return _mi(name, b, mat, pos)


static func _cyl(name: String, r_top: float, r_bot: float, h: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = SEG
	c.rings = 1
	return _mi(name, c, mat, pos)


## A sphere (or ellipsoid, when the size differs per axis) of the given overall size.
static func _ball(name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = 0.5
	s.height = 1.0
	s.radial_segments = SPHERE_RADIAL
	s.rings = SPHERE_RINGS
	return _mi(name, s, mat, pos, size)


static func _node(name: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.position = pos
	return n


## Builds the body for cfg: the template dictionary plus an optional "preset_id". Returns it posed standing.
static func build(cfg: Dictionary) -> Node3D:
	var pid := String(cfg.get("preset_id", cfg["default_preset"]))
	var p := preset_of(cfg, pid)
	var g := gait_cfg(cfg, pid)
	var height := float(cfg["height_m"])
	var colors: Dictionary = cfg["colors"]
	var shell := _mat(_col(colors["shell"]), 0.85)
	var shade := _mat(_col(colors["shell_shade"]), 0.9)
	var glass := _mat(_col(colors["visor"]), 0.12)
	var trim := _mat(_col(colors["trim"]), 0.7)
	var glove := _mat(_col(colors["glove"]), 0.8)
	var boot := _mat(_col(colors["boot"]), 0.85)
	var vit := _mat(_col(colors["vitals"]).darkened(0.6), 0.5)
	vit.emission_enabled = true
	vit.emission = _col(colors["vitals"])
	vit.emission_energy_multiplier = 1.2

	var hip_y := float(g["hip_y"])
	var l1 := float(g["leg_l1"])
	var l2 := float(g["leg_l2"])
	var ah := float(g["ankle_height_m"])
	var head_h := height / float(p["heads"])
	var torso_len := height - hip_y - NECK_M - head_h
	var sh := float(p["shoulder_half_m"])
	var ch := float(p["chest_half_m"])
	var depth := float(p["torso_depth_m"])
	var hh := float(p["hip_half_m"])
	var ar := float(p["arm_r_m"])
	var tr := float(p["thigh_r_m"])
	var sr := float(p["shin_r_m"])
	var shoulder_y := torso_len - 0.05
	var ua := 0.17 * height
	var fa := 0.15 * height

	var root := Node3D.new()
	root.name = "AvatarBody"
	root.set_meta("preset_id", String(p["id"]))

	var pelvis := _node("pelvis", Vector3(0.0, hip_y, 0.0))
	root.add_child(pelvis)
	pelvis.add_child(_box("hips", Vector3(2.0 * (hh + tr * 0.7), 0.17, depth * 0.92), Vector3(0.0, -0.02, 0.0), shade))

	var torso := _node("torso", Vector3.ZERO)
	pelvis.add_child(torso)
	torso.add_child(_box("waist", Vector3(2.0 * ch * 0.82, 0.14, depth * 0.86), Vector3(0.0, 0.05, 0.0), shade))
	var chest_h := torso_len - 0.1
	torso.add_child(_box("chest", Vector3(2.0 * ch, chest_h, depth), Vector3(0.0, 0.09 + chest_h * 0.5, 0.0), shell))
	torso.add_child(_cyl("neck", 0.045, 0.05, NECK_M + 0.03, Vector3(0.0, torso_len + NECK_M * 0.5 - 0.005, 0.0), shade))
	# Vitals: emissive strips on the chest front (and on the left forearm for the preset that asks for it).
	var vitals := _node("vitals", Vector3.ZERO)
	vitals.set_meta("material", vit)
	torso.add_child(vitals)
	vitals.add_child(_box("vitals_chest", Vector3(ch * 1.3, 0.035, 0.012), Vector3(0.0, torso_len * 0.62, -depth * 0.5 - 0.004), vit))
	if bool(p["pack"]):
		torso.add_child(_box("pack", Vector3(0.3, 0.34, 0.12), Vector3(0.0, torso_len * 0.6, depth * 0.5 + 0.06), shade))
		torso.add_child(_box("pack_flap", Vector3(0.32, 0.05, 0.13), Vector3(0.0, torso_len * 0.6 + 0.19, depth * 0.5 + 0.06), trim))

	# Head: helmet dome, the dark visor glass on its front.
	var head := _node("head", Vector3(0.0, torso_len + NECK_M, 0.0))
	torso.add_child(head)
	var hws := float(p["head_width_scale"])
	head.add_child(_ball("helmet", Vector3(head_h * hws, head_h, head_h * 0.95), Vector3(0.0, head_h * 0.5, 0.0), shell))
	var vz := head_h * 0.25
	var rz := head_h * 0.95 * 0.5
	var visor := _ball("visor", Vector3(head_h * hws * float(p["visor_width_frac"]), head_h * float(p["visor_height_frac"]) * 1.4, vz * 2.0),
		Vector3(0.0, head_h * 0.52, -(rz - vz * 0.45)), glass)
	head.add_child(visor)

	# Arms: shoulder ball, upper arm, elbow, forearm, glove.
	var rings := int(p["rings"])
	for side in [-1.0, 1.0]:
		var sn := "l" if side < 0.0 else "r"
		var arm := _node("arm_" + sn, Vector3(side * (sh - ar), shoulder_y, 0.0))
		torso.add_child(arm)
		arm.add_child(_ball("shoulder_" + sn, Vector3.ONE * ar * 2.2, Vector3.ZERO, shell))
		arm.add_child(_cyl("upper_arm_" + sn, ar, ar * 0.85, ua, Vector3(0.0, -ua * 0.5, 0.0), shell))
		for k in range(rings):
			arm.add_child(_cyl("arm_ring_%s%d" % [sn, k], ar * 0.95 + 0.012, ar * 0.95 + 0.012, 0.025,
				Vector3(0.0, -ua * (0.3 + 0.35 * float(k)), 0.0), trim))
		var elbow := _node("elbow_" + sn, Vector3(0.0, -ua, 0.0))
		arm.add_child(elbow)
		elbow.add_child(_ball("elbow_ball_" + sn, Vector3.ONE * ar * 1.8, Vector3.ZERO, shade))
		elbow.add_child(_cyl("forearm_" + sn, ar * 0.85, ar * 0.7, fa, Vector3(0.0, -fa * 0.5, 0.0), shell))
		elbow.add_child(_ball("glove_" + sn, Vector3.ONE * ar * 2.0, Vector3(0.0, -fa - 0.02, 0.0), glove))
		if bool(p["vitals_arm"]) and side < 0.0:
			elbow.add_child(_box("vitals_arm_" + sn, Vector3(0.035, 0.1, 0.012), Vector3(0.0, -fa * 0.45, -ar * 0.85 - 0.004), vit))

	# Legs: thigh, knee, shin, ankle, boot, and the sole marker.
	for side in [-1.0, 1.0]:
		var sn2 := "l" if side < 0.0 else "r"
		var leg := _node("leg_" + sn2, Vector3(side * hh, 0.0, 0.0))
		pelvis.add_child(leg)
		leg.add_child(_cyl("thigh_" + sn2, tr, tr * 0.78, l1, Vector3(0.0, -l1 * 0.5, 0.0), shell))
		for k in range(rings):
			leg.add_child(_cyl("thigh_ring_%s%d" % [sn2, k], tr * 0.9 + 0.012, tr * 0.9 + 0.012, 0.025,
				Vector3(0.0, -l1 * (0.3 + 0.35 * float(k)), 0.0), trim))
		var knee := _node("knee_" + sn2, Vector3(0.0, -l1, 0.0))
		leg.add_child(knee)
		knee.add_child(_ball("knee_ball_" + sn2, Vector3.ONE * sr * 2.1, Vector3.ZERO, shade))
		knee.add_child(_cyl("shin_" + sn2, sr * 1.05, sr * 0.75, l2, Vector3(0.0, -l2 * 0.5, 0.0), shell))
		var ankle := _node("ankle_" + sn2, Vector3(0.0, -l2, 0.0))
		knee.add_child(ankle)
		ankle.add_child(_box("boot_" + sn2, Vector3(sr * 2.3, ah + 0.03, 0.28), Vector3(0.0, (0.03 - ah) * 0.5, -0.05), boot))
		ankle.add_child(_node("foot_" + sn2, Vector3(0.0, -ah, 0.0)))

	apply_pose(joints(root), AvatarGait.pose(AvatarGait.initial_state(), g))
	return root


## Every named joint and marker of a built body (name -> Node3D); a name the body lacks is simply absent.
static func joints(root: Node3D) -> Dictionary:
	var out := {}
	for n in ["pelvis", "torso", "head", "arm_l", "arm_r", "elbow_l", "elbow_r", "leg_l", "leg_r", "knee_l", "knee_r",
			"ankle_l", "ankle_r", "foot_l", "foot_r", "visor", "vitals"]:
		var f := root.find_child(n, true, false)
		if f != null:
			out[n] = f
	return out


## Writes a pose (AvatarGait.pose) onto the joints. Reads and writes nodes only; nothing is allocated.
static func apply_pose(j: Dictionary, pose: Dictionary) -> void:
	(j["pelvis"] as Node3D).position.y = float(pose["pelvis_y"])
	var torso := j["torso"] as Node3D
	torso.rotation = Vector3(-float(pose["lean"]), float(pose["twist"]), 0.0)
	torso.position.y = float(pose["breath_y"])
	(j["head"] as Node3D).rotation.x = float(pose["lean"]) * 0.8
	for s in ["l", "r"]:
		(j["leg_" + s] as Node3D).rotation.x = float(pose["hip_" + s])
		(j["knee_" + s] as Node3D).rotation.x = -float(pose["knee_" + s])
		(j["ankle_" + s] as Node3D).rotation.x = float(pose["ankle_" + s])
		(j["arm_" + s] as Node3D).rotation.x = float(pose["arm_" + s])
		(j["elbow_" + s] as Node3D).rotation.x = float(pose["elbow_" + s])
	var vm = (j["vitals"] as Node3D).get_meta("material")
	if vm is StandardMaterial3D:
		(vm as StandardMaterial3D).emission_energy_multiplier = 0.8 + 0.8 * float(pose["pulse"])
