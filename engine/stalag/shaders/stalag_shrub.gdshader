// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- voxel-shrub shader: the cutout-leaf bushes of the frozen Stalag prototype (tag
// prototype-final: index.html makeWindyShrub over WIND_DISPLACE and SHRUB_FLUTTER), alpha scissor
// 0.45, double sided, nearest cutout texture, exp-squared fog as in stalag_flora.gdshader.
//
// Motion is a whole-bush lean (stalag_wind.gdshaderinc, amplitude 0.03) plus the per-cell twist of
// SHRUB_FLUTTER, deliberately smaller than the crown's: only the tumble, no front ripple, no
// turbulence, no shimmer. Cell amplitude 0.20, height gain min(1.2, 0.15 + 0.20 hw). The prototype's
// folk per-cluster hash is replaced by lowbias32 (Spec #517 A2).
//
// Per-vertex data as in stalag_leaf.gdshader: UV2 = the cell's centroid xz, CUSTOM0 = (heightFrac,
// exposure, cell y), COLOR = the baked brightness factor.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D cutout_tex : source_color, filter_nearest;
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform float wind_amp = 0.03; // whole-bush lean
uniform float cell_amp = 0.20; // per-cell twist amplitude
uniform float u_time = 0.0;
uniform vec2 gust_axis = vec2(0.8253356, 0.5646425);
uniform float gust_k = 0.20;
uniform float gust_w = 0.90;
uniform vec2 front_n = vec2(1.0, 0.0);
uniform float front_off = 0.0;
uniform float front_pk = 0.0;
uniform float strength_override = -1.0;
uniform float flutter_scale = 1.0; // 0: freeze the per-cell twist (negative control only)
uniform float alpha_solid = 0.0; // 1: ignore the cutout alpha (the probe's solid silhouette reference)

varying float v_depth;

#include "res://engine/stalag/shaders/stalag_wind.gdshaderinc" // the shared wind functions

float cell_seed(vec2 c) {
	return float(lowbias32(lowbias32(floatBitsToUint(c.x)) ^ floatBitsToUint(c.y)) >> 8u) / 16777216.0;
}

void vertex() {
	vec3 transformed = VERTEX;
	vec3 position = VERTEX;
	vec2 aCluster = UV2;
	float exposure = CUSTOM0.y;
	float aCellY = CUSTOM0.z;
	float hw = max(0.0, transformed.y);
	vec2 ip = MODEL_MATRIX[3].xz;

	transformed.xz += wf_lean(ip, hw, wind_amp, u_time, gust_axis, gust_k, gust_w, front_n, front_off, front_pk, strength_override);

	// ---- SHRUB_FLUTTER
	float height_gain = min(1.2, 0.15 + 0.20 * hw);
	vec2 cdir;
	float cstr = wf_sample(ip + aCluster, u_time, strength_override, cdir);
	float cseed = cell_seed(aCluster);
	float cph = cseed * 6.2831853;
	float crate = mix(0.85, 1.15, cseed);
	// T2/T3 per-cell flutter primary (Spec #368): per-cell rustle rate, 0.173 Hz
	float flutter_a = sin(u_time * 0.943 * crate + cph);
	// T2/T3 per-cell flutter secondary beat (Spec #368): erratic beat term, 0.116 Hz
	float flutter_b = sin(u_time * 0.773 * crate * 0.82 + cph * 1.3);
	float flutter = 0.6 * flutter_a + 0.4 * flutter_b;
	// T2/T3 per-cell gust swell floor (Spec #368): ambient gust-strength envelope, period 7.8s, 0.128 Hz
	float cell_gust_swell = 0.5 + 0.5 * sin(u_time * 0.806 + cph * 0.5);
	float gust_floor = 0.25 + 0.75 * cstr * (0.6 + 0.4 * cell_gust_swell);
	float lamp = cell_amp * flutter_scale * exposure * gust_floor * height_gain;

	vec3 cell_ctr = vec3(aCluster.x, aCellY, aCluster.y);
	vec3 rel = position - cell_ctr;
	float ax_seed = fract(cseed * 53.73 + aCellY * 0.913);
	vec3 tumble_axis = normalize(vec3(sin(ax_seed * 6.2831853) + 0.15, 0.45 + 0.5 * fract(ax_seed * 3.71), cos(ax_seed * 6.2831853) + 0.15));
	float tumble_angle = 3.6 * flutter * lamp;
	float tca = cos(tumble_angle), tsa = sin(tumble_angle);
	vec3 tumbled = rel * tca + cross(tumble_axis, rel) * tsa + tumble_axis * dot(tumble_axis, rel) * (1.0 - tca);
	transformed += (tumbled - rel);

	VERTEX = transformed;
	v_depth = -(MODELVIEW_MATRIX * vec4(transformed, 1.0)).z;
}

void fragment() {
	vec4 s = texture(cutout_tex, UV);
	ALPHA = alpha_solid > 0.5 ? 1.0 : s.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	float d = fog_density * v_depth;
	float f = 1.0 - clamp(exp(-d * d), 0.0, 1.0);
	ALBEDO = s.rgb * COLOR.rgb * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
