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

## Spec #549: the forest, understory and crown-shadow measurement of the world entry (world mode only).
const EntryTrees := preload("res://engine/stalag/tests/entry_trees.gd")
## Spec #551: the meadow ground's measurement (tile variants, tint, decals), run only when GRASS_OUT is set.
const GrassProbe := preload("res://engine/stalag/tests/grass_probe.gd")

## The second line of the default chat probe (Spec #542): once the contact has
## reached out, an ask keyword for the entanglement fact makes the first model turn.
const PROBE_QUESTION := "What is the entanglement?"

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
## on the real X11 session). Bumped 180.0 -> 240.0 (tester, Spec #373
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
	# Spec #542 amendment: the room answers a first message with a scripted voice and
	# an ordinary voice reaches out shortly after; the model is first reached by the
	# next line, which asks about the entanglement.
	Signals.handler_reply_complete.connect(_on_handler_reply_complete, CONNECT_ONE_SHOT)
	Signals.chatroom_handler_found.connect(_on_probe_contact, CONNECT_ONE_SHOT)
	Signals.terminal_line_submitted.emit(PROBE_MESSAGE)


func _on_probe_contact() -> void:
	Signals.terminal_line_submitted.emit(PROBE_QUESTION)


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
		if not (streamer.ring_ready() and streamer.pending_count() == 0 and streamer.settled() and w.is_grounded() and w.chunks_loaded() >= WORLD_MIN_CHUNKS):
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
	# Spec #549: the forest's own measurement runs inside this same real entry; its negative controls
	# act before the shot is saved, so the saved frame is the one the data and the pixels disagree on.
	var trees_mutation := OS.get_environment("ENTRY_TREES_MUTATE")
	if trees_mutation.is_empty():
		trees_mutation = "none"
	EntryTrees.prepare(w, trees_mutation)
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
	await EntryTrees.measure(w, path, shots_dir, trees_mutation)
	var grass_out := OS.get_environment("GRASS_OUT")
	if not grass_out.is_empty():
		await GrassProbe.run(w, path, shots_dir, grass_out)
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

const EXT_MODES := ["density", "router", "e2e_fastpath", "e2e_thinking", "e2e_dispatch", "e2e_settings", "e2e_relaunch", "e2e_corrupt", "seam", "shell_shot", "tone", "scale", "chat_features", "chat_layout", "chat_sendchat", "chat_contact_fake", "funnel_e2e", "funnel_refuse", "funnel_persist", "funnel_memory", "funnel_canon", "funnel_nolie", "funnel_mutate", "funnel_shots", "funnel_leak_live"]
const EXT_WATCHDOG_SECONDS := 3300.0
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
		"chat_features":
			await _run_chat_features()
		"chat_layout":
			await _run_chat_layout()
		"chat_sendchat":
			await _run_chat_sendchat()
		"chat_contact_fake":
			await _run_chat_contact_fake()
		"funnel_e2e", "funnel_refuse", "funnel_persist", "funnel_memory", "funnel_canon", "funnel_nolie", "funnel_mutate", "funnel_shots", "funnel_leak_live":
			await FunnelProbe.new(self).run(_ext_mode)
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


func _key_event(keycode: int, unicode: int = 0, alt: bool = false, ctrl: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = keycode as Key
	ev.unicode = unicode
	ev.alt_pressed = alt
	ev.ctrl_pressed = ctrl
	return ev


func _press(keycode: int, unicode: int = 0, alt: bool = false, ctrl: bool = false) -> void:
	Input.parse_input_event(_key_event(keycode, unicode, alt, ctrl))
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


## ===========================================================================
## Spec #542 modes (additive): the chatroom, driven through the real send path
## (TerminalGrid.line_submitted -> echo -> terminal_line_submitted -> shell ->
## submit_player_line -> Chatroom). Results go to
## $DECOHERENCE_PROBE_OUT_DIR/<mode>.part.json; tests/verify_chatroom.sh merges
## the parts into <MODE>.json. A fake model (tests/fake_handler.py) is reached
## through DECOHERENCE_OLLAMA_PORT; CHATROOM_FAKE_LOG and CHATROOM_FAKE_MODE_FILE
## name its request log and its mode file.
## ===========================================================================

const CR_BANNED := "(?i)handler|recruit|objective|quest|mission"
const CR_PROGRESS := "(?i)progress|checklist|learned|ticked|tick off|\\[x\\]|✓|✔|[0-9]+ ?/ ?[0-9]+ (facts|known|briefed)|try typing|you can (ask|type)|type (enter|accept)|hint|tutorial|tip:|ask me|objective|quest"
const CR_IDENT := "ENTRY_OFFERED|BRIEFING|offer_entry|\\bf_[a-z]+\\b|channel7|chatroom_|first_player_message"
const CR_HELLO := "hello anyone here"
const CR_ASKS := ["what is the entanglement", "who is the colonist", "how do orders work", "what is my job at the homestead"]
const CR_LAZY := ["ok", "hmm", "interesting", "go on", "right", "and then", "uh huh", "sure", "continue", "yes", "no", "maybe"]

var _cr_counts := {"reply": 0, "found": 0, "offered": 0, "granted": 0, "left": 0}
var _cr_req_at_found := -1


func _cr() -> Chatroom:
	return _scene().get_node("Chatroom")


func _cr_on_reply(_t: String) -> void:
	_cr_counts["reply"] += 1


func _cr_on_found() -> void:
	_cr_counts["found"] += 1
	_cr_req_at_found = _llm_node().request_count


func _cr_on_offered() -> void:
	_cr_counts["offered"] += 1


func _cr_on_granted() -> void:
	_cr_counts["granted"] += 1


func _cr_on_left() -> void:
	_cr_counts["left"] += 1


func _cr_connect() -> void:
	Signals.handler_reply_complete.connect(_cr_on_reply)
	Signals.chatroom_handler_found.connect(_cr_on_found)
	Signals.chatroom_entry_offered.connect(_cr_on_offered)
	Signals.chatroom_entry_granted.connect(_cr_on_granted)
	Signals.chatroom_left.connect(_cr_on_left)


## Spec #562: while the chat client is mounted a line is typed into it with real key
## events (one per character, then Enter); before that (the shell) it goes through
## the terminal's own line_submitted signal, as for every 542 probe.
func _cr_say(text: String) -> void:
	if _cc().is_mounted():
		_cc_burst(text)
		Input.parse_input_event(_key_event(KEY_ENTER))
		if not text.strip_edges().is_empty():
			_cc_expected += 1
		return
	_terminal_node().line_submitted.emit(text)


func _wait_for(pred: Callable, timeout_sec: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < end:
		if pred.call():
			return true
		await get_tree().process_frame
	return bool(pred.call())


func _cr_turns_done(cr: Chatroom) -> int:
	return cr.accepted_replies + cr.rejected_replies + cr.degraded_turns


## Leaves the current room (if inside), starts a fresh session and opens `chat`.
func _cr_new_session(seed_value: int) -> void:
	var cr := _cr()
	if cr.is_inside():
		_cr_say("leave")
		await _wait_frames(3)
	cr.reset_session(seed_value)
	_cr_say("chat")
	await _wait_for(cr.is_inside, 8.0)


## First message, then wait for the contact to reach out.
func _cr_contact() -> bool:
	var cr := _cr()
	_cr_say(CR_HELLO)
	return await _wait_for(func(): return cr.state == ChatroomScript.ST_ENGAGED, 8.0)


## One player line to the contact, then wait until that turn has completed.
func _cr_ask(text: String, timeout_sec: float = 20.0) -> Dictionary:
	var cr := _cr()
	var before := _cr_turns_done(cr)
	var t0 := Time.get_ticks_msec()
	_cr_say(text)
	var done: bool = await _wait_for(func(): return _cr_turns_done(cr) > before, timeout_sec)
	await _wait_frames(2)
	return {"done": done, "ms": Time.get_ticks_msec() - t0}


func _cr_ambient(cr: Chatroom) -> Array:
	return cr.emission_log.filter(func(e): return int(e["beat"]) == Chatroom.Beat.AMBIENT)


func _cr_body(row: String) -> String:
	var at := row.find("> ")
	return row.substr(at + 2) if at >= 0 else row


func _cr_letter_run(text: String) -> bool:
	var re := RegEx.new()
	re.compile("[A-Za-z]{3,}")
	return re.search(text) != null


func _cr_hits(pattern: String, rows: Array) -> int:
	var re := RegEx.new()
	re.compile(pattern)
	var n := 0
	for r in rows:
		if re.search(String(r)) != null:
			n += 1
	return n


func _cr_fake_log() -> Array:
	var out: Array = []
	var f := FileAccess.open(OS.get_environment("CHATROOM_FAKE_LOG"), FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)
	f.close()
	return out


## Structured completions only: the chat requests that carry a response format.
func _cr_fake_structured() -> Array:
	return _cr_fake_log().filter(func(r): return String(r.get("path", "")) == "/api/chat" and typeof(r.get("body", null)) == TYPE_DICTIONARY and r["body"].get("format", null) != null)


func _cr_set_mode(mode: String) -> void:
	var f := FileAccess.open(OS.get_environment("CHATROOM_FAKE_MODE_FILE"), FileAccess.WRITE)
	if f != null:
		f.store_string(mode)
		f.close()


func _cr_shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out_dir() + "/" + shot_name + ".png")


func _cr_part(mode: String, data: Dictionary) -> void:
	_write_json(_out_dir() + "/" + mode + ".part.json", data)


## --- leak: the #615 in-Godot think-leak check on the room's real forwarding path ----------------

## A think marker, a code fence, or a REASON_WINDOW-character run of the reasoning
## text that is NOT also in the prompt (a thinking model quotes the facts and the
## player's line in its reasoning, and a clean reply may quote them too; that overlap
## is the prompt, not a leak of the chain of thought).
func _cr_leak_scan(text: String, reasoning: String, prompt_blob: String) -> bool:
	var low := text.to_lower()
	if low.contains("<think") or low.contains("</think") or low.contains("reasoning_content") or text.contains("```"):
		return true
	if reasoning.length() >= ReplySanitizer.REASON_WINDOW:
		var flat_r := " ".join(reasoning.split(" ", false))
		var flat_t := " ".join(text.split(" ", false))
		var i := 0
		while i + ReplySanitizer.REASON_WINDOW <= flat_r.length():
			var window := flat_r.substr(i, ReplySanitizer.REASON_WINDOW)
			if flat_t.contains(window) and not prompt_blob.contains(window):
				return true
			i += 6
	return false


var _cr_reasoning_seen: String = ""


func _cr_on_probe_reasoning(reasoning: String) -> void:
	_cr_reasoning_seen = reasoning


## ===========================================================================

const CC_CONCEPT := "(?i)handler|recruit|contact|liaison|objective|quest|mission|tutorial|wizard|onboard|walkthrough|getting started|beginner|newcomer|briefing|assigned|progress|checklist|hint|tip:|try typing|welcome|guide|help"

var _cc_room_changes: int = 0
var _cc_last_active: String = ""
var _cc_expected: int = 0
var _cc_submits_base: int = 0
var _cc_driven: Dictionary = {}
var _cc_direct_calls: int = 0


func _cc() -> ChatClient:
	return _scene().get_node("ChatLayer/ChatClient")


func _cc_model() -> ChatModel:
	return _cr().model


## Lines that reached the room through the shell's pass-through: the room is its only
## consumer, and it counts each one it receives.
func _cc_submit_count() -> int:
	return _cc_submits_base + _cr().lines_received


func _cc_want(section: String) -> bool:
	var only := OS.get_environment("DECOHERENCE_CHAT_ONLY")
	return only.is_empty() or only.split(",").has(section)


func _cc_setup() -> void:
	_shell_node().world_dry_run = true
	_cr_connect()


## Typed text as one key event per character (no waiting between them).
func _cc_burst(text: String) -> void:
	for i in range(text.length()):
		Input.parse_input_event(_key_event(KEY_NONE, text.unicode_at(i)))


## Counts a change of the buffer on screen (read only).
func _cc_track() -> void:
	var now := _cc().active_buffer()
	if not _cc_last_active.is_empty() and now != _cc_last_active:
		_cc_room_changes += 1
	_cc_last_active = now


## A line: the characters, then Enter, then a frame.
func _cc_send(text: String) -> void:
	_cc_burst(text)
	Input.parse_input_event(_key_event(KEY_ENTER))
	if not text.strip_edges().is_empty():
		_cc_expected += 1
	await _wait_frames(2)
	_cc_track()


func _cc_key(keycode: int, ctrl: bool = false, alt: bool = false) -> void:
	Input.parse_input_event(_key_event(keycode, 0, alt, ctrl))
	await _wait_frames(2)
	_cc_track()


func _cc_open(seed_value: int) -> void:
	var cr := _cr()
	if cr.is_inside():
		_cr_say("leave")
		await _wait_frames(3)
	_cc_submits_base += cr.lines_received
	cr.reset_session(seed_value)
	_cr_say("chat")
	await _wait_for(func(): return _cc().is_mounted(), 8.0)
	await _wait_frames(3)
	_cc_last_active = _cc().active_buffer()


func _cc_rect(key: String) -> Rect2i:
	return _cc().layout_snapshot()[key]


func _cc_pane(ui: Array, key: String) -> Array:
	var r := _cc_rect(key)
	var out: Array = []
	for y in range(r.position.y, r.position.y + r.size.y):
		out.append(String(ui[y]).substr(r.position.x, r.size.x))
	return out


## Buffer ids in navigation order (read only).
func _cc_order() -> Array:
	return _cc_model().open_order()


func _cc_rows(buffer_id: String) -> Array:
	return _cc_model().rows_of(buffer_id)


func _cc_texts(buffer_id: String) -> Array:
	return _cc_rows(buffer_id).map(func(r): return ChatModel.plain_line(r))


func _cc_join_all() -> void:
	for rid in _cc_model().room_order:
		if not bool(_cc_model().rooms[rid]["joined"]):
			await _cc_send("/join " + String(rid))


func _cc_self() -> String:
	return _cc_model().self_handle


func _cc_contact() -> String:
	return _cr().contact_handle()


func _cc_sorted(a: Array) -> bool:
	var b := a.duplicate()
	b.sort()
	return a == b


func _cc_sig(e: Dictionary) -> String:
	return "%s|%s|%s" % [Color(e["color"]).to_html(), String(e["marker"]), String(e["tone"])]


func _cc_has_run(text: String) -> bool:
	return _cr_letter_run(text)


## Body of a voice row as drawn ("[HH:MM] <HANDLE> body" -> body).
func _cc_body(text: String) -> String:
	var at := text.find("> ")
	return text.substr(at + 2) if at >= 0 else text


func _cc_side_row(ui: Array, title: String) -> int:
	var side := _cc_rect("side")
	for y in range(side.position.y, side.position.y + side.size.y):
		var cells := String(ui[y]).substr(side.position.x, side.size.x)
		if cells.substr(3).strip_edges().begins_with(title) and (cells.substr(3, title.length()) == title):
			return y
	return -1


func _cc_unread_in_ui(ui: Array, title: String) -> int:
	var y := _cc_side_row(ui, title)
	if y < 0:
		return -1
	var side := _cc_rect("side")
	var cells := String(ui[y]).substr(side.position.x, side.size.x)
	var star := cells.find("*")
	return String(cells.substr(star + 1)).strip_edges().to_int() if star >= 0 else 0


func _cc_nav_total(ui: Array) -> int:
	var re := RegEx.new()
	re.compile("MESSAGES \\(([0-9]+)\\)")
	var m := re.search(String(ui[0]))
	return int(m.get_string(1)) if m != null else 0


func _cc_dm_logged(handle: String, since_ms: int) -> Dictionary:
	for e in _cr().emission_log:
		if int(e["beat"]) == Chatroom.Beat.DM and String(e["handle"]) == handle and int(e["t_ms"]) >= since_ms:
			return e
	return {}


func _cc_wait_dm_reply(handle: String, since_ms: int, timeout_sec: float) -> Dictionary:
	await _wait_for(func(): return not _cc_dm_logged(handle, since_ms).is_empty(), timeout_sec)
	return _cc_dm_logged(handle, since_ms)


func _cc_dm_pool(handle: String) -> Array:
	var dm = ChatroomScript.read_json(ChatroomScript.data_dir() + "/dm_script.json")
	return (dm["replies"].get(handle, []) as Array).map(func(r): return String(r["plain"]))


## --- features ----------------------------------------------------------------------------

func _run_chat_features() -> void:
	_cc_setup()
	var cr := _cr()
	var out := {}
	if _cc_want("entry"):
		await _cc_features_entry(out)
	if _cc_want("nav"):
		await _cc_features_nav(out)
	if _cc_want("people"):
		await _cc_features_people_and_switch(out)
	if _cc_want("directory"):
		await _cc_features_directory(out)
	if _cc_want("dm"):
		await _cc_features_dm(out)
	if _cc_want("unread"):
		await _cc_features_unread(out)
	if _cc_want("room"):
		await _cc_features_room(out)
	if _cc_want("cmd"):
		await _cc_features_cmd(out)
	if _cc_want("keys"):
		await _cc_features_keys(out)
	if _cc_want("leave"):
		await _cc_features_leave(out)
	out["keys"] = out.get("keys", {})
	var table: Dictionary = ChatroomScript.read_json(ChatroomScript.data_dir() + "/client_ui.json")["keys"]
	out["keys"]["table_actions"] = table.size()
	out["keys"]["actions_driven"] = _cc_driven.size()
	out["keys"]["driven"] = _cc_driven.keys()
	out["keys"]["direct_calls"] = _cc_direct_calls
	out["keys"]["submits"] = _cc_submit_count()
	out["keys"]["expected_submits"] = _cc_expected
	if out.has("entry"):
		out["entry"]["duplicate_submits"] = absi(_cc_submit_count() - _cc_expected)
	_cr_part("features", out)
	cr.reset_session(-1)


func _cc_features_entry(out: Dictionary) -> void:
	var cr := _cr()
	cr.reset_session(1001)
	var t0 := Time.get_ticks_msec()
	_cr_say("chat")
	await _wait_for(func(): return _cc().is_mounted() and _cc_rows(_cc().active_buffer()).size() >= 1, 8.0)
	var ms := Time.get_ticks_msec() - t0
	await _wait_frames(3)
	var term := _terminal_node()
	var panels := _panels_node()
	var crt_layer: CanvasLayer = _scene().get_node("CRTLayer")
	var chat_layer: CanvasLayer = _scene().get_node("ChatLayer")
	var active := _cc().active_buffer()
	var m := _cc_model()
	out["entry"] = {
		"first_buffer_kind": "room" if m.is_room(active) else "dm",
		"room_is_entry_room": active == String(cr.room_script().get("entry_room", "")),
		"dms_open": m.open_order().filter(func(id): return m.is_dm(String(id))).size(),
		"banner_rows": _cc_rows(active).size(),
		"ms_to_room": ms,
	}
	var mount := {
		"client_mounted": _cc().is_mounted(),
		"terminal_layer_hidden_while_open": not term.get_parent().visible,
		"panels_layer_hidden_while_open": not panels.get_parent().visible,
		"crt_overlay_visible": _scene().get_node("CRTLayer/CRTOverlay").visible and crt_layer.visible,
		"crt_layer_above_client": crt_layer.layer > chat_layer.layer,
	}
	await _cc_nav_snapshot(out)
	await _cc_send("hello")
	await _wait_seconds(3.5)
	_cr_say("leave")
	await _wait_frames(4)
	mount["restored_after_leave"] = term.get_parent().visible and panels.get_parent().visible and bool(term.get("_input_active"))
	mount["client_freed_or_hidden_after_leave"] = (not chat_layer.visible) and not _cc().is_mounted()
	out["mount"] = mount


func _cc_nav_snapshot(out: Dictionary) -> void:
	var ui_data: Dictionary = ChatroomScript.read_json(ChatroomScript.data_dir() + "/client_ui.json")
	var items: Array = ui_data["nav"]["items"]
	var ui := _cc().ui_text_snapshot()
	var row0 := String(ui[0])
	var all_labels := true
	var fkeys := true
	for it in items:
		if not row0.contains(String(it["label"])):
			all_labels = false
		if not row0.contains("[" + String(it["key"]) + " "):
			fkeys = false
	var lit := 0
	var plain := 0
	for s in _cc().segments_snapshot():
		if int(s["r"]) == 0 and String(s["t"]).begins_with("[F"):
			if Color(s["col"]) == Palette.ORANGE:
				lit += 1
			else:
				plain += 1
	var re := RegEx.new()
	re.compile("(?i)exit|leave|quit|close|help|guide|tutorial|start|learn")
	out["nav"] = {
		"items": items.size(),
		"labels_match_data": all_labels and row0.contains(String(ui_data["nav"]["brand"])),
		"on_row_zero": all_labels,
		"active_marked": lit == 1 and plain == items.size() - 1,
		"fkeys_ok": fkeys,
		"rendered_in_snapshot": not row0.strip_edges().is_empty(),
		"no_exit_label": re.search(row0) == null,
	}


func _cc_features_nav(out: Dictionary) -> void:
	if not out.has("nav"):
		await _cc_open(1001)
		await _cc_nav_snapshot(out)


## --- people and switching ------------------------------------------------------------------

func _cc_features_people_and_switch(out: Dictionary) -> void:
	var cr := _cr()
	await _cc_open(1002)
	await _cc_join_all()
	await _wait_frames(3)
	var m := _cc_model()
	var rosters: Array = []
	var count_ok := true
	var rows_ok := true
	var self_ok := true
	var once_ok := true
	var sorted_ok := true
	var header_agents_ok := true
	var old_words_absent := true
	for rid in m.room_order:
		await _cc_switch_to_room(String(rid))
		var snap := _cc().roster_snapshot()
		var handles: Array = snap.map(func(e): return String(e["handle"]))
		var ui := _cc().ui_text_snapshot()
		var header := String(ui[1])
		var re := RegEx.new()
		re.compile("AGENTS \\(([0-9]+)\\)")
		var mm := re.search(header)
		if mm == null or int(mm.get_string(1)) != snap.size() or snap.size() != m.roster(String(rid)).size():
			count_ok = false
		# Spec #562 A1: the header says how many agents ("N AGENTS"); the old words are gone
		var re_n := RegEx.new()
		re_n.compile("([0-9]+) AGENTS")
		var mn := re_n.search(header)
		if mn == null or int(mn.get_string(1)) != snap.size():
			header_agents_ok = false
		for ui_line in ui:
			if String(ui_line).contains("PEOPLE") or String(ui_line).contains("PRESENT"):
				old_words_absent = false
		if handles != m.roster(String(rid)):
			rows_ok = false
		self_ok = self_ok and handles.has(_cc_self())
		once_ok = once_ok and handles.count(_cc_self()) == 1
		sorted_ok = sorted_ok and _cc_sorted(handles)
		rosters.append(" ".join(PackedStringArray(handles)))
	var distinct := {}
	for r in rosters:
		distinct[r] = true
	# presence: wait until something joins or leaves in the room on screen, then compare
	var active := m.active
	var before: Array = _cc().roster_snapshot().map(func(e): return String(e["handle"]))
	var t0 := Time.get_ticks_msec()
	var changed: bool = await _wait_for(func(): return cr.emission_log.any(func(e): return int(e["beat"]) == Chatroom.Beat.PRESENCE and String(e["buffer"]) == active and int(e["t_ms"]) >= t0), 60.0)
	await _wait_frames(3)
	var after: Array = _cc().roster_snapshot().map(func(e): return String(e["handle"]))
	out["people"] = {
		"rooms_checked": m.room_order.size(),
		"count_matches_header": count_ok,
		"header_says_n_agents": header_agents_ok,
		"old_words_absent": old_words_absent,
		"rows_match_model": rows_ok,
		"includes_self": self_ok,
		"self_listed_once": once_ok,
		"sorted": sorted_ok,
		"per_room_differs": distinct.size() == rosters.size(),
		"updates_on_presence": changed and after != before and after == m.roster(active),
	}
	await _cc_features_switch(out)


func _cc_switch_to_room(rid: String) -> void:
	var guard := 0
	while _cc().active_buffer() != rid and guard < 12:
		await _cc_key(KEY_N, true)
		guard += 1


func _cc_features_switch(out: Dictionary) -> void:
	var m := _cc_model()
	var order := _cc_order()
	await _cc_switch_to_room(String(order[0]))
	var changes0 := _cc_room_changes
	var by_n := false
	var by_p := false
	var wraps := false
	var by_digit := false
	var by_cmd := false
	var by_f1 := false
	# Ctrl+N forward one, Ctrl+P back one
	var a := _cc().active_buffer()
	await _cc_key(KEY_N, true)
	by_n = _cc().active_buffer() == String(order[1])
	await _cc_key(KEY_P, true)
	by_p = _cc().active_buffer() == a
	_cc_driven["buffer_next"] = by_n
	_cc_driven["buffer_prev"] = by_p
	# wrap: from the last buffer Ctrl+N lands on the first, from the first Ctrl+P on the last
	await _cc_key(KEY_P, true)
	var first_back_to_last := _cc().active_buffer() == String(order[order.size() - 1])
	await _cc_key(KEY_N, true)
	wraps = first_back_to_last and _cc().active_buffer() == String(order[0])
	# Alt+3
	await _cc_key(KEY_3, false, true)
	by_digit = _cc().active_buffer() == String(order[2])
	_cc_driven["buffer_jump"] = by_digit
	# /join of a room already joined switches to it
	await _cc_send("/join " + String(order[4]))
	by_cmd = _cc().active_buffer() == String(order[4]) and _cc_order() == order
	# F1, Down, Enter
	await _cc_key(KEY_F1)
	var in_list := _cc().view_name() == "rooms"
	await _cc_key(KEY_DOWN)
	await _cc_key(KEY_ENTER)
	by_f1 = in_list and _cc().active_buffer() == String(order[0]) and _cc().view_name() == ""
	_cc_driven["nav_rooms"] = in_list
	# history is preserved across switches
	var rows_before := _cc_rows(String(order[1])).size()
	await _cc_switch_to_room(String(order[1]))
	await _cc_switch_to_room(String(order[2]))
	await _cc_switch_to_room(String(order[1]))
	var history_ok := _cc_rows(String(order[1])).size() >= rows_before
	# the active buffer is marked in the sidebar
	var ui := _cc().ui_text_snapshot()
	var title := String(m.buffers[m.active]["title"])
	var marked := false
	var y := _cc_side_row(ui, title)
	for s in _cc().segments_snapshot():
		if int(s["r"]) == y and String(s["t"]) == ">" and Color(s["col"]) == Palette.ORANGE:
			marked = true
	# a draft is kept per buffer
	var start := _cc().active_buffer()
	_cc_burst("draft-a")
	await _wait_frames(2)
	await _cc_key(KEY_N, true)
	var cleared := _cc().input_text() == ""
	_cc_burst("draft-b")
	await _wait_frames(2)
	await _cc_key(KEY_P, true)
	var back_a := _cc().input_text() == "draft-a" and _cc().active_buffer() == start
	await _cc_key(KEY_N, true)
	var back_b := _cc().input_text() == "draft-b"
	for i in range(8):
		Input.parse_input_event(_key_event(KEY_BACKSPACE))
	await _cc_key(KEY_P, true)
	for i in range(8):
		Input.parse_input_event(_key_event(KEY_BACKSPACE))
	await _wait_frames(2)
	out["switch"] = {
		"room_changes": _cc_room_changes - changes0,
		"by_ctrl_n": by_n,
		"by_ctrl_p": by_p,
		"by_alt_digit": by_digit,
		"by_command": by_cmd,
		"by_nav_f1": by_f1,
		"wraps_around": wraps,
		"history_preserved": history_ok,
		"active_marked": marked,
		"draft_input_per_buffer": cleared and back_a and back_b and _cc().input_text() == "",
	}


## --- directory -----------------------------------------------------------------------------------

func _cc_features_directory(out: Dictionary) -> void:
	var cr := _cr()
	await _cc_open(1004)
	var m := _cc_model()
	var data_rooms: int = cr.room_script()["rooms"].size()
	await _cc_key(KEY_F2)
	var opened := _cc().view_name() == "directory"
	_cc_driven["nav_directory"] = opened
	var ui := _cc().ui_text_snapshot()
	var main_lines := _cc_pane(ui, "main")
	var listed := 0
	var counts_ok := true
	var scrambled_ok := true
	var re := RegEx.new()
	re.compile("^\\s*[> ]\\s*(CHANNEL [0-9]+)\\s+([0-9]+)\\s\\s(.*)$")
	for line in main_lines:
		var mm := re.search(String(line).strip_edges(false, true))
		if mm == null:
			continue
		listed += 1
		var rid := m.room_id_for(mm.get_string(1))
		if rid.is_empty() or int(mm.get_string(2)) != m.member_count(rid):
			counts_ok = false
		var topic_shown := mm.get_string(3).strip_edges()
		if _cc_has_run(topic_shown) or topic_shown == String(m.rooms[rid]["topic"]):
			scrambled_ok = false
	# the selection wraps both ways
	await _cc_key(KEY_UP)
	var wrap_up := _cc().selection_index() == data_rooms - 1
	await _cc_key(KEY_DOWN)
	var wrap_down := _cc().selection_index() == 0
	# Esc closes it
	await _cc_key(KEY_ESCAPE)
	var esc := _cc().view_name() == ""
	_cc_driven["close_view"] = esc
	# join by Enter: F2, Down, Enter joins the second room
	await _cc_key(KEY_F2)
	await _cc_key(KEY_DOWN)
	var target := String(m.room_order[1])
	await _cc_key_submits(KEY_ENTER)
	await _wait_frames(3)
	var by_enter: bool = bool(m.rooms[target]["joined"]) and m.active == target and _cc().view_name() == ""
	var join_seen: bool = _cc_texts(target).any(func(t): return String(t).contains(_cc_self()) and String(t).contains("HAS JOINED"))
	var roster_self := _cc().roster_snapshot().any(func(e): return String(e["handle"]) == _cc_self())
	# join by command, idempotent re-join, unknown refused
	var third := String(m.room_order[2])
	await _cc_send("/join " + third)
	var by_cmd: bool = bool(m.rooms[third]["joined"]) and m.active == third
	var joins_before: int = _cc_texts(third).filter(func(t): return String(t).contains("HAS JOINED") and String(t).contains(_cc_self())).size()
	var order_before := _cc_order()
	await _cc_send("/join " + third)
	var joins_after: int = _cc_texts(third).filter(func(t): return String(t).contains("HAS JOINED") and String(t).contains(_cc_self())).size()
	var idempotent := joins_after == joins_before and _cc_order() == order_before
	var rows_before := _cc_rows(m.active).size()
	await _cc_send("/join nowhere")
	var refused: bool = _cc_order() == order_before and _cc_texts(m.active).size() == rows_before + 1 and String(_cc_texts(m.active)[-1]).contains(cr.ui_string("no_such_channel"))
	# a room that was left is still listed, but not joined
	await _cc_send("/part")
	await _cc_key(KEY_F2)
	var ui2 := _cc().ui_text_snapshot()
	var listed_after := 0
	for line in _cc_pane(ui2, "main"):
		if re.search(String(line).strip_edges(false, true)) != null:
			listed_after += 1
	var parted_ok: bool = (not bool(m.rooms[third]["joined"])) and listed_after == data_rooms
	await _cc_key(KEY_ESCAPE)
	out["directory"] = {
		"opened_by_f2": opened,
		"lists_all_rooms": listed == data_rooms,
		"rows": listed,
		"rooms_in_data": data_rooms,
		"member_counts_match": counts_ok,
		"topics_scrambled": scrambled_ok,
		"join_by_enter": by_enter,
		"join_by_command": by_cmd,
		"rejoin_idempotent": idempotent,
		"unknown_room_refused": refused,
		"esc_closes": esc,
		"joined_roster_has_self": roster_self,
		"join_line_seen": join_seen,
		"selection_wraps": wrap_up and wrap_down,
		"parted_room_listed_not_joined": parted_ok,
	}


## A key that makes the client submit a line (F2 + Enter, F4 + Enter, Ctrl+W, Ctrl+Q).
func _cc_key_submits(keycode: int, ctrl: bool = false) -> void:
	_cc_expected += 1
	await _cc_key(keycode, ctrl)


## One line to the contact thread, then wait for that turn to finish.
func _cc_ask_client(text: String, timeout_sec: float = 20.0) -> bool:
	var cr := _cr()
	var before := _cr_turns_done(cr)
	await _cc_send(text)
	var done: bool = await _wait_for(func(): return _cr_turns_done(cr) > before, timeout_sec)
	await _wait_frames(2)
	return done


## --- direct messages -------------------------------------------------------------------------

func _cc_features_dm(out: Dictionary) -> void:
	var cr := _cr()
	var llm := _llm_node()
	await _cc_open(1005)
	var m := _cc_model()
	var room_id := m.active
	var req0 := llm.request_count
	var t_send := Time.get_ticks_msec()
	await _cc_send("/msg XEN-4 hello")
	var open_by_msg: bool = m.active == "dm:XEN-4" and m.is_open("dm:XEN-4")
	var ui := _cc().ui_text_snapshot()
	var header := String(ui[1])
	var main_text := "\n".join(PackedStringArray(_cc_pane(ui, "main")))
	var own_pane: bool = header.contains(cr.ui_string("dm_header")) and header.contains("XEN-4") and main_text.contains("hello")
	var in_sidebar: bool = _cc_side_row(ui, "XEN-4") >= 0 and "\n".join(PackedStringArray(_cc_pane(ui, "side"))).contains(cr.ui_string("direct_title"))
	var dm_rows_clean: bool = _cc_rows("dm:XEN-4").all(func(r): return String(r["handle"]) == "XEN-4" or String(r["handle"]) == _cc_self())
	var room_clean: bool = not _cc_texts(room_id).any(func(t): return String(t).contains("hello"))
	var e := await _cc_wait_dm_reply("XEN-4", t_send, 8.0)
	var replied := not e.is_empty()
	var delay := int(e.get("t_ms", 0)) - t_send
	var body := _cc_body(String(e.get("row", "")))
	var scrambled := replied and body != String(e["plain"]) and not body.is_empty() and not _cc_has_run(body)
	var from_pool := replied and _cc_dm_pool("XEN-4").has(String(e["plain"]))
	var reply_llm := llm.request_count - req0
	# people list: Enter opens a direct message with the selected person
	await _cc_key(KEY_N, true)
	while _cc().active_buffer() != room_id:
		await _cc_key(KEY_N, true)
	await _cc_key(KEY_F4)
	var people_open := _cc().view_name() == "people"
	var roster: Array = _cc().roster_snapshot().map(func(r): return String(r["handle"]))
	var pick := ""
	for h in roster:
		if String(h) != _cc_self() and String(h) != _cc_contact() and String(h) != "XEN-4":
			pick = String(h)
			break
	for i in range(roster.find(pick)):
		await _cc_key(KEY_DOWN)
	await _cc_key_submits(KEY_ENTER)
	await _wait_frames(3)
	var by_people: bool = people_open and m.active == "dm:" + pick and m.is_open("dm:" + pick)
	_cc_driven["nav_people"] = people_open
	# a reply to a window that was closed in the meantime reopens it
	var t2 := Time.get_ticks_msec()
	await _cc_send("/msg OBL-17 ping")
	await _cc_key_submits(KEY_W, true)
	var closed_now := not m.is_open("dm:OBL-17")
	_cc_driven["close_buffer"] = closed_now
	var e2 := await _cc_wait_dm_reply("OBL-17", t2, 8.0)
	await _wait_frames(3)
	var reopened: bool = closed_now and not e2.is_empty() and m.is_open("dm:OBL-17") and m.unread_of("dm:OBL-17") > 0 and m.active != "dm:OBL-17"
	# closing keeps the history; opening it again shows the old rows
	await _cc_send("/msg XEN-4")
	var rows_before := _cc_rows("dm:XEN-4").size()
	await _cc_key_submits(KEY_W, true)
	var gone := not m.is_open("dm:XEN-4")
	await _cc_send("/msg XEN-4")
	var keeps: bool = gone and m.is_open("dm:XEN-4") and _cc_rows("dm:XEN-4").size() >= rows_before and _cc_texts("dm:XEN-4").any(func(t): return String(t).contains("hello"))
	# refusals
	var self_before := m.buffers.size()
	await _cc_send("/msg %s hi" % _cc_self())
	var to_self: bool = String(_cc_texts(m.active)[-1]).contains(cr.ui_string("self_message")) and m.buffers.size() == self_before
	await _cc_send("/msg NOBODY-0 hi")
	var to_unknown: bool = String(_cc_texts(m.active)[-1]).contains(cr.ui_string("no_such_user")) and not m.buffers.has("dm:NOBODY-0")
	# every ordinary person answers (nobody is silent)
	var people: Array = m.known_handles().filter(func(h): return String(h) != _cc_contact())
	var t3 := Time.get_ticks_msec()
	for h in people:
		await _cc_send("/msg %s ping" % String(h))
	await _wait_seconds(5.2)
	var silent := 0
	for h in people:
		if _cc_dm_logged(String(h), t3).is_empty():
			silent += 1
	out["dm"] = {
		"open_by_msg": open_by_msg,
		"open_by_people_select": by_people,
		"own_pane": own_pane,
		"isolated_from_room": dm_rows_clean and room_clean,
		"reply_scrambled": scrambled,
		"reply_llm_requests": reply_llm,
		"reply_delay_in_range": replied and delay >= 1000 and delay <= 4500,
		"reply_from_script_pool": from_pool,
		"incoming_to_closed_dm_reopens": reopened,
		"close_keeps_history": keeps,
		"dm_list_in_sidebar": in_sidebar,
		"to_self_refused": to_self,
		"to_unknown_refused": to_unknown,
		"silent_ambient_count": silent,
		"ambient_people_messaged": people.size(),
	}


## --- unread --------------------------------------------------------------------------------------

func _cc_dm_unread_sum_in_ui(ui: Array) -> int:
	var sum := 0
	var m := _cc_model()
	for id in m.buffers:
		if m.is_dm(String(id)) and m.is_open(String(id)):
			var n := _cc_unread_in_ui(ui, String(m.buffers[id]["title"]))
			sum += maxi(n, 0)
	return sum


func _cc_features_unread(out: Dictionary) -> void:
	var cr := _cr()
	await _cc_open(1006)
	var m := _cc_model()
	await _cc_send("/join channel3")
	await _cc_send("/join channel12")
	# channel12 is on screen; the entry room fills up behind it
	var away := "channel7"
	var grew: bool = await _wait_for(func(): return m.unread_of(away) >= 2, 40.0)
	await _wait_frames(3)
	var ui := _cc().ui_text_snapshot()
	var marker_text := _cc_unread_in_ui(ui, String(m.buffers[away]["title"]))
	var increments: bool = grew and marker_text == m.unread_of(away)
	var in_ui: bool = marker_text > 0
	# pixels of that sidebar row's right end, unread then read
	var factor := get_window().content_scale_factor
	var side := _cc_rect("side")
	var y := _cc_side_row(ui, String(m.buffers[away]["title"]))
	var cell := Rect2(float((side.position.x + side.size.x - 7) * ChatLayout.CELL_W), float(y * ChatLayout.CELL_H), float(6 * ChatLayout.CELL_W), float(ChatLayout.CELL_H))
	var img1 := await _grab()
	var lit_unread := int(_region_stats(img1, _phys(cell, factor))["lit"])
	await _cc_switch_to_room(away)
	await _wait_frames(3)
	var ui2 := _cc().ui_text_snapshot()
	var cleared: bool = m.unread_of(away) == 0 and _cc_unread_in_ui(ui2, String(m.buffers[away]["title"])) == 0
	var img2 := await _grab()
	var lit_read := int(_region_stats(img2, _phys(cell, factor))["lit"])
	# the buffer on screen never counts, however much arrives
	var seen0 := cr.emission_log.filter(func(e): return String(e["buffer"]) == away and int(e["beat"]) == Chatroom.Beat.AMBIENT).size()
	await _wait_seconds(8.0)
	var seen1 := cr.emission_log.filter(func(e): return String(e["buffer"]) == away and int(e["beat"]) == Chatroom.Beat.AMBIENT).size()
	var never_active: bool = m.unread_of(away) == 0 and seen1 > seen0
	# a room left alone keeps its count while other buffers are visited
	await _cc_key(KEY_1, false, true)
	await _cc_key(KEY_3, false, true)
	var held: bool = await _wait_for(func(): return m.unread_of("channel3") >= 2, 40.0)
	var n3: int = m.unread_of("channel3")
	await _cc_key(KEY_1, false, true)
	await _cc_key(KEY_3, false, true)
	await _cc_key(KEY_1, false, true)
	var survives: bool = held and m.unread_of("channel3") >= n3
	# a reply into a direct message that is not on screen marks it and the nav bar
	await _cc_send("/msg XEN-4 hi")
	var t0 := Time.get_ticks_msec()
	await _cc_key(KEY_1, false, true)
	var e := await _cc_wait_dm_reply("XEN-4", t0 - 600, 8.0)
	await _wait_frames(3)
	var ui3 := _cc().ui_text_snapshot()
	var dm_marks: bool = not e.is_empty() and m.unread_of("dm:XEN-4") == 1 and _cc_nav_total(ui3) == 1 and _cc_unread_in_ui(ui3, "XEN-4") == 1
	await _cc_send("/msg NUL-9 hi")
	var t1 := Time.get_ticks_msec()
	await _cc_key(KEY_1, false, true)
	var e2 := await _cc_wait_dm_reply("NUL-9", t1 - 600, 8.0)
	await _wait_frames(3)
	var ui4 := _cc().ui_text_snapshot()
	var total_ok: bool = not e2.is_empty() and m.unread_total() == 2 and _cc_nav_total(ui4) == 2 and _cc_dm_unread_sum_in_ui(ui4) == 2
	# F3 opens the newest unread direct message; with none unread it focuses the list
	await _cc_key(KEY_F3)
	var newest := _cc().active_buffer() == "dm:NUL-9"
	await _cc_key(KEY_F3)
	await _cc_key(KEY_F3)
	_cc_driven["nav_messages"] = newest
	# visiting everything zeroes everything
	await _cc_key(KEY_ESCAPE)
	# Viewing a buffer zeroes it. Traffic keeps arriving in the buffers not on screen while the
	# others are visited, so "zero at the end" would be a race: instead every buffer must read zero
	# the moment it is viewed, and afterwards hold at least the counting rows that arrived after
	# it was left (read once it is certainly off screen) and at most those that arrived after it
	# was reached (a row that lands while it is still on screen is the only slack).
	var arrived := {}
	var left := {}
	var zero_when_viewed := true
	for i in range(m.open_order().size() + 1):
		var before := _cc().active_buffer()
		await _cc_key(KEY_N, true)
		left[before] = m.rows_of(before).size()
		var cur := _cc().active_buffer()
		zero_when_viewed = zero_when_viewed and m.unread_of(cur) == 0
		arrived[cur] = m.rows_of(cur).size()
	var exact := true
	for id in m.open_order():
		var low := 0
		var high := 0
		for r in m.rows_of(String(id)).slice(int(left.get(String(id), 0))):
			if String(r["kind"]) == "voice" or String(r["kind"]) == "action":
				low += 1
		for r in m.rows_of(String(id)).slice(int(arrived.get(String(id), 0))):
			if String(r["kind"]) == "voice" or String(r["kind"]) == "action":
				high += 1
		if String(id) == _cc().active_buffer():
			low = 0
			high = 0
		var got: int = m.unread_of(String(id))
		if got < low or got > high:
			exact = false
	var ui5 := _cc().ui_text_snapshot()
	var all_zero := zero_when_viewed and exact and _cc_nav_total(ui5) == m.unread_total()
	out["unread"] = {
		"increments_while_away": increments,
		"clears_on_view": cleared,
		"active_never_counts": never_active,
		"nav_total_equals_sum_of_buffers": total_ok,
		"sidebar_marker_in_ui_text": in_ui,
		"marker_pixels_differ_from_read_row": lit_unread > lit_read,
		"dm_incoming_marks_dm_and_nav": dm_marks,
		"survives_switching": survives,
		"zero_after_visiting_all": all_zero,
		"lit_unread": lit_unread,
		"lit_read": lit_read,
	}


## --- the chat room itself ----------------------------------------------------------------------------

func _cc_main_snapshot() -> Array:
	return _cc_pane(_cc().ui_text_snapshot(), "main")


func _cc_features_room(out: Dictionary) -> void:
	var cr := _cr()
	await _cc_open(1007)
	var m := _cc_model()
	var room := {}
	room["scrollback_cap"] = ChatModel.MAX_ROWS
	# cursor editing: Left, Right, Home, End, Delete, Backspace
	_cc_burst("abcd")
	await _cc_key(KEY_LEFT)
	await _cc_key(KEY_LEFT)
	_cc_burst("X")
	await _wait_frames(1)
	var e1 := _cc().input_text() == "abXcd"
	await _cc_key(KEY_DELETE)
	var e2 := _cc().input_text() == "abXd"
	await _cc_key(KEY_HOME)
	_cc_burst("Y")
	await _wait_frames(1)
	var e3 := _cc().input_text() == "YabXd"
	await _cc_key(KEY_END)
	_cc_burst("Z")
	await _cc_key(KEY_BACKSPACE)
	var e4 := _cc().input_text() == "YabXd"
	for i in range(6):
		Input.parse_input_event(_key_event(KEY_BACKSPACE))
	await _wait_frames(2)
	room["cursor_editing_ok"] = e1 and e2 and e3 and e4 and _cc().input_text() == ""
	# name completion
	var names: Array = _cc().roster_snapshot().map(func(r): return String(r["handle"])).filter(func(h): return h != _cc_self())
	names.sort()
	var want := String(names[0])
	_cc_burst(want.substr(0, 3).to_lower())
	await _cc_key(KEY_TAB)
	var tab_ok := _cc().input_text().begins_with(want)
	_cc_driven["nick_complete"] = tab_ok
	room["nick_complete_tab"] = tab_ok
	for i in range(20):
		Input.parse_input_event(_key_event(KEY_BACKSPACE))
	await _wait_frames(2)
	# a long input is capped
	_cc_burst("a".repeat(230))
	await _wait_frames(2)
	room["long_input_capped_200"] = _cc().input_text().length() == 200
	for i in range(210):
		Input.parse_input_event(_key_event(KEY_BACKSPACE))
	await _wait_frames(2)
	# a long line wraps inside the pane (it is also the first message, answered by a scripted voice)
	var long_line := " ".join(PackedStringArray(["alphabet"] + range(24).map(func(i): return "word%d" % i)))
	await _cc_send(long_line)
	await _wait_seconds(3.8)
	var gutters_clear := true
	var ui := _cc().ui_text_snapshot()
	for key in ["gutter_a", "gutter_b"]:
		var g := _cc_rect(key)
		for y in range(g.position.y, g.position.y + g.size.y):
			if String(ui[y]).substr(g.position.x, g.size.x).strip_edges() != "":
				gutters_clear = false
	var wrapped := ChatModel.format_row({"kind": "self", "handle": _cc_self(), "text": long_line, "t": "00:00"}, _cc_rect("main").size.x - 1)
	room["rows_wrapped_within_pane"] = gutters_clear and wrapped.size() >= 2 and _cc().stats_snapshot()["overflow"] == 0 and String(ui[_cc_rect("main").position.y]).length() == _cc().layout_snapshot()["cols"]
	# a scripted room for the rest: history, echo, empty lines, the flood
	await _cc_send("/join channel3")
	await _cc_send("h1")
	await _cc_send("h2")
	await _cc_key(KEY_UP)
	var h1 := _cc().input_text() == "h2"
	await _cc_key(KEY_UP)
	var h2 := _cc().input_text() == "h1"
	await _cc_key(KEY_DOWN)
	var h3 := _cc().input_text() == "h2"
	await _cc_key(KEY_DOWN)
	var h4 := _cc().input_text() == ""
	_cc_driven["history_prev"] = h1 and h2
	_cc_driven["history_next"] = h3 and h4
	room["history_up_down"] = h1 and h2 and h3 and h4
	await _cc_send("echo check")
	var own: Array = _cc_rows("channel3").filter(func(r): return String(r["kind"]) == "self")
	var echoed: bool = not own.is_empty() and String(own[-1]["handle"]) == _cc_self() and String(own[-1]["text"]) == "echo check" and _cc().rows_snapshot().any(func(r): return String(r["text"]).ends_with("<%s> echo check" % _cc_self()))
	_cc_driven["send"] = echoed
	room["own_line_echoed_with_own_handle"] = echoed
	var rows0 := _cc_rows("channel3").size()
	var subs0 := _cc_submit_count()
	await _cc_key(KEY_ENTER)
	Input.parse_input_event(_key_event(KEY_NONE, 32))
	Input.parse_input_event(_key_event(KEY_NONE, 32))
	await _cc_key(KEY_ENTER)
	await _wait_frames(3)
	room["empty_line_ignored"] = _cc_rows("channel3").filter(func(r): return String(r["kind"]) == "self").size() == own.size() and _cc_submit_count() == subs0 and _cc().input_text() == ""
	# the flood: more than the cap, the oldest rows are dropped
	for i in range(270):
		await _cc_send("x%d" % i)
	await _wait_frames(3)
	var texts := _cc_texts("channel3")
	room["scrollback_trimmed_oldest"] = _cc_rows("channel3").size() == ChatModel.MAX_ROWS and not texts.any(func(t): return String(t).contains(_cc_self()) and String(t).contains("HAS JOINED"))
	# scrolling back and forward
	await _cc_key(KEY_PAGEUP)
	var up1: bool = int(m.buffers["channel3"]["scroll"]) > 0 and String(_cc().ui_text_snapshot()[_cc_rect("status").position.y]).contains("BACK")
	_cc_driven["scroll_up"] = up1
	room["pageup_scrolls"] = up1
	await _cc_key(KEY_PAGEUP)
	await _cc_key(KEY_PAGEUP)
	for i in range(5):
		await _cc_key(KEY_PAGEDOWN)
	var down1: bool = int(m.buffers["channel3"]["scroll"]) == 0
	_cc_driven["scroll_down"] = down1
	room["pagedown_to_live"] = down1
	await _cc_key(KEY_PAGEUP)
	await _cc_key(KEY_PAGEUP)
	await _cc_key(KEY_END, true)
	var live1: bool = int(m.buffers["channel3"]["scroll"]) == 0
	_cc_driven["scroll_live"] = live1
	room["ctrl_end_to_live"] = live1
	# new rows do not yank a scrolled-back view
	await _cc_key(KEY_PAGEUP)
	var view_before := _cc_main_snapshot()
	var scroll_before: int = int(m.buffers["channel3"]["scroll"])
	var arrivals0 := cr.emission_log.filter(func(e): return String(e["buffer"]) == "channel3").size()
	await _wait_for(func(): return cr.emission_log.filter(func(e): return String(e["buffer"]) == "channel3").size() >= arrivals0 + 2, 20.0)
	await _wait_frames(3)
	room["new_rows_do_not_yank_when_scrolled"] = _cc_main_snapshot() == view_before and int(m.buffers["channel3"]["scroll"]) > scroll_before
	await _cc_key(KEY_END, true)
	# every row carries a timestamp
	var re := RegEx.new()
	re.compile("^\\[[0-9]{2}:[0-9]{2}\\] ")
	var all_rows: Array = _cc().rows_snapshot()
	room["timestamps_all_rows"] = all_rows.size() > 0 and all_rows.all(func(r): return re.search(String(r["text"])) != null)
	# scripted joins and leaves show up as lines (the player's own join lines do not count)
	var jl := RegEx.new()
	jl.compile("HAS (JOINED|LEFT)")
	var scripted_presence := func() -> int:
		var n := 0
		for r in _cc().rows_snapshot():
			if String(r["kind"]) == "presence" and jl.search(String(r["text"])) != null and not String(r["text"]).contains(_cc_self()):
				n += 1
		return n
	await _wait_for(func(): return int(scripted_presence.call()) >= 3, 100.0)
	room["join_leave_lines"] = int(scripted_presence.call())
	out["room"] = room


## --- slash commands ------------------------------------------------------------------------------------

func _cc_features_cmd(out: Dictionary) -> void:
	var cr := _cr()
	var llm := _llm_node()
	await _cc_open(1008)
	var m := _cc_model()
	var found0 := int(_cr_counts["found"])
	var req0 := llm.request_count
	var cmd := {}
	await _cc_send("/join channel19")
	cmd["join"] = bool(m.rooms["channel19"]["joined"]) and m.active == "channel19"
	await _cc_send("/list")
	var listed: Array = _cc_texts(m.active).slice(-5)
	cmd["list"] = listed.size() == 5 and listed.all(func(t): return String(t).contains("CHANNEL"))
	await _cc_send("/who")
	var who: Array = m.roster(m.active)
	var who_rows: Array = _cc_texts(m.active).slice(-who.size())
	var who_ok := true
	for i in range(who.size()):
		who_ok = who_ok and who_rows[i] == who[i]
	cmd["who"] = who_ok
	await _cc_send("/clear")
	cmd["clear"] = _cc_rows("channel19").size() == 0
	await _cc_send("/zork")
	var unk := String(_cc_texts(m.active)[-1])
	cmd["unknown_in_register"] = unk == cr.ui_string("unknown_command")
	var sug := RegEx.new()
	sug.compile("(?i)join|part|list|who|msg|clear|try|mean|type|usage")
	cmd["unknown_has_no_suggestion"] = sug.search(unk) == null
	await _cc_send("/msg XEN-4")
	var opened := m.active == "dm:XEN-4"
	await _cc_send("/me")
	await _cc_send("/msg")
	await _cc_send("/msg XEN-4   ")
	await _cc_send("/part")
	cmd["part"] = opened and not m.is_open("dm:XEN-4") and m.is_open("channel19")
	cmd["msg"] = opened
	await _cc_send("/part")
	await _wait_seconds(5.0)
	cmd["commands_not_counted_as_messages"] = int(_cr_counts["found"]) == found0 and cr.state == ChatroomScript.ST_ROOM and llm.request_count == req0 and not cr.is_busy()
	# the last remaining buffer is never closed
	var last_before := _cc_order()
	await _cc_send("/part")
	cmd["part_last_buffer_refused"] = last_before.size() == 1 and _cc_order() == last_before and String(_cc_texts(m.active)[-1]) == cr.ui_string("last_buffer") and not _cc_texts(m.active).any(func(t): return String(t).contains("HAS LEFT"))
	# /me is a sent message: an action row, and it starts the contact timer
	await _cc_send("/me waves")
	var mine_rows: Array = _cc_rows(m.active).filter(func(r): return String(r["kind"]) == "action")
	cmd["me"] = not mine_rows.is_empty() and ChatModel.plain_line(mine_rows[-1]) == "* %s waves" % _cc_self()
	out["cmd"] = cmd


## --- every key of the table, and the fullscreen toggles ----------------------------------------------------

func _cc_features_keys(out: Dictionary) -> void:
	await _cc_open(1011)
	var keys := {}
	var win := get_window()
	var input_before := _cc().input_text()
	await _press(KEY_F11)
	await _wait_mode(win, "fullscreen")
	var f11_fs := _display_state(win) == "fullscreen"
	await _press(KEY_F11)
	await _wait_mode(win, "windowed")
	keys["f11_still_toggles_fullscreen"] = f11_fs and _display_state(win) == "windowed" and _cc().input_text() == input_before
	_cc_burst("abc")
	await _wait_frames(2)
	var subs0 := _cc_submit_count()
	await _press(KEY_ENTER, 0, true)
	await _wait_mode(win, "fullscreen")
	var alt_fs := _display_state(win) == "fullscreen"
	var kept := _cc().input_text() == "abc" and _cc_submit_count() == subs0
	await _press(KEY_ENTER, 0, true)
	await _wait_mode(win, "windowed")
	keys["alt_enter_still_toggles"] = alt_fs and kept and _display_state(win) == "windowed"
	for i in range(3):
		Input.parse_input_event(_key_event(KEY_BACKSPACE))
	await _wait_frames(2)
	for k in [KEY_F1, KEY_F2, KEY_F3, KEY_F4]:
		await _cc_key(k)
		await _cc_key(KEY_ESCAPE)
	keys["fkeys_not_inserted_as_text"] = _cc().input_text() == "" and _cc().view_name() == ""
	out["keys"] = keys


## --- leaving -----------------------------------------------------------------------------------------------

func _cc_left_ok(shell: ShellController) -> bool:
	return shell.current_state_name() == "SHELL" and not _cc().is_mounted() and bool(_terminal_node().get("_input_active"))


func _cc_features_leave(out: Dictionary) -> void:
	var shell := _shell_node()
	var res := {}
	var each := true
	var i := 0
	for word in ["leave", "exit", "quit", "/leave", "/exit", "/quit"]:
		await _cc_open(1012 + i)
		await _cc_send(String(word))
		await _wait_frames(4)
		if not _cc_left_ok(shell):
			each = false
		i += 1
	res["each_word_returns_to_shell"] = each
	await _cc_open(1020)
	await _cc_key_submits(KEY_Q, true)
	await _wait_frames(4)
	res["ctrl_q_returns_to_shell"] = _cc_left_ok(shell)
	_cc_driven["quit"] = res["ctrl_q_returns_to_shell"]
	res["terminal_input_active"] = bool(_terminal_node().get("_input_active"))
	res["state_is_shell"] = shell.current_state_name() == "SHELL"
	var mark := _ext_rendered.size()
	await _type_line("dir")
	var alive: bool = await _wait_for(func(): return _ext_rendered.slice(mark).any(func(t): return String(t).begins_with("DIRECTORY LISTING")), 5.0)
	res["shell_alive"] = alive
	# leaving and coming back resumes the buffers
	await _cc_open(1021)
	await _cc_send("/join channel3")
	await _cc_send("/msg XEN-4 yo")
	var order_before := _cc_order()
	var counts_before: Array = order_before.map(func(id): return _cc_rows(String(id)).size())
	var active_before := _cc().active_buffer()
	_cr_say("leave")
	await _wait_frames(4)
	_cr_say("chat")
	await _wait_for(func(): return _cc().is_mounted(), 8.0)
	await _wait_frames(3)
	var order_after := _cc_order()
	var resumed := order_after == order_before
	for n in range(order_after.size()):
		if _cc_rows(String(order_after[n])).size() < int(counts_before[n]):
			resumed = false
	res["reenter_resumes_buffers"] = resumed and _cc().active_buffer() == active_before
	var hint := RegEx.new()
	hint.compile("(?i)exit|leave|quit|close|help|ctrl[+]")
	var seen_hint := 0
	for line in _cc().ui_text_snapshot():
		if hint.search(String(line)) != null:
			seen_hint += 1
	for r in _cc().rows_snapshot():
		if String(r["kind"]) != "self" and hint.search(String(r["text"])) != null:
			seen_hint += 1
	res["no_leave_hint_rendered"] = seen_hint == 0
	out["leave"] = res


## --- layout and pixels -------------------------------------------------------------------------------------

## Lit pixels (as _palette_stats counts them) split by hue band, plus the lit bounding box.
func _cc_palette(img: Image) -> Dictionary:
	img.convert(Image.FORMAT_RGB8)
	var data := img.get_data()
	var w := img.get_width()
	var h := img.get_height()
	var lit := 0
	var teal := 0
	var orange := 0
	var off := 0
	var x0 := 1 << 30
	var y0 := 1 << 30
	var x1 := -1
	var y1 := -1
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var o := (y * w + x) * 3
			var r := int(data[o])
			var g := int(data[o + 1])
			var b := int(data[o + 2])
			var mx := maxi(r, maxi(g, b))
			if mx < 60:
				continue
			var mn := mini(r, mini(g, b))
			var d := float(mx - mn)
			if d / float(mx) < 0.12 and mx < 100:
				continue
			lit += 1
			x0 = mini(x0, x)
			y0 = mini(y0, y)
			x1 = maxi(x1, x)
			y1 = maxi(y1, y)
			var hue := -1.0
			if d / float(mx) >= 0.12:
				if mx == r:
					hue = fposmod(60.0 * (float(g - b) / d), 360.0)
				elif mx == g:
					hue = 60.0 * (2.0 + float(b - r) / d)
				else:
					hue = 60.0 * (4.0 + float(r - g) / d)
			if hue >= 165.0 and hue <= 185.0:
				teal += 1
			elif hue >= 22.0 and hue <= 38.0:
				orange += 1
			else:
				off += 1
	var lf := maxf(1.0, float(lit))
	return {"lit": lit, "teal_frac": float(teal) / lf, "orange_frac": float(orange) / lf, "off_frac": float(off) / lf, "x0": x0, "y0": y0, "x1": x1, "y1": y1}


func _cc_cells(r: Rect2i, factor: float) -> Rect2i:
	return _phys(Rect2(float(r.position.x * ChatLayout.CELL_W), float(r.position.y * ChatLayout.CELL_H), float(r.size.x * ChatLayout.CELL_W), float(r.size.y * ChatLayout.CELL_H)), factor)


func _cc_lit_frac(img: Image, rects: Array) -> float:
	var lit := 0
	var n := 0
	for r in rects:
		var st := _region_stats(img, r)
		lit += int(st["lit"])
		n += int(st["n"])
	return float(lit) / float(n) if n > 0 else 0.0


## Text that reaches past its pane edge or into a gutter column.
func _cc_overflow_rows(ui: Array, layout: Dictionary) -> int:
	var n := 0
	for key in ["gutter_a", "gutter_b"]:
		var g: Rect2i = layout[key]
		for y in range(g.position.y, g.position.y + g.size.y):
			if g.size.x > 0 and String(ui[y]).substr(g.position.x, g.size.x).strip_edges() != "":
				n += 1
	var cols := int(layout["cols"])
	for line in ui:
		if String(line).length() > cols:
			n += 1
	return n


func _run_chat_layout() -> void:
	_cc_setup()
	var cr := _cr()
	var win := get_window()
	var factor := win.content_scale_factor
	var tag := "%dx%d" % [win.size.x, win.size.y]
	var out_dir := _out_dir()
	await _cc_open(3001)
	await _cc_send("/join channel3")
	await _cc_send("hello anyone here")
	await _cc_send("/msg XEN-4 hi")
	await _cc_key(KEY_P, true)
	await _wait_seconds(5.0)
	_cc_burst("typing a line")
	await _wait_frames(4)
	var img := await _grab()
	img.save_png("%s/layout_%s.png" % [out_dir, tag])
	var layout := _cc().layout_snapshot()
	var ui := _cc().ui_text_snapshot()
	var rect_list := ChatLayout.rect_list(layout)
	var stats := _cc().stats_snapshot()
	var gutters: Array = [_cc_cells(layout["gutter_a"], factor), _cc_cells(layout["gutter_b"], factor)]
	var w := img.get_width()
	var h := img.get_height()
	var frame: Array = [Rect2i(0, 0, w, 3), Rect2i(0, h - 3, w, 3), Rect2i(0, 0, 3, h), Rect2i(w - 3, 0, 3, h)]
	var grid_w := int(layout["cols"]) * ChatLayout.CELL_W
	var grid_h := int(layout["rows"]) * ChatLayout.CELL_H
	if int(grid_w * factor) < w:
		frame.append(Rect2i(int(grid_w * factor), 0, w - int(grid_w * factor), h))
	if int(grid_h * factor) < h:
		frame.append(Rect2i(0, int(grid_h * factor), w, h - int(grid_h * factor)))
	var pal := _cc_palette(img)
	var in_client: bool = int(pal["x0"]) >= 0 and int(pal["y0"]) >= 0 and int(pal["x1"]) < int(grid_w * factor) and int(pal["y1"]) < int(grid_h * factor)
	var png_bytes := FileAccess.get_file_as_bytes("%s/layout_%s.png" % [out_dir, tag]).size()
	var term := _terminal_node()
	var px := {
		"nav_lit": int(_region_stats(img, _cc_cells(layout["nav"], factor))["lit"]),
		"side_lit": int(_region_stats(img, _cc_cells(layout["side"], factor))["lit"]),
		"main_lit": int(_region_stats(img, _cc_cells(layout["main"], factor))["lit"]),
		"people_lit": int(_region_stats(img, _cc_cells(layout["people"], factor))["lit"]),
		"input_lit": int(_region_stats(img, _cc_cells(layout["input"], factor))["lit"]),
		"gutter_lit_frac": _cc_lit_frac(img, gutters),
		"margin_lit_frac": _cc_lit_frac(img, frame),
		"teal_frac_of_lit": pal["teal_frac"],
		"orange_frac_of_lit": pal["orange_frac"],
		"offpalette_frac_of_lit": pal["off_frac"],
		"lit_bbox_inside_client": in_client,
	}
	var res := {
		"win": tag,
		"factor": factor,
		"cols": int(layout["cols"]),
		"rows": int(layout["rows"]),
		"tier": String(layout["tier"]),
		"rect_overlaps": ChatLayout.overlap_count(rect_list),
		"out_of_bounds": ChatLayout.out_of_bounds_count(rect_list, int(layout["cols"]), int(layout["rows"])),
		"overflow_rows": int(stats["overflow"]) + _cc_overflow_rows(ui, layout),
		"names_truncated": int(stats["truncated"]),
		"nav_visible": String(ui[0]).contains("Q-ENT") and px["nav_lit"] > 0,
		"input_visible": String(ui[ui.size() - 1]).contains("typing a line") and px["input_lit"] > 0,
		"side_cols": (layout["side"] as Rect2i).size.x,
		"main_cols": (layout["main"] as Rect2i).size.x,
		"people_cols": (layout["people"] as Rect2i).size.x,
		"px": px,
		"crt": {"scanline_spacing_px": float(_overlay_material().get_shader_parameter("scanline_spacing_px"))},
		"png_bytes": png_bytes,
		"shot_is_client": _cc().is_mounted() and not term.get_parent().visible and not _panels_node().get_parent().visible and px["nav_lit"] > 0 and px["side_lit"] > 0,
	}
	if tag == "1920x1080":
		res["neg"] = _cc_layout_negatives(img, layout, factor)
	if tag == "1280x720" and OS.get_environment("DECOHERENCE_CHAT_RESIZE") == "1":
		res["resize"] = await _cc_resize_run(win)
	_write_json("%s/layout_%s.json" % [out_dir, tag], res)
	print("PROBE_CHAT_LAYOUT " + JSON.stringify(res))
	cr.reset_session(-1)


## The instruments, proven on planted violations.
func _cc_layout_negatives(img: Image, layout: Dictionary, factor: float) -> Dictionary:
	var grey := Image.create(200, 100, false, Image.FORMAT_RGB8)
	grey.fill(Color(0.02, 0.05, 0.05))
	grey.fill_rect(Rect2i(10, 10, 120, 40), Color(0.7, 0.7, 0.7))
	var grey_stats := _cc_palette(grey)
	var gutters: Array = [_cc_cells(layout["gutter_a"], factor), _cc_cells(layout["gutter_b"], factor)]
	var planted := Image.new()
	planted.copy_from(img)
	var g: Rect2i = gutters[0]
	planted.fill_rect(Rect2i(g.position.x, g.position.y + 100, g.size.x, 40), Color(1, 1, 1))
	var shifted := ChatLayout.compute(1920, 1080)
	var sm: Rect2i = shifted["main"]
	shifted["main"] = Rect2i(sm.position.x - 6, sm.position.y, sm.size.x, sm.size.y)
	var long_ui: Array = _cc().ui_text_snapshot().duplicate()
	long_ui[10] = String(long_ui[10]) + "x"
	var dark := Image.create(64, 64, false, Image.FORMAT_RGB8)
	dark.fill(Palette.BG)
	var low := ChatLayout.compute(1000, 600)
	return {
		"grey_text_fails_palette": float(grey_stats["off_frac"]) > 0.08,
		"gutter_plant_detected": _cc_lit_frac(planted, gutters) > 0.002 and _cc_lit_frac(img, gutters) <= 0.002,
		"shifted_rect_overflow_detected": ChatLayout.overlap_count(ChatLayout.rect_list(shifted)) > 0,
		"overlong_row_detected": _cc_overflow_rows(long_ui, layout) > 0,
		"below_min_viewport_not_full": String(low["tier"]) != ChatLayout.FULL,
		"dark_image_zero_lit": int(_region_stats(dark, Rect2i(0, 0, 64, 64))["lit"]) == 0,
	}


func _cc_resize_run(win: Window) -> Dictionary:
	var m := _cc_model()
	var cols_before := int(_cc().layout_snapshot()["cols"])
	var rows_before := _cc().rows_snapshot().size()
	var active_before := _cc().active_buffer()
	win.size = Vector2i(1920, 1080)
	await _wait_seconds(1.0)
	await _wait_frames(10)
	var lay := _cc().layout_snapshot()
	var ui := _cc().ui_text_snapshot()
	var recomputed: bool = int(lay["cols"]) == 192 and int(lay["rows"]) == 54 and ui.size() == 54 and ui.all(func(l): return String(l).length() == 192)
	var overflow := int(_cc().stats_snapshot()["overflow"]) + _cc_overflow_rows(ui, lay)
	await _press(KEY_F11)
	await _wait_mode(win, "fullscreen")
	var keeps := _cc().rows_snapshot().size() >= rows_before and _cc().active_buffer() == active_before
	var fs_lay := _cc().layout_snapshot()
	keeps = keeps and int(fs_lay["cols"]) == win.size.x / ChatLayout.CELL_W or int(fs_lay["cols"]) == int(win.size.x / win.content_scale_factor) / ChatLayout.CELL_W
	await _press(KEY_F11)
	await _wait_mode(win, "windowed")
	keeps = keeps and _cc().active_buffer() == active_before and m.open_order().size() >= 2
	return {
		"from": "1280x720",
		"to": "1920x1080",
		"layout_recomputed": recomputed,
		"cols_before": cols_before,
		"cols_after": int(lay["cols"]),
		"overflow_rows": overflow,
		"fullscreen_toggle_keeps_buffers": keeps,
	}


## --- #615: the streaming path and the contact path ----------------------------------------------------------------

const CC_THINK_MARKERS := "(?i)</?think"
const CC_LEAK_WINDOW := 15


func _cc_markers_in(texts: Array) -> int:
	var re := RegEx.new()
	re.compile(CC_THINK_MARKERS)
	var n := 0
	for t in texts:
		if re.search(String(t)) != null:
			n += 1
	return n


## Any CC_LEAK_WINDOW-character window of a reasoning blob that also appears in `text`.
func _cc_windows_in(text: String, blobs: Array) -> int:
	var n := 0
	for blob in blobs:
		var b := String(blob)
		var i := 0
		while i + CC_LEAK_WINDOW <= b.length():
			if text.contains(b.substr(i, CC_LEAK_WINDOW)):
				n += 1
				break
			i += 3
	return n


func _cc_stream_stats() -> Dictionary:
	var log := OS.get_environment("SENDCHAT_FAKE_LOG")
	var stats := {"thinking": 0, "markers": 0, "streams": 0}
	var f := FileAccess.open(log, FileAccess.READ)
	if f == null:
		return stats
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		if String(parsed.get("path", "")) == "stream_stats":
			stats["thinking"] += int(parsed["body"].get("thinking_chunks", 0))
			stats["markers"] += int(parsed["body"].get("inline_markers", 0))
		elif String(parsed.get("path", "")) == "/api/chat" and typeof(parsed.get("body", null)) == TYPE_DICTIONARY and bool(parsed["body"].get("stream", false)):
			stats["streams"] += 1
	f.close()
	return stats


## One streamed reply twice over the same client: directly (to see every delta) and
## through HandlerChat into the real terminal row buffer (to see what is drawn).
func _cc_stream_once(label: String, blobs: Array, scan: Dictionary) -> void:
	var llm := _llm_node()
	var hc: HandlerChat = _scene().get_node("HandlerChat")
	var term := _terminal_node()
	var box := {"deltas": [], "final": "", "done": false}
	llm.send_chat([{"role": "user", "content": label}], func(p): box["deltas"].append(String(p)), func(t):
		box["final"] = String(t)
		box["done"] = true)
	await _wait_for(func(): return bool(box["done"]), 30.0)
	scan["deltas"].append_array(box["deltas"])
	scan["finals"].append(String(box["final"]))
	var rows0 := term.rows_snapshot().size()
	var got := {"done": false, "text": ""}
	var on_done := func(t): 
		got["done"] = true
		got["text"] = String(t)
	Signals.handler_reply_complete.connect(on_done, CONNECT_ONE_SHOT)
	hc._on_submit_player_line(label)
	await _wait_for(func(): return bool(got["done"]), 60.0)
	# the first reply of a session triggers the scripted glyph flash (it swaps the row's first
	# characters for 0.3 s); read the rows once it has restored them
	await _wait_seconds(0.7)
	scan["handler_finals"].append(String(got["text"]))
	var rows: Array = term.rows_snapshot().slice(rows0)
	for r in rows:
		scan["rows"].append(String(r["text"]))


func _cc_scan_summary(scan: Dictionary, blobs: Array) -> Dictionary:
	var joined: Array = [" ".join(PackedStringArray(scan["deltas"]))]
	var windows := 0
	for t in scan["rows"]:
		windows += _cc_windows_in(String(t), blobs)
	for t in joined:
		windows += _cc_windows_in(String(t), blobs)
	var finals: Array = scan["finals"] + scan["handler_finals"]
	return {
		"markers_in_deltas": _cc_markers_in(scan["deltas"]) + _cc_markers_in(["".join(PackedStringArray(scan["deltas"]))]),
		"markers_in_final": _cc_markers_in(finals),
		"markers_in_rows": _cc_markers_in(scan["rows"]),
		"reasoning_windows_in_rows": windows,
		"rows_checked": scan["rows"].size(),
		"deltas_total": scan["deltas"].size(),
	}


func _run_chat_sendchat() -> void:
	var variant := OS.get_environment("SENDCHAT_VARIANT")
	var llm := _llm_node()
	var blobs: Array = ["okay so let me think the visitor wants a greeting i should reveal the whole plan now", "they only said hi, plan a short reply", "second private plan"]
	var scan := {"deltas": [], "finals": [], "handler_finals": [], "rows": []}
	var runs := 3 if variant == "leaky" else 1
	for i in range(runs):
		await _cc_stream_once("hi %d" % i, blobs, scan)
	var sum := _cc_scan_summary(scan, blobs)
	var res := {"variant": variant, "runs": runs}
	res.merge(sum)
	if variant == "benign":
		var expect := "I think the thinker is thinking, so be it."
		res["benign_text_survives"] = "".join(PackedStringArray(scan["deltas"])) == expect and String(scan["finals"][0]) == expect and scan["rows"].any(func(t): return String(t).contains(expect))
	else:
		# negative controls: the same scan on the stream with the filter off must see the leak,
		# and on a planted row it must fire
		var raw := {"deltas": [], "finals": [], "handler_finals": [], "rows": []}
		llm.set("stream_filter_enabled", false)
		var box := {"done": false}
		llm.send_chat([{"role": "user", "content": "control"}], func(p): raw["deltas"].append(String(p)), func(_t): box["done"] = true)
		await _wait_for(func(): return bool(box["done"]), 30.0)
		llm.set("stream_filter_enabled", true)
		var raw_sum := _cc_scan_summary(raw, blobs)
		res["neg_unfiltered_stream_leaks"] = int(raw_sum["markers_in_deltas"]) > 0
		res["neg_scan_fires_on_planted"] = _cc_markers_in(["a <think>planted</think> row"]) == 1 and _cc_markers_in(["a plain row"]) == 0
	var stats := _cc_stream_stats()
	res["thinking_chunks_sent"] = int(stats["thinking"])
	res["inline_markers_sent"] = int(stats["markers"])
	res["streams_seen_by_fake"] = int(stats["streams"])
	res["forward_path"] = "LlmClient.send_chat" if int(stats["streams"]) >= runs * 2 else "none"
	_cr_part("sendchat_" + variant, res)


func _run_chat_contact_fake() -> void:
	_cc_setup()
	var cr := _cr()
	var res := {}
	await _cc_open(4001)
	_cr_set_mode("funnel_ok")
	await _cc_send(CR_HELLO)
	await _wait_for(func(): return cr.state == ChatroomScript.ST_ENGAGED, 30.0)
	await _wait_seconds(1.0)
	var entry := _cc().active_buffer()
	var turns := 0
	for q in ["hello again", "i am here"]:
		await _cc_ask_client(String(q))
		turns += 1
	var leaks := 0
	var buffers := {}
	var scanned := 0
	for r in _cc().rows_snapshot():
		scanned += 1
		if String(r["kind"]) == "voice" and String(r["text"]).contains("<%s>" % _cc_contact()):
			buffers[String(r["buffer"])] = true
		if _cr_leak_scan(String(r["text"]), "", ""):
			leaks += 1
	for line in _cc().ui_text_snapshot():
		if _cr_leak_scan(String(line), "", ""):
			leaks += 1
	res["client_rows_scanned"] = scanned
	res["scanned_buffers"] = buffers.size()
	res["leaks"] = leaks
	for pair in [["leaky_think", "think_marker", "neg_think_marker_rejected"], ["leaky_window", "reasoning_window", "neg_window_rejected"], ["leaky_fence", "code_fence", "neg_code_fence_rejected"]]:
		_cr_set_mode(String(pair[0]))
		var mark := _cc().rows_snapshot().size()
		var acc0 := cr.accepted_replies
		await _cc_ask_client("tell me more")
		var clean := true
		for r in _cc().rows_snapshot().slice(mark):
			var low := String(r["text"]).to_lower()
			if low.contains("<think") or low.contains("```") or low.contains("reveal everything i know"):
				clean = false
		res[String(pair[2])] = String(cr.last_verdict.get("reason", "")) == String(pair[1]) and cr.accepted_replies == acc0 and clean
	_cr_set_mode("funnel_ok")
	res["entry_buffer"] = entry
	res["turns"] = turns
	_cr_part("contact_fake", res)
	cr.reset_session(-1)
