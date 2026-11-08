extends Control

## Boot-theater driver for the Q-Ent general-purpose operating system
## (Spec #371/#373, extending Spec #370). Reads data/boot_sequence.json,
## formats every stage line's text against this machine's REAL hardware +
## entanglement facts (HardwareReadout.read_facts() merged with
## EntanglementReadout.read_facts(), applied via String.format() -- never a
## hardcoded value in this file), drives each stage into the shared
## TerminalGrid -- via BootAnimator.animate_line() for any stage carrying an
## `anim_style` key, or a single write_line() call for stages without one --
## awaits the real llama-server readiness gate at the "model_ready" stage,
## and triggers the scripted flicker + alien-glyph instability beat at the
## gate's resolution and at the Handler's first streamed reply -- never a
## per-frame randf() call. Once the boot theater completes, hands off into
## the minimal OS shell (ShellController) rather than straight into chat --
## the shell is the sole listener on Signals.terminal_line_submitted and the
## sole remaining emitter of Signals.submit_player_line; this file only
## ever forwards raw terminal input into terminal_line_submitted and must
## never emit submit_player_line directly (DOD-37 / TRAP-1).
##
## GALLERY mode (Spec #373 / plan-373 SS4), env-gated by
## DECOHERENCE_ANIM_GALLERY=1 and checked first in _ready(), independent of
## DECOHERENCE_PROBE -- a standalone synthetic-content harness (NOT the real
## boot narrative; reusing the real narrative would leak the live system
## clock into DOD-22's two sequential launches and break byte-identity, see
## plan-373 Trap A) that demonstrates each of the 6 registered animation
## styles on 3 fixed sample lines, labeled, then quits cleanly via
## get_tree().quit() so Kel can vote on which style plays where.

const WorldModule := preload("res://game/world/world_module.gd")
const BOOT_SEQUENCE_PATH := "res://frontdoor/data/boot_sequence.json"
const ANIMATION_STYLES_PATH := "res://frontdoor/data/animation_styles.json"
const LINE_STAGGER_SEC := 0.12
const SPINNER_TICK_SEC := 0.4

## Fallback used only if a stage carries an `anim_style` but omits
## `anim_duration_ms` -- every stage this spec ships assigns its own value,
## so this rarely if ever fires in practice.
const DEFAULT_ANIM_DURATION_MS := 1200

## Per-line animation duration for gallery-mode demonstrations. Generous
## relative to the ~90s outer timeout budget (3 samples x 6 styles at this
## duration comfortably clears in well under half that window).
const GALLERY_LINE_DURATION_MS := 1200

## Fixed, synthetic sample lines gallery mode animates -- never real
## hardware/entanglement facts, so two independent gallery runs are
## byte-identical regardless of wall-clock time (DOD-22).
const _GALLERY_SAMPLES := [
	"DEMO LINE ALPHA .............. SAMPLE VALUE ONE",
	"DEMO LINE BRAVO .............. SAMPLE VALUE TWO",
	"DEMO LINE CHARLIE ............ SAMPLE VALUE THREE",
]

@onready var _terminal: TerminalGrid = $TerminalLayer/TerminalGrid
@onready var _llm: LlmClient = $LlmClient
@onready var _handler: HandlerChat = $HandlerChat
@onready var _shell: ShellController = $ShellController
@onready var _crt_overlay: ColorRect = $CRTLayer/CRTOverlay

var _stages: Array = []

## The mounted `world` module (Spec #501), or null while the shell is showing.
var _world: Node = null

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
	if OS.get_environment("DECOHERENCE_ANIM_GALLERY") == "1":
		_terminal.set_input_line_active(false)
		await _run_gallery_sequence()
		get_tree().quit()
		return
	_hw_facts = HardwareReadout.read_facts()
	_hw_facts.merge(EntanglementReadout.read_facts())
	_handler.setup(_terminal, _llm)
	_shell.setup(_terminal)
	_shell.world_requested.connect(_on_world_requested)
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


## Reads data/animation_styles.json (the 6 pinned {id,label} entries) in
## file order -- both the normal boot's per-stage `anim_style` lookup and
## gallery mode's iteration share this one loader.
func _load_animation_styles() -> Array:
	var f := FileAccess.open(ANIMATION_STYLES_PATH, FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_ARRAY else []


func _run_boot_sequence() -> void:
	for stage_index in range(_stages.size()):
		await _run_stage(_stages[stage_index], stage_index)
	_enter_shell()


## `stage_index` feeds BootAnimator's seed formula (stage_index*1000 +
## line_index) -- a pure position function, never a wall-clock read (see
## boot_animator.gd's own determinism contract).
func _run_stage(stage: Dictionary, stage_index: int) -> void:
	var start_ms := Time.get_ticks_msec()

	if stage.has("ascii_art"):
		_terminal.write_ascii_art(stage["ascii_art"], Palette.TEAL)

	var anim_style := String(stage.get("anim_style", ""))
	var anim_duration_ms: int = int(stage.get("anim_duration_ms", DEFAULT_ANIM_DURATION_MS))
	var lines: Array = stage.get("lines", [])

	for line_index in range(lines.size()):
		var line: Dictionary = lines[line_index]
		var is_orange: bool = line.get("color", "teal") == "orange"
		var col: Color = Palette.ORANGE if is_orange else Palette.TEAL
		var text: String = String(line.get("text", "")).format(_hw_facts)
		if anim_style != "":
			var seed_value: int = stage_index * 1000 + line_index
			await BootAnimator.animate_line(get_tree(), _terminal, anim_style, seed_value, text, col, anim_duration_ms)
		else:
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


## GALLERY mode (Spec #373 / plan-373 SS4): demonstrates all 6 registered
## animation styles, labeled, on 3 fixed synthetic sample lines each. Seed
## is style_index*100 + sample_index -- a pure position formula, so two
## independent runs produce byte-identical PROBE_RENDERED transcripts
## (DOD-22).
func _run_gallery_sequence() -> void:
	var styles := _load_animation_styles()
	for style_index in range(styles.size()):
		var style: Dictionary = styles[style_index]
		var label := String(style.get("label", ""))
		var style_id := String(style.get("id", ""))
		_terminal.write_line("STYLE %d/%d: %s" % [style_index + 1, styles.size(), label], Palette.ORANGE)
		for sample_index in range(_GALLERY_SAMPLES.size()):
			var seed_value: int = style_index * 100 + sample_index
			await BootAnimator.animate_line(
				get_tree(), _terminal, style_id, seed_value,
				_GALLERY_SAMPLES[sample_index], Palette.TEAL, GALLERY_LINE_DURATION_MS
			)
	_terminal.write_line("GALLERY COMPLETE", Palette.ORANGE)


## Awaits the real llama-server readiness gate (honest theater -- DOD-14). A
## real, gate-driven progress-bar animation (Spec #375, reusing
## BootAnimator's progress_bar style via indeterminate_bar_frame/
## full_bar_frame -- no 7th style, no forked bar-drawing routine) keeps the
## wait visibly alive: it fills, capped below 100%, once per real poll
## tick, and only reaches a genuinely full bar once the gate has actually
## resolved success -- never on a fixed timer, never on failure. The
## gate's flicker + glyph-corrupt beat still fires the instant it
## resolves, whichever way it resolves.
func _wait_for_model_ready() -> void:
	_gate_resolved = false
	_gate_success = false
	_llm.model_ready.connect(_on_model_ready, CONNECT_ONE_SHOT)
	_llm.check_model_ready()

	var tick_index := 0
	while not _gate_resolved:
		_terminal.update_last_line(
			BootAnimator.indeterminate_bar_frame("STANDBY -- CORTEX WARMING", tick_index)
		)
		tick_index += 1
		await get_tree().create_timer(SPINNER_TICK_SEC).timeout

	if _gate_success:
		_terminal.update_last_line(BootAnimator.full_bar_frame("STANDBY -- CORTEX WARMING"))

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


## `world` was launched (Spec #501): hide the terminal layer, mount the 3D world in its
## place and hand it the keyboard. The CRT overlay layer stays on top, as everywhere.
func _on_world_requested() -> void:
	_world = WorldModule.instantiate_world()
	if _world == null:
		_terminal.write_line("WORLD ENGINE NOT BUILT -- RUN tools/build_engine.sh.", Palette.ORANGE)
		_shell.world_closed()
		return
	_terminal.set_input_line_active(false)
	_terminal.get_parent().visible = false
	add_child(_world)
	_world.exited.connect(_on_world_exited)


func _on_world_exited() -> void:
	if _world != null:
		remove_child(_world)
		_world.queue_free()
		_world = null
	_terminal.get_parent().visible = true
	_terminal.set_input_line_active(true)
	_terminal.write_line("WORLD CLOSED.", Palette.TEAL)
	_shell.world_closed()
