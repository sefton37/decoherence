extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #549 -- the understory's game policy: shrub and wildflower sprites, the voxel-shrub meshes and
## cutout textures, billboard widths, wind amplitudes and tier routing. Looks are the frozen Stalag
## prototype's (tag prototype-final: index.html prepShrubs, prepWildflowers, FORM_WIDTH,
## shrubBillboardGeometry, makeWindy, makeWindyShrub); the data is baked by tools/bake_trees.mjs into
## game/world/assets/understory/. The engine (StalagUnderstory) only places instances.

const DIR := "res://game/world/assets/understory/"
const FloraAssets := preload("res://game/world/flora_assets.gd")
const FLORA_SHADER := "res://engine/stalag/shaders/stalag_flora.gdshader"
const SHRUB_SHADER := "res://engine/stalag/shaders/stalag_shrub.gdshader"

## Billboard widths in metres per flower (index.html FORM_WIDTH by the flower's form class).
const FLOWER_WIDTH := {
	"flower-spike-lupine": 0.42, "flower-dot-forgetmenot": 0.30, "flower-cushion-campion": 0.24,
	"flower-sensor-bloom": 0.36, "flower-spike-fireweed": 0.44, "flower-cup-poppy": 0.34, "flower-ray-arnica": 0.34,
}
## Sway: flowers 0.05 and T1 shrubs 0.03 (makeWindy); voxel shrubs lean 0.03 and twist cells 0.20.
const AMP_FLOWER := 0.05
const AMP_T1_SHRUB := 0.03
const AMP_VOXEL_LEAN := 0.03
const AMP_VOXEL_CELL := 0.20

var manifest: Dictionary = {}
var blob := PackedByteArray()
## voxel shrub id -> Mesh surface arrays as loaded
var decoded := {}
var load_ms := 0.0
## MultiMesh key -> {mesh, material, cast, range_end, colors}. Keys: a shrub id, or a flower id, a slash
## and the tier. Nothing in the understory casts shadows (Spec #549 D9).
var forms := {}
var _flora_mats: Array = []  # flower and T1 shrub billboards (stalag_flora.gdshader)
var _voxel_mats: Array = []  # voxel shrubs (stalag_shrub.gdshader)
var _front_locked := false


func _init() -> void:
	var t0 := Time.get_ticks_usec()
	manifest = JSON.parse_string(FileAccess.get_file_as_string(DIR + "manifest.json"))
	var f := FileAccess.open(DIR + "understory.bin", FileAccess.READ)
	blob = f.get_buffer(f.get_length())
	f.close()
	for s in manifest["shrubs"]:
		if s["kind"] == "voxel":
			var c: Dictionary = s["crown"]
			decoded[s["id"]] = StalagTrees.decode_arrays(blob, int(c["offset"]), int(c["verts"]), "crown")
	_build_forms()
	load_ms = (Time.get_ticks_usec() - t0) / 1000.0


func _billboard(sprite_file: String, w: float, amp: float) -> Dictionary:
	var img := image(sprite_file)
	var h := w * (float(img.get_height()) / float(img.get_width()))
	var m := ShaderMaterial.new()
	m.shader = load(FLORA_SHADER)
	m.set_shader_parameter("sprite", ImageTexture.create_from_image(img))
	m.set_shader_parameter("wind_amp", amp)
	_flora_mats.append(m)
	return {"mesh": FloraAssets._cross_mesh(w, h), "material": m, "cast": GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "range_end": 0.0, "colors": false}


func _build_forms() -> void:
	var sprite_files := {}
	for sp in manifest["sprites"]:
		sprite_files[sp["id"]] = sp["file"]
	for s in manifest["shrubs"]:
		var id: String = s["id"]
		if s["kind"] == "sprite":
			var h: float = s["height_m"]
			var img := image(sprite_files[id])
			forms[id] = _billboard(sprite_files[id], h * (float(img.get_width()) / float(img.get_height())), AMP_T1_SHRUB)
		else:
			var arrays: Array = decoded[id]
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, StalagTrees.index_arrays(arrays), [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			mesh.custom_aabb = mesh.get_aabb().grow(0.5)
			var m := ShaderMaterial.new()
			m.shader = load(SHRUB_SHADER)
			m.set_shader_parameter("cutout_tex", ImageTexture.create_from_image(image(str(s["cutout"]) + ".png")))
			m.set_shader_parameter("wind_amp", AMP_VOXEL_LEAN)
			m.set_shader_parameter("cell_amp", AMP_VOXEL_CELL)
			_voxel_mats.append(m)
			forms[id] = {"mesh": mesh, "material": m, "cast": GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "range_end": 0.0, "colors": false}
	for fid in FLOWER_WIDTH.keys():
		for tier in ["muted", "vivid"]:
			forms[fid + "/" + tier] = _billboard(sprite_files[fid + "/" + tier], FLOWER_WIDTH[fid], AMP_FLOWER)


func materials() -> Array:
	return _flora_mats + _voxel_mats


## Per-frame wind feed: the same clock and weather front as the meadow and the crowns.
func set_time(t: float) -> void:
	var fr: Dictionary = StalagWind.current_front(t)
	for m in materials():
		m.set_shader_parameter("u_time", t)
		if _front_locked:
			continue
		m.set_shader_parameter("front_n", Vector2(fr["nx"], fr["nz"]))
		m.set_shader_parameter("front_off", fr["offset"])
		m.set_shader_parameter("front_pk", fr["peak"])


func force_strength(s: float) -> void:
	for m in materials():
		m.set_shader_parameter("strength_override", s)


func force_front(n: Vector2, off: float, pk: float, unlock: bool = false) -> void:
	_front_locked = not unlock
	if unlock:
		return
	for m in materials():
		m.set_shader_parameter("front_n", n)
		m.set_shader_parameter("front_off", off)
		m.set_shader_parameter("front_pk", pk)


## Probe hook: zero every understory amplitude (negative control).
func disable_wind() -> void:
	for m in _flora_mats:
		m.set_shader_parameter("wind_amp", 0.0)
	for m in _voxel_mats:
		m.set_shader_parameter("wind_amp", 0.0)
		m.set_shader_parameter("cell_amp", 0.0)


## Probe hook: set the voxel shrubs' whole-bush lean and per-cell twist amplitudes (the motion split).
func set_voxel_amps(lean: float, cell: float) -> void:
	for m in _voxel_mats:
		m.set_shader_parameter("wind_amp", lean)
		m.set_shader_parameter("cell_amp", cell)


## sha256 of what was loaded for one voxel shrub, flattened back to the baked layout.
func array_hash(id: String) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(StalagTrees.flatten_arrays(decoded[id], "crown").to_byte_array())
	return h.finish().hex_encode()


## Read raw (the directory carries a .gdignore, so Godot never imports the PNGs).
func image(file: String) -> Image:
	return Image.load_from_file(DIR + file)


## sha256 prefix (16 hex) of an Image's raw RGBA8 bytes.
static func rgba_sha16(img: Image) -> String:
	var im := img.duplicate()
	im.convert(Image.FORMAT_RGBA8)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(im.get_data())
	return h.finish().hex_encode().substr(0, 16)
