extends Control
class_name HandlerScreen

## The HANDLER screen of the Q-Ent OS (Spec #575): the one colonist the player was
## assigned laid out flat on the left, the player's own file on the right, and one
## button, the acceptance of the mission, at the bottom. Drawn as a glyph grid in the
## same teal and orange, in the same font, at the same 10 x 20 cell pitch as the chat
## client and the terminal.
##
## This node is a view. The colonist, the profile and every word live in the chatroom
## node and in handler_ui.json; HandlerView builds the rows and HandlerLayout decides
## where each pane sits. The screen owns only focus, scroll, the click and the keys. It
## knows no destination: pressing Launch announces `handler_launch_requested` and
## reads back what the shell says happened. It never reads a file or a clock, never
## asks a model and draws no random value.
##
## Controls: the keys come from handler_ui.json. Initial focus is the dossier, so a
## stray or repeated Enter at mount does nothing; Enter or Space accepts only while
## Launch has the focus; a held key repeats nothing but scrolling. The fullscreen
## toggles belong to the boot controller and never reach this node's actions. Esc is never a key
## of this screen (Spec 578): it belongs to the pause menu, so "Esc" is not a parsable key name here.

const FONT_PATH := "res://assets/fonts/DejaVuSansMono.ttf"
const FONT_SIZE := 16
const BASELINE := 15.0
const PANES := ["dossier", "profile", "launch"]
const SCROLL_ACTIONS := ["scroll_up", "scroll_down", "page_up", "page_down", "top", "bottom"]

var _font: Font
var _cr: Chatroom = null
var _shell: ShellController = null
var _ui: Dictionary = {}
var _rules: Dictionary = {}
var _view: Dictionary = {}
var _keymap: Array = []
var _mounted: bool = false

var _focus: int = 0
var _shown: String = "dossier"
var _scroll: Dictionary = {"dossier": 0, "profile": 0}
var _status_key: String = ""
var _layout: Dictionary = {}
var _cols: int = 0
var _rows: int = 0
var _segs: Array = []
var _fills: Array = []
var _frames: Array = []
var _lines: Dictionary = {"dossier": [], "profile": []}
var _view_rows: Dictionary = {"dossier": 0, "profile": 0}
var _dirty: bool = true
var _overflow: int = 0


func _ready() -> void:
	_font = load(FONT_PATH)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	resized.connect(_on_resized)


## --- Mounting -----------------------------------------------------------------------

## Called when the module opens, and again on every reopen: focus starts on the dossier.
func mount(chatroom: Chatroom, shell: ShellController) -> void:
	_cr = chatroom
	_shell = shell
	var hd := _cr.handler_data()
	_ui = hd.get("ui", {})
	_rules = hd.get("rules", {})
	_load_keys()
	_focus = 0
	_shown = "dossier"
	_scroll = {"dossier": 0, "profile": 0}
	_status_key = ""
	_mounted = true
	_dirty = true
	queue_redraw()


func unmount() -> void:
	_mounted = false
	queue_redraw()


func is_mounted() -> bool:
	return _mounted


func _load_keys() -> void:
	_keymap = []
	var keys: Dictionary = _ui.get("keys", {})
	for action in keys:
		var parsed := _parse_key(String(keys[action]))
		if not parsed.is_empty():
			parsed["action"] = String(action).trim_suffix("_alt")
			parsed["alias"] = String(action)
			_keymap.append(parsed)


## "Shift+Tab" -> {key, shift, ctrl, alt}.
static func _parse_key(spec: String) -> Dictionary:
	var shift := false
	var ctrl := false
	var alt := false
	var name := ""
	for part in spec.split("+", false):
		match String(part):
			"Shift":
				shift = true
			"Ctrl":
				ctrl = true
			"Alt":
				alt = true
			_:
				name = String(part)
	var code := KEY_NONE
	match name:
		"Enter":
			code = KEY_ENTER
		"Space":
			code = KEY_SPACE
		"Tab":
			code = KEY_TAB
		"Backspace":
			code = KEY_BACKSPACE
		"Up":
			code = KEY_UP
		"Down":
			code = KEY_DOWN
		"PageUp":
			code = KEY_PAGEUP
		"PageDown":
			code = KEY_PAGEDOWN
		"Home":
			code = KEY_HOME
		"End":
			code = KEY_END
	if code == KEY_NONE:
		return {}
	return {"key": code, "shift": shift, "ctrl": ctrl, "alt": alt}


## --- Input ------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _mounted or _cr == null:
		return
	if event is InputEventMouseButton:
		_mouse(event)
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	var k: InputEventKey = event
	# The fullscreen toggles belong to the boot controller: never an action here.
	if k.keycode == KEY_F11 or (k.alt_pressed and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER)):
		return
	var action := _action_for(k)
	if action.is_empty():
		return
	if k.echo and not SCROLL_ACTIONS.has(action):
		get_viewport().set_input_as_handled()
		return
	_run_action(action)
	get_viewport().set_input_as_handled()
	_dirty = true
	queue_redraw()


func _action_for(k: InputEventKey) -> String:
	var code: int = KEY_ENTER if k.keycode == KEY_KP_ENTER else k.keycode
	for entry in _keymap:
		if bool(entry["shift"]) != k.shift_pressed or bool(entry["ctrl"]) != k.ctrl_pressed or bool(entry["alt"]) != k.alt_pressed or k.meta_pressed:
			continue
		if int(entry["key"]) == code:
			return String(entry["action"])
	return ""


func _run_action(action: String) -> void:
	match action:
		"focus_next":
			_set_focus((_focus + 1) % PANES.size())
		"focus_prev":
			_set_focus((_focus + PANES.size() - 1) % PANES.size())
		"scroll_up":
			_scroll_by(-1)
		"scroll_down":
			_scroll_by(1)
		"page_up":
			_scroll_by(-_page())
		"page_down":
			_scroll_by(_page())
		"top":
			_scroll_to(0)
		"bottom":
			_scroll_to(1 << 30)
		"accept":
			if _focus == 2:
				_launch()
		"back":
			Signals.handler_module_closed.emit()


func _set_focus(index: int) -> void:
	_focus = index
	if index < 2:
		_shown = String(PANES[index])


func _focused_pane() -> String:
	return String(PANES[_focus]) if _focus < 2 else ""


func _page() -> int:
	var pane := _focused_pane()
	return maxi(int(_view_rows.get(pane, 1)) - 1, 1) if not pane.is_empty() else 1


func _scroll_by(delta: int) -> void:
	var pane := _focused_pane()
	if not pane.is_empty():
		_scroll[pane] = _clamped(pane, int(_scroll[pane]) + delta)


func _scroll_to(row: int) -> void:
	var pane := _focused_pane()
	if not pane.is_empty():
		_scroll[pane] = _clamped(pane, row)


func _clamped(pane: String, row: int) -> int:
	_ensure_composed()
	return clampi(row, 0, HandlerView.max_scroll((_lines[pane] as Array).size(), int(_view_rows[pane])))


func _mouse(e: InputEventMouseButton) -> void:
	if not e.pressed:
		return
	_ensure_composed()
	var at := e.position
	if e.button_index == MOUSE_BUTTON_LEFT:
		if _cell_rect_px(_layout["launch"]).has_point(at):
			_focus = 2
			_launch()
			_dirty = true
			queue_redraw()
			get_viewport().set_input_as_handled()
		else:
			for i in range(2):
				if _cell_rect_px(_layout[PANES[i]]).has_point(at):
					_set_focus(i)
					_dirty = true
					queue_redraw()
		return
	var delta := 0
	if e.button_index == MOUSE_BUTTON_WHEEL_UP:
		delta = -3
	elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		delta = 3
	if delta == 0:
		return
	for pane in ["dossier", "profile"]:
		if _cell_rect_px(_layout[pane]).has_point(at):
			_scroll[pane] = _clamped(pane, int(_scroll[pane]) + delta)
			_dirty = true
			queue_redraw()
			get_viewport().set_input_as_handled()
			return


func _cell_rect_px(r: Rect2i) -> Rect2:
	return Rect2(r.position.x * HandlerLayout.CELL_W, r.position.y * HandlerLayout.CELL_H, r.size.x * HandlerLayout.CELL_W, r.size.y * HandlerLayout.CELL_H)


## The press: the shell records the acceptance, then hands off through the named route. What
## came of it is read back from the shell and shown in the status line.
func _launch() -> void:
	Signals.handler_launch_requested.emit()
	var result := _shell.last_launch_result if _shell != null else ""
	match result:
		"unavailable":
			_status_key = "launch_unavailable"
		"unknown_route":
			_status_key = "unknown_route"
		_:
			_status_key = ""
	_dirty = true


func _on_resized() -> void:
	_dirty = true
	queue_redraw()


## --- Composition: view model -> segments -------------------------------------------------

func _put(r: int, c: int, text: String, color: Color, bound: int) -> void:
	if r < 0 or r >= _rows or c >= bound or text.is_empty():
		return
	var room := bound - c
	if text.length() > room:
		_overflow += 1
		text = text.substr(0, room)
	_segs.append({"r": r, "c": c, "t": text, "col": color})


func _fill(rect: Rect2i, color: Color) -> void:
	if rect.size.x > 0 and rect.size.y > 0:
		_fills.append({"rect": rect, "col": color})


func _status_text() -> String:
	if not _status_key.is_empty():
		return String(_ui.get(_status_key, ""))
	return String(_view.get("status", ""))


func _compose() -> void:
	_segs = []
	_fills = []
	_frames = []
	_overflow = 0
	_view = HandlerView.build(_cr.profile_snapshot(), _cr.dossier_snapshot().get("fields", {}), _ui, _rules)
	var label := String(_view["launch_label"])
	_layout = HandlerLayout.compute(int(size.x), int(size.y), label.length(), _shown)
	_cols = int(_layout["cols"])
	_rows = int(_layout["rows"])
	var title: Rect2i = _layout["title"]
	_fill(title, Color(Palette.TEAL, 0.10))
	_put(0, 1, String(_view["title"]), Palette.ORANGE, _cols)
	var handle := String(_view["handle"])
	if not handle.is_empty():
		_put(0, maxi(_cols - handle.length() - 1, 1), handle, Palette.TEAL_BRIGHT, _cols)
	for i in range(2):
		_compose_pane(String(PANES[i]))
	_compose_bar(label)


func _compose_pane(pane: String) -> void:
	var rect: Rect2i = _layout[pane]
	if rect.size.x <= 0 or rect.size.y <= 0:
		_lines[pane] = []
		_view_rows[pane] = 0
		return
	_fill(rect, Color(Palette.TEAL, 0.04))
	var focused := _focused_pane() == pane
	var marker := String(_ui.get("focus_marker", "")) if focused else ""
	var heading := String(_view["pane_titles"].get(pane, ""))
	var bound := rect.position.x + rect.size.x
	_put(rect.position.y, rect.position.x + 1, (marker + " " + heading).strip_edges() if focused else heading, Palette.ORANGE if focused else Palette.TEAL, bound)
	var width := maxi(rect.size.x - 2, 1)
	var lines: Array = HandlerView.dossier_lines(_view, width) if pane == "dossier" else HandlerView.profile_lines(_view, width)
	var rows := maxi(rect.size.y - 1, 0)
	_lines[pane] = lines
	_view_rows[pane] = rows
	var top := clampi(int(_scroll[pane]), 0, HandlerView.max_scroll(lines.size(), rows))
	_scroll[pane] = top
	for i in range(rows):
		if top + i >= lines.size():
			break
		var ln: Dictionary = lines[top + i]
		var y := rect.position.y + 1 + i
		var x := rect.position.x + 1
		var text := String(ln["t"])
		match String(ln["kind"]):
			"section":
				_put(y, x, text, Palette.ORANGE, bound)
			"field":
				var lw := int(ln["label_w"])
				_put(y, x, text.substr(0, lw), Palette.TEAL_DIM, bound)
				_put(y, x + lw, text.substr(lw), Palette.TEAL_BRIGHT, bound)
			"cont", "value":
				var lw2 := int(ln["label_w"])
				_put(y, x + lw2, text.substr(lw2), Palette.TEAL_BRIGHT, bound)
			"label":
				_put(y, x, text, Palette.TEAL_DIM, bound)
	var tail_x := bound - 2
	if top > 0:
		_put(rect.position.y, tail_x, "▲", Palette.TEAL_DIM, bound)
	if top + rows < lines.size():
		_put(rect.position.y + rect.size.y - 1, tail_x, "▼", Palette.TEAL_DIM, bound)


func _compose_bar(label: String) -> void:
	var status: Rect2i = _layout["status"]
	var warn := not _status_key.is_empty()
	_put(status.position.y, 1, _status_text(), Palette.ORANGE if warn else Palette.TEAL, status.position.x + status.size.x)
	var btn: Rect2i = _layout["launch"]
	var focused := _focus == 2
	_fill(btn, Color(Palette.ORANGE, 0.28) if focused else Color(Palette.TEAL, 0.08))
	_frames.append({"rect": btn, "col": Palette.ORANGE if focused else Palette.TEAL})
	var cx := btn.position.x + maxi((btn.size.x - label.length()) / 2, 0)
	_put(btn.position.y + btn.size.y / 2, cx, label, Palette.TEAL_BRIGHT, btn.position.x + btn.size.x)


## --- Drawing ----------------------------------------------------------------------------

func _draw() -> void:
	if not _mounted or _cr == null or _font == null:
		return
	if _dirty or _layout.is_empty() or int(size.x) / HandlerLayout.CELL_W != _cols or int(size.y) / HandlerLayout.CELL_H != _rows:
		_compose()
		_dirty = false
	draw_rect(Rect2(Vector2.ZERO, size), Palette.BG)
	for f in _fills:
		draw_rect(_cell_rect_px(f["rect"]), f["col"])
	for fr in _frames:
		var px := _cell_rect_px(fr["rect"])
		draw_rect(Rect2(px.position + Vector2(1, 1), px.size - Vector2(2, 2)), fr["col"], false, 2.0)
	for s in _segs:
		var text: String = s["t"]
		var x := float(int(s["c"]) * HandlerLayout.CELL_W)
		var y := float(int(s["r"]) * HandlerLayout.CELL_H) + BASELINE
		for i in range(text.length()):
			var ch := text.unicode_at(i)
			if ch != 32:
				_font.draw_char(get_canvas_item(), Vector2(x, y), ch, FONT_SIZE, s["col"])
			x += HandlerLayout.CELL_W


## --- Snapshots for probes -----------------------------------------------------------------

func _ensure_composed() -> void:
	if _mounted and _cr != null and (_dirty or _layout.is_empty() or int(size.x) / HandlerLayout.CELL_W != _cols or int(size.y) / HandlerLayout.CELL_H != _rows):
		_compose()
		_dirty = false


## Every cell the screen drew, as `rows` strings of `cols` characters.
func ui_text_snapshot() -> Array:
	_ensure_composed()
	var grid: Array = []
	for r in range(_rows):
		grid.append(" ".repeat(_cols))
	for s in _segs:
		var r := int(s["r"])
		var row := String(grid[r])
		var text: String = s["t"]
		grid[r] = row.substr(0, int(s["c"])) + text + row.substr(int(s["c"]) + text.length())
	return grid


func layout_snapshot() -> Dictionary:
	_ensure_composed()
	return _layout.duplicate(true)


func view_snapshot() -> Dictionary:
	_ensure_composed()
	return _view.duplicate(true)


func segments_snapshot() -> Array:
	_ensure_composed()
	return _segs.duplicate(true)


## {focus, shown, scroll_dossier, scroll_profile, max_dossier, max_profile, status, overflow, lines_dossier, lines_profile, rows_dossier, rows_profile}.
func state_snapshot() -> Dictionary:
	_ensure_composed()
	return {
		"focus": String(PANES[_focus]),
		"shown": _shown,
		"scroll_dossier": int(_scroll["dossier"]),
		"scroll_profile": int(_scroll["profile"]),
		"max_dossier": HandlerView.max_scroll((_lines["dossier"] as Array).size(), int(_view_rows["dossier"])),
		"max_profile": HandlerView.max_scroll((_lines["profile"] as Array).size(), int(_view_rows["profile"])),
		"lines_dossier": (_lines["dossier"] as Array).size(),
		"lines_profile": (_lines["profile"] as Array).size(),
		"rows_dossier": int(_view_rows["dossier"]),
		"rows_profile": int(_view_rows["profile"]),
		"status": _status_text(),
		"overflow": _overflow,
	}


func launch_rect_cells() -> Rect2i:
	_ensure_composed()
	return _layout["launch"]
