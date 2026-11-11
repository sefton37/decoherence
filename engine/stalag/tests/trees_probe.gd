extends SceneTree
## Spec #549 trees, wildflowers, shrubs and grass-thinning probe (headless, no GPU). It only MEASURES --
## tests/verify_stalag_trees.sh pairs it with the fresh JS oracle (tools/baseline/js_trees_oracle.mjs)
## and the DoD's jq does the judging.
##
## Env: TREES_PROBE_RAW     output JSON path (required)
##      TREES_MUTATE        none | lid_shift | flood_ignore | clearing_off | salt_swap | grove_off | landmark_lean |
##                          hue_exempt | euler_order | flower_floor | sensor_gap_off | trunk_gate_off |
##                          flower_gate_off | thin_off | thin_all | tier_swap | asset_flip | u_asset_flip
##
## Record (engine side only; the wrapper adds the JS side and the epoch):
##   {classes, world, placement{...}, flowers{...}, shrubs{...}, meadow_thinned{...}}
## Hashes are sha256 over raw little-endian dumps, in the orders the oracle uses (see the oracle header).

const TREE_MUT := ["lid_shift", "flood_ignore", "clearing_off", "salt_swap", "grove_off", "landmark_lean", "hue_exempt", "euler_order"]
const UNDER_MUT := ["flower_floor", "sensor_gap_off", "trunk_gate_off", "flower_gate_off", "thin_off", "thin_all", "tier_swap"]
const LANDMARKS := ["elder-pine", "sensor-pine"]
const ROUND := ["broadleaf-lump", "twin-trunk", "scrub-birch"]
const DEADWOOD := ["standing-snag", "cut-stump"]
const PATCH := ["flower-spike-lupine", "flower-dot-forgetmenot", "flower-cushion-campion", "flower-cup-poppy", "flower-ray-arnica"]
const GRASS := ["tuft-billboard-baseline", "tuft-billboard-bladed", "cover-billboard-creep"]
const TreeAssets := preload("res://game/world/tree_assets.gd")
const UnderstoryAssets := preload("res://game/world/understory_assets.gd")
const CHUNK_LO := -5
const CHUNK_HI := 5

var _sf := 1.0
var _mutation := "none"


func _fail(msg: String) -> void:
	push_error("trees_probe: " + msg)
	quit(2)


func _sha(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode()


func _initialize() -> void:
	var raw := OS.get_environment("TREES_PROBE_RAW")
	_mutation = OS.get_environment("TREES_MUTATE")
	if _mutation.is_empty():
		_mutation = "none"
	for c in ["StalagTrees", "StalagUnderstory", "StalagFlora"]:
		if raw.is_empty() or not ClassDB.class_exists(c):
			_fail("TREES_PROBE_RAW required and %s must be loaded" % c)
			return
	_sf = StalagWorld.get_sf()
	if TREE_MUT.has(_mutation):
		StalagTrees.set_mutation(_mutation)
	if UNDER_MUT.has(_mutation):
		StalagUnderstory.set_mutation(_mutation)

	StalagWorld.start_plan()
	while StalagWorld.plan_status() == 1:
		OS.delay_msec(20)
	if StalagWorld.plan_status() != 2:
		_fail("plan solve failed: " + StalagWorld.plan_error())
		return

	var out := {}
	out["classes"] = {"StalagTrees": true, "StalagWind": ClassDB.class_exists("StalagWind"), "StalagFlora": true, "StalagUnderstory": true}
	out["world"] = {"seed": StalagWorld.get_seed(), "extent": StalagWorld.get_extent(), "chunk_m": StalagWorld.get_chunk_m()}
	var t0 := Time.get_ticks_msec()
	var trees := _trees()
	out["placement"] = trees["record"]
	var tree_roots: Array = trees["roots"]
	out["flowers"] = _flowers()
	out["shrubs"] = _shrubs(tree_roots, out["flowers"].get("_lid_set", {}))
	out["flowers"].erase("_lid_set")
	out["meadow_thinned"] = _meadow()
	out["assets"] = _assets()
	out["understory_assets"] = _understory_assets()
	out["probe_ms"] = Time.get_ticks_msec() - t0
	var f := FileAccess.open(raw, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	quit(0)


# ---------------------------------------------------------------- lids and water, shared by every class
func _terrace(cx: int, cz: int) -> float:
	return floor(StalagWorld.surface_height(float(cx), float(cz)) / 4.0) * 4.0


# terrace height of the lid whose centre is (lx, lz) metres, or NaN when no lid is centred there.
func _lid_height(lx: float, lz: float) -> float:
	var cxf := lx / _sf - 2.0
	var czf := lz / _sf - 2.0
	var cx := int(round(cxf))
	var cz := int(round(czf))
	if absf(cxf - cx) > 1e-6 or absf(czf - cz) > 1e-6:
		return NAN
	if posmod(cz, 4) != 0 or posmod(cx - cz, 4) != 0:
		return NAN
	var half := 4.0 * StalagWorld.get_extent() * _sf
	var hh := _terrace(cx, cz)
	for d in [[4, 0], [0, 4], [4, 4], [2, 2]]:
		var px: int = cx + d[0]
		var pz: int = cz + d[1]
		if absf(px * _sf) > half + 1e-9 or absf(pz * _sf) > half + 1e-9:
			return NAN
		if _terrace(px, pz) != hh:
			return NAN
	return hh


# {off_lid, flooded_or_course}: independent lid and column checks over each instance's own lid
# centre. `stride` is doubles per instance; x, y, z at 0..2; the lid centre at lid_at, lid_at + 1.
func _lid_checks(arrs: Array, stride: int, lid_at: int, jitter: float) -> Dictionary:
	var seen := {}
	var off_lid := 0
	var fl_course := 0
	var dry := StalagWorld.water_dry_sentinel()
	for a: PackedFloat64Array in arrs:
		for i in range(a.size() / stride):
			var o := i * stride
			var x := a[o]
			var y := a[o + 1]
			var z := a[o + 2]
			var lx := a[o + lid_at]
			var lz := a[o + lid_at + 1]
			var key := Vector2(lx, lz)
			if not seen.has(key):
				var gx := int(floor(lx / 0.5))
				var gz := int(floor(lz / 0.5))
				var wet: bool = StalagWorld.is_flooded(gx, gz) or StalagWorld.course_level_at(gx, gz) != dry
				seen[key] = [_lid_height(lx, lz), wet]
			var info: Array = seen[key]
			var h: float = info[0]
			var bad := is_nan(h) or absf(x - lx) > jitter + 1e-9 or absf(z - lz) > jitter + 1e-9 or y <= 0.0
			if not bad and absf(y - (h + 2.0) * _sf) > 1e-9:
				bad = true
			if bad:
				off_lid += 1
			if info[1]:
				fl_course += 1
	return {"off_lid": off_lid, "flooded_or_course": fl_course}


# double-precision hypotenuse (Vector2.length is float32)
func _hyp(x: float, z: float) -> float:
	return sqrt(x * x + z * z)


func _stddev(xs: Array) -> float:
	if xs.is_empty():
		return 0.0
	var m := 0.0
	for x in xs:
		m += x
	m /= xs.size()
	var s := 0.0
	for x in xs:
		s += (x - m) * (x - m)
	return sqrt(s / xs.size())


func _chunk_range() -> Array:
	var r := []
	for cz in range(CHUNK_LO, CHUNK_HI + 1):
		for cx in range(CHUNK_LO, CHUNK_HI + 1):
			r.append(Vector2i(cx, cz))
	return r


func _in_ring(c: Vector2i) -> bool:
	return c.x >= -2 and c.x <= 2 and c.y >= -2 and c.y <= 2


# ---------------------------------------------------------------- trees
func _trees() -> Dictionary:
	var ids: PackedStringArray = StalagTrees.form_ids()
	var g1: Dictionary = StalagTrees.place_global()
	var g2: Dictionary = StalagTrees.place_global()
	var forms := []
	var total := 0
	var det_equal := true
	var arrs := []
	var within := 0
	var nearest := INF
	var roots := []
	for id in ids:
		var a: PackedFloat64Array = g1[id]
		var ba := a.to_byte_array()
		forms.append({"id": id, "gd_count": a.size() / 14, "gd_hash": _sha(ba)})
		total += a.size() / 14
		arrs.append(a)
		if _sha((g2[id] as PackedFloat64Array).to_byte_array()) != _sha(ba):
			det_equal = false
		for i in range(a.size() / 14):
			var d := _hyp(a[i * 14], a[i * 14 + 2])
			nearest = minf(nearest, d)
			if d < 8.0:
				within += 1
			roots.append(Vector2(a[i * 14], a[i * 14 + 2]))
	var lc := _lid_checks(arrs, 14, 12, 0.15)

	# per-chunk: union hash, matrix and colour hashes (chunks ascending by (cz, cx)), the ring
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	var mx_ctx := []
	var col_ctx := []
	for i in range(ids.size()):
		var m := HashingContext.new()
		m.start(HashingContext.HASH_SHA256)
		mx_ctx.append(m)
		var c := HashingContext.new()
		c.start(HashingContext.HASH_SHA256)
		col_ctx.append(c)
	var sum := 0
	var nchunks := 0
	var ring_per := []
	ring_per.resize(ids.size())
	ring_per.fill(0)
	var ring_chunks := 0
	var ring_total := 0
	for c in _chunk_range():
		var d: Dictionary = StalagTrees.place_chunk(c.x, c.y)
		var mats: Dictionary = StalagTrees.matrices_chunk(c.x, c.y)
		var cols: Dictionary = StalagTrees.colors_chunk(c.x, c.y)
		var any := false
		for fi in range(ids.size()):
			var id: String = ids[fi]
			var a: PackedFloat64Array = d[id]
			if a.size() > 0:
				any = true
				sum += a.size() / 14
				hc.update(a.to_byte_array())
				(mx_ctx[fi] as HashingContext).update((mats[id] as PackedFloat32Array).to_byte_array())
				if (cols[id] as PackedFloat32Array).size() > 0: # the dead forms carry no crown colours
					(col_ctx[fi] as HashingContext).update((cols[id] as PackedFloat32Array).to_byte_array())
				if _in_ring(c):
					ring_per[fi] += a.size() / 14
					ring_total += a.size() / 14
		if any:
			nchunks += 1
			if _in_ring(c):
				ring_chunks += 1
	for fi in range(ids.size()):
		forms[fi]["mx_gd_hash"] = (mx_ctx[fi] as HashingContext).finish().hex_encode()
		forms[fi]["col_gd_hash"] = (col_ctx[fi] as HashingContext).finish().hex_encode()
	var ring_form := {}
	for fi in range(ids.size()):
		ring_form[ids[fi]] = ring_per[fi]

	# ported checks (tree-placement-jitter.test.mjs and tree-forest-mix.test.mjs, at the engine's world)
	var all_forms := true
	for f in forms:
		if f["gd_count"] <= 0:
			all_forms = false
	var jit_ok := true
	var wj := []
	var hj := []
	var vj := []
	var hue := []
	var lm_hue := []
	var lm_upright := true
	var leaning := 0
	var others := 0
	for fi in range(ids.size()):
		var a: PackedFloat64Array = arrs[fi]
		var landmark: bool = LANDMARKS.has(ids[fi])
		for i in range(a.size() / 14):
			var o := i * 14
			if a[o + 6] < 0.85 or a[o + 6] > 1.15 or a[o + 7] < 0.90 or a[o + 7] > 1.12 or a[o + 10] < 0.92 or a[o + 10] > 1.08 or a[o + 11] < -4.0 or a[o + 11] > 4.0:
				jit_ok = false
			if _hyp(a[o + 8], a[o + 9]) > 0.0698 + 1e-9:
				jit_ok = false
			wj.append(a[o + 6])
			hj.append(a[o + 7])
			vj.append(a[o + 10])
			hue.append(a[o + 11])
			if landmark:
				lm_hue.append(a[o + 11])
				if a[o + 8] != 0.0 or a[o + 9] != 0.0:
					lm_upright = false
			else:
				others += 1
				if a[o + 8] != 0.0 or a[o + 9] != 0.0:
					leaning += 1
	jit_ok = jit_ok and _stddev(wj) > 0.02 and _stddev(hj) > 0.02 and _stddev(vj) > 0.02 and _stddev(hue) > 0.3
	var upright_ok: bool = lm_upright and others > 0 and float(leaning) / others > 0.5
	var crown := 0
	var round_n := 0
	for fi in range(ids.size()):
		var n: int = forms[fi]["gd_count"]
		if DEADWOOD.has(ids[fi]):
			continue
		crown += n
		if ROUND.has(ids[fi]):
			round_n += n
	var rf := float(round_n) / crown if crown > 0 else 0.0
	var mix_ok: bool = total == 4168 and rf >= 0.30 and rf <= 0.50

	return {
		"record": {
			"total_gd": total,
			"determinism_equal": det_equal,
			"within_clearing": within,
			"clearing_m": 8.0,
			"nearest_root_m_gd": nearest,
			"flooded_or_course": lc["flooded_or_course"],
			"off_lid": lc["off_lid"],
			"forms": forms,
			"chunks": {"count": nchunks, "gd_union_hash": hc.finish().hex_encode(), "sum": sum},
			"ring": {"rule": "lid_centre", "coord_min": -2, "coord_max": 2, "chunks": 25, "trees_gd": ring_total, "chunks_with_trees_gd": ring_chunks, "per_form_gd": ring_form},
			"ported_checks": {
				"CLEARING": within == 0,
				"DETERMINISM": det_equal,
				"EVERY_FORM_KEY": ids.size() == 12 and all_forms,
				"FOREST_MIX": mix_ok,
				"HUE_NO_EXEMPTION": lm_hue.size() > 0 and _stddev(lm_hue) > 0.3,
				"JITTER_BOUNDS": jit_ok,
				"LANDMARK_UPRIGHT": upright_ok,
				"LID_ONLY": total > 0 and lc["off_lid"] == 0,
			},
		},
		"roots": roots,
	}


# ---------------------------------------------------------------- wildflowers
func _grid_key(p: Vector2, cell: float) -> Vector2i:
	return Vector2i(int(floor(p.x / cell)), int(floor(p.y / cell)))


func _flowers() -> Dictionary:
	var ids: PackedStringArray = StalagUnderstory.flower_ids()
	var g1: Dictionary = StalagUnderstory.flowers_global()
	StalagUnderstory.set_mutation(_mutation if UNDER_MUT.has(_mutation) else "none") # drop the cache: a real second computation
	var g2: Dictionary = StalagUnderstory.flowers_global()
	var forms := []
	var total := 0
	var det_equal := true
	var arrs := []
	var lid_set := {}
	var sensors := []
	var nearest := INF
	var all_nonempty := true
	var tiers := {"muted": 0, "vivid": 0}
	var patch := {}
	for id in ids:
		var a: PackedFloat64Array = g1[id]
		var muted := 0
		var vivid := 0
		for i in range(a.size() / 9):
			if a[i * 9 + 7] > 0.5:
				vivid += 1
			else:
				muted += 1
			lid_set[Vector2(a[i * 9 + 5], a[i * 9 + 6])] = true
		forms.append({"id": id, "gd_count": a.size() / 9, "gd_hash": _sha(a.to_byte_array()), "muted_gd": muted, "vivid_gd": vivid})
		total += a.size() / 9
		arrs.append(a)
		tiers["muted"] += muted
		tiers["vivid"] += vivid
		if a.size() == 0:
			all_nonempty = false
		if _sha((g2[id] as PackedFloat64Array).to_byte_array()) != _sha(a.to_byte_array()):
			det_equal = false
	for fi in range(ids.size()):
		var a: PackedFloat64Array = arrs[fi]
		if ids[fi] == "flower-sensor-bloom":
			for i in range(a.size() / 9):
				sensors.append(Vector2(a[i * 9], a[i * 9 + 2]))
		if PATCH.has(ids[fi]):
			var pts := []
			for i in range(a.size() / 9):
				pts.append(Vector2(a[i * 9], a[i * 9 + 2]))
			patch[ids[fi]] = pts
	var min_gap := INF
	for i in range(sensors.size()):
		for j in range(i + 1, sensors.size()):
			min_gap = minf(min_gap, _hyp(sensors[i].x - sensors[j].x, sensors[i].y - sensors[j].y))
	var lc := _lid_checks(arrs, 9, 5, 0.15)

	# ring, chunks
	var ring_per := []
	ring_per.resize(ids.size())
	ring_per.fill(0)
	var ring_total := 0
	var ring_chunks := 0
	var chunk_sum := 0
	for c in _chunk_range():
		var d: Dictionary = StalagUnderstory.flowers_chunk(c.x, c.y)
		var any := false
		for fi in range(ids.size()):
			var a: PackedFloat64Array = d[ids[fi]]
			chunk_sum += a.size() / 9
			if a.size() > 0:
				any = true
			if _in_ring(c):
				ring_per[fi] += a.size() / 9
				ring_total += a.size() / 9
				for i in range(a.size() / 9):
					nearest = minf(nearest, _hyp(a[i * 9], a[i * 9 + 2]))
		if any and _in_ring(c):
			ring_chunks += 1
	var ring_form := {}
	for fi in range(ids.size()):
		ring_form[ids[fi]] = ring_per[fi]

	# lone: a patch instance with no same-species neighbour within 3 m; dominance within 4 m
	var lone := false
	var dom_ok := 0
	var dom_total := 0
	var grid := {}
	for sp in patch.keys():
		for p: Vector2 in patch[sp]:
			var k := _grid_key(p, 4.0)
			if not grid.has(k):
				grid[k] = []
			grid[k].append([p, sp])
	for sp in patch.keys():
		for p: Vector2 in patch[sp]:
			var k := _grid_key(p, 4.0)
			var same := 0
			var other := 0
			var near_same3 := false
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					var cell: Array = grid.get(Vector2i(k.x + dx, k.y + dz), [])
					for e in cell:
						var q: Vector2 = e[0]
						if q == p:
							continue
						var dd := _hyp(p.x - q.x, p.y - q.y)
						if dd <= 4.0:
							if e[1] == sp:
								same += 1
							else:
								other += 1
						if e[1] == sp and dd <= 3.0:
							near_same3 = true
			if not near_same3:
				lone = true
			if same + other > 0:
				dom_total += 1
				if same > other:
					dom_ok += 1
	var dom_frac := float(dom_ok) / dom_total if dom_total > 0 else 0.0
	var all_n: int = tiers["muted"] + tiers["vivid"]
	var vfrac := float(tiers["vivid"]) / all_n if all_n > 0 else -1.0

	return {
		"total_gd": total,
		"forms": forms,
		"lid_keys_gd": int(g1["_lid_keys"]),
		"off_lid": lc["off_lid"],
		"flooded_or_course": lc["flooded_or_course"],
		"sensor_min_gap_m": min_gap if min_gap != INF else 1.0e9,
		"nearest_root_m_ring_gd": nearest,
		"chunk_sum": chunk_sum,
		"ring": {"total_gd": ring_total, "per_form_gd": ring_form, "chunks_with_gd": ring_chunks},
		"ported_checks": {
			"FLOWER_DETERMINISM": det_equal,
			"FLOWER_EVERY_KEY": ids.size() == 7 and all_nonempty,
			"FLOWER_LID_ONLY": total > 0 and lc["off_lid"] == 0,
			"FLOWER_LONE_PRESENT": lone,
			"FLOWER_NO_WATER": total > 0 and lc["flooded_or_course"] == 0,
			"FLOWER_SENSOR_FLOOR_AND_GAP": sensors.size() >= 1 and (sensors.size() < 2 or min_gap >= 6.0),
			"FLOWER_TIER_MIX": tiers["muted"] > 0 and tiers["vivid"] >= 5 and vfrac >= 0.10 and vfrac <= 0.45,
			"FLOWER_ZONES_DISJOINT": dom_total >= 10 and dom_frac >= 0.60,
		},
		"_lid_set": lid_set,
	}


# ---------------------------------------------------------------- shrubs
func _shrubs(tree_roots: Array, flower_lids: Dictionary) -> Dictionary:
	var ids: PackedStringArray = StalagUnderstory.shrub_ids()
	var g1: Dictionary = StalagUnderstory.shrubs_global()
	StalagUnderstory.set_mutation(_mutation if UNDER_MUT.has(_mutation) else "none")
	var g2: Dictionary = StalagUnderstory.shrubs_global()
	var forms := []
	var total := 0
	var det_equal := true
	var arrs := []
	var all_nonempty := true
	var within := 0
	var in_flower := 0
	var min_tree := INF
	var tgrid := {}
	for p: Vector2 in tree_roots:
		var k := _grid_key(p, 2.0)
		if not tgrid.has(k):
			tgrid[k] = []
		tgrid[k].append(p)
	for id in ids:
		var a: PackedFloat64Array = g1[id]
		forms.append({"id": id, "gd_count": a.size() / 7, "gd_hash": _sha(a.to_byte_array())})
		total += a.size() / 7
		arrs.append(a)
		if a.size() == 0:
			all_nonempty = false
		if _sha((g2[id] as PackedFloat64Array).to_byte_array()) != _sha(a.to_byte_array()):
			det_equal = false
		for i in range(a.size() / 7):
			var p := Vector2(a[i * 7], a[i * 7 + 2])
			if _hyp(p.x, p.y) < 5.0:
				within += 1
			if flower_lids.has(Vector2(a[i * 7 + 5], a[i * 7 + 6])):
				in_flower += 1
			var k := _grid_key(p, 2.0)
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					for q: Vector2 in tgrid.get(Vector2i(k.x + dx, k.y + dz), []):
						min_tree = minf(min_tree, _hyp(p.x - q.x, p.y - q.y))
	var lc := _lid_checks(arrs, 7, 5, 0.15)

	var ring_per := []
	ring_per.resize(ids.size())
	ring_per.fill(0)
	var ring_total := 0
	var ring_chunks := 0
	var nearest := INF
	for c in _chunk_range():
		var d: Dictionary = StalagUnderstory.shrubs_chunk(c.x, c.y)
		var any := false
		for fi in range(ids.size()):
			var a: PackedFloat64Array = d[ids[fi]]
			if a.size() > 0:
				any = true
			if _in_ring(c):
				ring_per[fi] += a.size() / 7
				ring_total += a.size() / 7
				for i in range(a.size() / 7):
					nearest = minf(nearest, _hyp(a[i * 7], a[i * 7 + 2]))
		if any and _in_ring(c):
			ring_chunks += 1
	# injected-equals-internal, engine form: the chunk-by-chunk path (which reads the neighbouring
	# chunks' trees and flower lids through the shared world) rebuilds exactly the global result
	var by_form := []
	for fi in range(ids.size()):
		by_form.append([])
	for c in _chunk_range():
		var d: Dictionary = StalagUnderstory.shrubs_chunk(c.x, c.y)
		for fi in range(ids.size()):
			by_form[fi].append(d[ids[fi]])
	var union_equal := true
	for fi in range(ids.size()):
		var got := {}
		for a: PackedFloat64Array in by_form[fi]:
			for i in range(a.size() / 7):
				got[Vector2(a[i * 7], a[i * 7 + 2])] = true
		var want: PackedFloat64Array = arrs[fi]
		if got.size() != want.size() / 7:
			union_equal = false
		for i in range(want.size() / 7):
			if not got.has(Vector2(want[i * 7], want[i * 7 + 2])):
				union_equal = false
	var ring_form := {}
	for fi in range(ids.size()):
		ring_form[ids[fi]] = ring_per[fi]

	return {
		"total_gd": total,
		"forms": forms,
		"lid_keys_gd": int(g1["_lid_keys"]),
		"off_lid": lc["off_lid"],
		"flooded_or_course": lc["flooded_or_course"],
		"clearing_m": 5.0,
		"within_clearing": within,
		"min_tree_dist_m": min_tree if min_tree != INF else 1.0e9,
		"in_flower_lids": in_flower,
		"nearest_root_m_ring_gd": nearest,
		"ring": {"total_gd": ring_total, "per_form_gd": ring_form, "chunks_with_gd": ring_chunks},
		"ported_checks": {
			"SHRUB_ALL_SIX_NONEMPTY": ids.size() == 6 and all_nonempty,
			"SHRUB_CLEARING": total > 0 and within == 0,
			"SHRUB_DETERMINISM": det_equal,
			"SHRUB_FLOWER_LID_EXCLUDED": total > 0 and in_flower == 0,
			"SHRUB_INJECT_EQUALS_INTERNAL": union_equal,
			"SHRUB_LID_ONLY": total > 0 and lc["off_lid"] == 0,
			"SHRUB_NO_WATER": total > 0 and lc["flooded_or_course"] == 0,
			"SHRUB_TRUNK_GATE": total > 0 and min_tree >= 1.2,
		},
	}


# ---------------------------------------------------------------- grass thinning on the rendered meadow
func _meadow() -> Dictionary:
	var ids: PackedStringArray = StalagFlora.form_ids()
	var raw: Dictionary = StalagFlora.place_global()
	var raw_total := 0
	var raw_per := {}
	for id in ids:
		raw_per[id] = (raw[id] as PackedFloat64Array).size() / 7
		raw_total += raw_per[id]
	var world_per := {}
	var ring_per := {}
	for id in ids:
		world_per[id] = 0
		ring_per[id] = 0
	for c in _chunk_range():
		var d: Dictionary = StalagFlora.build_chunk_flora(c.x, c.y)
		for id in ids:
			if not d.has(id):
				continue
			var n: int = d[id]["count"]
			world_per[id] += n
			if _in_ring(c):
				ring_per[id] += n
	var world_total := 0
	var ring_total := 0
	var non_grass_removed := 0
	for id in ids:
		world_total += world_per[id]
		ring_total += ring_per[id]
		if not GRASS.has(id):
			non_grass_removed += raw_per[id] - world_per[id]
	var raw_ring := 0
	for c in _chunk_range():
		if _in_ring(c):
			var d: Dictionary = StalagFlora.place_chunk(c.x, c.y)
			for id in ids:
				raw_ring += (d[id] as PackedFloat64Array).size() / 7
	var grass := GRASS.duplicate()
	grass.sort()
	return {
		"rule": "grass_on_flower_or_shrub_lid",
		"grass_forms": grass,
		"raw_total": raw_total,
		"world_total_gd": world_total,
		"ring_total_gd": ring_total,
		"removed_world": raw_total - world_total,
		"removed_ring": raw_ring - ring_total,
		"non_grass_removed": non_grass_removed,
		"world_per_form_gd": world_per,
		"ring_per_form_gd": ring_per,
	}


# ---------------------------------------------------------------- baked assets, as the engine loads them
func _dir_bytes(path: String) -> int:
	var total := 0
	var d := DirAccess.open(path)
	if d == null:
		return 0
	for f in d.get_files():
		var fa := FileAccess.open(path.path_join(f), FileAccess.READ)
		if fa != null:
			total += fa.get_length()
	# dotfiles (.gdignore) are listed by get_files too; they are empty
	return total


# a corrupted copy of loaded crown arrays: mirrors x (the control that proves the array hash can fail)
func _flip_arrays(arrays: Array) -> void:
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
		return
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in range(v.size()):
		v[i] = Vector3(-v[i].x, v[i].y, v[i].z)
	arrays[Mesh.ARRAY_VERTEX] = v


func _assets() -> Dictionary:
	var ta := TreeAssets.new()
	var forms := []
	var tot := {"trunk_tris": 0, "crown_tris": 0, "tufts": 0, "leaf_cells": 0, "shadow_tris": 0}
	var bake_forms := {}
	for f in _fresh_bake("trees").get("forms", []):
		bake_forms[f["id"]] = f
	for id in ta.form_ids():
		var d: Dictionary = ta.decoded[id]
		var b: Dictionary = bake_forms.get(id, {})
		if _mutation == "asset_flip" and d["crown"] != null:
			_flip_arrays(d["crown"])
		var tt: int = (d["trunk"][Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		var ct := 0
		var st := 0
		if d["crown"] != null:
			ct = (d["crown"][Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			st = (d["shadow"][Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		var crown_b: Dictionary = b.get("crown", {}) if b.get("crown") != null else {}
		var tufts: int = int(crown_b.get("tufts", 0))
		var cells: int = int(crown_b.get("cells", 0))
		var trunk_b: Dictionary = b.get("trunk", {})
		forms.append({
			"id": id, "trunk_cells": int(trunk_b.get("cells", -1)), "leaf_cells": cells, "tufts": tufts,
			"trunk_tris": tt, "crown_tris": ct, "shadow_tris": st,
			"nominal_height_m": float(b.get("nominal_height_m", -1.0)),
			"array_hash_js": str(b.get("array_hash", "")), "array_hash_gd": ta.array_hash(id),
		})
		tot["trunk_tris"] += tt
		tot["crown_tris"] += ct
		tot["tufts"] += tufts
		tot["leaf_cells"] += cells
		tot["shadow_tris"] += st
	tot["bytes"] = _dir_bytes("res://game/world/assets/trees")
	var tex := []
	var fresh: Dictionary = _fresh_bake("trees")
	var imgs := ta.leaf_images()
	for t in fresh.get("leaf_tex", []):
		var img: Image = imgs[t["id"]]
		tex.append({"id": t["id"], "w": img.get_width(), "h": img.get_height(), "rgba_sha16_js": t["rgba_sha16"], "rgba_sha16_gd": TreeAssets.rgba_sha16(img)})
	return {"forms": forms, "totals": tot, "tuft_hash": str(fresh.get("tuft_hash", "")), "leaf_tex": tex, "load_ms": ta.load_ms}


func _understory_assets() -> Dictionary:
	var ua := UnderstoryAssets.new()
	var fresh: Dictionary = _fresh_bake("understory")
	var bake_forms := {}
	for s in fresh.get("shrubs", []):
		bake_forms[s["id"]] = s
	var forms := []
	var ut := {"leaf_cells": 0, "tufts": 0, "voxel_tris": 0}
	for id in ua.decoded.keys():
		var b: Dictionary = bake_forms.get(id, {})
		if _mutation == "u_asset_flip":
			_flip_arrays(ua.decoded[id])
		var tris: int = (ua.decoded[id][Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		forms.append({"id": id, "cells": int(b.get("cells", -1)), "tufts": int(b.get("tufts", -1)), "tris": tris,
			"array_hash_js": str(b.get("array_hash", "")), "array_hash_gd": ua.array_hash(id)})
		ut["leaf_cells"] += int(b.get("cells", 0))
		ut["tufts"] += int(b.get("tufts", 0))
		ut["voxel_tris"] += tris
	ut["bytes"] = _dir_bytes("res://game/world/assets/understory")
	var tex := []
	for t in fresh.get("shrub_tex", []):
		var img := ua.image(t["file"])
		tex.append({"id": t["id"], "w": img.get_width(), "h": img.get_height(), "rgba_sha16_js": t["rgba_sha16"], "rgba_sha16_gd": UnderstoryAssets.rgba_sha16(img)})
	var sprites := []
	for sp in fresh.get("sprites", []):
		var img := ua.image(sp["file"])
		sprites.append({"id": sp["id"], "w": img.get_width(), "h": img.get_height(), "rgba_sha16_js": sp["rgba_sha16"], "rgba_sha16_gd": UnderstoryAssets.rgba_sha16(img)})
	return {"forms": forms, "totals": ut, "tuft_hash": str(fresh.get("tuft_hash", "")), "shrub_tex": tex, "sprites": sprites, "load_ms": ua.load_ms}


# the fresh bake's manifest (the wrapper bakes into TREES_BAKE_DIR before the probe runs)
var _bake_cache := {}


func _fresh_bake(sub: String) -> Dictionary:
	if _bake_cache.has(sub):
		return _bake_cache[sub]
	var dir := OS.get_environment("TREES_BAKE_DIR")
	var txt := FileAccess.get_file_as_string(dir.path_join(sub).path_join("manifest.json")) if not dir.is_empty() else ""
	var m: Dictionary = JSON.parse_string(txt) if not txt.is_empty() else {}
	_bake_cache[sub] = m if m != null else {}
	return _bake_cache[sub]
