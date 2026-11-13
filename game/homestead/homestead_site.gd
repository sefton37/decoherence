extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 576 S1 -- the homestead site generator: a pure, engine-free function from a site seed and two
## data files (site_template.json, starter_equipment.json) to a layout. The same seed and data always
## give the same layout; nothing here reads a clock, the global random generator or the scene.
## The seed is the assigned colonist's id hashed with FNV-1a (32 bit), so determinism IS the
## persistence: nothing is saved. The numbers (slab, rings, pod, cone, gaps) all come from the template
## and the items from the equipment file, so the design owner re-poses everything by editing data.
##
## Frame: metres, slab-local. x and z are measured from the slab centre; the site renders with that
## centre at the world origin (the engine's flat pad). A direction angle a points along
## (cos a, sin a) in (x, z). The hand-off pose carries both that angle and a `yaw` in the world
## camera's convention (the camera looks along (-sin yaw, -cos yaw)), which is what the world scene
## and the S2 cutscene consume: layout["handoff"] = {x, z, yaw, dir_angle}.

const DEFAULT_COLONIST_ID := "default-colonist"
const FNV_OFFSET := 2166136261
const FNV_PRIME := 16777619
const MASK32 := 0xFFFFFFFF
const MAX_ATTEMPTS := 160
const ITEM_TRIES := 600
## Items are sampled at most this far from the hand-off pose, and no nearer than their radius plus this.
const FAN_REACH_M := 7.0
const HANDOFF_CLEAR_M := 0.7
## The tallest item's nearest distance exceeds the lowest item's by this much (see the ramp in _attempt).
const RAMP_M := 3.5
## The generator keeps this share of the cone's half-angle free at the edge (the checker uses all of it).
const CONE_USE := 0.95
const EPS := 1e-6


## FNV-1a, 32 bit, over the UTF-8 bytes of the colonist's id.
static func site_seed_for(colonist_id: String) -> int:
	var h := FNV_OFFSET
	for b in colonist_id.to_utf8_buffer():
		h = ((h ^ int(b)) * FNV_PRIME) & MASK32
	return h


static func load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}


## A 32-bit xorshift stream, seeded per attempt. State lives in the object; nothing is global.
class Stream:
	var s: int = 1

	func _init(seed_v: int, attempt: int) -> void:
		var x := (seed_v ^ ((attempt * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF
		x = ((x ^ (x >> 16)) * 0x85EBCA6B) & 0xFFFFFFFF
		x = ((x ^ (x >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF
		x = x ^ (x >> 16)
		s = x if x != 0 else 0x1234567
		for _i in range(4):
			next_f()

	## Uniform in [0, 1).
	func next_f() -> float:
		s = (s ^ (s << 13)) & 0xFFFFFFFF
		s = s ^ (s >> 17)
		s = (s ^ (s << 5)) & 0xFFFFFFFF
		return float(s) / 4294967296.0


## The layout for one site seed, or {} when no placement satisfied the constraints within the attempt
## budget (the unit fuzz requires that to be never). `ground_fn(x, z) -> float` gives the ground
## height at the slab centre; it sets the layout's y values and never enters the digest.
static func generate(site_seed: int, template: Dictionary, equipment: Dictionary, ground_fn: Callable) -> Dictionary:
	var items_in: Array = equipment.get("items", [])
	for attempt in range(MAX_ATTEMPTS):
		var lay := _attempt(site_seed, attempt, template, items_in)
		if lay.is_empty():
			continue
		var y := float(ground_fn.call(0.0, 0.0)) + float(template["slab"]["lift_m"])
		lay["slab"]["y"] = y
		lay["attempt"] = attempt
		return lay
	return {}


static func _ring_outer(template: Dictionary) -> float:
	var out := 0.0
	for r in template["scorch_rings"]:
		out = maxf(out, float(r["radius_m"]) + float(r["width_m"]) * 0.5)
	return out


## Distance from point (px, pz) to the segment (ax, az)-(bx, bz).
static func _seg_dist(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
	var vx := bx - ax
	var vz := bz - az
	var l2 := vx * vx + vz * vz
	var u := 0.0
	if l2 > 0.0:
		u = clampf(((px - ax) * vx + (pz - az) * vz) / l2, 0.0, 1.0)
	return sqrt(pow(px - (ax + u * vx), 2.0) + pow(pz - (az + u * vz), 2.0))


static func _attempt(site_seed: int, attempt: int, template: Dictionary, items_in: Array) -> Dictionary:
	var rng := Stream.new(site_seed, attempt)
	var slab: Dictionary = template["slab"]
	var hx := float(slab["half_x_m"])
	var hz := float(slab["half_z_m"])
	var edge := float(template["edge_margin_m"])
	var jit := float(template["ring_center_jitter_m"])
	var gap := float(template["min_gap_m"])
	var lane := float(template["door_path_clear_m"])
	var cone := deg_to_rad(float(template["view_cone_deg"]))
	# Items stay this far off the facing line, so the follow camera's own character never hides one.
	var shadow := deg_to_rad(float(template["walker_shadow_deg"]))
	var pod_t: Dictionary = template["pod"]
	var pod_r := float(pod_t["footprint_r_m"])
	var ring_out := _ring_outer(template)

	# Pod: tucked into the slab's back corner (-x, -z) with its rings; slid along the back, door turned.
	var px := -(hx - ring_out - jit - edge)
	var pz := -(hz - ring_out - jit - edge) + rng.next_f() * float(pod_t["offset_range_m"])
	var theta := deg_to_rad(float(pod_t["door_base_deg"]) + (rng.next_f() * 2.0 - 1.0) * float(pod_t["yaw_jitter_deg"]))
	var dx := cos(theta)
	var dz := sin(theta)

	# Rings: centred on the pod, jittered ("it did not land exactly on the mark").
	var ja := rng.next_f() * TAU
	var jr := sqrt(rng.next_f()) * jit
	var rcx := px + cos(ja) * jr
	var rcz := pz + sin(ja) * jr
	var rings: Array = []
	for r in template["scorch_rings"]:
		rings.append({"x": rcx, "z": rcz, "radius_m": float(r["radius_m"]), "width_m": float(r["width_m"])})

	var door_x := px + dx * pod_r
	var door_z := pz + dz * pod_r
	var hand_x := door_x + dx * float(template["handoff"]["distance_m"])
	var hand_z := door_z + dz * float(template["handoff"]["distance_m"])
	if absf(hand_x) > hx - edge or absf(hand_z) > hz - edge:
		return {}

	# Items: biggest first, each sampled in the cone ahead of the hand-off pose.
	var order: Array = []
	for i in range(items_in.size()):
		order.append(i)
	var heights: Array = []
	for it in items_in:
		heights.append(shape_height_m(it["shape"]))
	# Tallest first: the tall items take the far part of the fan and the low ones the near part (the
	# ramp below), so from the hand-off pose a tall item never hides a low one behind it.
	order.sort_custom(func(a: int, b: int) -> bool:
		if heights[a] != heights[b]:
			return heights[a] > heights[b]
		return String(items_in[a]["id"]) < String(items_in[b]["id"]))
	var placed := {}
	var placed_list: Array = []
	for rank in range(order.size()):
		var ix: int = order[rank]
		var item: Dictionary = items_in[ix]
		var lift := (1.0 - float(rank) / float(maxi(order.size() - 1, 1))) * RAMP_M
		var r := float(item["footprint_r_m"])
		var found := false
		for _t in range(ITEM_TRIES):
			var dist := r + HANDOFF_CLEAR_M + lift + rng.next_f() * (FAN_REACH_M - RAMP_M)
			var off := (rng.next_f() * 2.0 - 1.0)
			var ang := theta + signf(off) * (shadow + absf(off) * (cone * CONE_USE - shadow))
			var x := hand_x + cos(ang) * dist
			var z := hand_z + sin(ang) * dist
			if absf(x) + r > hx - 0.02 or absf(z) + r > hz - 0.02:
				continue
			if sqrt(pow(x - px, 2.0) + pow(z - pz, 2.0)) < r + pod_r + gap:
				continue
			var clash := false
			for q in placed_list:
				if sqrt(pow(x - float(q[0]), 2.0) + pow(z - float(q[1]), 2.0)) < r + float(q[2]) + gap:
					clash = true
					break
			if clash:
				continue
			if _seg_dist(x, z, door_x, door_z, hand_x, hand_z) < r + lane * 0.5:
				continue
			if _seg_dist(px, pz, hand_x, hand_z, x, z) < pod_r:
				continue
			placed[ix] = {"id": String(item["id"]), "x": x, "z": z, "yaw": rng.next_f() * TAU, "footprint_r_m": r}
			placed_list.append([x, z, r])
			found = true
			break
		if not found:
			return {}
	var items_out: Array = []
	for i in range(items_in.size()):
		items_out.append(placed[i])

	return {
		"site_seed": site_seed,
		"template_version": int(template["template_version"]),
		"slab": {"half_x_m": hx, "half_z_m": hz, "thickness_m": float(slab["thickness_m"]), "y": 0.0},
		"pod": {"x": px, "z": pz, "yaw": theta, "footprint_r_m": pod_r, "height_m": float(pod_t["height_m"])},
		"rings": rings,
		"door": {"x": door_x, "z": door_z, "dir_angle": theta},
		"handoff": {"x": hand_x, "z": hand_z, "dir_angle": theta, "yaw": atan2(-dx, -dz)},
		"items": items_out,
	}


## Every constraint the layout promises, measured. Returns
## {violations: {total, out_of_slab, overlap, door_blocked, item_not_in_cone, item_behind_pod,
## handoff_off_slab, ring_off_slab}, hits: {pairs_checked, door_paths_checked, cone_checks}}.
static func check_layout(layout: Dictionary, template: Dictionary) -> Dictionary:
	var v := {"total": 0, "out_of_slab": 0, "overlap": 0, "door_blocked": 0, "item_not_in_cone": 0,
		"item_behind_pod": 0, "handoff_off_slab": 0, "ring_off_slab": 0}
	var hits := {"pairs_checked": 0, "door_paths_checked": 0, "cone_checks": 0}
	var hx := float(layout["slab"]["half_x_m"])
	var hz := float(layout["slab"]["half_z_m"])
	var gap := float(template["min_gap_m"])
	var lane := float(template["door_path_clear_m"])
	var cone := deg_to_rad(float(template["view_cone_deg"]))
	var pod: Dictionary = layout["pod"]
	var hand: Dictionary = layout["handoff"]
	var door: Dictionary = layout["door"]
	var bodies: Array = [{"x": pod["x"], "z": pod["z"], "r": pod["footprint_r_m"]}]
	for it in layout["items"]:
		bodies.append({"x": it["x"], "z": it["z"], "r": it["footprint_r_m"]})
	for b in bodies:
		if absf(float(b["x"])) + float(b["r"]) > hx + EPS or absf(float(b["z"])) + float(b["r"]) > hz + EPS:
			v["out_of_slab"] += 1
	for i in range(bodies.size()):
		for j in range(i + 1, bodies.size()):
			hits["pairs_checked"] += 1
			var d := sqrt(pow(float(bodies[i]["x"]) - float(bodies[j]["x"]), 2.0) + pow(float(bodies[i]["z"]) - float(bodies[j]["z"]), 2.0))
			if d < float(bodies[i]["r"]) + float(bodies[j]["r"]) + gap - EPS:
				v["overlap"] += 1
	hits["door_paths_checked"] += 1
	for it in layout["items"]:
		var ix := float(it["x"])
		var iz := float(it["z"])
		var ir := float(it["footprint_r_m"])
		if _seg_dist(ix, iz, float(door["x"]), float(door["z"]), float(hand["x"]), float(hand["z"])) < ir + lane * 0.5 - EPS:
			v["door_blocked"] += 1
		hits["cone_checks"] += 1
		var bearing := atan2(iz - float(hand["z"]), ix - float(hand["x"]))
		if absf(angle_difference(float(hand["dir_angle"]), bearing)) > cone + EPS:
			v["item_not_in_cone"] += 1
		if _seg_dist(float(pod["x"]), float(pod["z"]), float(hand["x"]), float(hand["z"]), ix, iz) < float(pod["footprint_r_m"]) - EPS:
			v["item_behind_pod"] += 1
	if absf(float(hand["x"])) > hx + EPS or absf(float(hand["z"])) > hz + EPS:
		v["handoff_off_slab"] += 1
	for r in layout["rings"]:
		var outer := float(r["radius_m"]) + float(r["width_m"]) * 0.5
		if absf(float(r["x"])) + outer > hx + EPS or absf(float(r["z"])) + outer > hz + EPS:
			v["ring_off_slab"] += 1
	for k in v.keys():
		if k != "total":
			v["total"] += v[k]
	return {"violations": v, "hits": hits}


## Item ids from the player's left to right as seen from the hand-off pose (the fuzz counts distinct orders).
static func item_order_by_bearing(layout: Dictionary) -> Array:
	var hand: Dictionary = layout["handoff"]
	var rows: Array = []
	for it in layout["items"]:
		var b := angle_difference(float(hand["dir_angle"]), atan2(float(it["z"]) - float(hand["z"]), float(it["x"]) - float(hand["x"])))
		rows.append([b, String(it["id"])])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var ids: Array = []
	for r in rows:
		ids.append(r[1])
	return ids


## A short stable digest of the layout's geometry (poses to a tenth of a millimetre; heights excluded,
## so the same colonist on different ground still has the same layout).
static func layout_digest(layout: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("v%d seed%d" % [int(layout["template_version"]), int(layout["site_seed"])])
	lines.append("slab %.4f %.4f" % [float(layout["slab"]["half_x_m"]), float(layout["slab"]["half_z_m"])])
	lines.append("pod %.4f %.4f %.4f" % [float(layout["pod"]["x"]), float(layout["pod"]["z"]), float(layout["pod"]["yaw"])])
	for r in layout["rings"]:
		lines.append("ring %.4f %.4f %.4f %.4f" % [float(r["x"]), float(r["z"]), float(r["radius_m"]), float(r["width_m"])])
	for it in layout["items"]:
		lines.append("item %s %.4f %.4f %.4f" % [String(it["id"]), float(it["x"]), float(it["z"]), float(it["yaw"])])
	lines.append("hand %.4f %.4f %.4f" % [float(layout["handoff"]["x"]), float(layout["handoff"]["z"]), float(layout["handoff"]["yaw"])])
	lines.append("door %.4f %.4f" % [float(layout["door"]["x"]), float(layout["door"]["z"])])
	return "\n".join(lines).sha256_text().substr(0, 16)


## The top of a shape above its base (the highest part's top).
static func shape_height_m(shape: Dictionary) -> float:
	var top := 0.0
	for p in shape["parts"]:
		var pos: Array = p["pos"]
		var size: Array = p["size"]
		var half := float(size[1]) * 0.5 if p["prim"] != "sphere" else float(size[0])
		top = maxf(top, float(pos[1]) + half)
	return top


## How far a shape's parts reach from the item's centre in the ground plane (the farthest corner or rim).
static func shape_reach_m(shape: Dictionary) -> float:
	var far := 0.0
	for p in shape["parts"]:
		var pos: Array = p["pos"]
		var size: Array = p["size"]
		var ox := float(pos[0])
		var oz := float(pos[2])
		var reach := 0.0
		if p["prim"] == "box":
			reach = sqrt(pow(absf(ox) + float(size[0]) * 0.5, 2.0) + pow(absf(oz) + float(size[2]) * 0.5, 2.0))
		else:
			reach = sqrt(ox * ox + oz * oz) + float(size[0])
		far = maxf(far, reach)
	return far
