extends Control

## Boot-theater driver for the Q-Ent general-purpose operating system
## (Spec #371 / plan-371, extending Spec #370). Reads
## data/boot_sequence.json, formats every stage line's text against this
## machine's REAL hardware facts (HardwareReadout.read_facts(), applied via
## String.format() -- never a hardcoded value in this file), drives each
## stage into the shared TerminalGrid, awaits the real Ollama readiness
## gate at the "model_ready" stage, and triggers the scripted flicker +
## alien-glyph instability beat at the gate's resolution and at the
## Handler's first streamed reply -- never a per-frame randf() call. Once
## the boot theater completes, hands off into the minimal OS shell
## (ShellController) rather than straight into chat -- the shell is the
## sole listener on Signals.terminal_line_submitted and the sole remaining
## emitter of Signals.submit_player_line; this file only ever forwards raw
## terminal input into terminal_line_submitted and must never emit
## submit_player_line directly (DOD-37 / TRAP-1).

const BOOT_SEQUENCE_PATH := "res://data/boot_sequence.json"
const LINE_STAGGER_SEC := 0.12
const SPINNER_TICK_SEC := 0.4
const SPINNER_FRAMES := [".", "..", "...", "...."]

@onready var _terminal: TerminalGrid = $TerminalLayer/TerminalGrid
@onready var _ollama: OllamaClient = $OllamaClient
@onready var _handler: HandlerChat = $HandlerChat
@onready var _shell: ShellController = $ShellController
@onready var _crt_overlay: ColorRect = $CRTLayer/CRTOverlay

var _stages: Array = []

## This machine's real hardware facts, read once at boot via
## HardwareReadout.read_facts() and applied to every stage line's text via
## String.format() -- keeps this machine's literal CPU/GPU/hostname values
## OUT of tracked source (DOD-5/6/7), portable to any player's machine.
var _hw_facts: Dictionary = {}

## Gate-resolution state for _wait_for_model_ready(). Deliberately instance
## member variables, NOT locals captured by a lambda -- GDScript lambdas
## capture enclosing locals BY VALUE at creation time, so a closure
## reassigning a captured local never becomes visible to the awaiting
## function's own copy. Instance fields (mutated via a real bound method,
## _on_model_ready below) do not have this problem.
var _gate_resolved: bool = false
var _gate_success: bool = false


func _ready() -> void:
	_hw_facts = HardwareReadout.read_facts()
	_handler.setup(_terminal, _ollama)
	_shell.setup(_terminal)
	_terminal.set_input_line_active(false)
	_load_boot_sequence()
	_run_boot_sequence()


func _load_boot_sequence() -> void:
	var f := FileAccess.open(BOOT_SEQUENCE_PATH, FileAccess.READ)
	if f == null:
		_stages = []
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	_stages = parsed if typeof(parsed) == TYPE_ARRAY else []


func _run_boot_sequence() -> void:
	for stage in _stages:
		await _run_stage(stage)
	_enter_shell()


func _run_stage(stage: Dictionary) -> void:
	var start_ms := Time.get_ticks_msec()

	if stage.has("ascii_art"):
		_terminal.write_ascii_art(stage["ascii_art"], Palette.TEAL)

	for line in stage.get("lines", []):
		var is_orange: bool = line.get("color", "teal") == "orange"
		var col: Color = Palette.ORANGE if is_orange else Palette.TEAL
		var text: String = String(line.get("text", "")).format(_hw_facts)
		_terminal.write_line(text, col)
		await get_tree().create_timer(LINE_STAGGER_SEC).timeout

	if stage.get("gate", "") == "model_ready":
		await _wait_for_model_ready()

	if stage.get("instability", false):
		_trigger_instability_beat()

	var elapsed: int = Time.get_ticks_msec() - start_ms
	var min_ms: int = stage.get("min_duration_ms", 0)
	if elapsed < min_ms:
		await get_tree().create_timer((min_ms - elapsed) / 1000.0).timeout


## Awaits the real Ollama readiness gate (honest theater -- DOD-14). A
## periodic dot/spinner tick keeps the wait visibly alive rather than
## silently hanging, and the gate's flicker + glyph-corrupt beat fires the
## instant it resolves, whichever way it resolves.
func _wait_for_model_ready() -> void:
	_gate_resolved = false
	_gate_success = false
	_ollama.model_ready.connect(_on_model_ready, CONNECT_ONE_SHOT)
	_ollama.check_model_ready()

	var spinner_index := 0
	while not _gate_resolved:
		_terminal.update_last_line(
			"STANDBY -- CORTEX WARMING " + SPINNER_FRAMES[spinner_index % SPINNER_FRAMES.size()]
		)
		spinner_index += 1
		await get_tree().create_timer(SPINNER_TICK_SEC).timeout

	_terminal.update_last_line(
		"CORTEX WARM -- LINK ESTABLISHED" if _gate_success else "CORTEX LINK FAILED -- RETRY BUDGET EXHAUSTED"
	)
	_trigger_instability_beat()


## Bound method (not a lambda) so it correctly mutates this instance's real
## _gate_resolved/_gate_success fields -- see the note on those fields above.
func _on_model_ready(success: bool) -> void:
	_gate_success = success
	_gate_resolved = true


## The scripted flicker+glyph-corruption narrative beat: a short
## spike-then-decay Tween on the CRT overlay's `flicker` uniform, paired 1:1
## with a TerminalGrid.corrupt_glyph_flash() call -- a single synchronized
## event with two symptoms, never independent noise sources. Called at
## exactly two points (Spec #371 keeps ONE subtle boot-theater beat, tied to
## the honest gate resolution, rather than a second cosmetic flicker): the
## model_ready gate resolving (whichever way it resolves), and the
## Handler's first streamed reply.
func _trigger_instability_beat() -> void:
	_terminal.corrupt_glyph_flash()
	var material: ShaderMaterial = _crt_overlay.material
	if material == null:
		return
	var tween := create_tween()
	tween.tween_property(material, "shader_parameter/flicker", 0.85, 0.05)
	tween.tween_property(material, "shader_parameter/flicker", 0.0, 0.30)


## Boot theater has finished -- hand off into the minimal OS shell rather
## than straight into chat (Spec #371). The shell always comes up
## regardless of _gate_success (the OS always finishes booting to a
## shell); only the chat module's LAUNCH honors the resolved outcome,
## _gate_success, decided inside ShellController itself (plan-371 §2b).
func _enter_shell() -> void:
	_terminal.set_input_line_active(true)
	if not _terminal.line_submitted.is_connected(_on_terminal_line_submitted):
		_terminal.line_submitted.connect(_on_terminal_line_submitted)
	if not Signals.handler_reply_complete.is_connected(_on_first_handler_reply):
		Signals.handler_reply_complete.connect(_on_first_handler_reply, CONNECT_ONE_SHOT)
	_shell.enter(_gate_success)
	Signals.shell_ready.emit()


func _on_first_handler_reply(_text: String) -> void:
	_trigger_instability_beat()


## The SINGLE upstream channel for every keystroke-equivalent line of
## input -- forwards into Signals.terminal_line_submitted only.
## ShellController is the sole listener on that signal and the sole
## remaining emitter of Signals.submit_player_line (its own CHAT-state
## pass-through). This file must NEVER emit Signals.submit_player_line
## directly (DOD-37 / TRAP-1) -- doing so would let a decoy chat-shaped
## line sent during SHELL state reach the Handler behind the shell's back.
func _on_terminal_line_submitted(text: String) -> void:
	Signals.terminal_line_submitted.emit(text)
