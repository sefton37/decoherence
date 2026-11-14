// SPDX-License-Identifier: AGPL-3.0-only
// Spec 582 S1 -- the far terrain's one shader: vertex or instance colour, an optional procedural tree sprite
// (an upright billboard; the sprite's alpha cuts the silhouette, the instance's custom x picks the cone or the round
// crown) and the
// world's exp-squared fog, with one addition: beyond fade_start (metres from fade_center, Chebyshev) the fog is
// forced up to the full haze colour by fade_end, so the last ring of tiles melts into the haze that the flat
// skirt beyond it is painted with. Each level of tiles shows only inside its own window (clip_out) and outside
// the window of the finer level (clip_in), so two levels never overlap and never z-fight.
// Provenance: written for this project. The lit-colour-plus-haze-as-emission fog follows
// game/world/backdrop.gdshader (Spec 580 S4) and engine/stalag/shaders/stalag_terrain.gdshader (same project,
// same licence); the clip and fade parts are new.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

uniform sampler2D sprite_cone : source_color, filter_linear_mipmap;
uniform sampler2D sprite_round : source_color, filter_linear_mipmap;
uniform bool use_sprite = false;
uniform vec4 haze_color : source_color = vec4(0.62, 0.75, 0.87, 1.0);
uniform float fog_density = 0.0014;
uniform vec2 fade_center = vec2(0.0, 0.0);
uniform float fade_start = 600.0;
uniform float fade_end = 840.0;
uniform vec4 clip_in = vec4(0.0, 0.0, 0.0, 0.0); // xmin, zmin, xmax, zmax: nothing is drawn inside it
uniform vec4 clip_out = vec4(-1.0e9, -1.0e9, 1.0e9, 1.0e9); // nothing is drawn outside it

varying float v_depth;
varying vec2 v_world;
varying float v_kind;

void vertex() {
	if (use_sprite) {
		// an upright billboard: the quad turns about its own vertical axis to face the camera (the instance's
		// scale along x and z is kept)
		vec3 right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
		vec3 back = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0), MODEL_MATRIX[1], vec4(back * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
		v_world = MODEL_MATRIX[3].xz;
	} else {
		v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	}
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	v_kind = INSTANCE_CUSTOM.x;
}

void fragment() {
	if (v_world.x > clip_in.x && v_world.x < clip_in.z && v_world.y > clip_in.y && v_world.y < clip_in.w) {
		discard;
	}
	if (v_world.x < clip_out.x || v_world.x > clip_out.z || v_world.y < clip_out.y || v_world.y > clip_out.w) {
		discard;
	}
	vec3 base = COLOR.rgb;
	if (use_sprite) {
		vec4 s = v_kind > 0.5 ? texture(sprite_round, UV) : texture(sprite_cone, UV);
		ALPHA = s.a;
		ALPHA_SCISSOR_THRESHOLD = 0.5;
		base *= s.rgb * mix(0.55, 1.0, 1.0 - UV.y); // darker at the foot of a crown: a little volume
	}
	float d = fog_density * v_depth;
	float f = 1.0 - clamp(exp(-d * d), 0.0, 1.0);
	vec2 q = abs(v_world - fade_center);
	f = max(f, smoothstep(fade_start, fade_end, max(q.x, q.y)));
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
