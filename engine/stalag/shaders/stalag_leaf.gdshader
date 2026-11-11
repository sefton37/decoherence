// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- tree crown shader: the cutout-leaf crowns of the frozen Stalag prototype (tag
// prototype-final: index.html makeWindyCrown over WIND_DISPLACE and LEAF_FLUTTER), alpha scissor
// 0.45, double sided, nearest leaf texture, exp-squared fog as in stalag_flora.gdshader.
//
// Motion is two layers: the whole-crown lean (stalag_wind.gdshaderinc, amplitude 0.045) and the
// per-leaf-cell flutter of LEAF_FLUTTER: every cell tumbles about its own centroid at its own slow
// rate (rate band 0.85 to 1.15, top rate u_leaf_w * 1.15 / 2 pi = 0.256 Hz, under the 0.35 Hz charter
// ceiling: gusts grow the AMPLITUDE only), a travelling-front ripple along the gust axis, a gust
// tumble localized to the front band, and a small vertical shimmer. The shape and every constant
// are the prototype's; its two folk GLSL hashes (the per-cluster seed and the sub-crown turbulence)
// are replaced by lowbias32 (Spec #517 A2), so the fields differ in detail, not in character.
//
// Per-vertex data (tools/bake_trees.mjs): UV2 = the cell's centroid xz (aCluster), CUSTOM0 =
// (heightFrac, exposure, cell y centroid), COLOR = the baked light/brightness factor.
shader_type spatial;
// Crowns receive no shadows (prototype parity, and no self-darkening under the shadow proxies).
render_mode cull_disabled, diffuse_lambert, specular_disabled, shadows_disabled;

uniform sampler2D leaf_tex : source_color, filter_nearest;
uniform vec4 tint = vec4(1.0, 1.0, 1.0, 1.0); // per-species hueDegToColor: raw linear values, as the prototype passes them
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform float wind_amp = 0.045; // whole-crown lean (makeWindyCrown amp)
uniform float u_time = 0.0; // the single shared clock
uniform vec2 gust_axis = vec2(0.8253356, 0.5646425); // (cos 0.6, sin 0.6): the gust rolls downwind
uniform float gust_k = 0.20; // rad per metre
uniform float gust_w = 0.90; // rad per second
uniform vec2 front_n = vec2(1.0, 0.0);
uniform float front_off = 0.0;
uniform float front_pk = 0.0;
uniform float strength_override = -1.0; // >= 0 forces the field strength (probe calm and gale)
// LEAF_FLUTTER constants (windUniforms in index.html)
uniform float u_leaf_amp = 0.18; // per-cluster flutter amplitude
uniform float u_leaf_w = 1.4; // flutter angular rate, rad/s
uniform float u_leaf_front_k = 0.7; // rad per metre along the gust axis
uniform float u_leaf_front_speed = 0.8; // rad per second
uniform float u_leaf_front_amp = 4.4;
uniform float u_leaf_turb_amp = 0.35;
uniform float u_leaf_turb_freq = 2.4;
uniform float u_leaf_shimmer = 0.35; // vertical shimmer, metres per unit of flutter amplitude (the probe isolates the tumble with 0)
uniform float alpha_solid = 0.0; // 1: ignore the leaf alpha (negative control only)
uniform float tint_flat = 0.0; // 1: ignore tint and instance colour (negative control only)

varying float v_depth;

#include "res://engine/stalag/shaders/stalag_wind.gdshaderinc" // the shared wind functions

// hash of a float pair by its bit patterns (lowbias32, in place of the prototype's folk sin hash)
float cell_seed(vec2 c) {
	return float(lowbias32(lowbias32(floatBitsToUint(c.x)) ^ floatBitsToUint(c.y)) >> 8u) / 16777216.0;
}

void vertex() {
	vec3 transformed = VERTEX;
	vec3 position = VERTEX;
	vec2 aCluster = UV2;
	float exposure = CUSTOM0.y;
	float aCellY = CUSTOM0.z;
	float hw = max(0.0, transformed.y); // metres above the pinned base (root never slides)
	vec2 ip = MODEL_MATRIX[3].xz; // per-tree world XZ

	// whole-crown lean (WIND_DISPLACE)
	transformed.xz += wf_lean(ip, hw, wind_amp, u_time, gust_axis, gust_k, gust_w, front_n, front_off, front_pk, strength_override);

	// ---- LEAF_FLUTTER: every term offsets its sample by THIS cell's centroid
	const float LEAF_CRATE_MIN = 0.85;
	const float LEAF_CRATE_MAX = 1.15;
	vec2 lwdir;
	float lwstr = wf_sample(ip + aCluster, u_time, strength_override, lwdir);
	float lseed = cell_seed(aCluster);
	float lph = lseed * 6.2831; // per-cell phase
	float crate = mix(LEAF_CRATE_MIN, LEAF_CRATE_MAX, lseed); // per-cell RATE
	// two near-equal low frequencies beat against each other: a slow, erratic rustle
	float flutter = 0.6 * sin(u_time * u_leaf_w * crate + lph) + 0.4 * sin(u_time * u_leaf_w * crate * 0.82 + lph * 1.3);
	float gust_floor = 0.25 + 0.75 * lwstr; // gusts grow AMPLITUDE only (charter)

	// TRAVELING-FRONT: a slow crest sweeps across the crown along the gust axis
	float front_proj = dot(ip + aCluster, gust_axis);
	float front_wave = sin(u_leaf_front_k * front_proj - u_time * u_leaf_front_speed);

	// SUB-CROWN TURBULENCE: a fine spatial gain, no new time content
	vec2 tq = floor((ip + aCluster) * u_leaf_turb_freq);
	float turb_n = float(lowbias32(lowbias32(uint(int(tq.x))) ^ uint(int(tq.y))) >> 8u) / 16777216.0;
	float turb_gain = 1.0 - u_leaf_turb_amp * 0.5 + u_leaf_turb_amp * turb_n;

	// HEIGHT-SCALE: flutter amplitude grows with height above the pinned root
	float height_gain = min(4.0, 0.15 + 2.7 * pow(hw / 8.0, 2.5));

	float lamp = u_leaf_amp * exposure * gust_floor * height_gain * turb_gain;
	float front_disp = u_leaf_amp * u_leaf_front_amp * gust_floor * height_gain * (0.4 + 0.6 * front_pk) * front_wave;

	// PER-CELL TUMBLE FLOOR: rotation about this cell's own 3D centroid
	vec3 cell_ctr = vec3(aCluster.x, aCellY, aCluster.y);
	vec3 rel = position - cell_ctr;
	float ax_seed = fract(lseed * 53.73 + aCellY * 0.913);
	vec3 tumble_axis = normalize(vec3(sin(ax_seed * 6.2831) + 0.15, 0.45 + 0.5 * fract(ax_seed * 3.71), cos(ax_seed * 6.2831) + 0.15));
	float floor_angle = 4.2 * flutter * lamp;

	// GUST TUMBLE: extra amplitude and a downwind bias, localized to the travelling front band
	float gust_band = front_pk * (0.5 + 0.5 * front_wave);
	float gust_angle = 3.6 * lamp * gust_band * sin(u_time * u_leaf_w * crate + lph * 1.6 + aCellY * 0.25);
	vec3 downwind_axis = normalize(vec3(gust_axis.x, 0.2, gust_axis.y));
	tumble_axis = normalize(mix(tumble_axis, downwind_axis, min(1.0, gust_band)));

	float tumble_angle = floor_angle + gust_angle; // Rodrigues rotation of rel about tumble_axis
	float tca = cos(tumble_angle), tsa = sin(tumble_angle);
	vec3 tumbled = rel * tca + cross(tumble_axis, rel) * tsa + tumble_axis * dot(tumble_axis, rel) * (1.0 - tca);
	transformed += (tumbled - rel);

	transformed.xz += gust_axis * front_disp; // coherent travelling-front ripple, along the wind axis
	transformed.y += u_leaf_shimmer * lamp * sin(u_time * u_leaf_w * crate * 0.6 + lph * 0.7); // small vertical shimmer

	VERTEX = transformed;
	v_depth = -(MODELVIEW_MATRIX * vec4(transformed, 1.0)).z;
}

void fragment() {
	vec4 s = texture(leaf_tex, UV);
	ALPHA = alpha_solid > 0.5 ? 1.0 : s.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	vec3 base = tint_flat > 0.5 ? s.rgb : s.rgb * tint.rgb * COLOR.rgb;
	float d = fog_density * v_depth;
	float f = 1.0 - clamp(exp(-d * d), 0.0, 1.0);
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
