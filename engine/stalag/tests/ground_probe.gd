extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #551 phase 2 -- the measurement of the ground materials, run inside the REAL world entry by
## engine/stalag/tests/grass_probe.gd (the player's own path: shell, `world`, CRT overlay and all).
## The frozen Stalag prototype (tag prototype-final) drew one grass tile and one dirt tile over this
## ground; this probe measures that rock, mossy rock, gravel, sand, mud and dirt-wall F wear the right
## places and are not repeated tiles, and that the meadow's flora stays off mud and sand.
##
## Everything is measured from rendered pixels at fixed orthographic windows of 20 x 10 squares (one
## 0.5 m square = 64 px, one texel = 4 px), top-down for tops and face-on for walls:
##   * ID arm: the ground shader's own code with its output replaced by the material id it chose
##     (built in memory, never on disk, unshaded so the painted byte is the byte read back); N arm: the
##     same with the face normal. A top square belongs to a material when all 256 of its texel samples carry
##     that id on a flat top; a wall square when at least MASK_MIN_WALL of them carry it on a face turned
##     straight at the camera (the lattice's slanted faces share every wall square);
##   * V arm: the shader's chosen texel before light and fog, decals and tint off, i.e. the atlas bytes themselves;
##     the selected texels' luma is matched against the 64 candidates "variant v of the material's atlas row
##     under symmetry k" (Pearson >= 0.9); two neighbouring squares are "similar" when they wear the same
##     variant under the same symmetry;
##   * D and T arms (decals off, tint off) measure that decals and the tint are really drawn.
## Light is made flat for the windows (the sun's shadows and the fog are off, restored after) so that a
## uniform texel block means a crisp texture and a palette can be counted.
## The id oracle for tops replays the shader's rule in script from the committed fields image (the column
## id and the ragged border draw) at every flat texel sample. For walls, each sample's ray is cast into
## the chunk meshes the engine drew and the rule is evaluated at the hit from the committed wall field,
## where the rule gives one answer for the column and the eight around it.
## Negative controls act before the first grab (the caller passes GRASS_MUTATE); the production path
## never reads the environment.

const GROUND_SHADER := "res://engine/stalag/shaders/stalag_grass.gdshader"
const TERRAIN_SHADER := "res://engine/stalag/shaders/stalag_terrain.gdshader"
const ATLAS_PATH := "res://game/world/assets/ground/atlas.png"
const DECALS_PATH := "res://game/world/assets/ground/decals.png"
const FIELDS_TOP_PATH := "res://game/world/assets/ground/fields_top.png"
const FIELDS_WALL_PATH := "res://game/world/assets/ground/fields_wall.png"
const FIELDS_SHA_PATH := "res://game/world/assets/ground/fields_sha.json"
const RULES_PATH := "res://game/world/assets/ground/rules.json"
const GRASS_VARIANTS_PATH := "res://game/world/assets/grass_variants.png"
const DIRT_SHIPPED_PATH := "res://game/world/assets/dirt_side.png"
const MUTATIONS := ["mask_off", "wall_rotate", "fields_swapped", "no_fields", "mud_black", "old_dirt_wall"]

const M_GRASS := 0
const M_DIRT := 1
const M_ROCK := 2
const M_MOSS := 3
const MAT_IDS := {"grass": 0, "dirt_wall": 1, "rock": 2, "moss": 3, "gravel": 4, "sand": 5, "mud": 6}
const MAT_ORDER := ["gravel", "sand", "mud", "rock", "moss", "dirt_wall"]

const TILES_X := 20
const TILES_Y := 10
const PX := 64
const TEXEL_PX := 4
const TEXELS := 16
const TOP := 40
const ORTHO_SIZE := 5.625
const SETTLE_FRAMES := 3
const ID_STEP := 25  # the id arm paints byte id * 25 + 12
const ID_BASE := 12
const COL_M := 0.5
const FIELD_DIM := 448
const FIELD_ORIGIN := 224
const EDGE_K := [32768, 20971, 11796, 5243, 0, 0, 0, 0]
const MASK_MIN_TOP := 256  # a top square must be wholly the material, flat
const MASK_MIN_WALL := 48  # a wall square must show at least this many of its 256 texels as the material's straight face
const MATCH_MIN := 0.9
# A rendered square counts as tinted when the tint, switched off, changes at least TINT_TEXELS_MIN of its
# texels by TINT_TEXEL_MIN in luma: the ordered dither flips a share of the texels by one brightness quantum
# (0.10 of the albedo, about 4 percent of the output byte luma), and the share grows with the tint's value there.
const TINT_TEXEL_MIN := 0.03
const TINT_TEXELS_MIN := 8
# Wall symmetries the shader may use, in screen terms: identity and the mirror across the vertical axis
# (the image's top row is world up, so strata stay level). Bit 1 of the symmetry index flips x.
const WALL_ALLOWED_K := [0, 2]

# Fixed windows (seed-7 world, plan hash 4448de3c, checked by the fields wrapper). Top windows: nadir,
# [centre x, surface height y, centre z] in metres, the centre on the 0.5 m lattice. Wall windows: face-on
# to the outward normal n = (nx, nz), centre c = (x, y, z), the tangent and height of the centre on the
# lattice. Squares from every window of a material are pooled.
const TOP_WINDOWS := {
	"gravel": [[78.0, 2.75, -19.5], [18.5, 2.75, 81.5], [6.0, 3.25, 83.5]],
	"sand": [[5.0, 1.25, 44.5], [5.5, 1.25, 64.0]],
	"mud": [[3.5, 0.25, 27.5], [3.5, 0.75, 37.5]],
}
const WALL_WINDOWS := {
	"rock": [{"c": [8.5, 3.0, 0.0], "n": [1, 0]}],
	"moss": [{"c": [3.5, 3.0, 0.0], "n": [-1, 0]}],
	"dirt_wall": [{"c": [0.0, 3.0, 11.0], "n": [1, 0]}],
}


# ---- images, samples ----------------------------------------------------------------------------

static func _grab(w: Node) -> Image:
	for k in range(SETTLE_FRAMES):
		await w.get_tree().process_frame
	var img: Image = w.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


static func _luma_of(r: int, g: int, b: int) -> float:
	return 0.2126 * float(r) + 0.7152 * float(g) + 0.0722 * float(b)


static func _sample_off(width: int, i: int, j: int, tx: int, ty: int) -> int:
	return ((TOP + PX * j + TEXEL_PX * ty + 2) * width + PX * i + TEXEL_PX * tx + 2) * 3


static func _decode_id(r: int) -> int:
	var id := int(round(float(r - ID_BASE) / float(ID_STEP)))
	if id < 0 or id > 8 or absi(r - (id * ID_STEP + ID_BASE)) > 8:
		return -1
	return id


# every 4 x 4 pixel texel block of the square is uniform within 2 per channel


static func _samples(d: PackedByteArray, width: int, i: int, j: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(TEXELS * TEXELS * 3)
	var n := 0
	for ty in range(TEXELS):
		for tx in range(TEXELS):
			var o := _sample_off(width, i, j, tx, ty)
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


# symmetry k of the square: bit 0 transposes, bit 1 flips x, bit 2 flips y
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


# the 64 candidate luma arrays of one atlas row: variant v under symmetry k
static func _candidates(atlas: Image, row: int) -> Array:
	var out: Array = []
	for v in range(8):
		for k in range(8):
			var a := PackedFloat32Array()
			a.resize(TEXELS * TEXELS)
			for ty in range(TEXELS):
				for tx in range(TEXELS):
					var m := _d4(tx, ty, k)
					var c := atlas.get_pixel(v * TEXELS + m.x, row * TEXELS + m.y)
					a[ty * TEXELS + tx] = _luma_of(int(round(c.r * 255.0)), int(round(c.g * 255.0)), int(round(c.b * 255.0)))
			out.append({"v": v, "k": k, "luma": a})
	return out


# ---- the shader's own hash, replayed in script ------------------------------------------------------

static func _lowbias32(x_in: int) -> int:
	var x := x_in & 0xffffffff
	x ^= x >> 16
	x = (x * 0x7feb352d) & 0xffffffff
	x ^= x >> 15
	x = (x * 0x846ca68b) & 0xffffffff
	x ^= x >> 16
	return x


static func _hcell(cx: int, cy: int, key: int, salt: int) -> int:
	var h := _lowbias32(cx)
	h = _lowbias32(h ^ (cy & 0xffffffff))
	h = _lowbias32(h ^ key)
	return _lowbias32(h ^ salt)


## The shader's top_material() for world texel (wx, wz), replayed from the committed ids.
static func _oracle_top_id(ids: PackedByteArray, wx: int, wz: int) -> int:
	var ltx := posmod(wx, TEXELS)
	var ltz := posmod(wz, TEXELS)
	var cx := (wx - ltx) / TEXELS
	var cz := (wz - ltz) / TEXELS
	var ex := ltx if ltx < 8 else 15 - ltx
	var ez := ltz if ltz < 8 else 15 - ltz
	var sx := -1 if ltx < 8 else 1
	var sz := -1 if ltz < 8 else 1
	var tx := sx if (_hcell(wx, wz, 0, 211) & 0xffff) < EDGE_K[ex] else 0
	var tz := sz if (_hcell(wx, wz, 0, 212) & 0xffff) < EDGE_K[ez] else 0
	var fx := clampi(cx + tx + FIELD_ORIGIN, 0, FIELD_DIM - 1)
	var fz := clampi(cz + tz + FIELD_ORIGIN, 0, FIELD_DIM - 1)
	return ids[fz * FIELD_DIM + fx]


# ---- debug shaders (in memory only) -------------------------------------------------------------------

const S2L := "float s2l(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }\n\n"


static func _debug_shader(ground: Shader, mode: String, force_dirt: bool) -> Shader:
	var code := ground.code
	var out_albedo := "\tALBEDO = base * (1.0 - f);"
	var out_emit := "\tEMISSION = haze_color.rgb * f;"
	var render_mode := "render_mode diffuse_lambert, specular_disabled;"
	if not code.contains(out_albedo) or not code.contains(out_emit) or not code.contains(render_mode):
		return null
	# unshaded: no light, no ambient, no reflection, so the painted byte is the byte read back
	var paint := ""
	if mode == "albedo":
		paint = "\tALBEDO = base;"  # the texel the shader chose, before light and fog: the atlas bytes themselves
	elif mode == "id":
		var idv := "1" if force_dirt else "mat_id"
		paint = "\tfloat idb = (mat_id < 0 ? 0.0 : float(%s) * %d.0 + %d.0) / 255.0;\n\tALBEDO = vec3(s2l(idb), s2l(float(bucket) * 200.0 / 255.0), 0.0);" % [idv, ID_STEP, ID_BASE]
	else:
		paint = "\tALBEDO = vec3(s2l(geo_n.x * 0.5 + 0.5), s2l(geo_n.y * 0.5 + 0.5), s2l(geo_n.z * 0.5 + 0.5));"
	code = code.replace(render_mode, "render_mode unshaded;")
	code = code.replace(out_albedo, paint)
	code = code.replace(out_emit, "\tEMISSION = vec3(0.0);")
	code = code.replace("void fragment() {", S2L + "void fragment() {")
	var s := Shader.new()
	s.code = code
	return s


# ---- arms ----------------------------------------------------------------------------------------------

class Arms:
	extends RefCounted
	var w: Node
	var mats: Array = []
	var shaders: Array = []  # production shaders (after any mutation)
	var id_shaders: Array = []
	var n_shaders: Array = []
	var albedo_shaders: Array = []
	var decal_rate: float = 0.0
	var mat_rates: PackedFloat32Array = PackedFloat32Array()
	var tint: float = 0.0

	func _init(world: Node, id_arm: Array, n_arm: Array, albedo_arm: Array) -> void:
		w = world
		mats = [world.grass_mat, world.dirt_mat]
		for m in mats:
			shaders.append(m.shader)
		id_shaders = id_arm
		n_shaders = n_arm
		albedo_shaders = albedo_arm
		decal_rate = float(mats[0].get_shader_parameter("decal_rate"))
		mat_rates = mats[0].get_shader_parameter("mat_decal_rate")
		tint = float(mats[0].get_shader_parameter("tint_strength"))

	func set_arm(arm: String) -> void:
		for i in range(mats.size()):
			var m: ShaderMaterial = mats[i]
			if arm == "id":
				m.shader = id_shaders[i]
			elif arm == "n":
				m.shader = n_shaders[i]
			elif arm == "V":
				m.shader = albedo_shaders[i]
			else:
				m.shader = shaders[i]
			var no_decals: bool = arm == "V" or arm == "D"
			var no_tint: bool = arm == "V" or arm == "T"
			m.set_shader_parameter("decal_rate", 0.0 if no_decals else decal_rate)
			m.set_shader_parameter("mat_decal_rate", PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0]) if no_decals else mat_rates)
			m.set_shader_parameter("tint_strength", 0.0 if no_tint else tint)


# ---- poses ------------------------------------------------------------------------------------------------

static func _pose_top(w: Node, x: float, y: float, z: float) -> void:
	var cam: Camera3D = w.cam
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = ORTHO_SIZE
	cam.global_position = Vector3(x, y + 14.0, z)
	cam.look_at(Vector3(x, y, z), Vector3(0.0, 0.0, -1.0))


static func _pose_wall(w: Node, c: Vector3, n: Vector3) -> void:
	var cam: Camera3D = w.cam
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = ORTHO_SIZE
	cam.global_position = c + n * 8.0
	cam.look_at(c, Vector3.UP)


## Renders the arms for one window. Returns {S, V, D, T, ID, N} images.
static func _render_arms(w: Node, arms: Arms) -> Dictionary:
	var out := {}
	for arm in ["S", "V", "D", "T", "id", "n"]:
		arms.set_arm(arm)
		out[arm] = await _grab(w)
	arms.set_arm("S")
	return out


# ---- one window's squares --------------------------------------------------------------------------------

## True when the pixel at byte offset `o` carries material `mid` and, for tops, points straight up, or for
## walls, points straight at the camera (outward normal `n`).
static func _ok_sample(di: PackedByteArray, dn: PackedByteArray, o: int, mid: int, kind: String, n: Vector3) -> bool:
	if _decode_id(di[o]) != mid:
		return false
	var dot: float
	if kind == "top":
		dot = float(dn[o + 1]) / 255.0 * 2.0 - 1.0
	else:
		dot = (float(dn[o]) / 255.0 * 2.0 - 1.0) * n.x + (float(dn[o + 1]) / 255.0 * 2.0 - 1.0) * n.y + (float(dn[o + 2]) / 255.0 * 2.0 - 1.0) * n.z
	return dot >= 0.96


## The selection of a window: the squares (i, j) of which at least `min_samples` of the 256 texel samples carry
## material `mid` on a flat top (kind "top"), or on a face turned straight at the camera (kind "wall"). A top
## square must be wholly the material; on a wall the lattice's slanted hexagonal faces share every 0.5 m square
## with the straight faces (diamonds and corner pieces a quarter-metre across), so a wall square is judged on
## the texels that are the material's straight face.
## Returns [{q: Vector2i, mask: PackedByteArray of 256, count}].
static func _select(imgs: Dictionary, mid: int, kind: String, n: Vector3, min_samples: int) -> Array:
	var di: PackedByteArray = imgs["id"].get_data()
	var dn: PackedByteArray = imgs["n"].get_data()
	var width: int = imgs["id"].get_width()
	var sel: Array = []
	for j in range(TILES_Y):
		for i in range(TILES_X):
			var mask := PackedByteArray()
			mask.resize(TEXELS * TEXELS)
			var cnt := 0
			for ty in range(TEXELS):
				for tx in range(TEXELS):
					if _ok_sample(di, dn, _sample_off(width, i, j, tx, ty), mid, kind, n):
						mask[ty * TEXELS + tx] = 1
						cnt += 1
			if cnt >= min_samples:
				sel.append({"q": Vector2i(i, j), "mask": mask, "count": cnt})
	return sel


static func _masked_pearson(a: PackedFloat32Array, b: PackedFloat32Array, m1: PackedByteArray, m2: PackedByteArray) -> float:
	var n := 0
	var ma := 0.0
	var mb := 0.0
	for k in range(a.size()):
		if m1[k] != 0 and m2[k] != 0:
			n += 1
			ma += a[k]
			mb += b[k]
	if n < 16:
		return 0.0
	ma /= n
	mb /= n
	var sab := 0.0
	var saa := 0.0
	var sbb := 0.0
	for k in range(a.size()):
		if m1[k] != 0 and m2[k] != 0:
			var da := a[k] - ma
			var db := b[k] - mb
			sab += da * db
			saa += da * da
			sbb += db * db
	if saa < 1e-9 or sbb < 1e-9:
		return 0.0
	return sab / sqrt(saa * sbb)


static func _material_stats(imgs: Dictionary, sel: Array, cands: Array, kind: String, mid: int, n: Vector3) -> Dictionary:
	var dS: PackedByteArray = imgs["S"].get_data()
	var dV: PackedByteArray = imgs["V"].get_data()
	var dD: PackedByteArray = imgs["D"].get_data()
	var dT: PackedByteArray = imgs["T"].get_data()
	var di: PackedByteArray = imgs["id"].get_data()
	var dn: PackedByteArray = imgs["n"].get_data()
	var width: int = imgs["S"].get_width()
	var lumas := {}
	for e in sel:
		lumas[e["q"]] = _luma(_samples(dV, width, e["q"].x, e["q"].y))
	var vs := {}
	var ks := {}
	var vt := {}
	var matched := 0
	var bad := 0
	var cell_vk := {}
	for e in sel:
		var q: Vector2i = e["q"]
		var best_r := -2.0
		var best_c = null
		for c in cands:
			var r := _masked_pearson(lumas[q], c["luma"], e["mask"], e["mask"])
			if r > best_r:
				best_r = r
				best_c = c
		if best_r >= MATCH_MIN:
			matched += 1
			vs[best_c["v"]] = true
			ks[best_c["k"]] = true
			vt[Vector2i(best_c["v"], best_c["k"])] = true
			if not cell_vk.has(q):
				cell_vk[q] = int(best_c["v"]) * 8 + int(best_c["k"])
			if kind == "wall" and not (int(best_c["k"]) in WALL_ALLOWED_K):
				bad += 1
		elif kind == "wall":
			bad += 1  # a wall unit that matches no mirror-only candidate is a rotated or distorted one
	# neighbouring squares are "similar" when they wear the same variant under the same symmetry (the tile repeated)
	var similar := 0
	var pairs := 0
	for q in cell_vk.keys():
		for nb in [Vector2i(q.x + 1, q.y), Vector2i(q.x, q.y + 1)]:
			if cell_vk.has(nb):
				pairs += 1
				if cell_vk[nb] == cell_vk[q]:
					similar += 1
	var decal := 0
	var tint := 0
	var nonuni := 0
	var rgb := {}
	var luma_sum := 0.0
	var pixels := 0
	for e in sel:
		var q: Vector2i = e["q"]
		var m: PackedByteArray = e["mask"]
		var ls := _luma(_samples(dS, width, q.x, q.y))
		var lt := _luma(_samples(dT, width, q.x, q.y))
		var s_s := _samples(dS, width, q.x, q.y)
		var s_d := _samples(dD, width, q.x, q.y)
		for k in range(TEXELS * TEXELS):
			if m[k] != 0 and (absi(s_s[k * 3] - s_d[k * 3]) > 8 or absi(s_s[k * 3 + 1] - s_d[k * 3 + 1]) > 8 or absi(s_s[k * 3 + 2] - s_d[k * 3 + 2]) > 8):
				decal += 1
				break
		var moved := 0
		for k in range(TEXELS * TEXELS):
			if m[k] != 0 and absf(ls[k] / maxf(lt[k], 1.0) - 1.0) >= TINT_TEXEL_MIN:
				moved += 1
		if moved >= TINT_TEXELS_MIN:
			tint += 1
		# crispness and palette: only texel blocks that are wholly the material's straight face
		var x0 := PX * q.x
		var y0 := TOP + PX * q.y
		var square_uniform := true
		for by in range(TEXELS):
			for bx in range(TEXELS):
				var whole := true
				for py in range(TEXEL_PX):
					for px in range(TEXEL_PX):
						if not _ok_sample(di, dn, ((y0 + TEXEL_PX * by + py) * width + x0 + TEXEL_PX * bx + px) * 3, mid, kind, n):
							whole = false
				if not whole:
					continue
				for c in range(3):
					var lo := 255
					var hi := 0
					for py in range(TEXEL_PX):
						for px in range(TEXEL_PX):
							var v := dS[((y0 + TEXEL_PX * by + py) * width + x0 + TEXEL_PX * bx + px) * 3 + c]
							lo = mini(lo, v)
							hi = maxi(hi, v)
					if hi - lo > 2:
						square_uniform = false
				for py in range(TEXEL_PX):
					for px in range(TEXEL_PX):
						var o := ((y0 + TEXEL_PX * by + py) * width + x0 + TEXEL_PX * bx + px) * 3
						rgb[(dS[o] << 16) | (dS[o + 1] << 8) | dS[o + 2]] = true
						luma_sum += _luma_of(dS[o], dS[o + 1], dS[o + 2])
						pixels += 1
		if not square_uniform:
			nonuni += 1
	return {"squares": sel.size(), "cells": cell_vk.size(), "pairs": pairs, "similar_pairs": similar, "matched_squares": matched,
		"variants_used": vs.size(), "transforms_used": ks.size(), "vt_pairs": vt.size(), "bad_transform_squares": bad,
		"decal_squares": decal, "tint_squares": tint, "nonuniform_squares": nonuni, "distinct_rgb": rgb.size(),
		"luma_sum": luma_sum, "pixels": pixels}


static func _merge(into: Dictionary, add: Dictionary) -> void:
	for k in add.keys():
		if k == "variants_used" or k == "transforms_used" or k == "vt_pairs" or k == "distinct_rgb":
			into[k] = maxi(int(into.get(k, 0)), int(add[k]))
		else:
			into[k] = into.get(k, 0) + add[k]


# ---- the id oracle at a top window -------------------------------------------------------------------------

## Compares the rendered ids at every texel sample of a nadir window with the script replay of the
## shader's rule. Only flat tops are compared (the N arm).
static func _id_check_top(imgs: Dictionary, ids: PackedByteArray, cx: float, cz: float) -> Dictionary:
	var di: PackedByteArray = imgs["id"].get_data()
	var dn: PackedByteArray = imgs["n"].get_data()
	var width: int = imgs["id"].get_width()
	var checked := 0
	var bad := 0
	var by_id := {}
	var first: Array = []
	for j in range(TILES_Y):
		for i in range(TILES_X):
			for ty in range(TEXELS):
				for tx in range(TEXELS):
					var o := _sample_off(width, i, j, tx, ty)
					if dn[o + 1] < 250:
						continue
					var px := PX * i + TEXEL_PX * tx + 2
					var py := TOP + PX * j + TEXEL_PX * ty + 2
					var wx := int(floor((cx + (float(px) + 0.5 - 640.0) / 128.0) * 32.0))
					var wz := int(floor((cz + (float(py) + 0.5 - 360.0) / 128.0) * 32.0))
					var want := _oracle_top_id(ids, wx, wz)
					if want == M_GRASS and di[o + 1] > 100:
						want = M_DIRT  # the engine's dirt bucket draws a grass column as dirt
					var got := _decode_id(di[o])
					checked += 1
					by_id[want] = by_id.get(want, 0) + 1
					if got != want:
						bad += 1
						if first.size() < 6:
							first.append([wx, wz, want, got, dn[o], dn[o + 1], dn[o + 2]])
	return {"checked": checked, "mismatch": bad, "by_id": by_id, "first": first}


## One triangle mesh per loaded chunk, from the very meshes the engine drew, for the wall oracle's rays.
static func _triangle_meshes(streamer: Node3D) -> Array:
	var out: Array = []
	for c in streamer.chunk_coords():
		var mi: MeshInstance3D = streamer.chunk_node(c)
		var tm: TriangleMesh = mi.mesh.generate_triangle_mesh()
		out.append({"tm": tm, "faces": tm.get_faces(), "off": mi.global_position})
	return out


## The first front-facing surface along a ray, over all chunks: {position, normal} in world space, or {}.
## The mesh query returns a normal turned toward the ray, so the true facing comes from the triangle's own
## winding (clockwise is the front, as the renderer draws it). A ray that starts inside solid ground passes
## through the faces it sees from behind (they are not drawn).
static func _ray_front(tms: Array, origin: Vector3, dir: Vector3) -> Dictionary:
	var o := origin
	for attempt in range(12):
		var best := {}
		var best_d := INF
		for e in tms:
			var r: Dictionary = e["tm"].intersect_ray(o - e["off"], dir)
			if r.is_empty():
				continue
			var pos: Vector3 = r["position"] + e["off"]
			var d := (pos - o).length()
			if d < best_d:
				var fi := int(r["face_index"])
				var fv: PackedVector3Array = e["faces"]
				best_d = d
				best = {"position": pos, "normal": Plane(fv[fi * 3], fv[fi * 3 + 1], fv[fi * 3 + 2]).normal}
		if best.is_empty():
			return {}
		if (best["normal"] as Vector3).dot(dir) > 0.0:
			o = best["position"] + dir * 0.002  # a back face: keep going
			continue
		return best
	return {}


## The wall rule replayed in script for the texel samples of the selected squares. Each sample's ray is cast
## into the chunk meshes the engine drew; at the hit, the rule is evaluated exactly as the shader evaluates it
## (the column behind the face from the committed wall field, the face's turn from the sun) and compared
## with the id the id arm painted. Every other texel is sampled, to bound the cost.
## Returns {checked, mismatch, first}.
static func _oracle_wall(imgs: Dictionary, sel: Array, n: Vector3, c: Vector3, wall: Image, rules: Dictionary, sun: Vector2, tms: Array) -> Dictionary:
	var di: PackedByteArray = imgs["id"].get_data()
	var width: int = imgs["id"].get_width()
	var right := Vector3.UP.cross(n)
	var drop_min := int(round(float(rules["wall"]["rock_drop_m"]) * 8.0))
	var water_q := int(round(float(rules["wall"]["moss_water_m"]) * 10.0))
	var checked := 0
	var bad := 0
	var ambiguous := 0
	var first: Array = []
	for e in sel:
		var q: Vector2i = e["q"]
		var m: PackedByteArray = e["mask"]
		for ty in range(0, TEXELS, 2):
			for tx in range(0, TEXELS, 2):
				if m[ty * TEXELS + tx] == 0:
					continue
				var px := PX * q.x + TEXEL_PX * tx + 2
				var py := TOP + PX * q.y + TEXEL_PX * ty + 2
				var s := (float(px) + 0.5 - 640.0) / 128.0
				var y := c.y - (float(py) + 0.5 - 360.0) / 128.0
				var origin := Vector3(c.x, y, c.z) + right * s + n * 8.0
				var hit := _ray_front(tms, origin, -n)
				if hit.is_empty():
					continue
				# a ray can slip through a seam between two triangles: a second ray a hair away must find the same face
				var hit2 := _ray_front(tms, origin + right * 0.003 + Vector3.UP * 0.003, -n)
				if hit2.is_empty() or (hit2["position"] - hit["position"]).dot(-n) > 0.001 or (hit2["position"] - hit["position"]).dot(-n) < -0.001:
					continue
				var fn: Vector3 = (hit["normal"] as Vector3).normalized()
				if fn.dot(n) < 0.96:
					continue  # the ray and the raster disagree about which face this edge pixel is on
				var p: Vector3 = hit["position"]
				var facing := Vector2(n.x, n.z)  # the face's dominant horizontal axis
				var col0 := Vector2i(int(floor((p.x - facing.x * 0.3) / COL_M)), int(floor((p.z - facing.y * 0.3) / COL_M)))
				# The lattice's second coset staggers faces by half a column, so a sample is only judged where the
				# rule gives ONE answer for the column behind the face and all eight columns around it.
				var want := -2
				var unanimous := true
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						var wp := wall.get_pixel(clampi(col0.x + dx + FIELD_ORIGIN, 0, FIELD_DIM - 1), clampi(col0.y + dz + FIELD_ORIGIN, 0, FIELD_DIM - 1))
						var pred := M_DIRT
						if int(round(wp.g * 255.0)) >= drop_min:
							pred = M_ROCK
							if int(round(wp.r * 255.0)) < water_q or -facing.dot(sun.normalized()) > float(rules["wall"]["moss_shade"]):
								pred = M_MOSS
						if want == -2:
							want = pred
						elif want != pred:
							unanimous = false
				if not unanimous:
					ambiguous += 1
					continue
				var col := col0
				checked += 1
				var got := _decode_id(di[py * width * 3 + px * 3])
				if want != got:
					bad += 1
					if first.size() < 6:
						first.append([px, py, want, got, col.x, col.y, snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001), snappedf(fn.x, 0.01), snappedf(fn.y, 0.01), snappedf(fn.z, 0.01)])
	return {"checked": checked, "mismatch": bad, "ambiguous": ambiguous, "first": first}


# ---- assets ----------------------------------------------------------------------------------------------------

static func assets() -> Dictionary:
	var a := Image.load_from_file(ATLAS_PATH)
	var d := Image.load_from_file(DECALS_PATH)
	var gv := Image.load_from_file(GRASS_VARIANTS_PATH)
	var ds := Image.load_from_file(DIRT_SHIPPED_PATH)
	a.convert(Image.FORMAT_RGBA8)
	d.convert(Image.FORMAT_RGBA8)
	gv.convert(Image.FORMAT_RGBA8)
	ds.convert(Image.FORMAT_RGBA8)
	var binary := true
	var dd := d.get_data()
	for k in range(3, dd.size(), 4):
		if dd[k] != 0 and dd[k] != 255:
			binary = false
	return {
		"atlas_w": a.get_width(), "atlas_h": a.get_height(), "atlas_rows": a.get_height() / TEXELS,
		"atlas_row0_equals_variants": a.get_region(Rect2i(0, 0, a.get_width(), TEXELS)).get_data() == gv.get_data(),
		"atlas_dirt_v0_equals_shipped": a.get_region(Rect2i(0, TEXELS, TEXELS, TEXELS)).get_data() == ds.get_data(),
		"ground_decal_alpha_binary": binary, "ground_decals_w": d.get_width(), "ground_decals_h": d.get_height(),
	}


static func _hash_image(img: Image) -> String:
	var c := img.duplicate()
	c.convert(Image.FORMAT_RGBA8)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(c.get_data())
	return ctx.finish().hex_encode()


static func _ids_of(path: String) -> PackedByteArray:
	var img := Image.load_from_file(path)
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var ids := PackedByteArray()
	ids.resize(FIELD_DIM * FIELD_DIM)
	for k in range(FIELD_DIM * FIELD_DIM):
		ids[k] = data[k * 4]
	return ids


# ---- mutations ----------------------------------------------------------------------------------------------------

static func apply_mutation(w: Node, mutation: String) -> void:
	var mats := [w.grass_mat, w.dirt_mat]
	if mutation == "wall_rotate":
		for m in mats:
			m.set_shader_parameter("wall_rotate", true)
	elif mutation == "fields_swapped":
		var wall = mats[0].get_shader_parameter("fields_wall")
		for m in mats:
			m.set_shader_parameter("fields_top", wall)
	elif mutation == "no_fields":
		var blank := Image.create(FIELD_DIM, FIELD_DIM, false, Image.FORMAT_RGBA8)
		blank.fill(Color(0, 0, 0, 1))
		var tex := ImageTexture.create_from_image(blank)
		for m in mats:
			m.set_shader_parameter("fields_top", tex)
			m.set_shader_parameter("fields_wall", tex)
	elif mutation == "mud_black":
		for m in mats:
			m.set_shader_parameter("mud_lift", 0.0)
	elif mutation == "old_dirt_wall":
		w.dirt_mat.shader = load(TERRAIN_SHADER)


# ---- the flora and understory exclusion ----------------------------------------------------------------------------------

static func _count_blocked(builds: Dictionary, chunk: Vector2i, ids: PackedByteArray, blocked: Dictionary, chunk_m: float) -> Dictionary:
	var n := 0
	var bad := 0
	var per := {}
	for key in builds.keys():
		var e: Dictionary = builds[key]
		var buf: PackedFloat32Array = e["buffer"]
		var count := int(e["count"])
		per[key] = count
		for k in range(count):
			var x := float(chunk.x) * chunk_m + buf[k * 12 + 3]
			var z := float(chunk.y) * chunk_m + buf[k * 12 + 11]
			var gx := int(floor(x / COL_M)) + FIELD_ORIGIN
			var gz := int(floor(z / COL_M)) + FIELD_ORIGIN
			n += 1
			if gx >= 0 and gz >= 0 and gx < FIELD_DIM and gz < FIELD_DIM and blocked.has(int(ids[gz * FIELD_DIM + gx])):
				bad += 1
	return {"n": n, "blocked": bad, "per": per}


static func _flora(w: Node, mutation: String, ids: PackedByteArray, rules: Dictionary) -> Dictionary:
	var streamer: Node3D = w.get_node("Streamer")
	var ground_look: GDScript = load("res://game/world/ground_look.gd")
	var blocked := {}
	for nm in rules["flora_blocked"]:
		blocked[int(rules["ids"][nm])] = true
	var chunk_m: float = StalagWorld.get_chunk_m()
	var coords: Array = streamer.chunk_coords()
	var rendered_meadow: int = streamer.flora_instances
	var rendered_understory: int = streamer.understory_instances
	var info_before: Dictionary = StalagFlora.ground_mask_info()
	# global placement: the mask must not touch it
	var g_with := _global_hash()
	if mutation == "mask_off":
		StalagFlora.set_ground_mask(PackedByteArray(), 0, 0)
	var meadow := 0
	var understory := 0
	var blocked_on := 0
	var chunk_list: Array = []
	var meadow_forms := {}
	var flower_forms := {}
	var shrub_forms := {}
	for c in coords:
		chunk_list.append([c.x, c.y])
		var fl: Dictionary = StalagFlora.build_chunk_flora(c.x, c.y)
		var un: Dictionary = StalagUnderstory.build_chunk_understory(c.x, c.y)
		var a := _count_blocked(fl, c, ids, blocked, chunk_m)
		var b := _count_blocked(un, c, ids, blocked, chunk_m)
		meadow += int(a["n"])
		understory += int(b["n"])
		blocked_on += int(a["blocked"]) + int(b["blocked"])
		for k in a["per"].keys():
			meadow_forms[k] = int(meadow_forms.get(k, 0)) + int(a["per"][k])
		for k in b["per"].keys():
			# a flower key is its id plus a tier suffix after a slash; a shrub key is its id
			var form_id := String(k).get_slice("/", 0)
			var target: Dictionary = flower_forms if String(k).contains("/") else shrub_forms
			target[form_id] = int(target.get(form_id, 0)) + int(b["per"][k])
	# the same ring with the mask cleared: what the filter removed
	StalagFlora.set_ground_mask(PackedByteArray(), 0, 0)
	var g_without := _global_hash()
	var meadow_all := 0
	var understory_all := 0
	for c in coords:
		meadow_all += int(_count_blocked(StalagFlora.build_chunk_flora(c.x, c.y), c, ids, blocked, chunk_m)["n"])
		understory_all += int(_count_blocked(StalagUnderstory.build_chunk_understory(c.x, c.y), c, ids, blocked, chunk_m)["n"])
	if mutation != "mask_off":
		ground_look.install_flora_mask()
	else:
		StalagFlora.set_ground_mask(PackedByteArray(), 0, 0)
	var names: Array = []
	for nm in rules["flora_blocked"]:
		names.append(nm)
	return {
		"ring_chunks": chunk_list, "blocked_materials": names, "mask_installed": info_before["installed"],
		"mask_blocked_columns": info_before["blocked"],
		"ring_unfiltered": meadow_all + understory_all, "ring_filtered": meadow + understory,
		"meadow_unfiltered": meadow_all, "meadow_filtered": meadow, "understory_unfiltered": understory_all, "understory_filtered": understory,
		"removed_meadow": meadow_all - meadow, "removed_understory": understory_all - understory,
		"per_form": {"meadow": meadow_forms, "flowers": flower_forms, "shrubs": shrub_forms},
		"blocked_on_material": blocked_on,
		"rendered_meadow": rendered_meadow, "rendered_understory": rendered_understory,
		"rendered_equals_build": rendered_meadow == meadow and rendered_understory == understory,
		"global_placement_bit_equal": g_with == g_without, "global_hash": g_with,
	}


static func _global_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var g: Dictionary = StalagFlora.place_global()
	for k in g.keys():
		if k == "_lids":
			continue
		ctx.update(PackedByteArray(String(k).to_utf8_buffer()))
		ctx.update((g[k] as PackedFloat64Array).to_byte_array())
	return ctx.finish().hex_encode()


static func _save_window(imgs: Dictionary, shots_dir: String, name: String) -> void:
	if shots_dir.is_empty():
		return
	(imgs["S"] as Image).save_png(shots_dir.path_join("ground_%s.png" % name))


# ---- the whole measurement -----------------------------------------------------------------------------------------------------

## Returns the record's .ground section. The camera is left posed; the caller restores nothing (it ends
## the run). `mutation` is the negative control, "none" in production runs.
static func run(w: Node, mutation: String, shots_dir: String) -> Dictionary:
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(RULES_PATH))
	var sha_doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIELDS_SHA_PATH))
	var ids := _ids_of(FIELDS_TOP_PATH)
	var ground: Dictionary = {}
	ground["perf_phase"] = 2 if (w.grass_mat.get_shader_parameter("atlas") != null and w.grass_mat.get_shader_parameter("fields_top") != null) else 0
	# the fields as the game loaded them, before any mutation
	var top_tex: Texture2D = w.grass_mat.get_shader_parameter("fields_top")
	var wall_tex: Texture2D = w.grass_mat.get_shader_parameter("fields_wall")
	ground["fields_sha"] = _hash_image(top_tex.get_image())
	ground["fields_sha_committed"] = String(sha_doc["top"])
	ground["fields_wall_sha"] = _hash_image(wall_tex.get_image())
	ground["fields_wall_sha_committed"] = String(sha_doc["wall"])
	# flora first: the world is in its entry state, nothing has been hidden or moved
	ground["flora"] = _flora(w, mutation, ids, rules)

	apply_mutation(w, mutation)
	var ground_shader: Shader = load(GROUND_SHADER)
	var id_arm: Array = []
	var n_arm: Array = []
	var albedo_arm: Array = []
	for m in [w.grass_mat, w.dirt_mat]:
		# a material that does not wear the ground shader (a control) can only ever draw the one dirt tile
		var forced: bool = String(m.shader.resource_path) != GROUND_SHADER
		id_arm.append(_debug_shader(ground_shader, "id", forced))
		n_arm.append(_debug_shader(ground_shader, "n", forced))
		# the V arm of a control that wears the old shader is the old shader itself (its tile is what is matched)
		albedo_arm.append(m.shader if forced else _debug_shader(ground_shader, "albedo", false))
	var arms := Arms.new(w, id_arm, n_arm, albedo_arm)
	var crt: Node = w.get_tree().root.find_child("CRTLayer", true, false)
	if crt != null:
		crt.visible = false
	w.walker.visible = false
	w.flora_clock_frozen = true
	var streamer: Node3D = w.get_node("Streamer")
	for c in streamer.chunk_coords():
		for nm in ["Flora", "Trees", "Understory"]:
			var n: Node = streamer.chunk_node(c).get_node_or_null(nm)
			if n != null:
				n.visible = false
	w.cam.target = null
	w.cam.look_active = false
	# the sun's shadow edges are not texel-aligned: with them off the light is flat across a texel block, so a
	# uniform block means a crisp texture and nothing else
	var shadows_were: bool = w.sun.shadow_enabled
	w.sun.shadow_enabled = false
	# fog is a smooth function of depth: with it on, faces at different depths would carry different colours
	# and the palette of one texture could not be counted; it is off for the windows and restored after
	var fog_param = w.grass_mat.get_shader_parameter("use_fog")  # unset means the shader's default, on
	var fog_were: bool = true if fog_param == null else bool(fog_param)
	for m in [w.grass_mat, w.dirt_mat]:
		m.set_shader_parameter("use_fog", false)
	var water_hidden: Array = []
	for wn in streamer.water_nodes():
		wn.visible = false
		water_hidden.append(wn)
	var atlas := Image.load_from_file(ATLAS_PATH)
	atlas.convert(Image.FORMAT_RGBA8)

	var wall_img := Image.load_from_file(FIELDS_WALL_PATH)
	wall_img.convert(Image.FORMAT_RGBA8)
	var tms := _triangle_meshes(streamer)
	var mats_out := {}
	for nm in MAT_ORDER:
		mats_out[nm] = {"kind": "wall" if nm in ["rock", "moss", "dirt_wall"] else "top", "squares": 0, "windows": []}
	var id_checked := 0
	var id_bad := 0
	var first_bad_tops: Array = []
	var first_bad_walls: Array = []
	var wall_ambiguous := 0
	var wall_expect_bad := 0
	var mud_px := 0
	var mud_luma := 0.0
	var grass_px := 0
	var grass_luma := 0.0

	for nm in ["gravel", "sand", "mud"]:
		var cands := _candidates(atlas, int(MAT_IDS[nm]))
		for win in TOP_WINDOWS[nm]:
			_pose_top(w, float(win[0]), float(win[1]), float(win[2]))
			var imgs := await _render_arms(w, arms)
			_save_window(imgs, shots_dir, "%s_top_%d" % [nm, mats_out[nm]["windows"].size()])
			var sel := _select(imgs, int(MAT_IDS[nm]), "top", Vector3.UP, MASK_MIN_TOP)
			var st := _material_stats(imgs, sel, cands, "top", int(MAT_IDS[nm]), Vector3.UP)
			_merge(mats_out[nm], st)
			mats_out[nm]["windows"].append({"x": win[0], "y": win[1], "z": win[2], "squares": sel.size()})
			var chk := _id_check_top(imgs, ids, float(win[0]), float(win[2]))
			id_checked += int(chk["checked"])
			id_bad += int(chk["mismatch"])
			if chk["first"].size() > 0 and first_bad_tops.size() < 12:
				first_bad_tops.append({"window": win, "bad": chk["first"]})
			if nm == "mud":
				# luma of mud against the grass beside it, in the frame the player would see
				mud_px += int(st["pixels"])
				mud_luma += float(st["luma_sum"])
				var gsel := _select(imgs, M_GRASS, "top", Vector3.UP, MASK_MIN_TOP)
				var gst := _material_stats(imgs, gsel, _candidates(atlas, 0), "top", M_GRASS, Vector3.UP)
				grass_px += int(gst["pixels"])
				grass_luma += float(gst["luma_sum"])
	for nm in ["rock", "moss", "dirt_wall"]:
		var cands := _candidates(atlas, int(MAT_IDS[nm]))
		for win in WALL_WINDOWS[nm]:
			var n := Vector3(win["n"][0], 0.0, win["n"][1])
			var c := Vector3(win["c"][0], win["c"][1], win["c"][2])
			_pose_wall(w, c, n)
			var imgs := await _render_arms(w, arms)
			_save_window(imgs, shots_dir, "%s_wall_%d" % [nm, mats_out[nm]["windows"].size()])
			var sel := _select(imgs, int(MAT_IDS[nm]), "wall", n, MASK_MIN_WALL)
			var st := _material_stats(imgs, sel, cands, "wall", int(MAT_IDS[nm]), n)
			_merge(mats_out[nm], st)
			mats_out[nm]["windows"].append({"c": win["c"], "n": win["n"], "squares": sel.size()})
			var wo := _oracle_wall(imgs, sel, n, c, wall_img, rules, w.grass_mat.get_shader_parameter("sun_xz"), tms)
			id_checked += int(wo["checked"])
			wall_expect_bad += int(wo["mismatch"])
			wall_ambiguous += int(wo["ambiguous"])
			if wo["first"].size() > 0 and first_bad_walls.size() < 12:
				first_bad_walls.append({"material": nm, "c": win["c"], "n": win["n"], "bad": wo["first"]})
	for nm in MAT_ORDER:
		for k in ["luma_sum", "pixels"]:
			mats_out[nm].erase(k)
	ground["materials"] = mats_out
	ground["id_checked"] = id_checked
	ground["id_mismatch_total"] = id_bad + wall_expect_bad
	ground["id_mismatch_tops"] = id_bad
	ground["id_mismatch_walls"] = wall_expect_bad
	ground["id_wall_ambiguous_skipped"] = wall_ambiguous
	ground["first_mismatches"] = {"tops": first_bad_tops, "walls": first_bad_walls}
	ground["mud"] = {"pixels": mud_px, "luma": (mud_luma / maxf(1.0, float(mud_px))) / 255.0,
		"grass_luma": (grass_luma / maxf(1.0, float(grass_px))) / 255.0,
		"ratio": (mud_luma / maxf(1.0, float(mud_px))) / maxf(1e-6, grass_luma / maxf(1.0, float(grass_px))),
		"lift": w.grass_mat.get_shader_parameter("mud_lift")}
	for wn in water_hidden:
		wn.visible = true
	w.sun.shadow_enabled = shadows_were
	for m in [w.grass_mat, w.dirt_mat]:
		m.set_shader_parameter("use_fog", fog_were)
	arms.set_arm("S")
	return ground

