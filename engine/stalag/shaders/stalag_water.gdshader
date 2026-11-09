// Spec #517 -- the water material, ported from the prototype's single water ShaderMaterial
// (index.html buildWaterChunk / waterMat): one translucent unlit material for still ponds,
// flowing courses and waterfalls. The mesher's vertex colour carries what three.js got in
// attributes: COLOR.rg = flow direction * 0.5 + 0.5, COLOR.b = depth band / 4. A column is
// STILL when the flow is zero, a COURSE when it is not, and a FALL when it is flowing and
// the face is a steep wall (normal.y near 0). Palette: cells.js WATER.depthTints and foam.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D flip_tex : source_color, filter_nearest, repeat_enable; // 8-frame 128x16 strip
uniform sampler2D flow_map : source_color, filter_nearest, repeat_enable; // 16x16 river noise
uniform vec4 tint1 : source_color = vec4(0.44, 0.70, 0.68, 1.0);
uniform vec4 tint2 : source_color = vec4(0.32, 0.55, 0.54, 1.0);
uniform vec4 tint3 : source_color = vec4(0.22, 0.41, 0.41, 1.0);
uniform vec4 tint4 : source_color = vec4(0.14, 0.29, 0.30, 1.0);
uniform vec4 foam : source_color = vec4(0.659, 0.769, 0.733, 1.0);
uniform vec4 w_hi : source_color = vec4(0.318, 0.510, 0.451, 1.0);
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform float water_alpha = 0.95;
uniform float depth_mix = 0.55;
uniform float advect = 0.9;
uniform float phase_rate = 0.33333334;
uniform float contrast = 1.9;
uniform bool use_fog = true;
uniform float pull = 0.9995; // pulls the water slightly toward the camera so it wins over the coincident terrain cap

varying vec3 v_world;
varying vec3 v_nrm;
varying vec2 v_flow;
varying float v_band;
varying float v_depth;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = NORMAL;
	v_flow = COLOR.rg * 2.0 - 1.0;
	v_band = COLOR.b * 4.0;
	vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	v_depth = -vp.z;
	vp.xyz *= pull;
	POSITION = PROJECTION_MATRIX * vp;
}

float m2(vec2 p) {
	return p.x < 0.5 ? (p.y < 0.5 ? 0.0 : 3.0) : (p.y < 0.5 ? 2.0 : 1.0);
}
float bayer4_still(vec2 fc) {
	vec2 p = floor(mod(fc, 4.0));
	return (4.0 * m2(mod(p, 2.0)) + m2(floor(p / 2.0))) / 16.0;
}
float bayer2(vec2 a) {
	vec2 p = mod(floor(a), 2.0);
	return p.y < 0.5 ? (p.x < 0.5 ? 0.00 : 0.50) : (p.x < 0.5 ? 0.75 : 0.25);
}
float bayer4(vec2 a) {
	return bayer2(0.5 * a) * 0.25 + bayer2(a);
}
vec2 snap16(vec2 uv) {
	return (floor(uv * 16.0) + 0.5) / 16.0;
}
// SPDX-License-Identifier: LicenseRef-PublicDomain
// lowbias32: Chris Wellons, "Prospecting for Hash Functions", https://nullprogram.com/blog/2018/07/31/ (public domain)
uint lowbias32(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}
// Per-cell pseudo-random number in [0, 1): the integer cell address and the salt k are mixed
// in turn through lowbias32; the top 24 bits are exactly representable as a float.
float hcell(vec2 c, float k) {
	uint h = lowbias32(uint(int(c.x)));
	h = lowbias32(h ^ uint(int(c.y)));
	h = lowbias32(h ^ uint(int(k)));
	return float(h >> 8u) / 16777216.0;
}

void fragment() {
	float t = TIME;
	vec3 col;
	bool is_flow = length(v_flow) > 0.001;
	bool is_fall = is_flow && abs(v_nrm.y) < 0.5;
	if (is_fall) {
		vec2 fdir = v_flow / max(length(v_flow), 1e-4);
		vec2 fperp = vec2(-fdir.y, fdir.x);
		float across = dot(v_world.xz, fperp);
		float col_id = floor(across / 0.25);
		float ffr = floor(hcell(vec2(col_id, 3.0), 1.0) * 7.999);
		float fv_off = floor(hcell(vec2(col_id, 5.0), 2.0) * 16.0) / 16.0;
		float tick = floor(t * 10.0);
		vec2 flt = vec2(fract(across / 0.25), fract(v_world.y / 1.2 + fv_off + tick / 16.0));
		float fg = texture(flip_tex, vec2((ffr + flt.x) / 8.0, flt.y)).r;
		col = fg < 0.7 ? tint2.rgb * 1.25 : (fg < 0.9 ? tint1.rgb * 1.15 : mix(tint1.rgb, foam.rgb, 0.75));
		float ch = hcell(vec2(floor(across * 32.0), floor(v_world.y * 32.0)), 13.0 + tick);
		if (ch > 0.88) col = foam.rgb;
	} else if (is_flow) {
		vec2 wxz = v_world.xz / 0.5;
		float spd = length(v_flow);
		vec2 dir = spd > 0.001 ? v_flow / spd : vec2(1.0, 0.0);
		vec2 perp = vec2(-dir.y, dir.x);
		vec2 fuv = vec2(dot(wxz, dir) * 0.40, dot(wxz, perp) * 1.35);
		float dn = texture(flow_map, snap16(wxz * 0.19)).r;
		float p0 = fract(t * phase_rate + dn);
		float p1 = fract(t * phase_rate + dn + 0.5);
		float w0 = 1.0 - abs(1.0 - 2.0 * p0);
		float adv = advect * spd;
		vec2 uv0 = snap16(fuv - vec2((p0 - 0.5) * adv, 0.0));
		vec2 uv1 = snap16(fuv - vec2((p1 - 0.5) * adv, 0.0) + vec2(0.5));
		float s = texture(flow_map, uv0).r * w0 + texture(flow_map, uv1).r * (1.0 - w0);
		float con = contrast * clamp(0.5 + 0.75 * spd, 0.6, 2.2);
		s = clamp((s - 0.5) * con + 0.5, 0.0, 1.0);
		float idx = clamp(floor(s * 4.0 + bayer4(FRAGCOORD.xy)), 0.0, 3.0);
		col = idx < 0.5 ? tint4.rgb : (idx < 1.5 ? tint3.rgb : (idx < 2.5 ? tint2.rgb : tint1.rgb));
		if (s > 0.97) col = w_hi.rgb;
		float along = floor(dot(wxz, dir) * 16.0) / 16.0;
		float lane = floor(dot(wxz, perp) * 8.0);
		float lh = hcell(vec2(lane, 11.0), 9.0);
		float d = fract(along * 0.5 - t * spd * 0.55 + lh * 3.7);
		if (lh > 0.55 && dn > 0.25) {
			if (d < 0.08) col = foam.rgb * 1.05;
			else if (d < 0.17) col = mix(col, foam.rgb, 0.6);
			else if (d < 0.26) col = mix(col, foam.rgb, 0.3);
		}
	} else {
		vec2 cell = floor(v_world.xz / 0.5);
		vec2 lt = fract(v_world.xz / 0.5);
		float fr = floor(hcell(cell, 1.0) * 7.999);
		float g = texture(flip_tex, vec2((fr + lt.x) / 8.0, lt.y)).r;
		vec3 tint_hard = v_band < 1.5 ? tint1.rgb : (v_band < 2.5 ? tint2.rgb : (v_band < 3.5 ? tint3.rgb : tint4.rgb));
		vec3 tint = mix(tint_hard, tint1.rgb, depth_mix);
		float patch_v = texture(flip_tex, vec2(fract(v_world.x / 4.0) / 8.0, fract(v_world.z / 4.0))).r;
		col = tint * (0.80 + 0.34 * g) * (0.95 + 0.10 * patch_v);
		float tx = floor(lt.x * 16.0);
		float tz = floor(lt.y * 16.0);
		float s0x = floor(hcell(cell, 2.0) * 15.999);
		float s0z = floor(hcell(cell, 3.0) * 15.999);
		float s1x = floor(hcell(cell, 4.0) * 15.999);
		float s1z = floor(hcell(cell, 5.0) * 15.999);
		bool on0 = fract(t / 60.0 + hcell(cell, 6.0)) < 0.12;
		bool on1 = hcell(cell, 8.0) > 0.5 && fract(t / 60.0 + hcell(cell, 7.0)) < 0.12;
		if (on0 && abs(tx - s0x) < 0.5 && abs(tz - s0z) < 0.5) col = foam.rgb * 1.06;
		if (on1 && abs(tx - s1x) < 0.5 && abs(tz - s1z) < 0.5) col = foam.rgb * 1.06;
		float bay = bayer4_still(FRAGCOORD.xy);
		col = floor(col * 12.0 + bay) / 12.0;
	}
	float d_f = fog_density * v_depth;
	float f = use_fog ? 1.0 - clamp(exp(-d_f * d_f), 0.0, 1.0) : 0.0;
	ALBEDO = mix(col, haze_color.rgb, f);
	ALPHA = water_alpha;
}
