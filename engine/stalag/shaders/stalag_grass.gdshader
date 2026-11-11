// SPDX-License-Identifier: AGPL-3.0-only
// Spec #551 phases 1 and 2 -- the ground. The terrain skin of stalag_terrain.gdshader (the
// prototype's nearest-filtered 16 px tile, world-space planar UVs from the engine, one tile
// per 0.5 m, tag prototype-final) with the layers that break the stamped-grid look:
//   A. each 0.5 m square picks one of eight tile variants by a position hash and turns or mirrors
//      it (tops: one of the eight square symmetries; walls: a mirror only, so strata stay level);
//   B. a world-space brightness and dryness tint, snapped to the 1/32 m texel grid and quantised
//      with an ordered dither, so it stays pixel art;
//   D. sparse decals (clover, flower specks, dirt, pebbles, straw, lichen, shells ...) on a share
//      of the squares.
// Phase 2 adds the material: grass, dirt wall, rock, mossy rock, gravel, sand, mud (path and
// podzol have atlas rows already, nothing draws them yet). The top material of a column is an id baked
// into fields_top.png (tools/bake_ground_fields.mjs; the flora filter reads the same ids); the wall
// material is rock for a riser of a metre or more, mossy rock when that face is damp (near water) or
// turned away from the sun, otherwise dirt. Both mesh buckets use this shader (uniform `bucket`).
// The art comes from tools/bake_grass.mjs and tools/bake_ground.mjs; the policy (strengths, rates,
// thresholds) lives in game/world/grass_look.gd and game/world/ground_look.gd. The terrain shader
// stays untouched as the old look and the A/B baseline. Fog is the prototype's exp-squared term, as
// there, because the world's built-in fog is off.
//
// Everything is a whole-texel fetch. The square and the texel come from ONE integer texel
// coordinate, so a square boundary can never mix the neighbour's variant with this square's texel.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// The shipped single tile; variant 0 of the strip equals it, and the S1 look probe reads it from here.
uniform sampler2D tile : source_color, filter_nearest, repeat_enable;
uniform sampler2D variants : source_color, filter_nearest; // 8 grass tiles of 16 x 16 side by side
uniform sampler2D decals : source_color, filter_nearest; // 8 grass decals, alpha 0 or 255
uniform sampler2D atlas : source_color, filter_nearest; // 9 materials by 8 variants of 16 x 16 (row = material id)
uniform sampler2D ground_decals : source_color, filter_nearest; // the same layout, alpha 0 or 255
uniform sampler2D fields_top : filter_nearest; // R = top material id per 0.5 m column (448 x 448)
uniform sampler2D fields_wall : filter_nearest; // R = water distance in 0.1 m, G = riser in eighths of a metre
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform bool use_skin = true; // false: one flat colour (negative control)
uniform vec4 flat_color : source_color = vec4(0.30, 0.55, 0.22, 1.0);
uniform bool use_fog = true; // false: no fog term (negative control)

uniform int variant_count = 8; // 1: the old look through this shader (negative control)
uniform bool use_rotation = true; // false: no turning or mirroring
uniform float decal_rate = 0.0; // share of grass squares that carry a decal; policy sets it
uniform float tint_strength = 0.0; // 0: no tint; policy sets it
uniform float tint_swing = 0.70; // brightness range of the grass tint, before the strength
uniform float tint_step = 0.10; // brightness quantum; 0: continuous (negative control)
uniform vec3 dry_mul = vec3(1.32, 1.18, 0.55); // colour of the driest ground
uniform bool tint_snap = true; // false: sample the tint per pixel, not per texel (negative control)

uniform int bucket = 0; // 0: the engine's grass bucket (tops), 1: its dirt bucket (walls and low tops)
uniform bool wall_rotate = false; // true: walls turn like tops (negative control; strata would tilt)
uniform float mud_lift = 1.0; // multiplies the mud albedo; policy sets it (the pond ring read near black)
uniform vec2 sun_xz = vec2(80.0, 50.0); // horizontal direction toward the sun; policy sets it
uniform int rock_drop_q = 8; // riser (in eighths of a metre) at which a wall is rock
uniform int moss_water_q = 60; // water distance (0.1 m units) under which a rock face is damp
uniform float moss_shade = 0.35; // how far a rock face must turn from the sun to grow moss
uniform float mat_decal_rate[9]; // per material, share of squares that carry a decal (grass uses decal_rate)
uniform int mat_decal_count[9]; // per material, how many decal tiles its row holds
uniform float mat_tint_amp[9]; // per material, brightness range of the tint (grass uses tint_swing)

// 16 texels per tile and one tile per 0.5 m UV unit make 32 texels per metre: derived here,
// never typed as a second copy of the engine's scale.
const float TEXELS_PER_TILE = 16.0;
const float TILE_WORLD_M = 0.5;
const float TEXELS_PER_M = TEXELS_PER_TILE / TILE_WORLD_M;
const int TEXELS = 16;

// Field geometry: one texel per column of one tile, 448 columns, the origin 224 columns in.
const int FIELD_DIM = 448;
const int FIELD_ORIGIN = 224;
// Material ids = atlas rows.
const int M_GRASS = 0;
const int M_DIRT = 1;
const int M_ROCK = 2;
const int M_MOSS = 3;
const int M_MUD = 6;
// Chance, out of 65536, that a texel near a column edge takes the neighbouring column's material,
// by its distance in texels from that edge: the ragged, still pixel-hard material border.
const int EDGE_K[8] = int[8](32768, 20971, 11796, 5243, 0, 0, 0, 0);

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

// The top material of a world texel: the baked id of its column, except that a texel near a column
// edge may take the neighbouring column's id (one hash draw per axis), so borders are ragged by a
// few texels and never straight along the column grid.
int top_material(ivec2 wt) {
	ivec2 lt = wt & ivec2(15);
	ivec2 c = (wt - lt) / TEXELS;
	int ex = lt.x < 8 ? lt.x : 15 - lt.x;
	int ez = lt.y < 8 ? lt.y : 15 - lt.y;
	int sx = lt.x < 8 ? -1 : 1;
	int sz = lt.y < 8 ? -1 : 1;
	int tx = int(hcell(wt, 0u, 211u) & 0xffffu) < EDGE_K[ex] ? sx : 0;
	int tz = int(hcell(wt, 0u, 212u) & 0xffffu) < EDGE_K[ez] ? sz : 0;
	ivec2 fc = clamp(c + ivec2(tx, tz) + ivec2(FIELD_ORIGIN), ivec2(0), ivec2(FIELD_DIM - 1));
	return int(round(texelFetch(fields_top, fc, 0).r * 255.0));
}

void fragment() {
	vec3 base = flat_color.rgb;
	int mat_id = -1;
	vec3 geo_n = vec3(0.0, 1.0, 0.0);
	if (use_skin) {
		// Geometric face normal from the world position's screen derivatives, turned toward the
		// camera, quantised to a 6-bit key: every face orientation gets its own variant lattice.
		vec3 fn = normalize(cross(dFdx(v_wpos), dFdy(v_wpos)));
		if (dot(fn, CAMERA_POSITION_WORLD - v_wpos) < 0.0) fn = -fn;
		geo_n = fn;
		ivec3 q = ivec3(round(fn * 2.0)) + ivec3(3);
		uint key = uint(q.x) | (uint(q.y) << 3u) | (uint(q.z) << 6u);
		bool top = fn.y > 0.3;

		// One integer texel coordinate; floor-divide and mask, never % on a negative.
		ivec2 T = ivec2(floor(UV * TEXELS_PER_TILE));
		ivec2 tx = T & ivec2(TEXELS - 1);
		ivec2 cell = (T - tx) / TEXELS;

		// The surface coordinate of the tint and the edge picks: the world xz on tops, the distance along the
		// wall and the height on walls (the xz plane degenerates there).
		vec2 tn = normalize(vec2(-fn.z, fn.x) + vec2(0.00001));
		vec2 wsurf = top ? v_wpos.xz : vec2(dot(v_wpos.xz, tn), v_wpos.y);
		ivec2 W = ivec2(floor(wsurf * TEXELS_PER_M));

		// Which material this fragment wears.
		int mat = M_GRASS;
		if (top) {
			ivec2 wt = ivec2(floor((v_wpos.xz - fn.xz * 0.05) * TEXELS_PER_M));
			mat = top_material(wt);
			if (bucket == 1 && mat == M_GRASS) mat = M_DIRT;
		} else {
			// The facing is the dominant horizontal axis of the face normal, so the screen derivatives that bend the
			// normal along a face's edge pixels can never move the column read onto a neighbour.
			vec2 facing = abs(fn.x) >= abs(fn.z) ? vec2(sign(fn.x), 0.0) : vec2(0.0, sign(fn.z));
			ivec2 wc = ivec2(floor((v_wpos.xz - facing * 0.3) / TILE_WORLD_M)) + ivec2(FIELD_ORIGIN);
			vec4 wf = texelFetch(fields_wall, clamp(wc, ivec2(0), ivec2(FIELD_DIM - 1)), 0);
			int drop_q = int(round(wf.g * 255.0));
			int wd_q = int(round(wf.r * 255.0));
			mat = M_DIRT;
			if (drop_q >= rock_drop_q) {
				mat = M_ROCK;
				float shade = -dot(facing, normalize(sun_xz));
				if (wd_q < moss_water_q || shade > moss_shade) mat = M_MOSS;
			}
		}
		mat_id = mat;

		uint h = hcell(cell, key, 1u + uint(mat) * 17u);
		int v = int(h % uint(max(variant_count, 1)));
		ivec2 t = tx;
		if (top) {
			if (use_rotation) t = d4(tx, (h >> 8u) & 7u);
		} else if (wall_rotate) {
			t = d4(tx, (h >> 8u) & 7u);
		} else {
			// mirror only, and the image's top row is world up: strata stay level, light stays top-left
			t = ivec2(use_rotation && ((h >> 8u) & 1u) != 0u ? TEXELS - 1 - tx.x : tx.x, TEXELS - 1 - tx.y);
		}
		if (mat == M_GRASS) {
			// Variant 0 is the shipped tile itself, read from the bound `tile`; the strip holds the other seven.
			if (v == 0) {
				base = texelFetch(tile, t, 0).rgb;
			} else {
				base = texelFetch(variants, ivec2(v * TEXELS + t.x, t.y), 0).rgb;
			}
		} else {
			base = texelFetch(atlas, ivec2(v * TEXELS + t.x, mat * TEXELS + t.y), 0).rgb;
		}

		// D: decals on a share of the squares; alpha is 0 or 255, so it is a replace.
		uint h2 = hcell(cell, key, 7u + uint(mat) * 29u);
		float rate = mat == M_GRASS ? decal_rate : mat_decal_rate[mat];
		if (h01(h2) < rate) {
			int nd = mat == M_GRASS ? 8 : max(mat_decal_count[mat], 1);
			int di = int((h2 >> 16u) % uint(nd));
			ivec2 dt = top ? d4(tx, (h2 >> 20u) & 7u) : ivec2(tx.x, TEXELS - 1 - tx.y);
			vec4 dc = mat == M_GRASS ? texelFetch(decals, ivec2(di * TEXELS + dt.x, dt.y), 0) : texelFetch(ground_decals, ivec2(di * TEXELS + dt.x, mat * TEXELS + dt.y), 0);
			if (dc.a > 0.5) base = dc.rgb;
		}

		// B: the world-space tint on the texel grid, quantised with an ordered dither. The three salts
		// (117, 118, 119) pick one realisation of the noise out of many equally valid ones.
		if (tint_strength > 0.0) {
			vec2 wp = tint_snap ? vec2(W) / TEXELS_PER_M : wsurf;
			float n1 = 0.65 * vnoise(wp / 5.0, 117u) + 0.35 * vnoise(wp / 1.8, 118u);
			float n2 = vnoise(wp / 12.0 + 17.0, 119u);
			float r = bayer4(W);
			float swing = (mat == M_GRASS ? tint_swing : mat_tint_amp[mat]) * tint_strength;
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
			if (mat == M_GRASS) base = mix(base, base * dry_mul, dry_share * min(tint_strength, 1.0));
			base *= 1.0 + bright;
		}
		if (mat == M_MUD) base *= mud_lift;
	}
	float d = fog_density * v_depth;
	float f = use_fog ? 1.0 - clamp(exp(-d * d), 0.0, 1.0) : 0.0;
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
