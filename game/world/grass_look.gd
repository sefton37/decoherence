extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #551 phase 1 -- game policy for the meadow ground: which art the grass shader draws, and
## how strongly. The shader (engine/stalag/shaders/stalag_grass.gdshader) is policy-free; the
## frozen Stalag prototype (tag prototype-final) supplied the 16 px tile it varies, and
## tools/bake_grass.mjs bakes the two strips named below.

## TASTE KNOB. How strongly the large-scale world tint swings the meadow between lush and dry:
## it scales both the brightness swing (up to +/-30 percent at 1.0) and the share of dry-yellow
## ground. 1.0 is the look that was voted. If the dry end reads too yellow on a walk, 0.7 is the
## first thing to try. 0.0 switches the tint off.
const GRASS_TINT_STRENGTH := 1.0
## Share of 0.5 m squares that carry a decal (clover, flower specks, bare dirt, pebbles, straw).
const GRASS_DECAL_RATE := 0.12
## Brightness quantum of the tint, in albedo units. The tint stays a few discrete steps, never a gradient.
const GRASS_TINT_STEP := 0.10
## Brightness range of the tint at strength 1.0 (0.70 is +/-0.35, softened by the dither to about +/-30 percent).
const GRASS_TINT_SWING := 0.70
## Colour multiplier of the driest ground.
const GRASS_DRY_MULTIPLIER := Vector3(1.32, 1.18, 0.55)
## How many tile variants the strip holds, and the strips themselves.
const GRASS_VARIANT_COUNT := 8
const GRASS_VARIANTS_TEXTURE := "res://game/world/assets/grass_variants.png"
const GRASS_DECALS_TEXTURE := "res://game/world/assets/grass_decals.png"


## Hands the grass material its art and its policy. The shipped single tile stays bound by the caller.
static func apply(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("variants", load(GRASS_VARIANTS_TEXTURE))
	mat.set_shader_parameter("decals", load(GRASS_DECALS_TEXTURE))
	mat.set_shader_parameter("variant_count", GRASS_VARIANT_COUNT)
	mat.set_shader_parameter("use_rotation", true)
	mat.set_shader_parameter("decal_rate", GRASS_DECAL_RATE)
	mat.set_shader_parameter("tint_strength", GRASS_TINT_STRENGTH)
	mat.set_shader_parameter("tint_swing", GRASS_TINT_SWING)
	mat.set_shader_parameter("tint_step", GRASS_TINT_STEP)
	mat.set_shader_parameter("dry_mul", GRASS_DRY_MULTIPLIER)
	mat.set_shader_parameter("tint_snap", true)
