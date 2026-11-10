extends SceneTree
## Spec #545 flora probe (headless, no GPU). It only MEASURES -- tests/verify_stalag_flora.sh pairs
## it with the fresh JS oracle (tools/baseline/js_flora_oracle.mjs) and the DoD's jq does the judging.
##
## Env: FLORA_PROBE_RAW     output JSON path (required)
##      FLORA_ORACLE_DIR    directory written by the oracle (required)
##      FLORA_MUTATE        none | lid_shift | flood_ignore | salt_swap | wind_no_gust | wind_flow_sign | wind_no_terrain
##
## Record (engine side only; the wrapper adds the JS side and the epoch):
##   {classes, world, placement{total_gd, lids_gd, determinism_equal, excluded_forms_leaked, off_lid,
##    flooded_or_course, forms[{id, gd_count, gd_hash}], chunks{count, gd_union_hash, sum},
##    ported_checks{4}}, wind{samples, mismatch, max_abs_err, parts[{name, n, mismatch}], ported_checks{15}}}

const PARTS := {
	"boundary": 1, "deflect": 2, "flow": 2, "front": 7, "gust": 1, "katabatic": 3,
	"prevail": 1, "thermal": 1, "vnoise3": 1, "vorticle": 3, "windat": 4,
}
const EXCLUDED := ["cover-billboard-mat", "shrub-billboard-star", "rock-mossy", "rock-sensor"]

var _sf := 1.0


func _fail(msg: String) -> void:
	push_error("flora_probe: " + msg)
	quit(2)


func _sha(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(bytes)
	return h.finish().hex_encode()


func _read_all(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


func _initialize() -> void:
	var raw := OS.get_environment("FLORA_PROBE_RAW")
	var odir := OS.get_environment("FLORA_ORACLE_DIR")
	var mutation := OS.get_environment("FLORA_MUTATE")
	if mutation.is_empty():
		mutation = "none"
	if raw.is_empty() or odir.is_empty() or not ClassDB.class_exists("StalagFlora") or not ClassDB.class_exists("StalagWind"):
		_fail("FLORA_PROBE_RAW / FLORA_ORACLE_DIR required and StalagFlora, StalagWind must be loaded")
		return
	_sf = StalagWorld.get_sf()
	if mutation.begins_with("wind_"):
		StalagWind.set_mutation(mutation.trim_prefix("wind_"))
	else:
		StalagFlora.set_mutation(mutation)

	StalagWorld.start_plan()
	while StalagWorld.plan_status() == 1:
		OS.delay_msec(20)
	if StalagWorld.plan_status() != 2:
		_fail("plan solve failed: " + StalagWorld.plan_error())
		return

	var out := {}
	out["classes"] = {"StalagFlora": true, "StalagWind": true}
	out["world"] = {"seed": StalagWorld.get_seed(), "extent": StalagWorld.get_extent(), "chunk_m": StalagWorld.get_chunk_m()}
	out["placement"] = _placement()
	out["wind"] = _wind(odir)
	var f := FileAccess.open(raw, FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	quit(0)


# ---------------------------------------------------------------- placement
func _placement() -> Dictionary:
	var ids: PackedStringArray = StalagFlora.form_ids()
	var g1: Dictionary = StalagFlora.place_global()
	var g2: Dictionary = StalagFlora.place_global()
	var forms := []
	var total := 0
	var det_equal := true
	for id in ids:
		var a: PackedFloat64Array = g1[id]
		var b: PackedFloat64Array = g2[id]
		var ba := a.to_byte_array()
		forms.append({"id": id, "gd_count": a.size() / 7, "gd_hash": _sha(ba)})
		total += a.size() / 7
		if _sha(b.to_byte_array()) != _sha(ba):
			det_equal = false
	var leaked := 0
	for k in g1.keys():
		if k != "_lids" and not ids.has(k):
			leaked += 1
	for e in EXCLUDED:
		if g1.has(e) or ids.has(e):
			leaked += 1

	# independent lid and column checks over the instances' own lid centres
	var seen := {}
	var off_lid := 0
	var fl_course := 0
	var dry := StalagWorld.water_dry_sentinel()
	for id in ids:
		var a: PackedFloat64Array = g1[id]
		for i in range(a.size() / 7):
			var o := i * 7
			var x := a[o]
			var y := a[o + 1]
			var z := a[o + 2]
			var lx := a[o + 5]
			var lz := a[o + 6]
			var key := Vector2(lx, lz)
			if not seen.has(key):
				seen[key] = _lid_height(lx, lz)  # NaN when not a lid
				var gx := int(floor(lx / 0.5))
				var gz := int(floor(lz / 0.5))
				if StalagWorld.is_flooded(gx, gz) or StalagWorld.course_level_at(gx, gz) != dry:
					seen[key] = [seen[key], true]
				else:
					seen[key] = [seen[key], false]
			var info: Array = seen[key]
			var h: float = info[0]
			var bad := is_nan(h) or absf(x - lx) > 0.15 + 1e-9 or absf(z - lz) > 0.15 + 1e-9 or y <= 0.0
			if not bad and absf(y - (h + 2.0) * _sf) > 1e-9:
				bad = true
			if bad:
				off_lid += 1
			if info[1]:
				fl_course += 1

	# per-chunk union
	var cm: float = StalagWorld.get_chunk_m()
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	var sum := 0
	var nchunks := 0
	for cz in range(-5, 5):
		for cx in range(-5, 5):
			var d: Dictionary = StalagFlora.place_chunk(cx, cz)
			var any := false
			for id in ids:
				var a: PackedFloat64Array = d[id]
				if a.size() > 0:
					any = true
					sum += a.size() / 7
					hc.update(a.to_byte_array())
			if any:
				nchunks += 1
	var union_hash := hc.finish().hex_encode()
	var names_ok := true
	for e in EXCLUDED:
		if ids.has(e):
			names_ok = false
	var all_forms := true
	for f in forms:
		if f["gd_count"] <= 0:
			all_forms = false
	return {
		"total_gd": total,
		"lids_gd": int(g1["_lids"]),
		"determinism_equal": det_equal,
		"excluded_forms_leaked": leaked,
		"off_lid": off_lid,
		"flooded_or_course": fl_course,
		"forms": forms,
		"chunks": {"count": nchunks, "gd_union_hash": union_hash, "sum": sum},
		"ported_checks": {
			"DETERMINISM": det_equal,
			"ALL_FORMS_HAVE_INSTANCES": all_forms,
			"LID_ONLY": total > 0 and off_lid == 0,
			"EXCLUDED_FORMS_ZERO": names_ok and leaked == 0,
		},
	}


# terrace height of the lid whose centre is (lx, lz) metres, or NaN when no lid is centred there.
# An independent GDScript restatement of the lid rule through the carved surface-height query.
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


func _terrace(cx: int, cz: int) -> float:
	return floor(StalagWorld.surface_height(float(cx), float(cz)) / 4.0) * 4.0


# ---------------------------------------------------------------- wind
func _wind(odir: String) -> Dictionary:
	var sb := _read_all(odir.path_join("samples.bin"))
	if sb.is_empty():
		_fail("cannot read samples.bin")
		return {}
	var samples := sb.to_float64_array()
	var n := samples.size() / 4
	var res: Dictionary = StalagWind.run_samples(samples)
	var parts := []
	var mismatch_total := 0
	var max_err := 0.0
	for name in PARTS.keys():
		var k: int = PARTS[name]
		var want := _read_all(odir.path_join("wind_%s.bin" % name))
		var got: PackedFloat64Array = res[name]
		var gb := got.to_byte_array()
		var bad := 0
		if gb.size() != want.size():
			bad = n
		else:
			var wf := want.to_float64_array()
			for i in range(n):
				var s := i * k * 8
				if gb.slice(s, s + k * 8) != want.slice(s, s + k * 8):
					bad += 1
					for j in range(k):
						var d := absf(got[i * k + j] - wf[i * k + j])
						if not is_nan(d) and d > max_err:
							max_err = d
		parts.append({"name": name, "n": n, "mismatch": bad})
		mismatch_total += bad
	parts.sort_custom(func(a, b): return a["name"] < b["name"])
	return {
		"samples": n,
		"mismatch": mismatch_total,
		"max_abs_err": max_err,
		"parts": parts,
		"ported_checks": _wind_checks(),
	}


func _vec(d: Dictionary) -> Array:
	return [d["vx"], d["vy"], d["vz"]]


func _wind_checks() -> Dictionary:
	var S := StalagWorld.get_seed()
	var sf := _sf
	var c := {}
	var r: Dictionary = StalagWind.wind_at_seed(10, 2, 5, 100, S)
	var v := _vec(r)
	c["shape"] = v.all(func(x): return is_finite(x)) and r["strength"] >= 0.0 and r["strength"] <= 1.0
	var a: Dictionary = StalagWind.wind_at_seed(10, 2, 5, 100, S)
	c["deterministic"] = a == StalagWind.wind_at_seed(10, 2, 5, 100, S)
	c["stable"] = a == StalagWind.wind_at_seed(10, 2, 5, 100, S)
	c["varies"] = _vec(StalagWind.wind_at_seed(0, 5, 0, 0, S)) != _vec(StalagWind.wind_at_seed(100, 5, 80, 500, S))
	c["seed_differs"] = _vec(StalagWind.wind_at_seed(10, 2, 5, 100, S + 1)) != _vec(a)
	var t_top: float = StalagWorld.surface_height(0.0, 0.0) * sf
	var lo: Dictionary = StalagWind.wind_at_seed(0, t_top + 0.5, 0, 20, S)
	var hi: Dictionary = StalagWind.wind_at_seed(0, t_top + 14, 0, 20, S)
	c["bl_rises"] = hi["strength"] >= lo["strength"]
	c["live_aloft"] = hi["strength"] > 0.0
	var max_vy := -INF
	var therm_at := [0, 0, 0]
	for tq in range(0, 601, 30):
		for gx in range(-30, 31, 6):
			for gz in range(-30, 31, 6):
				var yg: float = StalagWorld.surface_height(gx / sf, gz / sf) * sf + 1.0
				var vy: float = StalagWind.wind_at_seed(gx, yg, gz, tq, S)["vy"]
				if vy > max_vy:
					max_vy = vy
					therm_at = [gx, gz, tq]
	c["thermal_vy_positive"] = max_vy > 0.05
	c["thermal_nonneg"] = StalagWind.thermal(0, 0, 120, S, 0.5) >= 0.0 and StalagWind.thermal(therm_at[0], therm_at[1], therm_at[2], S, 1.0) > 0.0
	var down := false
	var tk := 250
	while tk <= 600 and not down:
		var gx := -30
		while gx <= 30 and not down:
			var gz := -30
			while gz <= 30 and not down:
				var g := _grad(gx, gz)
				var slope := sqrt(g[0] * g[0] + g[1] * g[1])
				if slope >= 0.05:
					var k: PackedFloat64Array = StalagWind.katabatic(gx, gz, tk, S, 0.5)
					var mag := sqrt(k[0] * k[0] + k[2] * k[2])
					if mag >= 1e-4 and (k[0] * -g[0] + k[2] * -g[1]) / slope > 0.0:
						down = true
				gz += 5
			gx += 5
		tk += 30
	c["katabatic_downslope"] = down
	var vort = null
	var vt := 120
	while vt <= 600 and vort == null:
		for vv in StalagWind.active_vorticles(vt, S, 0, 0, 84):
			if vv["kind"] == "vortex":
				vort = vv
				break
		vt += 18
	vt -= 18
	var px: float = vort["cx"] + 3.0 if vort != null else 8.0
	var pz: float = vort["cz"] if vort != null else 5.0
	var vfa: PackedFloat64Array = StalagWind.vorticle_field(px, pz, vt, S)
	c["vorticle_deterministic"] = vort != null and vfa == StalagWind.vorticle_field(px, pz, vt, S) \
		and (vfa[0] != 0.0 or vfa[1] != 0.0 or vfa[2] != 0.0) and StalagWind.vorticle_field(px, pz, vt, S + 1) != vfa
	var curl := 0.0
	if vort != null:
		var d := 3.0
		var e: PackedFloat64Array = StalagWind.vorticle_field(vort["cx"] + d, vort["cz"], vt, S)
		var w: PackedFloat64Array = StalagWind.vorticle_field(vort["cx"] - d, vort["cz"], vt, S)
		var nn: PackedFloat64Array = StalagWind.vorticle_field(vort["cx"], vort["cz"] + d, vt, S)
		var ss: PackedFloat64Array = StalagWind.vorticle_field(vort["cx"], vort["cz"] - d, vt, S)
		curl = absf((e[2] - w[2]) / (2.0 * d) - (nn[0] - ss[0]) / (2.0 * d))
	c["vorticle_curl"] = vort != null and curl > 0.05
	var fgain := 1.0
	for tt in range(0, 601, 2):
		fgain = maxf(fgain, StalagWind.front_gain(3, 3, tt, S)["gain"])
	c["front_modulation"] = fgain > 1.3
	var hi_n := 0
	var tot_n := 0
	var t2 := 0.0
	while t2 <= 2000.0:
		tot_n += 1
		if StalagWind.front_gain(7, 2, t2, S)["sbs"] >= 4.0:
			hi_n += 1
		t2 += 0.5
	c["front_budget_sbs4_low"] = float(hi_n) / float(tot_n) < 0.20
	var rng_free := true
	var rx := RegEx.new()
	rx.compile("randf|randi|rand_range|RandomNumberGenerator|std::rand|random_device")
	for p in ["res://engine/stalag/src/stalag_wind.cpp", "res://engine/stalag/src/stalag_flora.cpp"]:
		var txt := FileAccess.get_file_as_string(p)
		if txt.is_empty() or rx.search(txt) != null:
			rng_free = false
	c["no_platform_rng"] = rng_free
	return c


# terrain gradient (finite differences, 1 m) exactly as the ported test builds it
func _grad(x: float, z: float) -> Array:
	var sf := _sf
	var hpx: float = StalagWorld.surface_height((x + 1.0) / sf, z / sf) * sf
	var hmx: float = StalagWorld.surface_height((x - 1.0) / sf, z / sf) * sf
	var hpz: float = StalagWorld.surface_height(x / sf, (z + 1.0) / sf) * sf
	var hmz: float = StalagWorld.surface_height(x / sf, (z - 1.0) / sf) * sf
	return [(hpx - hmx) / 2.0, (hpz - hmz) / 2.0]
