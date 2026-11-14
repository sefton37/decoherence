// SPDX-License-Identifier: AGPL-3.0-only
// Spec 582 S1 -- the clear-air sky: a horizon-to-zenith gradient (the horizon colour holds from the horizon line
// down, so the fogged far ground and the sky meet in one colour), an optional sun glow and disc, and procedural
// clouds.
// Provenance: written for this project. The gradient follows tools/scenic/scenic_sky.gdshader and the engine's
// stalag_sky.gdshader (same project, same licence). The clouds are fractal value noise (a hash-based lattice
// noise summed over five octaves) on a flat cloud deck, lit by one offset sample toward the sun; no image, no
// texture and no third-party code is used.
shader_type sky;

uniform vec4 horizon_color : source_color = vec4(0.72, 0.83, 0.94, 1.0);
uniform vec4 zenith_color : source_color = vec4(0.2, 0.44, 0.84, 1.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.96, 0.86, 1.0);
uniform vec3 sun_dir = vec3(0.0, 0.8, 0.6); // unit vector toward the sun, world space
uniform float sun_size = 0.012; // disc angular radius, radians; 0 = no disc
uniform float glow_power = 18.0;
uniform float glow_strength = 0.12;
uniform float climb = 1.5; // how quickly the sky climbs from horizon to zenith colour
uniform float curve = 0.6;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.0; // 0 = no clouds at all
uniform float cloud_scale = 1.6;
uniform float cloud_time = 0.0; // the world feeds its own clock; a probe freezes it
uniform vec4 cloud_light : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 cloud_shade : source_color = vec4(0.62, 0.7, 0.82, 1.0);

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return s;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = clamp(d.y * climb, 0.0, 1.0);
	vec3 col = mix(horizon_color.rgb, zenith_color.rgb, pow(h, curve));
	float sd = max(dot(d, normalize(sun_dir)), 0.0);
	col += sun_color.rgb * pow(sd, glow_power) * glow_strength;
	if (sun_size > 0.0) {
		float disc = smoothstep(cos(sun_size * 1.4), cos(sun_size), sd);
		col = mix(col, sun_color.rgb * 1.6, disc);
	}
	if (cloud_cover > 0.0 && d.y > 0.0 && !AT_CUBEMAP_PASS) {
		vec2 p = d.xz / (d.y + 0.12) * cloud_scale + vec2(cloud_time, cloud_time * 0.37);
		float n = fbm(p);
		float dens = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.22, n);
		float n2 = fbm(p + normalize(sun_dir).xz * 0.18);
		float lit = clamp(0.62 + (n - n2) * 5.0, 0.0, 1.0);
		vec3 ccol = mix(cloud_shade.rgb, cloud_light.rgb, lit);
		float fade = smoothstep(0.0, 0.2, d.y);
		col = mix(col, ccol, dens * fade * 0.92);
	}
	COLOR = col;
}
