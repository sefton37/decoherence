// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545 -- rock shader: the faceted truncated-octahedron rocks of the frozen Stalag prototype
// (tag prototype-final). Vertex colours are linear (the bake applies the prototype's sRGB to linear
// step, index.html s2l, "so it does not blow out"), lit lambert, with the same exp-squared fog as
// the terrain: the surface keeps (1 - f) of its lit colour and gains f of the haze as emission.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform bool colors_are_srgb = false; // true: feed the colours un-converted (negative control only)

varying float v_depth;

void vertex() {
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	vec3 base = COLOR.rgb;
	if (colors_are_srgb) {
		base = vec3(pow(base.r, 1.0 / 2.4), pow(base.g, 1.0 / 2.4), pow(base.b, 1.0 / 2.4));
	}
	float d = fog_density * v_depth;
	float f = 1.0 - clamp(exp(-d * d), 0.0, 1.0);
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
