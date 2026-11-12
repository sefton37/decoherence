extends SceneTree
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #928 -- the river-bank probe (headless, CPU only). Original work for this spec; the raster helpers are
## the Spec #558 probe's own, copied unchanged. It only MEASURES -- tests/verify_water_bank.sh wraps it and the
## definition of done's jq judges.
##
## Question: along every river and fall course inside the walkable footprint, does the water mesh the engine
## builds reach the dry bank columns that the plan leaves flush with the water, and did building that leave
## every water triangle that already existed exactly where it was? Spec #558 closed the same gap for still
## water (lakes, springs); this probe judges the columns whose reaching level comes from a course.
##
## Definitions (0.5 m columns, the plan's own grid; level L is a plan terrace index, the surface of level L
## is lattice height 4*L+2, one lattice unit is SF metres). The candidate rule is the #558 probe's, unchanged.
##   * WET column: the plan floods it (water_level_at = still, else course_level_at = course); level L.
##   * CANDIDATE column: a plan-dry column inside the footprint within RING_MAX rings (8-neighbour) of a wet
##     column, whose terrace floor(h/4) is at or below the level that reaches it (a ring-r column takes the MAX
##     level among its ring-(r-1) neighbours; a tie goes to the still-water source). Source 1 = the reaching
##     level comes from a course (river or fall): those are this spec's COURSE candidates. Source 0 = still.
##     A cliff beside the water (terrace above the level) is never a candidate, so it is never gated and any
##     water standing on it is BLEED.
##   * SEGMENT: an 8-connected group of course wet columns of ONE level (a river's surface steps by whole
##     terraces, so the bank's own level is per segment, not one pond level). Every course candidate belongs
##     to the segment whose column gave it its level; the gap is also scored per segment.
##   * COVERED / GAP / EXPOSED / BLEED / OVER: exactly the #558 probe's definitions, scored for the course set.
##   * ZONE: every column within FAR_MARGIN_COLS (Chebyshev) of a course candidate. Water triangles are classed
##     by the column their centroid lies in: FAR (outside the zone), ZONE-WET (inside, wet column) and
##     ZONE-DRY (inside, dry column). A triangle's identity is a hash of centroid, depth band and flow vector,
##     so a moved vertex, a changed band or a changed flow direction is a different triangle.
##   * The BASELINE is the water the engine built at the end of Spec #558, cut once into the fixture. FAR and
##     ZONE-WET must equal it exactly (count, xor, sum); every ZONE-DRY baseline triangle must still be present
##     (the fix may ADD water in the zone, never move, drop or re-attribute existing water); all flow-carrying
##     triangles must equal it exactly (new bank water carries no flow, so no foam or ripple changes).
##   * NEW triangles are the ZONE-DRY ones not in the baseline. Each must lie in a candidate column, stay
##     between its level surface minus COVER_TOL_LAT and plus OVER_TOL_LAT, and keep clear of fall columns.
##   * TILING: the footprint is built a second time with the 28 m regions shifted by half a region; the water
##     triangles of the inner window must be the same set (a fix that depends on the chunk box fails).
## The water is measured over the eight 28 m chunk regions that tile the +-112 m footprint.
##
## Env: WATERBANK_OUT         output JSON path (required)
##      WATERBANK_MUTATE      none | drop_all | punch | sink | lift | far_nudge | zone_nudge | flow_leak | wall_sheet
##                            | tile_break | drop_new | lift_new (negative controls, applied to the built mesh; drop_new removes
##                              every new triangle, i.e. rebuilds the Spec #558 water out of the candidate build; lift_new raises
##                              every new up-facing triangle one terrace)
##                            | ideal | naive_base (positive controls: pretend water is laid over every course candidate
##                              at its level + 4 lattice units (ideal), or on top of the Spec #558 water at its level
##                              (naive_base, a fill coplanar with the mud))
##      WATERBANK_FIXTURE     res:// path of the baseline fixture (default FIXTURE_PATH)
##      WATERBANK_CUT         path: write a new baseline fixture there (run once, on the Spec #558 build)

# ---- taste knobs and fixed definitions (the record carries them; the definition of done reads them)
const FOOTPRINT_HALF_COLS := 224   # columns per side of the origin = 112 m, the walkable footprint
const CHUNK_M := 28.0              # metres per measured region (the engine's chunk size)
const RING_MAX := 2                # TASTE: rings of bank the water must reach (2 columns = 1 m, the plan's own rim width)
const COVER_TOL_LAT := 1.0         # lattice units a water face may sit under its level and still count
const OVER_TOL_LAT := 4.0          # lattice units a water face may stand above its level (one terrace)
const GAP_COL_COVER_MIN := 0.75    # a candidate covered below this share is a gap column
const COURSE_GAP_AREA_MAX_COLS := 12.0     # TASTE: the most uncovered bank area (whole columns, every river and fall) the walker may meet
const COURSE_GAP_CLUSTER_MAX_COLS := 2  # TASTE: the largest run of connected gap columns the walker may meet
const SEGMENT_GAP_MAX_COLS := 6.0         # TASTE: the most uncovered bank area any single one-level segment may keep
const WITNESS_UNCOVERED_MAX := 3.0        # TASTE: the most uncovered area among the recorded witness columns
const COURSE_EXPOSED_AREA_MAX_COLS := 24.0 # TASTE: the most bank area (whole columns) where bare terrain stands above the water; the river analogue of the dry flanks of mud bumps the project owner accepted for lakes in Spec #558
const EXPOSE_TOL_LAT := 1.0        # lattice units terrain may stand above the water over a bank column and still read as wet
const BLEED_AREA_MAX_COLS := 4.0   # TASTE: the most water area allowed beyond the bank, onto the land
const OVER_AREA_MAX_COLS := 4.0    # TASTE: the most area allowed standing above its level
const NEW_STRAY_MAX_TRIS := 6000         # TASTE: new water triangles allowed outside every candidate column
const NEW_STRAY_UP_MAX_TRIS := 0          # TASTE: new up-facing water triangles allowed outside every candidate column (water standing on the land)
const NEW_UP_HIGH_MAX_TRIS := 2000          # TASTE: new up-facing water triangles allowed to ride more than COVER_TOL_LAT above their level (the one-terrace film over a bump; a whole bank lifted a terrace would be all of them)
const NEW_OFF_LEVEL_MAX_TRIS := 40      # TASTE: new water triangles allowed off their level band (below level - COVER_TOL_LAT or above level + OVER_TOL_LAT)
const NEW_WALL_AREA_MAX_M2 := 110.0        # TASTE: the most area of NEW vertical water faces (hard walls on a bank) in square metres
const TRIS_GROWTH_MAX_FRAC := 0.5        # TASTE: water triangles may grow at most this fraction over the baseline (memory and draw cost)
const FALL_GUARD_COLS := 2         # new water keeps this many columns clear of any fall column
const FAR_MARGIN_COLS := 3         # TASTE: columns of clearance around a course candidate that the unchanged-water fingerprints skip (1.5 m)
const FIXTURE_PATH := "res://engine/stalag/tests/fixtures/water_bank_baseline.json"
const SAMPLES := 4                 # sample points per column side
const BUILD_MS_MAX := 250          # TASTE: the slowest single 28 m water build the probe may see, milliseconds
const HASH_BITS := 40              # inclusion hashes keep this many low bits

var _mutation := "none"


func _fail(msg: String) -> void:
	push_error("water_bank_probe: " + msg)
	quit(2)


# Rasterise the up-facing triangles of one mesh into `cov` (sample key -> highest covering height, metres).
func _rasterise(v: PackedVector3Array, cov: Dictionary) -> void:
	var pitch := 0.5 / SAMPLES
	var t := 0
	while t + 2 < v.size():
		var a := v[t]
		var b := v[t + 1]
		var c := v[t + 2]
		t += 3
		var n := (b - a).cross(c - a)
		if n.length() < 1e-9 or n.normalized().y <= 0.9:
			continue
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-12:
			continue
		var yc := (a.y + b.y + c.y) / 3.0
		var i0 := int(ceil(minf(a.x, minf(b.x, c.x)) / pitch - 0.5))
		var i1 := int(floor(maxf(a.x, maxf(b.x, c.x)) / pitch - 0.5))
		var j0 := int(ceil(minf(a.z, minf(b.z, c.z)) / pitch - 0.5))
		var j1 := int(floor(maxf(a.z, maxf(b.z, c.z)) / pitch - 0.5))
		for i in range(i0, i1 + 1):
			for j in range(j0, j1 + 1):
				var px := (i + 0.5) * pitch
				var pz := (j + 0.5) * pitch
				var l1 := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) / d
				var l2 := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) / d
				if l1 >= -1e-9 and l2 >= -1e-9 and l1 + l2 <= 1.0 + 1e-9:
					var key := Vector2i(i, j)
					if not cov.has(key) or float(cov[key]) < yc:
						cov[key] = yc


func _rasterise_top(v: PackedVector3Array, out: Dictionary, min_ny: float) -> void:
	var pitch := 0.5 / SAMPLES
	var t := 0
	while t + 2 < v.size():
		var a := v[t]
		var b := v[t + 1]
		var c := v[t + 2]
		t += 3
		var n := (b - a).cross(c - a)
		if n.length() < 1e-9 or n.normalized().y <= min_ny:
			continue
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-12:
			continue
		var i0 := int(ceil(minf(a.x, minf(b.x, c.x)) / pitch - 0.5))
		var i1 := int(floor(maxf(a.x, maxf(b.x, c.x)) / pitch - 0.5))
		var j0 := int(ceil(minf(a.z, minf(b.z, c.z)) / pitch - 0.5))
		var j1 := int(floor(maxf(a.z, maxf(b.z, c.z)) / pitch - 0.5))
		for i in range(i0, i1 + 1):
			for j in range(j0, j1 + 1):
				var px := (i + 0.5) * pitch
				var pz := (j + 0.5) * pitch
				var l1 := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) / d
				var l2 := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) / d
				if l1 >= -1e-9 and l2 >= -1e-9 and l1 + l2 <= 1.0 + 1e-9:
					var y := l1 * a.y + l2 * b.y + (1.0 - l1 - l2) * c.y
					var key := Vector2i(i, j)
					if not out.has(key) or float(out[key]) < y:
						out[key] = y


func _floor_terrace(gx: int, gz: int, sf: float) -> int:
	var h: float = StalagWorld.surface_height((gx * 0.5 + 0.25) / sf, (gz * 0.5 + 0.25) / sf)
	return int(floor(h / 4.0))


func _covered_fraction(cov: Dictionary, gx: int, gz: int, level: int, sf: float, cut: Dictionary) -> float:
	var need := (4.0 * level + 2.0 - COVER_TOL_LAT) * sf
	var hit := 0
	for i in range(SAMPLES):
		for j in range(SAMPLES):
			var key := Vector2i(gx * SAMPLES + i, gz * SAMPLES + j)
			if cut.has(Vector2i(gx, gz)):
				continue
			if cov.has(key) and float(cov[key]) >= need:
				hit += 1
	return float(hit) / float(SAMPLES * SAMPLES)



func _tri_hash(cen: Vector3, d: float, fl: Vector2) -> int:
	var x := int(round(cen.x * 10000.0))
	var y := int(round(cen.y * 10000.0))
	var z := int(round(cen.z * 10000.0))
	var h := (x * 73856093) ^ (y * 19349663) ^ (z * 83492791)
	h = h ^ (int(round(d * 1000.0)) * 40503) ^ (int(round(fl.x * 1000.0)) * 99991) ^ (int(round(fl.y * 1000.0)) * 7919)
	# Non-linear finish: without it the xor of many flat-water triangles (one shared height) cancels a uniform shift.
	h = h ^ (h >> 33)
	h = h * 19349663
	h = h ^ (h >> 29)
	h = h * 83492791
	return h ^ (h >> 31)


func _mix40(h: int) -> int:
	var m := (1 << HASH_BITS) - 1
	return ((h ^ (h >> 23)) * 31 + (h >> 11)) & m


func _initialize() -> void:
	var out_path := OS.get_environment("WATERBANK_OUT")
	_mutation = OS.get_environment("WATERBANK_MUTATE")
	if _mutation.is_empty():
		_mutation = "none"
	var fixture_path := OS.get_environment("WATERBANK_FIXTURE")
	if fixture_path.is_empty():
		fixture_path = FIXTURE_PATH
	var cut_path := OS.get_environment("WATERBANK_CUT")
	if out_path.is_empty() or not ClassDB.class_exists("StalagWorld") or not ClassDB.class_exists("StalagChunkMesher"):
		_fail("WATERBANK_OUT is required and the Stalag classes must be loaded")
		return
	if not (_mutation in ["none", "drop_all", "punch", "sink", "lift", "far_nudge", "zone_nudge", "flow_leak", "wall_sheet", "tile_break", "drop_new", "lift_new", "ideal", "naive_base"]):
		_fail("bad WATERBANK_MUTATE " + _mutation)
		return
	StalagWorld.start_plan()
	while StalagWorld.plan_status() == 1:
		OS.delay_msec(20)
	if StalagWorld.plan_status() != 2:
		_fail("plan solve failed: " + StalagWorld.plan_error())
		return
	var sf := StalagWorld.get_sf()
	var dry := StalagWorld.water_dry_sentinel()
	var half := FOOTPRINT_HALF_COLS

	# ---- falls anywhere in the plan (the whole domain, not just the footprint)
	var fall_cols := 0
	var fall_near := {}
	var dim := StalagWorld.plan_dim()
	var g0 := StalagWorld.plan_g0()
	for gz in range(g0, g0 + dim):
		for gx in range(g0, g0 + dim):
			if StalagWorld.course_fall_top_at(gx, gz) != dry:
				fall_cols += 1
				for dz in range(-FALL_GUARD_COLS, FALL_GUARD_COLS + 1):
					for dx in range(-FALL_GUARD_COLS, FALL_GUARD_COLS + 1):
						fall_near[Vector2i(gx + dx, gz + dz)] = true

	# ---- the plan's wet columns (footprint plus the ring margin, so chains can start outside the edge)
	var wet := {}  # Vector2i -> [level, source]  source 0 = lake/spring, 1 = river/fall
	for gz in range(-half - RING_MAX, half + RING_MAX):
		for gx in range(-half - RING_MAX, half + RING_MAX):
			var lv := StalagWorld.water_level_at(gx, gz)
			var src := 0
			if lv == dry:
				lv = StalagWorld.course_level_at(gx, gz)
				src = 1
			if lv != dry:
				wet[Vector2i(gx, gz)] = [lv, src]

	# ---- segments: 8-connected wet columns of one level and one source (ponds for still, one-level course segments)
	var seg := {}  # Vector2i -> segment id
	var seg_n := 0
	var seg_src := {}  # segment id -> source
	for k in wet.keys():
		if seg.has(k):
			continue
		seg[k] = seg_n
		seg_src[seg_n] = int(wet[k][1])
		var sst: Array = [k]
		while sst.size() > 0:
			var sc: Vector2i = sst.pop_back()
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var sn := Vector2i(sc.x + dx, sc.y + dz)
					if wet.has(sn) and not seg.has(sn) and int(wet[sn][1]) == int(wet[k][1]) and int(wet[sn][0]) == int(wet[k][0]):
						seg[sn] = seg_n
						sst.push_back(sn)
		seg_n += 1
	var step_pairs := 0
	for k in wet.keys():
		if int(wet[k][1]) != 1:
			continue
		for nb in [Vector2i(k.x + 1, k.y), Vector2i(k.x, k.y + 1)]:
			if wet.has(nb) and int(wet[nb][1]) == 1 and int(wet[nb][0]) != int(wet[k][0]):
				step_pairs += 1

	# ---- candidates: ring-by-ring over plan-dry columns, level = max of the previous ring's neighbours
	var cand := {}  # Vector2i -> [level, ring, source, segment]
	var seen := {}
	for k in wet.keys():
		seen[k] = true
	var frontier: Array = wet.keys()
	for ring in range(1, RING_MAX + 1):
		var reach := {}  # Vector2i -> [level, source, segment]
		for c in frontier:
			var base: Array = wet[c] if wet.has(c) else cand[c]
			var lv: int = base[0]
			var src: int = base[1] if wet.has(c) else base[2]
			var sid: int = int(seg[c]) if wet.has(c) else int(base[3])
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var nb := Vector2i(c.x + dx, c.y + dz)
					if seen.has(nb) or absi(nb.x) >= half or absi(nb.y) >= half:
						continue
					if not reach.has(nb) or int(reach[nb][0]) < lv or (int(reach[nb][0]) == lv and int(reach[nb][1]) > src):
						reach[nb] = [lv, src, sid]
		var next: Array = []
		for nb in reach.keys():
			seen[nb] = true
			var lv2: int = reach[nb][0]
			if _floor_terrace(nb.x, nb.y, sf) <= lv2:
				cand[nb] = [lv2, ring, reach[nb][1], reach[nb][2]]
				next.append(nb)
		frontier = next

	# ---- the zone around the course candidates
	var zone := {}
	for c in cand.keys():
		if int(cand[c][2]) != 1:
			continue
		for dz in range(-FAR_MARGIN_COLS, FAR_MARGIN_COLS + 1):
			for dx in range(-FAR_MARGIN_COLS, FAR_MARGIN_COLS + 1):
				zone[Vector2i(c.x + dx, c.y + dz)] = true

	# ---- baseline fixture (absent only when cutting one)
	var fx: Dictionary = {}
	var base_c := {}
	var witness: Array = []
	if cut_path.is_empty():
		var wf := FileAccess.open(fixture_path, FileAccess.READ)
		if wf == null:
			_fail("cannot read baseline fixture " + fixture_path)
			return
		fx = JSON.parse_string(wf.get_as_text())
		wf.close()
		witness = fx["columns"]
		for hv in fx["zone_dry_hashes"]:
			base_c[int(hv)] = int(base_c.get(int(hv), 0)) + 1  # a multiset: a fix may add a triangle identical to an existing one
	var punch := {}  # columns whose water is cut under mutation punch
	if _mutation == "punch":
		for w in witness:
			punch[Vector2i(int(w[0]), int(w[1]))] = true

	# ---- the water, as the engine builds it, over the footprint (tiling A: the engine's own chunk tiling)
	var cov := {}
	var tmap := {}
	var tris := 0
	var build_ms_max := 0.0
	var fp := {"far": [0, 0, 0], "zwet": [0, 0, 0], "flow": [0, 0, 0], "win": [0, 0, 0]}
	var seen_c := {}
	var cut_hashes: Array = []
	var new_n := 0
	var new_stray := 0
	var new_stray_up := 0
	var new_off := 0
	var new_near_fall := 0
	var new_wall_area := 0.0
	var new_wall_tris := 0
	var new_up := 0
	var new_up_high := 0
	var wall_n := 0
	var chunks := int(round(2.0 * half * 0.5 / CHUNK_M))
	var win_lo := -half * 0.5 + CHUNK_M * 0.5 + 1.0  # the inner window both tilings cover (tiling B starts half a region in)
	var win_hi := -win_lo
	var keep := PackedVector3Array()  # drop_new and naive_base: the build as it was before the fix (every new triangle removed)
	var cand_list: Array = []
	for c in cand.keys():
		if int(cand[c][2]) == 1:
			cand_list.append(c)
	cand_list.sort()
	for ci in range(chunks):
		for cj in range(chunks):
			var xa := -half * 0.5 + CHUNK_M * ci
			var za := -half * 0.5 + CHUNK_M * cj
			var t0 := Time.get_ticks_usec()
			var w2 := StalagChunkMesher.build_water_arrays(xa, xa + CHUNK_M, za, za + CHUNK_M)
			build_ms_max = maxf(build_ms_max, (Time.get_ticks_usec() - t0) / 1000.0)
			var v: PackedVector3Array = w2["vertices"]
			var dp: PackedFloat32Array = w2["depth"]
			var fl: PackedVector2Array = w2["flow"]
			if _mutation == "wall_sheet" and ci == 0 and cj == 0:
				for q in range(mini(300, cand_list.size())):
					var cc: Vector2i = cand_list[q]
					var x0 := (cc.x + 0.5) * 0.5
					var z0 := (cc.y + 0.5) * 0.5
					var y0 := (4.0 * int(cand[cc][0]) + 2.0) * sf
					v.append(Vector3(x0, y0, z0))
					v.append(Vector3(x0 + 1.0, y0, z0))
					v.append(Vector3(x0, y0 + 4.0 * sf + 1.0, z0))
					for r in range(3):
						dp.append(1.0)
						fl.append(Vector2(0.0, 0.0))
			var nv := v.size()
			var t := 0
			while t + 2 < nv:
				var t0i := t
				var a := v[t]
				var b := v[t + 1]
				var c3 := v[t + 2]
				var cen := (a + b + c3) / 3.0
				var col := Vector2i(int(floor(cen.x / 0.5)), int(floor(cen.z / 0.5)))
				var nrm := (b - a).cross(c3 - a)
				var nlen := nrm.length()
				var ny := 0.0
				if nlen > 1e-12:
					ny = nrm.y / nlen
				var d0 := dp[t]
				var f0 := fl[t]
				var in_zone := zone.has(col)
				var is_new := false
				var is_wet := wet.has(col)
				if _mutation == "far_nudge":
					cen.y += 0.0125
					a.y += 0.0125
					b.y += 0.0125
					c3.y += 0.0125
					v[t] = a
					v[t + 1] = b
					v[t + 2] = c3
				elif _mutation == "zone_nudge" and in_zone and is_wet and ny > 0.9:
					cen.y += 0.0125
					a.y += 0.0125
					b.y += 0.0125
					c3.y += 0.0125
					v[t] = a
					v[t + 1] = b
					v[t + 2] = c3
				elif _mutation == "flow_leak" and in_zone and not is_wet and ny > 0.9 and f0.length() < 0.001:
					f0 = Vector2(1.0, 0.0)
				var h := _tri_hash(cen, d0, f0)
				var is_flow := f0.length() > 0.001
				t += 3
				if _mutation == "tile_break" and absf(fposmod(cen.x + half * 0.5, CHUNK_M) - CHUNK_M * 0.5) > CHUNK_M * 0.5 - 0.3:
					continue
				tris += 1
				if is_flow:
					fp["flow"][0] += 1
					fp["flow"][1] ^= h
					fp["flow"][2] += h
				if cen.x >= win_lo and cen.x < win_hi and cen.z >= win_lo and cen.z < win_hi:
					fp["win"][0] += 1
					fp["win"][1] ^= h
					fp["win"][2] += h
				if ny < 0.5 and ny > -0.5 and not is_wet:
					wall_n += 1
				if not in_zone:
					fp["far"][0] += 1
					fp["far"][1] ^= h
					fp["far"][2] += h
				elif is_wet:
					fp["zwet"][0] += 1
					fp["zwet"][1] ^= h
					fp["zwet"][2] += h
				else:
					var h40 := _mix40(h)
					var seen_n := int(seen_c.get(h40, 0)) + 1
					seen_c[h40] = seen_n
					if not cut_path.is_empty():
						cut_hashes.append(h40)
					elif seen_n > int(base_c.get(h40, 0)):
						is_new = true
						new_n += 1
						if _mutation == "lift_new" and ny > 0.9:
							a.y += 4.0 * sf
							b.y += 4.0 * sf
							c3.y += 4.0 * sf
							cen.y += 4.0 * sf
							v[t0i] = a
							v[t0i + 1] = b
							v[t0i + 2] = c3
						if fall_near.has(col):
							new_near_fall += 1
						if not cand.has(col):
							new_stray += 1
							if ny > 0.9:
								new_stray_up += 1
						else:
							var surf := (4.0 * int(cand[col][0]) + 2.0) * sf
							var ymax := maxf(a.y, maxf(b.y, c3.y))
							var off := ymax > surf + (OVER_TOL_LAT + 0.01) * sf
							if ny > 0.9:
								new_up += 1
								if cen.y > surf + (COVER_TOL_LAT + 0.01) * sf:
									new_up_high += 1
								if cen.y < surf - (COVER_TOL_LAT + 0.01) * sf:
									off = true
							if off:
								new_off += 1
						if ny < 0.5 and ny > -0.5:
							new_wall_tris += 1
							new_wall_area += nlen * 0.5
				if (_mutation == "drop_new" or _mutation == "naive_base") and not is_new:
					keep.append(a)
					keep.append(b)
					keep.append(c3)
			var tr := StalagChunkMesher.build_region_arrays(xa, xa + CHUNK_M, za, za + CHUNK_M)
			_rasterise_top(tr["base"]["vertices"], tmap, 0.3)
			_rasterise_top(tr["caps"]["vertices"], tmap, 0.3)
			if _mutation == "drop_all":
				continue
			if _mutation == "drop_new" or _mutation == "naive_base":
				v = keep
				keep = PackedVector3Array()
			if _mutation == "sink":
				for q in range(v.size()):
					v[q] = v[q] - Vector3(0.0, 0.5, 0.0)
			elif _mutation == "lift":
				for q in range(v.size()):
					v[q] = v[q] + Vector3(0.0, 1.0, 0.0)
			_rasterise(v, cov)

	# ---- tiling B: the same footprint built from regions shifted by half a region; the inner window must match
	var win_b := [0, 0, 0]
	for ci in range(chunks - 1):
		for cj in range(chunks - 1):
			var xb := -half * 0.5 + CHUNK_M * 0.5 + CHUNK_M * ci
			var zb := -half * 0.5 + CHUNK_M * 0.5 + CHUNK_M * cj
			var wb := StalagChunkMesher.build_water_arrays(xb, xb + CHUNK_M, zb, zb + CHUNK_M)
			var vb: PackedVector3Array = wb["vertices"]
			var db: PackedFloat32Array = wb["depth"]
			var flb: PackedVector2Array = wb["flow"]
			var tb := 0
			while tb + 2 < vb.size():
				var cenb := (vb[tb] + vb[tb + 1] + vb[tb + 2]) / 3.0
				if cenb.x >= win_lo and cenb.x < win_hi and cenb.z >= win_lo and cenb.z < win_hi:
					var hb := _tri_hash(cenb, db[tb], flb[tb])
					win_b[0] += 1
					win_b[1] ^= hb
					win_b[2] += hb
				tb += 3

	if _mutation == "ideal" or _mutation == "naive_base":
		var lift := 4.0 if _mutation == "ideal" else 0.0
		for c in cand.keys():
			if int(cand[c][2]) != 1:
				continue
			var yy := (4.0 * int(cand[c][0]) + 2.0 + lift) * sf
			for i in range(SAMPLES):
				for j in range(SAMPLES):
					var key := Vector2i(c.x * SAMPLES + i, c.y * SAMPLES + j)
					if not cov.has(key) or float(cov[key]) < yy:
						cov[key] = yy

	# ---- score the candidates (course = source 1 is the gated set; still water reported apart)
	var gap_area := [0.0, 0.0]
	var uncovered_cols := [0, 0]
	var cand_n := [0, 0]
	var flush_n := [0, 0]
	var gapcols := {}  # course gap columns only
	var exposed_area := 0.0
	var seg_gap := {}  # segment id -> uncovered area (course)
	var seg_cand := {}
	for c in cand.keys():
		var lvl: int = cand[c][0]
		var sidx: int = cand[c][2]
		var f := _covered_fraction(cov, c.x, c.y, lvl, sf, punch)
		gap_area[sidx] += 1.0 - f
		cand_n[sidx] += 1
		if _floor_terrace(c.x, c.y, sf) == lvl:
			flush_n[sidx] += 1
		if f == 0.0:
			uncovered_cols[sidx] += 1
		if sidx == 1:
			var ex := 0
			for i in range(SAMPLES):
				for j in range(SAMPLES):
					var key := Vector2i(c.x * SAMPLES + i, c.y * SAMPLES + j)
					if not tmap.has(key):
						continue
					var wy := -1.0e9
					if cov.has(key) and not punch.has(c):
						wy = float(cov[key])
					if float(tmap[key]) > wy + EXPOSE_TOL_LAT * sf:
						ex += 1
			exposed_area += ex / float(SAMPLES * SAMPLES)
			var sid: int = cand[c][3]
			seg_gap[sid] = float(seg_gap.get(sid, 0.0)) + (1.0 - f)
			seg_cand[sid] = int(seg_cand.get(sid, 0)) + 1
			if f < GAP_COL_COVER_MIN:
				gapcols[c] = true
	var largest := 0
	var done := {}
	for c in gapcols.keys():
		if done.has(c):
			continue
		var size := 0
		var stack: Array = [c]
		done[c] = true
		while stack.size() > 0:
			var cur: Vector2i = stack.pop_back()
			size += 1
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var nb := Vector2i(cur.x + dx, cur.y + dz)
					if gapcols.has(nb) and not done.has(nb):
						done[nb] = true
						stack.push_back(nb)
		largest = maxi(largest, size)
	var worst_seg := 0.0
	var segs_scored := 0
	for sid in seg_cand.keys():
		segs_scored += 1
		worst_seg = maxf(worst_seg, float(seg_gap[sid]))

	# ---- bleed and over: every covered sample point, judged by the column it lies in
	var bleed := 0
	var over := 0
	for key in cov.keys():
		var col2 := Vector2i(int(floor(float(key.x) / SAMPLES)), int(floor(float(key.y) / SAMPLES)))
		if absi(col2.x) >= half or absi(col2.y) >= half:
			continue
		if punch.has(col2):
			continue
		var lvl2 := -9999
		if wet.has(col2):
			lvl2 = int(wet[col2][0])
		elif cand.has(col2):
			lvl2 = int(cand[col2][0])
		if lvl2 == -9999:
			bleed += 1
		elif float(cov[key]) > (4.0 * lvl2 + 2.0 + OVER_TOL_LAT) * sf:
			over += 1

	# ---- witnesses: each must still be a course candidate of the recorded level, and be covered
	var w_valid := 0
	var w_area := 0.0
	for w in witness:
		var wkey := Vector2i(int(w[0]), int(w[1]))
		if cand.has(wkey) and int(cand[wkey][2]) == 1 and int(cand[wkey][0]) == int(w[2]):
			w_valid += 1
		w_area += 1.0 - _covered_fraction(cov, wkey.x, wkey.y, int(w[2]), sf, punch)

	var missing := 0
	var base_total := 0
	for hk in base_c.keys():
		base_total += int(base_c[hk])
	if cut_path.is_empty():
		for hv in base_c.keys():
			missing += maxi(0, int(base_c[hv]) - int(seen_c.get(hv, 0)))
	var wet_in := [0, 0]
	for k in wet.keys():
		if absi(k.x) < half and absi(k.y) < half:
			wet_in[int(wet[k][1])] += 1
	var fxd: Dictionary = fx.get("fp", {})
	var rec := {
		"generated_epoch": Time.get_unix_time_from_system(),
		"mutation": _mutation,
		"headless": DisplayServer.get_name() == "headless",
		"plan_hash": StalagWorld.plan_hash(),
		"constants": {
			"FOOTPRINT_HALF_COLS": FOOTPRINT_HALF_COLS, "CHUNK_M": CHUNK_M, "RING_MAX": RING_MAX,
			"COVER_TOL_LAT": COVER_TOL_LAT, "OVER_TOL_LAT": OVER_TOL_LAT, "GAP_COL_COVER_MIN": GAP_COL_COVER_MIN,
			"COURSE_GAP_AREA_MAX_COLS": COURSE_GAP_AREA_MAX_COLS, "COURSE_GAP_CLUSTER_MAX_COLS": COURSE_GAP_CLUSTER_MAX_COLS,
			"SEGMENT_GAP_MAX_COLS": SEGMENT_GAP_MAX_COLS, "WITNESS_UNCOVERED_MAX": WITNESS_UNCOVERED_MAX,
			"COURSE_EXPOSED_AREA_MAX_COLS": COURSE_EXPOSED_AREA_MAX_COLS, "EXPOSE_TOL_LAT": EXPOSE_TOL_LAT,
			"BLEED_AREA_MAX_COLS": BLEED_AREA_MAX_COLS, "OVER_AREA_MAX_COLS": OVER_AREA_MAX_COLS,
			"NEW_STRAY_MAX_TRIS": NEW_STRAY_MAX_TRIS, "NEW_STRAY_UP_MAX_TRIS": NEW_STRAY_UP_MAX_TRIS, "NEW_UP_HIGH_MAX_TRIS": NEW_UP_HIGH_MAX_TRIS, "NEW_OFF_LEVEL_MAX_TRIS": NEW_OFF_LEVEL_MAX_TRIS,
			"NEW_WALL_AREA_MAX_M2": NEW_WALL_AREA_MAX_M2, "TRIS_GROWTH_MAX_FRAC": TRIS_GROWTH_MAX_FRAC,
			"FALL_GUARD_COLS": FALL_GUARD_COLS, "FAR_MARGIN_COLS": FAR_MARGIN_COLS, "BUILD_MS_MAX": BUILD_MS_MAX, "SAMPLES": SAMPLES,
		},
		"water_tris": tris,
		"water_build_ms_max": snappedf(build_ms_max, 0.1),
		"wet_still_cols": wet_in[0],
		"wet_course_cols": wet_in[1],
		"fall_cols_plan": fall_cols,
		"course_step_pairs": step_pairs,
		"fp": {
			"far": {"tris": fp["far"][0], "xor": str(fp["far"][1]), "sum": str(fp["far"][2])},
			"zone_wet": {"tris": fp["zwet"][0], "xor": str(fp["zwet"][1]), "sum": str(fp["zwet"][2])},
			"flow": {"tris": fp["flow"][0], "xor": str(fp["flow"][1]), "sum": str(fp["flow"][2])},
		},
		"base": {
			"head_tris": int(fx.get("head_water_tris", -1)),
			"far": fxd.get("far", {}), "zone_wet": fxd.get("zone_wet", {}), "flow": fxd.get("flow", {}),
			"zone_dry_count": int(fx.get("zone_dry_count", -1)), "head_commit": fx.get("head_commit", ""),
			"head_course_gap_area_cols": fx.get("head_course_gap_area_cols", -1), "head_wall_tris": int(fx.get("head_wall_tris", -1)),
		},
		"zone_dry": {"present_missing": missing, "baseline_count": base_total},
		"added": {"tris": new_n, "stray": new_stray, "stray_up": new_stray_up, "off_level": new_off, "near_fall": new_near_fall, "up": new_up, "up_high": new_up_high,
			"wall_tris": new_wall_tris, "wall_area_m2": snappedf(new_wall_area, 0.01)},
		"tiling": {"a": {"tris": fp["win"][0], "xor": str(fp["win"][1]), "sum": str(fp["win"][2])},
			"b": {"tris": win_b[0], "xor": str(win_b[1]), "sum": str(win_b[2])}},
		"still": {"candidates": cand_n[0], "gap_area_cols": snappedf(gap_area[0], 0.01)},
		"course": {"candidates": cand_n[1], "flush_candidates": flush_n[1], "uncovered_cols": uncovered_cols[1],
			"gap_area_cols": snappedf(gap_area[1], 0.01), "gap_cols": gapcols.size(), "largest_gap_cluster_cols": largest,
			"exposed_area_cols": snappedf(exposed_area, 0.01), "segments_scored": segs_scored,
			"segments_total_course": seg_src.values().count(1), "worst_segment_gap_area_cols": snappedf(worst_seg, 0.01)},
		"bleed_area_cols": snappedf(bleed / float(SAMPLES * SAMPLES), 0.01),
		"over_area_cols": snappedf(over / float(SAMPLES * SAMPLES), 0.01),
		"witness": {"total": witness.size(), "valid": w_valid, "uncovered_area_cols": snappedf(w_area, 0.01)},
	}
	if not cut_path.is_empty():
		var cut := {
			"head_commit": "spec-558-build",
			"head_water_tris": tris,
			"head_course_gap_area_cols": snappedf(gap_area[1], 0.01),
			"head_wall_tris": wall_n,
			"zone_dry_count": cut_hashes.size(),
			"fp": rec["fp"],
			"columns": [],
			"zone_dry_hashes": cut_hashes,
		}
		var k2 := 0
		for c in cand_list:
			if k2 % 8 == 0:
				cut["columns"].append([c.x, c.y, int(cand[c][0])])
			k2 += 1
		var cf := FileAccess.open(cut_path, FileAccess.WRITE)
		if cf == null:
			_fail("cannot write " + cut_path)
			return
		cf.store_string(JSON.stringify(cut))
		cf.close()
	var of := FileAccess.open(out_path, FileAccess.WRITE)
	if of == null:
		_fail("cannot write " + out_path)
		return
	of.store_string(JSON.stringify(rec))
	of.close()
	print("WATERBANK ", JSON.stringify(rec))
	quit(0)
