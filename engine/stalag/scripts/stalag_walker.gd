extends Node3D
## Spec #501 third-person placeholder character + its kinematic controller.
##
## The controller is a GDScript port of the prototype's character-controller.js
## semantics (fixed substeps, accelerate toward a wish velocity, coyote time, jump
## buffer, auto step-up of MAX_STEP, snap-down to ground, per-axis wall sliding). It
## talks to the world only through StalagWorld's occupancy-derived queries
## (ground_envelope_at / ground_floor / blocked_between), the same seam the JS had.
## The body is a primitive capsule; avatar art is a later slice.

signal landed

const GRAVITY := 24.0
const JUMP_VELOCITY := 7.27
const WALK_SPEED := 4.5
const RUN_SPEED := 7.0
const GROUND_ACCEL := 50.0
const GROUND_DECEL := 60.0
const AIR_ACCEL := 12.0
const MAX_STEP := 1.0  ## auto-climb up to this rise; taller is a wall
const SNAP_DOWN := 1.0  ## stick to ground on descending terraces
const COYOTE_TIME := 0.10
const JUMP_BUFFER := 0.10
const TERMINAL_VEL := 55.0
const FIXED_SUBSTEP := 1.0 / 120.0
const PLAYER_HEIGHT := 1.7
## Drawn capsule radius: a little under the collision radius (0.3, from the prototype), so the
## drawn body never reaches into a wall the collision has stopped at.
const BODY_RADIUS := 0.27
const GROUND_EPS := 0.02
## Deviation from character-controller.js (Spec #501): the footprint sample may lift the
## feet above the centre-point ground by at most this much. The prototype lets any
## footprint corner set the height, so against a steep riser the body can hover a full
## riser above the surface under its centre; this caps that at less than one cell
## diameter so the character always reads as standing on the rendered terrain.
const MAX_FOOTPRINT_LIFT := 0.45
## The world edge: stay this far inside the footprint.
const EDGE_MARGIN := 0.25

# --- state (feet position; the node itself is placed at the feet) ---
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var on_ground: bool = false
var coyote: float = 0.0
var jump_buffer: float = 0.0
var acc: float = 0.0

# --- input (world-space wish direction on xz, magnitude 0..1) ---
var input_move := Vector2.ZERO
var input_jump: bool = false
var input_run: bool = false

## Negative-control hook: shifts the rendered body (never the controller's feet).
var body_offset_y: float = 0.0

var _edge: float = 0.0
var _body: Node3D
var _was_airborne: bool = false


func _ready() -> void:
	_edge = StalagWorld.get_half_extent_m() - EDGE_MARGIN
	_build_body()


func _build_body() -> void:
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.35, 0.10)
	mat.roughness = 0.8
	var trunk := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = BODY_RADIUS
	cap.height = PLAYER_HEIGHT
	trunk.mesh = cap
	trunk.material_override = mat
	trunk.position = Vector3(0.0, PLAYER_HEIGHT * 0.5, 0.0)
	_body.add_child(trunk)
	# A small visor on the -Z side so the facing direction reads at a glance.
	var visor := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.36, 0.14, 0.20)
	visor.mesh = box
	var vmat := StandardMaterial3D.new()
	vmat.albedo_color = Color(0.10, 0.12, 0.18)
	visor.material_override = vmat
	visor.position = Vector3(0.0, PLAYER_HEIGHT * 0.82, -BODY_RADIUS)
	_body.add_child(visor)


## Places the character with feet at p and clears all motion.
func teleport(p: Vector3, grounded: bool = false) -> void:
	pos = p
	vel = Vector3.ZERO
	on_ground = grounded
	coyote = 0.0
	jump_buffer = 0.0
	acc = 0.0
	_apply_transform()


func body_node() -> Node3D:
	return _body


## Turns the body to face a horizontal direction (the visor is on its -Z side).
func face_direction(d: Vector2) -> void:
	if _body != null and d.length() > 1e-4:
		_body.rotation.y = atan2(-d.x, -d.y)


func speed_xz() -> float:
	return Vector2(vel.x, vel.z).length()


func _process(delta: float) -> void:
	step(minf(delta, 0.1))


## Advances the controller by dt seconds of fixed substeps, then updates the node.
func step(dt: float) -> void:
	acc += dt
	var guard := 0
	while acc >= FIXED_SUBSTEP and guard < 600:
		_substep(FIXED_SUBSTEP)
		acc -= FIXED_SUBSTEP
		guard += 1
	_apply_transform()


func _apply_transform() -> void:
	global_position = pos
	if _body != null:
		_body.position = Vector3(0.0, body_offset_y, 0.0)
		var flat := Vector2(vel.x, vel.z)
		if flat.length() > 0.3:
			_body.rotation.y = lerp_angle(_body.rotation.y, atan2(-flat.x, -flat.y), 0.25)


static func _approach(v: float, target: float, max_delta: float) -> float:
	if v < target:
		return minf(v + max_delta, target)
	if v > target:
		return maxf(v - max_delta, target)
	return v


func _substep(h: float) -> void:
	# timers
	if coyote > 0.0:
		coyote = maxf(0.0, coyote - h)
	jump_buffer = JUMP_BUFFER if input_jump else maxf(0.0, jump_buffer - h)

	# horizontal acceleration toward the wish velocity
	var wish := input_move
	var wlen := wish.length()
	if wlen > 1.0:
		wish /= wlen
	var speed := RUN_SPEED if input_run else WALK_SPEED
	var has_input := wlen > 1e-4
	var accel := (GROUND_ACCEL if has_input else GROUND_DECEL) if on_ground else AIR_ACCEL
	vel.x = _approach(vel.x, wish.x * speed, accel * h)
	vel.z = _approach(vel.z, wish.y * speed, accel * h)

	# jump
	if jump_buffer > 0.0 and (on_ground or coyote > 0.0):
		vel.y = JUMP_VELOCITY
		on_ground = false
		coyote = 0.0
		jump_buffer = 0.0

	# horizontal move, per axis so the character slides along walls
	_resolve_horizontal(0, vel.x * h)
	_resolve_horizontal(2, vel.z * h)
	_clamp_to_world()

	# vertical: snap to ground or integrate gravity
	if on_ground and vel.y <= 0.0:
		var floor_y := StalagWorld.ground_floor(pos.x, pos.z, pos.y + 0.05)
		var centre_y := StalagWorld.ground_envelope_at(pos.x, pos.z, pos.y + 0.05)
		if centre_y > -INF:
			floor_y = minf(floor_y, centre_y + MAX_FOOTPRINT_LIFT)
		if floor_y > -INF and pos.y - floor_y <= SNAP_DOWN:
			pos.y = floor_y
			vel.y = 0.0
			on_ground = true
			coyote = COYOTE_TIME
		else:
			on_ground = false
			coyote = COYOTE_TIME  # walked off an edge
	if not on_ground:
		vel.y = maxf(vel.y - GRAVITY * h, -TERMINAL_VEL)
		var new_y := pos.y + vel.y * h
		if vel.y > 0.0:
			if StalagWorld.blocked_between(pos.x, pos.z, new_y + PLAYER_HEIGHT - 0.4, new_y + PLAYER_HEIGHT):
				vel.y = 0.0  # ceiling
			else:
				pos.y = new_y
		else:
			# Falling: floor at or just above new_y, centre point only, capped to pos.y + 1.
			var f2 := StalagWorld.ground_envelope_at(pos.x, pos.z, pos.y + 1.0)
			if f2 > -INF and new_y <= f2 + GROUND_EPS:
				pos.y = f2
				vel.y = 0.0
				on_ground = true
				coyote = COYOTE_TIME
				landed.emit()
			else:
				pos.y = new_y


# Step-sweep: (a) walk forward if the body band is clear and settle onto a small rise;
# (b) else probe the ground ahead and climb it if the rise <= MAX_STEP and the band above
# it is clear; (c) else it is a wall and that velocity component is lost.
func _resolve_horizontal(axis: int, delta: float) -> void:
	var tx := pos.x + (delta if axis == 0 else 0.0)
	var tz := pos.z + (delta if axis == 2 else 0.0)

	if not StalagWorld.blocked_between(tx, tz, pos.y + MAX_STEP + 0.05, pos.y + PLAYER_HEIGHT):
		pos[axis] += delta
		# Centre-only settle (a footprint probe could reach into a neighbouring wall).
		var floor_y := StalagWorld.ground_envelope_at(pos.x, pos.z, pos.y + MAX_STEP + 0.1)
		if floor_y > -INF and floor_y > pos.y and floor_y - pos.y <= MAX_STEP:
			if not StalagWorld.blocked_between(pos.x, pos.z, floor_y + MAX_STEP + 0.05, floor_y + PLAYER_HEIGHT):
				pos.y = floor_y
		return

	var f_ahead := StalagWorld.ground_floor(tx, tz, INF)
	var rise := f_ahead - pos.y
	if rise > 0.0 and rise <= MAX_STEP:
		if not StalagWorld.blocked_between(tx, tz, f_ahead + MAX_STEP + 0.05, f_ahead + PLAYER_HEIGHT):
			pos[axis] += delta
			pos.y = f_ahead
			return

	vel[axis] = 0.0


func _clamp_to_world() -> void:
	if absf(pos.x) > _edge:
		pos.x = clampf(pos.x, -_edge, _edge)
		vel.x = 0.0
	if absf(pos.z) > _edge:
		pos.z = clampf(pos.z, -_edge, _edge)
		vel.z = 0.0
