extends Node3D
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 580 S4 -- the backdrop ring: a visual-only far skirt from the edge of the playable footprint (+-112 m) out to
## about 300 m, so that the world does not end in a cliff of sky and so that river and lake water that runs past the
## footprint meets land or water instead of nothing. It is built in GDScript from the engine's own height function
## on a coarse grid; it has no collision and is not walkable. Everything here is procedural or self-made: the
## terrain and the sea are generated meshes, the distant trees are crossed-quad impostors whose silhouette sprites
## are drawn in code below, tinted with the same per-species crown colours as the real forest (tree_assets.gd
## CROWN_TINTS). No image, mesh or sound is loaded from disk. The world scene builds it only at the `far` and
## `vista` view levels; `near` never creates it.
##
## The ring is built a few columns of cells per frame (never in one frame), each band as its own mesh, so that the
## main thread never pays for the whole ring at once.

const TreeAssets := preload("res://game/world/tree_assets.gd")
const SHADER := "res://game/world/backdrop.gdshader"
const CELL_M := 8.0  ## the coarse grid
const INNER_HALF_M := 112.0  ## the playable footprint; the ring starts where the real terrain ends
const OUTER_HALF_M := 304.0  ## 38 cells from the centre: a little past 300 m
const SEA_Y := 2.0  ## below the water plan's shore level at the footprint edge (1.2 to 3.3): lowland past the edge floods, the rest is land
const SINK_M := 0.35  ## the ring terrain sits this far under the engine's height, so it never pokes through the edge
const COLS_PER_STEP := 1  ## columns of cells computed per frame
const COLS_PER_MESH := 10  ## columns gathered into one mesh (fewer draw calls than a mesh per column)
const TREE_CELL_M := 7.0
const TREE_CHANCE := 0.55
const TREE_MIN_H := 7.0
const TREE_MAX_H := 17.0
const TREE_WIDTH_FRAC := 0.42
const TREE_LAND_MARGIN_M := 0.4  ## trees stand only where the ground is this far above the sea
const LEAF_BAKED := Color(0.78, 1.0, 0.78)  ## the baked per-tree colour the real crowns are multiplied by
## The forest table's weights per species (stalag_trees.cpp FOREST_W), so the far forest has the same mix.
const SPECIES_WEIGHTS := {
	"boreal-fir": 20, "young-spire": 16, "broadleaf-lump": 15, "frost-sapling": 12, "scrub-birch": 12,
	"northwatch-larch": 10, "twin-trunk": 10, "sensor-pine": 3, "tall-pine": 3, "elder-pine": 1,
}
const TERRAIN_LOW := Color(0.15, 0.25, 0.07)
const TERRAIN_HIGH := Color(0.26, 0.28, 0.10)
const SEA_COLOR := Color(0.12, 0.34, 0.36)

var tris := 0
var trees := 0
var water_cells := 0
var step_ms_max := 0.0  ## the longest single frame the ring's build took on the main thread
var build_ms_total := 0.0

var _shader: Shader
var _terrain_mat: ShaderMaterial
var _sea_mat: ShaderMaterial
var _cone_mat: ShaderMaterial
var _round_mat: ShaderMaterial
var _impostor_mesh: ArrayMesh
var _species: Array = []  ## [{id, color, round}] in weight order
var _weight_total := 0
var _next_col := 0
var _last_col := 0
var _done := false
var _first_col := 0
var _tv := PackedVector3Array()
var _tc := PackedColorArray()
var _wv := PackedVector3Array()
var _cone_xf: Array = []
var _round_xf: Array = []
var _cols_gathered := 0


## `tree_assets` is the world's TreeAssets (read only: manifest, leaf images and the crown tint table).
func setup(tree_assets: RefCounted) -> void:
	_shader = load(SHADER)
	_terrain_mat = _material(false, null)
	_sea_mat = _material(false, null)
	_cone_mat = _material(true, _sprite(false))
	_round_mat = _material(true, _sprite(true))
	_impostor_mesh = _cross_mesh()
	var means := _leaf_means(tree_assets)
	var leaf_of := {}
	for form in tree_assets.manifest["forms"]:
		if form["crown"] != null:
			leaf_of[form["id"]] = str(form["crown"]["leaf_tex"])
	for id in SPECIES_WEIGHTS.keys():
		var tint: Color = TreeAssets.crown_tint(TreeAssets.CROWN_TINTS[id])
		var leaf: Color = means[leaf_of[id]]
		var c := Color(leaf.r * LEAF_BAKED.r * tint.r, leaf.g * LEAF_BAKED.g * tint.g, leaf.b * LEAF_BAKED.b * tint.b)
		_species.append({"id": id, "color": c, "round": leaf_of[id] == "warm"})
		_weight_total += int(SPECIES_WEIGHTS[id])
	_first_col = int(floor(-OUTER_HALF_M / CELL_M))
	_last_col = int(floor(OUTER_HALF_M / CELL_M)) - 1
	_next_col = _first_col


func materials() -> Array:
	return [_terrain_mat, _sea_mat, _cone_mat, _round_mat]


func is_done() -> bool:
	return _done


func _process(_delta: float) -> void:
	if _done or _shader == null:
		return
	var upto := mini(_next_col + COLS_PER_STEP - 1, _last_col)
	var t0 := Time.get_ticks_usec()
	_build_band(_next_col, upto)
	_cols_gathered += upto - _next_col + 1
	if _cols_gathered >= COLS_PER_MESH or upto >= _last_col:
		_flush()
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	step_ms_max = maxf(step_ms_max, ms)
	build_ms_total += ms
	_next_col = upto + 1
	if _next_col > _last_col:
		_done = true


func _material(sprite: bool, tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("use_sprite", sprite)
	if tex != null:
		m.set_shader_parameter("sprite", tex)
	return m


# ---------------------------------------------------------------- the bands
func _build_band(c0: int, c1: int) -> void:
	var rows_n := int(floor(OUTER_HALF_M / CELL_M)) * 2
	var z_first := int(floor(-OUTER_HALF_M / CELL_M))
	for i in range(c0, c1 + 1):
		for j in range(z_first, z_first + rows_n):
			var cx := (float(i) + 0.5) * CELL_M
			var cz := (float(j) + 0.5) * CELL_M
			if absf(cx) < INNER_HALF_M and absf(cz) < INNER_HALF_M:
				continue  # inside the playable footprint: the real terrain is there
			var x0 := float(i) * CELL_M
			var z0 := float(j) * CELL_M
			var h00 := _h(x0, z0)
			var h10 := _h(x0 + CELL_M, z0)
			var h01 := _h(x0, z0 + CELL_M)
			var h11 := _h(x0 + CELL_M, z0 + CELL_M)
			var n := _hash(i, j, 7)
			var shade := float(n & 255) / 255.0
			var col := TERRAIN_LOW.lerp(TERRAIN_HIGH, clampf((h00 + h11) * 0.5 / 10.0 + (shade - 0.5) * 0.4, 0.0, 1.0))
			var a := Vector3(x0, h00 - SINK_M, z0)
			var b := Vector3(x0 + CELL_M, h10 - SINK_M, z0)
			var c := Vector3(x0, h01 - SINK_M, z0 + CELL_M)
			var d := Vector3(x0 + CELL_M, h11 - SINK_M, z0 + CELL_M)
			# Godot's front face is clockwise seen from above: a, c, b and b, c, d face up
			_tv.append_array([a, c, b, b, c, d])
			for _k in range(6):
				_tc.append(col)
			tris += 2
			if minf(minf(h00, h10), minf(h01, h11)) < SEA_Y:
				var s00 := Vector3(x0, SEA_Y, z0)
				var s10 := Vector3(x0 + CELL_M, SEA_Y, z0)
				var s01 := Vector3(x0, SEA_Y, z0 + CELL_M)
				var s11 := Vector3(x0 + CELL_M, SEA_Y, z0 + CELL_M)
				_wv.append_array([s00, s01, s10, s10, s01, s11])
				tris += 2
				water_cells += 1
		_place_trees(i, _cone_xf, _round_xf)


## Turns what the last few columns gathered into meshes and starts again.
func _flush() -> void:
	_add_surface_mesh(_tv, _tc, _terrain_mat)
	_add_surface_mesh(_wv, PackedColorArray(), _sea_mat, SEA_COLOR)
	_add_trees(_cone_xf, _cone_mat)
	_add_trees(_round_xf, _round_mat)
	_tv = PackedVector3Array()
	_tc = PackedColorArray()
	_wv = PackedVector3Array()
	_cone_xf = []
	_round_xf = []
	_cols_gathered = 0


func _h(x: float, z: float) -> float:
	return float(StalagWorld.ground_envelope_at(x, z, INF))


## Hashed tree placement for the tree cells that fall in the column of grid cells `i` (one terrain cell wide).
func _place_trees(i: int, cone_xf: Array, round_xf: Array) -> void:
	var x_lo := float(i) * CELL_M
	var x_hi := x_lo + CELL_M
	var gx0 := int(floor(x_lo / TREE_CELL_M))
	var gx1 := int(floor((x_hi - 0.001) / TREE_CELL_M))
	var gz_lim := int(floor(OUTER_HALF_M / TREE_CELL_M))
	for gx in range(gx0, gx1 + 1):
		var cxm := (float(gx) + 0.5) * TREE_CELL_M
		if cxm < x_lo or cxm >= x_hi:
			continue  # each tree cell belongs to exactly one column of terrain cells
		for gz in range(-gz_lim, gz_lim):
			var czm := (float(gz) + 0.5) * TREE_CELL_M
			if absf(cxm) < INNER_HALF_M + 2.0 and absf(czm) < INNER_HALF_M + 2.0:
				continue
			if absf(cxm) > OUTER_HALF_M - 4.0 or absf(czm) > OUTER_HALF_M - 4.0:
				continue
			var h := _hash(gx, gz, 13)
			if float(h & 1023) / 1024.0 >= TREE_CHANCE:
				continue
			var jx := (float((h >> 10) & 255) / 255.0 - 0.5) * (TREE_CELL_M - 1.0)
			var jz := (float((h >> 18) & 255) / 255.0 - 0.5) * (TREE_CELL_M - 1.0)
			var x := cxm + jx
			var z := czm + jz
			var y := _h(x, z)
			if y < SEA_Y + TREE_LAND_MARGIN_M:
				continue
			var h2 := _hash(gx, gz, 29)
			var sp: Dictionary = _pick_species(int(h2 & 0xffff))
			var th := TREE_MIN_H + (TREE_MAX_H - TREE_MIN_H) * (float((h2 >> 16) & 255) / 255.0)
			var tw := th * TREE_WIDTH_FRAC
			var yaw := float((h2 >> 24) & 255) / 255.0 * TAU
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(tw, th, tw))
			var entry := [Transform3D(basis, Vector3(x, y - 0.3, z)), sp["color"]]
			if sp["round"]:
				round_xf.append(entry)
			else:
				cone_xf.append(entry)
			trees += 1


func _pick_species(r: int) -> Dictionary:
	var a := r % _weight_total
	for s in _species:
		a -= int(SPECIES_WEIGHTS[s["id"]])
		if a < 0:
			return s
	return _species[0]


## A small integer hash of a cell and a salt (xorshift-multiply), deterministic across runs.
func _hash(a: int, b: int, salt: int) -> int:
	var h := (a * 374761393 + b * 668265263 + salt * 2246822519) & 0xffffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0xffffffff
	h = (h ^ (h >> 16)) & 0xffffffff
	return h


func _add_surface_mesh(verts: PackedVector3Array, colors: PackedColorArray, mat: ShaderMaterial, flat: Color = Color(1, 1, 1)) -> void:
	if verts.is_empty():
		return
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	for t in range(0, verts.size(), 3):
		var n := (verts[t + 1] - verts[t]).cross(verts[t + 2] - verts[t]).normalized()
		if n.y < 0.0:
			n = -n
		normals[t] = n
		normals[t + 1] = n
		normals[t + 2] = n
	if colors.is_empty():
		colors.resize(verts.size())
		colors.fill(flat)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Sea" if mat == _sea_mat else "Terrain"
	if mat == _sea_mat:
		mi.add_to_group("backdrop_water")
	add_child(mi)


func _add_trees(entries: Array, mat: ShaderMaterial) -> void:
	if entries.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _impostor_mesh
	mm.instance_count = entries.size()
	for k in range(entries.size()):
		mm.set_instance_transform(k, entries[k][0])
		mm.set_instance_color(k, entries[k][1])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.name = "Trees"
	add_child(mmi)
	tris += 4 * entries.size()


# ---------------------------------------------------------------- procedural assets
## Two crossed vertical quads, one metre wide and tall, standing on y = 0 (scaled per tree).
func _cross_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for q in range(2):
		var base := verts.size()
		for iy in range(2):
			for ix in range(2):
				var x := -0.5 + float(ix)
				var y := 1.0 - float(iy)
				verts.append(Vector3(x, y, 0.0) if q == 0 else Vector3(0.0, y, -x))
				uvs.append(Vector2(float(ix), float(iy)))
		idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)  # up-pointing normals on both faces, as the meadow billboards do
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A crown silhouette drawn in code: a layered cone (conifers) or a lumpy ellipse (broadleaf), alpha-cut, with a
## little brightness noise so a mass of them is not a flat colour.
func _sprite(round_crown: bool) -> ImageTexture:
	var w := 64
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		var fy := float(y) / float(h - 1)
		for x in range(w):
			var fx := (float(x) + 0.5) / float(w) * 2.0 - 1.0
			var inside := false
			if round_crown:
				var cy := (fy - 0.42) / 0.40
				inside = fx * fx + cy * cy <= 1.0 + 0.12 * sin(float(y) * 1.7 + float(x) * 0.9)
				if fy > 0.82 and absf(fx) < 0.09:
					inside = true  # trunk
			else:
				var layer := fmod(fy * 7.0, 1.0)
				var half := fy * 0.92 * (0.70 + 0.30 * layer) + 0.04 * sin(float(y) * 2.3)
				inside = fy > 0.04 and absf(fx) <= half
				if fy > 0.9 and absf(fx) < 0.08:
					inside = true
			var v := 0.78 + 0.22 * float((_hash(x, y, 3) & 255)) / 255.0
			img.set_pixel(x, y, Color(v, v, v, 1.0 if inside else 0.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## The mean linear colour of the opaque pixels of each leaf texture ("warm", "cool").
func _leaf_means(tree_assets: RefCounted) -> Dictionary:
	var out := {}
	var imgs: Dictionary = tree_assets.leaf_images()
	for k in imgs.keys():
		var img: Image = imgs[k]
		var key := str(k).trim_prefix("leaf_")
		var sum := Vector3.ZERO
		var n := 0
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var px := img.get_pixel(x, y)
				if px.a > 0.45:
					var lin := px.srgb_to_linear()
					sum += Vector3(lin.r, lin.g, lin.b)
					n += 1
		sum /= float(maxi(n, 1))
		out[key] = Color(sum.x, sum.y, sum.z)
	return out
