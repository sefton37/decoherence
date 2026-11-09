// Spec #517 -- terrain skin. The prototype's tile-textured grass and dirt (nearest-filtered
// 16 px tiles, world-space UVs from the engine) with three.js FogExp2 fog reproduced exactly:
// factor = 1 - exp(-(density * depth)^2). Godot's built-in fog has a different curve, so the
// environment's fog stays off and this shader applies the prototype's.
//
// Fog is folded into the lit result without a custom light(): the surface keeps (1 - f) of
// its lit colour and gains f of the haze colour as emission, which is exactly mix(lit, haze, f).
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform sampler2D tile : source_color, filter_nearest, repeat_enable;
uniform vec4 haze_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform float fog_density = 0.012;
uniform bool use_skin = true; // false: one flat colour per material (negative control)
uniform vec4 flat_color : source_color = vec4(0.30, 0.55, 0.22, 1.0);
uniform bool use_fog = true; // false: no fog term (negative control)

varying float v_depth;

void vertex() {
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	vec3 base = use_skin ? texture(tile, UV).rgb : flat_color.rgb;
	float d = fog_density * v_depth;
	float f = use_fog ? 1.0 - clamp(exp(-d * d), 0.0, 1.0) : 0.0;
	ALBEDO = base * (1.0 - f);
	EMISSION = haze_color.rgb * f;
	ROUGHNESS = 1.0;
}
