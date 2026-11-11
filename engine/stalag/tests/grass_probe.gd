extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #551 phase 1 -- the measurement of the meadow ground, run inside the REAL world entry
## (the player's own path: shell, `world`, CRT overlay and all). Called by
## frontdoor/scripts/probe_driver.gd after the entry shot, only when GRASS_OUT is set.
## The frozen Stalag prototype (tag prototype-final) drew the one 16 px grass tile this ground
## used to repeat; this probe measures how far the repetition is broken, against that old look.
##
## Everything is measured from rendered pixels:
##   * the OLD look is the same frame drawn with the untouched terrain shader (arm O);
##   * a fixed orthographic top-down window of 20 x 10 squares, one 0.5 m square = 64 px, one texel
##     = 4 px, picks the squares that are flat grass in the old look (the "flat set");
##   * each flat square's 256 texel samples are matched against all 64 (variant, symmetry) cells of
##     the baked strip, and neighbouring flat squares are correlated with each other.
## Negative controls act on the material before the first grab (env GRASS_MUTATE); the production
## path never reads the environment.
##
## Phase 2 (Spec #551): after the grass measurement it runs engine/stalag/tests/ground_probe.gd, which adds
## the record's .ground section (rock, mossy rock, gravel, sand, mud and dirt-wall F, the id oracle, the
## flora and understory exclusion) and the Phase 2 negative controls. The perf arms swap BOTH mesh
## buckets between the ground shader and the terrain shader.
##
## Writes one JSON record to GRASS_OUT (the wrapper tests/verify_grass_look.sh adds the entry
## marker facts and the error count) and shots into STALAG_SHOTS_DIR.

const GroundProbe := preload("res://engine/stalag/tests/ground_probe.gd")
const TERRAIN_SHADER := "res://engine/stalag/shaders/stalag_terrain.gdshader"
const VARIANTS_PATH := "res://game/world/assets/grass_variants.png"
const DECALS_PATH := "res://game/world/assets/grass_decals.png"
const SHIPPED_PATH := "res://game/world/assets/grass_top.png"
const UNIFORMS := [
	"tile", "variants", "decals", "use_skin", "flat_color", "use_fog", "haze_color", "fog_density",
	"variant_count", "use_rotation", "decal_rate", "tint_strength", "tint_swing", "tint_step", "dry_mul", "tint_snap",
]
const MUTATIONS := ["none", "single_variant", "old_shader", "no_decals", "no_tint", "smooth_tint", "unsnapped_tint", "burn"]

const TILES_X := 20
const TILES_Y := 10
const PX := 64  # pixels per 0.5 m square
const TEXEL_PX := 4
const TEXELS := 16
const TOP := 40  # first lattice row, in pixels
const CAM_X := -4.0
const CAM_Z := 0.0
const CAM_UP := 6.0
const ORTHO_SIZE := 5.625  # 720 / 128: one metre is 128 px
const PERF_BLOCKS := 10
const PERF_WARM := 10
const PERF_FRAMES := 60
const BURN_ITERATIONS := 240000  # control strength only: on a busy GPU the A/A noise reached ~10 ms (audit 551-P2), 60000 gave an 18 ms burn
const SETTLE_FRAMES := 3


static func _grab(w: Node) -> Image:
	for k in range(SETTLE_FRAMES):
		await w.get_tree().process_frame
	var img := w.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


static func _luma_of(r: int, g: int, b: int) -> float:
	return 0.2126 * float(r) + 0.7152 * float(g) + 0.0722 * float(b)


# ---- samples and squares ------------------------------------------------------------------

# the 256 texel-centre samples of square (i, j), as RGB bytes
static func _samples(d: PackedByteArray, width: int, i: int, j: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(TEXELS * TEXELS * 3)
	var x0 := PX * i
	var y0 := TOP + PX * j
	var n := 0
	for ty in range(TEXELS):
		for tx in range(TEXELS):
			var o := ((y0 + TEXEL_PX * ty + 2) * width + x0 + TEXEL_PX * tx + 2) * 3
			out[n] = d[o]
			out[n + 1] = d[o + 1]
			out[n + 2] = d[o + 2]
			n += 3
	return out


static func _luma(s: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(TEXELS * TEXELS)
	for k in range(TEXELS * TEXELS):
		out[k] = _luma_of(s[k * 3], s[k * 3 + 1], s[k * 3 + 2])
	return out


static func _near(a: PackedByteArray, b: PackedByteArray, tol: int) -> bool:
	for k in range(a.size()):
		if absi(a[k] - b[k]) > tol:
			return false
	return true


# every 4 x 4 pixel texel block of the square is uniform within 2 per channel
static func _uniform_blocks(d: PackedByteArray, width: int, i: int, j: int) -> bool:
	var x0 := PX * i
	var y0 := TOP + PX * j
	for by in range(TEXELS):
		for bx in range(TEXELS):
			for c in range(3):
				var lo := 255
				var hi := 0
				for py in range(TEXEL_PX):
					for px in range(TEXEL_PX):
						var v := d[((y0 + TEXEL_PX * by + py) * width + x0 + TEXEL_PX * bx + px) * 3 + c]
						lo = mini(lo, v)
						hi = maxi(hi, v)
				if hi - lo > 2:
					return false
	return true


static func _pearson(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := a.size()
	var ma := 0.0
	var mb := 0.0
	for k in range(n):
		ma += a[k]
		mb += b[k]
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for k in range(n):
		var da := a[k] - ma
		var db := b[k] - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	if saa < 1e-9 or sbb < 1e-9:
		return 0.0
	return sab / sqrt(saa * sbb)


static func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, float(a.size()))


static func _median(a: Array) -> float:
	var s := a.duplicate()
	s.sort()
	if s.is_empty():
		return 0.0
	return float(s[s.size() / 2])


# symmetry k of the square, bit 0 transposes, bit 1 flips x, bit 2 flips y
static func _d4(tx: int, ty: int, k: int) -> Vector2i:
	var x := tx
	var y := ty
	if (k & 1) != 0:
		var t := x
		x = y
		y = t
	if (k & 2) != 0:
		x = TEXELS - 1 - x
	if (k & 4) != 0:
		y = TEXELS - 1 - y
	return Vector2i(x, y)


# the 64 candidate luma arrays: variant v under symmetry k
static func _candidates(variants: Image) -> Array:
	var out: Array = []
	var n := variants.get_width() / TEXELS
	for v in range(n):
		for k in range(8):
			var a := PackedFloat32Array()
			a.resize(TEXELS * TEXELS)
			for ty in range(TEXELS):
				for tx in range(TEXELS):
					var m := _d4(tx, ty, k)
					var c := variants.get_pixel(v * TEXELS + m.x, m.y)
					a[ty * TEXELS + tx] = _luma_of(int(round(c.r * 255.0)), int(round(c.g * 255.0)), int(round(c.b * 255.0)))
			out.append({"v": v, "k": k, "luma": a})
	return out


# ---- the flat set, from the old look ------------------------------------------------------

static func _flat_set(o: Image) -> Dictionary:
	var d := o.get_data()
	var width := o.get_width()
	var sq: Array = []
	for j in range(TILES_Y):
		for i in range(TILES_X):
			sq.append(_samples(d, width, i, j))
	# leader clustering: a square joins the first cluster whose leader is within 3 on every channel
	var leaders: Array = []
	var counts: Array = []
	for s in range(sq.size()):
		var placed := false
		for li in range(leaders.size()):
			if _near(sq[s], sq[leaders[li]], 3):
				counts[li] += 1
				placed = true
				break
		if not placed:
			leaders.append(s)
			counts.append(1)
	var best := 0
	for li in range(leaders.size()):
		if counts[li] > counts[best]:
			best = li
	var modal: PackedByteArray = sq[leaders[best]]
	var flat: Array = []
	for j in range(TILES_Y):
		for i in range(TILES_X):
			var s := j * TILES_X + i
			flat.append(_near(sq[s], modal, 3) and _uniform_blocks(d, width, i, j))
	var pairs: Array = []
	for j in range(TILES_Y):
		for i in range(TILES_X):
			if not flat[j * TILES_X + i]:
				continue
			if i + 1 < TILES_X and flat[j * TILES_X + i + 1]:
				pairs.append([j * TILES_X + i, j * TILES_X + i + 1])
			if j + 1 < TILES_Y and flat[(j + 1) * TILES_X + i]:
				pairs.append([j * TILES_X + i, (j + 1) * TILES_X + i])
	var n_flat := 0
	for f in flat:
		if f:
			n_flat += 1
	return {"flat": flat, "pairs": pairs, "n_flat": n_flat}


# ---- repetition metrics for one arm -------------------------------------------------------

static func _repeat(img: Image, fs: Dictionary, cands: Array) -> Dictionary:
	var d := img.get_data()
	var width := img.get_width()
	var flat: Array = fs["flat"]
	var lumas := {}
	for s in range(flat.size()):
		if flat[s]:
			lumas[s] = _luma(_samples(d, width, s % TILES_X, s / TILES_X))
	var similar := 0
	for p in fs["pairs"]:
		if _pearson(lumas[p[0]], lumas[p[1]]) >= 0.9:
			similar += 1
	var vs := {}
	var ks := {}
	var vt := {}
	var matched := 0
	var v0 := 0
	for s in lumas.keys():
		var best_r := -2.0
		var best_c = null
		for c in cands:
			var r := _pearson(lumas[s], c["luma"])
			if r > best_r:
				best_r = r
				best_c = c
		if best_r >= 0.9:
			matched += 1
			vs[best_c["v"]] = true
			ks[best_c["k"]] = true
			vt[Vector2i(best_c["v"], best_c["k"])] = true
			if best_c["v"] == 0:
				v0 += 1
	return {"similar_pairs": similar, "variants_used": vs.size(), "transforms_used": ks.size(), "vt_pairs": vt.size(),
		"v0_squares": v0, "matched_squares": matched}


static func _distinct_rgb(img: Image, fs: Dictionary) -> int:
	var d := img.get_data()
	var width := img.get_width()
	var seen := {}
	var flat: Array = fs["flat"]
	for s in range(flat.size()):
		if not flat[s]:
			continue
		var x0 := PX * (s % TILES_X)
		var y0 := TOP + PX * (s / TILES_X)
		for y in range(y0, y0 + PX):
			for x in range(x0, x0 + PX):
				var o := (y * width + x) * 3
				seen[(d[o] << 16) | (d[o + 1] << 8) | d[o + 2]] = true
	return seen.size()


static func _nonuniform(img: Image, fs: Dictionary) -> int:
	var d := img.get_data()
	var width := img.get_width()
	var flat: Array = fs["flat"]
	var n := 0
	for s in range(flat.size()):
		if flat[s] and not _uniform_blocks(d, width, s % TILES_X, s / TILES_X):
			n += 1
	return n


# share of the non-flat squares' pixels where a and b differ by more than 8 in any channel
static func _slope_diff(a: Image, b: Image, fs: Dictionary) -> float:
	var da := a.get_data()
	var db := b.get_data()
	var width := a.get_width()
	var flat: Array = fs["flat"]
	var changed := 0
	var total := 0
	for s in range(flat.size()):
		if flat[s]:
			continue
		var x0 := PX * (s % TILES_X)
		var y0 := TOP + PX * (s / TILES_X)
		for y in range(y0, y0 + PX):
			for x in range(x0, x0 + PX):
				var o := (y * width + x) * 3
				total += 1
				if absi(da[o] - db[o]) > 8 or absi(da[o + 1] - db[o + 1]) > 8 or absi(da[o + 2] - db[o + 2]) > 8:
					changed += 1
	return float(changed) / maxf(1.0, float(total))


# share of the lower-half pixels where a and b differ by more than 8 in any channel
static func _lower_diff(a: Image, b: Image) -> float:
	var da := a.get_data()
	var db := b.get_data()
	var width := a.get_width()
	var height := a.get_height()
	var changed := 0
	var total := 0
	for y in range(height / 2, height):
		for x in range(width):
			var o := (y * width + x) * 3
			total += 1
			if absi(da[o] - db[o]) > 8 or absi(da[o + 1] - db[o + 1]) > 8 or absi(da[o + 2] - db[o + 2]) > 8:
				changed += 1
	return float(changed) / maxf(1.0, float(total))


# ---- the scene ----------------------------------------------------------------------------

static func _hide_chunk_roots(w: Node) -> bool:
	var streamer: Node3D = w.get_node("Streamer")
	var hidden := 0
	for c in streamer.chunk_coords():
		for nm in ["Flora", "Trees", "Understory"]:
			var n: Node = streamer.chunk_node(c).get_node_or_null(nm)
			if n != null:
				n.visible = false
				hidden += 1
	return hidden > 0


static func _pose_nadir(w: Node) -> void:
	var cam: Camera3D = w.cam
	cam.target = null
	cam.look_active = false
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = ORTHO_SIZE
	var feet := StalagWorld.spawn_feet_y()
	cam.global_position = Vector3(CAM_X, feet + CAM_UP, CAM_Z)
	cam.look_at(Vector3(CAM_X, feet, CAM_Z), Vector3(0.0, 0.0, -1.0))


static func _uniform_names(shader: Shader) -> Dictionary:
	var names := {}
	for u in shader.get_shader_uniform_list():
		names[String(u["name"])] = true
	return names


static func _apply_mutation(mat: ShaderMaterial, mutation: String) -> void:
	if mutation == "single_variant":
		mat.set_shader_parameter("variant_count", 1)
		mat.set_shader_parameter("use_rotation", false)
	elif mutation == "old_shader":
		mat.shader = load(TERRAIN_SHADER)
	elif mutation == "no_decals":
		mat.set_shader_parameter("decal_rate", 0.0)
	elif mutation == "no_tint":
		mat.set_shader_parameter("tint_strength", 0.0)
	elif mutation == "smooth_tint":
		mat.set_shader_parameter("tint_step", 0.0)
	elif mutation == "unsnapped_tint":
		mat.set_shader_parameter("tint_snap", false)
	elif mutation == "burn":
		# a long dependent ALU loop appended to the fragment source, in memory only
		var s := Shader.new()
		var loop := "\tfloat burn_acc = ALBEDO.g;\n\tfor (int bi = 0; bi < %d; bi++) { burn_acc = sin(burn_acc * 1.7 + float(bi)) * 0.5 + 0.5; }\n\tALBEDO += vec3(burn_acc * 0.0001);\n\tROUGHNESS = 1.0;" % BURN_ITERATIONS
		s.code = mat.shader.code.replace("\tROUGHNESS = 1.0;", loop)
		mat.shader = s


# GPU render time, interleaved: new shader, old shader, old shader again, PERF_BLOCKS times. Phase 2: both
# buckets change together (the dirt bucket wears the ground shader too), so the old arm is the prototype's
# terrain shader on both and the delta is the whole cost of the ground look.
static func _perf(w: Node, mat: ShaderMaterial, new_shader: Shader, old_shader: Shader, burn: bool) -> Dictionary:
	var rid: RID = w.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var dirt: ShaderMaterial = w.dirt_mat
	var dirt_new: Shader = dirt.shader
	var arms: Array = [new_shader, old_shader, old_shader]
	var dirt_arms: Array = [dirt_new, old_shader, old_shader]
	var samples: Array = [[], [], []]
	for b in range(PERF_BLOCKS):
		for a in range(3):
			mat.shader = arms[a]
			dirt.shader = dirt_arms[a]
			for f in range(PERF_WARM + PERF_FRAMES):
				await w.get_tree().process_frame
				if f >= PERF_WARM:
					samples[a].append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	mat.shader = new_shader
	dirt.shader = dirt_new
	var nm := _median(samples[0])
	var om := _median(samples[1])
	var o2 := _median(samples[2])
	return {"blocks": PERF_BLOCKS, "frames_per_arm_block": PERF_FRAMES, "samples_per_arm": samples[0].size(),
		"new_median_ms": nm, "old_median_ms": om, "old2_median_ms": o2, "delta_ms": nm - om,
		"aa_noise_ms": absf(om - o2), "burn": burn}


static func _assets() -> Dictionary:
	var v := Image.load_from_file(VARIANTS_PATH)
	var d := Image.load_from_file(DECALS_PATH)
	var s := Image.load_from_file(SHIPPED_PATH)
	v.convert(Image.FORMAT_RGBA8)
	d.convert(Image.FORMAT_RGBA8)
	s.convert(Image.FORMAT_RGBA8)
	var binary := true
	var dd := d.get_data()
	for k in range(3, dd.size(), 4):
		if dd[k] != 0 and dd[k] != 255:
			binary = false
	return {
		"variants_n": v.get_width() / TEXELS, "decals_n": d.get_width() / TEXELS,
		"variants_w": v.get_width(), "variants_h": v.get_height(),
		"decals_w": d.get_width(), "decals_h": d.get_height(),
		"v0_equals_shipped": v.get_region(Rect2i(0, 0, TEXELS, TEXELS)).get_data() == s.get_data(),
		"decal_alpha_binary": binary,
	}


## Runs the whole measurement. `entry_path` is the already-saved entry_world.png.
static func run(w: Node, entry_path: String, shots_dir: String, out_path: String) -> void:
	var mutation := OS.get_environment("GRASS_MUTATE")
	if mutation.is_empty():
		mutation = "none"
	var mat: ShaderMaterial = w.grass_mat
	var terrain: Shader = load(TERRAIN_SHADER)
	_apply_mutation(mat, mutation)
	var shipped_shader: Shader = mat.shader
	var present := _uniform_names(shipped_shader)
	var uniforms_present := true
	for u in UNIFORMS:
		if not present.has(u):
			uniforms_present = false
	var rec := {"generated_epoch": Time.get_unix_time_from_system(), "mutation": mutation,
		"headless": DisplayServer.get_name() == "headless", "adapter": RenderingServer.get_video_adapter_name(),
		"project_name": str(ProjectSettings.get_setting("application/config/name"))}
	rec["look"] = {
		"shader_path": shipped_shader.resource_path, "dirt_shader_path": w.dirt_mat.shader.resource_path,
		"uniforms_present": uniforms_present,
		"variant_count": mat.get_shader_parameter("variant_count"), "use_rotation": mat.get_shader_parameter("use_rotation"),
		"tint_snap": mat.get_shader_parameter("tint_snap"), "tint_strength": mat.get_shader_parameter("tint_strength"),
		"tint_step": mat.get_shader_parameter("tint_step"), "decal_rate": mat.get_shader_parameter("decal_rate"),
	}
	rec["assets"] = _assets()

	# ---- at the entry pose, as the player sees it (CRT overlay on, flora on)
	var entry_img := Image.load_from_file(entry_path)
	var s_entry := await _grab(w)
	s_entry.save_png(shots_dir.path_join("grass_entry_new.png"))
	mat.shader = terrain
	var o_entry := await _grab(w)
	o_entry.save_png(shots_dir.path_join("grass_entry_old.png"))
	var o_entry2 := await _grab(w)
	mat.shader = shipped_shader
	rec["entry"] = {"shot_w": entry_img.get_width(), "shot_h": entry_img.get_height(), "shot_file": entry_path,
		"lower_diff_frac": _lower_diff(s_entry, o_entry), "aa_diff_frac": _lower_diff(o_entry, o_entry2)}
	var ground_mutation: bool = mutation in GroundProbe.MUTATIONS
	if ground_mutation:
		rec["perf"] = {"skipped": true}  # the phase 2 controls read the .ground section only
	else:
		rec["perf"] = await _perf(w, mat, shipped_shader, terrain, mutation == "burn")

	# ---- the nadir window
	var crt: Node = w.get_tree().root.find_child("CRTLayer", true, false)
	if crt != null:
		crt.visible = false
	w.walker.visible = false
	var flora_hidden := _hide_chunk_roots(w)
	w.flora_clock_frozen = true
	_pose_nadir(w)
	mat.shader = terrain
	var o1 := await _grab(w)
	var o2 := await _grab(w)
	var aa_identical := o1.get_data() == o2.get_data()
	mat.shader = shipped_shader
	var s_img := await _grab(w)
	o1.save_png(shots_dir.path_join("grass_nadir_old.png"))
	s_img.save_png(shots_dir.path_join("grass_nadir_new.png"))
	var d_img: Image = null
	var t_img: Image = null
	var v_img: Image = null
	if uniforms_present:
		var rate = mat.get_shader_parameter("decal_rate")
		var strength = mat.get_shader_parameter("tint_strength")
		mat.set_shader_parameter("decal_rate", 0.0)
		d_img = await _grab(w)
		mat.set_shader_parameter("decal_rate", rate)
		mat.set_shader_parameter("tint_strength", 0.0)
		t_img = await _grab(w)
		mat.set_shader_parameter("decal_rate", 0.0)
		v_img = await _grab(w)
		mat.set_shader_parameter("decal_rate", rate)
		mat.set_shader_parameter("tint_strength", strength)

	var fs := _flat_set(o1)
	var cands := _candidates(Image.load_from_file(VARIANTS_PATH))
	var n_nonflat := TILES_X * TILES_Y - int(fs["n_flat"])
	rec["window"] = {
		"viewport_w": o1.get_width(), "viewport_h": o1.get_height(), "px_per_tile": float(o1.get_height()) / ORTHO_SIZE * 0.5,
		"tiles_x": TILES_X, "tiles_y": TILES_Y, "cam_x": CAM_X, "cam_z": CAM_Z, "selection": "old_look_modal",
		"old_arm_shader": terrain.resource_path, "flora_hidden": flora_hidden, "crt_hidden": crt != null and not crt.visible,
		"aa_identical": aa_identical, "flat_squares": fs["n_flat"], "pairs": fs["pairs"].size(),
	}
	rec["repeat"] = {"old_look": _repeat(o1, fs, cands), "shipped": _repeat(s_img, fs, cands)}
	rec["slope"] = {"squares": n_nonflat, "diff_frac": _slope_diff(v_img, o1, fs) if v_img != null else 0.0}

	var changed := 0
	var shifted := 0
	var fmin := 1.0
	var fmax := 1.0
	var sd := s_img.get_data()
	var width := s_img.get_width()
	var flat: Array = fs["flat"]
	for s in range(flat.size()):
		if not flat[s]:
			continue
		var i := s % TILES_X
		var j := s / TILES_X
		var ss := _samples(sd, width, i, j)
		if d_img != null and not _near(ss, _samples(d_img.get_data(), width, i, j), 8):
			changed += 1
		if t_img != null:
			var fac := _mean(_luma(ss)) / maxf(1e-6, _mean(_luma(_samples(t_img.get_data(), width, i, j))))
			if absf(fac - 1.0) >= 0.10:
				shifted += 1
			fmin = minf(fmin, fac)
			fmax = maxf(fmax, fac)
	rec["decals"] = {"squares_changed": changed}
	rec["tint"] = {"squares_shifted": shifted, "factor_min": fmin, "factor_max": fmax}
	rec["crisp"] = {"nonuniform_squares": _nonuniform(s_img, fs), "distinct_rgb": _distinct_rgb(s_img, fs),
		"distinct_rgb_old": _distinct_rgb(o1, fs), "texel_px": TEXEL_PX}

	if crt != null:
		crt.visible = true
	w.walker.visible = true

	# ---- phase 2: the ground materials and the flora exclusion (the negative controls act inside)
	rec["assets"].merge(GroundProbe.assets())
	rec["ground"] = await GroundProbe.run(w, mutation, shots_dir)
	var out := FileAccess.open(out_path, FileAccess.WRITE)
	out.store_string(JSON.stringify(rec))
	out.close()
	print("PROBE_GRASS_DONE mutation=%s" % mutation)
