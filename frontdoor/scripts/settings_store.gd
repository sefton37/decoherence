extends RefCounted
class_name SettingsStore

## Persisted player settings for the Q-Ent OS (Spec #519). Schema lives in
## data/settings_schema.json; the file is user://settings.json, written
## atomically (temp file then rename) and loaded strictly: unknown keys are
## dropped, invalid values fall back to the default, a corrupt file yields
## the defaults plus status "corrupt" so the caller can say so honestly.
##
## The mapping helpers below turn a setting value into the number the
## engine applies; boot_controller.gd and the terminal do the applying.

const SCHEMA_PATH := "res://frontdoor/data/settings_schema.json"
const FILE_NAME := "settings.json"

## CRT: [scanline_intensity, vignette_strength]. "normal" equals the scene's
## shipped values so defaults reproduce today's look exactly.
const _CRT_PARAMS := {
	"normal": [0.25, 0.4],
	"off": [0.0, 0.0],
	"low": [0.12, 0.2],
	"high": [0.45, 0.6],
}

## Multiplier applied to the scripted flicker's peak (0.85 * factor).
const _FLICKER_FACTOR := {"full": 1.0, "half": 0.5, "off": 0.0}

## Typewriter reveal speed in characters per second; 0 = instant.
const _TEXT_CPS := {"normal": 160.0, "slow": 50.0, "fast": 600.0, "instant": 0.0}


static func load_schema() -> Dictionary:
	var parsed = IntentRouter.load_json(SCHEMA_PATH)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {"settings": []}


static func defaults(schema: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for s in schema.get("settings", []):
		out[String(s.get("key", ""))] = String(s.get("default", ""))
	return out


static func is_valid(schema: Dictionary, key: String, value: String) -> bool:
	for s in schema.get("settings", []):
		if String(s.get("key", "")) == key:
			return value in s.get("values", [])
	return false


## Strict merge: starts from defaults, accepts only known keys with valid values.
static func sanitize_loaded(schema: Dictionary, loaded: Dictionary) -> Dictionary:
	var out := defaults(schema)
	for k in loaded:
		if typeof(loaded[k]) == TYPE_STRING and is_valid(schema, String(k), String(loaded[k])):
			out[String(k)] = String(loaded[k])
	return out


## Returns {settings: Dictionary, status: "ok"|"missing"|"corrupt"}.
static func load_settings(schema: Dictionary, path: String = "") -> Dictionary:
	var target := path if path != "" else "user://" + FILE_NAME
	if not FileAccess.file_exists(target):
		return {"settings": defaults(schema), "status": "missing"}
	var f := FileAccess.open(target, FileAccess.READ)
	if f == null:
		return {"settings": defaults(schema), "status": "corrupt"}
	var text := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(text) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {"settings": defaults(schema), "status": "corrupt"}
	return {"settings": sanitize_loaded(schema, parser.data), "status": "ok"}


## Atomic save: write <path>.tmp, then rename over <path>. Returns success.
static func save_settings(settings: Dictionary, path: String = "") -> bool:
	var target := path if path != "" else "user://" + FILE_NAME
	var tmp := target + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(settings))
	f.close()
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(target))
	return err == OK


static func crt_params(value: String) -> Array:
	return _CRT_PARAMS.get(value, _CRT_PARAMS["normal"])


static func flicker_factor(value: String) -> float:
	return float(_FLICKER_FACTOR.get(value, 1.0))


static func text_cps(value: String) -> float:
	return float(_TEXT_CPS.get(value, _TEXT_CPS["normal"]))


## Window request for a display value: {fullscreen: bool, size: Vector2i}.
static func display_request(value: String) -> Dictionary:
	if value == "fullscreen":
		return {"fullscreen": true, "size": Vector2i(0, 0)}
	var parts := value.split("x")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		return {"fullscreen": false, "size": Vector2i(parts[0].to_int(), parts[1].to_int())}
	return {"fullscreen": false, "size": Vector2i(1920, 1080)}
