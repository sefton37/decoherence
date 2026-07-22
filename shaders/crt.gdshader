shader_type canvas_item;

// CRT/flicker overlay (Spec #370 / plan-370, Risk 4). Deliberately a pure
// UV/FRAGCOORD-space overlay shader applied to a full-rect ColorRect on a
// top CanvasLayer -- NOT a SCREEN_TEXTURE-sampling distortion shader, which
// would require a BackBufferCopy ancestor for no payoff this spec needs.
// Constructs its own scanline + vignette darkening pattern and blends it
// via COLOR.a; never samples what is rendered underneath.

uniform float scanline_intensity : hint_range(0.0, 1.0) = 0.25;
uniform float scanline_spacing_px : hint_range(1.0, 20.0) = 4.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.4;

// Instability grammar (DOD-11). Driven ONLY by boot_controller.gd's
// scripted Tweens at named narrative beats (gate resolution, the
// instability-hint stage, the Handler's first reply) -- NEVER a per-frame
// randf() call. A short spike-then-decay curve, not continuous noise.
uniform float flicker : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Scanline darkening bands: every other pixel row (in screen space) is
	// darkened by scanline_intensity.
	float scan_phase = mod(FRAGCOORD.y, scanline_spacing_px);
	float scanline_alpha = step(scan_phase, scanline_spacing_px * 0.5) * scanline_intensity;

	// Radial vignette from screen center.
	vec2 centered = UV - vec2(0.5, 0.5);
	float dist = length(centered) * 1.41421356;
	float vignette_alpha = smoothstep(0.35, 1.0, dist) * vignette_strength;

	float overlay_alpha = clamp(scanline_alpha + vignette_alpha, 0.0, 1.0);
	vec3 overlay_color = vec3(0.0, 0.0, 0.0);

	// Flicker pushes the overlay toward a brief bright teal flash rather
	// than pure darkening -- reads as an instability spike, not a dimming.
	overlay_color = mix(overlay_color, vec3(0.4, 0.9, 0.85), flicker);
	overlay_alpha = clamp(overlay_alpha + flicker * 0.5, 0.0, 1.0);

	COLOR = vec4(overlay_color, overlay_alpha);
}
