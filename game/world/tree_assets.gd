extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #549 -- the forest's game policy: which mesh and material each tree form uses, the per-species
## crown tint, the crown wind amplitude and the shadow caster policy. Looks are the frozen Stalag
## prototype's (tag prototype-final: index.html TREE_CANOPY_PARAMS hueDeg, hueDegToColor,
## makeWindyCrown, prepTrees); the meshes and leaf textures are baked by tools/bake_trees.mjs into
## game/world/assets/trees/. The engine (StalagTrees, StalagChunkMesher) only places instances.

const DIR := "res://game/world/assets/trees/"

## Crown colour tint per species: hsv2rgb(128 + hueDeg, 0.30, 0.92) as material colour (index.html
## TREE_CANOPY_PARAMS hueDeg, CROWN_BASE_HUE, CROWN_TINT_S, CROWN_TINT_V).
const HUE_DEG := {
	"frost-sapling": 4, "scrub-birch": 8, "young-spire": -2, "boreal-fir": -6, "broadleaf-lump": 2,
	"tall-pine": -4, "northwatch-larch": 6, "twin-trunk": 0, "elder-pine": -8, "sensor-pine": -3,
}
const CROWN_BASE_HUE := 128.0
const CROWN_TINT_S := 0.30
const CROWN_TINT_V := 0.92
## Whole-crown sway (makeWindyCrown(..., 0.045)).
const CROWN_WIND_AMP := 0.045
## Crown shadows (Spec #549 D12): the shadow proxies cast within this distance (a range on a trunk would
## also stop drawing it, so the trunks cast at every distance).
const SHADOW_DISTANCE_M := 70.0
const DEAD_FORMS := ["standing-snag", "cut-stump"]
const LEAF_SHADER := "res://engine/stalag/shaders/stalag_leaf.gdshader"
const ROCK_SHADER := "res://engine/stalag/shaders/stalag_rock.gdshader"

var manifest: Dictionary = {}
var blob := PackedByteArray()
## form id -> {trunk: Array, crown: Array or null, shadow: Array or null} (Mesh surface arrays as loaded)
var decoded := {}
var load_ms := 0.0
## form id -> {part name: {mesh, material, cast, range_end, colors}}; parts are "trunk", "crown", "shadow".
## `cast` is a GeometryInstance3D shadow casting setting: trunks cast, the full crowns never do, the
## baked shadow proxies cast shadows only. `colors` marks the MultiMesh that carries per-instance colour.
var forms := {}
var _crown_mats: Array = []
var _trunk_mat: ShaderMaterial
var _front_locked := false


func _init() -> void:
	var t0 := Time.get_ticks_usec()
	manifest = JSON.parse_string(FileAccess.get_file_as_string(DIR + "manifest.json"))
	var f := FileAccess.open(DIR + "trees.bin", FileAccess.READ)
	blob = f.get_buffer(f.get_length())
	f.close()
	for form in manifest["forms"]:
		var d := {"trunk": null, "crown": null, "shadow": null}
		for part in ["trunk", "crown", "shadow"]:
			var p = form[part]
			if p != null:
				d[part] = StalagTrees.decode_arrays(blob, int(p["offset"]), int(p["verts"]), part)
		decoded[form["id"]] = d
	_build_forms()
	load_ms = (Time.get_ticks_usec() - t0) / 1000.0


func _surface_mesh(arrays: Array, crown: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var flags := 0
	if crown:
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	# the baked runs are a triangle soup; merging identical vertices (same triangles, same order) lets
	# the GPU shade each distinct vertex once, which is most of the crown cost (per-vertex wind field)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, StalagTrees.index_arrays(arrays), [], {}, flags)
	# the wind moves vertices a little; give the culling box room for it
	mesh.custom_aabb = mesh.get_aabb().grow(1.0)
	return mesh


## Crown tint: hsv2rgb(128 + hueDeg, 0.30, 0.92), raw linear values (index.html hueDegToColor).
static func crown_tint(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(CROWN_BASE_HUE + hue_deg, 360.0) / 360.0, CROWN_TINT_S, CROWN_TINT_V)


func _build_forms() -> void:
	var imgs := leaf_images()
	var tex := {}
	for k in imgs.keys():
		tex[k] = ImageTexture.create_from_image(imgs[k])
	_trunk_mat = ShaderMaterial.new()
	_trunk_mat.shader = load(ROCK_SHADER)
	for form in manifest["forms"]:
		var id: String = form["id"]
		var d: Dictionary = decoded[id]
		var parts := {}
		parts["trunk"] = {"mesh": _surface_mesh(d["trunk"], false), "material": _trunk_mat,
			"cast": GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "range_end": 0.0, "colors": false}  # no range: it would also stop drawing the trunk
		if d["crown"] != null:
			var m := ShaderMaterial.new()
			m.shader = load(LEAF_SHADER)
			m.set_shader_parameter("leaf_tex", tex["leaf_" + str(form["crown"]["leaf_tex"])])
			m.set_shader_parameter("tint", crown_tint(float(HUE_DEG[id])))
			m.set_shader_parameter("wind_amp", CROWN_WIND_AMP)
			_crown_mats.append(m)
			parts["crown"] = {"mesh": _surface_mesh(d["crown"], true), "material": m,
				"cast": GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "range_end": 0.0, "colors": true}
			parts["shadow"] = {"mesh": _surface_mesh(d["shadow"], false), "material": null,
				"cast": GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, "range_end": SHADOW_DISTANCE_M, "colors": false}
		forms[id] = parts


func materials() -> Array:
	return _crown_mats


## Per-frame wind feed (index.html animate): one shared clock and the weather front, the same feed
## the meadow gets (flora_assets.gd set_time).
func set_time(t: float) -> void:
	var fr: Dictionary = StalagWind.current_front(t)
	for m in _crown_mats:
		m.set_shader_parameter("u_time", t)
		if _front_locked:
			continue
		m.set_shader_parameter("front_n", Vector2(fr["nx"], fr["nz"]))
		m.set_shader_parameter("front_off", fr["offset"])
		m.set_shader_parameter("front_pk", fr["peak"])


## Probe hook: force the field strength (>= 0) or hand it back to the field (< 0).
func force_strength(s: float) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("strength_override", s)


## Probe hook: pin the front wall so set_time stops feeding it; unlock = true hands it back.
func force_front(n: Vector2, off: float, pk: float, unlock: bool = false) -> void:
	_front_locked = not unlock
	if unlock:
		return
	for m in _crown_mats:
		m.set_shader_parameter("front_n", n)
		m.set_shader_parameter("front_off", off)
		m.set_shader_parameter("front_pk", pk)


## Probe hooks (negative controls and the motion split): whole-crown lean, per-cell flutter, alpha, tint.
func disable_wind() -> void:
	set_lean_amp(0.0)


func set_lean_amp(a: float) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("wind_amp", a)


func set_flutter_amp(a: float) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("u_leaf_amp", a)


## Probe hooks that isolate the per-cell tumble: the travelling-front ripple (u_leaf_front_amp) and the
## vertical shimmer, both of which also move cells, can be taken out; `set_leaf_rate` is the flutter
## angular rate (rad/s), 0 freezes every per-cell time term (a negative control).
func set_front_amp(a: float) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("u_leaf_front_amp", a)


func set_shimmer(a: float) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("u_leaf_shimmer", a)


func set_leaf_rate(w: float) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("u_leaf_w", w)


func alpha_solid(on: bool) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("alpha_solid", 1.0 if on else 0.0)


func tint_flat(on: bool) -> void:
	for m in _crown_mats:
		m.set_shader_parameter("tint_flat", 1.0 if on else 0.0)


## sha256 of what was loaded for one form: the three runs flattened back to the baked layout, in file
## order. Equal to the bake's own array_hash only if the engine holds the bytes the bake wrote.
func array_hash(id: String) -> String:
	var d: Dictionary = decoded[id]
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	for part in ["trunk", "crown", "shadow"]:
		if d[part] != null:
			h.update(StalagTrees.flatten_arrays(d[part], part).to_byte_array())
	return h.finish().hex_encode()


func form_ids() -> Array:
	var ids := []
	for form in manifest["forms"]:
		ids.append(form["id"])
	return ids


## The two leaf textures as {id: Image}, read raw (the directory carries a .gdignore).
func leaf_images() -> Dictionary:
	var out := {}
	for t in manifest["leaf_tex"]:
		out[t["id"]] = Image.load_from_file(DIR + t["id"] + ".png")
	return out


## sha256 prefix (16 hex) of an Image's raw RGBA8 bytes.
static func rgba_sha16(img: Image) -> String:
	var im := img.duplicate()
	im.convert(Image.FORMAT_RGBA8)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(im.get_data())
	return h.finish().hex_encode().substr(0, 16)
