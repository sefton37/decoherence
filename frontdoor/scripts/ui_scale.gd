extends RefCounted
class_name UiScale

## Runtime content scaling for the front door (Spec #541 D10/D11). The UI is
## laid out for a 1920x1080 logical canvas; on a larger window the whole canvas
## is magnified by Window.content_scale_factor so the front door reads the
## same as it does at 1080p. Windows at or below 1080p keep factor 1, so the
## 1280x720 compact tier is untouched. Applied in code, never through
## project.godot (which carries no stretch keys).

const BASE_W := 1920.0
const BASE_H := 1080.0
const MAX_FACTOR := 5.0

## The CRT shader's scanline spacing at factor 1 (physical pixels).
const BASE_SCANLINE_SPACING_PX := 4.0


## max(1, min(w / 1920, h / 1080)), capped at MAX_FACTOR.
static func factor_for(window_size: Vector2i) -> float:
	var f := minf(float(window_size.x) / BASE_W, float(window_size.y) / BASE_H)
	return clampf(f, 1.0, MAX_FACTOR)


## The shader samples FRAGCOORD in physical pixels, so the spacing scales with
## the factor or the scanlines go hairline on a large display.
static func crt_spacing(factor: float) -> float:
	return BASE_SCANLINE_SPACING_PX * factor
