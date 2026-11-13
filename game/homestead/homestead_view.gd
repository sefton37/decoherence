extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 576 S1 -- builds the homestead from a layout: the Foundation Slab, its scorch rings, the landed
## drop pod with its door standing open, and the eight starting items, all as primitive meshes.
## Provenance: procedural primitives only (boxes, cylinders, spheres and one generated ring mesh built in
## code from the data files); no imported mesh, texture or audio, nothing ported from elsewhere.
##
## The result is one Node3D "Homestead" at the world origin with named children the probe measures:
##   Slab, Rings/Ring_<i>, Pod (Floor, Skirt, Wall_<k>, Roof, Emblem_<k>, DoorPanel), Items/Item_<id>.
## The pod's local +x is its door; its node is yawed so that +x points along the layout's door
## direction. Every item's base sits exactly on the slab's top.

const RING_LIFT_M := 0.025  ## rings float this far above the slab top (a flat decal, no z-fight)
const RING_STEP_M := 0.004  ## and each outer ring a little higher than the one inside it
const RING_SEGMENTS := 72
const SKIRT_RATIO := 1.06
const FLOOR_THICKNESS_M := 0.12
const WALL_THICKNESS_M := 0.14
const EMBLEM_RADIUS_M := 0.34


static func build(layout: Dictionary, template: Dictionary, equipment: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Homestead"
	var colors: Dictionary = template["colors"]
	var slab: Dictionary = layout["slab"]
	var top := float(slab["y"])

	var slab_mi := _box("Slab", Vector3(float(slab["half_x_m"]) * 2.0, float(slab["thickness_m"]), float(slab["half_z_m"]) * 2.0),
		Vector3(0.0, top - float(slab["thickness_m"]) * 0.5, 0.0), Color(colors["slab"]))
	root.add_child(slab_mi)

	var rings := Node3D.new()
	rings.name = "Rings"
	root.add_child(rings)
	var ring_list: Array = layout["rings"]
	for i in range(ring_list.size()):
		var r: Dictionary = ring_list[i]
		var mi := MeshInstance3D.new()
		mi.name = "Ring_%d" % i
		mi.mesh = _annulus(float(r["radius_m"]) - float(r["width_m"]) * 0.5, float(r["radius_m"]) + float(r["width_m"]) * 0.5)
		var shade := float(i) * 0.12
		mi.material_override = _mat(Color(colors["scorch"]).lerp(Color(colors["slab"]), shade), true)
		mi.position = Vector3(float(r["x"]), top + RING_LIFT_M + RING_STEP_M * float(i), float(r["z"]))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rings.add_child(mi)

	root.add_child(_build_pod(layout, template))

	var items := Node3D.new()
	items.name = "Items"
	root.add_child(items)
	var defs := {}
	for d in equipment["items"]:
		defs[String(d["id"])] = d
	for it in layout["items"]:
		var node := Node3D.new()
		node.name = "Item_" + String(it["id"])
		node.position = Vector3(float(it["x"]), top, float(it["z"]))
		node.rotation.y = float(it["yaw"])
		for p in defs[String(it["id"])]["shape"]["parts"]:
			node.add_child(_part(p, colors))
		items.add_child(node)
	return root


static func _mat(c: Color, double_sided: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	if double_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _box(node_name: String, size: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = _mat(c)
	mi.position = pos
	return mi


static func _cyl(node_name: String, radius: float, height: float, pos: Vector3, c: Color, segments: int = 24) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segments
	m.rings = 1
	mi.mesh = m
	mi.material_override = _mat(c)
	mi.position = pos
	return mi


## One data part: box (size x,y,z), cyl (size radius,height) or sphere (size radius), centred at pos.
static func _part(p: Dictionary, colors: Dictionary) -> MeshInstance3D:
	var size: Array = p["size"]
	var pos: Array = p["pos"]
	var at := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	var c := Color(colors[String(p["color"])])
	var prim := String(p["prim"])
	if prim == "box":
		return _box("Part", Vector3(float(size[0]), float(size[1]), float(size[2])), at, c)
	if prim == "cyl":
		return _cyl("Part", float(size[0]), float(size[1]), at, c)
	var mi := MeshInstance3D.new()
	mi.name = "Part"
	var s := SphereMesh.new()
	s.radius = float(size[0])
	s.height = float(size[0]) * 2.0
	mi.mesh = s
	mi.material_override = _mat(c)
	mi.position = at
	return mi


## A flat ring (annulus) in the xz plane, facing up, built from triangles.
static func _annulus(inner: float, outer: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for i in range(RING_SEGMENTS):
		var a0 := TAU * float(i) / float(RING_SEGMENTS)
		var a1 := TAU * float(i + 1) / float(RING_SEGMENTS)
		var i0 := Vector3(cos(a0) * inner, 0.0, sin(a0) * inner)
		var o0 := Vector3(cos(a0) * outer, 0.0, sin(a0) * outer)
		var i1 := Vector3(cos(a1) * inner, 0.0, sin(a1) * inner)
		var o1 := Vector3(cos(a1) * outer, 0.0, sin(a1) * outer)
		for v in [i0, o0, o1, i0, o1, i1]:
			st.add_vertex(v)
	return st.commit()


static func _build_pod(layout: Dictionary, template: Dictionary) -> Node3D:
	var colors: Dictionary = template["colors"]
	var pt: Dictionary = template["pod"]
	var pod: Dictionary = layout["pod"]
	var r := float(pt["footprint_r_m"])
	var height := float(pt["height_m"])
	var roof_h := float(pt["roof_height_m"])
	var wall_h := height - roof_h
	var n := int(pt["wall_panels"])
	var half := PI / float(n)
	var hull := Color(colors["hull"])

	var node := Node3D.new()
	node.name = "Pod"
	node.position = Vector3(float(pod["x"]), float(layout["slab"]["y"]), float(pod["z"]))
	node.rotation.y = -float(pod["yaw"])  # local +x (the door) points along the layout's door direction

	node.add_child(_cyl("Floor", r, FLOOR_THICKNESS_M, Vector3(0.0, FLOOR_THICKNESS_M * 0.5, 0.0), Color(colors["hull_shade"])))
	node.add_child(_cyl("Skirt", r * SKIRT_RATIO, 0.3, Vector3(0.0, 0.15, 0.0), Color(colors["underside"])))

	# Walls: an n-sided drum of flat panels with the door-side panel left out (the doorway).
	var panel_w := 2.0 * r * sin(half) * 1.02
	var radial := r * cos(half) - WALL_THICKNESS_M * 0.5
	var wall_y := FLOOR_THICKNESS_M + (wall_h - FLOOR_THICKNESS_M) * 0.5
	for k in range(1, n):
		var a := TAU * float(k) / float(n)
		var w := _box("Wall_%d" % k, Vector3(WALL_THICKNESS_M, wall_h - FLOOR_THICKNESS_M, panel_w),
			Vector3(cos(a) * radial, wall_y, sin(a) * radial), hull)
		w.rotation.y = -a
		node.add_child(w)

	var roof := MeshInstance3D.new()
	roof.name = "Roof"
	var rm := CylinderMesh.new()
	rm.bottom_radius = r * SKIRT_RATIO
	rm.top_radius = 0.35
	rm.height = roof_h
	rm.radial_segments = n
	rm.rings = 1
	roof.mesh = rm
	roof.material_override = _mat(hull)
	roof.position = Vector3(0.0, wall_h + roof_h * 0.5, 0.0)
	roof.rotation.y = half
	node.add_child(roof)

	# The red hexagon of the Empire livery on two hull panels away from the door.
	for k in [3, n - 3]:
		var a2 := TAU * float(k) / float(n)
		var holder := Node3D.new()
		holder.name = "Emblem_%d" % k
		var out := r * cos(half) + 0.005
		holder.position = Vector3(cos(a2) * out, wall_h * 0.58, sin(a2) * out)
		holder.rotation.y = -a2
		var hex := _cyl("Hex", EMBLEM_RADIUS_M, 0.02, Vector3.ZERO, Color(colors["emblem"]), 6)
		hex.rotation_degrees.z = 90.0
		holder.add_child(hex)
		node.add_child(holder)

	# The door: hinged at the doorway's +z edge, swung open outward (closed it would span the doorway).
	var door_w := 2.0 * r * sin(half)
	var hinge := Node3D.new()
	hinge.name = "DoorPanel"
	hinge.position = Vector3(r * cos(half) + 0.02, 0.0, r * sin(half))
	hinge.rotation.y = -deg_to_rad(float(pt["door_open_deg"]))
	var leaf := _box("Leaf", Vector3(0.08, float(pt["door_height_m"]), door_w * 0.97),
		Vector3(0.0, float(pt["door_height_m"]) * 0.5 + FLOOR_THICKNESS_M, -door_w * 0.485), Color(colors["hull_shade"]))
	hinge.add_child(leaf)
	node.add_child(hinge)
	return node


## The world-space bounding box of every mesh under `root` (the root must be inside the tree).
static func world_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box
