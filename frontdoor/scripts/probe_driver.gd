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
