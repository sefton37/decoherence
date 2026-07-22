extends Control

## Boot-theater driver for the Q-Ent Phase 0 experience (Spec #370 /
## plan-370). Reads data/boot_sequence.json, drives each stage into the
## shared TerminalGrid, awaits the real Ollama readiness gate at the
## "model_ready" stage, and triggers the scripted flicker + alien-glyph
## instability beats at exactly three named narrative points -- never a
## per-frame randf() call. Once the sequence completes, activates the
## input line, wires it to the Signals bus, and emits Signals.chat_ready.

const BOOT_SEQUENCE_PATH := "res://data/boot_sequence.json"
const LINE_STAGGER_SEC := 0.12
const SPINNER_TICK_SEC := 0.4
const SPINNER_FRAMES := [".", "..", "...", "...."]

@onready var _terminal: TerminalGrid = $TerminalLayer/TerminalGrid
@onready var _ollama: OllamaClient = $OllamaClient
@onready var _handler: HandlerChat = $HandlerChat
@onready var _crt_overlay: ColorRect = $CRTLayer/CRTOverlay

var _stages: Array = []

## Gate-resolution state for _wait_for_model_ready(). Deliberately instance
## member variables, NOT locals captured by a lambda -- GDScript lambdas
## capture enclosing locals BY VALUE at creation time, so a closure
## reassigning a captured local never becomes visible to the awaiting
## function's own copy. Instance fields (mutated via a real bound method,
## _on_model_ready below) do not have this problem.
var _gate_resolved: bool = false
var _gate_success: bool = false


func _ready() -> void:
	_handler.setup(_terminal, _ollama)
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
	_activate_chat_handoff()


func _run_stage(stage: Dictionary) -> void:
	var start_ms := Time.get_ticks_msec()

	if stage.has("ascii_art"):
		_terminal.write_ascii_art(stage["ascii_art"], Palette.TEAL)

	for line in stage.get("lines", []):
		var is_orange: bool = line.get("color", "teal") == "orange"
		var col: Color = Palette.ORANGE if is_orange else Palette.TEAL
		_terminal.write_line(line.get("text", ""), col)
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
## exactly three points: the model_ready gate resolving, the
## instability_hint stage, and the Handler's first streamed reply.
func _trigger_instability_beat() -> void:
	_terminal.corrupt_glyph_flash()
	var material: ShaderMaterial = _crt_overlay.material
	if material == null:
		return
	var tween := create_tween()
	tween.tween_property(material, "shader_parameter/flicker", 0.85, 0.05)
	tween.tween_property(material, "shader_parameter/flicker", 0.0, 0.30)


func _activate_chat_handoff() -> void:
	_terminal.set_input_line_active(true)
	if not _terminal.line_submitted.is_connected(_on_terminal_line_submitted):
		_terminal.line_submitted.connect(_on_terminal_line_submitted)
	if not Signals.handler_reply_complete.is_connected(_on_first_handler_reply):
		Signals.handler_reply_complete.connect(_on_first_handler_reply, CONNECT_ONE_SHOT)
	Signals.chat_ready.emit()


func _on_first_handler_reply(_text: String) -> void:
	_trigger_instability_beat()


func _on_terminal_line_submitted(text: String) -> void:
	Signals.submit_player_line.emit(text)
