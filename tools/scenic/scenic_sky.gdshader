// SPDX-License-Identifier: AGPL-3.0-only
// Spec 577 S2a scenic sky: used by the scenic render tool ONLY (the game keeps stalag_sky.gdshader).
// A horizon-to-zenith gradient with a warm glow and a small disc toward the sun, so a low
// golden-hour sun reads in the frame. Below the horizon it stays horizon-coloured, which is the
// same colour the world's fog fades to (the tool sets both from one shot field).
shader_type sky;

uniform vec4 horizon_color : source_color = vec4(0.95, 0.72, 0.50, 1.0);
uniform vec4 zenith_color : source_color = vec4(0.25, 0.42, 0.70, 1.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.80, 0.55, 1.0);
uniform vec3 sun_dir = vec3(0.0, 0.2, 1.0); // unit vector toward the sun, world space
uniform float sun_size = 0.016; // disc angular radius, radians
uniform float glow_power = 14.0;
uniform float glow_strength = 0.35;
uniform float climb = 1.6; // how quickly the sky climbs from horizon to zenith colour
uniform float curve = 0.60;

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = clamp(d.y * climb, 0.0, 1.0);
	vec3 col = mix(horizon_color.rgb, zenith_color.rgb, pow(h, curve));
	float sd = max(dot(d, normalize(sun_dir)), 0.0);
	col += sun_color.rgb * pow(sd, glow_power) * glow_strength;
	float disc = smoothstep(cos(sun_size * 1.4), cos(sun_size), sd);
	col = mix(col, sun_color.rgb * 1.6, disc);
	COLOR = col;
}
