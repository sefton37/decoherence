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
// Lattice value in [0, 1) at an integer address, three coordinates mixed in turn.
float lattice_hash(ivec3 i) {
	uint h = lowbias32(uint(i.x));
	h = lowbias32(h ^ uint(i.y));
	h = lowbias32(h ^ uint(i.z));
	return float(h >> 8u) / 16777216.0;
}
float wf_vnoise3(vec3 x) {
	vec3 fl = floor(x);
	ivec3 i = ivec3(fl);
	vec3 f = x - fl;
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0); // quintic fade
	float n000 = lattice_hash(i + ivec3(0, 0, 0)), n100 = lattice_hash(i + ivec3(1, 0, 0));
	float n010 = lattice_hash(i + ivec3(0, 1, 0)), n110 = lattice_hash(i + ivec3(1, 1, 0));
	float n001 = lattice_hash(i + ivec3(0, 0, 1)), n101 = lattice_hash(i + ivec3(1, 0, 1));
	float n011 = lattice_hash(i + ivec3(0, 1, 1)), n111 = lattice_hash(i + ivec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}
float wf_fbm3(vec3 x) {
	float a = 0.0, amp = 0.5;
	for (int o = 0; o < 3; o++) {
		a += amp * (wf_vnoise3(x) * 2.0 - 1.0);
		x *= 2.0;
		amp *= 0.5;
	}
	return a;
}
float wf_psi(vec2 p, float tt, float th) {
	return 2.0 * (cos(th) * p.y - sin(th) * p.x) + 6.0 * wf_fbm3(vec3(p.x / 28.0, p.y / 28.0, tt));
}
// horizontal flow = curl of a streamfunction (divergence-free), the shape of horizontalCurl()
vec2 wf_curl(vec2 p, float t, float th) {
	float tt = t * 0.05, e = 0.5;
	float dpz = (wf_psi(vec2(p.x, p.y + e), tt, th) - wf_psi(vec2(p.x, p.y - e), tt, th)) / (2.0 * e);
	float dpx = (wf_psi(vec2(p.x + e, p.y), tt, th) - wf_psi(vec2(p.x - e, p.y), tt, th)) / (2.0 * e);
	return vec2(dpz, -dpx);
}

void vertex() {
	vec3 transformed = VERTEX;
	float hw = max(0.0, transformed.y); // metres above the pinned base: the root never slides
	vec2 ip = MODEL_MATRIX[3].xz; // per-plant world XZ
	vec2 cell = floor(ip * 1.7);
	float ph = float(lowbias32(lowbias32(uint(int(cell.x))) ^ uint(int(cell.y))) >> 8u) / 16777216.0 * 6.2831; // per-plant phase
	// windSample(ip, uTime): global field direction and strength
	float th = 0.6; // prevailing heading: the shader keeps the prototype's constant
	vec2 wdir0 = vec2(cos(th), sin(th));
	vec2 ax = ip - wdir0 * 2.0 * u_time;
	float gustg = 1.0 + 1.8 * smoothstep(0.55, 0.82, wf_vnoise3(vec3(ax / 45.0, u_time * 0.03)));
	vec2 h = wf_curl(ip, u_time, th) * gustg;
	float sp = length(h);
	vec2 wdir = sp > 1e-4 ? h / sp : wdir0;
	float wstr = strength_override >= 0.0 ? strength_override : clamp(sp / 6.0, 0.0, 1.0);
	float carrier = 0.62 * sin(u_time * 0.95 + ph) + 0.38 * sin(u_time * 0.60 + ph * 1.7); // breath
	float gust = 0.5 + 0.5 * sin(u_time * gust_w + dot(ip, gust_axis) * gust_k - ph); // gust wave
	float disp = hw * wind_amp * carrier * (0.30 + 0.70 * wstr * gust);
	float fdist = dot(ip, front_n) - front_off; // distance to the moving wall
	float fgain = 1.0 + 1.4 * front_pk * max(0.0, 1.0 - abs(fdist) / 28.0); // the front heaves the lean
	disp = clamp(disp * fgain, -hw * wind_amp * 2.4, hw * wind_amp * 2.4);
	transformed.xz += wdir * disp;
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
