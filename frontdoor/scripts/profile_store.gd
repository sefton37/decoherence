extends RefCounted
class_name ProfileStore

## The two small local files behind the recruitment funnel (Spec #573).
##
## profile.json is who the player is to the game: designation, handle, the
## generated Empire handler, the acceptance record and an empty assignments list
## that the handler module builds on later. Unknown top-level keys survive a round
## trip. A file that does not parse is moved aside (never destroyed) and a fresh
## profile is made by the caller.
##
## handler_dossier.json is the handler's operational memory: a few short fields
## and nothing else (no transcript, no timestamps). /forget deletes the file.
##
## Both files live under user:// and are written atomically (temp file, rename).
## Nothing here draws randomness, reads a clock or touches the network.

const PROFILE_FILE := "user://profile.json"
const DOSSIER_FILE := "user://handler_dossier.json"
const SCHEMA := 1
const KIND_EMPIRE := "empire"


static func new_profile(designation: String, handler_name: String) -> Dictionary:
	return {
		"schema": SCHEMA,
		"player": {"designation": designation, "handle": ""},
		"handler": {"name": handler_name, "kind": KIND_EMPIRE, "former": []},
		"acceptance": {"accepted": false, "handler": "", "handle": "", "launched": false},
		"assignments": [],
	}


## True when the dictionary has the shape the funnel and the handler module read.
static func is_valid(p: Variant) -> bool:
	if typeof(p) != TYPE_DICTIONARY:
		return false
	if int(p.get("schema", -1)) != SCHEMA:
		return false
	var player = p.get("player", null)
	var handler = p.get("handler", null)
	var acc = p.get("acceptance", null)
	if typeof(player) != TYPE_DICTIONARY or typeof(handler) != TYPE_DICTIONARY or typeof(acc) != TYPE_DICTIONARY:
		return false
	if typeof(player.get("designation", null)) != TYPE_STRING or typeof(player.get("handle", null)) != TYPE_STRING:
		return false
	if typeof(handler.get("name", null)) != TYPE_STRING or String(handler.get("kind", "")) != KIND_EMPIRE:
		return false
	if typeof(handler.get("former", null)) != TYPE_ARRAY:
		return false
	if typeof(acc.get("accepted", null)) != TYPE_BOOL or typeof(acc.get("launched", null)) != TYPE_BOOL:
		return false
	if typeof(acc.get("handler", null)) != TYPE_STRING or typeof(acc.get("handle", null)) != TYPE_STRING:
		return false
	return typeof(p.get("assignments", null)) == TYPE_ARRAY and String(player["designation"]).length() > 0 and String(handler["name"]).length() > 0


## {profile, status}: status is "ok", "missing" or "corrupt". A corrupt file has
## already been moved aside when this returns; the profile is then empty.
static func load_profile(path: String = "") -> Dictionary:
	var target := path if not path.is_empty() else PROFILE_FILE
	if not FileAccess.file_exists(target):
		return {"profile": {}, "status": "missing"}
	var f := FileAccess.open(target, FileAccess.READ)
	var text := f.get_as_text() if f != null else ""
	if f != null:
		f.close()
	var parser := JSON.new()
	if f == null or parser.parse(text) != OK or not is_valid(parser.data):
		move_aside(target)
		return {"profile": {}, "status": "corrupt"}
	return {"profile": parser.data, "status": "ok"}


## Atomic save: write <path>.tmp, then rename over <path>.
static func save_profile(profile: Dictionary, path: String = "") -> bool:
	return _write_atomic(profile, path if not path.is_empty() else PROFILE_FILE)


## Keeps a damaged file: <path>.corrupt, or the first free <path>.corrupt<N>.
static func move_aside(path: String) -> String:
	var dest := path + ".corrupt"
	var n := 1
	while FileAccess.file_exists(dest):
		n += 1
		dest = path + ".corrupt" + str(n)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(dest))
	return dest


static func _write_atomic(data: Dictionary, target: String) -> bool:
	var tmp := target + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(target)) == OK


## --- Dossier ------------------------------------------------------------------

static func empty_dossier() -> Dictionary:
	return {"schema": SCHEMA, "fields": {}}


## The stored fields as {name: value}; an absent or damaged file is an empty dossier.
static func load_dossier(path: String = "") -> Dictionary:
	var target := path if not path.is_empty() else DOSSIER_FILE
	var out := empty_dossier()
	if not FileAccess.file_exists(target):
		return out
	var f := FileAccess.open(target, FileAccess.READ)
	if f == null:
		return out
	var text := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(text) != OK or typeof(parser.data) != TYPE_DICTIONARY or typeof(parser.data.get("fields", null)) != TYPE_DICTIONARY:
		return out
	for k in parser.data["fields"]:
		if typeof(parser.data["fields"][k]) == TYPE_STRING:
			out["fields"][String(k)] = String(parser.data["fields"][k])
	return out


static func save_dossier(dossier: Dictionary, path: String = "") -> bool:
	return _write_atomic(dossier, path if not path.is_empty() else DOSSIER_FILE)


## /forget: the file goes away. True when no dossier file remains.
static func wipe_dossier(path: String = "") -> bool:
	var target := path if not path.is_empty() else DOSSIER_FILE
	if FileAccess.file_exists(target):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
	return not FileAccess.file_exists(target)


## One short line: control characters dropped, whitespace collapsed, cut at max_len.
static func clean_value(raw: String, max_len: int) -> String:
	var out := ""
	var last_space := true
	for i in range(raw.length()):
		var c := raw.unicode_at(i)
		if c < 32 or c == 127 or c == 32:
			if not last_space:
				out += " "
				last_space = true
			continue
		out += char(c)
		last_space = false
	out = out.strip_edges()
	if out.length() > max_len:
		out = out.substr(0, max_len).strip_edges()
	return out


## Stores one answer. Only a field named in `cfg.fields` is accepted, the value is
## cut to `cfg.max_value_len`, and the whole file stays within `cfg.max_bytes`.
static func set_field(dossier: Dictionary, field: String, value: String, cfg: Dictionary) -> bool:
	if not (cfg.get("fields", []) as Array).has(field):
		return false
	var v := clean_value(value, int(cfg.get("max_value_len", 60)))
	if v.is_empty():
		return false
	dossier["fields"][field] = v
	var cap := int(cfg.get("max_bytes", 2048))
	while JSON.stringify(dossier).to_utf8_buffer().size() > cap and v.length() > 1:
		v = v.substr(0, v.length() / 2)
		dossier["fields"][field] = v
	return true


## --- HANDLER module helpers (Spec #575) -----------------------------------------------------

## A directory of handler data files that replaces the shipped one (probes only).
const ENV_HANDLER_DIR := "DECOHERENCE_HANDLER_DIR"
const HANDLER_DATA_DIR := "res://frontdoor/data/handler"


static func handler_data_dir() -> String:
	var env := OS.get_environment(ENV_HANDLER_DIR)
	return env if not env.is_empty() else HANDLER_DATA_DIR


static func read_json_file(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var parser := JSON.new()
	return parser.data if parser.parse(text) == OK else null


## {ok, dir, tables, rules, ui, route}: the four data files of the module. `ok` is false when any is missing or damaged.
static func load_handler_data() -> Dictionary:
	var dir := handler_data_dir()
	var out := {"ok": false, "dir": dir, "tables": {}, "rules": {}, "ui": {}, "route": {}}
	var names := {"tables": "colonist_tables.json", "rules": "colonist_rules.json", "ui": "handler_ui.json", "route": "launch_route.json"}
	var good := true
	for k in names:
		var data = read_json_file(dir + "/" + String(names[k]))
		if typeof(data) == TYPE_DICTIONARY:
			out[k] = data
		else:
			good = false
	out["ok"] = good
	return out


## True once the player has accepted the mission (the Launch press). The key is absent until then.
static func mission_accepted(p: Dictionary) -> bool:
	var acc = p.get("acceptance", null)
	return typeof(acc) == TYPE_DICTIONARY and bool(acc.get("mission_accepted", false))
