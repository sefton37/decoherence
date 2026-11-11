// SPDX-License-Identifier: AGPL-3.0-only
// Spec #551 phase 1 -- the meadow ground. The terrain skin of stalag_terrain.gdshader (the
// prototype's nearest-filtered 16 px grass tile, world-space planar UVs from the engine, one tile
// per 0.5 m, tag prototype-final) with three layers that break the stamped-grid look:
//   A. each 0.5 m square picks one of eight tile variants by a position hash and turns or mirrors
//      it (one of the eight square symmetries);
//   B. a world-space brightness and dryness tint, snapped to the 1/32 m texel grid and quantised
//      with an ordered dither, so it stays pixel art;
//   D. sparse decals (clover, flower specks, dirt, pebbles, straw) on a share of the squares.
// The art comes from tools/bake_grass.mjs; the policy (tint strength, decal rate) lives in
// game/world/grass_look.gd. The terrain shader stays untouched as the old look and the A/B
// baseline. Fog is the prototype's exp-squared term, as there, because the world's built-in fog is off.
//
// Everything is texelFetch on whole texels. The square and the texel come from ONE integer texel
// coordinate, so a square boundary can never mix the neighbour's variant with this square's texel.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// The shipped single tile; variant 0 of the strip equals it, and the S1 look probe reads it from here.
uniform sampler2D tile : source_color, filter_nearest, repeat_enable;
uniform sampler2D variants : source_color, filter_nearest; // 8 tiles of 16 x 16 side by side
uniform sampler2D decals : source_color, filter_nearest; // 8 tiles, alpha 0 or 255
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform bool use_skin = true; // false: one flat colour (negative control)
uniform vec4 flat_color : source_color = vec4(0.30, 0.55, 0.22, 1.0);
uniform bool use_fog = true; // false: no fog term (negative control)

uniform int variant_count = 8; // 1: the old look through this shader (negative control)
uniform bool use_rotation = true; // false: no turning or mirroring
uniform float decal_rate = 0.0; // share of squares that carry a decal; policy sets it
uniform float tint_strength = 0.0; // 0: no tint; policy sets it
uniform float tint_swing = 0.70; // brightness range of the tint, before the strength
uniform float tint_step = 0.10; // brightness quantum; 0: continuous (negative control)
uniform vec3 dry_mul = vec3(1.32, 1.18, 0.55); // colour of the driest ground
uniform bool tint_snap = true; // false: sample the tint per pixel, not per texel (negative control)

// 16 texels per tile and one tile per 0.5 m UV unit make 32 texels per metre: derived here,
// never typed as a second copy of the engine's scale.
const float TEXELS_PER_TILE = 16.0;
const float TILE_WORLD_M = 0.5;
const float TEXELS_PER_M = TEXELS_PER_TILE / TILE_WORLD_M;
const int TEXELS = 16;

varying float v_depth;
varying vec3 v_wpos;

void vertex() {
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
// Hash of a 2D integer address, a 6-bit key and a salt, mixed in turn through lowbias32.
uint hcell(ivec2 c, uint key, uint salt) {
	uint h = lowbias32(uint(c.x));
	h = lowbias32(h ^ uint(c.y));
	h = lowbias32(h ^ key);
	return lowbias32(h ^ salt);
}
float h01(uint h) {
	return float(h & 0xffffu) / 65535.0;
}

// The eight symmetries of the square that map texel centres onto texel centres:
// bit 0 transposes, bit 1 flips x, bit 2 flips y.
ivec2 d4(ivec2 t, uint r) {
	if ((r & 1u) != 0u) t = t.yx;
	if ((r & 2u) != 0u) t.x = TEXELS - 1 - t.x;
	if ((r & 4u) != 0u) t.y = TEXELS - 1 - t.y;
	return t;
}

// Smooth value noise over integer lattice points, hashed per lattice point.
float vnoise(vec2 p, uint salt) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 s = f * f * (3.0 - 2.0 * f);
	ivec2 c = ivec2(i);
	float a = h01(hcell(c, 0u, salt));
	float b = h01(hcell(c + ivec2(1, 0), 0u, salt));
	float d = h01(hcell(c + ivec2(0, 1), 0u, salt));
	float e = h01(hcell(c + ivec2(1, 1), 0u, salt));
	return mix(mix(a, b, s.x), mix(d, e, s.x), s.y);
}

// 4 x 4 ordered-dither threshold in (0, 1).
float bayer4(ivec2 p) {
	int x = p.x & 3;
	int y = p.y & 3;
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[y * 4 + x]) + 0.5) / 16.0;
}

void fragment() {
	vec3 base;
	if (use_skin) {
		// Geometric face normal from the world position's screen derivatives, turned toward the
		// camera, quantised to a 6-bit key: every face orientation gets its own variant lattice.
		vec3 fn = normalize(cross(dFdx(v_wpos), dFdy(v_wpos)));
		if (dot(fn, CAMERA_POSITION_WORLD - v_wpos) < 0.0) fn = -fn;
		ivec3 q = ivec3(round(fn * 2.0)) + ivec3(3);
		uint key = uint(q.x) | (uint(q.y) << 3u) | (uint(q.z) << 6u);

		// One integer texel coordinate; floor-divide and mask, never % on a negative.
		ivec2 T = ivec2(floor(UV * TEXELS_PER_TILE));
		ivec2 tx = T & ivec2(TEXELS - 1);
		ivec2 cell = (T - tx) / TEXELS;

		uint h = hcell(cell, key, 1u);
		int v = int(h % uint(max(variant_count, 1)));
		ivec2 t = use_rotation ? d4(tx, (h >> 8u) & 7u) : tx;
		// Variant 0 is the shipped tile itself, read from the bound `tile`; the strip holds the other seven.
		if (v == 0) {
			base = texelFetch(tile, t, 0).rgb;
		} else {
			base = texelFetch(variants, ivec2(v * TEXELS + t.x, t.y), 0).rgb;
		}

		// D: decals on a share of the squares; alpha is 0 or 255, so it is a replace.
		uint h2 = hcell(cell, key, 7u);
		if (h01(h2) < decal_rate) {
			int di = int((h2 >> 16u) % 8u);
			ivec2 dt = d4(tx, (h2 >> 20u) & 7u);
			vec4 dc = texelFetch(decals, ivec2(di * TEXELS + dt.x, dt.y), 0);
			if (dc.a > 0.5) base = dc.rgb;
		}

		// B: the world-space tint on the texel grid, quantised with an ordered dither. The three salts
		// (117, 118, 119) pick one realisation of the noise out of many equally valid ones.
		if (tint_strength > 0.0) {
			ivec2 W = ivec2(floor(v_wpos.xz * TEXELS_PER_M));
			vec2 wp = tint_snap ? vec2(W) / TEXELS_PER_M : v_wpos.xz;
			float n1 = 0.65 * vnoise(wp / 5.0, 117u) + 0.35 * vnoise(wp / 1.8, 118u);
			float n2 = vnoise(wp / 12.0 + 17.0, 119u);
			float r = bayer4(W);
			float swing = tint_swing * tint_strength;
			float dry_t = smoothstep(0.35, 0.70, n2);
			float bright;
			float dry_share;
			if (tint_step > 0.0) {
				bright = floor((n1 - 0.5) * swing / tint_step + r) * tint_step;
				dry_share = floor(dry_t * 3.0 + r) / 3.0;
			} else {
				bright = (n1 - 0.5) * swing;
				dry_share = dry_t;
			}
			base = mix(base, base * dry_mul, dry_share * min(tint_strength, 1.0)) * (1.0 + bright);
		}
	} else {
		base = flat_color.rgb;
	}
	float d = fog_density * v_depth;
	float f = use_fog ? 1.0 - clamp(exp(-d * d), 0.0, 1.0) : 0.0;
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
