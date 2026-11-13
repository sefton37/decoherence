extends SceneTree

## Unit tests for the Spec #578 global pause menu (no renderer, no model, no GPU).
## Run via tests/verify_pause_menu_unit.sh with PM_GROUP = state | seam | chatclock | exitflush.
## Output contract (parsed by the DoD):
##   PM_UNIT_<GROUP>_OK   the group passed (printed once, last)
##   PM_UNIT_PASS <name>  one per passing check
##   PM_UNIT_FAIL <name>: <why>   any failure (the script exits 1)
##   PM_UNIT_NEGCTL <name>        a negative control: the check CAN fail
## An unknown group exits 2.

const GROUPS := ["state", "seam", "chatclock", "exitflush"]
const DATA_PATH := "res://frontdoor/data/pause_menu.json"

var _failed: int = 0
var _pm: Node = null
var _started: bool = false


## The autoloads enter the tree only once the loop is running: the groups run on the first frame.
func _process(_delta: float) -> bool:
	if _started:
		return false
	_started = true
	_run()
	return false


func _run() -> void:
	var group := OS.get_environment("PM_GROUP")
	if not group in GROUPS:
		print("PM_UNIT_FAIL group: unknown group '%s'" % group)
		quit(2)
		return
	_pm = root.get_node_or_null("PauseMenu")
	_ok("autoload_present", _pm != null, "PauseMenu is not an autoload of the project")
	if _pm == null:
		quit(1)
		return
	match group:
		"state":
			_group_state()
		"seam":
			_group_seam()
		"chatclock":
			_group_chatclock()
		"exitflush":
			_group_exitflush()
	if _failed == 0:
		print("PM_UNIT_%s_OK" % group.to_upper())
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, why: String = "") -> void:
	if cond:
		print("PM_UNIT_PASS " + name)
	else:
		_failed += 1
		print("PM_UNIT_FAIL %s: %s" % [name, why])


func _neg(name: String, caught: bool) -> void:
	if caught:
		print("PM_UNIT_NEGCTL " + name)
	else:
		_failed += 1
		print("PM_UNIT_FAIL negctl_%s: the broken stand-in was NOT caught" % name)


func _data() -> Dictionary:
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.pressed = true
	return ev


func _press(code: int) -> void:
	root.push_input(_key(code))


func _reset() -> void:
	if _pm.is_open():
		_pm.close()
	_pm.quit_fn = Callable()
	paused = false


func _world_stub() -> Node:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar exits := 0\nfunc request_exit() -> void:\n\texits += 1\n"
	s.reload()
	var n := Node.new()
	n.set_script(s)
	n.add_to_group("stalag_world")
	root.add_child(n)
	return n


## --- state ---------------------------------------------------------------------------------

func _group_state() -> void:
	var data := _data()
	var ids_data: Array = []
	for it in data.get("items", []):
		ids_data.append(String(it["id"]))
	_ok("data_items_are_the_four", ids_data == ["resume", "settings", "exit_shell", "exit_desktop"], str(ids_data))
	_ok("starts_closed", not _pm.is_open())
	_ok("starts_unpaused", not paused)

	# open / close / toggle
	_pm.open()
	_ok("open_opens", _pm.is_open())
	_ok("open_pauses_tree", paused)
	_ok("open_shows_layer", _pm.visible)
	_pm.close()
	_ok("close_closes", not _pm.is_open())
	_ok("close_resumes_tree", not paused)
	_ok("close_hides_layer", not _pm.visible)
	_pm.toggle()
	_ok("toggle_opens", _pm.is_open())
	_pm.toggle()
	_ok("toggle_closes", not _pm.is_open())
	_pm.open()
	_pm.open()
	_pm.close()
	_ok("open_twice_close_once_is_closed", not _pm.is_open() and not paused)

	# the item list comes from the data; the world-only item is hidden with no world mounted
	var no_world: Array = _pm.item_ids()
	_ok("no_world_hides_exit_shell", no_world == ["resume", "settings", "exit_desktop"], str(no_world))
	var world := _world_stub()
	var with_world: Array = _pm.item_ids()
	_ok("world_mounted_shows_exit_shell", with_world == ids_data, str(with_world))
	var labels_ok := true
	for i in range(with_world.size()):
		var want := ""
		for it in data["items"]:
			if String(it["id"]) == String(with_world[i]):
				want = String(it["label"])
		if not String(_pm.item_label(i)).begins_with(want) or want.is_empty():
			labels_ok = false
	_ok("labels_come_from_the_data_file", labels_ok)
	world.free()
	_ok("world_gone_hides_exit_shell_again", _pm.item_ids() == ["resume", "settings", "exit_desktop"])

	# selection wraps both ways
	_pm.open()
	_ok("selection_starts_on_the_first_item", _pm.selected_index() == 0 and _pm.selected_id() == "resume")
	_pm.move_selection(-1)
	_ok("selection_wraps_up_to_last", _pm.selected_index() == 2 and _pm.selected_id() == "exit_desktop", str(_pm.selected_index()))
	_pm.move_selection(1)
	_ok("selection_wraps_down_to_first", _pm.selected_index() == 0)
	_pm.move_selection(1)
	_pm.move_selection(1)
	_pm.move_selection(1)
	_ok("selection_full_circle", _pm.selected_index() == 0)
	# the keys drive it too
	_press(KEY_DOWN)
	_ok("down_key_moves", _pm.selected_index() == 1, str(_pm.selected_index()))
	_press(KEY_UP)
	_press(KEY_UP)
	_ok("up_key_wraps", _pm.selected_index() == 2, str(_pm.selected_index()))
	_pm.close()

	# settings asks for the display toggle (and only that)
	var asked := [0]
	var cb := func() -> void: asked[0] += 1
	_pm.display_toggle_requested.connect(cb)
	_pm.open()
	_pm.move_selection(1)
	_pm.activate()
	_ok("settings_requests_display_toggle", asked[0] == 1 and _pm.is_open(), "asked=%d open=%s" % [asked[0], _pm.is_open()])
	_pm.display_toggle_requested.disconnect(cb)
	_pm.close()

	# mouse mode saved on open and restored on close. The headless display server keeps no mouse mode at all
	# (a set mode reads back as visible), so there the check cannot run and says so; the world probe
	# (PROBE_PM_WORLD mouse_free_while_open, mouse_captured_after) proves it on the real display driver.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pm.open()
		var during := Input.mouse_mode
		_pm.close()
		_ok("mouse_is_free_while_open", during == Input.MOUSE_MODE_VISIBLE, "during=%d" % during)
		_ok("mouse_mode_restored_on_close", Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "after=%d" % Input.mouse_mode)
	else:
		print("PM_UNIT_SKIP mouse_mode: the headless display server cannot hold a mouse mode (covered by the world probe)")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# closed carries the paused milliseconds
	var got := [-1]
	var cb2 := func(ms: int) -> void: got[0] = ms
	_pm.closed.connect(cb2)
	_pm.open()
	OS.delay_msec(60)
	_pm.close()
	_pm.closed.disconnect(cb2)
	_ok("closed_reports_paused_msec", got[0] >= 55 and got[0] < 5000, str(got[0]))

	# exit_shell asks the world to leave, after the menu has closed and the tree is running again
	var w2 := _world_stub()
	_pm.open()
	_pm.move_selection(-1)
	_pm.move_selection(-1)
	_ok("exit_shell_is_selectable_with_a_world", _pm.selected_id() == "exit_shell", _pm.selected_id())
	_pm.activate()
	_ok("exit_shell_asks_the_world_to_leave", int(w2.get("exits")) == 1)
	_ok("exit_shell_closes_the_menu", not _pm.is_open() and not paused)
	w2.free()
	_reset()


## --- seam ----------------------------------------------------------------------------------

func _group_seam() -> void:
	# A surface with zero Esc code (stands in for a screen built after this spec): Esc opens the menu.
	var plain := Node.new()
	root.add_child(plain)
	_press(KEY_ESCAPE)
	_ok("surface_without_esc_code_gets_the_menu", _pm.is_open() and paused)
	_press(KEY_ESCAPE)
	_ok("esc_again_closes_it", not _pm.is_open() and not paused)
	plain.free()

	# A surface that claims Esc for a sub-pane: Esc 1 closes the pane only, Esc 2 opens the menu.
	var s := GDScript.new()
	s.source_code = "extends Node\nvar pane_open := true\nfunc _input(event: InputEvent) -> void:\n\tif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and pane_open:\n\t\tpane_open = false\n\t\tget_viewport().set_input_as_handled()\n"
	s.reload()
	var claimer := Node.new()
	claimer.set_script(s)
	root.add_child(claimer)
	_press(KEY_ESCAPE)
	_ok("claimed_esc_closes_the_pane", not bool(claimer.get("pane_open")))
	_ok("claimed_esc_keeps_the_menu_closed", not _pm.is_open())
	_press(KEY_ESCAPE)
	_ok("second_esc_opens_the_menu", _pm.is_open() and paused)
	_press(KEY_ESCAPE)
	_ok("third_esc_closes_it", not _pm.is_open())
	# negative control: a claimer that never leaves its pane swallows Esc forever and the menu never opens
	var s2 := GDScript.new()
	s2.source_code = "extends Node\nfunc _input(event: InputEvent) -> void:\n\tif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:\n\t\tget_viewport().set_input_as_handled()\n"
	s2.reload()
	var hog := Node.new()
	hog.set_script(s2)
	root.add_child(hog)
	_press(KEY_ESCAPE)
	_neg("an_always_claiming_surface_keeps_the_menu_shut", not _pm.is_open())
	hog.free()
	claimer.free()
	_reset()


## --- chatclock -----------------------------------------------------------------------------

## Loaded at run time: the room's script names the autoloads, which a --script main script cannot compile against.
func _fresh_room() -> Node:
	var cr: Node = load("res://frontdoor/scripts/chatroom.gd").new()
	root.add_child(cr)
	cr.setup(null, null, null)
	cr.sim_enable(10000)
	cr._inside = true
	return cr


func _group_chatclock() -> void:
	var cr: Node = _fresh_room()
	_ok("room_has_a_funnel", cr.funnel != null)
	cr.funnel._next_at = 20000
	cr.funnel._busy_until = 15000
	cr.funnel._wait_since = 12000
	cr._outbox_end = 16000
	cr._outbox = [{"due": 17000, "buffer": "x", "text": "t", "fkind": "k", "then": "", "extra": {}, "epoch": cr._epoch}]
	cr._dm_pending = [{"at": 18000, "handle": "h", "plain": "p", "seed": 1, "epoch": cr._epoch}]
	var rid: String = String(cr.model.room_order[0])
	cr._rooms_rt[rid]["next_ms"] = 19000
	cr._rooms_rt[rid]["next_pres_ms"] = 21000
	var n := 7321
	_pm.closed.emit(n)
	_ok("funnel_next_at_moves_by_exactly_n", cr.funnel._next_at == 20000 + n, str(cr.funnel._next_at))
	_ok("funnel_busy_and_wait_move_by_n", cr.funnel._busy_until == 15000 + n and cr.funnel._wait_since == 12000 + n)
	_ok("outbox_end_moves_by_n", cr._outbox_end == 16000 + n)
	_ok("outbox_due_moves_by_exactly_n", int(cr._outbox[0]["due"]) == 17000 + n, str(cr._outbox[0]["due"]))
	_ok("dm_due_moves_by_exactly_n", int(cr._dm_pending[0]["at"]) == 18000 + n, str(cr._dm_pending[0]["at"]))
	_ok("ambient_and_presence_timers_move_by_n", int(cr._rooms_rt[rid]["next_ms"]) == 19000 + n and int(cr._rooms_rt[rid]["next_pres_ms"]) == 21000 + n)

	# control: a shift of 0 leaves everything where it was, so a clock that ran on through the pause fires early
	cr.free()
	var ctl: Node = _fresh_room()
	ctl._outbox = [{"due": 17000, "buffer": "x", "text": "t", "fkind": "k", "then": "", "extra": {}, "epoch": ctl._epoch}]
	ctl._dm_pending = [{"at": 18000, "handle": "h", "plain": "p", "seed": 1, "epoch": ctl._epoch}]
	var now_after_pause: int = 18000 + 100  # the clock kept running through the pause
	_pm.closed.emit(0)
	var early_outbox: bool = now_after_pause >= int(ctl._outbox[0]["due"])
	var early_dm: bool = now_after_pause >= int(ctl._dm_pending[0]["at"])
	_neg("shift_zero_fires_early", early_outbox and early_dm)
	_pm.closed.emit(now_after_pause - 17000 + 1)
	_ok("a_full_shift_does_not_fire_early", now_after_pause < int(ctl._outbox[0]["due"]) and now_after_pause < int(ctl._dm_pending[0]["at"]))
	ctl.free()

	# a room the player is not in is not touched (its own away clock covers the time outside)
	var out: Node = _fresh_room()
	out._inside = false
	out.funnel._next_at = 20000
	_pm.closed.emit(500)
	_ok("room_not_inside_is_not_shifted", out.funnel._next_at == 20000)
	out.free()
	_reset()


## --- exitflush -----------------------------------------------------------------------------

func _group_exitflush() -> void:
	var order: Array = []
	var s := GDScript.new()
	s.source_code = "extends Node\nvar log: Array\nvar tag := \"\"\nvar flushes := 0\nfunc flush_for_exit() -> void:\n\tflushes += 1\n\tlog.append(tag)\n"
	s.reload()
	var holder := Node.new()
	root.add_child(holder)
	var members: Array = []
	for t in ["a", "b", "c"]:
		var m := Node.new()
		m.set_script(s)
		m.set("log", order)
		m.set("tag", t)
		m.add_to_group("quit_flush")
		holder.add_child(m)
		members.append(m)
	var quits: Array = []
	_pm.quit_fn = func(code: int) -> void:
		quits.append({"code": code, "flushed_before": order.size()})
	_pm.exit_to_desktop()
	var flushed_once := true
	for m in members:
		if int(m.get("flushes")) != 1:
			flushed_once = false
	_ok("every_quit_flush_member_flushed_once", flushed_once)
	_ok("flushed_in_tree_order", order == ["a", "b", "c"], str(order))
	_ok("exactly_one_quit_with_code_0", quits.size() == 1 and int(quits[0]["code"]) == 0, str(quits))
	_ok("all_flushes_ran_before_the_quit", quits.size() == 1 and int(quits[0]["flushed_before"]) == 3)
	_pm.exit_to_desktop()
	_ok("second_exit_quits_nothing_more", quits.size() == 1)

	# the menu item path: double Enter on the exit row still quits once
	_pm.set("_quitting", false)
	order.clear()
	quits.clear()
	for m in members:
		m.set("flushes", 0)
	_pm.quit_fn = func(code: int) -> void:
		quits.append({"code": code, "flushed_before": order.size()})
	_pm.open()
	_pm.move_selection(-1)
	_ok("exit_row_is_selected", _pm.selected_id() == "exit_desktop", _pm.selected_id())
	_press(KEY_ENTER)
	_press(KEY_ENTER)
	_ok("double_enter_quits_once", quits.size() == 1, str(quits.size()))
	# negative control: an exit with no once-guard quits on every call, and the same count check sees it
	var unguarded: Array = []
	var bad_exit := func() -> void: unguarded.append(0)
	bad_exit.call()
	bad_exit.call()
	_neg("an_unguarded_exit_quits_twice", unguarded.size() != 1)
	holder.free()
	_pm.set("_quitting", false)
	_reset()
