extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 580 geometric richness metrics, shared by tools/scenic/richness_probe.gd (the three bench poses) and
## tools/scenic/scenic_shots.gd (every scenic shot). It only READS: rays against the engine's ground and the
## multimeshes the game's streamer loaded. It builds nothing.
##
##   far_ground_p90_m      90th percentile of the distance where a frame ray first meets ground, counting only
##                         hits that fog hides at most 80 percent (opacity 1 - exp(-(density * d)^2))
##   tree_far_p95_m        95th percentile of the distance of drawn trees in the frustum, same fog filter
##   unloaded_visible_hit  frame-grid rays whose fog-visible ground hit lies in a chunk that is not loaded
##   species_ge10          forms with at least 10 drawn instances in the frustum
##   bare_near_frac        share of ground hits within 100 m with no flora or understory instance within 1.5 m
## "Drawn" honours the game's own distance cull (visibility_range_end on a chunk's multimesh, measured to the
## centre of its bounding box, which is how the engine applies it).

const COLS := 64
const ROWS := 36
const MAX_FOG := 0.8  ## content hidden more than this by fog does not count as visible
const WORLD_HALF_M := 112.0
const BARE_RANGE_M := 100.0
const BARE_RADIUS_M := 1.5
const SPECIES_MIN := 10

var _cam: Camera3D
var _streamer
var _size: Vector2i


func _init(cam: Camera3D, streamer, size: Vector2i) -> void:
	_cam = cam
	_streamer = streamer
	_size = size


## Distance at which fog hides MAX_FOG of the scene for an exp-squared density.
static func visible_limit_m(density: float) -> float:
	return sqrt(-log(1.0 - MAX_FOG)) / density


## The record fields for the camera as it stands, for the fog density the frame is drawn with.
func measure(density: float) -> Dictionary:
	var hits := _ground_hits(visible_limit_m(density))
	var inst := _collect_instances(density)
	return {
		"far_ground_p90_m": snappedf(_percentile(hits["dist"], 0.90), 0.01),
		"unloaded_visible_hit": hits["unloaded"],
		"ground_hit_rays": hits["dist"].size(),  # of ROWS x COLS: rays that meet ground inside the fog limit
		"ground_past_fog_rays": hits["past_fog"],  # rays still above ground at the fog limit (sky, or ground the fog hides)
		"far_ground_max_m": snappedf(_percentile(hits["dist"], 1.0), 0.01),
		"tree_far_p95_m": snappedf(_percentile(inst["tree_dist"], 0.95), 0.01),
		"species_ge10": _count_ge(inst["form_counts"], SPECIES_MIN),
		"bare_near_frac": snappedf(_bare_near(hits["near_pts"], inst["grid"]), 0.0001),
	}


func _percentile(vals: Array, q: float) -> float:
	if vals.is_empty():
		return 0.0
	var a := vals.duplicate()
	a.sort()
	var i := clampi(int(ceil(q * float(a.size()))) - 1, 0, a.size() - 1)
	return float(a[i])


func _count_ge(counts: Dictionary, n: int) -> int:
	var k := 0
	for v in counts.values():
		if int(v) >= n:
			k += 1
	return k


## Marches a coarse grid of pixel rays against the engine's ground. Returns the fog-visible hit distances,
## the number of those whose chunk is not loaded, and the hit points within BARE_RANGE_M (loaded chunks).
func _ground_hits(limit_m: float) -> Dictionary:
	var dist: Array = []
	var near_pts: Array = []
	var unloaded := 0
	var past_fog := 0
	var o := _cam.global_position
	for r in range(ROWS):
		for c in range(COLS):
			var px := Vector2((float(c) + 0.5) / float(COLS) * float(_size.x), (float(r) + 0.5) / float(ROWS) * float(_size.y))
			var d := _cam.project_ray_normal(px)
			var t := 0.5
			var resolved := false
			while t < limit_m:
				var q := o + d * t
				if absf(q.x) > WORLD_HALF_M or absf(q.z) > WORLD_HALF_M:
					resolved = true
					break
				if q.y < StalagWorld.ground_envelope_at(q.x, q.z, INF):
					dist.append(t)
					var loaded: bool = _streamer.chunk_node(_streamer.chunk_of(q)) != null
					if not loaded:
						unloaded += 1
					elif t <= BARE_RANGE_M:
						near_pts.append(q)
					resolved = true
					break
				t += 0.5 if t < 40.0 else 1.0
			if not resolved:
				past_fog += 1
	return {"dist": dist, "near_pts": near_pts, "unloaded": unloaded, "past_fog": past_fog}


## Reads every loaded chunk's multimeshes: drawn tree distances, per-form instance counts in the frustum, and
## a 1.5 m hash grid of the flora and understory instances that are drawn.
func _collect_instances(density: float) -> Dictionary:
	var tree_dist: Array = []
	var form_counts := {}
	var grid := {}
	var cam := _cam.global_position
	for coord in _streamer.chunk_coords():
		var chunk: Node = _streamer.chunk_node(coord)
		for group in chunk.get_children():
			var kind := str(group.name)
			if kind != "Trees" and kind != "Flora" and kind != "Understory":
				continue
			for m in group.get_children():
				var mmi := m as MultiMeshInstance3D
				if mmi == null or _culled(mmi, cam):
					continue
				var nm := str(mmi.name)
				var form := nm
				if kind == "Trees":
					if not nm.ends_with("_trunk"):
						continue
					form = "tree:" + nm.trim_suffix("_trunk")
				elif kind == "Understory":
					form = "under:" + nm.trim_suffix("_muted").trim_suffix("_vivid")
				else:
					form = "flora:" + nm
				var mm := mmi.multimesh
				var buf: PackedFloat32Array = mm.buffer
				var xf := mmi.global_transform
				var n := mm.instance_count
				var seen := 0
				for i in range(n):
					var b := i * 12
					var gp := xf * Vector3(buf[b + 3], buf[b + 7], buf[b + 11])
					if kind != "Trees":
						var key := _cell_key(gp.x, gp.z)
						if grid.has(key):
							grid[key].append(Vector2(gp.x, gp.z))
						else:
							grid[key] = [Vector2(gp.x, gp.z)]
					if not _cam.is_position_in_frustum(gp):
						continue
					seen += 1
					if kind == "Trees":
						var dd := cam.distance_to(gp)
						var f := 1.0 - exp(-pow(density * dd, 2.0))
						if f <= MAX_FOG:
							tree_dist.append(dd)
				form_counts[form] = int(form_counts.get(form, 0)) + seen
	return {"tree_dist": tree_dist, "form_counts": form_counts, "grid": grid}


## The game's own distance cull: a multimesh whose centre is past its visibility_range_end is not drawn.
func _culled(mmi: MultiMeshInstance3D, cam: Vector3) -> bool:
	if mmi.visibility_range_end <= 0.0:
		return false
	var center := mmi.global_transform * mmi.get_aabb().get_center()
	return center.distance_to(cam) > mmi.visibility_range_end


func _cell_key(x: float, z: float) -> int:
	return int(floor(x / BARE_RADIUS_M)) * 100003 + int(floor(z / BARE_RADIUS_M))


func _bare_near(pts: Array, grid: Dictionary) -> float:
	if pts.is_empty():
		return 0.0
	var bare := 0
	for q in pts:
		var cx := int(floor(q.x / BARE_RADIUS_M))
		var cz := int(floor(q.z / BARE_RADIUS_M))
		var found := false
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var key := (cx + dx) * 100003 + (cz + dz)
				if grid.has(key):
					for v in grid[key]:
						if Vector2(q.x, q.z).distance_to(v) <= BARE_RADIUS_M:
							found = true
							break
				if found:
					break
			if found:
				break
		if not found:
			bare += 1
	return float(bare) / float(pts.size())
