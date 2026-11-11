// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- the wind functions shared by the meadow, the crowns and the understory shaders,
// moved out of stalag_flora.gdshader (Spec #545) so every plant reads ONE source and a crown cannot
// drift off the grass's wind. Functions only (no uniforms: each shader owns its own).
//
// The sway is the prototype's WIND_DISPLACE (index.html) over its windSample (src/windfield.js
// WIND_GLSL), frozen Stalag prototype, tag prototype-final: a root-pinned, height-weighted lean =
// breath carrier x (0.30 floor + 0.70 x field strength x travelling gust wave), amplified near a
// passing weather front and clamped. The field shape (curl of an fbm streamfunction, gust gain)
// is the prototype's; its two unattributed folk hashes are replaced by lowbias32 (Spec #517 A2 /
// #545), so the GPU and CPU fields agree in SHAPE only, as windfield.js itself says of its mirror.

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
// windSample(p, t): global field direction (out) and strength. p_strength_override >= 0 forces the
// strength (the probe's calm and gale controls).
float wf_sample(vec2 p, float t, float p_strength_override, out vec2 wdir) {
	float th = 0.6; // prevailing heading: the shader keeps the prototype's constant
	vec2 wdir0 = vec2(cos(th), sin(th));
	vec2 ax = p - wdir0 * 2.0 * t;
	float gustg = 1.0 + 1.8 * smoothstep(0.55, 0.82, wf_vnoise3(vec3(ax / 45.0, t * 0.03)));
	vec2 h = wf_curl(p, t, th) * gustg;
	float sp = length(h);
	wdir = sp > 1e-4 ? h / sp : wdir0;
	return p_strength_override >= 0.0 ? p_strength_override : clamp(sp / 6.0, 0.0, 1.0);
}
// per-plant phase from the root's world XZ
float wf_phase(vec2 ip) {
	vec2 cell = floor(ip * 1.7);
	return float(lowbias32(lowbias32(uint(int(cell.x))) ^ uint(int(cell.y))) >> 8u) / 16777216.0 * 6.2831;
}
// WIND_DISPLACE: the whole-plant lean at height hw above the pinned root, as an XZ displacement.
vec2 wf_lean(vec2 ip, float hw, float amp, float t, vec2 p_gust_axis, float p_gust_k, float p_gust_w,
		vec2 p_front_n, float p_front_off, float p_front_pk, float p_strength_override) {
	float ph = wf_phase(ip);
	vec2 wdir;
	float wstr = wf_sample(ip, t, p_strength_override, wdir);
	float carrier = 0.62 * sin(t * 0.95 + ph) + 0.38 * sin(t * 0.60 + ph * 1.7); // breath
	float gust = 0.5 + 0.5 * sin(t * p_gust_w + dot(ip, p_gust_axis) * p_gust_k - ph); // gust wave
	float disp = hw * amp * carrier * (0.30 + 0.70 * wstr * gust);
	float fdist = dot(ip, p_front_n) - p_front_off; // distance to the moving wall
	float fgain = 1.0 + 1.4 * p_front_pk * max(0.0, 1.0 - abs(fdist) / 28.0); // the front heaves the lean
	disp = clamp(disp * fgain, -hw * amp * 2.4, hw * amp * 2.4);
	return wdir * disp;
}
