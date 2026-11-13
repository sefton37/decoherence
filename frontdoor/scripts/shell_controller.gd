extends Node
class_name ShellController

## Minimal Q-Ent OS shell (Spec #371 / plan-371 §3): BOOT -> SHELL -> CHAT.
## Owns ALL terminal input once boot theater finishes -- the SOLE listener
## on Signals.terminal_line_submitted, and the sole remaining emitter of
## Signals.submit_player_line (its own CHAT-state pass-through, once a
## module has actually been launched). Nothing else may ever call
## Signals.submit_player_line.emit directly (DOD-37 / TRAP-1) --
## boot_controller.gd only ever forwards raw terminal input into
## terminal_line_submitted.
##
## Command grammar (1980s micro-computer register, per Kel's framing):
## `dir` lists the current directory (modules-as-directories, read from
## data/modules.json); typing a module's own id launches it -- mirroring
## "type a program's name to run it" rather than a modern shell verb.
## Anything else renders an in-register unknown-command line.

const WorldModule := preload("res://game/world/world_module.gd")

## Emitted when `world` is launched and the engine is present; boot_controller.gd owns
## the scene layers, so it mounts the world and calls world_closed() when it exits.
signal world_requested

const MODULES_PATH := "res://frontdoor/data/modules.json"
const DIR_COMMAND := "dir"
const DEFAULT_WINDOWED := "1920x1080"

enum State { SHELL, CHAT, WORLD, HANDLER }

const SHELL_CONTEXT_THINK_GLYPH_SEC := 0.15

var _state: State = State.SHELL
var _terminal: TerminalGrid = null
var _gate_success: bool = false
var _modules: Array = []

## --- Spec #519: conversational router ------------------------------------
## Exact commands (dir, help, settings, set <k> <v>, module ids) are resolved
## by a plain table with ZERO LLM requests. Any other free text goes to the
## local model through IntentRouter, which can only select from a closed
## action schema; ShellController alone acts on the validated result.
var _llm: LlmClient = null
var _schema: Dictionary = {}
var _settings: Dictionary = {}
var settings_status: String = "missing"
var _ctx: Dictionary = {}
var _router_cfg: Dictionary = {}
var _prompt_data: Dictionary = {}
var _system_prompt: String = ""
var _decode_grammar: String = ""
var _decode_schema: Dictionary = {}
var _text_cps: float = 160.0

## The windowed `display` value F11 / Alt+Enter returns to (Spec #541 D12).
var _last_windowed: String = DEFAULT_WINDOWED

## Bumped on every submitted line and every state change: a routing result
## whose epoch no longer matches is stale and silently dropped.
var _epoch: int = 0
var stale_drops: int = 0
var _think_active: bool = false
var _think_clock: float = 0.0
var _think_frame: int = 0

## Test hook (probes only): resolve and render routed intents but do not
## perform their state-changing effects.
var router_dry_run: bool = false

## Test hook (probes only): when > 0, overrides the router's request timeout.
var router_timeout_override_ms: int = 0

## Spec #542: the chatroom, which alone decides whether the player may enter the
## world from a chat. Test hook (probes only): world_dry_run counts launches
## without mounting anything.
var _chatroom: Chatroom = null
var world_dry_run: bool = false
var world_request_count: int = 0

## --- Spec #575: the HANDLER module and its launch seam ---------------------------------
## Test hook (probes only): the world reports itself unavailable, as on a machine where
## the engine library was never built.
var world_force_unavailable: bool = false
## Modules opened (the HANDLER module), counted for probes.
var module_open_count: int = 0
## What the last Launch press came to: "" (nothing pressed or ignored), "ok", "unavailable"
## or "unknown_route". The screen reads it back to word its status line.
var last_launch_result: String = ""
## One entry per route hand-off: {route, assignment, accepted_persisted}, for probes.
var route_log: Array = []
## True from a successful hand-off until the world closes: a second press is inert.
var _handoff_latched: bool = false
## Whether the router's module list was built with the HANDLER module in it.
var _router_unlocked: bool = false
var _actions_data: Dictionary = {}

## Details of the most recent resolved line, for probes:
## {source, action, args, reason, say, dispatched, would_dispatch, ms}
var last_route: Dictionary = {}


## Wires this controller to the shared TerminalGrid and loads the module
## registry. Called once by boot_controller.gd during _ready(), before the
## boot theater begins.
func setup(terminal_grid: TerminalGrid, llm: LlmClient = null, chatroom: Chatroom = null) -> void:
	_terminal = terminal_grid
	_llm = llm
	_chatroom = chatroom
	_modules = _load_modules()
	_load_router_data()
	if not Signals.terminal_line_submitted.is_connected(_on_terminal_line_submitted):
		Signals.terminal_line_submitted.connect(_on_terminal_line_submitted)
	if not Signals.chatroom_left.is_connected(_on_chatroom_left):
		Signals.chatroom_left.connect(_on_chatroom_left)
	if not Signals.chatroom_entry_granted.is_connected(_on_entry_granted):
		Signals.chatroom_entry_granted.connect(_on_entry_granted)
	if not Signals.handler_module_closed.is_connected(_on_handler_closed):
		Signals.handler_module_closed.connect(_on_handler_closed)
	if not Signals.handler_launch_requested.is_connected(_on_handler_launch_requested):
		Signals.handler_launch_requested.connect(_on_handler_launch_requested)


## Called once by boot_controller.gd when the boot theater finishes.
## `gate_success` is the resolved model-ready outcome (_gate_success) --
## the shell itself always comes up regardless (the OS always finishes
## booting to a shell); only launching the chat module honors it.
func enter(gate_success: bool) -> void:
	_gate_success = gate_success
	_state = State.SHELL
	_epoch += 1
	_sync_router()
	if settings_status == "corrupt":
		_out("SETTINGS FILE UNREADABLE -- DEFAULTS RESTORED.", Palette.ORANGE)


func _load_modules() -> Array:
	var f := FileAccess.open(MODULES_PATH, FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_ARRAY else []


## Single dispatch point for every keystroke-equivalent line of input --
## a real Enter keypress forwarded by boot_controller.gd, or the tester's
## probe simulating one. While in SHELL state, nothing here can ever reach
## the Handler: the only way submit_player_line is emitted below is the
## CHAT-state pass-through, gated on _state, which only flips inside
## _handle_launch() after a successful launch.
func _on_terminal_line_submitted(text: String) -> void:
	if _state == State.CHAT:
		Signals.submit_player_line.emit(text)
		return
	if _state == State.WORLD or _state == State.HANDLER:
		return  # the world and the HANDLER screen own the keyboard; the terminal is hidden
	# Any new line supersedes a routing call still in flight (stale drop).
	_epoch += 1
	_clear_thinking()
	_sync_router()
	var cmd := text.strip_edges().to_lower()
	if cmd == DIR_COMMAND:
		_fast("list_dir", {})
		_handle_dir()
	elif cmd == "help":
		_fast("help", {})
		_handle_help()
	elif cmd == "settings":
		_fast("show_settings", {})
		_handle_show_settings()
	elif _is_exact_set(cmd):
		_handle_set_command(cmd)
	elif _module_id_for(cmd) != "":
		_fast("open_module", {"module": cmd})
		_handle_launch(cmd)
	else:
		_route(text)


## True only for the typed form: bare `set`, or exactly three words
## `set <key> <value>` (an unknown key or value still gets the typed error
## line). Anything longer that merely starts with "set" ("set the flicker to
## half") is plain language and goes to the router, not to the usage line.
func _is_exact_set(cmd: String) -> bool:
	if cmd == "set":
		return true
	var parts := cmd.split(" ", false)
	return parts.size() == 3 and parts[0] == "set"


func _module_id_for(cmd: String) -> String:
	for m in _visible_modules():
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var mod_id: String = String(m.get("id", "")).to_lower()
		if mod_id == cmd:
			return mod_id
	return ""


func _handle_dir() -> void:
	var visible := _visible_modules()
	_out("DIRECTORY LISTING:", Palette.TEAL)
	for m in visible:
		var label: String = String(m.get("label", m.get("id", ""))).to_upper()
		_out("  " + label, Palette.TEAL)
	_out("%d MODULE(S)" % visible.size(), Palette.TEAL)


## Launches a module by id. "chat" and "world" exist (Specs #371, #501) -- any
## further module needs its own branch here. Honors the resolved gate outcome: a failed model-ready link
## produces an honest in-register failure line and stays in the shell,
## never a false success handoff (fold-in of issue #578).
func _handle_launch(cmd: String) -> void:
	if cmd == "world":
		_launch_world()
		return
	if cmd == "handler":
		_open_handler()
		return
	if cmd != "chat":
		_terminal.write_line("MODULE NOT YET IMPLEMENTED: " + cmd, Palette.ORANGE)
		return
	if not _gate_success:
		_terminal.write_line("CORTEX LINK FAILED -- CHAT MODULE UNAVAILABLE.", Palette.ORANGE)
		return
	_state = State.CHAT
	_epoch += 1
	Signals.chat_ready.emit()
	Signals.chat_opened.emit()


## `world` (Spec #501): degrades to an in-register failure line, never a crash, when the
## Stalag engine library has not been built on this machine. True when the world was
## requested (or counted, under the dry-run hook), false when it is unavailable.
func _launch_world() -> bool:
	world_request_count += 1
	if world_force_unavailable or (not world_dry_run and not WorldModule.available()):
		_terminal.write_line("WORLD ENGINE NOT BUILT -- RUN tools/build_engine.sh.", Palette.ORANGE)
		return false
	if world_dry_run:
		return true
	_state = State.WORLD
	_epoch += 1
	world_requested.emit()
	return true


## The room let the player go: the shell takes the keyboard back.
func _on_chatroom_left() -> void:
	if _state == State.CHAT:
		_state = State.SHELL
		_epoch += 1


## The funnel ended (the signal's name is older than its meaning: it now means entry to
## the HANDLER module). The room's own state is re-checked here, so a stray signal alone
## can never open anything.
func _on_entry_granted() -> void:
	if _state == State.CHAT and _chatroom != null and _chatroom.entry_allowed():
		_open_handler()


## --- Spec #575: the HANDLER module and the launch seam --------------------------------------

## Modules the player can see: one with `locked_until` is absent until the room says so.
func _visible_modules() -> Array:
	var out: Array = []
	for m in _modules:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var lock := String(m.get("locked_until", ""))
		if lock.is_empty() or (lock == "handler_unlocked" and _handler_unlocked()):
			out.append(m)
	return out


func _handler_unlocked() -> bool:
	return _chatroom != null and _chatroom.handler_unlocked()


func visible_module_count() -> int:
	return _visible_modules().size()


## Rebuilds what the router offers when the HANDLER module has unlocked since it was built.
func _sync_router() -> void:
	if _handler_unlocked() != _router_unlocked:
		_build_router_context()


func _build_router_context() -> void:
	var visible := _visible_modules()
	_ctx = IntentRouter.make_context(_actions_data, visible, _schema)
	_decode_schema = IntentRouter.build_schema(_ctx, int(_router_cfg.get("max_say_chars", 120)))
	_decode_grammar = IntentRouter.build_grammar(_ctx, int(_router_cfg.get("max_say_chars", 120)), String(_router_cfg.get("grammar_prefix", "</think>\n\n")))
	_system_prompt = IntentRouter.build_system_prompt(_prompt_data, _actions_data, visible, _schema)
	_router_unlocked = _handler_unlocked()


## Opens the HANDLER module from the shell or from the room: the colonist is made sure of,
## the screen takes the keyboard (the boot controller mounts it on the opened signal).
func _open_handler() -> void:
	if _state != State.SHELL and _state != State.CHAT:
		return
	if _chatroom == null or not _chatroom.handler_unlocked() or not _chatroom.ensure_colonist():
		_out(String(_chatroom.handler_data().get("ui", {}).get("module_unavailable", "")) if _chatroom != null else "", Palette.ORANGE)
		return
	_state = State.HANDLER
	_epoch += 1
	module_open_count += 1
	Signals.handler_module_opened.emit()


## Boot lands in the module for a player who finished the funnel and has not accepted the
## mission yet. True when it opened.
func land_on_boot() -> bool:
	if _state != State.SHELL or not _handler_unlocked() or ProfileStore.mission_accepted(_chatroom.profile_snapshot()):
		return false
	_open_handler()
	return _state == State.HANDLER


func _on_handler_closed() -> void:
	if _state == State.HANDLER:
		_state = State.SHELL
		_epoch += 1


## The Launch press: the acceptance is recorded first, then the named route is entered.
## Ignored unless the module is open, and inert from a successful hand-off until the world closes.
func _on_handler_launch_requested() -> void:
	last_launch_result = ""
	if _state != State.HANDLER or _handoff_latched or not _handler_unlocked():
		return
	var accepted := _chatroom.accept_mission()
	if not bool(accepted["ok"]):
		return
	var route: Variant = ProfileStore.read_json_file(ProfileStore.handler_data_dir() + "/launch_route.json")
	var route_id := String(route.get("route", "")) if typeof(route) == TYPE_DICTIONARY else ""
	enter_route(route_id, String(accepted["assignment_id"]))


## The seam a later spec re-points: the route ids live in launch_route.json, and only the
## ones this shell knows how to enter resolve. An unknown route is refused.
func enter_route(route_id: String, assignment_id: String) -> bool:
	var data = ProfileStore.read_json_file(ProfileStore.handler_data_dir() + "/launch_route.json")
	var routes: Dictionary = data.get("routes", {}) if typeof(data) == TYPE_DICTIONARY else {}
	var persisted := ProfileStore.mission_accepted(_chatroom.profile_snapshot()) if _chatroom != null else false
	route_log.append({"route": route_id, "assignment": assignment_id, "accepted_persisted": persisted})
	if not routes.has(route_id) or typeof(routes[route_id]) != TYPE_DICTIONARY:
		last_launch_result = "unknown_route"
		return false
	if String(routes[route_id].get("kind", "")) == "world":
		if not _launch_world():
			last_launch_result = "unavailable"
			return false
		_handoff_latched = true
		last_launch_result = "ok"
		return true
	last_launch_result = "unknown_route"
	return false


## Characters per second of the typewriter reveal, from the persisted setting.
func text_cps() -> float:
	return _text_cps


## Called by boot_controller.gd when the world has been closed: back to the shell prompt.
func world_closed() -> void:
	_state = State.SHELL
	_handoff_latched = false
	_epoch += 1


## ---------------------------------------------------------------------------
## Spec #519: exact-command handlers, settings, and the conversational router.
## ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _think_active or _terminal == null:
		return
	_think_clock += delta
	if _think_clock >= SHELL_CONTEXT_THINK_GLYPH_SEC:
		_think_clock = 0.0
		_think_frame += 1
		_terminal.set_transient_line(_think_text(), Palette.ORANGE)


func _load_router_data() -> void:
	_schema = SettingsStore.load_schema()
	var loaded := SettingsStore.load_settings(_schema)
	_settings = loaded["settings"]
	settings_status = loaded["status"]
	_text_cps = SettingsStore.text_cps(String(_settings.get("text_speed", "normal")))
	var actions_data = IntentRouter.load_json(IntentRouter.ACTIONS_PATH)
	var cfg = IntentRouter.load_json(IntentRouter.CONFIG_PATH)
	var prompt = IntentRouter.load_json(IntentRouter.PROMPT_PATH)
	_router_cfg = cfg if typeof(cfg) == TYPE_DICTIONARY else {}
	_prompt_data = prompt if typeof(prompt) == TYPE_DICTIONARY else {}
	if typeof(actions_data) != TYPE_DICTIONARY:
		actions_data = {"actions": []}
	_actions_data = actions_data
	_build_router_context()


## The current persisted settings (copy), for boot_controller's initial apply.
func get_settings() -> Dictionary:
	return _settings.duplicate()


func is_shell_state() -> bool:
	return _state == State.SHELL


func current_state_name() -> String:
	return State.keys()[_state]


## Writes one output line honoring text_speed (visual reveal only: the full
## text is still emitted to line_rendered immediately).
func _out(text: String, color) -> void:
	if _text_cps > 0.0:
		_terminal.write_line_typed(text, color, _text_cps)
	else:
		_terminal.write_line(text, color)


func _fast(action: String, args: Dictionary) -> void:
	last_route = {"source": "fast", "action": action, "args": args, "reason": "", "say": "", "dispatched": true, "would_dispatch": true, "ms": 0}
	Signals.intent_resolved.emit("fast", action, args)


func _handle_help() -> void:
	_out("Q-ENT OS COMMANDS:", Palette.TEAL)
	var chips := "[ DIR ]"
	for m in _visible_modules():
		chips += " [ " + String(m.get("label", m.get("id", ""))).to_upper() + " ]"
	chips += " [ SETTINGS ]"
	_out(chips, Palette.TEAL)
	_out("TYPE A COMMAND, OR SAY WHAT YOU WANT IN PLAIN WORDS.", Palette.TEAL)


func _handle_show_settings() -> void:
	_out("SETTINGS:", Palette.TEAL)
	for s in _schema.get("settings", []):
		var key := String(s.get("key", ""))
		_out("  %s = %s   (%s)" % [key.to_upper(), String(_settings.get(key, "")).to_upper(), " ".join(PackedStringArray(s.get("values", []))).to_upper()], Palette.TEAL)
	_out("CHANGE WITH: SET <KEY> <VALUE>", Palette.TEAL)


## `set <key> <value>` typed exactly.
func _handle_set_command(cmd: String) -> void:
	var parts := cmd.split(" ", false)
	if parts.size() != 3:
		_fast("set_setting", {})
		_out("USAGE: SET <KEY> <VALUE>   (TYPE SETTINGS TO SEE THEM)", Palette.ORANGE)
		return
	_fast("set_setting", {"key": parts[1], "value": parts[2]})
	_apply_setting(parts[1], parts[2])


## Validates, applies and persists one setting. Returns true on success.
## `silent` (Spec #541 D12, the F11 / Alt+Enter toggle) skips the terminal line.
func _apply_setting(key: String, value: String, silent: bool = false) -> bool:
	if not SettingsStore.is_valid(_schema, key, value):
		if not silent:
			_out("SETTING NOT RECOGNIZED: %s %s" % [key.to_upper(), value.to_upper()], Palette.ORANGE)
		return false
	_settings[key] = value
	if key == "text_speed":
		_text_cps = SettingsStore.text_cps(value)
	var saved := SettingsStore.save_settings(_settings)
	Signals.setting_changed.emit(key, value)
	if not silent:
		_out("SETTING %s -> %s%s" % [key.to_upper(), value.to_upper(), "" if saved else "  (NOT SAVED)"], Palette.TEAL)
	return true


## F11 / Alt+Enter (Spec #541 D12): flips `display` between fullscreen and the
## last windowed value (default 1920x1080) through the normal settings path --
## validated, persisted, announced on Signals.setting_changed -- but silent.
func toggle_display() -> void:
	var current := String(_settings.get("display", DEFAULT_WINDOWED))
	if current == "fullscreen":
		_apply_setting("display", _last_windowed, true)
	else:
		_last_windowed = current
		_apply_setting("display", "fullscreen", true)


## --- Router path ----------------------------------------------------------

func _think_text() -> String:
	var glyphs = BootAnimator._SPINNER_GLYPHS
	return "%s %s" % [String(_router_cfg.get("thinking_label", "TRANSLATING INTENT")), glyphs[_think_frame % glyphs.size()]]


func _show_thinking() -> void:
	_think_active = true
	_think_clock = 0.0
	_think_frame = 0
	_terminal.set_transient_line(_think_text(), Palette.ORANGE)
	Signals.intent_thinking.emit(true)


func _clear_thinking() -> void:
	if not _think_active:
		return
	_think_active = false
	_terminal.clear_transient_line()
	Signals.intent_thinking.emit(false)


func _unresolved(text: String, offline: bool) -> void:
	_out("COMMAND NOT RECOGNIZED: " + _neutralize_markers(text), Palette.ORANGE)
	var key := "offline_line" if offline else "unclear_line"
	_out(String(_router_cfg.get(key, "TYPE HELP FOR EXACT COMMANDS.")), Palette.ORANGE)


## The legacy echo repeats the player's own words. A pasted reasoning marker
## ("</think>") must never reach the screen looking like system output, so the
## opening angle bracket of a think tag is replaced; all other text is echoed
## unchanged.
func _neutralize_markers(text: String) -> String:
	var out := text
	for marker in ["</think", "<think"]:
		var at := out.to_lower().find(marker)
		while at != -1:
			out = out.substr(0, at) + "[" + out.substr(at + 1)
			at = out.to_lower().find(marker)
	return out


func _route(text: String) -> void:
	var cleaned := IntentRouter.sanitize_input(text, int(_router_cfg.get("max_input_chars", 200)))
	if cleaned.is_empty():
		last_route = {"source": "llm", "action": "unclear", "args": {}, "reason": "empty", "say": "", "dispatched": false, "would_dispatch": false, "ms": 0}
		_unresolved(text, false)
		Signals.intent_resolved.emit("llm", "unclear", {})
		return
	if _llm == null or not _gate_success:
		last_route = {"source": "degraded", "action": "unclear", "args": {}, "reason": "offline", "say": "", "dispatched": false, "would_dispatch": false, "ms": 0}
		_unresolved(text, true)
		Signals.intent_resolved.emit("degraded", "unclear", {})
		return
	var my_epoch := _epoch
	_show_thinking()
	var messages := [
		{"role": "system", "content": _system_prompt},
		{"role": "user", "content": cleaned},
	]
	var options := {
		"grammar": _decode_grammar,
		"schema": _decode_schema,
		"thinking": bool(_router_cfg.get("thinking", false)),
		"temperature": _router_cfg.get("temperature", 0),
		"seed": _router_cfg.get("seed", 0),
		"max_tokens": _router_cfg.get("max_tokens", 96),
		"cache_prompt": _router_cfg.get("cache_prompt", true),
		"timeout_ms": router_timeout_override_ms if router_timeout_override_ms > 0 else _router_cfg.get("timeout_ms", 8000),
	}
	_llm.complete_structured(messages, options, _on_route_done.bind(my_epoch, text))


## Bound method (never a lambda: lambdas capture by value). Arguments after
## `result` are the bound epoch and the original text.
func _on_route_done(result: Dictionary, epoch: int, text: String) -> void:
	if epoch != _epoch or _state != State.SHELL:
		stale_drops += 1
		return
	_clear_thinking()
	if not bool(result.get("ok", false)):
		last_route = {"source": "degraded", "action": "unclear", "args": {}, "reason": String(result.get("error", "")), "say": "", "dispatched": false, "would_dispatch": false, "ms": int(result.get("ms", 0))}
		_unresolved(text, true)
		Signals.intent_resolved.emit("degraded", "unclear", {})
		return
	var verdict := IntentRouter.validate_action(String(result.get("content", "")), _ctx, int(_router_cfg.get("max_say_chars", 120)))
	var action: String = verdict["action"]
	var args: Dictionary = verdict["args"]
	if not bool(verdict["ok"]) or action == "unclear":
		last_route = {"source": "llm", "action": "unclear", "args": {}, "reason": String(verdict["reason"]), "say": "", "dispatched": false, "would_dispatch": false, "ms": int(result.get("ms", 0))}
		_unresolved(text, false)
		Signals.intent_resolved.emit("llm", "unclear", {})
		return
	# Deterministic echo from the VALIDATED action, then the sanitized `say`.
	_out("> " + IntentRouter.echo_for(action, args), Palette.TEAL)
	var cleaned_say := ReplySanitizer.sanitize(String(verdict["say"]), "", int(_router_cfg.get("max_say_chars", 120)))
	var say_line: String = cleaned_say["text"] if bool(cleaned_say["ok"]) else String(_prompt_data.get("fallback_say", {}).get(action, ""))
	if not say_line.is_empty():
		_out(say_line, Palette.TEAL)
	last_route = {"source": "llm", "action": action, "args": args, "reason": "", "say": say_line, "dispatched": not router_dry_run, "would_dispatch": true, "ms": int(result.get("ms", 0))}
	if not router_dry_run:
		_dispatch(action, args)
	Signals.intent_resolved.emit("llm", action, args)


## Executes one validated action. This match is the ONLY place model-chosen
## intent becomes behavior, and every branch is a call to an existing
## handler -- nothing is built from model text.
func _dispatch(action: String, args: Dictionary) -> void:
	match action:
		"open_module":
			_handle_launch(String(args.get("module", "")))
		"list_dir":
			_handle_dir()
		"help":
			_handle_help()
		"show_settings":
			_handle_show_settings()
		"set_setting":
			_apply_setting(String(args.get("key", "")), String(args.get("value", "")))
