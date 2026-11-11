// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545 -- billboard flora shader: the cross-billboard plants of the frozen Stalag prototype
// (tag prototype-final), their wind sway and the exp-squared fog of the rest of the world.
//
// The sway is the prototype's WIND_DISPLACE (index.html) over its windSample (src/windfield.js
// WIND_GLSL): a root-pinned, height-weighted lean = breath carrier x (0.30 floor + 0.70 x field
// strength x travelling gust wave), amplified near a passing weather front and clamped. The field
// shape (curl of an fbm streamfunction, gust gain, 1/7 boundary layer, front gain) is the
// prototype's; its two unattributed folk hashes are replaced by lowbias32 (Spec #517 A2 / #545),
// so the GPU and CPU fields agree in SHAPE only, as windfield.js itself says of its mirror.
// The per-plant world position is the full MODEL_MATRIX (chunk node plus instance transform).
//
// Fog is folded into the lit result as in stalag_terrain.gdshader: mix(lit, haze, f).
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D sprite : source_color, filter_nearest;
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform float wind_amp = 0.06; // 0.06 grass and cover, 0.03 fern and shrub (index.html makeWindy)
uniform float u_time = 0.0; // the single shared clock; held still, the meadow freezes
uniform vec2 gust_axis = vec2(0.8253356, 0.5646425); // (cos 0.6, sin 0.6): the gust rolls downwind
uniform float gust_k = 0.20; // rad per metre
uniform float gust_w = 0.90; // rad per second
uniform vec2 front_n = vec2(1.0, 0.0); // weather-front wall normal, world XZ
uniform float front_off = 0.0; // signed offset of the moving wall
uniform float front_pk = 0.0; // front peak 0..1 (0 = no front)
uniform bool flip_v = false; // true: sample the sprite upside down (negative control only)
uniform float strength_override = -1.0; // >= 0 forces the field strength (probe calm and gale)

varying float v_depth;

#include "res://engine/stalag/shaders/stalag_wind.gdshaderinc" // the wind functions, shared with the crowns and the understory (Spec #549)

void vertex() {
	vec3 transformed = VERTEX;
	float hw = max(0.0, transformed.y); // metres above the pinned base: the root never slides
	vec2 ip = MODEL_MATRIX[3].xz; // per-plant world XZ
	transformed.xz += wf_lean(ip, hw, wind_amp, u_time, gust_axis, gust_k, gust_w, front_n, front_off, front_pk, strength_override);
	VERTEX = transformed;
	v_depth = -(MODELVIEW_MATRIX * vec4(transformed, 1.0)).z;
}

void fragment() {
	vec4 s = texture(sprite, flip_v ? vec2(UV.x, 1.0 - UV.y) : UV);
	ALPHA = s.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	float d = fog_density * v_depth;
	float f = 1.0 - clamp(exp(-d * d), 0.0, 1.0);
	ALBEDO = s.rgb * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	// Up-pointing normals on both faces (index.html billboardGeometry): the lit hemisphere either way.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = 1.0;
}
