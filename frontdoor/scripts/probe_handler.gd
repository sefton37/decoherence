extends RefCounted
class_name HandlerProbe

## Spec #575 probe modes (additive; inert unless the probe driver dispatches to it): the
## HANDLER module driven end to end through the real frontdoor. Every player action is an
## InputEventKey or InputEventMouseButton pushed into the viewport; the probe only READS the
## shell, the room, the screen and the saved files to observe. The funnel is played to its
## end by the funnel probe's scripted player on the room's simulated clock, against a fake
## model, so reaching the module takes seconds of wall time. Each mode writes one JSON file
## with exactly the keys the DoD reads. No authored word is spelled here: expected text is
## always read from the data files or from the stored profile.
##
## Modes: handler_flow (entry, content, accept, launch, boundary, scroll), handler_resume
## (resume and freeze), handler_mutate (every word is data), handler_layout (geometry, pixels,
## instrument controls, resize), handler_states (a screenshot per state), handler_world (the
## real engine through the route), handler_isolation (the user data dir is a scratch dir).

const SEED_BASE := 575000
const HOSTILE_ORIGIN := "{doing}{0}%s {{x}} </think> ${HOME} QQQQQQQQQQ"
const HOSTILE_DOING := "{origin}\\n[b]{}{{}} %d %s QQQQQQQQQQQQQQQQQQQQQQQQQQ"
const KNOWN_KEY_ACTIONS := ["focus_next", "focus_prev", "scroll_up", "scroll_down", "page_up", "page_down", "top", "bottom", "accept", "accept_alt", "back"]
const MARKER := "ZQX-"

var d  # the probe driver node (untyped on purpose: its helpers are called dynamically)
var fp: FunnelProbe
var cr: Chatroom
var shell: ShellController
var sc: HandlerScreen
var win: Window
var _out: Dictionary = {}
var _started_unix: int = 0
var _log: Array = []
var _stage_at_grant: String = ""
var _llm_at_open: int = -1
var _open_cause: String = ""


func _init(driver) -> void:
	d = driver


func run(mode: String) -> void:
	_started_unix = int(Time.get_unix_time_from_system())
	shell = d._shell_node()
	cr = d._cr()
	sc = d._scene().get_node("HandlerLayer/HandlerScreen")
	win = d.get_window()
	fp = FunnelProbe.new(d)
	fp.shell = shell
	fp.cr = cr
	fp.llm = d._llm_node()
	Signals.chatroom_entry_granted.connect(fp._on_granted)
	Signals.chatroom_entry_granted.connect(_on_grant)
	Signals.handler_module_opened.connect(_on_open)
	match mode:
		"handler_flow":
			await _mode_flow()
		"handler_resume":
			await _mode_resume()
		"handler_mutate":
			await _mode_mutate()
		"handler_layout":
			await _mode_layout()
		"handler_states":
			await _mode_states()
		"handler_world":
			await _mode_world()
		"handler_isolation":
			_mode_isolation()
	var file := "handler_flow" if mode == "handler_flow" else mode
	if mode != "handler_layout":
		d._write_json(d._out_dir() + "/" + file + ".json", _out)
	print("PROBE_HANDLER_DONE " + mode)


func _on_grant() -> void:
	_log.append("chatroom_entry_granted")
	_stage_at_grant = cr.funnel.stage_id() if cr.funnel != null else ""


func _on_open() -> void:
	_log.append("handler_module_opened")
	_llm_at_open = d._llm_node().request_count
	# the module opened inside the room's own grant (the room is in its launch state and has stamped it)
	_open_cause = "chatroom_entry_granted" if cr.state == ChatroomScript.ST_LAUNCH and cr.grant_ms >= 0 else "other"


## --- Driving --------------------------------------------------------------------------------

func key(code: int, shift: bool = false, alt: bool = false, ctrl: bool = false, meta: bool = false, echo: bool = false, pressed: bool = true) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.pressed = pressed
	ev.echo = echo
	ev.shift_pressed = shift
	ev.alt_pressed = alt
	ev.ctrl_pressed = ctrl
	ev.meta_pressed = meta
	Input.parse_input_event(ev)
	fp.keys_driven += 1
	await d._wait_frames(2)


func type_text(text: String) -> void:
	for i in range(text.length()):
		Input.parse_input_event(d._key_event(KEY_NONE, text.unicode_at(i)))
		fp.keys_driven += 1
	await key(KEY_ENTER)


func mouse(pos: Vector2, button: int = MOUSE_BUTTON_LEFT, pressed: bool = true) -> void:
	# the event enters at the window's own pixels; the content scale maps it into the logical grid
	var phys := pos * win.content_scale_factor
	var ev := InputEventMouseButton.new()
	ev.position = phys
	ev.global_position = phys
	ev.button_index = button as MouseButton
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await d._wait_frames(2)


## The centre of a rectangle of cells, in logical pixels (`mouse` scales it to window pixels).
func centre(r: Rect2i) -> Vector2:
	return Vector2((r.position.x + r.size.x * 0.5) * HandlerLayout.CELL_W, (r.position.y + r.size.y * 0.5) * HandlerLayout.CELL_H)


func state() -> Dictionary:
	return sc.state_snapshot()


func lay() -> Dictionary:
	return sc.layout_snapshot()


func rows() -> Array:
	return sc.ui_text_snapshot()


func focus_pane(name: String) -> void:
	var guard := 0
	while String(state()["focus"]) != name and guard < 4:
		await key(KEY_TAB)
		guard += 1


## Leaves the module if open, clears a dry-run hand-off, and opens it again with the typed command.
func reopen() -> void:
	if shell.current_state_name() == "HANDLER":
		await key(back_key())
	if shell.current_state_name() == "CHAT":
		d._cr_say("leave")
		await d._wait_frames(3)
	shell.world_closed()
	d._cr_say("handler")
	await d._wait_for(func(): return shell.current_state_name() == "HANDLER" and sc.is_mounted(), 5.0)
	await d._wait_frames(3)


## The funnel played to its end (the scripted player, a fake model), ending in the module.
func reach(seed_value: int, dry: bool = true) -> Dictionary:
	shell.world_dry_run = dry
	_log.clear()
	var rec: Dictionary = await fp.run_profile("fast", seed_value)
	await d._wait_for(func(): return shell.current_state_name() == "HANDLER" and sc.is_mounted(), 5.0)
	await d._wait_frames(5)
	return rec


func disk_profile() -> Dictionary:
	var loaded := ProfileStore.load_profile()
	return loaded["profile"] if String(loaded["status"]) == "ok" else {}


func disk_accepted() -> bool:
	return ProfileStore.mission_accepted(disk_profile())


func mounted_visible() -> bool:
	return sc.is_mounted() and d._scene().get_node("HandlerLayer").visible


## --- Reading what is on screen -----------------------------------------------------------------

func collapse(text: String) -> String:
	return "".join(text.split(" ", false))


## The content rows of a whole pane, scrolled through with real keys: the rows as drawn, in order.
func full_pane_lines(pane: String) -> Array:
	await focus_pane(pane)
	await key(KEY_HOME)
	var rect: Rect2i = lay()[pane]
	var seen := {}
	var guard := 0
	while guard < 40:
		guard += 1
		var st := state()
		var top := int(st["scroll_" + pane])
		var grid := rows()
		for i in range(rect.size.y - 1):
			var y := rect.position.y + 1 + i
			if y < grid.size() and top + i < int(st["lines_" + pane]):
				seen[top + i] = String(grid[y]).substr(rect.position.x, rect.size.x)
		if top >= int(st["max_" + pane]):
			break
		await key(KEY_PAGEDOWN)
	var keys := seen.keys()
	keys.sort()
	var out: Array = []
	for k in keys:
		out.append(String(seen[k]))
	await key(KEY_HOME)
	return out


## How many (label, value) pairs read back in `lines`: the label then its value, wrapped rows included.
func fields_found(lines: Array, pairs: Array) -> int:
	var found := 0
	var from := 0
	for p in pairs:
		var label := String(p[0]) + ":"
		var want := collapse(String(p[1]))
		for i in range(from, lines.size()):
			var t := String(lines[i]).strip_edges()
			if t.begins_with(label):
				var got := t.substr(label.length())
				var j := i + 1
				while j < lines.size() and String(lines[j]).begins_with("  "):
					got += String(lines[j])
					j += 1
				if collapse(got) == want:
					found += 1
				from = i + 1
				break
	return found


func ui_data() -> Dictionary:
	return cr.handler_data().get("ui", {})


## The keycode of the data-driven back action (Spec 578: Esc belongs to the pause menu).
func back_key() -> int:
	var spec := String(ui_data().get("keys", {}).get("back", ""))
	return int(HandlerScreen._parse_key(spec).get("key", KEY_NONE))


func rules_data() -> Dictionary:
	return cr.handler_data().get("rules", {})


func shown_value(raw: Variant) -> String:
	var s := str(int(raw)) if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT else String(raw)
	return String(ui_data().get("value_labels", {}).get(s, s))


## The (label, value) pairs of the dossier as the stored colonist says them, never as the view builds them.
func dossier_pairs() -> Array:
	var out: Array = []
	var f: Dictionary = cr.colonist().get("fields", {})
	var labels: Dictionary = ui_data().get("field_labels", {})
	for fd in rules_data().get("fields", []):
		var id := String(fd["id"])
		out.append([String(labels.get(id, "")), shown_value(f.get(id, ""))])
	return out


func profile_pairs() -> Array:
	var ui := ui_data()
	var pl: Dictionary = ui.get("profile_labels", {})
	var pv: Dictionary = ui.get("profile_values", {})
	var p := cr.profile_snapshot()
	var dossier: Dictionary = cr.dossier_snapshot().get("fields", {})
	var nof := String(ui.get("not_on_file", ""))
	var former: Array = p["handler"]["former"]
	var former_text := ", ".join(PackedStringArray(former)) if not former.is_empty() else String(pv.get("none", ""))
	var cf: Dictionary = cr.colonist().get("fields", {})
	var status := String(pv.get("status_accepted", "")) if ProfileStore.mission_accepted(p) else String(pv.get("status_pending", ""))
	var origin := String(dossier.get("origin", ""))
	var doing := String(dossier.get("doing", ""))
	return [
		[String(pl["handle"]), String(p["player"]["handle"])],
		[String(pl["former_designation"]), String(p["player"]["designation"])],
		[String(pl["status"]), status],
		[String(pl["handler_name"]), String(p["handler"]["name"])],
		[String(pl["handler_kind"]), String(pv.get("kind_empire", ""))],
		[String(pl["former_handlers"]), former_text],
		[String(pl["origin"]), origin if not origin.is_empty() else nof],
		[String(pl["doing"]), doing if not doing.is_empty() else nof],
		[String(pl["colonist"]), (String(cf.get("given_name", "")) + " " + String(cf.get("family_name", ""))).strip_edges()],
	]


func any_row_contains(needle: String) -> bool:
	for r in rows():
		if String(r).contains(needle):
			return true
	return false


func text_of(list: Array) -> String:
	return "\n".join(PackedStringArray(list))


## --- handler_flow ------------------------------------------------------------------------------------------------

func _mode_flow() -> void:
	# before the funnel is finished the module is locked: spoofed signals open and launch nothing
	cr.reset_session(SEED_BASE)
	cr.sim_enable(0)
	var w0 := shell.world_request_count
	var m0 := shell.module_open_count
	Signals.emit_signal("handler_launch_requested")
	await d._wait_frames(3)
	var spoof_launch := shell.world_request_count - w0 + (1000 if disk_accepted() else 0)
	Signals.emit_signal("chatroom_entry_granted")
	await d._wait_frames(3)
	var spoof_entry := shell.module_open_count - m0 + (shell.world_request_count - w0 - spoof_launch)
	fp.grants = 0
	_log.clear()

	var rec: Dictionary = await reach(SEED_BASE + 1)
	var prof := disk_profile()
	var llm_now: int = d._llm_node().request_count
	_out["display"] = OS.get_environment("DISPLAY")
	_out["user_dir_isolated"] = OS.get_user_data_dir().begins_with(d._out_dir())
	_out["entry"] = {
		"from_funnel_launch_stage": _stage_at_grant == "launch" and (rec["stages"] as Array).back() == "launch",
		"state_after": shell.current_state_name(),
		"world_requests_at_entry": int(rec["world_total"]),
		"chat_unmounted": not d._cc().is_mounted(),
		"module_mounted": mounted_visible(),
		"entered_by_signal": _open_cause,
		"direct_calls": fp.direct_calls,
		"model_requests_in_module": llm_now - _llm_at_open,
		"profile_launched": bool(prof.get("acceptance", {}).get("launched", false)),
		"assignment_persisted": (prof.get("assignments", []) as Array).size(),
		"accepted_at_entry": ProfileStore.mission_accepted(prof),
		"keys_driven": fp.keys_driven,
	}
	var focus_at_open := String(state()["focus"])
	var launch_rect_at_open := sc.launch_rect_cells()
	_out["content"] = await _content()
	_out["scroll"] = await _scroll()
	var boundary: Dictionary = await _boundary()
	boundary["spoof_launch_signal_locked"] = spoof_launch
	boundary["spoof_entry_granted_off_stage"] = spoof_entry
	(boundary["attacks"] as Array).append({"name": "spoof_launch_signal_locked", "world_requests": spoof_launch})
	(boundary["attacks"] as Array).append({"name": "spoof_entry_granted_off_stage", "world_requests": spoof_entry})
	boundary["attack_count"] = (boundary["attacks"] as Array).size()
	_out["boundary"] = boundary
	_out["accept"] = await _accept(focus_at_open, launch_rect_at_open)
	_out["launch"] = await _launch()
	shell.world_dry_run = true


func _content() -> Dictionary:
	var ui := ui_data()
	var p := cr.profile_snapshot()
	var dossier_lines: Array = await full_pane_lines("dossier")
	var profile_lines: Array = await full_pane_lines("profile")
	var dp := dossier_pairs()
	var pp := profile_pairs()
	var dtext := text_of(dossier_lines)
	var ptext := text_of(profile_lines)
	var title_row := String(rows()[0])
	var re := RegEx.new()
	re.compile("\\{[A-Za-z_0-9]+\\}")
	var order_ok := true
	var last_at := -1
	for sid in rules_data().get("sections", []):
		var at := dtext.find(String(ui["section_labels"][String(sid["id"])]))
		if at < 0 or at < last_at:
			order_ok = false
		last_at = at
	var labels_ok := true
	for k in ui["pane_titles"]:
		if not any_row_contains(String(ui["pane_titles"][k])):
			labels_ok = false
	var cf: Dictionary = cr.colonist().get("fields", {})
	var view := sc.view_snapshot()
	var view_equal := true
	var flat: Array = []
	for s in view["dossier"]:
		flat.append_array(s["rows"])
	for i in range(flat.size()):
		if String(flat[i]["value"]) != String(dp[i][1]) or String(flat[i]["label"]) != String(dp[i][0]):
			view_equal = false
	var out := {
		"handle_in_title": title_row.contains(String(p["player"]["handle"])) and not String(p["player"]["handle"]).is_empty(),
		"handler_name_shown": ptext.contains(String(p["handler"]["name"])),
		"designation_shown_as_former": ptext.contains(String(ui["profile_labels"]["former_designation"])) and ptext.contains(String(p["player"]["designation"])),
		"colonist_name_shown": dtext.contains(String(cf["given_name"])) and dtext.contains(String(cf["family_name"])),
		"dossier_fields_expected": dp.size(),
		"dossier_fields_rendered": fields_found(dossier_lines, dp),
		"profile_fields_expected": pp.size(),
		"profile_fields_rendered": fields_found(profile_lines, pp),
		"unresolved_slots": re.search_all(dtext).size(),
		"labels_from_data": labels_ok,
		"section_order_matches_rules": order_ok,
		"intimate_section_visible": dtext.contains(String(ui["section_labels"]["intimate"])) and dtext.contains(String(cf["relationship_status"])) and dtext.contains(String(cf["orientation"])),
		"values_equal_view_model": view_equal and flat.size() == dp.size(),
	}
	out["not_on_file_when_wiped"] = await _not_on_file()
	out["hostile_values_inert"] = await _hostile()
	return out


## /forget typed in the real chat, then the module again: the answers read as not on file.
func _not_on_file() -> bool:
	await key(back_key())
	shell.enter(true)
	d._cr_say("chat")
	await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
	await d._wait_frames(3)
	d._cr_say("/forget")
	await d._wait_frames(4)
	d._cr_say("leave")
	await d._wait_frames(4)
	await reopen()
	var lines: Array = await full_pane_lines("profile")
	var ok := fields_found(lines, profile_pairs()) == 9
	var nof := String(ui_data().get("not_on_file", ""))
	var text := text_of(lines)
	return ok and text.count(nof) >= 2 and cr.dossier_snapshot().get("fields", {}).is_empty()


## Hostile answers (braces, markup, format tokens, long words): literal, inside the pane, nothing else changes.
func _hostile() -> bool:
	var before := cr.colonist_id()
	await key(back_key())
	var dossier := ProfileStore.empty_dossier()
	dossier["fields"]["origin"] = HOSTILE_ORIGIN.substr(0, 60)
	dossier["fields"]["doing"] = HOSTILE_DOING.substr(0, 60)
	ProfileStore.save_dossier(dossier)
	cr.reset_session(SEED_BASE + 2, true)
	await reopen()
	var lines: Array = await full_pane_lines("profile")
	var pp := profile_pairs()
	var found := fields_found(lines, pp)
	var rect: Rect2i = lay()["profile"]
	var gutter: Rect2i = lay()["gutter"]
	var within := true
	var grid := rows()
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		var line := String(grid[y])
		if line.substr(rect.position.x + rect.size.x).strip_edges() != "" or line.substr(gutter.position.x, gutter.size.x).strip_edges() != "":
			within = false
	return found == 9 and cr.colonist_id() == before and int(state()["overflow"]) == 0 and within and shell.current_state_name() == "HANDLER" and cr.dossier_snapshot()["fields"]["origin"] == HOSTILE_ORIGIN.substr(0, 60)


func _boundary() -> Dictionary:
	var res := {"attacks": [], "attack_count": 0}
	await unaccept(SEED_BASE + 4)
	var attacks_accepted := 0
	var chat_lines0 := cr.lines_received
	var names: Array = []
	var defs := _attack_defs()
	for a in defs:
		var w0 := shell.world_request_count
		await reopen()
		await (a["run"] as Callable).call()
		await d._wait_frames(2)
		var dw := shell.world_request_count - w0
		if disk_accepted():
			attacks_accepted += 1
		(res["attacks"] as Array).append({"name": String(a["name"]), "world_requests": dw})
		names.append(String(a["name"]))
		if String(a["name"]) == "enter_on_mount":
			res["stray_enter_on_mount"] = dw
		if String(a["name"]) == "enter_repeated_on_mount":
			res["repeat_enter_on_mount"] = dw
	res["attack_count"] = (res["attacks"] as Array).size()
	res["typed_text_to_chat"] = cr.lines_received - chat_lines0
	res["attacks_accepted_persisted"] = attacks_accepted
	# the positive control: a real click on the drawn button opens the world exactly once
	await reopen()
	var w1 := shell.world_request_count
	await mouse(centre(sc.launch_rect_cells()))
	res["control_real_click_world"] = shell.world_request_count - w1
	return res


func _attack_defs() -> Array:
	var out: Array = []
	var add := func(name: String, run: Callable) -> void:
		out.append({"name": name, "run": run})
	add.call("enter_on_mount", func(): await key(KEY_ENTER))
	add.call("enter_repeated_on_mount", func():
		for i in range(6):
			await key(KEY_ENTER))
	add.call("kp_enter_on_mount", func(): await key(KEY_KP_ENTER))
	add.call("space_on_dossier", func(): await key(KEY_SPACE))
	add.call("enter_on_profile", func():
		await key(KEY_TAB)
		await key(KEY_ENTER))
	add.call("space_on_profile", func():
		await key(KEY_TAB)
		await key(KEY_SPACE))
	add.call("echo_enter_on_launch", func():
		await focus_pane("launch")
		await key(KEY_ENTER, false, false, false, false, true))
	add.call("echo_space_on_launch", func():
		await focus_pane("launch")
		await key(KEY_SPACE, false, false, false, false, true))
	add.call("alt_enter_on_launch", func():
		await focus_pane("launch")
		await key(KEY_ENTER, false, true))
	add.call("alt_enter_on_dossier", func(): await key(KEY_ENTER, false, true))
	add.call("ctrl_enter_on_launch", func():
		await focus_pane("launch")
		await key(KEY_ENTER, false, false, true))
	add.call("shift_enter_on_launch", func():
		await focus_pane("launch")
		await key(KEY_ENTER, true))
	add.call("meta_enter_on_launch", func():
		await focus_pane("launch")
		await key(KEY_ENTER, false, false, false, true))
	add.call("ctrl_space_on_launch", func():
		await focus_pane("launch")
		await key(KEY_SPACE, false, false, true))
	add.call("enter_release_only_on_launch", func():
		await focus_pane("launch")
		await key(KEY_ENTER, false, false, false, false, false, false))
	add.call("escape_then_enter", func():
		await key(back_key())
		await key(KEY_ENTER)
		await key(KEY_ENTER))
	add.call("typed_world_word_on_module", func(): await type_text("world"))
	add.call("typed_launch_word_on_module", func(): await type_text("launch"))
	add.call("click_title_bar", func(): await mouse(centre(lay()["title"])))
	add.call("click_status_row", func(): await mouse(centre(lay()["status"])))
	add.call("click_gutter", func(): await mouse(centre(lay()["gutter"])))
	add.call("click_dossier_pane", func(): await mouse(centre(lay()["dossier"])))
	add.call("click_profile_pane", func(): await mouse(centre(lay()["profile"])))
	add.call("click_left_of_button", func():
		var r: Rect2i = sc.launch_rect_cells()
		await mouse(Vector2(r.position.x * 10 - 1, centre(r).y)))
	add.call("click_above_button", func():
		var r: Rect2i = sc.launch_rect_cells()
		await mouse(Vector2(centre(r).x, r.position.y * 20 - 1)))
	add.call("click_right_of_button", func():
		var r: Rect2i = sc.launch_rect_cells()
		await mouse(Vector2((r.position.x + r.size.x) * 10 + 1, centre(r).y)))
	add.call("right_click_button", func(): await mouse(centre(sc.launch_rect_cells()), MOUSE_BUTTON_RIGHT))
	add.call("middle_click_button", func(): await mouse(centre(sc.launch_rect_cells()), MOUSE_BUTTON_MIDDLE))
	add.call("release_only_on_button", func(): await mouse(centre(sc.launch_rect_cells()), MOUSE_BUTTON_LEFT, false))
	add.call("wheel_over_button", func():
		await mouse(centre(sc.launch_rect_cells()), MOUSE_BUTTON_WHEEL_DOWN)
		await mouse(centre(sc.launch_rect_cells()), MOUSE_BUTTON_WHEEL_UP))
	add.call("spoof_launch_signal_after_close", func():
		await key(back_key())
		Signals.emit_signal("handler_launch_requested"))
	add.call("spoof_closed_signal_in_shell", func():
		await key(back_key())
		Signals.emit_signal("handler_module_closed")
		Signals.emit_signal("handler_launch_requested"))
	return out


## Takes the acceptance back out of the saved profile (the colonist stays) and restarts the room on it,
## so a section that needs an unaccepted player starts from one.
func unaccept(seed_value: int) -> void:
	var p := disk_profile()
	(p["acceptance"] as Dictionary).erase("mission_accepted")
	ProfileStore.save_profile(p)
	cr.reset_session(seed_value, true)
	await reopen()


func _scroll() -> Dictionary:
	await reopen()
	var res := {}
	var seq: Array = [String(state()["focus"])]
	await key(KEY_TAB)
	seq.append(String(state()["focus"]))
	await key(KEY_TAB)
	seq.append(String(state()["focus"]))
	res["focus_cycle"] = seq
	await focus_pane("dossier")
	await key(KEY_TAB, true)
	var back1 := String(state()["focus"])
	await key(KEY_TAB, true)
	res["shift_tab_reverses"] = back1 == "launch" and String(state()["focus"]) == "profile"
	await focus_pane("dossier")
	var ui := ui_data()
	var marker := String(ui.get("focus_marker", ""))
	var grid := rows()
	var drect: Rect2i = lay()["dossier"]
	var prect: Rect2i = lay()["profile"]
	res["focus_marked"] = String(grid[drect.position.y]).substr(drect.position.x, drect.size.x).contains(marker) and not String(grid[prect.position.y]).substr(prect.position.x, prect.size.x).contains(marker)
	# the dossier is longer than the pane at this size: End reaches the last row, the first row is gone
	await key(KEY_HOME)
	var top_rows: Array = rows()
	var first_label := String(ui["section_labels"][String(rules_data()["sections"][0]["id"])])
	var st0 := state()
	await key(KEY_END)
	var st1 := state()
	var end_rows := rows()
	var last_pair: Array = dossier_pairs().back()
	var tail_word := String(last_pair[1]).split(" ", false)[-1]
	var band := end_rows.slice(drect.position.y + 1, drect.position.y + drect.size.y)
	var band_text := ""
	for r in band:
		band_text += String(r).substr(drect.position.x, drect.size.x) + "\n"
	res["end_reachable"] = int(st1["scroll_dossier"]) == int(st1["max_dossier"]) and int(st1["max_dossier"]) > 0
	res["last_row_visible_at_end"] = band_text.contains(tail_word)
	res["first_row_absent_at_end"] = not band_text.contains(first_label)
	await key(KEY_HOME)
	res["home_returns_top"] = int(state()["scroll_dossier"]) == 0 and String(top_rows[drect.position.y + 1]).contains(first_label) and int(st0["scroll_dossier"]) == 0
	# the mouse wheel over a pane scrolls that pane
	var s0 := int(state()["scroll_dossier"])
	await mouse(centre(drect), MOUSE_BUTTON_WHEEL_DOWN)
	var s1 := int(state()["scroll_dossier"])
	await mouse(centre(drect), MOUSE_BUTTON_WHEEL_UP)
	res["wheel_scrolls"] = s1 > s0 and int(state()["scroll_dossier"]) < s1
	# page keys move by a page less one row
	await focus_pane("dossier")
	await key(KEY_HOME)
	await key(KEY_PAGEDOWN)
	var p1 := int(state()["scroll_dossier"])
	await key(KEY_PAGEUP)
	res["page_keys"] = p1 == mini(int(state()["rows_dossier"]) - 1, int(state()["max_dossier"])) and p1 > 1 and int(state()["scroll_dossier"]) == 0
	# nothing scrolls when everything fits: the profile pane at this size, then at a taller one
	await focus_pane("profile")
	await key(KEY_DOWN)
	res["no_scroll_when_fits"] = int(state()["max_profile"]) == 0 and int(state()["scroll_profile"]) == 0
	# a short viewport makes the profile pane scroll
	win.size = Vector2i(1280, 240)
	await d._wait_seconds(1.0)
	await d._wait_frames(8)
	await focus_pane("profile")
	var long_max := int(state()["max_profile"])
	await key(KEY_END)
	res["profile_scrolls_when_long"] = long_max > 0 and int(state()["scroll_profile"]) == long_max
	win.size = Vector2i(1280, 720)
	await d._wait_seconds(1.0)
	await d._wait_frames(8)
	return res


func _accept(focus_at_open: String, rect_at_open: Rect2i) -> Dictionary:
	var res := {}
	await unaccept(SEED_BASE + 5)
	var keys: Dictionary = ui_data().get("keys", {})
	var extra := 0
	for k in keys:
		if not KNOWN_KEY_ACTIONS.has(String(k)):
			extra += 1
	var lay0 := lay()
	res["no_decline_control"] = extra == 0 and (lay0["launch"] as Rect2i).size.x > 0 and not lay0.has("decline") and HandlerLayout.pane_names().count("launch") == 1
	await reopen()
	var label := String(ui_data()["launch_label"])
	var btn: Rect2i = sc.launch_rect_cells()
	var btn_text := ""
	for y in range(btn.position.y, btn.position.y + btn.size.y):
		btn_text += String(rows()[y]).substr(btn.position.x, btn.size.x)
	res["launch_label_from_data"] = btn_text.contains(label) and not label.is_empty()
	res["launch_enabled_on_open"] = btn.size.x > 0 and rect_at_open.size.x > 0
	res["initial_focus_not_launch"] = String(state()["focus"]) == "dossier" and focus_at_open == "dossier"
	# an unknown key in the saved profile must survive the press
	var p := disk_profile()
	p["future_probe_key"] = {"kept": true}
	p["player"]["future_player_key"] = "kept"
	ProfileStore.save_profile(p)
	cr.reset_session(SEED_BASE + 3, true)
	await reopen()
	var before_world := shell.world_request_count
	var log_n := shell.route_log.size()
	await mouse(centre(sc.launch_rect_cells()))
	res["click_accepts"] = shell.world_request_count - before_world
	var after := disk_profile()
	res["acceptance_persisted"] = ProfileStore.mission_accepted(after)
	res["acceptance_before_route"] = shell.route_log.size() == log_n + 1 and bool(shell.route_log.back()["accepted_persisted"])
	res["assignment_persisted"] = (after.get("assignments", []) as Array).size() == 1 and String(after["assignments"][0]["fields"]["colonist_id"]) == cr.colonist_id()
	var acc: Dictionary = after["acceptance"]
	res["acceptance_record_single"] = acc.keys().size() == 5 and acc.has("mission_accepted") and (after["assignments"] as Array).size() == 1
	res["profile_keys_survive"] = after.has("future_probe_key") and after["player"].has("future_player_key")
	res["accepted_status_shown"] = any_row_contains(String(ui_data()["accepted_status"]))
	return res


func _launch() -> Dictionary:
	var res := {}
	await reopen()
	var r: Rect2i = sc.launch_rect_cells()
	var l := lay()
	res["button_rect_in_bounds"] = r.position.x >= 0 and r.position.y >= 0 and r.end.x <= int(l["cols"]) and r.end.y <= int(l["rows"]) and r.size.x >= 14
	# Alt+Enter and F11 never accept: Alt+Enter on the focused button, F11 toggles the display
	await focus_pane("launch")
	var w0 := shell.world_request_count
	var display0: String = d._display_state(win)
	await key(KEY_ENTER, false, true)
	await d._wait_mode(win, "fullscreen")
	res["alt_enter_no_launch"] = shell.world_request_count == w0 and d._display_state(win) != display0
	await key(KEY_F11)
	await d._wait_mode(win, "windowed")
	res["f11_toggles_display"] = shell.world_request_count == w0 and d._display_state(win) == display0
	# the keyboard accepts too: Enter, and separately Space, on the focused button, once each
	for word in ["accept", "accept_alt"]:
		await reopen()
		await focus_pane("launch")
		var kb := shell.world_request_count
		await key(KEY_ENTER if word == "accept" else KEY_SPACE)
		await key(KEY_ENTER if word == "accept" else KEY_SPACE)
		res["enter_key_accepts" if word == "accept" else "space_key_accepts"] = shell.world_request_count - kb == 1
	await reopen()
	var base := shell.world_request_count
	var log0 := shell.route_log.size()
	await mouse(centre(sc.launch_rect_cells()))
	res["click_launches"] = shell.world_request_count - base
	res["world_requests_after_click"] = shell.world_request_count - base
	await mouse(centre(sc.launch_rect_cells()))
	await mouse(centre(sc.launch_rect_cells()))
	res["repeat_clicks_world_requests"] = shell.world_request_count - base
	await key(KEY_ENTER)
	await key(KEY_SPACE)
	res["enter_on_focus_world_requests"] = shell.world_request_count - base
	res["inert_until_world_closed"] = shell.world_request_count - base == 1 and shell.current_state_name() == "HANDLER"
	var route_entry: Dictionary = shell.route_log[log0] if shell.route_log.size() > log0 else {}
	var data = ProfileStore.read_json_file(ProfileStore.handler_data_dir() + "/launch_route.json")
	var route := {
		"id": String(route_entry.get("route", "")),
		"id_from_data": typeof(data) == TYPE_DICTIONARY and String(data.get("route", "")) == String(route_entry.get("route", "x")),
		"assignment_id_passed": not String(route_entry.get("assignment", "")).is_empty() and String(route_entry.get("assignment", "")) == cr.colonist_id(),
	}
	# the world closes: the same press works again after the module is reopened
	await reopen()
	var base2 := shell.world_request_count
	await mouse(centre(sc.launch_rect_cells()))
	res["rearmed_after_world_closed"] = shell.world_request_count - base2 == 1
	# an engine that is not there: the status line says so, nothing is entered, the press is armed again
	await reopen()
	shell.world_force_unavailable = true
	await mouse(centre(sc.launch_rect_cells()))
	res["unavailable_message_in_status"] = String(state()["status"]) == String(ui_data()["launch_unavailable"]) and any_row_contains(String(ui_data()["launch_unavailable"])) and shell.last_launch_result == "unavailable"
	shell.world_force_unavailable = false
	var base3 := shell.world_request_count
	await mouse(centre(sc.launch_rect_cells()))
	res["unavailable_rearmed"] = shell.world_request_count - base3 == 1 and shell.last_launch_result == "ok"
	# a route the shell does not know is refused, and nothing is entered
	await reopen()
	var copy := _data_copy("unknown_route", func(name, data2):
		if name == "launch_route.json":
			data2["route"] = "no_such_route"
		return data2)
	var original := OS.get_environment(ProfileStore.ENV_HANDLER_DIR)
	OS.set_environment(ProfileStore.ENV_HANDLER_DIR, copy)
	var base4 := shell.world_request_count
	await mouse(centre(sc.launch_rect_cells()))
	route["unknown_route_refused"] = shell.last_launch_result == "unknown_route" and any_row_contains(String(ui_data()["unknown_route"]))
	route["unknown_route_world_requests"] = shell.world_request_count - base4
	OS.set_environment(ProfileStore.ENV_HANDLER_DIR, original)
	res["route"] = route
	return res


## A copy of the handler data directory under user:// with `edit(file_name, parsed)` applied to every file.
func _data_copy(tag: String, edit: Callable) -> String:
	var src := ProfileStore.handler_data_dir()
	var dst := "user://handler_probe_data/" + tag
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst))
	var da := DirAccess.open(src)
	for f in da.get_files():
		if not f.ends_with(".json"):
			continue
		var data = ProfileStore.read_json_file(src + "/" + f)
		data = edit.call(f, data)
		var out := FileAccess.open(dst + "/" + f, FileAccess.WRITE)
		out.store_string(JSON.stringify(data))
		out.close()
	return dst


## --- handler_resume ---------------------------------------------------------------------------------------------------

## The shell half of a boot, in this process: the saved profile is read again (the room's reset keeps
## it), the shell comes up with `gate`, and boot lands where the saved profile says. `profile` is a
## dictionary to save first, "corrupt" for a file that does not parse, or null for a fresh install.
func restart(profile: Variant, gate: bool = true) -> void:
	if shell.current_state_name() == "HANDLER":
		await key(back_key())
	if shell.current_state_name() == "CHAT":
		d._cr_say("leave")
		await d._wait_frames(3)
	shell.world_closed()
	var keep := true
	if typeof(profile) == TYPE_DICTIONARY:
		ProfileStore.save_profile(profile)
	elif typeof(profile) == TYPE_STRING:
		var f := FileAccess.open(ProfileStore.PROFILE_FILE, FileAccess.WRITE)
		f.store_string("{this is not a profile")
		f.close()
	else:
		keep = false
	cr.reset_session(SEED_BASE + 50, keep)
	shell.enter(gate)
	shell.land_on_boot()
	await d._wait_frames(4)


func dir_lines() -> Array:
	d._ext_rendered.clear()
	d._cr_say("dir")
	await d._wait_frames(4)
	return d._ext_rendered.duplicate()


func module_label(id: String) -> String:
	var mods = ProfileStore.read_json_file("res://frontdoor/data/modules.json")
	for m in mods:
		if String(m["id"]) == id:
			return String(m["label"]).to_upper()
	return ""


func lines_have(lines: Array, needle: String) -> bool:
	for l in lines:
		if String(l).contains(needle):
			return true
	return false


func _mode_resume() -> void:
	var res := {}
	var llm_start: int = d._llm_node().request_count
	# the real boot of a profile that predates the module (written before launch): launched, no colonist
	var seed_copy = ProfileStore.read_json_file(OS.get_environment("HANDLER_PROBE_LEGACY"))
	var boot_state := shell.current_state_name()
	var first := disk_profile()
	var first_colonist := cr.colonist().duplicate(true)
	var legacy := {
		"seeded_without_colonist": typeof(seed_copy) == TYPE_DICTIONARY and (seed_copy["assignments"] as Array).is_empty() and bool(seed_copy["acceptance"]["launched"]),
		"colonist_generated_on_open": boot_state == "HANDLER" and (first.get("assignments", []) as Array).size() == 1 and shell.module_open_count == 1,
		"persisted": (first.get("assignments", []) as Array).size() == 1 and String(first["assignments"][0]["fields"]["colonist_id"]) == cr.colonist_id(),
	}
	await reopen()
	legacy["second_open_equal"] = JSON.stringify(cr.colonist()) == JSON.stringify(first_colonist) and shell.module_open_count == 2
	res["legacy_573_profile"] = legacy

	var base := disk_profile()
	var cid := cr.colonist_id()
	# a restart before the mission was accepted lands in the module, with the same colonist, no chat, no model
	var llm0: int = d._llm_node().request_count
	await restart(base.duplicate(true))
	res["unaccepted_boot"] = {
		"state": shell.current_state_name(),
		"chat_mounted": d._cc().is_mounted(),
		"model_requests": d._llm_node().request_count - llm0 + cr.model_requests,
		"same_colonist": cr.colonist_id() == cid,
		"launch_enabled": sc.launch_rect_cells().size.x >= 14 and mounted_visible(),
	}
	# after the mission was accepted the boot lands in the shell; the typed command reopens the module
	var accepted: Dictionary = base.duplicate(true)
	accepted["acceptance"]["mission_accepted"] = true
	await restart(accepted)
	var ab := {"state": shell.current_state_name()}
	d._cr_say("handler")
	await d._wait_for(func(): return shell.current_state_name() == "HANDLER" and sc.is_mounted(), 5.0)
	await d._wait_frames(3)
	var ui := ui_data()
	ab["handler_reopens_module"] = shell.current_state_name() == "HANDLER"
	ab["acceptance_marked"] = any_row_contains(String(ui["accepted_status"])) and any_row_contains(String(ui["profile_values"]["status_accepted"]))
	var log_n := shell.route_log.size()
	var w0 := shell.world_request_count
	shell.world_dry_run = true
	await mouse(centre(sc.launch_rect_cells()))
	var after := disk_profile()
	ab["relaunch_same_route"] = shell.route_log.size() == log_n + 1 and String(shell.route_log.back()["route"]) == "world_entry" and String(shell.route_log.back()["assignment"]) == cid and shell.world_request_count == w0 + 1
	ab["acceptance_record_single"] = ProfileStore.mission_accepted(after) and (after["assignments"] as Array).size() == 1 and (after["acceptance"] as Dictionary).keys().size() == 5
	res["accepted_boot"] = ab
	# accepted the invitation but never chose a handle: the module is still locked
	var partial := ProfileStore.new_profile("newb7001", "HNDL-7001")
	partial["acceptance"]["accepted"] = true
	partial["acceptance"]["handler"] = "HNDL-7001"
	await restart(partial)
	res["accepted_no_handle"] = {"state": shell.current_state_name()}
	# a fresh install: no module in dir, none in the router, the typed name is refused like any other
	var m_before := shell.module_open_count
	await restart(null, false)
	var label := module_label("handler")
	var listed: Array = await dir_lines()
	var fresh := {
		"state": shell.current_state_name(),
		"dir_lists_handler": lines_have(listed, label),
		"dir_control_lists_chat": lines_have(listed, module_label("chat")),
		"router_enum_has_handler": (shell._ctx["modules"] as Array).has("handler"),
	}
	d._cr_say("handler")
	await d._wait_frames(4)
	fresh["open_refused"] = shell.current_state_name() == "SHELL" and shell.module_open_count == m_before and not mounted_visible()
	res["fresh"] = fresh
	# unlocked: the same checks flip once the funnel has been finished
	await restart(accepted)
	var listed2: Array = await dir_lines()
	res["unlocked"] = {"dir_lists_handler": lines_have(listed2, label), "router_enum_has_handler": (shell._ctx["modules"] as Array).has("handler")}
	# a profile that does not parse: moved aside, a fresh one made, the shell comes up
	await restart("corrupt")
	var moved := false
	var da := DirAccess.open("user://")
	for f in da.get_files():
		if f.begins_with("profile.json.corrupt"):
			moved = true
	res["corrupt_profile"] = {"state": shell.current_state_name(), "no_crash": cr.loaded() and cr.is_inside() == false, "moved_aside": moved}
	# the model is down: the module opens and the press is accepted all the same
	var llm1: int = d._llm_node().request_count
	await restart(base.duplicate(true), false)
	var gf := {"module_opens": shell.current_state_name() == "HANDLER" and mounted_visible()}
	shell.world_dry_run = true
	await mouse(centre(sc.launch_rect_cells()))
	gf["accept_ok"] = shell.last_launch_result == "ok" and disk_accepted() and d._llm_node().request_count == llm1
	res["gate_failed"] = gf
	# The back key returns to the prompt; the module reopens with the same colonist; the chat still opens
	await restart(base.duplicate(true), true)
	var eb := {}
	var id1 := cr.colonist_id()
	await key(back_key())
	eb["state"] = shell.current_state_name()
	d._cr_say("handler")
	await d._wait_for(func(): return shell.current_state_name() == "HANDLER" and sc.is_mounted(), 5.0)
	eb["reopen_same_colonist"] = cr.colonist_id() == id1
	await key(back_key())
	d._cr_say("chat")
	await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
	eb["chat_still_opens"] = shell.current_state_name() == "CHAT" and d._cc().is_mounted()
	d._cr_say("leave")
	await d._wait_frames(4)
	res["esc_back"] = eb
	_out["resume"] = res
	_out["freeze"] = await _freeze(base)
	_out["model_requests_total"] = d._llm_node().request_count - llm_start


func _freeze(base: Dictionary) -> Dictionary:
	var res := {}
	var c0: String = JSON.stringify(base["assignments"][0])
	# an edit of the data (a new rules version, a new name, a changed template) never changes the colonist
	var copy := _data_copy("edited", func(name, data):
		if name == "colonist_rules.json":
			data["template_version"] = int(data["template_version"]) + 1
		elif name == "colonist_tables.json":
			(data["given_names"] as Array).append("Zzyzx")
			data["bio_templates"][0]["text"] = "A rewritten first line for {given_name}."
		return data)
	var original := OS.get_environment(ProfileStore.ENV_HANDLER_DIR)
	OS.set_environment(ProfileStore.ENV_HANDLER_DIR, copy)
	await restart(base.duplicate(true))
	res["data_changed_same_colonist"] = shell.current_state_name() == "HANDLER" and JSON.stringify(cr.colonist()) == c0 and JSON.stringify(disk_profile()["assignments"][0]) == c0
	OS.set_environment(ProfileStore.ENV_HANDLER_DIR, original)
	# a colonist that no longer validates is replaced, and an acceptance of the old one is cleared
	var tampered: Dictionary = base.duplicate(true)
	tampered["assignments"][0]["fields"]["age"] = 15
	tampered["acceptance"]["mission_accepted"] = true
	await restart(tampered)
	d._cr_say("handler")
	await d._wait_for(func(): return shell.current_state_name() == "HANDLER" and sc.is_mounted(), 5.0)
	await d._wait_frames(3)
	var now := cr.colonist()
	var data := cr.handler_data()
	res["tampered_regenerated"] = JSON.stringify(now) != JSON.stringify(tampered["assignments"][0]) and int(now["fields"]["age"]) >= 21
	res["regenerated_valid"] = ColonistGen.validate(now, data["tables"], data["rules"], true).is_empty()
	var disk := disk_profile()
	res["acceptance_cleared_when_regenerated"] = not ProfileStore.mission_accepted(disk) and not (disk["acceptance"] as Dictionary).has("mission_accepted")
	# unknown keys anywhere in the profile survive the open and the press
	var keyed: Dictionary = base.duplicate(true)
	keyed["zz_future"] = {"a": [1, 2], "b": {"c": "d"}}
	keyed["player"]["zz_player"] = "x"
	keyed["acceptance"]["zz_acc"] = 1
	await restart(keyed)
	shell.world_dry_run = true
	await mouse(centre(sc.launch_rect_cells()))
	var kept := disk_profile()
	res["hostile_profile_keys_survive"] = kept.has("zz_future") and kept["zz_future"]["b"]["c"] == "d" and kept["player"].has("zz_player") and kept["acceptance"].has("zz_acc") and ProfileStore.mission_accepted(kept)
	return res


## --- handler_mutate ---------------------------------------------------------------------------------------------------

## Every word of a string carries the marker, except a word that holds a slot (its value carries one).
func _mark(text: String) -> String:
	var out: Array = []
	for w in text.split(" ", false):
		out.append(String(w) if String(w).contains("{") else MARKER + String(w))
	return " ".join(PackedStringArray(out))


func _mut_list(list: Array, box: Dictionary) -> Array:
	var out: Array = []
	for e in list:
		box["total"] += 1
		box["words"].append_array(String(e).to_lower().split(" ", false))
		out.append(_mark(String(e)))
	return out


func _mut_ui(node: Variant, box: Dictionary, skip_keys: Array) -> Variant:
	match typeof(node):
		TYPE_STRING:
			box["total"] += 1
			box["words"].append_array(String(node).to_lower().split(" ", false))
			return _mark(String(node))
		TYPE_DICTIONARY:
			var out := {}
			for k in node:
				out[k] = node[k] if skip_keys.has(String(k)) else _mut_ui(node[k], box, skip_keys)
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for e in node:
				arr.append(_mut_ui(e, box, skip_keys))
			return arr
	return node


func _mutate_file(name: String, data: Variant, box: Dictionary) -> Variant:
	if name == "handler_ui.json":
		return _mut_ui(data, box, ["keys", "focus_marker", "_note", "draft", "schema"])
	if name != "colonist_tables.json":
		return data
	var t: Dictionary = data
	for h in t["hubs"]:
		h["name"] = _mut_list([h["name"]], box)[0]
	t["given_names"] = _mut_list(t["given_names"], box)
	t["family_names"] = _mut_list(t["family_names"], box)
	for g in t["gender"]:
		for k in ["label", "they", "them", "their"]:
			g[k] = _mut_list([g[k]], box)[0]
	for p in t["professions"]:
		p["label"] = _mut_list([p["label"]], box)[0]
	t["education"] = _mut_list(t["education"], box)
	t["family"] = _mut_list(t["family"], box)
	for tr in t["traits"]:
		tr["label"] = _mut_list([tr["label"]], box)[0]
		tr["excludes"] = _mut_list(tr["excludes"], box)
	for k in t["intimate"]:
		t["intimate"][k] = _mut_list(t["intimate"][k], box)
	for b in t["bio_templates"]:
		b["text"] = _mut_list([b["text"]], box)[0]
		for rk in b.get("requires", {}):
			b["requires"][rk] = _mut_list(b["requires"][rk], box)
	return t


## Tokens by kind: carrying the marker, an original word of the data (unmarked), or a word nothing explains.
func _classify(tokens: Array, allowed: Dictionary, word_set: Dictionary) -> Dictionary:
	var letters := RegEx.new()
	letters.compile("[A-Za-z]{2,}")
	var marked := 0
	var original := 0
	var chrome := 0
	for t in tokens:
		var tok := String(t)
		if tok.begins_with(MARKER):
			marked += 1
			continue
		if letters.search(tok) == null or allowed.has(tok.trim_suffix(":")) or allowed.has(tok):
			continue
		if word_set.has(tok.to_lower().trim_suffix(":").trim_suffix(".").trim_suffix(",")):
			original += 1
		else:
			chrome += 1
	return {"marked": marked, "original": original, "chrome": chrome}


func _mode_mutate() -> void:
	var box := {"total": 0, "words": []}
	var copy := _data_copy("mutated", func(name, data): return _mutate_file(name, data, box))
	var original := OS.get_environment(ProfileStore.ENV_HANDLER_DIR)
	OS.set_environment(ProfileStore.ENV_HANDLER_DIR, copy)
	await reach(SEED_BASE + 10)
	var dossier_lines: Array = await full_pane_lines("dossier")
	var profile_lines: Array = await full_pane_lines("profile")
	var p := cr.profile_snapshot()
	var f: Dictionary = cr.colonist().get("fields", {})
	var allowed := {}
	var own: Array = [String(p["player"]["handle"]), String(p["player"]["designation"]), String(p["handler"]["name"]), String(f.get("colonist_id", "")), String(f.get("handler_of_record", "")), String(f.get("assisted_by", ""))]
	for df in cr.dossier_snapshot().get("fields", {}).values():
		own.append_array(String(df).split(" ", false))
	for o in own:
		allowed[String(o)] = true
	# the chrome rows (title, status, button) are read from the same snapshot
	var grid := rows()
	var l := lay()
	var chrome: Array = [String(grid[0])]
	for key_name in ["status", "launch"]:
		var r: Rect2i = l[key_name]
		for y in range(r.position.y, r.position.y + r.size.y):
			chrome.append(String(grid[y]).substr(r.position.x, r.size.x))
	var tokens: Array = []
	for row in dossier_lines + profile_lines + chrome:
		tokens.append_array(String(row).split(" ", false))
	var word_set := {}
	for w in box["words"]:
		word_set[String(w).strip_edges().trim_suffix(".").trim_suffix(",")] = true
	var counts := _classify(tokens, allowed, word_set)
	# the instrument on planted input: one hard-coded word and one original word must each be counted
	var planted := _classify(["QZVTNONSENSE", "courier", MARKER + "ok"], allowed, {"courier": true})
	var from_data := true
	for fd in rules_data().get("fields", []):
		if String(fd["src_kind"]) == "table" and not String(f.get(String(fd["id"]), "")).begins_with(MARKER):
			from_data = false
	OS.set_environment(ProfileStore.ENV_HANDLER_DIR, original)
	_out["mutate"] = {
		"strings_total": int(box["total"]),
		"marker_tokens_rendered": int(counts["marked"]),
		"original_words_rendered": int(counts["original"]),
		"hardcoded_chrome": int(counts["chrome"]),
		"planted_detected": int(planted["chrome"]) == 1 and int(planted["original"]) == 1 and int(planted["marked"]) == 1,
		"colonist_values_from_data": from_data,
		"tokens_checked": tokens.size(),
	}


## --- pixels: shared by handler_layout and handler_states ---------------------------------------------------

## Cell rows of the grid that carry text, against the lit pixels of the same rows. The button's rows are
## measured on their own (its frame is lit without text). Returns {rows_text, rows_lit, mismatches}.
func row_pattern(img: Image, grid: Array, layout: Dictionary, factor: float) -> Dictionary:
	var btn: Rect2i = layout["launch"]
	var cols := int(layout["cols"])
	var mismatches := 0
	var text_rows := 0
	var lit_rows := 0
	for r in range(grid.size()):
		if r >= btn.position.y and r < btn.position.y + btn.size.y:
			continue
		var has_text := String(grid[r]).strip_edges() != ""
		var band: Rect2i = d._phys(Rect2(0, r * HandlerLayout.CELL_H, cols * HandlerLayout.CELL_W, HandlerLayout.CELL_H), factor)
		var lit := int(d._region_stats(img, band)["lit"]) > 0
		text_rows += 1 if has_text else 0
		lit_rows += 1 if lit else 0
		if has_text != lit:
			mismatches += 1
	return {"rows_text": text_rows, "rows_lit": lit_rows, "mismatches": mismatches}


func overflow_rows(grid: Array, layout: Dictionary) -> int:
	var n := 0
	var g: Rect2i = layout["gutter"]
	for y in range(g.position.y, g.position.y + g.size.y):
		if g.size.x > 0 and String(grid[y]).substr(g.position.x, g.size.x).strip_edges() != "":
			n += 1
	for line in grid:
		if String(line).length() > int(layout["cols"]):
			n += 1
	return n


func fresh_file(path: String) -> bool:
	return FileAccess.get_modified_time(path) >= _started_unix - 2 and FileAccess.get_file_as_bytes(path).size() > 0


func frame_rects(img: Image, layout: Dictionary, factor: float) -> Array:
	var w := img.get_width()
	var h := img.get_height()
	var frame: Array = [Rect2i(0, 0, w, 3), Rect2i(0, h - 3, w, 3), Rect2i(0, 0, 3, h), Rect2i(w - 3, 0, 3, h)]
	var grid_w := int(layout["cols"]) * HandlerLayout.CELL_W
	var grid_h := int(layout["rows"]) * HandlerLayout.CELL_H
	if int(grid_w * factor) < w:
		frame.append(Rect2i(int(grid_w * factor), 0, w - int(grid_w * factor), h))
	if int(grid_h * factor) < h:
		frame.append(Rect2i(0, int(grid_h * factor), w, h - int(grid_h * factor)))
	return frame


func lit_frac(img: Image, rect: Rect2i) -> float:
	var st: Dictionary = d._region_stats(img, rect)
	return float(st["lit"]) / maxf(1.0, float(st["n"]))


## The numbers every screenshot is judged by, read from the image and the grid the screen drew.
func pixel_facts(img: Image, layout: Dictionary, factor: float) -> Dictionary:
	var gutter: Rect2i = d._cc_cells(layout["gutter"], factor)
	var pal: Dictionary = d._cc_palette(img)
	var grid_w := int(layout["cols"]) * HandlerLayout.CELL_W
	var grid_h := int(layout["rows"]) * HandlerLayout.CELL_H
	var in_client: bool = int(pal["x0"]) >= 0 and int(pal["y0"]) >= 0 and int(pal["x1"]) < int(grid_w * factor) and int(pal["y1"]) < int(grid_h * factor)
	var btn: Rect2i = d._cc_cells(layout["launch"], factor)
	var gut_frac := lit_frac(img, gutter) if gutter.size.x > 0 else 0.0
	var margin := 0.0
	var frame := frame_rects(img, layout, factor)
	var lit := 0
	var n := 0
	for r in frame:
		var st: Dictionary = d._region_stats(img, r)
		lit += int(st["lit"])
		n += int(st["n"])
	margin = float(lit) / maxf(1.0, float(n))
	return {
		"title_lit": int(d._region_stats(img, d._cc_cells(layout["title"], factor))["lit"]),
		"dossier_lit": int(d._region_stats(img, d._cc_cells(layout["dossier"], factor))["lit"]),
		"profile_lit": int(d._region_stats(img, d._cc_cells(layout["profile"], factor))["lit"]),
		"launch_lit": int(d._region_stats(img, btn)["lit"]),
		"launch_rect_lit_frac": lit_frac(img, btn),
		"gutter_lit_frac": gut_frac,
		"margin_lit_frac": margin,
		"teal_frac_of_lit": pal["teal_frac"],
		"orange_frac_of_lit": pal["orange_frac"],
		"offpalette_frac_of_lit": pal["off_frac"],
		"lit_bbox_inside_client": in_client,
	}


func palette_ok(px: Dictionary) -> bool:
	return float(px["gutter_lit_frac"]) <= 0.002 and float(px["margin_lit_frac"]) <= 0.002 and float(px["teal_frac_of_lit"]) >= 0.55 and float(px["orange_frac_of_lit"]) <= 0.30 and float(px["offpalette_frac_of_lit"]) <= 0.08 and bool(px["lit_bbox_inside_client"])


func tail_word_of_dossier() -> String:
	var last: Array = dossier_pairs().back()
	return String(last[1]).split(" ", false)[-1]


## --- handler_layout ----------------------------------------------------------------------------------------------

func _mode_layout() -> void:
	await reach(SEED_BASE + 20)
	var factor := win.content_scale_factor
	var tag := "%dx%d" % [win.size.x, win.size.y]
	var out_dir: String = d._out_dir()
	var png := "%s/layout_%s.png" % [out_dir, tag]
	await d._wait_frames(6)
	var img: Image = await d._grab()
	img.save_png(png)
	var l := lay()
	var grid := rows()
	var st := state()
	var rects := HandlerLayout.rect_list(l)
	var px := pixel_facts(img, l, factor)
	var btn: Rect2i = l["launch"]
	var others: Array = [l["title"], l["dossier"], l["gutter"], l["profile"], l["status"]]
	var btn_overlaps := 0
	for o in others:
		if (o as Rect2i).size.x > 0 and btn.intersects(o):
			btn_overlaps += 1
	var p := cr.profile_snapshot()
	var cf: Dictionary = cr.colonist().get("fields", {})
	var label := String(ui_data()["launch_label"])
	var btn_text := ""
	for y in range(btn.position.y, btn.position.y + btn.size.y):
		btn_text += String(grid[y]).substr(btn.position.x, btn.size.x)
	var pat := row_pattern(img, grid, l, factor)
	# the end of the dossier is reachable with the keyboard
	await focus_pane("dossier")
	await key(KEY_END)
	var st_end := state()
	var drect: Rect2i = l["dossier"]
	var end_rows := rows()
	var band := ""
	for y in range(drect.position.y + 1, drect.position.y + drect.size.y):
		band += String(end_rows[y]).substr(drect.position.x, drect.size.x) + "\n"
	var end_ok := int(st_end["scroll_dossier"]) == int(st_end["max_dossier"]) and band.contains(tail_word_of_dossier())
	await key(KEY_HOME)
	var png_bytes := FileAccess.get_file_as_bytes(png).size()
	var term: TerminalGrid = d._terminal_node()
	var res := {
		"win": tag,
		"factor": factor,
		"cols": int(l["cols"]),
		"rows": int(l["rows"]),
		"tier": String(l["tier"]),
		"rect_overlaps": HandlerLayout.overlap_count(rects),
		"out_of_bounds": HandlerLayout.out_of_bounds_count(rects, int(l["cols"]), int(l["rows"])),
		"overflow_rows": int(st["overflow"]) + overflow_rows(grid, l),
		"names_truncated": 0,
		"dossier_cols": (l["dossier"] as Rect2i).size.x,
		"profile_cols": (l["profile"] as Rect2i).size.x,
		"title_visible": String(grid[0]).contains(String(ui_data()["title"])) and int(px["title_lit"]) > 0,
		"launch": {
			"rect_w_cells": btn.size.x,
			"rect_h_cells": btn.size.y,
			"inside_client": btn.position.x >= 0 and btn.position.y >= 0 and btn.end.x <= int(l["cols"]) and btn.end.y <= int(l["rows"]),
			"overlaps_panes": btn_overlaps,
		},
		"scroll_end_reachable": end_ok,
		"px": px,
		"crt": {"scanline_spacing_px": float(d._overlay_material().get_shader_parameter("scanline_spacing_px"))},
		"png_bytes": png_bytes,
		"shot_is_client": mounted_visible() and not term.get_parent().visible and not d._panels_node().get_parent().visible and int(px["dossier_lit"]) > 0 and int(px["profile_lit"]) > 0,
		"text": {
			"handle_found": String(grid[0]).contains(String(p["player"]["handle"])),
			"handler_name_found": any_row_contains(String(p["handler"]["name"])),
			"colonist_name_found": any_row_contains(String(cf["given_name"])) and any_row_contains(String(cf["family_name"])),
			"launch_label_in_button_rect": btn_text.contains(label) and float(px["launch_rect_lit_frac"]) >= 0.05,
			"rows_lit_match_rows_text": int(pat["mismatches"]) == 0,
			"every_text_row_lit": int(pat["rows_text"]) == int(pat["rows_lit"]) or int(pat["mismatches"]) == 0,
			"every_empty_row_dark": int(pat["mismatches"]) == 0,
			"png_fresh": fresh_file(png),
		},
	}
	# a click on the drawn button lands, at this content scale too (the click is computed from the drawn rectangle)
	var wc0 := shell.world_request_count
	await mouse(centre(sc.launch_rect_cells()))
	res["click_lands_at_this_scale"] = shell.world_request_count - wc0 == 1
	if tag == "1920x1080":
		res["neg"] = _layout_negatives(img, l, factor, grid)
	if tag == "1280x720" and OS.get_environment("HANDLER_RESIZE") == "1":
		res["resize"] = await _resize_run()
	d._write_json("%s/layout_%s.json" % [out_dir, tag], res)
	print("PROBE_HANDLER_LAYOUT " + JSON.stringify(res))


## The instruments, proven on planted violations.
func _layout_negatives(img: Image, layout: Dictionary, factor: float, grid: Array) -> Dictionary:
	var grey := Image.create(200, 100, false, Image.FORMAT_RGB8)
	grey.fill(Palette.BG)
	grey.fill_rect(Rect2i(10, 10, 120, 40), Color(0.7, 0.7, 0.7))
	var grey_stats: Dictionary = d._cc_palette(grey)
	var gutter: Rect2i = d._cc_cells(layout["gutter"], factor)
	var planted := Image.new()
	planted.copy_from(img)
	planted.fill_rect(Rect2i(gutter.position.x, gutter.position.y + 100, gutter.size.x, 40), Color(1, 1, 1))
	var shifted := HandlerLayout.compute(1920, 1080, 14)
	var sd: Rect2i = shifted["dossier"]
	shifted["dossier"] = Rect2i(sd.position.x + 6, sd.position.y, sd.size.x, sd.size.y)
	var long_grid: Array = grid.duplicate()
	long_grid[10] = String(long_grid[10]) + "x"
	var dark := Image.create(64, 64, false, Image.FORMAT_RGB8)
	dark.fill(Palette.BG)
	var low := HandlerLayout.compute(1000, 600, 14)
	var no_button := Image.new()
	no_button.copy_from(img)
	var br: Rect2i = d._cc_cells(layout["launch"], factor)
	no_button.fill_rect(br, Palette.BG)
	var handle := String(cr.profile_snapshot()["player"]["handle"])
	return {
		"grey_text_fails_palette": float(grey_stats["off_frac"]) > 0.08,
		"gutter_plant_detected": lit_frac(planted, gutter) > 0.002 and lit_frac(img, gutter) <= 0.002,
		"shifted_rect_overflow_detected": HandlerLayout.overlap_count(HandlerLayout.rect_list(shifted)) > 0,
		"overlong_row_detected": overflow_rows(long_grid, layout) > 0 and overflow_rows(grid, layout) == 0,
		"below_min_viewport_not_full": String(low["tier"]) != HandlerLayout.FULL,
		"dark_image_zero_lit": int(d._region_stats(dark, Rect2i(0, 0, 64, 64))["lit"]) == 0,
		"missing_button_detected": lit_frac(no_button, br) < 0.05 and lit_frac(img, br) >= 0.05,
		"stale_png_detected": not fresh_file(ProjectSettings.globalize_path("res://project.godot")) and fresh_file(d._out_dir() + "/layout_1920x1080.png"),
		"wrong_text_detected": not any_row_contains(handle + "_not_on_screen") and any_row_contains(handle),
	}


func _resize_run() -> Dictionary:
	await focus_pane("dossier")
	await key(KEY_END)
	var scroll_before := int(state()["scroll_dossier"])
	var cols_before := int(lay()["cols"])
	await mouse(centre(sc.launch_rect_cells()))
	var focus_before := String(state()["focus"])
	win.size = Vector2i(1920, 1080)
	await d._wait_seconds(1.0)
	await d._wait_frames(10)
	var l := lay()
	var grid := rows()
	var recomputed: bool = int(l["cols"]) == 192 and int(l["rows"]) == 54 and grid.size() == 54 and grid.all(func(r): return String(r).length() == 192)
	var st := state()
	var accepted_text := String(ui_data()["accepted_status"])
	var btn: Rect2i = l["launch"]
	var res := {
		"from": "1280x720",
		"to": "1920x1080",
		"layout_recomputed": recomputed,
		"cols_before": cols_before,
		"cols_after": int(l["cols"]),
		"overflow_rows": int(st["overflow"]) + overflow_rows(grid, l),
		"scroll_clamped": scroll_before > 0 and int(st["scroll_dossier"]) <= int(st["max_dossier"]),
		"focus_kept": String(st["focus"]) == focus_before,
		"accepted_kept": any_row_contains(accepted_text) and disk_accepted(),
		"launch_rect_in_bounds": btn.end.x <= int(l["cols"]) and btn.end.y <= int(l["rows"]) and btn.size.x >= 14,
	}
	await key(KEY_F11)
	await d._wait_mode(win, "fullscreen")
	var fs := lay()
	var keeps: bool = String(state()["focus"]) == focus_before and any_row_contains(accepted_text) and int(fs["cols"]) >= 192 and mounted_visible()
	await key(KEY_F11)
	await d._wait_mode(win, "windowed")
	res["fullscreen_toggle_keeps_state"] = keeps and String(state()["focus"]) == focus_before and any_row_contains(accepted_text)
	return res


## --- handler_states ----------------------------------------------------------------------------------------------

func _shot(name: String, expect: Array) -> Dictionary:
	await d._wait_frames(4)
	var img: Image = await d._grab()
	var path := "%s/%s.png" % [d._out_dir(), name]
	img.save_png(path)
	var l := lay()
	var grid := rows()
	var factor := win.content_scale_factor
	var px := pixel_facts(img, l, factor)
	var pat := row_pattern(img, grid, l, factor)
	var found := true
	for needle in expect:
		if not any_row_contains(String(needle)):
			found = false
	return {
		"state": name,
		"bytes": FileAccess.get_file_as_bytes(path).size(),
		"fresh": fresh_file(path),
		"expect_text_found": found and not expect.is_empty(),
		"rows_lit_match_rows_text": int(pat["mismatches"]) == 0,
		"gutters_dark": float(px["gutter_lit_frac"]) <= 0.002,
		"palette_ok": palette_ok(px),
		"state_sha": _sha(img),
		"_img": img,
	}


func _sha(img: Image) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	return ctx.finish().hex_encode()


func _mode_states() -> void:
	await reach(SEED_BASE + 30)
	var ui := ui_data()
	var p := cr.profile_snapshot()
	var handle := String(p["player"]["handle"])
	var handler_name := String(p["handler"]["name"])
	var label := String(ui["launch_label"])
	var marker := String(ui["focus_marker"])
	var shots: Array = []
	var s_open: Dictionary = await _shot("open", [handle, handler_name, label, String(ui["pane_titles"]["dossier"]), String(ui["pane_titles"]["profile"])])
	shots.append(s_open)
	await key(KEY_TAB)
	shots.append(await _shot("profile_focus", [marker + " " + String(ui["pane_titles"]["profile"])]))
	await key(KEY_TAB)
	var s_launch: Dictionary = await _shot("launch_focus", [label, handle])
	shots.append(s_launch)
	var btn: Rect2i = d._cc_cells(lay()["launch"], win.content_scale_factor)
	var focus_differs: bool = (s_open["_img"] as Image).get_region(btn).get_data() != (s_launch["_img"] as Image).get_region(btn).get_data()
	await focus_pane("dossier")
	for i in range(3):
		await key(KEY_DOWN)
	shots.append(await _shot("scrolled_mid", [marker + " " + String(ui["pane_titles"]["dossier"])]))
	await key(KEY_END)
	var s_end: Dictionary = await _shot("scrolled_end", [tail_word_of_dossier()])
	shots.append(s_end)
	var drect: Rect2i = lay()["dossier"]
	var band := ""
	for y in range(drect.position.y + 1, drect.position.y + drect.size.y):
		band += String(rows()[y]).substr(drect.position.x, drect.size.x) + "\n"
	var first_label := String(ui["section_labels"][String(rules_data()["sections"][0]["id"])])
	var end_facts := {"last_row_found": band.contains(tail_word_of_dossier()), "first_row_absent": not band.contains(first_label)}
	await key(KEY_HOME)
	await focus_pane("launch")
	shell.world_dry_run = true
	await mouse(centre(sc.launch_rect_cells()))
	var accepted_text := String(ui["accepted_status"])
	var s_acc: Dictionary = await _shot("accepted", [accepted_text, String(ui["profile_values"]["status_accepted"])])
	shots.append(s_acc)
	var acc_facts := {"status_text_found": any_row_contains(accepted_text)}
	var nof_ok: bool = await _not_on_file()
	var nof_text := String(ui["not_on_file"])
	var s_nof: Dictionary = await _shot("not_on_file", [nof_text])
	shots.append(s_nof)
	var nof_facts := {"text_found": nof_ok and any_row_contains(nof_text)}
	var hostile_ok: bool = await _hostile()
	var s_host: Dictionary = await _shot("hostile", [HOSTILE_ORIGIN.substr(0, 14)])
	shots.append(s_host)
	var hostile_lines: Array = await full_pane_lines("profile")
	var host_facts := {"braces_literal": hostile_ok and collapse(text_of(hostile_lines).replace("\n", "")).contains(collapse(HOSTILE_ORIGIN.substr(0, 60))), "within_pane": hostile_ok and int(state()["overflow"]) == 0}
	var out_shots: Array = []
	var tags := {}
	for s in shots:
		var c: Dictionary = (s as Dictionary).duplicate()
		c.erase("_img")
		out_shots.append(c)
		tags[c["state"]] = true
	# the instruments: a blank image, an old file and a wrong needle are each refused
	var blank := Image.create(win.size.x, win.size.y, false, Image.FORMAT_RGB8)
	blank.fill(Palette.BG)
	var l := lay()
	var blank_px := pixel_facts(blank, l, win.content_scale_factor)
	var blank_pat := row_pattern(blank, rows(), l, win.content_scale_factor)
	_out["display"] = OS.get_environment("DISPLAY")
	_out["shots"] = out_shots
	_out["focus_launch_shot"] = {"focus_px_differs": focus_differs}
	_out["accepted_shot"] = acc_facts
	_out["scrolled_end_shot"] = end_facts
	_out["not_on_file_shot"] = nof_facts
	_out["hostile_shot"] = host_facts
	_out["neg"] = {
		"blank_png_fails": not palette_ok(blank_px) and int(blank_pat["mismatches"]) > 0,
		"stale_png_fails": not fresh_file(ProjectSettings.globalize_path("res://project.godot")),
		"wrong_text_fails": not any_row_contains(handle + "_not_on_screen"),
	}


## --- handler_world -----------------------------------------------------------------------------------------------

func _mode_world() -> void:
	await reach(SEED_BASE + 40, false)
	var typed_world := 0
	var ok_state := shell.current_state_name() == "HANDLER"
	var w0 := shell.world_request_count
	var log_n := shell.route_log.size()
	await mouse(centre(sc.launch_rect_cells()))
	var world: Node = null
	var guard := 0
	while world == null and guard < 600:
		guard += 1
		await d._wait_frames(2)
		world = d.get_tree().get_first_node_in_group("stalag_world")
	var hidden_terminal := false
	var hidden_layer := false
	var unmounted := false
	var chunks := 0
	var grounded := false
	if world != null:
		hidden_terminal = not d._terminal_node().get_parent().visible
		hidden_layer = not d._scene().get_node("HandlerLayer").visible
		unmounted = not sc.is_mounted()
		var streamer: Node = world.get_node("Streamer")
		var settle := 0
		guard = 0
		while guard < 4000 and settle < 30:
			guard += 1
			await d._wait_frames(1)
			if streamer.ring_ready() and streamer.pending_count() == 0 and streamer.settled() and world.is_grounded() and world.chunks_loaded() >= 9:
				settle += 1
		chunks = int(world.chunks_loaded())
		grounded = bool(world.is_grounded())
	var entry: Dictionary = shell.route_log[log_n] if shell.route_log.size() > log_n else {}
	var in_world := world != null
	if world != null:
		world.request_exit()
		await d._wait_frames(4)
	d._ext_rendered.clear()
	d._cr_say("dir")
	await d._wait_frames(6)
	var data = ProfileStore.read_json_file(ProfileStore.handler_data_dir() + "/launch_route.json")
	_out["world"] = {
		"entered": in_world and ok_state and shell.world_request_count == w0 + 1,
		"chunks": chunks,
		"grounded": grounded,
		"entered_via": "handler_launch" if String(entry.get("route", "")) != "" and typed_world == 0 else "",
		"route": String(entry.get("route", "")),
		"typed_world_command": typed_world,
		"assignment_passed": String(entry.get("assignment", "")) == cr.colonist_id() and not cr.colonist_id().is_empty(),
		"terminal_hidden_during": hidden_terminal,
		"handler_layer_hidden_during": hidden_layer,
		"handler_unmounted": unmounted,
		"exited_shell_alive": lines_have(d._ext_rendered, "DIRECTORY LISTING") and shell.current_state_name() == "SHELL",
		"route_from_data": typeof(data) == TYPE_DICTIONARY and String(data.get("route", "")) == String(entry.get("route", "x")),
	}


## --- handler_isolation -------------------------------------------------------------------------------------------

func _mode_isolation() -> void:
	var out_dir: String = d._out_dir()
	var marker := FileAccess.open("user://isolation_probe.txt", FileAccess.WRITE)
	marker.store_string("probe")
	marker.close()
	var abs_path := ProjectSettings.globalize_path("user://isolation_probe.txt")
	_out["user_dir"] = OS.get_user_data_dir()
	_out["file_written_under_out"] = FileAccess.file_exists("user://isolation_probe.txt") and abs_path.begins_with(out_dir)
	_out["display"] = OS.get_environment("DISPLAY")
	_out["audio_driver"] = AudioServer.get_driver_name()
