extends RefCounted
class_name PauseMenuProbe

## Spec #578 probe mode `pause_menu` (additive; inert unless the probe driver dispatches to it): the
## global pause menu driven through the real frontdoor. Every player action is a real InputEventKey or
## InputEventMouseButton pushed into the engine's input; the probe only READS the menu, the scene and the
## settings file to observe, never calls into the menu to act. PM_MODE selects the run (env):
##   surfaces  Esc on the boot sequence, the prompt, the chatroom and the world (each opens, pauses,
##             closes, and the first row also closes it), the chat pane coexistence, the world details,
##             the display toggle from the menu, F11 and Alt+Enter                   -> PROBE_PM_*
##   control   the same four surfaces with the overlay removed at startup: the menu must NOT open
##   sizes     the menu over the prompt at the window size the run was launched at, with a screenshot
##   exit      one surface (PM_SURFACE), then the Exit row by real keys, after the wrapper has proved
##             that its process scan can see the live game
## Marker lines are printed with the PROBE_PM_ prefix; the wrapper copies only those and judges nothing.

const SURFACES := ["boot", "shell", "chat", "world"]
const WORLD_MIN_CHUNKS := 9
const ENTER_TIMEOUT_SEC := 120.0
const HANDSHAKE_TIMEOUT_SEC := 90.0

var d  # the probe driver node (untyped on purpose: its helpers are called dynamically)
var pm: Node = null
var win: Window
var mode: String = ""
var quit_calls: int = 0
var _surface_for_flush: String = ""


func _init(driver) -> void:
	d = driver


func run() -> void:
	mode = OS.get_environment("PM_MODE")
	win = d.get_window()
	pm = d.get_node_or_null("/root/PauseMenu")
	match mode:
		"surfaces":
			await _run_surfaces()
		"control":
			# The negative control: take the overlay out before anything can open it.
			if pm != null:
				pm.get_parent().remove_child(pm)
				pm.free()
				pm = null
			await _run_surfaces()
		"sizes":
			await _run_sizes()
		"exit":
			await _run_exit()
		_:
			print("PROBE_PM_BAD_MODE mode=" + mode)


## --- Driving (real events only) -----------------------------------------------------------------

func key(code: int, alt: bool = false, press_only: bool = false) -> void:
	var downs: Array = [true] if press_only else [true, false]
	for pressed in downs:
		var ev := InputEventKey.new()
		ev.keycode = code as Key
		ev.physical_keycode = code as Key
		ev.pressed = pressed
		ev.alt_pressed = alt
		Input.parse_input_event(ev)
	await d._wait_frames(3)


func release(code: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.pressed = false
	Input.parse_input_event(ev)
	await d._wait_frames(2)


func click(logical: Vector2) -> void:
	var phys := logical * win.content_scale_factor
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = phys
		ev.global_position = phys
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await d._wait_frames(2)


## --- Reading ------------------------------------------------------------------------------------

func is_open() -> bool:
	return pm != null and is_instance_valid(pm) and pm.is_open()


func menu_visible() -> bool:
	return pm != null and is_instance_valid(pm) and pm.visible and pm.get_child(0).is_visible_in_tree()


func tree_paused() -> bool:
	return d.get_tree().paused


func b(v: bool) -> int:
	return 1 if v else 0


func size_text() -> String:
	return "%dx%d" % [win.size.x, win.size.y]


func world_node() -> Node:
	return d.get_tree().get_first_node_in_group("stalag_world")


func select_by_keys(id: String) -> bool:
	for i in range(8):
		if pm != null and pm.selected_id() == id:
			return true
		await key(KEY_DOWN)
	return pm != null and pm.selected_id() == id


## --- Reaching the surfaces ----------------------------------------------------------------------

func to_shell() -> void:
	await Signals.shell_ready
	await d._wait_frames(30)


func enter_world() -> Node:
	Signals.terminal_line_submitted.emit("dir")
	await d._wait_frames(10)
	Signals.terminal_line_submitted.emit("world")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(ENTER_TIMEOUT_SEC * 1000.0):
		var w: Node = world_node()
		if w != null:
			var st: Node = w.get_node("Streamer")
			if st.ring_ready() and st.pending_count() == 0 and st.settled() and w.is_grounded() and w.chunks_loaded() >= WORLD_MIN_CHUNKS:
				await d._wait_frames(30)
				return w
		await d._wait_frames(5)
	return null


## The HANDLER screen, reached the way a returning player reaches it: a saved profile that has launched
## the chat and not yet accepted the mission lands in the module at boot (a fresh session on that profile).
func enter_handler() -> bool:
	var cr: Chatroom = d._cr()
	var shell: ShellController = d._shell_node()
	var screen: HandlerScreen = d._scene().get_node("HandlerLayer/HandlerScreen")
	var prof := ProfileStore.new_profile("NEWB0001", "PMHANDLER")
	prof["acceptance"]["launched"] = true
	ProfileStore.save_profile(prof)
	cr.reset_session(5783, true)
	shell.enter(true)
	shell.land_on_boot()
	await d._wait_for(func(): return shell.current_state_name() == "HANDLER" and screen.is_mounted(), 8.0)
	await d._wait_frames(10)
	return shell.current_state_name() == "HANDLER" and screen.is_mounted()


func enter_chat() -> void:
	await d._cc_open(5781)


## --- surfaces / control -------------------------------------------------------------------------

## Esc opens, the menu is visible, the tree is paused; Esc closes and the tree runs; the first row (Resume) closes too.
func surface_check(surf: String) -> void:
	await key(KEY_ESCAPE)
	var esc_open: bool = is_open()
	var vis := menu_visible()
	var paused := tree_paused()
	await key(KEY_ESCAPE)
	var esc_close := esc_open and not is_open()
	var resumed := esc_open and not tree_paused()
	await key(KEY_ESCAPE)
	var resume_item := false
	if is_open():
		await key(KEY_ENTER)
		resume_item = not is_open() and not tree_paused()
	await d._wait_frames(2)
	print("PROBE_PM_SURFACE surface=%s size=%s esc_open=%d menu_visible=%d tree_paused=%d esc_close=%d tree_resumed=%d resume_item=%d" % [
		surf, size_text(), b(esc_open), b(vis), b(paused), b(esc_close), b(resumed), b(resume_item)])


func chat_coexistence() -> void:
	var cc: ChatClient = d._cc()
	var cr: Chatroom = d._cr()
	await key(KEY_F2)
	var view_open: bool = cc.view_name() == "directory"
	await key(KEY_ESCAPE)
	var esc1_closed_view: bool = view_open and cc.view_name() == ""
	var menu_after_esc1 := is_open()
	await key(KEY_ESCAPE)
	var esc2 := is_open()
	await key(KEY_ESCAPE)
	var esc3 := esc2 and not is_open()
	var wired := false
	if pm != null and is_instance_valid(pm):
		for c in pm.closed.get_connections():
			if (c["callable"] as Callable).get_object() == cr:
				wired = true
	print("PROBE_PM_CHAT view_open=%d esc1_closed_view=%d menu_after_esc1=%d esc2_opened_menu=%d esc3_closed_menu=%d chat_wired=%d" % [
		b(view_open), b(esc1_closed_view), b(menu_after_esc1), b(esc2), b(esc3), b(wired)])


func world_details(w: Node) -> void:
	var walker = w.walker
	# positive control: the held key does move the walker when no menu is up
	await key(KEY_W, false, true)
	var p_start: Vector3 = walker.pos
	await d._wait_frames(10)  # short: the first few metres only, so nothing is in the way for the resume leg
	var p0: Vector3 = walker.pos
	await key(KEY_ESCAPE)
	var still_in_world: bool = world_node() == w and w.is_inside_tree()
	var mouse_free: bool = is_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	var p_open: Vector3 = walker.pos  # the pose at the moment the menu stands (the key took a few frames to land)
	var clock0: float = w.flora_clock
	await d._wait_frames(40)
	var p1: Vector3 = walker.pos
	var clock1: float = w.flora_clock
	var has_exit_shell: bool = pm != null and "exit_shell" in pm.item_ids()
	var click_ok := false
	if pm != null and is_open():
		var r: Rect2 = pm.row_rect(0)
		await click(r.get_center())
		click_ok = not is_open() and not tree_paused()
	var captured_after: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	# positive control for the frozen walker: the same held key moves it again once the menu is gone
	var p_resume: Vector3 = walker.pos
	await d._wait_frames(10)
	var walked_after: float = p_resume.distance_to(walker.pos)
	await release(KEY_W)
	print("PROBE_PM_WORLD_CONTROL walked_before=%.3f walked_after=%.3f" % [p_start.distance_to(p0), walked_after])
	print("PROBE_PM_WORLD esc1_still_in_world=%d mouse_free_while_open=%d moved=%.3f clock_frozen=%d mouse_captured_after=%d exit_shell_item=%d mouse_click_resume=%d" % [
		b(still_in_world), b(mouse_free), p_open.distance_to(p1), b(is_equal_approx(clock0, clock1)), b(captured_after), b(has_exit_shell), b(click_ok)])


func exit_to_shell_check() -> void:
	await key(KEY_ESCAPE)
	var found: bool = await select_by_keys("exit_shell")
	await key(KEY_ENTER)
	await d._wait_for(func(): return world_node() == null, 20.0)
	await d._wait_frames(10)
	print("PROBE_PM_EXIT_SHELL item_found=%d world_gone=%d menu_closed=%d tree_running=%d" % [
		b(found), b(world_node() == null), b(not is_open()), b(not tree_paused())])


func display_check() -> void:
	var toggled := false
	var persisted := ""
	var back := false
	if pm != null:
		await key(KEY_ESCAPE)
		if await select_by_keys("settings"):
			await key(KEY_ENTER)
			await d._wait_mode(win, "fullscreen")
			toggled = d._display_state(win) == "fullscreen"
			persisted = d._persisted_display()
			await key(KEY_ENTER)
			await d._wait_mode(win, "windowed")
			back = d._display_state(win) == "windowed"
		await key(KEY_ESCAPE)
	await key(KEY_F11)
	await d._wait_mode(win, "fullscreen")
	var f11_on: bool = d._display_state(win) == "fullscreen"
	await key(KEY_F11)
	await d._wait_mode(win, "windowed")
	var f11: bool = f11_on and d._display_state(win) == "windowed"
	await key(KEY_ENTER, true)
	await d._wait_mode(win, "fullscreen")
	var alt_on: bool = d._display_state(win) == "fullscreen"
	await key(KEY_ENTER, true)
	await d._wait_mode(win, "windowed")
	var alt: bool = alt_on and d._display_state(win) == "windowed"
	print("PROBE_PM_DISPLAY item_toggled=%d persisted=%s toggled_back=%d f11_still=%d altenter_still=%d" % [b(toggled), persisted, b(back), b(f11), b(alt)])


func _run_surfaces() -> void:
	await d._wait_frames(40)
	await surface_check("boot")
	await to_shell()
	await surface_check("shell")
	await enter_chat()
	await chat_coexistence()
	await surface_check("chat")
	d._cr_say("leave")
	await d._wait_frames(6)
	if mode == "surfaces":  # the negative control keeps its four surfaces
		if await enter_handler():
			await surface_check("handler")
			var shell: ShellController = d._shell_node()
			await key(KEY_BACKSPACE)  # the data-driven back key: Esc is the menu
			print("PROBE_PM_HANDLER_BACK back_to_shell=%d" % b(shell.current_state_name() == "SHELL"))
		else:
			print("PROBE_PM_HANDLER_UNREACHABLE")
	var w: Node = await enter_world()
	if w == null:
		print("PROBE_PM_WORLD_UNREACHABLE")
		return
	await surface_check("world")
	await world_details(w)
	if pm != null:
		await exit_to_shell_check()
	await display_check()


## --- sizes --------------------------------------------------------------------------------------

func _px(img: Image, x: int, y: int) -> Color:
	return img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1))


func _run_sizes() -> void:
	await to_shell()
	var f: float = win.content_scale_factor
	var before: Image = await d._grab()
	await key(KEY_ESCAPE)
	await d._wait_frames(6)
	var after: Image = await d._grab()
	var r: Rect2 = pm.panel_rect()
	var phys := Rect2(r.position * f, r.size * f)
	var rect_inside := phys.position.x >= 0.0 and phys.position.y >= 0.0 and phys.end.x <= float(win.size.x) and phys.end.y <= float(win.size.y) and r.size.x > 0.0
	# opaque: nearly every pixel of the panel differs from the same pixel before it opened, and the padding band is one flat fill
	var changed := 0
	var total := 0
	var step := maxi(int(f), 1) * 3
	for y in range(int(phys.position.y) + 4, int(phys.end.y) - 4, step):
		for x in range(int(phys.position.x) + 4, int(phys.end.x) - 4, step):
			total += 1
			var a := _px(before, x, y)
			var c := _px(after, x, y)
			if absf(a.r - c.r) + absf(a.g - c.g) + absf(a.b - c.b) > 0.03:
				changed += 1
	var fill: Color = pm.PANEL_FILL
	var flat := 0
	var flat_total := 0
	for y in range(int(phys.position.y + 6.0 * f), int(phys.position.y + (pm.PAD - 6.0) * f), maxi(int(f), 1)):
		for x in range(int(phys.position.x + 12.0 * f), int(phys.end.x - 12.0 * f), step):
			flat_total += 1
			var c2 := _px(after, x, y)
			if absf(c2.r - fill.r) + absf(c2.g - fill.g) + absf(c2.b - fill.b) < 0.06:
				flat += 1
	var opaque := total > 0 and float(changed) / float(total) >= 0.9 and flat_total > 0 and float(flat) / float(flat_total) >= 0.9
	# above the CRT: the layer number, and the padding band carries no scanline rhythm
	var crt_layer: CanvasLayer = d._scene().get_node("CRTLayer")
	var mn := 1.0
	var mx := 0.0
	var cx := int(phys.position.x + phys.size.x * 0.5)
	for y in range(int(phys.position.y + 6.0 * f), int(phys.position.y + 6.0 * f) + 12):
		var lum := _px(after, cx, y).g
		mn = minf(mn, lum)
		mx = maxf(mx, lum)
	var above_crt: bool = pm.layer > crt_layer.layer and (mx - mn) < 0.012
	# the selected row is pixel-distinct from an unselected one
	var sel: Rect2 = pm.row_rect(0)
	var oth: Rect2 = pm.row_rect(1)
	var sx := int((sel.end.x - 10.0) * f)
	var c_sel := _px(after, sx, int(sel.get_center().y * f))
	var c_oth := _px(after, sx, int(oth.get_center().y * f))
	var distinct := (absf(c_sel.r - c_oth.r) + absf(c_sel.g - c_oth.g) + absf(c_sel.b - c_oth.b)) > 0.2
	var size_name := size_text()
	var dir := OS.get_environment("PM_LOG_DIR")
	var file := "%s/pm_%s.png" % [dir, size_name]
	var saved := after.save_png(file) == OK
	print("PROBE_PM_SHOT size=%s rect_inside=%d opaque_changed=%d above_crt=%d selected_distinct=%d file=%s saved=%d" % [
		size_name, b(rect_inside), b(opaque), b(above_crt), b(distinct), file, b(saved)])
	print("PROBE_PM_SHOT_DETAIL size=%s changed=%d/%d flat=%d/%d scanline_span=%.4f scale=%.2f" % [size_name, changed, total, flat, flat_total, mx - mn, f])


## --- exit ---------------------------------------------------------------------------------------

func _on_quit(code: int) -> void:
	quit_calls += 1
	var w: Node = world_node()
	var down := false
	var flushes := 0
	if w != null:
		down = bool(w.streamer._stopped) and w.streamer.pending_count() == 0
		flushes = int(w.flush_calls)
	print("PROBE_PM_FLUSH surface=%s streamer_down=%d flush_calls=%d quit_calls=%d" % [_surface_for_flush, b(down), flushes, quit_calls])
	d.get_tree().quit(code)


func _run_exit() -> void:
	var surf := OS.get_environment("PM_SURFACE")
	_surface_for_flush = surf
	match surf:
		"boot":
			await d._wait_frames(40)
		"shell":
			await to_shell()
		"chat":
			await to_shell()
			await enter_chat()
		"handler":
			await to_shell()
			if not await enter_handler():
				print("PROBE_PM_HANDLER_UNREACHABLE")
				d._ext_quit(4)
				return
		"world":
			await to_shell()
			var w: Node = await enter_world()
			if w == null:
				print("PROBE_PM_WORLD_UNREACHABLE")
				d._ext_quit(4)
				return
		_:
			print("PROBE_PM_BAD_SURFACE surface=" + surf)
			d._ext_quit(2)
			return
	pm.quit_fn = Callable(self, "_on_quit")
	print("PROBE_PM_EXIT_ARMED surface=" + surf)
	var go := OS.get_environment("PM_LOG_DIR") + "/" + surf + ".go"
	var t0 := Time.get_ticks_msec()
	while not FileAccess.file_exists(go) and Time.get_ticks_msec() - t0 < int(HANDSHAKE_TIMEOUT_SEC * 1000.0):
		await d._wait_frames(10)
	await key(KEY_ESCAPE)
	var found: bool = await select_by_keys("exit_desktop")
	print("PROBE_PM_EXIT_SELECTED surface=%s found=%d" % [surf, b(found)])
	await key(KEY_ENTER)
	# the menu quits at once; reaching this point means it did not
	await d._wait_seconds(10.0)
	print("PROBE_PM_EXIT_STUCK surface=" + surf)
	d._ext_quit(3)
