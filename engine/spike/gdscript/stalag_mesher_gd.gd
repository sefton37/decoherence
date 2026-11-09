class_name StalagMesherGd
extends RefCounted
## Spec #494 spike -- GDScript candidate.
##
## A from-scratch port of the stalag `base` terrain mesh: truncated-octahedron (TO)
## boundary-face extraction over BCC lattice cells, flat-shaded, world metres. The
## algorithm and the integer/float operation order mirror the C++ candidate
## (ext/src/stalag_mesher.cpp) so the two are comparable like for like.
##
## Sources ported (frozen reference, read at implementation time, NOT at run time):
## to-cell.js (VERTICES, faces, NEIGHBOR_OFFSETS), cells.js (faceNormal), worldgen.js
## (hash2 / valueNoise / terrainHeight), worldmesh.js (surfaceHeightBase and the cap
## decision passes that decide which base faces are suppressed).
##
## NOT ported: the `caps` mesh output, skin, water, carve. surfaceHeight is taken as
## surfaceHeightBase, valid only on carve-free regions.
##
## JS 32-bit semantics (`|0`, `Math.imul`, `>>> 16`) are emulated by masking GDScript's
## 64-bit ints to 32 bits.

# Lattice units -> world metres (cell diameter 0.5 m / 4 lattice). ONE definition here.
const SF := 0.125
const TERRACE_LAT := 4
const SLAB_DEPTH := 4
const RMARGIN := 4
const JMARGIN := 8
const SIDE_WALL_MIN := 12
const SIDE_PLACE_MIN := 0.4
const SIDE_ROUGH := 0.12
const MASK32 := 0xFFFFFFFF
const UNSET := -2147483648

# ------------------------------------------------------------------ TO cell tables
const VERTICES: Array[Vector3i] = [
	Vector3i(-2, -1, 0), Vector3i(-2, 0, -1), Vector3i(-2, 0, 1), Vector3i(-2, 1, 0),
	Vector3i(-1, -2, 0), Vector3i(-1, 0, -2), Vector3i(-1, 0, 2), Vector3i(-1, 2, 0),
	Vector3i(0, -2, -1), Vector3i(0, -2, 1), Vector3i(0, -1, -2), Vector3i(0, -1, 2),
	Vector3i(0, 1, -2), Vector3i(0, 1, 2), Vector3i(0, 2, -1), Vector3i(0, 2, 1),
	Vector3i(1, -2, 0), Vector3i(1, 0, -2), Vector3i(1, 0, 2), Vector3i(1, 2, 0),
	Vector3i(2, -1, 0), Vector3i(2, 0, -1), Vector3i(2, 0, 1), Vector3i(2, 1, 0),
]

# 14 faces: 6 squares (4 verts) then 8 hexagons (6 verts); index == NEIGHBOR_OFFSETS index.
const FACES: Array = [
	[22, 20, 21, 23], [1, 0, 2, 3], [14, 7, 15, 19],
	[9, 4, 8, 16], [13, 6, 11, 18], [10, 5, 12, 17],
	[19, 15, 13, 18, 22, 23], [21, 17, 12, 14, 19, 23], [18, 11, 9, 16, 20, 22],
	[20, 16, 8, 10, 17, 21], [7, 3, 2, 6, 13, 15], [12, 5, 1, 3, 7, 14],
	[6, 2, 0, 4, 9, 11], [8, 4, 0, 1, 5, 10],
]

const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(4, 0, 0), Vector3i(-4, 0, 0), Vector3i(0, 4, 0), Vector3i(0, -4, 0),
	Vector3i(0, 0, 4), Vector3i(0, 0, -4),
	Vector3i(2, 2, 2), Vector3i(2, 2, -2), Vector3i(2, -2, 2), Vector3i(2, -2, -2),
	Vector3i(-2, 2, 2), Vector3i(-2, 2, -2), Vector3i(-2, -2, 2), Vector3i(-2, -2, -2),
]

# Side-cap wall facings: [mating (offset, face) x4, backing (offset, face), open, run x2, z_wall].
const SIDE_DIRS: Array[Dictionary] = [
	{ "mating": [Vector3i(2, 2, 2), Vector3i(2, 2, -2), Vector3i(2, -2, 2), Vector3i(2, -2, -2)],
		"mating_face": [13, 12, 11, 10], "backing": Vector3i(4, 0, 0), "backing_face": 1,
		"open": Vector3i(-4, 0, 0), "run": [Vector3i(0, 0, 4), Vector3i(0, 0, -4)], "z_wall": false },
	{ "mating": [Vector3i(2, 2, -2), Vector3i(-2, 2, -2), Vector3i(2, -2, -2), Vector3i(-2, -2, -2)],
		"mating_face": [12, 8, 10, 6], "backing": Vector3i(0, 0, -4), "backing_face": 4,
		"open": Vector3i(0, 0, 4), "run": [Vector3i(4, 0, 0), Vector3i(-4, 0, 0)], "z_wall": true },
	{ "mating": [Vector3i(-2, 2, -2), Vector3i(-2, 2, 2), Vector3i(-2, -2, -2), Vector3i(-2, -2, 2)],
		"mating_face": [8, 9, 6, 7], "backing": Vector3i(-4, 0, 0), "backing_face": 0,
		"open": Vector3i(4, 0, 0), "run": [Vector3i(0, 0, 4), Vector3i(0, 0, -4)], "z_wall": false },
	{ "mating": [Vector3i(-2, 2, 2), Vector3i(2, 2, 2), Vector3i(-2, -2, 2), Vector3i(2, -2, 2)],
		"mating_face": [9, 13, 7, 11], "backing": Vector3i(0, 0, 4), "backing_face": 5,
		"open": Vector3i(0, 0, -4), "run": [Vector3i(4, 0, 0), Vector3i(-4, 0, 0)], "z_wall": true },
]

# 13-column box of the cy-bound scan (see _cy_bounds).
const BOX: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(4, 0), Vector2i(-4, 0), Vector2i(0, 4), Vector2i(0, -4),
	Vector2i(4, 4), Vector2i(4, -4), Vector2i(-4, 4), Vector2i(-4, -4),
	Vector2i(2, 2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(-2, -2),
]

# Per-face emission tables, built once: triangles as vertex-index triples.
static var _tris: Array[PackedInt32Array] = []
static var _tris_alt: Array[PackedInt32Array] = []
static var _normals: Array[Vector3] = []
static var _voff: Array[Vector3] = []

# ------------------------------------------------------------------ per-build state
var _seed := 0
var _floor_half := 0.0
var _x_min := 0.0
var _x_max := 0.0
var _z_min := 0.0
var _z_max := 0.0
var _i0 := 0
var _k0 := 0
var _i_n := 0
var _k_n := 0
var _ht_cache := PackedInt32Array()
var _top_cells := {}       # col_key -> Vector2i(hT, cy)
var _bottom_caps := {}     # cell_key -> true
var _suppress := {}        # face_key -> true
var _force_x_split := {}   # face_key -> true


static func _ensure_tables() -> void:
	if not _tris.is_empty():
		return
	for v in VERTICES:
		_voff.append(Vector3(v.x * SF, v.y * SF, v.z * SF))
	for fi in 14:
		var f := PackedInt32Array(FACES[fi])
		var sx := 0.0
		var sy := 0.0
		var sz := 0.0
		for vi in f:
			var vv: Vector3i = VERTICES[vi]
			sx += float(vv.x)
			sy += float(vv.y)
			sz += float(vv.z)
		var cnt := float(f.size())
		sx /= cnt
		sy /= cnt
		sz /= cnt
		var length := sqrt(sx * sx + sy * sy + sz * sz)
		var c := Vector3(sx / length, sy / length, sz / length)
		_normals.append(c)
		var t := PackedInt32Array()
		var alt := PackedInt32Array()
		if f.size() == 4:
			# Default split along the horizontal (constant-Y) diagonal v0-v2 when it exists.
			var use_v02: bool = VERTICES[f[0]].y == VERTICES[f[2]].y
			var a02 := PackedInt32Array([f[0], f[1], f[2], f[0], f[2], f[3]])
			var a13 := PackedInt32Array([f[1], f[2], f[3], f[1], f[3], f[0]])
			t = a02 if use_v02 else a13
			alt = a13 if use_v02 else a02
		else:
			for k in range(1, 5):
				t.append(f[0])
				t.append(f[k])
				t.append(f[k + 1])
		_tris.append(t)
		_tris_alt.append(alt)


# ------------------------------------------------------------------ hashing and noise
static func _to_i32(v: int) -> int:
	var u := v & MASK32
	return u - 0x100000000 if u >= 0x80000000 else u


# SPDX-License-Identifier: LicenseRef-PublicDomain
# lowbias32: Chris Wellons, "Prospecting for Hash Functions", https://nullprogram.com/blog/2018/07/31/ (public domain)
static func _lowbias32(x: int) -> int:
	x = (x ^ (x >> 16)) & MASK32
	x = (x * 0x7feb352d) & MASK32
	x = (x ^ (x >> 15)) & MASK32
	x = (x * 0x846ca68b) & MASK32
	return (x ^ (x >> 16)) & MASK32


# worldgen.js hash2: the JS products are exact doubles reduced mod 2^32 by `|0`.
static func _hash2(ix: int, iz: int, seed: int) -> float:
	var h := (seed & MASK32) ^ ((ix * 2654435761) & MASK32) ^ ((iz * 1234567891) & MASK32)
	return float(_lowbias32(h)) / 4294967296.0


static func _value_noise(x: float, z: float, seed: int) -> float:
	var fxl := floorf(x)
	var fzl := floorf(z)
	var ix := int(fxl)
	var iz := int(fzl)
	var fx := x - fxl
	var fz := z - fzl
	var v00 := _hash2(ix, iz, seed)
	var v10 := _hash2(ix + 1, iz, seed)
	var v01 := _hash2(ix, iz + 1, seed)
	var v11 := _hash2(ix + 1, iz + 1, seed)
	var ux := fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
	var uz := fz * fz * fz * (fz * (fz * 6.0 - 15.0) + 10.0)
	var a := v00 + ux * (v10 - v00)
	var b := v01 + ux * (v11 - v01)
	return a + uz * (b - a)


static func _terrain_height(x: float, z: float, seed: int) -> float:
	var s1 := _to_i32(seed * 1234567 + 7)
	var s2 := _to_i32(seed * 9876541 + 13)
	var s3 := _to_i32(seed * 3141592 + 3)
	var n0 := _value_noise(x / 32.0, z / 32.0, seed) * 14.0
	var n1 := _value_noise(x / 16.0, z / 16.0, s1) * 6.0
	var n2 := _value_noise(x / 8.0, z / 8.0, s2) * 3.0
	var n3 := _value_noise(x / 4.0, z / 4.0, s3) * 1.5
	return n0 + n1 + n2 + n3 - 2.0


# worldmesh.js cellHash (integer avalanche).
static func _cell_hash(cx: int, cy: int, cz: int, seed: int) -> float:
	var h := (seed & MASK32) ^ (((cx & MASK32) * 0x27d4eb2d) & MASK32) ^ (((cy & MASK32) * 0x165667b1) & MASK32) ^ (((cz & MASK32) * 0x9e3779b1) & MASK32)
	h = ((h ^ (h >> 15)) * 0x85ebca6b) & MASK32
	h = ((h ^ (h >> 13)) * 0xc2b2ae35) & MASK32
	return float((h ^ (h >> 16)) & MASK32) / 4294967296.0


static func _xor_seed(seed: int, k: int) -> int:
	return _to_i32((seed & MASK32) ^ k)


static func _mesa_lift(cx: int, cz: int, seed: int) -> float:
	var wx := cx * SF
	var wz := cz * SF
	if absf(wx - 6.0) <= 2.5 and absf(wz - 0.0) <= 2.5:
		return 16.0
	var g := 16.0
	var gi := int(floorf(wx / g + 0.5))
	var gj := int(floorf(wz / g + 0.5))
	if _cell_hash(gi, 7, gj, seed) >= 0.45:
		return 0.0
	var half_x := 2.5 + _cell_hash(gi, 8, gj, seed) * 2.5
	var half_z := 2.5 + _cell_hash(gi, 9, gj, seed) * 2.5
	if absf(wx - gi * g) > half_x or absf(wz - gj * g) > half_z:
		return 0.0
	var gx := gi * g / SF
	var gz := gj * g / SF
	var h0 := floorf(_terrain_height(gx, gz, seed) / TERRACE_LAT)
	for o in [Vector2(44, 0), Vector2(-44, 0), Vector2(0, 44), Vector2(0, -44),
			Vector2(32, 32), Vector2(-32, -32), Vector2(32, -32), Vector2(-32, 32)]:
		if floorf(_terrain_height(gx + o.x, gz + o.y, seed) / TERRACE_LAT) != h0:
			return 0.0
	return 12.0 + floorf(_cell_hash(gi, 10, gj, seed) * 4.0) * 4.0


static func _cliff_lift(cx: int, cz: int, seed: int) -> float:
	var wx := cx * SF
	var wz := cz * SF
	var a := _value_noise(wx * 0.045 + 17.0, wz * 0.045 + 4.0, _xor_seed(seed, 0x1f83d9ab))
	if a <= 0.80:
		return 0.0
	var lift := 16.0
	var b := _value_noise(wx * 0.09 + 31.0, wz * 0.09 + 19.0, _xor_seed(seed, 0x5be0cd19))
	if b > 0.7:
		lift += 12.0
	return lift


static func _ridged_relief(cx: int, cz: int, seed: int) -> float:
	var wx := cx * SF
	var wz := cz * SF
	var r := sqrt(wx * wx + wz * wz)
	if r <= 70.0:
		return 0.0
	var t := (r - 70.0) / (110.0 - 70.0)
	var gm := 1.0 if r >= 110.0 else t * t * (3.0 - 2.0 * t)
	var r1 := 12.0 * (1.0 - absf(2.0 * _value_noise(wx / 56.0, wz / 56.0, _xor_seed(seed, 0x9E37)) - 1.0))
	var r2 := 6.0 * (1.0 - absf(2.0 * _value_noise(wx / 28.0, wz / 28.0, _xor_seed(seed, 0x85EB)) - 1.0))
	return gm * (r1 + r2)


# worldmesh.js surfaceHeightBase (pre-carve; valid on carve-free regions only).
static func _surface_height_base(cx: int, cz: int, seed: int) -> float:
	return _terrain_height(cx, cz, seed) + _ridged_relief(cx, cz, seed) + _mesa_lift(cx, cz, seed) + _cliff_lift(cx, cz, seed)


# ------------------------------------------------------------------ occupancy
static func _col_key(cx: int, cz: int) -> int:
	return ((cx + 4096) << 16) | (cz + 4096)


static func _cell_key(cx: int, cy: int, cz: int) -> int:
	return ((cx + 4096) << 32) | ((cy + 4096) << 16) | (cz + 4096)


static func _face_key(cx: int, cy: int, cz: int, fi: int) -> int:
	return (_cell_key(cx, cy, cz) << 4) | fi


func _compute_ht(cx: int, cz: int) -> int:
	var h := _surface_height_base(cx, cz, _seed)
	return int(floorf(h / TERRACE_LAT) * TERRACE_LAT)


# Quantised terrace height of a column (lattice), no footprint gate.
func _col_ht(cx: int, cz: int) -> int:
	var d := cx - cz
	var k := cz >> 1
	var i := d >> 2
	if (d & 3) == 0 and i >= _i0 and i < _i0 + _i_n and k >= _k0 and k < _k0 + _k_n:
		var idx := (i - _i0) * _k_n + (k - _k0)
		var v := _ht_cache[idx]
		if v == UNSET:
			v = _compute_ht(cx, cz)
			_ht_cache[idx] = v
		return v
	return _compute_ht(cx, cz)


func _in_foot(cx: int, cz: int) -> bool:
	return not (absf(cx * SF) > _floor_half + 1e-9 or absf(cz * SF) > _floor_half + 1e-9)


func _sp(cx: int, cy: int, cz: int) -> bool:
	if not _in_foot(cx, cz):
		return false
	var h := _col_ht(cx, cz)
	return cy <= h and cy >= h - SLAB_DEPTH * TERRACE_LAT


func _solid_or_cap(cx: int, cy: int, cz: int) -> bool:
	return _sp(cx, cy, cz) or _bottom_caps.has(_cell_key(cx, cy, cz))


func _in_region(cx: int, cz: int) -> bool:
	return (cx * SF) >= _x_min and (cx * SF) < _x_max and (cz * SF) >= _z_min and (cz * SF) < _z_max


# Per-column bound of the cy values that can matter. Any empty cell that yields output
# (side cap / bottom cap) needs a solid cell within |dy| <= 4 inside the 13-column box,
# and solid cells span [hT-16, hT]; hence [Hmin-20, Hmax+4]. Returns Vector2i(lo, hi)
# or Vector2i(1, 0) (empty range) when no box column is inside the footprint.
func _cy_bounds(cx: int, cz: int) -> Vector2i:
	var any := false
	var hmin := 0
	var hmax := 0
	for b in BOX:
		var nx := cx + b.x
		var nz := cz + b.y
		if not _in_foot(nx, nz):
			continue
		var h := _col_ht(nx, nz)
		if not any:
			hmin = h
			hmax = h
			any = true
		elif h < hmin:
			hmin = h
		elif h > hmax:
			hmax = h
	if not any:
		return Vector2i(1, 0)
	return Vector2i(hmin - 20, hmax + 4)


## Build the base mesh for the region [x_min, x_max) x [z_min, z_max) (world metres).
func build(seed: int, extent: int, x_min: float, x_max: float, z_min: float, z_max: float) -> ArrayMesh:
	_ensure_tables()
	_seed = seed
	_floor_half = 4.0 * extent * SF
	_x_min = x_min
	_x_max = x_max
	_z_min = z_min
	_z_max = z_max
	_top_cells = {}
	_bottom_caps = {}
	_suppress = {}
	_force_x_split = {}

	# ---- iteration bounds (region + RMARGIN ring), as worldmesh.js
	var k_min := -2 * extent - 2
	var k_max := 2 * extent + 2
	var i_min := -2 * extent - 2
	var i_max := 2 * extent + 2
	var k_lo := maxi(k_min, int(floorf(z_min / (2.0 * SF))) - RMARGIN)
	var k_hi := mini(k_max, int(ceilf(z_max / (2.0 * SF))) + RMARGIN)
	var cy_lo_const := -10 - SLAB_DEPTH * TERRACE_LAT
	var cy_hi_const := 26
	var j_min := int(floorf((cy_lo_const - 2 * k_hi) / 4.0)) - JMARGIN
	var j_max := int(ceilf((cy_hi_const - 2 * k_lo) / 4.0)) + JMARGIN

	# per-k i ranges, and the global i extent for the dense column cache
	var ilo_of := PackedInt32Array()
	var ihi_of := PackedInt32Array()
	var gi_lo := 1 << 30
	var gi_hi := -(1 << 30)
	for k in range(k_lo, k_hi + 1):
		var lo := maxi(i_min, int(floorf((x_min / SF - 2 * k) / 4.0)) - RMARGIN)
		var hi := mini(i_max, int(ceilf((x_max / SF - 2 * k) / 4.0)) + RMARGIN)
		ilo_of.append(lo)
		ihi_of.append(hi)
		gi_lo = mini(gi_lo, lo)
		gi_hi = maxi(gi_hi, hi)
	var pad := 6
	_i0 = gi_lo - pad
	_i_n = gi_hi - gi_lo + 1 + 2 * pad
	_k0 = k_lo - pad
	_k_n = k_hi - k_lo + 1 + 2 * pad
	_ht_cache = PackedInt32Array()
	_ht_cache.resize(_i_n * _k_n)
	_ht_cache.fill(UNSET)

	# ---------------------------------------------------------------- Phase 1
	for k in range(k_lo, k_hi + 1):
		var cz := 2 * k
		for i in range(ilo_of[k - k_lo], ihi_of[k - k_lo] + 1):
			var cx := 4 * i + 2 * k
			var cb := _cy_bounds(cx, cz)
			if cb.x > cb.y:
				continue
			var ja := maxi(j_min, int(ceilf((cb.x - 2 * k) / 4.0)))
			var jb := mini(j_max, int(floorf((cb.y - 2 * k) / 4.0)))
			for j in range(ja, jb + 1):
				var cy := 4 * j + 2 * k
				if not _sp(cx, cy, cz):
					_empty_cell(cx, cy, cz)
					continue
				if not _sp(cx, cy + 4, cz):
					_top_cells[_col_key(cx, cz)] = Vector2i(_col_ht(cx, cz), cy)

	# ---------------------------------------------------------------- Phase 2
	# Flat cap decision: four same-height HIGH columns around a half-offset column.
	# Only the suppression of the five base faces the cap would replace matters here
	# (the cap solids themselves belong to the un-ported `caps` mesh).
	for key in _top_cells:
		var cell: Vector2i = _top_cells[key]
		if cell.y != cell.x:
			continue
		var cx: int = (key >> 16) - 4096
		var cz: int = (key & 0xFFFF) - 4096
		var hh: int = cell.x
		var kb := _col_key(cx + 4, cz)
		var kc := _col_key(cx, cz + 4)
		var kd := _col_key(cx + 4, cz + 4)
		var kg := _col_key(cx + 2, cz + 2)
		if not _top_cells.has(kb) or _top_cells[kb].x != hh:
			continue
		if not _top_cells.has(kc) or _top_cells[kc].x != hh:
			continue
		if not _top_cells.has(kd) or _top_cells[kd].x != hh:
			continue
		if not _top_cells.has(kg) or _top_cells[kg].x != hh:
			continue
		var g_cy: int = _top_cells[kg].y
		_suppress[_face_key(cx, hh, cz, 6)] = true
		_suppress[_face_key(cx + 4, hh, cz, 10)] = true
		_suppress[_face_key(cx, hh, cz + 4, 7)] = true
		_suppress[_face_key(cx + 4, hh, cz + 4, 11)] = true
		_suppress[_face_key(cx + 2, g_cy, cz + 2, 2)] = true

	# ---------------------------------------------------------------- Base extraction
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for k in range(k_lo, k_hi + 1):
		var cz := 2 * k
		for i in range(ilo_of[k - k_lo], ihi_of[k - k_lo] + 1):
			var cx := 4 * i + 2 * k
			if not _in_region(cx, cz):
				continue
			var cb := _cy_bounds(cx, cz)
			if cb.x > cb.y:
				continue
			var ja := maxi(j_min, int(ceilf((cb.x - 2 * k) / 4.0)))
			var jb := mini(j_max, int(floorf((cb.y - 2 * k) / 4.0)))
			for j in range(ja, jb + 1):
				var cy := 4 * j + 2 * k
				if not _solid_or_cap(cx, cy, cz):
					continue
				var origin := Vector3(cx * SF, cy * SF, cz * SF)
				for fi in 14:
					var off := NEIGHBOR_OFFSETS[fi]
					if _solid_or_cap(cx + off.x, cy + off.y, cz + off.z):
						continue
					var fkey := _face_key(cx, cy, cz, fi)
					if _suppress.has(fkey):
						continue
					var tr: PackedInt32Array = _tris_alt[fi] if ((fi == 2 or fi == 3) and _force_x_split.has(fkey)) else _tris[fi]
					var n := _normals[fi]
					for vi in tr:
						verts.append(origin + _voff[vi])
						norms.append(n)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Phase 1 handling of an EMPTY cell: side cap in a tall blocky wall, else bottom cap.
func _empty_cell(cx: int, cy: int, cz: int) -> void:
	var wall := -1
	for di in 4:
		var d: Dictionary = SIDE_DIRS[di]
		var op: Vector3i = d["open"]
		var bo: Vector3i = d["backing"]
		if _sp(cx + op.x, cy + op.y, cz + op.z):
			continue
		if not _sp(cx + bo.x, cy + bo.y, cz + bo.z):
			continue
		var mated := true
		for mo: Vector3i in d["mating"]:
			if not _sp(cx + mo.x, cy + mo.y, cz + mo.z):
				mated = false
				break
		if not mated:
			continue
		if _col_ht(cx + bo.x, cz + bo.z) - _col_ht(cx + op.x, cz + op.z) < SIDE_WALL_MIN:
			continue
		if _mesa_lift(cx + bo.x, cz + bo.z, _seed) <= 0.0:
			continue
		var flat := true
		for rn: Vector3i in d["run"]:
			if _sp(cx + rn.x + op.x, cy + rn.y + op.y, cz + rn.z + op.z):
				flat = false
				break
			if not _sp(cx + rn.x + bo.x, cy + rn.y + bo.y, cz + rn.z + bo.z):
				flat = false
				break
		if not flat:
			continue
		wall = di
		break
	if wall >= 0:
		var d: Dictionary = SIDE_DIRS[wall]
		var op: Vector3i = d["open"]
		var ter := float(cy - _col_ht(cx + op.x, cz + op.z)) / TERRACE_LAT
		var place_prob := maxf(SIDE_PLACE_MIN, 1.0 - SIDE_ROUGH * ter)
		if _cell_hash(cx, cy, cz, _seed) < place_prob:
			var mating: Array = d["mating"]
			var mating_face: Array = d["mating_face"]
			for m in 4:
				var mo: Vector3i = mating[m]
				_suppress[_face_key(cx + mo.x, cy + mo.y, cz + mo.z, mating_face[m])] = true
			var bk: Vector3i = d["backing"]
			_suppress[_face_key(cx + bk.x, cy + bk.y, cz + bk.z, d["backing_face"])] = true
			if d["z_wall"]:
				if _sp(cx, cy - 4, cz):
					_force_x_split[_face_key(cx, cy - 4, cz, 2)] = true
				if _sp(cx, cy + 4, cz):
					_force_x_split[_face_key(cx, cy + 4, cz, 3)] = true
		return
	# Bottom cap: seated on solid below, with an overhanging solid hex above.
	if _sp(cx, cy - 4, cz) and (_sp(cx + 2, cy + 2, cz + 2) or _sp(cx + 2, cy + 2, cz - 2) \
			or _sp(cx - 2, cy + 2, cz + 2) or _sp(cx - 2, cy + 2, cz - 2)):
		_bottom_caps[_cell_key(cx, cy, cz)] = true
