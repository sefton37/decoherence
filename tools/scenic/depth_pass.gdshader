// SPDX-License-Identifier: AGPL-3.0-only
// Spec 582 S1 -- the horizon probe's depth pass: every surface of the world, re-drawn unshaded, writes its
// linear view distance (metres, 0 to range_m) into the 24 bits of the red, green and blue channels. The probe
// draws it against a background of pure white, which is the "no surface" code (the sky); a real surface never
// reaches it (the depth is clamped just under range_m). tools/scenic/post.py decodes the PNG it saves.
// The encoded value is converted from sRGB to linear first, because the renderer converts the frame back to sRGB
// on its way to the 8-bit target, and the probe checks the round trip against a known plane.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform float range_m = 4000.0;
// The far terrain's tree impostors are upright alpha-cut billboards (game/world/far_terrain.gdshader); the probe
// gives them a copy of this material with tree_pass on, so their depth has the same silhouette as their colour.
uniform bool tree_pass = false;
uniform sampler2D sprite_cone : source_color, filter_linear_mipmap;
uniform sampler2D sprite_round : source_color, filter_linear_mipmap;

varying float v_depth;
varying float v_kind;

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) / vec3(1.055), vec3(2.4)), c / vec3(12.92), lessThanEqual(c, vec3(0.04045)));
}

void vertex() {
	if (tree_pass) {
		vec3 right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
		vec3 back = normalize(vec3(INV_VIEW_MATRIX[2].x, 0.0, INV_VIEW_MATRIX[2].z));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0), MODEL_MATRIX[1], vec4(back * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
	}
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	v_kind = INSTANCE_CUSTOM.x;
}

void fragment() {
	if (tree_pass) {
		vec4 sp = v_kind > 0.5 ? texture(sprite_round, UV) : texture(sprite_cone, UV);
		if (sp.a < 0.5) {
			discard;
		}
	}
	float t = clamp(v_depth / range_m, 0.0, 0.99998);
	float v = floor(t * 16777215.0);
	float r = floor(v / 65536.0);
	float g = floor((v - r * 65536.0) / 256.0);
	float b = v - r * 65536.0 - g * 256.0;
	ALBEDO = srgb_to_linear(vec3(r, g, b) / 255.0);
}
