// SPDX-License-Identifier: AGPL-3.0-only
// Spec 580 S4 -- the backdrop ring's one shader: vertex or instance colour, an optional procedural sprite for the
// distant tree impostors, and the same exp-squared fog as the rest of the world (stalag_terrain.gdshader): the
// surface keeps (1 - f) of its lit colour and gains f of the haze colour as emission. Visual only.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

uniform sampler2D sprite : source_color, filter_linear_mipmap;
uniform bool use_sprite = false; // true: the impostor sprite's alpha cuts the silhouette
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.005;

varying float v_depth;

void vertex() {
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	vec3 base = COLOR.rgb;
	if (use_sprite) {
		vec4 s = texture(sprite, UV);
		ALPHA = s.a;
		ALPHA_SCISSOR_THRESHOLD = 0.5;
		base *= s.rgb;
	}
	float d = fog_density * v_depth;
	float f = 1.0 - clamp(exp(-d * d), 0.0, 1.0);
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
