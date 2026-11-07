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

const MODULES_PATH := "res://frontdoor/data/modules.json"
const DIR_COMMAND := "dir"

enum State { SHELL, CHAT }

var _state: State = State.SHELL
var _terminal: TerminalGrid = null
var _gate_success: bool = false
var _modules: Array = []


## Wires this controller to the shared TerminalGrid and loads the module
## registry. Called once by boot_controller.gd during _ready(), before the
## boot theater begins.
func setup(terminal_grid: TerminalGrid) -> void:
	_terminal = terminal_grid
	_modules = _load_modules()
	if not Signals.terminal_line_submitted.is_connected(_on_terminal_line_submitted):
		Signals.terminal_line_submitted.connect(_on_terminal_line_submitted)


## Called once by boot_controller.gd when the boot theater finishes.
## `gate_success` is the resolved model-ready outcome (_gate_success) --
## the shell itself always comes up regardless (the OS always finishes
## booting to a shell); only launching the chat module honors it.
func enter(gate_success: bool) -> void:
	_gate_success = gate_success
	_state = State.SHELL


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
	var cmd := text.strip_edges().to_lower()
	if cmd == DIR_COMMAND:
		_handle_dir()
	elif _module_id_for(cmd) != "":
		_handle_launch(cmd)
	else:
		_terminal.write_line("COMMAND NOT RECOGNIZED: " + text, Palette.ORANGE)


func _module_id_for(cmd: String) -> String:
	for m in _modules:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var mod_id: String = String(m.get("id", "")).to_lower()
		if mod_id == cmd:
			return mod_id
	return ""


func _handle_dir() -> void:
	_terminal.write_line("DIRECTORY LISTING:", Palette.TEAL)
	for m in _modules:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var label: String = String(m.get("label", m.get("id", ""))).to_upper()
		_terminal.write_line("  " + label, Palette.TEAL)
	_terminal.write_line("%d MODULE(S)" % _modules.size(), Palette.TEAL)


## Launches a module by id. Only "chat" exists today (per spec #371's
## single-module scope) -- any future module would need its own branch
## here. Honors the resolved gate outcome: a failed model-ready link
## produces an honest in-register failure line and stays in the shell,
## never a false success handoff (fold-in of issue #578).
func _handle_launch(cmd: String) -> void:
	if cmd != "chat":
		_terminal.write_line("MODULE NOT YET IMPLEMENTED: " + cmd, Palette.ORANGE)
		return
	if not _gate_success:
		_terminal.write_line("CORTEX LINK FAILED -- CHAT MODULE UNAVAILABLE.", Palette.ORANGE)
		return
	_state = State.CHAT
	Signals.chat_ready.emit()
	Signals.chat_opened.emit()
