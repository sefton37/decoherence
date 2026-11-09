// Spec #517 -- the prototype's sky dome gradient: horizon haze to zenith blue,
// h = clamp(dir.y * 1.5 + 0.15, 0, 1), colour = mix(horizon, zenith, pow(h, 0.65)).
shader_type sky;

uniform vec4 horizon_color : source_color = vec4(0.6667, 0.8, 0.8784, 1.0);
uniform vec4 zenith_color : source_color = vec4(0.3529, 0.5882, 0.8157, 1.0);

void sky() {
	float h = clamp(EYEDIR.y * 1.5 + 0.15, 0.0, 1.0);
	COLOR = mix(horizon_color.rgb, zenith_color.rgb, pow(h, 0.65));
}
