extends Node3D
## Spec #501 world scene root: wires the engine's streamer, walker and follow camera
## into one playable terrain. Game policy (spawn point, key bindings, exit) lives here;
## the engine scripts under engine/stalag/scripts stay policy-free.
##
## Only ever loaded through world_module.gd, after it confirmed the engine classes exist.

signal exited

const SPAWN_YAW := -PI / 2.0  ## look along +x, toward the demo mesa in front of spawn

# Untyped on purpose: these nodes carry engine scripts (stalag_*.gd) with their own API.
@onready var streamer = $Streamer
@onready var walker = $Walker
@onready var cam = $Camera

## The probe drives the walker itself; real key reads are skipped while it does.
var scripted_input: bool = false
var _exit_emitted: bool = false


func _ready() -> void:
	add_to_group("stalag_world")
	walker.teleport(Vector3(0.0, StalagWorld.spawn_feet_y(), 0.0), true)
	cam.yaw = SPAWN_YAW
	var fwd: Vector3 = cam.forward_xz()
	walker.face_direction(Vector2(fwd.x, fwd.z))
	cam.target = walker
	cam.look_active = true
	streamer.set_focus(walker.pos)
	cam.follow(walker.pos)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _exit_tree() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Chunks currently adopted into the scene tree.
func chunks_loaded() -> int:
	return streamer.loaded_count()


func is_grounded() -> bool:
	return walker.on_ground


## Leave the world and hand control back to the shell.
func request_exit() -> void:
	if _exit_emitted:
		return
	_exit_emitted = true
	streamer.shutdown()
	exited.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		request_exit()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	streamer.set_focus(walker.pos)
	if scripted_input:
		return
	var f: Vector3 = cam.forward_xz()
	var r: Vector3 = cam.right_xz()
	var wish := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		wish += Vector2(f.x, f.z)
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		wish -= Vector2(f.x, f.z)
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		wish += Vector2(r.x, r.z)
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		wish -= Vector2(r.x, r.z)
	walker.input_move = wish.normalized() if wish.length() > 0.0 else Vector2.ZERO
	walker.input_jump = Input.is_key_pressed(KEY_SPACE)
	walker.input_run = Input.is_key_pressed(KEY_SHIFT)
