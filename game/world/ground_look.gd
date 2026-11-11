extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #551 phase 2 -- game policy for the ground materials: which art and which baked fields the
## ground shader (engine/stalag/shaders/stalag_grass.gdshader) draws, how strongly, and which
## materials keep the meadow's flora off. The shader is policy-free. The frozen Stalag prototype (tag
## prototype-final) supplied the 16 px tiles; tools/bake_ground.mjs bakes the atlas and the decals
## named below, and tools/bake_ground_fields.mjs bakes the two field images from a survey of the world.

## TASTE KNOB. Multiplies the mud albedo. The design lab's pond ring read close to black from a
## distance (tile mean luma 0.17); 1.3 lifts it to about 0.22, still dark and wet but readable. 1.0 is
## the lab as voted. One definition in the repository; the render check reads it from the material.
const GROUND_MUD_LIFT := 1.3

const ATLAS_TEXTURE := "res://game/world/assets/ground/atlas.png"
const DECALS_TEXTURE := "res://game/world/assets/ground/decals.png"
const FIELDS_TOP_TEXTURE := "res://game/world/assets/ground/fields_top.png"
const FIELDS_WALL_TEXTURE := "res://game/world/assets/ground/fields_wall.png"
const RULES_PATH := "res://game/world/assets/ground/rules.json"

## Per material id (the atlas rows: grass, dirt wall, rock, mossy rock, gravel, sand, mud, path, podzol):
## the share of 0.5 m squares that carry a decal, how many decal tiles the row holds, and the brightness
## range of the world tint. Grass takes its rate and range from grass_look.gd.
const DECAL_RATES := [0.12, 0.06, 0.06, 0.06, 0.09, 0.09, 0.09, 0.09, 0.09]
const DECAL_COUNTS := [8, 2, 3, 3, 3, 4, 3, 4, 4]
const TINT_AMPS := [0.70, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45]
## One metre is this many quanta of the field images: wall risers in eighths of a metre, water distance in tenths.
const RISER_PER_M := 8.0
const WATER_PER_M := 10.0


static func _rules() -> Dictionary:
	var f := FileAccess.open(RULES_PATH, FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	return d


## Hands one of the two ground materials (bucket 0 grass, 1 dirt) its art, its fields and its policy.
## `sun_position` is the sun's world position: the moss rule reads which way a rock face turns from it.
static func apply(mat: ShaderMaterial, bucket: int, sun_position: Vector3) -> void:
	var rules := _rules()
	var wall: Dictionary = rules["wall"]
	mat.set_shader_parameter("atlas", load(ATLAS_TEXTURE))
	mat.set_shader_parameter("ground_decals", load(DECALS_TEXTURE))
	mat.set_shader_parameter("fields_top", load(FIELDS_TOP_TEXTURE))
	mat.set_shader_parameter("fields_wall", load(FIELDS_WALL_TEXTURE))
	mat.set_shader_parameter("bucket", bucket)
	mat.set_shader_parameter("wall_rotate", false)
	mat.set_shader_parameter("mud_lift", GROUND_MUD_LIFT)
	mat.set_shader_parameter("sun_xz", Vector2(sun_position.x, sun_position.z))
	mat.set_shader_parameter("rock_drop_q", int(round(float(wall["rock_drop_m"]) * RISER_PER_M)))
	mat.set_shader_parameter("moss_water_q", int(round(float(wall["moss_water_m"]) * WATER_PER_M)))
	mat.set_shader_parameter("moss_shade", float(wall["moss_shade"]))
	mat.set_shader_parameter("mat_decal_rate", PackedFloat32Array(DECAL_RATES))
	mat.set_shader_parameter("mat_decal_count", PackedInt32Array(DECAL_COUNTS))
	mat.set_shader_parameter("mat_tint_amp", PackedFloat32Array(TINT_AMPS))


## The blocked-column bit array the engine's flora filter reads: 1 where the column's top material is
## one of rules.json "flora_blocked" (mud and sand), read from the SAME ids the shader draws.
static func flora_mask() -> PackedByteArray:
	var rules := _rules()
	var ids: Dictionary = rules["ids"]
	var blocked := {}
	for name in rules["flora_blocked"]:
		blocked[int(ids[name])] = true
	var img: Image = (load(FIELDS_TOP_TEXTURE) as Texture2D).get_image()
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var n := img.get_width() * img.get_height()
	var mask := PackedByteArray()
	mask.resize(n)
	for i in range(n):
		mask[i] = 1 if blocked.has(int(data[i * 4])) else 0
	return mask


## Gives the engine the mask before any chunk is built (the meadow and the understory are filtered
## after their placement, so the placement itself stays bit-equal to the prototype's).
static func install_flora_mask() -> void:
	var rules := _rules()
	StalagFlora.set_ground_mask(flora_mask(), int(rules["columns"]), int(rules["half"]))
