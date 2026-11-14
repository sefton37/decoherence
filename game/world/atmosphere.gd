extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 582 S1 -- atmosphere presets for the world scene: the sun, the ambient light, the sky and the haze colour.
## The presets are data (res://game/world/data/atmosphere.json): `classic` is the world's own look, `clear` is
## daylight with a clear sky and clouds, `amber` is the low golden sun. apply() sets the sun, the ambient light and
## the sky on the world and returns the resolved fog values; the world scene pushes the haze colour and the density
## to every shader that carries fog (it owns that list), and the far terrain takes `ground_haze`.
##
## `classic` writes back exactly the values the scene and the engine sky shader already carry, so a world that
## applies it renders the same picture as a world that never called this file.

const DATA_PATH := "res://game/world/data/atmosphere.json"
const SKY_CLEAR := "res://game/world/sky_clear.gdshader"
## The engine sky material of the scene file stays for `classic`; the other presets replace it with sky_clear.

static var _cache: Dictionary = {}


static func load_data() -> Dictionary:
	if _cache.is_empty():
		var doc = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		_cache = doc if typeof(doc) == TYPE_DICTIONARY else {"default": "classic", "presets": {}}
	return _cache


static func has_preset(name: String) -> bool:
	return load_data()["presets"].has(name)


static func default_name() -> String:
	return str(load_data().get("default", "classic"))


static func col(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


## Applies `name` to the world's sun, ambient light and sky. `cloud_time` is the world's clock. Returns
## {name, haze, ground_haze, density (float, or -1.0 for 'the level's own'), sun_dir (Vector3 toward the sun)}.
static func apply(world: Node, name: String, cloud_time: float) -> Dictionary:
	var presets: Dictionary = load_data()["presets"]
	if not presets.has(name):
		push_warning("atmosphere: unknown preset '%s'; using '%s'" % [name, default_name()])
		name = default_name()
	var p: Dictionary = presets[name]
	var sun: DirectionalLight3D = world.sun
	var sj: Dictionary = p["sun"]
	if sj["elev_deg"] != null:
		var elev := deg_to_rad(float(sj["elev_deg"]))
		var az := deg_to_rad(float(sj["azimuth_deg"]))
		var to_sun := Vector3(sin(az) * cos(elev), sin(elev), cos(az) * cos(elev)).normalized()
		sun.global_position = Vector3(0.0, 50.0, 0.0)
		sun.look_at(sun.global_position - to_sun, Vector3.UP)
	sun.light_color = col(sj["color"])
	sun.light_energy = float(sj["energy"])
	var env: Environment = world.cam.environment
	env.ambient_light_color = col(p["ambient"]["color"])
	env.ambient_light_energy = float(p["ambient"]["energy"])
	var d_sun: Vector3 = sun.global_basis.z  # the light looks down -z, so +z points toward the sun
	var sky: Dictionary = p["sky"]
	var cl: Dictionary = p["clouds"]
	var sky_mat: Material = env.sky.sky_material
	if name == "classic":
		# the scene file's engine sky, with the preset's own two colours (the same numbers it already holds)
		if sky_mat is ShaderMaterial and (sky_mat as ShaderMaterial).shader.resource_path != SKY_CLEAR:
			(sky_mat as ShaderMaterial).set_shader_parameter("horizon_color", col(sky["horizon"]))
			(sky_mat as ShaderMaterial).set_shader_parameter("zenith_color", col(sky["zenith"]))
		else:
			env.sky.sky_material = _classic_sky(sky)
	else:
		var m: ShaderMaterial
		if sky_mat is ShaderMaterial and (sky_mat as ShaderMaterial).shader.resource_path == SKY_CLEAR:
			m = sky_mat
		else:
			m = ShaderMaterial.new()
			m.shader = load(SKY_CLEAR)
			env.sky.sky_material = m
		m.set_shader_parameter("horizon_color", col(sky["horizon"]))
		m.set_shader_parameter("zenith_color", col(sky["zenith"]))
		m.set_shader_parameter("sun_color", col(sj["color"]))
		m.set_shader_parameter("sun_dir", d_sun)
		m.set_shader_parameter("sun_size", float(sky["sun_size"]))
		m.set_shader_parameter("glow_strength", float(sky["glow_strength"]))
		m.set_shader_parameter("glow_power", float(sky["glow_power"]))
		m.set_shader_parameter("cloud_cover", float(cl["cover"]) if bool(cl["enabled"]) else 0.0)
		m.set_shader_parameter("cloud_scale", float(cl["scale"]))
		m.set_shader_parameter("cloud_time", cloud_time * float(cl["speed"]))
	var f: Dictionary = p["fog"]
	return {
		"name": name,
		"haze": col(f["haze"]),
		"ground_haze": col(f["ground_haze"]),
		"density": float(f["density"]) if f["density"] != null else -1.0,
		"sun_dir": d_sun,
		"sun_moved": sj["elev_deg"] != null,
	}


## Moves the clouds with the world clock (no-op when the sky has none).
static func set_time(world: Node, name: String, cloud_time: float) -> void:
	var p: Dictionary = load_data()["presets"].get(name, {})
	if p.is_empty() or not bool(p["clouds"]["enabled"]):
		return
	var sky_mat: Material = world.cam.environment.sky.sky_material
	if sky_mat is ShaderMaterial:
		(sky_mat as ShaderMaterial).set_shader_parameter("cloud_time", cloud_time * float(p["clouds"]["speed"]))


static func _classic_sky(sky: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://engine/stalag/shaders/stalag_sky.gdshader")
	m.set_shader_parameter("horizon_color", col(sky["horizon"]))
	m.set_shader_parameter("zenith_color", col(sky["zenith"]))
	return m
