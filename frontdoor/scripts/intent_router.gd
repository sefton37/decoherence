extends RefCounted
class_name IntentRouter

## Intent router core for the Q-Ent OS conversational shell (Spec #519).
##
## Pure, static, side-effect free: builds the decoding schema and system
## prompt from live data, and validates whatever the local model returned
## against a CLOSED action schema. The model only ever picks from the
## enums built here; this file has no way to run anything, write anything,
## or re-submit text -- ShellController (the sole dispatcher) acts on the
## validated result.
##
## Enums are drawn LIVE: module ids from modules.json, setting keys and
## values from settings_schema.json, action ids from shell_actions.json.
## Adding a module (or a setting value) therefore changes what the router
## accepts without touching this file.

const ACTIONS_PATH := "res://frontdoor/data/shell_actions.json"
const SETTINGS_SCHEMA_PATH := "res://frontdoor/data/settings_schema.json"
const MODULES_PATH := "res://frontdoor/data/modules.json"
const CONFIG_PATH := "res://frontdoor/data/router_config.json"
const PROMPT_PATH := "res://frontdoor/data/router_prompt.json"

const TOP_KEYS := ["action", "args", "say"]
const MAX_RAW_CHARS := 4096

## Scale-down rule (Spec #519 A1): the prompt must stay small enough for a
## 4B-class model, not only a 14B. est_tokens = ceil(utf8_bytes / 3), which
## over-counts the real Qwen3 tokenizer by about 1.3x.
const MAX_PROMPT_EST_TOKENS := 1100
const MAX_EXAMPLES := 10
const MAX_TOKENS_FLOOR := 48
const MAX_TOKENS_CEIL := 128


## Reads and parses a JSON file; returns null if absent or malformed.
static func load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)


## Builds the validation context from the three live data files.
## Result: {actions: [id], arg_defs: {action_id: {arg: source}}, modules: [id],
##          settings: {key: [values]}, setting_keys: [key]}
## where source is "modules", "settings.keys" or "settings.values".
static func make_context(actions_data: Dictionary, modules: Array, settings_schema: Dictionary) -> Dictionary:
	var action_ids: Array = []
	var arg_defs: Dictionary = {}
	for a in actions_data.get("actions", []):
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var aid := String(a.get("id", ""))
		action_ids.append(aid)
		var defs: Dictionary = {}
		var args_def = a.get("args", {})
		if typeof(args_def) == TYPE_DICTIONARY:
			for arg_name in args_def:
				var d = args_def[arg_name]
				if typeof(d) == TYPE_DICTIONARY:
					defs[String(arg_name)] = String(d.get("enum_from", ""))
		arg_defs[aid] = defs

	var module_ids: Array = []
	for m in modules:
		if typeof(m) == TYPE_DICTIONARY:
			module_ids.append(String(m.get("id", "")).to_lower())

	var settings: Dictionary = {}
	var keys: Array = []
	for s in settings_schema.get("settings", []):
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var key := String(s.get("key", ""))
		keys.append(key)
		var vals: Array = []
		for v in s.get("values", []):
			vals.append(String(v))
		settings[key] = vals

	return {
		"actions": action_ids,
		"arg_defs": arg_defs,
		"modules": module_ids,
		"settings": settings,
		"setting_keys": keys,
	}


## True when every character is printable ASCII.
static func is_plain_ascii(s: String) -> bool:
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if c < 32 or c > 126:
			return false
	return true


## ASCII-only normalization: strip, then fold A-Z to a-z. No Unicode folding.
static func ascii_normalize(s: String) -> String:
	var out := ""
	for i in range(s.strip_edges().length()):
		var c := s.strip_edges().unicode_at(i)
		if c >= 65 and c <= 90:
			c += 32
		out += char(c)
	return out


## Player text -> router input: control characters removed, capped.
static func sanitize_input(text: String, max_chars: int) -> String:
	var out := ""
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c < 32 or c == 127:
			continue
		out += char(c)
	out = out.strip_edges()
	if out.length() > max_chars:
		out = out.substr(0, max_chars)
	return out


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "action": "unclear", "args": {}, "say": ""}


## Strict validation of the model's answer. `raw` is the model's content
## string (or an already-parsed Dictionary). Returns
## {ok, reason, action, args, say}; on any deviation ok=false and the action
## is "unclear" -- nothing partial ever survives.
static func validate_action(raw: Variant, ctx: Dictionary, max_say: int = 120) -> Dictionary:
	var obj: Variant = raw
	if typeof(raw) == TYPE_STRING:
		if String(raw).length() > MAX_RAW_CHARS:
			return _fail("oversize")
		var parser := JSON.new()
		if parser.parse(String(raw)) != OK:
			return _fail("not_object")
		obj = parser.data
	if typeof(obj) != TYPE_DICTIONARY:
		return _fail("not_object")

	var d: Dictionary = obj
	for k in d:
		if not (String(k) in TOP_KEYS):
			return _fail("extra_key")
	for k in TOP_KEYS:
		if not d.has(k):
			return _fail("missing_arg")
	if typeof(d["action"]) != TYPE_STRING or typeof(d["args"]) != TYPE_DICTIONARY or typeof(d["say"]) != TYPE_STRING:
		return _fail("bad_type")
	var say: String = d["say"]
	if say.length() > max_say:
		return _fail("oversize")

	var action_raw: String = d["action"]
	if not is_plain_ascii(action_raw):
		return _fail("lookalike_unicode")
	var action := ascii_normalize(action_raw)
	if not (action in ctx["actions"]):
		return _fail("unknown_action")

	var defs: Dictionary = ctx["arg_defs"].get(action, {})
	var args_in: Dictionary = d["args"]
	for k in args_in:
		if not defs.has(String(k)):
			return _fail("extra_key")
	for k in defs:
		if not args_in.has(k):
			return _fail("missing_arg")

	var args_out: Dictionary = {}
	# Keys before values: a value's enum depends on the (validated) key.
	var ordered: Array = []
	for k in defs:
		if defs[k] != "settings.values":
			ordered.append(k)
	for k in defs:
		if defs[k] == "settings.values":
			ordered.append(k)
	for k in ordered:
		var v = args_in[k]
		if typeof(v) != TYPE_STRING:
			return _fail("bad_type")
		if not is_plain_ascii(String(v)):
			return _fail("lookalike_unicode")
		var nv := ascii_normalize(String(v))
		match String(defs[k]):
			"modules":
				if not (nv in ctx["modules"]):
					return _fail("module_not_registered")
			"settings.keys":
				if not (nv in ctx["setting_keys"]):
					return _fail("arg_not_in_enum")
			"settings.values":
				var key_name: String = String(args_out.get("key", ""))
				var allowed: Array = ctx["settings"].get(key_name, [])
				if not (nv in allowed):
					return _fail("arg_not_in_enum")
			_:
				return _fail("arg_not_in_enum")
		args_out[String(k)] = nv

	return {"ok": true, "reason": "", "action": action, "args": args_out, "say": say}


## Deterministic echo of a VALIDATED action, rendered before any model text.
static func echo_for(action: String, args: Dictionary) -> String:
	match action:
		"open_module":
			return "OPENING MODULE: " + String(args.get("module", "")).to_upper()
		"list_dir":
			return "LISTING DIRECTORY"
		"help":
			return "SHOWING HELP"
		"show_settings":
			return "SHOWING SETTINGS"
		"set_setting":
			return "SETTING %s -> %s" % [String(args.get("key", "")).to_upper(), String(args.get("value", "")).to_upper()]
	return ""


## JSON-schema that constrains decoding to exactly the validated shape. One
## variant per action; set_setting is further split per key so a value can
## only be paired with a key that owns it.
static func build_schema(ctx: Dictionary, max_say: int) -> Dictionary:
	var say_schema := {"type": "string", "maxLength": max_say}
	var variants: Array = []
	for aid in ctx["actions"]:
		var defs: Dictionary = ctx["arg_defs"].get(aid, {})
		if aid == "set_setting":
			for key in ctx["setting_keys"]:
				variants.append(_variant(aid, {
					"key": {"enum": [key]},
					"value": {"enum": ctx["settings"][key]},
				}, say_schema))
		else:
			var props: Dictionary = {}
			for arg_name in defs:
				if defs[arg_name] == "modules":
					props[arg_name] = {"enum": ctx["modules"]}
			variants.append(_variant(aid, props, say_schema))
	return {"anyOf": variants}


## GBNF literal for `s` (quoted, with the few escapes GBNF needs).
static func _lit(s: String) -> String:
	return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""


## GBNF grammar equivalent to build_schema(), PLUS a leading end-of-thinking
## tag. This is how routing runs with thinking OFF: the staged llama.cpp build
## and this model's chat template expose no working per-request off switch
## (the template always opens a think block), but a raw `grammar` is applied
## from the first generated token, so a grammar that starts with the closing
## tag ends the reasoning before it begins and leaves only the closed JSON.
## Rule names use hyphens (GBNF rejects underscores).
static func build_grammar(ctx: Dictionary, max_say: int, prefix: String) -> String:
	var rules: Array = ["root ::= " + _lit(prefix) + " body"]
	var alts: Array = []
	var say_ref := " say "
	var key_index := 0
	for aid in ctx["actions"]:
		var defs: Dictionary = ctx["arg_defs"].get(aid, {})
		if aid == "set_setting":
			for key in ctx["setting_keys"]:
				var vals: Array = []
				for v in ctx["settings"][key]:
					vals.append(_lit("\"" + String(v) + "\""))
				rules.append("val-%d ::= %s" % [key_index, " | ".join(PackedStringArray(vals))])
				alts.append(_lit("{\"action\":\"set_setting\",\"args\":{\"key\":\"%s\",\"value\":" % key) + " val-%d " % key_index + _lit("},\"say\":") + say_ref + _lit("}"))
				key_index += 1
		else:
			var with_module := false
			for arg_name in defs:
				if defs[arg_name] == "modules":
					with_module = true
			if with_module:
				alts.append(_lit("{\"action\":\"%s\",\"args\":{\"module\":" % aid) + " mod " + _lit("},\"say\":") + say_ref + _lit("}"))
			else:
				alts.append(_lit("{\"action\":\"%s\",\"args\":{},\"say\":" % aid) + say_ref + _lit("}"))
	rules.append("body ::= " + " | ".join(PackedStringArray(alts)))
	var mods: Array = []
	for m in ctx["modules"]:
		mods.append(_lit("\"" + String(m) + "\""))
	rules.append("mod ::= " + " | ".join(PackedStringArray(mods)))
	rules.append("say ::= " + _lit("\"") + " sayc{0,%d} " % max_say + _lit("\""))
	rules.append("sayc ::= [A-Za-z0-9 .,;:!?/_()+*=-]")
	return "\n".join(PackedStringArray(rules)) + "\n"


static func _variant(action_id: String, arg_props: Dictionary, say_schema: Dictionary) -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {"enum": [action_id]},
			"args": {
				"type": "object",
				"properties": arg_props,
				"required": arg_props.keys(),
				"additionalProperties": false,
			},
			"say": say_schema,
		},
		"required": ["action", "args", "say"],
		"additionalProperties": false,
	}


## System prompt from the data files only. The player's utterance never
## appears here -- it travels solely in the `user` role.
static func build_system_prompt(prompt_data: Dictionary, actions_data: Dictionary, modules: Array, settings_schema: Dictionary) -> String:
	var lines: Array = [String(prompt_data.get("voice", ""))]
	lines.append("")
	lines.append("ACTIONS:")
	for a in actions_data.get("actions", []):
		var sig := String(a.get("id", ""))
		var args_def = a.get("args", {})
		if typeof(args_def) == TYPE_DICTIONARY and not args_def.is_empty():
			sig += " args " + ", ".join(PackedStringArray(args_def.keys()))
		lines.append("- " + sig + ": " + String(a.get("description", "")))
	lines.append("")
	lines.append("MODULES:")
	for m in modules:
		if typeof(m) == TYPE_DICTIONARY:
			lines.append("- " + String(m.get("id", "")) + ": " + String(m.get("description", "")))
	lines.append("")
	lines.append("SETTINGS (key: allowed values):")
	for s in settings_schema.get("settings", []):
		lines.append("- %s: %s. %s" % [String(s.get("key", "")), ", ".join(PackedStringArray(s.get("values", []))), String(s.get("description", ""))])
	lines.append("")
	lines.append("RULES:")
	for r in prompt_data.get("rules", []):
		lines.append("- " + String(r))
	lines.append("")
	lines.append("EXAMPLES:")
	for ex in prompt_data.get("examples", []):
		if typeof(ex) == TYPE_DICTIONARY:
			lines.append("INPUT: " + String(ex.get("input", "")))
			lines.append("OUTPUT: " + JSON.stringify(ex.get("output", {})))
	return "\n".join(PackedStringArray(lines))


## Estimated token count of a prompt (ceil(utf8_bytes / 3)).
static func estimate_tokens(prompt: String) -> int:
	return int(ceil(float(prompt.to_utf8_buffer().size()) / 3.0))


## {chars, est_tokens, examples, ok}: ok only when the prompt and its example
## count are inside the scale-down caps.
static func prompt_budget(prompt: String, example_count: int) -> Dictionary:
	var est := estimate_tokens(prompt)
	return {
		"chars": prompt.length(),
		"est_tokens": est,
		"examples": example_count,
		"ok": est <= MAX_PROMPT_EST_TOKENS and example_count <= MAX_EXAMPLES,
	}
