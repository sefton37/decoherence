extends Camera3D
## Spec #501 follow camera: third person, mouse look, kept above the terrain.
##
## The boom starts at a pivot above the target's feet and swings by yaw/pitch. Terrain
## clearance uses the engine's ground query: the boom is shortened first (down to
## MIN_DIST) and the camera is then lifted above whatever surface is under it, so the
## view never ends up inside a hill or a mesa.

const MIN_DIST := 2.5
const MAX_DIST := 6.0
const DEFAULT_DIST := 5.0
## Camera elevation above the horizon, radians. Slightly negative lets it sit low and look up.
const PITCH_MIN := -0.30
const PITCH_MAX := 1.30
const PIVOT_HEIGHT := 1.5
const CLEARANCE := 0.45
const MOUSE_SENS := 0.0030

var yaw: float = 0.0
var pitch: float = 0.40
var dist: float = DEFAULT_DIST
## Mouse look runs only while the world owns the mouse (set by the world scene).
var look_active: bool = false
## Node exposing `pos` (feet position) to follow every frame; null = placed by hand.
var target: Node = null


func _process(_delta: float) -> void:
	if target != null:
		follow(target.pos)


func _unhandled_input(event: InputEvent) -> void:
	if not look_active:
		return
	if event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		yaw -= m.relative.x * MOUSE_SENS
		pitch = clampf(pitch + m.relative.y * MOUSE_SENS, PITCH_MIN, PITCH_MAX)
	elif event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.pressed and b.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist - 0.4, MIN_DIST, MAX_DIST)
		elif b.pressed and b.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist + 0.4, MIN_DIST, MAX_DIST)


## Horizontal forward direction the camera looks along (unit, y = 0).
func forward_xz() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right_xz() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func _is_inside_terrain(p: Vector3) -> bool:
	# The highest surface under p (any height): if it is above p, p is buried.
	return StalagWorld.ground_envelope_at(p.x, p.z, INF) > p.y - 0.30


## Places the camera for a target standing at `feet`.
func follow(feet: Vector3) -> void:
	var pivot := feet + Vector3(0.0, PIVOT_HEIGHT, 0.0)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	var use := dist
	# Shorten the boom until its tip is clear of the terrain.
	while use > MIN_DIST and _is_inside_terrain(pivot + dir * use):
		use -= 0.25
	use = maxf(use, MIN_DIST)
	var pos := pivot + dir * use
	# Never below the highest surface under the camera (tight boom, steep slope, wall corner).
	var under := StalagWorld.ground_envelope_at(pos.x, pos.z, INF)
	if under > -INF and pos.y < under + CLEARANCE:
		pos.y = under + CLEARANCE
	global_position = pos
	look_at(pivot, Vector3.UP)


## Current distance from the pivot to the camera (what the probe reports).
func boom_length(feet: Vector3) -> float:
	return global_position.distance_to(feet + Vector3(0.0, PIVOT_HEIGHT, 0.0))
