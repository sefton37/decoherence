extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #545 -- the meadow's game policy: which sprite or rock each form uses, how wide the
## billboards are, how hard the wind leans them, and the per-frame wind feed. Looks are the frozen
## Stalag prototype's (tag prototype-final: index.html FORM_WIDTH, billboardGeometry, rockGeometry,
## makeWindy, ROCK embed); the sprites and rock meshes are baked by tools/bake_flora.mjs into
## game/world/assets/flora/. The engine (StalagFlora, StalagChunkMesher) only places instances.

const SPRITE_DIR := "res://game/world/assets/flora/"
const FLORA_SHADER := "res://engine/stalag/shaders/stalag_flora.gdshader"
const ROCK_SHADER := "res://engine/stalag/shaders/stalag_rock.gdshader"

## Billboard width in metres per form class (index.html FORM_WIDTH).
const FORM_WIDTH := {"grass-tuft": 0.40, "ground-cover": 0.42, "fern": 0.50, "shrub": 0.62}
const BILLBOARDS := {
	"tuft-billboard-baseline": "grass-tuft",
	"tuft-billboard-bladed": "grass-tuft",
	"cover-billboard-creep": "ground-cover",
	"fern-billboard-frond": "fern",
	"fern-billboard-mirror": "fern",
	"shrub-billboard-lump": "shrub",
}
const ROCKS := ["rock-pebbles", "rock-cobble", "rock-boulder", "rock-outcrop"]
## Sway amplitude: grass and cover 0.06, fern and shrub 0.03 (makeWindy).
const AMP_GRASS := 0.06
const AMP_FERN := 0.03
## Rocks sink 5 cm so they read half buried (prepFoliage embed). One deliberate exception: the
## pebbles. The prototype's pebble mesh stands 3.8 cm tall at scale 1, so sunk 5 cm it never
## breaks the ground (all 817 ring pebbles measured fully buried, spec #545 DOD-17); they sit
## on the ground instead. Flagged for the coordinator; one constant to revert.
const ROCK_EMBED := 0.05
const ROCK_EMBED_PEBBLES := 0.0

## form id -> {mesh: Mesh, material: ShaderMaterial, casts: bool, sprite: Image or null}
var forms := {}
var _billboard_mats: Array = []
var _rock_mats: Array = []
var _front_locked := false


func _init() -> void:
	for id in BILLBOARDS.keys():
		_add_billboard(id, BILLBOARDS[id])
	_add_rocks()


func _add_billboard(id: String, form: String) -> void:
	# Read raw: the asset directory carries a .gdignore, so Godot never imports it.
	var img := Image.load_from_file(SPRITE_DIR + id + ".png")
	var tex := ImageTexture.create_from_image(img)
	var w: float = FORM_WIDTH[form]
	var h: float = w * (float(img.get_height()) / float(img.get_width()))
	var m := ShaderMaterial.new()
	m.shader = load(FLORA_SHADER)
	m.set_shader_parameter("sprite", tex)
	m.set_shader_parameter("wind_amp", AMP_FERN if (form == "fern" or form == "shrub") else AMP_GRASS)
	_billboard_mats.append(m)
	forms[id] = {"mesh": _cross_mesh(w, h), "material": m, "casts": false, "sprite": img}


## Two crossed quads, 3 height segments each so the tips can curve (billboardGeometry): the base
## sunk by `embed` so the plant roots; up-normals are the shader's job.
static func _cross_mesh(w: float, h: float) -> ArrayMesh:
	var embed := maxf(0.06, 0.16 * h)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for q in range(2):
		var base := verts.size()
		for iy in range(4):  # rows from the top
			var y := (h - embed) - h * float(iy) / 3.0  # plane spans -embed .. h - embed
			for ix in range(2):
				var x := -w / 2.0 + w * float(ix)
				verts.append(Vector3(x, y, 0.0) if q == 0 else Vector3(0.0, y, -x))
				uvs.append(Vector2(float(ix), float(iy) / 3.0))
		for iy in range(3):
			var a := base + iy * 2
			idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _add_rocks() -> void:
	var txt := FileAccess.get_file_as_string(SPRITE_DIR + "rocks.json")
	var data: Dictionary = JSON.parse_string(txt)
	for r in data["rocks"]:
		var pos: Array = r["positions"]
		var nrm: Array = r["normals"]
		var col: Array = r["colors"]
		var nv := pos.size() / 3
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var c := PackedColorArray()
		v.resize(nv)
		n.resize(nv)
		c.resize(nv)
		# The prototype's triangles are counter-clockwise; Godot's front face is clockwise, so swap
		# the 2nd and 3rd vertex of every triangle (as the terrain mesher does).
		var embed: float = ROCK_EMBED_PEBBLES if r["id"] == "rock-pebbles" else ROCK_EMBED
		for t in range(0, nv, 3):
			for k in range(3):
				var src := t + (0 if k == 0 else (2 if k == 1 else 1))
				v[t + k] = Vector3(pos[src * 3], pos[src * 3 + 1] - embed, pos[src * 3 + 2])
				n[t + k] = Vector3(nrm[src * 3], nrm[src * 3 + 1], nrm[src * 3 + 2])
				c[t + k] = Color(col[src * 3], col[src * 3 + 1], col[src * 3 + 2], 1.0)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		arrays[Mesh.ARRAY_COLOR] = c
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var m := ShaderMaterial.new()
		m.shader = load(ROCK_SHADER)
		_rock_mats.append(m)
		forms[r["id"]] = {"mesh": mesh, "material": m, "casts": true, "sprite": null}


func billboard_ids() -> Array:
	return BILLBOARDS.keys()


func materials() -> Array:
	return _billboard_mats + _rock_mats


## Per-frame wind feed (index.html animate): one shared clock and the weather front.
func set_time(t: float) -> void:
	var fr: Dictionary = StalagWind.current_front(t)
	for m in _billboard_mats:
		m.set_shader_parameter("u_time", t)
		if _front_locked:
			continue
		m.set_shader_parameter("front_n", Vector2(fr["nx"], fr["nz"]))
		m.set_shader_parameter("front_off", fr["offset"])
		m.set_shader_parameter("front_pk", fr["peak"])


## Probe hook: force the field strength (>= 0) or hand it back to the field (< 0).
func force_strength(s: float) -> void:
	for m in _billboard_mats:
		m.set_shader_parameter("strength_override", s)


## Probe hook: pin the front wall (normal, offset, peak) so set_time stops feeding it; pass
## unlock = true to hand it back to the weather.
func force_front(n: Vector2, off: float, pk: float, unlock: bool = false) -> void:
	_front_locked = not unlock
	if unlock:
		return
	for m in _billboard_mats:
		m.set_shader_parameter("front_n", n)
		m.set_shader_parameter("front_off", off)
		m.set_shader_parameter("front_pk", pk)


## Probe hook: zero the sway amplitude (negative control).
func disable_wind() -> void:
	for m in _billboard_mats:
		m.set_shader_parameter("wind_amp", 0.0)


## Probe hook: sample the sprites upside down (negative control only).
func sprites_flipped(on: bool) -> void:
	for m in _billboard_mats:
		m.set_shader_parameter("flip_v", on)


## Probe hook: feed the rock colours un-converted (negative control).
func rocks_srgb(on: bool) -> void:
	for m in _rock_mats:
		m.set_shader_parameter("colors_are_srgb", on)
