extends Node3D
## Spec #501 world scene root: wires the engine's streamer, walker and follow camera
## into one playable terrain. Game policy (spawn point, key bindings, exit) lives here;
## the engine scripts under engine/stalag/scripts stay policy-free.
##
## Only ever loaded through world_module.gd, after it confirmed the engine classes exist.

signal exited
## The water plan failed an invariant: the world declines to enter (the shell prints the line).
signal declined(message: String)

const SPAWN_YAW := -PI / 2.0  ## look along +x, toward the demo mesa in front of spawn

# Untyped on purpose: these nodes carry engine scripts (stalag_*.gd) with their own API.
@onready var streamer = $Streamer
@onready var walker = $Walker
@onready var cam = $Camera
@onready var sun: DirectionalLight3D = $Sun

## Asset and shader paths for the prototype's look (tiles baked by tools/bake_skin.mjs).
const TERRAIN_SHADER := "res://engine/stalag/shaders/stalag_terrain.gdshader"
const WATER_SHADER := "res://engine/stalag/shaders/stalag_water.gdshader"
const GRASS_TILE := "res://game/world/assets/grass_top.png"
const DIRT_TILE := "res://game/world/assets/dirt_side.png"
const FLIP_TEX := "res://game/world/assets/water_flip.png"
const FLOW_TEX := "res://game/world/assets/river_noise.png"
## The prototype's sun sits at (80, 120, 50) and looks at the origin.
const SUN_POSITION := Vector3(80.0, 120.0, 50.0)

var grass_mat: ShaderMaterial
var dirt_mat: ShaderMaterial
var water_mat: ShaderMaterial

## The probe drives the walker itself; real key reads are skipped while it does.
var scripted_input: bool = false
var _exit_emitted: bool = false


func _make_material(shader_path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(shader_path)
	return m


## Builds the three materials and hands them to the streamer before it loads anything.
func _build_look() -> void:
	grass_mat = _make_material(TERRAIN_SHADER)
	grass_mat.set_shader_parameter("tile", load(GRASS_TILE))
	dirt_mat = _make_material(TERRAIN_SHADER)
	dirt_mat.set_shader_parameter("tile", load(DIRT_TILE))
	dirt_mat.set_shader_parameter("flat_color", Color(0.42, 0.28, 0.15))
	water_mat = _make_material(WATER_SHADER)
	water_mat.set_shader_parameter("flip_tex", load(FLIP_TEX))
	water_mat.set_shader_parameter("flow_map", load(FLOW_TEX))
	streamer.grass_material = grass_mat
	streamer.dirt_material = dirt_mat
	streamer.water_material = water_mat
	sun.look_at_from_position(SUN_POSITION, Vector3.ZERO)
	_warm_shaders()


## Draws each material once on a speck in front of the camera so the pipelines compile
## before the first chunk lands (the first adoption otherwise pays the compile).
func _warm_shaders() -> void:
	for m in [grass_mat, dirt_mat, water_mat]:
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.02, 0.02)
		mi.mesh = q
		mi.material_override = m
		mi.position = Vector3(0.0, 0.0, -0.5)
		cam.add_child(mi)
		get_tree().create_timer(0.5).timeout.connect(mi.queue_free)


func _ready() -> void:
	add_to_group("stalag_world")
	_build_look()
	streamer.plan_failed.connect(_on_plan_failed)
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


func _on_plan_failed(message: String) -> void:
	declined.emit("the ground could not be shaped: " + message)
	request_exit()


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
