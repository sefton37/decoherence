extends Node
## Automated end-to-end readiness probe for DOD-24 (Spec #370 / plan-370
## Risk 5). Tester-owned harness -- the implementer must not modify this
## file's gating or output-format contract.
##
## Completely inert unless the environment variable DECOHERENCE_PROBE=1 is
## set. A real player launch (no env vars set) never instantiates any of
## this node's behavior beyond the no-op early return in _ready().
##
## Drives the REAL boot -> chat pipeline exclusively through the global
## Signals bus (autoload "Signals", see signal_bus.gd) -- it never reaches
## into the scene tree directly and there is no `--scene` bypass. This
## means the DoD's probe check (DOD-24) necessarily exercises the same
## boot.tscn a real player boots into.

const PROBE_MESSAGE := "Hello, this is an automated readiness probe."

## Comfortably inside the stored DOD-24 check's outer `timeout 240` wrapper
## so this node's own watchdog is the normal exit path, not the harness's
## SIGTERM (which would risk an orphaned Godot process / a window left open
## on Kel's real X11 session).
const WATCHDOG_SECONDS := 180.0

var _watchdog: Timer
var _screenshot_path: String = ""
var _finished := false

func _ready() -> void:
	if OS.get_environment("DECOHERENCE_PROBE") != "1":
		return
	_screenshot_path = OS.get_environment("DECOHERENCE_PROBE_SCREENSHOT")

	_watchdog = Timer.new()
	_watchdog.one_shot = true
	_watchdog.wait_time = WATCHDOG_SECONDS
	add_child(_watchdog)
	_watchdog.timeout.connect(_on_watchdog_timeout)
	_watchdog.start()

	Signals.chat_ready.connect(_on_chat_ready)
	Signals.handler_reply_complete.connect(_on_handler_reply_complete)

## Fires once the real boot theater completes and the Handler chat signals
## it is ready for input. Submits the probe message through the exact same
## signal a real Enter keypress on the terminal input line uses.
func _on_chat_ready() -> void:
	if _finished:
		return
	Signals.submit_player_line.emit(PROBE_MESSAGE)

## Fires once the Handler's streamed reply has fully arrived. `text` is the
## real accumulated reply -- the printed length is always computed from it,
## never a literal constant, so this file can never satisfy its own
## fabrication guard (DOD-30) by accident.
func _on_handler_reply_complete(text: String) -> void:
	if _finished:
		return
	_finished = true
	_watchdog.stop()
	var reply_len: int = text.length()
	print("PROBE_OK reply_len=%d" % reply_len)
	_save_screenshot()
	get_tree().quit()

## Self-termination path: if boot/chat never completes (implementation
## missing, Ollama unreachable, a hang), force-quit and report loudly rather
## than relying solely on the outer harness's SIGTERM.
func _on_watchdog_timeout() -> void:
	if _finished:
		return
	_finished = true
	print("PROBE_TIMEOUT")
	_save_screenshot()
	get_tree().quit()

func _save_screenshot() -> void:
	if _screenshot_path.is_empty():
		return
	var img := get_viewport().get_texture().get_image()
	img.save_png(_screenshot_path)
