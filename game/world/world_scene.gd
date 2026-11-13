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
## Spec 576: the follow camera cannot come closer than 2.5 m (its own minimum boom), and straight behind the
## colonist at the hand-off pose that would put it inside the pod. So it starts swung this many degrees to
## one side of the facing line: the same 2.5 m boom, but standing in the open beside the pod, still looking
## across the colonist at the equipment (the mouse still turns it freely).
const HANDOFF_CAM_YAW_DEG := 50.0
const HANDOFF_BOOM_M := 2.5

# Untyped on purpose: these nodes carry engine scripts (stalag_*.gd) with their own API.
@onready var streamer = $Streamer
@onready var walker = $Walker
@onready var cam = $Camera
@onready var sun: DirectionalLight3D = $Sun

## Asset and shader paths for the prototype's look (tiles baked by tools/bake_skin.mjs).
## The prototype's own skin shader: no bucket draws with it any more, it is the probes' old-look baseline.
const TERRAIN_SHADER := "res://engine/stalag/shaders/stalag_terrain.gdshader"
## Spec #551: the ground (tile variants, world tint, decals; phase 2: rock, moss, gravel, sand, mud, dirt F); both buckets.
const GRASS_SHADER := "res://engine/stalag/shaders/stalag_grass.gdshader"
const WATER_SHADER := "res://engine/stalag/shaders/stalag_water.gdshader"
const FloraAssets := preload("res://game/world/flora_assets.gd")
const TreeAssets := preload("res://game/world/tree_assets.gd")
const UnderstoryAssets := preload("res://game/world/understory_assets.gd")
const GrassLook := preload("res://game/world/grass_look.gd")
const GroundLook := preload("res://game/world/ground_look.gd")
const HomesteadSite := preload("res://game/homestead/homestead_site.gd")
const HomesteadView := preload("res://game/homestead/homestead_view.gd")
const SITE_TEMPLATE := "res://game/homestead/data/site_template.json"
const SITE_EQUIPMENT := "res://game/homestead/data/starter_equipment.json"
const GRASS_TILE := "res://game/world/assets/grass_top.png"
const DIRT_TILE := "res://game/world/assets/dirt_side.png"
const FLIP_TEX := "res://game/world/assets/water_flip.png"
const FLOW_TEX := "res://game/world/assets/river_noise.png"
## The prototype's sun sits at (80, 120, 50) and looks at the origin.
const SUN_POSITION := Vector3(80.0, 120.0, 50.0)

var grass_mat: ShaderMaterial
var dirt_mat: ShaderMaterial
var water_mat: ShaderMaterial
## Spec #545: the meadow's sprites, rock meshes, materials and the wind feed (game policy).
var flora: RefCounted
## Spec #549: the forest (trunks, crowns, shadow proxies) and the understory (shrubs, wildflowers):
## meshes, materials and the same wind feed as the meadow (game policy).
var trees: RefCounted
var understory: RefCounted
## The shared wind clock, in seconds. The probe freezes or sets it; otherwise it runs with the frame.
var flora_clock: float = 0.0
var flora_clock_frozen: bool = false

## The probe drives the walker itself; real key reads are skipped while it does.
var scripted_input: bool = false
var _exit_emitted: bool = false
## How many times the menu's quit path flushed this scene (read by the probes).
var flush_calls: int = 0

## Spec 576: the homestead belongs to the assigned colonist. The id (set before the scene enters the
## tree; S2 wires the Launch seam to it) is hashed to the site seed; empty means the default site.
var colonist_id: String = ""
var homestead_layout: Dictionary = {}
var homestead_template: Dictionary = {}
var homestead_equipment: Dictionary = {}
var homestead: Node3D


func _make_material(shader_path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(shader_path)
	return m


## Builds the three materials and hands them to the streamer before it loads anything.
func _build_look() -> void:
	grass_mat = _make_material(GRASS_SHADER)
	grass_mat.set_shader_parameter("tile", load(GRASS_TILE))
	GrassLook.apply(grass_mat)
	GroundLook.apply(grass_mat, 0, SUN_POSITION)
	# Spec #551 phase 2: the dirt bucket (walls, low tops) wears the same shader: rock, moss, dirt F.
	dirt_mat = _make_material(GRASS_SHADER)
	dirt_mat.set_shader_parameter("tile", load(DIRT_TILE))
	dirt_mat.set_shader_parameter("flat_color", Color(0.42, 0.28, 0.15))
	GrassLook.apply(dirt_mat)
	GroundLook.apply(dirt_mat, 1, SUN_POSITION)
	GroundLook.install_flora_mask(_pad_flora_rects())  # before the streamer builds a chunk: mud, sand and the pad keep the meadow off
	water_mat = _make_material(WATER_SHADER)
	water_mat.set_shader_parameter("flip_tex", load(FLIP_TEX))
	water_mat.set_shader_parameter("flow_map", load(FLOW_TEX))
	streamer.grass_material = grass_mat
	streamer.dirt_material = dirt_mat
	streamer.water_material = water_mat
	flora = FloraAssets.new()
	streamer.flora_assets = flora.forms
	flora.set_time(flora_clock)
	trees = TreeAssets.new()
	streamer.tree_assets = trees.forms
	trees.set_time(flora_clock)
	understory = UnderstoryAssets.new()
	streamer.understory_assets = understory.forms
	understory.set_time(flora_clock)
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


## Ground height under (x, z) as the walker sees it: the highest surface up to a metre above the spawn.
func _ground_at(x: float, z: float) -> float:
	return StalagWorld.ground_envelope_at(x, z, StalagWorld.spawn_feet_y() + 1.0)


## Spec 576: generates this colonist's site (a pure function of the id and the two data files).
func _plan_homestead() -> void:
	homestead_template = HomesteadSite.load_json(SITE_TEMPLATE)
	homestead_equipment = HomesteadSite.load_json(SITE_EQUIPMENT)
	# The engine's flat pad takes its size and blend width from the template (one statement of each).
	var pad_half := maxf(float(homestead_template["slab"]["half_x_m"]), float(homestead_template["slab"]["half_z_m"])) + float(homestead_template["pad_margin_m"])
	StalagWorld.set_pad(pad_half, float(homestead_template["pad_blend_m"]))
	var site_seed: int = int(homestead_template["default_site_seed"])
	if not colonist_id.is_empty():
		site_seed = HomesteadSite.site_seed_for(colonist_id)
	homestead_layout = HomesteadSite.generate(site_seed, homestead_template, homestead_equipment, _ground_at)


## The pad's footprint (slab plus margin) as a blocked rectangle for the meadow and understory filter.
func _pad_flora_rects() -> Array:
	if homestead_layout.is_empty():
		return []
	var m := float(homestead_template["pad_margin_m"])
	var hx := float(homestead_layout["slab"]["half_x_m"]) + m
	var hz := float(homestead_layout["slab"]["half_z_m"]) + m
	return [{"x0": -hx, "x1": hx, "z0": -hz, "z1": hz}]


func _ready() -> void:
	add_to_group("stalag_world")
	add_to_group("quit_flush")
	_plan_homestead()
	_build_look()
	streamer.plan_failed.connect(_on_plan_failed)
	var start := Vector3(0.0, StalagWorld.spawn_feet_y(), 0.0)
	var facing := Vector2.ZERO
	cam.yaw = SPAWN_YAW
	if not homestead_layout.is_empty():
		homestead = HomesteadView.build(homestead_layout, homestead_template, homestead_equipment)
		add_child(homestead)
		var hand: Dictionary = homestead_layout["handoff"]
		start = Vector3(float(hand["x"]), _ground_at(float(hand["x"]), float(hand["z"])), float(hand["z"]))
		cam.yaw = float(hand["yaw"]) + deg_to_rad(HANDOFF_CAM_YAW_DEG)
		cam.dist = HANDOFF_BOOM_M
		facing = Vector2(cos(float(hand["dir_angle"])), sin(float(hand["dir_angle"])))
	walker.teleport(start, true)
	var fwd: Vector3 = cam.forward_xz()
	walker.face_direction(facing if facing != Vector2.ZERO else Vector2(fwd.x, fwd.z))
	cam.target = walker
	cam.look_active = true
	streamer.set_focus(walker.pos)
	cam.follow(walker.pos)
	if not scripted_input:  # a probe drives the walker itself and has no pointer to capture
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


## Spec #578: the pause menu (Esc) owns leaving the world, and quitting the game flushes the streamer.
## Called by the menu's quit path before the process ends: the streamer waits for its worker tasks.
func flush_for_exit() -> void:
	flush_calls += 1
	streamer.shutdown()


func _process(delta: float) -> void:
	streamer.set_focus(walker.pos)
	if not flora_clock_frozen:
		flora_clock += delta
	flora.set_time(flora_clock)  # one clock and the weather front for the whole meadow
	trees.set_time(flora_clock)  # ... and the crowns and the understory read the same clock and front
	understory.set_time(flora_clock)
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
