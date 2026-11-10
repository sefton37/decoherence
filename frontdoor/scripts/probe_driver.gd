extends Node
## Automated end-to-end readiness probe (Spec #371 / plan-371, tester-owned
## harness -- the implementer must not modify this file's gating or
## output-format contract). Rewritten for the Phase 0b flow: the app now
## boots into a minimal OS shell before chat, and chat must be discovered
## and launched by whatever drives the terminal -- so this probe drives
## BOOT -> SHELL -> CHAT exclusively through the global Signals bus,
## exactly the same send-path a real player's Enter keypress uses. It
## never reaches into the scene tree directly and there is no `--scene`
## bypass.
##
## Completely inert unless the environment variable DECOHERENCE_PROBE=1 is
## set. A real player launch (no env vars set) never instantiates any of
## this node's behavior beyond the no-op early return in _ready().
##
## Two independent sequences, selected once at _ready():
##   - Normal (success) path -- boot -> shell_ready -> decoy quiet-check ->
##     dir -> launch chat -> real message -> Handler reply -> screenshot.
##   - Force-fail path (DECOHERENCE_FORCE_GATE_FAIL=1) -- a REDUCED
##     sequence that never attempts dir/launch/chat at all; it only
##     listens for the honest gate-failure line to render and confirms the
##     success line never leaks, then quits under its own short watchdog.

## The real message sent once the chat module is launched -- the final,
## live round trip through the Handler. Printed length is always computed
## from the actual reply text (never a literal constant), so this file can
## never satisfy its own fabrication guard (DOD-30-equivalent) by accident.
const PROBE_MESSAGE := "Hello, this is an automated readiness probe."

## A chat-shaped line sent DURING the shell phase, before any launch
## command -- deliberately NOT "dir" and NOT the launch command, so it can
## only ever reach the Handler if the shell's dir/launch gate is purely
## cosmetic (the exact adversarial defect DOD-32's PROBE_PRELAUNCH_QUIET
## sub-check exists to catch).
const DECOY_MESSAGE := "Hello? Is this thing on?"

## Shell command grammar, pinned by the implementer's plan (bare module
## name to launch, mirroring 1980s micro-computer register).
const DIR_COMMAND := "dir"
const LAUNCH_COMMAND := "chat"

## How long the decoy must sit unanswered before the probe trusts the
## dir/launch gate is real and prints PROBE_PRELAUNCH_QUIET. Bounded, not
## a race: exactly one Timer, connected/disconnected explicitly around the
## window so it can never fire twice or leak into the later real-message
## wait.
const PRELAUNCH_QUIET_WINDOW_SEC := 4.0

## Comfortably inside the stored DOD-15 check's outer `timeout 300` (raised
## from #371's `timeout 260` per plan-373 §3 -- the new entanglement stage +
## per-line animation frames add real wall-clock time) so this node's own
## watchdog is the normal exit path on the success side, not the harness's
## SIGTERM (which would risk an orphaned Godot process / a window left open
## on Kel's real X11 session). Bumped 180.0 -> 240.0 (tester, Spec #373
## Phase 1); still 60s inside the 300s outer timeout, pre-emptive pending
## the first real DOD-15 measurement per plan-373 §3/Unknowns.
const WATCHDOG_SECONDS := 240.0

## The force-fail path never waits on a real LLM round trip -- it only
## needs to observe one rendered line. Deliberately SHORT and well inside
## DOD-33's outer `timeout 120`: if this constant were ever raised to (or
## reused as) WATCHDOG_SECONDS above, a force-fail run would be
## harness-SIGKILLed before it could exit gracefully (see plan-371 Risks).
const FORCE_FAIL_WATCHDOG_SECONDS := 30.0

## Grace period after the honest failure line is observed, before the
## force-fail path finishes -- gives one last chance for a stray success
## line to leak in before this file asserts SUCCESS_LEAK is absent.
const FORCE_FAIL_GRACE_SEC := 2.0

## Pinned literal print prefix (DOD-25). Load-bearing per spec #371 §4:
## without this scoping, a bare-stdout grep for the GPU/hostname string is
## vacuously satisfied by Godot's own Vulkan-device-selection boilerplate
## log line, independent of any app code.
const PROBE_RENDERED_PREFIX := "PROBE_RENDERED: "

var _watchdog: Timer
var _quiet_timer: Timer
var _grace_timer: Timer
var _screenshot_path: String = ""
var _finished := false
var _force_fail_mode := false

## Content tracking for the dir-listing content assertion (DOD-32
## DIR_OK): true once a line_rendered payload containing "CHAT" (ci) has
## been observed AFTER the dir command was sent.
var _dir_sent := false
var _dir_confirmed := false

## Quiet-window bookkeeping for PROBE_PRELAUNCH_QUIET.
var _quiet_window_active := false
var _quiet_window_leaked := false

## Force-fail bookkeeping.
var _force_fail_saw_failure := false
var _force_fail_saw_leak := false

## --- World mode (Spec #501): DECOHERENCE_PROBE=1 + DECOHERENCE_PROBE_MODE=world drives
## BOOT -> SHELL -> `dir` -> `world` -> walk-scene up -> screenshot -> exit -> shell still
## alive -> unknown module rejected. The default (chat) path above is untouched.
const WORLD_COMMAND := "world"
const UNKNOWN_COMMAND := "xyzzy_no_such_module"
const WORLD_MIN_CHUNKS := 9
var _world_mode := false
var _world_step := ""  # dir | launch | in_world | exit_dir | exit_unknown | done
var _world_settle_frames := 0


func _ready() -> void:
	if OS.get_environment("DECOHERENCE_PROBE") != "1":
		return
	_screenshot_path = OS.get_environment("DECOHERENCE_PROBE_SCREENSHOT")
	_force_fail_mode = OS.get_environment("DECOHERENCE_FORCE_GATE_FAIL") == "1"

	# Echoing every rendered line is unconditional and starts immediately --
	# it must catch boot-stage hardware-readout lines too, long before
	# shell_ready ever fires.
	Signals.line_rendered.connect(_on_line_rendered)

	var ext := OS.get_environment("DECOHERENCE_PROBE_MODE")
	if ext in EXT_MODES:
		_ext_mode = ext
		_start_ext_watchdog()
		_run_ext.call_deferred()
		return

	if OS.get_environment("DECOHERENCE_PROBE_MODE") == "world":
		_world_mode = true
		_start_normal_watchdog()
		Signals.shell_ready.connect(_on_world_shell_ready, CONNECT_ONE_SHOT)
		return

	if _force_fail_mode:
		_start_force_fail_watchdog()
		return

	_start_normal_watchdog()
	Signals.shell_ready.connect(_on_shell_ready, CONNECT_ONE_SHOT)


## --- Rendered-line echo (both paths) -----------------------------------

func _on_line_rendered(text: String) -> void:
	print(PROBE_RENDERED_PREFIX + text)

	if _ext_mode != "":
		_ext_rendered.append(text)
		if _ext_first_line_ms < 0:
			_ext_first_line_ms = Time.get_ticks_msec()
		return

	if _world_mode:
		_world_on_line(text)
		return

	if _force_fail_mode:
		if text.findn("CORTEX LINK FAILED") != -1:
			_on_force_fail_observed()
		if text.findn("CORTEX WARM -- LINK ESTABLISHED") != -1:
			_force_fail_saw_leak = true
		return

	if _dir_sent and not _dir_confirmed and text.findn("CHAT") != -1:
		_dir_confirmed = true
		print("PROBE_DIR_OK")
		_launch_chat()


## --- Normal (success) path ----------------------------------------------

func _start_normal_watchdog() -> void:
	_watchdog = Timer.new()
	_watchdog.one_shot = true
	_watchdog.wait_time = WATCHDOG_SECONDS
	add_child(_watchdog)
	_watchdog.timeout.connect(_on_watchdog_timeout)
	_watchdog.start()


## Fires once the real boot theater completes and the shell is live and
## accepting `dir`/module-name input. Immediately starts the
## PROBE_PRELAUNCH_QUIET check by sending a decoy chat-shaped line before
## ever sending `dir` -- proving the gate is real, not decorative, before
## exercising it.
func _on_shell_ready() -> void:
	if _finished:
		return
	Signals.handler_reply_complete.connect(_on_quiet_window_leak, CONNECT_ONE_SHOT)
	_quiet_window_active = true
	_quiet_window_leaked = false
	Signals.terminal_line_submitted.emit(DECOY_MESSAGE)

	_quiet_timer = Timer.new()
	_quiet_timer.one_shot = true
	_quiet_timer.wait_time = PRELAUNCH_QUIET_WINDOW_SEC
	add_child(_quiet_timer)
	_quiet_timer.timeout.connect(_on_quiet_window_elapsed)
	_quiet_timer.start()


## Only ever connected during the quiet window (CONNECT_ONE_SHOT); if this
## fires, the decoy reached the Handler and the shell's dir/launch gate is
## cosmetic -- the exact defect DOD-32's QUIET_OK sub-check exists to
## catch. Per plan-371 §5, no special-casing is needed here beyond simply
## never printing the marker below.
func _on_quiet_window_leak(_text: String) -> void:
	_quiet_window_leaked = true


func _on_quiet_window_elapsed() -> void:
	if _finished:
		return
	_quiet_window_active = false
	if Signals.handler_reply_complete.is_connected(_on_quiet_window_leak):
		Signals.handler_reply_complete.disconnect(_on_quiet_window_leak)
	if not _quiet_window_leaked:
		print("PROBE_PRELAUNCH_QUIET")
	_send_dir()


func _send_dir() -> void:
	if _finished:
		return
	_dir_sent = true
	Signals.terminal_line_submitted.emit(DIR_COMMAND)


## Only called once the dir listing has been confirmed (via
## _on_line_rendered above) to actually contain the chat module -- a
## genuine content assertion gates the launch, not a fixed delay.
func _launch_chat() -> void:
	if _finished:
		return
	Signals.chat_opened.connect(_on_chat_opened, CONNECT_ONE_SHOT)
	Signals.terminal_line_submitted.emit(LAUNCH_COMMAND)


## Fires once the shell hands off control to the real Handler chatroom.
func _on_chat_opened() -> void:
	if _finished:
		return
	print("PROBE_LAUNCH_OK")
	Signals.handler_reply_complete.connect(_on_handler_reply_complete, CONNECT_ONE_SHOT)
	Signals.terminal_line_submitted.emit(PROBE_MESSAGE)


## Fires once the Handler's streamed reply to the real message has fully
## arrived. `text` is the real accumulated reply -- the printed length is
## always computed from it, never a literal constant.
func _on_handler_reply_complete(text: String) -> void:
	if _finished:
		return
	_finished = true
	_watchdog.stop()
	var reply_len: int = text.length()
	print("PROBE_OK reply_len=%d" % reply_len)
	_save_screenshot()
	get_tree().quit()


## Self-termination path: if boot/shell/chat never completes
## (implementation missing, LLM server unreachable, a hang), force-quit and
## report loudly rather than relying solely on the outer harness's
## SIGTERM.
func _on_watchdog_timeout() -> void:
	if _finished:
		return
	_finished = true
	print("PROBE_TIMEOUT")
	_save_screenshot()
	get_tree().quit()


## --- Force-fail path -----------------------------------------------------

func _start_force_fail_watchdog() -> void:
	_watchdog = Timer.new()
	_watchdog.one_shot = true
	_watchdog.wait_time = FORCE_FAIL_WATCHDOG_SECONDS
	add_child(_watchdog)
	_watchdog.timeout.connect(_on_force_fail_watchdog_timeout)
	_watchdog.start()


## Called from _on_line_rendered() the first time the honest gate-failure
## line renders. Starts a short grace period (rather than quitting
## immediately) so a stray success-line leak arriving one line later would
## still be observed before this file asserts SUCCESS_LEAK is absent.
func _on_force_fail_observed() -> void:
	if _finished or _force_fail_saw_failure:
		return
	_force_fail_saw_failure = true
	_grace_timer = Timer.new()
	_grace_timer.one_shot = true
	_grace_timer.wait_time = FORCE_FAIL_GRACE_SEC
	add_child(_grace_timer)
	_grace_timer.timeout.connect(_on_force_fail_grace_elapsed)
	_grace_timer.start()


func _on_force_fail_grace_elapsed() -> void:
	_finish_force_fail()


func _on_force_fail_watchdog_timeout() -> void:
	_finish_force_fail()


## Single exit point for the force-fail path -- reachable either via the
## post-observation grace timer or the outer watchdog (if the failure line
## never rendered at all, e.g. the force-fail hook itself is missing).
## Prints one of three mutually exclusive, distinct completion markers so
## a transcript reader never has to infer which branch fired.
func _finish_force_fail() -> void:
	if _finished:
		return
	_finished = true
	_watchdog.stop()
	if _force_fail_saw_leak:
		print("PROBE_FORCE_FAIL_LEAK")
	elif _force_fail_saw_failure:
		print("PROBE_FORCE_FAIL_OK")
	else:
		print("PROBE_FORCE_FAIL_TIMEOUT")
	_save_screenshot()
	get_tree().quit()


func _save_screenshot() -> void:
	if _screenshot_path.is_empty():
		return
	var img := get_viewport().get_texture().get_image()
	img.save_png(_screenshot_path)


## --- World mode (Spec #501) ----------------------------------------------

func _on_world_shell_ready() -> void:
	_world_step = "dir"
	Signals.terminal_line_submitted.emit(DIR_COMMAND)


func _world_on_line(text: String) -> void:
	if _world_step == "dir" and text.findn("WORLD") != -1 and text.findn("COMMAND") == -1:
		print("PROBE_WORLD_LISTED")
		_world_step = "launch"
		Signals.terminal_line_submitted.emit(WORLD_COMMAND)
	elif _world_step == "exit_dir" and text.findn("DIRECTORY LISTING") != -1:
		print("PROBE_WORLD_EXITED shell_alive=1")
		_world_step = "exit_unknown"
		Signals.terminal_line_submitted.emit(UNKNOWN_COMMAND)
	elif _world_step == "exit_unknown" and text.findn("COMMAND NOT RECOGNIZED") != -1:
		print("PROBE_WORLD_UNKNOWN_REJECTED")
		_world_finish()


func _process(_delta: float) -> void:
	if not _world_mode or _finished:
		return
	if _world_step == "launch":
		var w := get_tree().get_first_node_in_group("stalag_world")
		if w != null:
			_world_step = "in_world"
			_world_settle_frames = 0
	elif _world_step == "in_world":
		var w := get_tree().get_first_node_in_group("stalag_world")
		if w == null:
			return
		var streamer: Node = w.get_node("Streamer")
		if not (streamer.ring_ready() and streamer.pending_count() == 0 and w.is_grounded() and w.chunks_loaded() >= WORLD_MIN_CHUNKS):
			return
		_world_settle_frames += 1
		if _world_settle_frames < 30:
			return
		_world_step = "shot"
		_world_shoot(w)


## Screenshot through the REAL shell path (CRT overlay and all). The terrain fraction is
## measured as "lower-half pixels that change when the terrain is hidden", so the overlay's
## own scanline/vignette darkening cannot be mistaken for the sky or for terrain.
func _world_shoot(w: Node) -> void:
	var streamer: Node3D = w.get_node("Streamer")
	print("PROBE_WORLD_ENTERED chunks=%d grounded=%d" % [w.chunks_loaded(), 1 if w.is_grounded() else 0])
	await get_tree().process_frame
	var with_terrain := get_viewport().get_texture().get_image()
	with_terrain.convert(Image.FORMAT_RGB8)
	var shots_dir := OS.get_environment("STALAG_SHOTS_DIR")
	if shots_dir.is_empty():
		shots_dir = OS.get_user_data_dir()
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var path := shots_dir + "/entry_world.png"
	with_terrain.save_png(path)
	streamer.visible = false
	await get_tree().process_frame
	await get_tree().process_frame
	var without := get_viewport().get_texture().get_image()
	without.convert(Image.FORMAT_RGB8)
	streamer.visible = true
	var a := with_terrain.get_data()
	var b := without.get_data()
	var width := with_terrain.get_width()
	var height := with_terrain.get_height()
	var changed := 0
	var total := 0
	for y in range(height / 2, height):
		for x in range(width):
			var o := (y * width + x) * 3
			total += 1
			if absi(a[o] - b[o]) > 8 or absi(a[o + 1] - b[o + 1]) > 8 or absi(a[o + 2] - b[o + 2]) > 8:
				changed += 1
	print("PROBE_WORLD_SHOT lower_nonbg=%.4f file=%s" % [float(changed) / maxf(1.0, float(total)), path])
	_world_step = "exit_dir"
	w.request_exit()
	await get_tree().process_frame
	await get_tree().process_frame
	Signals.terminal_line_submitted.emit(DIR_COMMAND)


func _world_finish() -> void:
	if _finished:
		return
	_finished = true
	_world_step = "done"
	_watchdog.stop()
	_save_screenshot()
	get_tree().quit()


## ===========================================================================
## Spec #519 modes (additive; the chat / force-fail / world paths above are
## untouched). Selected by DECOHERENCE_PROBE_MODE:
##   density      boot with DECOHERENCE_BOOT_PRESET, report layout + density
##   router       feed an utterance file through the shell (accuracy / degrade)
##   e2e_fastpath / e2e_thinking / e2e_dispatch   shell behavior through the
##                real model
##   e2e_settings / e2e_relaunch / e2e_corrupt    settings apply + persistence
##   tone / scale (Spec #541)   rendered-pixel measurements of the calm chrome,
##                the input row + cursor, and the fullscreen content scale;
##                results go to $DECOHERENCE_PROBE_OUT_DIR
## All of them drive the shell through Signals.terminal_line_submitted, the
## same send path a real Enter keypress uses.
## ===========================================================================

const EXT_MODES := ["density", "router", "e2e_fastpath", "e2e_thinking", "e2e_dispatch", "e2e_settings", "e2e_relaunch", "e2e_corrupt", "seam", "shell_shot", "tone", "scale"]
const EXT_WATCHDOG_SECONDS := 1500.0
const RESOLVE_TIMEOUT_SEC := 25.0

var _ext_mode := ""
var _ext_rendered: Array = []
var _ext_first_line_ms := -1
var _ext_resolved := false
var _ext_result: Dictionary = {}
var _ext_think_events: Array = []
var _ext_chat_opened := false
var _boot_started_ms := 0
var _shell_ready_seen := false
var _shell_ready_ms := 0


## Snapshot taken INSIDE the shell_ready emission, i.e. before boot_controller
## retires the boot panes (enter_shell_mode runs right after the emit).
var _snap: Dictionary = {}


func _on_ext_shell_ready() -> void:
	_shell_ready_seen = true
	_shell_ready_ms = Time.get_ticks_msec()
	var panels := _panels_node()
	_snap = {
		"report": panels.layout_report(),
		"mean": panels.mean_active_cells(),
		"unique": panels.unique_frames(),
		"lamp": {
			"cortex": panels.lamp_state("cortex"),
			"cortex_up_before_gate": panels.cortex_up_before_gate(),
			"up_count": panels.up_count(),
			"rollup_text": panels.rollup_text(),
		},
	}


func _start_ext_watchdog() -> void:
	_boot_started_ms = Time.get_ticks_msec()
	_watchdog = Timer.new()
	_watchdog.one_shot = true
	_watchdog.wait_time = EXT_WATCHDOG_SECONDS
	add_child(_watchdog)
	_watchdog.timeout.connect(_on_ext_watchdog)
	_watchdog.start()


func _on_ext_watchdog() -> void:
	print("PROBE_TIMEOUT mode=" + _ext_mode)
	get_tree().quit(1)


func _scene() -> Node:
	return get_tree().current_scene


func _shell_node() -> ShellController:
	return _scene().get_node("ShellController")


func _llm_node() -> LlmClient:
	return _scene().get_node("LlmClient")


func _panels_node() -> BootPanels:
	return _scene().get_node("PanelsLayer/BootPanels")


func _terminal_node() -> TerminalGrid:
	return _scene().get_node("TerminalLayer/TerminalGrid")


func _overlay_material() -> ShaderMaterial:
	return _scene().get_node("CRTLayer/CRTOverlay").material


func _on_ext_resolved(source: String, action: String, args: Dictionary) -> void:
	_ext_resolved = true
	_ext_result = {"source": source, "action": action, "args": args, "at_ms": Time.get_ticks_msec()}


func _on_ext_thinking(active: bool) -> void:
	_ext_think_events.append({"active": active, "at_ms": Time.get_ticks_msec()})


func _on_ext_chat_opened() -> void:
	_ext_chat_opened = true


func _wait_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _wait_seconds(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## Submits one line and waits for intent_resolved. Returns {timed_out, wall_ms,
## first_line_ms, ...resolved fields}.
func _submit_and_wait(text: String, timeout_sec: float = RESOLVE_TIMEOUT_SEC) -> Dictionary:
	_ext_resolved = false
	_ext_result = {}
	_ext_first_line_ms = -1
	var t0 := Time.get_ticks_msec()
	Signals.terminal_line_submitted.emit(text)
	var deadline := t0 + int(timeout_sec * 1000.0)
	while not _ext_resolved and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var out := _ext_result.duplicate()
	out["timed_out"] = not _ext_resolved
	out["wall_ms"] = (int(_ext_result.get("at_ms", Time.get_ticks_msec())) - t0)
	out["first_line_ms"] = (_ext_first_line_ms - t0) if _ext_first_line_ms >= 0 else -1
	return out


func _ext_quit(code: int) -> void:
	if _watchdog != null:
		_watchdog.stop()
	_save_screenshot()
	get_tree().quit(code)


func _run_ext() -> void:
	Signals.intent_resolved.connect(_on_ext_resolved)
	Signals.intent_thinking.connect(_on_ext_thinking)
	Signals.chat_opened.connect(_on_ext_chat_opened)
	if _ext_mode == "density":
		await _run_density()
		return
	await Signals.shell_ready
	await _wait_frames(5)
	match _ext_mode:
		"router":
			await _run_router()
		"e2e_fastpath":
			await _run_e2e_fastpath()
		"e2e_thinking":
			await _run_e2e_thinking()
		"e2e_dispatch":
			await _run_e2e_dispatch()
		"e2e_settings":
			await _run_e2e_settings()
		"e2e_relaunch":
			await _run_e2e_relaunch()
		"e2e_corrupt":
			await _run_e2e_corrupt()
		"seam":
			await _run_seam()
		"shell_shot":
			await _run_shell_shot()
		"tone":
			await _run_tone()
		"scale":
			await _run_scale()
	_ext_quit(0)


## --- density ---------------------------------------------------------------

## Share of lit pixels, and the share of lit pixels whose hue is outside the
## teal (about 174 deg) / orange (about 30 deg) bands. Greys and whites are
## off-palette by definition (low saturation).
func _palette_stats(img: Image) -> Dictionary:
	img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	var w := img.get_width()
	var h := img.get_height()
	var lit := 0
	var off := 0
	var total := 0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var o := (y * w + x) * 3
			var r := int(data[o])
			var g := int(data[o + 1])
			var b := int(data[o + 2])
			total += 1
			var mx := maxi(r, maxi(g, b))
			if mx < 60:
				continue
			var mn := mini(r, mini(g, b))
			var d := float(mx - mn)
			# The engine's default grey clear colour is today's background, not
			# a drawn pixel: skip dark, near-grey pixels. Bright greys (white or
			# grey glyphs) still count as lit and off-palette below.
			if d / float(mx) < 0.12 and mx < 100:
				continue
			lit += 1
			var hue := -1.0
			if d / float(mx) >= 0.12:
				if mx == r:
					hue = fposmod(60.0 * (float(g - b) / d), 360.0)
				elif mx == g:
					hue = 60.0 * (2.0 + float(b - r) / d)
				else:
					hue = 60.0 * (4.0 + float(r - g) / d)
			var on_palette := (hue >= 165.0 and hue <= 185.0) or (hue >= 22.0 and hue <= 38.0)
			if not on_palette:
				off += 1
	return {"lit_frac": float(lit) / maxf(1.0, float(total)), "offpalette_frac": float(off) / maxf(1.0, float(lit))}


func _run_density() -> void:
	Signals.shell_ready.connect(_on_ext_shell_ready, CONNECT_ONE_SHOT)
	var gate_line := false
	while not gate_line:
		if _ext_rendered.any(func(t): return String(t).findn("CORTEX LINK FAILED") != -1 or String(t).findn("LINK ESTABLISHED") != -1):
			gate_line = true
		await get_tree().process_frame
	await _wait_frames(30)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var stats := _palette_stats(img)
	var neg := Image.create(64, 64, false, Image.FORMAT_RGB8)
	neg.fill(Color8(255, 176, 0))
	var neg_stats := _palette_stats(neg)
	# Blank-frame negative control: a frame with nothing drawn must read ~0 lit.
	var blank := Image.create(64, 64, false, Image.FORMAT_RGB8)
	blank.fill(Palette.BG)
	var blank_stats := _palette_stats(blank)
	while not _shell_ready_seen:
		await get_tree().process_frame
	var boot_ms := _shell_ready_ms - _boot_started_ms
	var rep: Dictionary = _snap["report"]
	var vp := get_viewport().get_visible_rect().size
	var row := {
		"preset": OS.get_environment("DECOHERENCE_BOOT_PRESET"),
		"size": "%dx%d" % [int(vp.x), int(vp.y)],
		"viewport": rep["viewport"],
		"tier": rep["tier"],
		"term": rep["term"],
		"panels": rep["panels"],
		"panel_count": rep["panel_count"],
		"overlaps": rep["overlaps"],
		"in_bounds": rep["in_bounds"],
		"active_cells_mean": _snap["mean"],
		"unique_frames": _snap["unique"],
		"boot_ms": boot_ms,
		"lamp": _snap["lamp"],
		"offpalette_frac": stats["offpalette_frac"],
		"lit_frac": stats["lit_frac"],
		"palette_neg_frac": neg_stats["offpalette_frac"],
		"blank_neg_lit_frac": blank_stats["lit_frac"],
	}
	print("PROBE_DENSITY " + JSON.stringify(row))
	_ext_quit(0)


## --- router (accuracy / degrade) --------------------------------------------

func _row_template(u: Dictionary) -> Dictionary:
	return {
		"text": String(u.get("text", "")), "split": String(u.get("split", "")), "class": String(u.get("class", "")),
		"expect_action": String(u.get("expect_action", "")), "expect_args": u.get("expect_args", {}),
	}


func _run_router() -> void:
	var shell := _shell_node()
	var llm := _llm_node()
	var out_dir := OS.get_environment("DECOHERENCE_ROUTER_OUT")
	var degrade := OS.get_environment("DECOHERENCE_ROUTER_MODE") == "degrade"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var utts = IntentRouter.load_json(OS.get_environment("DECOHERENCE_UTTERANCES"))
	var work: Array = []
	if degrade:
		var n_free := 0
		for u in utts:
			if n_free >= 24:
				break
			work.append(u)
			n_free += 1
		for fast_cmd in ["dir", "help", "settings"]:
			work.append({"text": fast_cmd, "split": "dev", "class": "fast", "expect_action": "fast", "fast": true})
	else:
		shell.router_dry_run = true
		work = utts
	var req0 := llm.request_count
	var rows: Array = []
	var rendered_all: Array = []
	for u in work:
		var mark := _ext_rendered.size()
		var res := await _submit_and_wait(String(u["text"]))
		await _wait_frames(2)
		var row := _row_template(u)
		row["fast"] = bool(u.get("fast", false))
		row["source"] = String(res.get("source", "timeout"))
		row["action"] = String(res.get("action", "unclear"))
		row["args"] = res.get("args", {})
		row["timed_out"] = bool(res["timed_out"])
		row["wall_ms"] = int(res["wall_ms"])
		row["reason"] = String(shell.last_route.get("reason", ""))
		row["say"] = String(shell.last_route.get("say", ""))
		row["dispatched"] = bool(shell.last_route.get("dispatched", false))
		row["would_dispatch"] = bool(shell.last_route.get("would_dispatch", false))
		row["ms"] = int(shell.last_route.get("ms", 0))
		row["thinking_on"] = llm.last_thinking_enabled if row["source"] == "llm" else false
		row["reasoning_chars"] = llm.last_reasoning_chars if row["source"] == "llm" else 0
		row["prompt_tokens"] = llm.last_prompt_tokens if row["source"] == "llm" else 0
		row["out_tokens"] = llm.last_out_tokens if row["source"] == "llm" else 0
		var lines: Array = _ext_rendered.slice(mark)
		row["rendered"] = lines
		for l in lines:
			rendered_all.append(l)
		rows.append(row)
	var llm_cfg = IntentRouter.load_json("res://data/llm_config.json")
	if typeof(llm_cfg) != TYPE_DICTIONARY:
		llm_cfg = {}
	var src := LlmClient.resolve_source(llm_cfg, OS.get_environment("DECOHERENCE_LLM_SOURCE"))
	var model_name := ""
	var ctx_used := 0
	if src == LlmClient.SOURCE_OLLAMA:
		model_name = String(llm_cfg.get("ollama", {}).get("model", ""))
		ctx_used = int(llm_cfg.get("ollama", {}).get("num_ctx", 0))
	elif src == LlmClient.SOURCE_OWNED:
		model_name = String(llm_cfg.get("model_path", "")).get_file().get_basename()
		ctx_used = int(llm_cfg.get("ctx_size", 0))
	var doc := {"mode": "degrade" if degrade else "live", "model": model_name, "source": src, "num_ctx": ctx_used, "rows": rows, "request_count_delta": llm.request_count - req0}
	var f := FileAccess.open(out_dir + "/rows.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	var r := FileAccess.open(out_dir + "/rendered.txt", FileAccess.WRITE)
	r.store_string("\n".join(PackedStringArray(rendered_all)) + "\n")
	r.close()
	print("PROBE_ROUTER_DONE rows=%d request_count_delta=%d" % [rows.size(), llm.request_count - req0])


## --- e2e: fast path ------------------------------------------------------------

func _run_e2e_fastpath() -> void:
	var llm := _llm_node()
	var req0 := llm.request_count
	var cmds := ["dir", "DIR", "help", "HELP", "settings", "set crt normal", "set flicker full", "set text_speed normal"]
	var max_ms := 0
	var dir_lines: Array = []
	for c in cmds:
		var mark := _ext_rendered.size()
		var res := await _submit_and_wait(c, 5.0)
		await _wait_frames(2)
		max_ms = maxi(max_ms, int(res["first_line_ms"]))
		if String(c).to_lower() == "dir" and dir_lines.is_empty():
			dir_lines = _ext_rendered.slice(mark)
	print("PROBE_FASTPATH cmds=%d llm_requests_delta=%d max_resolve_ms=%d" % [cmds.size(), llm.request_count - req0, max_ms])
	var want := ["DIRECTORY LISTING:", "  CHAT", "  WORLD", "2 MODULE(S)"]
	if dir_lines == want:
		print("PROBE_DIR_LEGACY_LINES_OK")
	var shell := _shell_node()
	shell.router_dry_run = true
	var mark2 := _ext_rendered.size()
	await _submit_and_wait("xyzzy_no_such_module")
	await _wait_frames(2)
	if _ext_rendered.slice(mark2).any(func(t): return String(t) == "COMMAND NOT RECOGNIZED: xyzzy_no_such_module"):
		print("PROBE_UNKNOWN_COMPAT_OK")


## --- e2e: thinking row, stale drop, busy fast path, timeout -----------------------

func _run_e2e_thinking() -> void:
	var shell := _shell_node()
	var term := _terminal_node()
	shell.router_dry_run = true
	# 1. Thinking row: appears within 250 ms, clears on resolution, never on a fast command.
	_ext_think_events.clear()
	var t0 := Time.get_ticks_msec()
	_ext_resolved = false
	Signals.terminal_line_submitted.emit("take me to the chatroom please")
	var first_ms := -1
	var saw_row := false
	while not _ext_resolved and Time.get_ticks_msec() - t0 < 25000:
		if first_ms < 0 and not _ext_think_events.is_empty():
			first_ms = int(_ext_think_events[0]["at_ms"]) - t0
		if term.has_transient_line():
			saw_row = true
		await get_tree().process_frame
	await _wait_frames(3)
	var cleared := (not term.has_transient_line()) and _ext_think_events.size() >= 2 and not bool(_ext_think_events[_ext_think_events.size() - 1]["active"])
	_ext_think_events.clear()
	await _submit_and_wait("dir", 5.0)
	var flash := 1 if not _ext_think_events.is_empty() else 0
	if first_ms >= 0 and saw_row:
		print("PROBE_THINKING first_ms=%d cleared=%d fastpath_flash=%d" % [first_ms, 1 if cleared else 0, flash])
	# 2. Stale drop: route a line that WOULD open chat, then supersede it at once.
	shell.router_dry_run = false
	_ext_chat_opened = false
	var drops0 := shell.stale_drops
	var n := 0
	for i in range(3):
		var before := shell.stale_drops
		Signals.terminal_line_submitted.emit("take me to the chat module right now")
		await _wait_frames(2)
		Signals.terminal_line_submitted.emit("help")
		var deadline := Time.get_ticks_msec() + 30000
		while shell.stale_drops == before and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		n += 1 if shell.stale_drops > before else 0
	await _wait_frames(5)
	var moved := 1 if (_ext_chat_opened or shell.current_state_name() != "SHELL") else 0
	print("PROBE_STALE_DROPPED n=%d dispatched_after_state_change=%d" % [shell.stale_drops - drops0, moved])
	# 3. Busy router never blocks an exact command.
	shell.router_dry_run = true
	Signals.terminal_line_submitted.emit("what modules do you have installed")
	await _wait_frames(3)
	var mark := _ext_rendered.size()
	var tb := Time.get_ticks_msec()
	_ext_first_line_ms = -1
	Signals.terminal_line_submitted.emit("dir")
	await _wait_frames(3)
	var busy_ms := (_ext_first_line_ms - tb) if _ext_first_line_ms >= 0 else 9999
	if busy_ms < 150 and _ext_rendered.slice(mark).has("DIRECTORY LISTING:"):
		print("PROBE_BUSY_FASTPATH_OK")
	await _wait_seconds(1.0)
	# 4. Timeout -> honest degraded line, nothing dispatched, exact commands still work.
	shell.router_timeout_override_ms = 1
	var mark3 := _ext_rendered.size()
	var res := await _submit_and_wait("open the chat for me", 10.0)
	var deg_dispatched := bool(shell.last_route.get("dispatched", true))
	shell.router_timeout_override_ms = 0
	await _wait_frames(2)
	var joined := " ".join(PackedStringArray(_ext_rendered.slice(mark3)))
	var res2 := await _submit_and_wait("dir", 5.0)
	if String(res.get("source", "")) == "degraded" and joined.contains("EXACT COMMANDS") and joined.contains("HELP") and not deg_dispatched and String(res2.get("source", "")) == "fast":
		print("PROBE_TIMEOUT_DEGRADED_OK")


## --- e2e: real dispatch through the real model ----------------------------------------

func _check_state(action: String, args: Dictionary, lines: Array) -> bool:
	var shell := _shell_node()
	match action:
		"list_dir":
			return lines.has("DIRECTORY LISTING:")
		"help":
			return lines.has("Q-ENT OS COMMANDS:")
		"show_settings":
			return lines.has("SETTINGS:")
		"set_setting":
			return String(shell.get_settings().get(String(args.get("key", "")), "")) == String(args.get("value", "")) and not String(args.get("key", "")).is_empty()
		"open_module":
			return shell.current_state_name() == "CHAT" and _ext_chat_opened
	return false


func _run_e2e_dispatch() -> void:
	var shell := _shell_node()
	shell.router_dry_run = false
	var cases := [
		["show me the directory", "list_dir"],
		["what can I do here", "help"],
		["show my settings", "show_settings"],
		["make the flicker half", "set_setting"],
		["make the text faster", "set_setting"],
		["turn off the crt effect", "set_setting"],
		["go 720p", "set_setting"],
		["take me to the chat", "open_module"],
	]
	for c in cases:
		var mark := _ext_rendered.size()
		var res := await _submit_and_wait(String(c[0]))
		await _wait_frames(3)
		var lines: Array = _ext_rendered.slice(mark)
		var action := String(res.get("action", "unclear"))
		var args: Dictionary = res.get("args", {})
		var echo_ok := action != "unclear" and lines.has("> " + IntentRouter.echo_for(action, args))
		var state_ok := _check_state(action, args, lines)
		var extra := ""
		if action == "set_setting":
			extra = " key=%s" % String(args.get("key", ""))
		print("PROBE_DISPATCH action=%s%s via=%s echo_matches=%d state_matches=%d" % [action, extra, String(res.get("source", "none")), 1 if echo_ok else 0, 1 if state_ok else 0])
		if action != String(c[1]):
			print("PROBE_DISPATCH_MISS expected=%s got=%s" % [String(c[1]), action])
		if String(c[0]).contains("720"):
			Signals.terminal_line_submitted.emit("set display 1920x1080")
			await _wait_frames(5)


## --- e2e: settings apply / persist / invalid / corrupt --------------------------------------

func _sample_flicker_max(boot: Node) -> float:
	var mat := _overlay_material()
	var peak := 0.0
	boot._trigger_instability_beat()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 700:
		peak = maxf(peak, float(mat.get_shader_parameter("flicker")))
		await get_tree().process_frame
	return peak


func _run_e2e_settings() -> void:
	var shell := _shell_node()
	var mat := _overlay_material()
	var boot := _scene()
	for v in ["normal", "off", "low", "high", "normal"]:
		await _submit_and_wait("set crt " + v, 5.0)
		await _wait_frames(3)
		print("PROBE_SETTING_APPLIED key=crt value=%s scanline_intensity=%s vignette_strength=%s" % [v, str(mat.get_shader_parameter("scanline_intensity")), str(mat.get_shader_parameter("vignette_strength"))])
	for v in ["off", "half", "full"]:
		await _submit_and_wait("set flicker " + v, 5.0)
		var peak := await _sample_flicker_max(boot)
		print("PROBE_FLICKER_MAX setting=%s max=%.3f" % [v, peak])
	for v in ["1280x720", "1920x1080", "1280x720"]:
		await _submit_and_wait("set display " + v, 5.0)
		await _wait_frames(20)
		var win := get_window()
		print("PROBE_SETTING_APPLIED key=display value=%s window_w=%d window_h=%d" % [v, win.size.x, win.size.y])
	await _submit_and_wait("set text_speed fast", 5.0)
	print("PROBE_SETTING_APPLIED key=text_speed value=fast cps=%s" % str(shell._text_cps))
	# Invalid input never changes anything.
	var before := shell.get_settings()
	var mark := _ext_rendered.size()
	await _submit_and_wait("set flicker purple", 5.0)
	await _submit_and_wait("set bogus 1", 5.0)
	await _wait_frames(2)
	var rej := _ext_rendered.slice(mark).filter(func(t): return String(t).begins_with("SETTING NOT RECOGNIZED")).size()
	if shell.get_settings() == before and rej == 2:
		print("PROBE_SETTINGS_INVALID_REJECTED_OK")
	await _submit_and_wait("set crt low", 5.0)
	await _submit_and_wait("set flicker half", 5.0)
	print("PROBE_SETTINGS_FINAL " + JSON.stringify(shell.get_settings()))


func _run_e2e_relaunch() -> void:
	var shell := _shell_node()
	var mat := _overlay_material()
	await _wait_frames(20)
	var s := shell.get_settings()
	var win := get_window()
	var want := {"crt": "low", "flicker": "half", "text_speed": "fast", "display": "1280x720"}
	print("PROBE_RELAUNCH_STATE " + JSON.stringify(s) + " scanline=" + str(mat.get_shader_parameter("scanline_intensity")) + " window=%dx%d" % [win.size.x, win.size.y])
	if s == want and absf(float(mat.get_shader_parameter("scanline_intensity")) - 0.12) < 0.001 and win.size == Vector2i(1280, 720):
		print("PROBE_SETTINGS_PERSISTED_RELAUNCH_OK")


func _run_e2e_corrupt() -> void:
	var shell := _shell_node()
	await _wait_frames(5)
	var defaults := {"crt": "normal", "flicker": "full", "text_speed": "normal", "display": "1920x1080"}
	var honest := _ext_rendered.any(func(t): return String(t).begins_with("SETTINGS FILE UNREADABLE"))
	if shell.get_settings() == defaults and honest and shell.settings_status == "corrupt":
		print("PROBE_SETTINGS_CORRUPT_DEFAULTED_OK")


## --- model-source seam (Spec #519 A1) -----------------------------------------
## Drives one routed free-text line and, if it was model-routed, one send_chat
## call, against whatever Ollama-shaped endpoint DECOHERENCE_OLLAMA_PORT names
## (tests/fake_ollama.py). tests/verify_ollama_seam.sh judges the request log.

func _run_seam() -> void:
	var shell := _shell_node()
	var llm := _llm_node()
	shell.router_dry_run = true
	var mark := _ext_rendered.size()
	var res := await _submit_and_wait("take me to the chat room please")
	await _wait_frames(2)
	var route_source := String(res.get("source", "timeout"))
	var chat_len := -1
	var chat_deltas := 0
	if route_source == "llm":
		var box := {"done": false, "text": "", "deltas": 0}
		llm.send_chat([{"role": "user", "content": "hello"}], func(_piece): box["deltas"] += 1, func(text): box["text"] = String(text); box["done"] = true)
		var deadline := Time.get_ticks_msec() + 15000
		while not bool(box["done"]) and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		chat_len = String(box["text"]).length()
		chat_deltas = int(box["deltas"])
	var rendered: Array = _ext_rendered.slice(mark)
	print("PROBE_SEAM route_source=%s route_action=%s chat_len=%d chat_deltas=%d requests=%d" % [route_source, String(res.get("action", "")), chat_len, chat_deltas, llm.request_count])
	for l in rendered:
		print("PROBE_SEAM_LINE " + String(l))


## --- shell screenshot (Spec #519 deliverable) -----------------------------------
## Types two plain-language lines through the real router and leaves the result
## on screen; _ext_quit saves DECOHERENCE_PROBE_SCREENSHOT.

func _run_shell_shot() -> void:
	for text in ["what can I do here", "make the text faster"]:
		var res := await _submit_and_wait(text)
		print("PROBE_SHELL_SHOT text=%s source=%s action=%s" % [text, String(res.get("source", "")), String(res.get("action", ""))])
		await _wait_seconds(1.5)
	await _wait_seconds(2.0)


## ===========================================================================
## Spec #541 modes: `tone` and `scale`. Both measure RENDERED pixels (the
## viewport texture), never a flag in the data structure, and both type
## through real InputEventKey events so the genuine _input paths run.
## Output dir: DECOHERENCE_PROBE_OUT_DIR (required).
## ===========================================================================

const LIT_LUMA := 0.2


func _out_dir() -> String:
	var d := OS.get_environment("DECOHERENCE_PROBE_OUT_DIR")
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "  "))
		f.close()


func _key_event(keycode: int, unicode: int = 0, alt: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = keycode as Key
	ev.unicode = unicode
	ev.alt_pressed = alt
	return ev


func _press(keycode: int, unicode: int = 0, alt: bool = false) -> void:
	Input.parse_input_event(_key_event(keycode, unicode, alt))
	await get_tree().process_frame


func _type_text(text: String) -> void:
	for i in range(text.length()):
		await _press(KEY_NONE, text.unicode_at(i))


func _type_line(text: String) -> void:
	await _type_text(text)
	await _press(KEY_ENTER)


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


## Pixel statistics over `r` (physical pixels) of an RGB8 image: mean luma of
## every pixel, mean luma of the lit ones (luma >= LIT_LUMA), and the lit
## bounding box.
func _region_stats(img: Image, r: Rect2i) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var rr := r.intersection(Rect2i(0, 0, w, h))
	var data := img.get_data()
	var n := 0
	var lit := 0
	var sum_all := 0.0
	var sum_lit := 0.0
	var x0 := 1 << 30
	var y0 := 1 << 30
	var x1 := -1
	var y1 := -1
	for y in range(rr.position.y, rr.end.y):
		var o := (y * w + rr.position.x) * 3
		for x in range(rr.position.x, rr.end.x):
			var l := (0.2126 * data[o] + 0.7152 * data[o + 1] + 0.0722 * data[o + 2]) / 255.0
			o += 3
			n += 1
			sum_all += l
			if l >= LIT_LUMA:
				lit += 1
				sum_lit += l
				if x < x0:
					x0 = x
				if x > x1:
					x1 = x
				if y < y0:
					y0 = y
				if y > y1:
					y1 = y
	return {
		"n": n, "lit": lit,
		"mean": sum_all / maxf(1.0, float(n)),
		"lit_mean": sum_lit / maxf(1.0, float(lit)),
		"bbox_w": (x1 - x0 + 1) if lit > 0 else 0,
		"bbox_h": (y1 - y0 + 1) if lit > 0 else 0,
	}


func _phys(r: Rect2, factor: float) -> Rect2i:
	return Rect2i(Vector2i((r.position * factor).round()), Vector2i((r.size * factor).round()))


## Run-length analysis of a blink series [[t_ms, luma], ...]: the on/off
## threshold is the midpoint of the observed range (a series with no real
## swing has zero transitions by construction).
func _blink_stats(series: Array) -> Dictionary:
	var lo := 1.0
	var hi := 0.0
	for p in series:
		lo = minf(lo, float(p[1]))
		hi = maxf(hi, float(p[1]))
	var swing := hi - lo >= 0.08
	var thr := (lo + hi) * 0.5
	var on := 0
	var off := 0
	var transitions := 0
	var prev := -1
	var change_ms: Array = []
	for p in series:
		var state := 1 if (swing and float(p[1]) > thr) else 0
		if state == 1:
			on += 1
		else:
			off += 1
		if prev != -1 and state != prev:
			transitions += 1
			change_ms.append(int(p[0]))
		prev = state
	var half := 0.0
	if change_ms.size() >= 2:
		half = float(int(change_ms[change_ms.size() - 1]) - int(change_ms[0])) / float(change_ms.size() - 1)
	return {"samples": series.size(), "on": on, "off": off, "transitions": transitions, "half_period_ms": int(round(half))}


func _cursor_luma(term: TerminalGrid, factor: float) -> float:
	var img := await _grab()
	var r := term.cursor_rect().grow(-2.0)
	return float(_region_stats(img, _phys(r, factor))["mean"])


func _run_tone() -> void:
	var term := _terminal_node()
	var factor := get_window().content_scale_factor
	await _type_line("help")
	await _wait_seconds(3.0)
	var img := await _grab()
	var out_dir := _out_dir()
	img.save_png(out_dir + "/tone.png")

	# Backdrop: an empty region, plus negative controls for the instrument.
	var vp := get_viewport().get_visible_rect().size
	var empty := _region_stats(img, _phys(Rect2(1100, 100, 700, 500), factor))
	var grey_img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	grey_img.fill(Color(0.3, 0.3, 0.3))
	var bg_img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	bg_img.fill(Palette.BG)
	var grey_luma: float = _region_stats(grey_img, Rect2i(0, 0, 64, 64))["mean"]
	var bg_luma: float = _region_stats(bg_img, Rect2i(0, 0, 64, 64))["mean"]

	# Terminal text vs chrome, same frame.
	var term_stats := _region_stats(img, _phys(Rect2(0, 0, PanelLayout.TERM_W, PanelLayout.TERM_H), factor))
	var chrome_sum := 0.0
	var chrome_lit := 0
	var report: Dictionary = _panels_node().layout_report()
	for p in report["panels"]:
		var cs := _region_stats(img, _phys(Rect2(p[0], p[1], p[2], p[3]), factor))
		chrome_sum += float(cs["lit_mean"]) * int(cs["lit"])
		chrome_lit += int(cs["lit"])
	var chrome_lit_mean := chrome_sum / maxf(1.0, float(chrome_lit))

	# Input row: the bar must lift the row above a plain empty row.
	var cr := term.cursor_rect()
	var bar := _region_stats(img, _phys(Rect2(700, cr.position.y, 280, cr.size.y), factor))
	var plain := _region_stats(img, _phys(Rect2(700, cr.position.y + 2.0 * cr.size.y, 280, cr.size.y), factor))
	var lift: float = float(bar["mean"]) - float(plain["mean"])

	# Cursor blink: sample the rendered pixels at the cursor cell for 3 s.
	await _wait_seconds(1.0)
	var series: Array = []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		series.append([Time.get_ticks_msec() - t0, await _cursor_luma(term, factor)])
	var blink := _blink_stats(series)
	var flat: Array = []
	for i in range(60):
		flat.append([i * 50, 0.5])
	var neg_flat: Dictionary = _blink_stats(flat)

	# Solid while typing: type at an OFF phase; the cursor must be on at once.
	var solid_trials := 0
	var solid_ok := true
	var lo := 1.0
	var hi := 0.0
	for p in series:
		lo = minf(lo, float(p[1]))
		hi = maxf(hi, float(p[1]))
	var mid := (lo + hi) * 0.5
	for trial in range(3):
		var waited := 0
		while await _cursor_luma(term, factor) > mid and waited < 120:
			waited += 1
		if waited >= 120:
			solid_ok = false
			break
		await _press(KEY_NONE, "x".unicode_at(0))
		solid_trials += 1
		var after_key := await _cursor_luma(term, factor)
		await _wait_seconds(0.3)
		var later := await _cursor_luma(term, factor)
		if after_key <= mid or later <= mid:
			solid_ok = false
	for i in range(solid_trials):
		await _press(KEY_BACKSPACE)

	# Echo: direct call (no line_rendered), then the real typed path.
	var before_lr := _ext_rendered.size()
	term.write_player_line("</think>zz")
	var last_text := String(term.rows_snapshot().back()["text"])
	var delta := _ext_rendered.size() - before_lr
	var neutralized := last_text.findn("</think") == -1 and last_text.begins_with("> [/think")
	await _type_line("hello probe")
	await _wait_seconds(0.5)
	var row_present := false
	for row in term.rows_snapshot():
		if String(row["text"]) == "> hello probe":
			row_present = true

	var result := {
		"viewport": "%dx%d" % [int(vp.x), int(vp.y)],
		"empty_luma": empty["mean"],
		"term_lit_mean": term_stats["lit_mean"],
		"chrome_lit_mean": chrome_lit_mean,
		"input_row_lift": lift,
		"neg": {"grey_luma": grey_luma, "bg_luma": bg_luma},
		"cursor": {
			"samples": blink["samples"], "on": blink["on"], "off": blink["off"],
			"transitions": blink["transitions"], "half_period_ms": blink["half_period_ms"],
			"solid_while_typing": solid_ok and solid_trials >= 3,
			"neg_flat_transitions": neg_flat["transitions"],
		},
		"echo": {"row_present": row_present, "line_rendered_delta": delta, "marker_neutralized": neutralized},
	}
	_write_json(out_dir + "/tone.json", result)
	print("PROBE_TONE " + JSON.stringify(result))


func _display_state(win: Window) -> String:
	if win.mode == Window.MODE_FULLSCREEN or win.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		return "fullscreen"
	return "windowed"


func _persisted_display() -> String:
	var f := FileAccess.open("user://" + SettingsStore.FILE_NAME, FileAccess.READ)
	if f == null:
		return ""
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return String(parsed.get("display", "")) if typeof(parsed) == TYPE_DICTIONARY else ""


func _scale_consistent(win: Window) -> bool:
	var factor := UiScale.factor_for(win.size)
	var mat := _overlay_material()
	return is_equal_approx(win.content_scale_factor, factor) \
		and is_equal_approx(float(mat.get_shader_parameter("scanline_spacing_px")), UiScale.crt_spacing(factor))


func _wait_mode(win: Window, want: String) -> void:
	var t0 := Time.get_ticks_msec()
	while _display_state(win) != want and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
	await _wait_frames(20)


func _run_scale() -> void:
	var term := _terminal_node()
	var win := get_window()
	await _type_line("help")
	await _wait_seconds(3.0)
	var img := await _grab()
	var out_dir := _out_dir()
	var factor := win.content_scale_factor
	var vp := get_viewport().get_visible_rect().size
	var tag := "%dx%d" % [win.size.x, win.size.y]
	img.save_png("%s/scale_%s.png" % [out_dir, tag])
	var rep: Dictionary = _panels_node().layout_report()
	var stats := _region_stats(img, _phys(Rect2(0, 0, PanelLayout.TERM_W, PanelLayout.TERM_H), factor))
	# Negative control for the bbox instrument: a known lit rectangle on a dark
	# image must come back at exactly its size, and a dark image at zero.
	var ctl := Image.create(200, 100, false, Image.FORMAT_RGB8)
	ctl.fill(Color(0, 0, 0))
	ctl.fill_rect(Rect2i(20, 10, 60, 30), Color(1, 1, 1))
	var ctl_stats := _region_stats(ctl, Rect2i(0, 0, 200, 100))
	var dark_stats := _region_stats(Image.create(50, 50, false, Image.FORMAT_RGB8), Rect2i(0, 0, 50, 50))
	var bbox_ok: bool = int(ctl_stats["bbox_w"]) == 60 and int(ctl_stats["bbox_h"]) == 30 and int(dark_stats["bbox_w"]) == 0
	var result := {
		"win": tag,
		"factor": factor,
		"vp": "%dx%d" % [int(vp.x), int(vp.y)],
		"tier": rep["tier"],
		"overlaps": rep["overlaps"],
		"in_bounds": rep["in_bounds"],
		"panel_count": rep["panel_count"],
		"crt_spacing": _overlay_material().get_shader_parameter("scanline_spacing_px"),
		"term_bbox_w": stats["bbox_w"],
		"term_bbox_h": stats["bbox_h"],
		"neg": {"bbox_ok": bbox_ok},
	}
	_write_json("%s/scale_%s.json" % [out_dir, tag], result)
	print("PROBE_SCALE " + JSON.stringify(result))
	if OS.get_environment("DECOHERENCE_SCALE_TOGGLE") == "1":
		await _run_toggle(term, win, out_dir)


## F11 and Alt+Enter through the real key path. Fullscreen on the Xvfb display
## is the screen-sized window; the real monitor is a user-observable check.
func _run_toggle(term: TerminalGrid, win: Window, out_dir: String) -> void:
	var submitted := [0]
	term.line_submitted.connect(func(_t): submitted[0] += 1)
	var rows0 := term.rows_snapshot().size()
	var lr0 := _ext_rendered.size()
	await _press(KEY_F11)
	await _wait_mode(win, "fullscreen")
	var f11_to := _display_state(win)
	var f11_factor_ok := _scale_consistent(win)
	var persisted := _persisted_display()
	var silent_f11 := term.rows_snapshot().size() == rows0 and _ext_rendered.size() == lr0
	await _type_line("settings")
	await _wait_seconds(1.5)
	var shows := ""
	for line in _ext_rendered:
		var t := String(line)
		if t.strip_edges().begins_with("DISPLAY = "):
			shows = t.strip_edges().substr("DISPLAY = ".length()).split(" ", false)[0]
	await _press(KEY_F11)
	await _wait_mode(win, "windowed")
	var f11_back := _display_state(win)
	var back_factor_ok := _scale_consistent(win)
	# Alt+Enter with text in the buffer: it must toggle and must not submit.
	await _type_text("abc")
	var subs0: int = submitted[0]
	var rows1 := term.rows_snapshot().size()
	var lr1 := _ext_rendered.size()
	await _press(KEY_ENTER, 0, true)
	await _wait_mode(win, "fullscreen")
	var toggled := _display_state(win) == "fullscreen"
	var silent_alt := term.rows_snapshot().size() == rows1 and _ext_rendered.size() == lr1
	var alt_submitted: int = submitted[0] - subs0
	await _press(KEY_ENTER, 0, true)
	await _wait_mode(win, "windowed")
	for i in range(3):
		await _press(KEY_BACKSPACE)
	var result := {
		"f11": {"to": f11_to, "back": f11_back, "factor_matches": f11_factor_ok and back_factor_ok},
		"alt_enter": {"submitted": alt_submitted, "toggled": toggled},
		"persisted": persisted,
		"settings_shows": shows,
		"silent": silent_f11 and silent_alt,
	}
	_write_json(out_dir + "/toggle.json", result)
	print("PROBE_TOGGLE " + JSON.stringify(result))
