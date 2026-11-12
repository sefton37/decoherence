extends SceneTree
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #558 (issue #924) -- the water-fill probe (headless, CPU only). Original work for this spec; no ported code.
## It only MEASURES -- tests/verify_water_fill.sh wraps it and the definition of done's jq judges.
##
## Question: inside the walkable footprint, does the water mesh the engine builds reach the dry columns
## that the water plan leaves dry but that sit AT OR BELOW the water beside them? The plan caps every
## bank column next to a pond at the pond's own terrace (stalag_plan.cpp "Shore cap"), so a rim of such
## columns surrounds each pond; left bare it reads as a flat dark shelf between the water and the real
## bank. The probe also measures the opposite error: water spilling past the bank or standing too high.
##
## Definitions (all in 0.5 m columns, the plan's own grid; level L is a plan terrace index, the surface of
## level L is lattice height 4*L+2, one lattice unit is SF metres):
##   * WET column: the plan floods it (water_level_at, else course_level_at); its level is L.
##   * CANDIDATE column: a plan-dry column inside the footprint reachable from a wet column through at
##     most RING_MAX rings of 8-neighbour steps over plan-dry columns whose terrace floor(h/4) is AT OR
##     BELOW the level that reaches them (a ring-r column takes the MAX level among its ring-(r-1)
##     neighbours; a tie goes to the still-water source). A candidate is "flush" at terrace == level.
##     The gated numbers use still-water (lake or spring) candidates; river/fall candidates are reported
##     on their own so the definition of done can hold them where they are.
##   * COVERED fraction of a column: of its 4x4 sample points (0.125 m pitch) the share lying under an
##     up-facing water triangle (normal.y > 0.9) whose height is at least the level's surface minus
##     COVER_TOL_LAT lattice units. Water that is present but sunk below its level does not count.
##   * GAP area = sum over candidates of (1 - covered fraction). A gap column is a candidate whose covered
##     fraction is below GAP_COL_COVER_MIN; the largest 8-connected group of gap columns is the cluster.
##   * POND: an 8-connected group of still-water wet columns of one level; every still-water candidate
##     belongs to the pond whose column gave it its level, and the gap is also scored per pond.
##   * EXPOSED area: of a candidate's 16 samples, those where the terrain's highest up-facing surface stands
##     more than EXPOSE_TOL_LAT lattice units above the water's highest surface there (or where there is no
##     water). It is what a player sees as mud above the waterline.
##   * BLEED area: water-covered sample area (in columns) lying in plan-dry columns that are neither wet nor
##     candidates. OVER area: water-covered sample area in wet or candidate columns whose face stands more
##     than OVER_TOL_LAT lattice units above the level's surface. Both must stay near zero: a fix that
##     floods the bank or lifts the whole pond would pass the gap test and fail these.
## The water is measured over the eight 28 m chunk regions that tile the +-112 m footprint, so the chunk
## seams are inside the measurement.
##
## Env: WATERFILL_OUT      output JSON path (required)
##      WATERFILL_MUTATE   none | drop_all | punch | sink   (negative controls; applied to the built mesh)
##                         | far_nudge (moves every water vertex 0.0125 m up: the far-field fingerprint must notice)
##                         | ideal | naive   (positive control: pretend water is laid over every still-water
##                           candidate column at its level + 4 lattice units (ideal) or at its level (naive))
##      WATERFILL_LIST     1 adds the gap-column list to the record (used once, to cut the witness fixture)
##      WATERFILL_WITNESS  res:// path of the witness fixture (default WITNESS_PATH)

# ---- taste knobs and fixed definitions (the record carries them; the definition of done reads them)
const FOOTPRINT_HALF_COLS := 224   # columns per side of the origin = 112 m, the walkable footprint
const CHUNK_M := 28.0              # metres per measured region (the engine's chunk size)
const RING_MAX := 2                # TASTE: rings of shelf the water must reach (2 columns = 1 m, the plan's own rim width)
const COVER_TOL_LAT := 1.0         # lattice units a water face may sit under its level and still count
const OVER_TOL_LAT := 4.0          # lattice units a water face may stand above its level (one terrace)
const GAP_COL_COVER_MIN := 0.75    # a candidate covered below this share is a gap column
const GAP_AREA_MAX_COLS := 12.0   # TASTE: the most uncovered shelf area (whole columns, all ponds) the walker may meet; 0.5% of the 2561 columns bare at ec4becd
const GAP_CLUSTER_MAX_COLS := 2    # TASTE: the largest run of connected gap columns the walker may meet
const WITNESS_UNCOVERED_MAX := 2.0 # TASTE: the most uncovered area among the recorded witness columns
const BLEED_AREA_MAX_COLS := 4.0   # TASTE: the most water area allowed beyond the shelf, onto the bank
const OVER_AREA_MAX_COLS := 4.0    # TASTE: the most area allowed standing above its level
const POND_GAP_MAX_COLS := 3.0     # TASTE: the most uncovered shelf area any single pond may keep
const EXPOSE_TOL_LAT := 1.0        # lattice units terrain may stand above the water over a shelf column and still read as wet
const EXPOSED_AREA_MAX_COLS := 44.0 # TASTE: the most shelf area (whole columns) where bare terrain stands above the water (an ideal fill leaves 2.75, a same-plane fill 146, ec4becd 2561). owner walkthrough 2026-11-11: residual is dry flanks of single-cell mud bumps one terrace above the pond
const WITNESS_PATH := "res://engine/stalag/tests/fixtures/water_fill_witness.json"
const FAR_MARGIN_COLS := 3         # TASTE: columns of clearance around still-water shelf that the unchanged-water fingerprint skips (1.5 m)
const SAMPLES := 4                 # sample points per column side
const BUILD_MS_MAX := 250          # TASTE: the slowest single 28 m water build the probe may see, milliseconds (16 at ec4becd; a worker-thread budget)

var _mutation := "none"


func _fail(msg: String) -> void:
	push_error("water_fill_probe: " + msg)
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


func _initialize() -> void:
	var out_path := OS.get_environment("WATERFILL_OUT")
	_mutation = OS.get_environment("WATERFILL_MUTATE")
	if _mutation.is_empty():
		_mutation = "none"
	var witness_path := OS.get_environment("WATERFILL_WITNESS")
	if witness_path.is_empty():
		witness_path = WITNESS_PATH
	if out_path.is_empty() or not ClassDB.class_exists("StalagWorld") or not ClassDB.class_exists("StalagChunkMesher"):
		_fail("WATERFILL_OUT is required and the Stalag classes must be loaded")
		return
	if not (_mutation in ["none", "drop_all", "punch", "sink", "ideal", "naive", "far_nudge"]):
		_fail("bad WATERFILL_MUTATE " + _mutation)
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

	# ---- ponds: 8-connected still-water columns of one level (the whole plan, so a pond cut by the edge is one pond)
	var pond := {}  # Vector2i -> pond id
	var pond_n := 0
	for k in wet.keys():
		if int(wet[k][1]) != 0 or pond.has(k):
			continue
		pond[k] = pond_n
		var pst: Array = [k]
		while pst.size() > 0:
			var pc: Vector2i = pst.pop_back()
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var pn := Vector2i(pc.x + dx, pc.y + dz)
					if wet.has(pn) and int(wet[pn][1]) == 0 and int(wet[pn][0]) == int(wet[k][0]) and not pond.has(pn):
						pond[pn] = pond_n
						pst.push_back(pn)
		pond_n += 1

	# ---- candidates: ring-by-ring over plan-dry columns, level = max of the previous ring's neighbours
	var cand := {}  # Vector2i -> [level, ring, source, pond]
	var seen := {}
	for k in wet.keys():
		seen[k] = true
	var frontier: Array = wet.keys()
	for ring in range(1, RING_MAX + 1):
		var reach := {}  # Vector2i -> [level, source, pond]
		for c in frontier:
			var base: Array = wet[c] if wet.has(c) else cand[c]
			var lv: int = base[0]
			var src: int = base[1] if wet.has(c) else base[2]
			var pid: int = int(pond[c]) if (wet.has(c) and pond.has(c)) else (int(base[3]) if not wet.has(c) else -1)
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var nb := Vector2i(c.x + dx, c.y + dz)
					if seen.has(nb) or absi(nb.x) >= half or absi(nb.y) >= half:
						continue
					if not reach.has(nb) or int(reach[nb][0]) < lv or (int(reach[nb][0]) == lv and int(reach[nb][1]) > src):
						reach[nb] = [lv, src, pid]
		var next: Array = []
		for nb in reach.keys():
			seen[nb] = true
			var lv2: int = reach[nb][0]
			if _floor_terrace(nb.x, nb.y, sf) <= lv2:
				cand[nb] = [lv2, ring, reach[nb][1], reach[nb][2]]
				next.append(nb)
		frontier = next

	# ---- witness fixture
	var witness: Array = []
	var wf := FileAccess.open(witness_path, FileAccess.READ)
	if wf == null:
		_fail("cannot read witness fixture " + witness_path)
		return
	var wj: Dictionary = JSON.parse_string(wf.get_as_text())
	wf.close()
	witness = wj["columns"]
	var punch := {}  # columns whose water is cut under mutation punch
	if _mutation == "punch":
		for w in witness:
			punch[Vector2i(int(w[0]), int(w[1]))] = true

	# ---- the unchanged-water fingerprint: water triangles farther than FAR_MARGIN_COLS from every still-water
	# shelf column. A fix that only adds shelf water leaves every one of them where it was, so count and hash
	# match the ec4becd baseline recorded in the witness fixture (rivers and falls are inside it).
	var near := {}
	for c in cand.keys():
		if int(cand[c][2]) != 0:
			continue
		for dz in range(-FAR_MARGIN_COLS, FAR_MARGIN_COLS + 1):
			for dx in range(-FAR_MARGIN_COLS, FAR_MARGIN_COLS + 1):
				near[Vector2i(c.x + dx, c.y + dz)] = true
	var far_n := 0
	var far_xor := 0
	var far_sum := 0

	# ---- the water, as the engine builds it, over the footprint
	var cov := {}
	var tmap := {}
	var tris := 0
	var build_ms_max := 0.0
	var build_ms_sum := 0.0
	var chunks := int(round(2.0 * half * 0.5 / CHUNK_M))
	for ci in range(chunks):
		for cj in range(chunks):
			var xa := -half * 0.5 + CHUNK_M * ci
			var za := -half * 0.5 + CHUNK_M * cj
			var t0 := Time.get_ticks_usec()
			var w2 := StalagChunkMesher.build_water_arrays(xa, xa + CHUNK_M, za, za + CHUNK_M)
			var dt_ms := (Time.get_ticks_usec() - t0) / 1000.0
			build_ms_max = maxf(build_ms_max, dt_ms)
			build_ms_sum += dt_ms
			var v: PackedVector3Array = w2["vertices"]
			tris += v.size() / 3
			if _mutation == "far_nudge":
				for q in range(v.size()):
					v[q] = v[q] + Vector3(0.0, 0.0125, 0.0)
			var ft := 0
			while ft + 2 < v.size():
				var cen := (v[ft] + v[ft + 1] + v[ft + 2]) / 3.0
				ft += 3
				if near.has(Vector2i(int(floor(cen.x / 0.5)), int(floor(cen.z / 0.5)))):
					continue
				var hq := (int(round(cen.x * 10000.0)) * 73856093) ^ (int(round(cen.y * 10000.0)) * 19349663) ^ (int(round(cen.z * 10000.0)) * 83492791)
				far_n += 1
				far_xor ^= hq
				far_sum += hq
			var tr := StalagChunkMesher.build_region_arrays(xa, xa + CHUNK_M, za, za + CHUNK_M)
			_rasterise_top(tr["base"]["vertices"], tmap, 0.3)
			_rasterise_top(tr["caps"]["vertices"], tmap, 0.3)
			if _mutation == "drop_all":
				continue
			if _mutation == "sink":
				for q in range(v.size()):
					v[q] = v[q] - Vector3(0.0, 0.5, 0.0)
			_rasterise(v, cov)

	if _mutation == "ideal" or _mutation == "naive":
		var lift := 4.0 if _mutation == "ideal" else 0.0
		for c in cand.keys():
			if int(cand[c][2]) != 0:
				continue
			var yy := (4.0 * int(cand[c][0]) + 2.0 + lift) * sf
			for i in range(SAMPLES):
				for j in range(SAMPLES):
					var key := Vector2i(c.x * SAMPLES + i, c.y * SAMPLES + j)
					if not cov.has(key) or float(cov[key]) < yy:
						cov[key] = yy

	# ---- score the candidates (still water = source 0 is the gated set; courses are reported apart)
	var gap_area := [0.0, 0.0]
	var uncovered_cols := [0, 0]
	var cand_n := [0, 0]
	var flush_n := [0, 0]
	var gapcols := {}  # still-water gap columns only
	var exposed_area := 0.0
	var pond_gap := {}  # pond id -> uncovered area
	var pond_cand := {}  # pond id -> candidate count
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
		if sidx == 0:
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
			var pidx: int = cand[c][3]
			pond_gap[pidx] = float(pond_gap.get(pidx, 0.0)) + (1.0 - f)
			pond_cand[pidx] = int(pond_cand.get(pidx, 0)) + 1
		if sidx == 0 and f < GAP_COL_COVER_MIN:
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

	var worst_pond := 0.0
	var ponds_scored := 0
	for pidx in pond_cand.keys():
		ponds_scored += 1
		worst_pond = maxf(worst_pond, float(pond_gap[pidx]))

	# ---- bleed and over: every covered sample point, judged by the column it lies in
	var bleed := 0
	var over := 0
	for key in cov.keys():
		var col := Vector2i(int(floor(float(key.x) / SAMPLES)), int(floor(float(key.y) / SAMPLES)))
		if absi(col.x) >= half or absi(col.y) >= half:
			continue
		if punch.has(col):
			continue
		var lvl2 := -9999
		if wet.has(col):
			lvl2 = int(wet[col][0])
		elif cand.has(col):
			lvl2 = int(cand[col][0])
		if lvl2 == -9999:
			bleed += 1
		elif float(cov[key]) > (4.0 * lvl2 + 2.0 + OVER_TOL_LAT) * sf:
			over += 1

	# ---- witnesses: each must still be a candidate of the recorded level, and be covered
	var w_valid := 0
	var w_area := 0.0
	for w in witness:
		var key := Vector2i(int(w[0]), int(w[1]))
		if cand.has(key) and int(cand[key][0]) == int(w[2]):
			w_valid += 1
		w_area += 1.0 - _covered_fraction(cov, key.x, key.y, int(w[2]), sf, punch)

	var wet_in := [0, 0]
	for k in wet.keys():
		if absi(k.x) < half and absi(k.y) < half:
			wet_in[int(wet[k][1])] += 1
	var rec := {
		"generated_epoch": Time.get_unix_time_from_system(),
		"mutation": _mutation,
		"headless": DisplayServer.get_name() == "headless",
		"plan_hash": StalagWorld.plan_hash(),
		"constants": {
			"FOOTPRINT_HALF_COLS": FOOTPRINT_HALF_COLS, "CHUNK_M": CHUNK_M, "RING_MAX": RING_MAX,
			"COVER_TOL_LAT": COVER_TOL_LAT, "OVER_TOL_LAT": OVER_TOL_LAT, "GAP_COL_COVER_MIN": GAP_COL_COVER_MIN,
			"GAP_AREA_MAX_COLS": GAP_AREA_MAX_COLS, "GAP_CLUSTER_MAX_COLS": GAP_CLUSTER_MAX_COLS,
			"WITNESS_UNCOVERED_MAX": WITNESS_UNCOVERED_MAX, "BLEED_AREA_MAX_COLS": BLEED_AREA_MAX_COLS,
			"OVER_AREA_MAX_COLS": OVER_AREA_MAX_COLS, "POND_GAP_MAX_COLS": POND_GAP_MAX_COLS,
			"EXPOSE_TOL_LAT": EXPOSE_TOL_LAT, "FAR_MARGIN_COLS": FAR_MARGIN_COLS, "EXPOSED_AREA_MAX_COLS": EXPOSED_AREA_MAX_COLS, "BUILD_MS_MAX": BUILD_MS_MAX, "SAMPLES": SAMPLES,
		},
		"far": {"tris": far_n, "xor": str(far_xor), "sum": str(far_sum), "head_tris": int(wj.get("head_far_tris", -1)), "head_xor": str(wj.get("head_far_xor", "-1")), "head_sum": str(wj.get("head_far_sum", "-1"))},
		"water_tris": tris,
		"water_build_ms_max": snappedf(build_ms_max, 0.1),
		"water_build_ms_sum": snappedf(build_ms_sum, 0.1),
		"wet_still_cols": wet_in[0],
		"wet_course_cols": wet_in[1],
		"still": {"candidates": cand_n[0], "flush_candidates": flush_n[0], "uncovered_cols": uncovered_cols[0],
			"gap_area_cols": snappedf(gap_area[0], 0.01), "gap_cols": gapcols.size(), "largest_gap_cluster_cols": largest,
			"exposed_area_cols": snappedf(exposed_area, 0.01), "ponds_total": pond_n, "ponds_scored": ponds_scored, "worst_pond_gap_area_cols": snappedf(worst_pond, 0.01)},
		"course": {"candidates": cand_n[1], "flush_candidates": flush_n[1], "uncovered_cols": uncovered_cols[1],
			"gap_area_cols": snappedf(gap_area[1], 0.01)},
		"bleed_area_cols": snappedf(bleed / float(SAMPLES * SAMPLES), 0.01),
		"over_area_cols": snappedf(over / float(SAMPLES * SAMPLES), 0.01),
		"witness": {"total": witness.size(), "valid": w_valid, "uncovered_area_cols": snappedf(w_area, 0.01),
			"head_still_gap_area_cols": wj.get("head_still_gap_area_cols", -1),
			"head_course_gap_area_cols": wj.get("head_course_gap_area_cols", -1), "head_commit": wj.get("head_commit", "")},
	}
	if OS.get_environment("WATERFILL_LIST") == "1":
		var lst := []
		for c in cand.keys():
			if int(cand[c][2]) == 0:
				lst.append([c.x, c.y, cand[c][0]])
		lst.sort()
		rec["still_candidate_list"] = lst
	var of := FileAccess.open(out_path, FileAccess.WRITE)
	if of == null:
		_fail("cannot write " + out_path)
		return
	of.store_string(JSON.stringify(rec))
	of.close()
	print("WATERFILL ", JSON.stringify(rec))
	quit(0)
