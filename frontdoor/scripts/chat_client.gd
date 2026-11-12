extends Control
class_name ChatClient

## The full-screen glyph-grid chat client (Spec #562). A navigation bar across
## the top, the player's rooms and direct messages down the left, the buffer in
## the middle and the people in the room on the right, drawn in the same teal
## and orange, in the same font, at the same 10 x 20 cell pitch as the terminal.
##
## This node is a view. The rooms, the people, the unread counters and every
## scripted voice live in the Chatroom node and its ChatModel; this file reads
## them, draws them, and turns key presses into either a view change (switch a
## buffer, scroll, open a list) or a line. Every line, a command included, goes
## through the shell's single pass-through (Signals.terminal_line_submitted), so
## nothing here ever reaches the model. There is no help screen, no key legend
## and no exit label: the labels are the ones in client_ui.json, and nothing
## explains itself.

const FONT_PATH := "res://assets/fonts/DejaVuSansMono.ttf"
const UI_FILE := "client_ui.json"
const FONT_SIZE := 16
const BASELINE := 15.0

var _font: Font
var _cr: Chatroom = null
var _ui: Dictionary = {}
var _keymap: Array = []
var _mounted: bool = false

var _input_text: String = ""
var _cursor: int = 0
var _view: String = ""
var _sel: int = 0
var _focus_dm: bool = false
var _seen_active: String = ""
var _tab_prefix: String = ""
var _tab_index: int = 0
var _tab_head: String = ""

var _layout: Dictionary = {}
var _cols: int = 0
var _rows: int = 0
var _segs: Array = []
var _fills: Array = []
var _roster_cache: Array = []
var _topics: Dictionary = {}
var _dirty: bool = true
var _truncated: int = 0
var _overflow: int = 0
var _last_minute: int = -1
var _last_key_ms: int = -1000000
var _blink_origin_ms: int = 0
var _cursor_drawn_on: bool = true
var _cursor_blink_ms: int = 530
var _cursor_solid_ms: int = 600


func _ready() -> void:
	_font = load(FONT_PATH)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	resized.connect(_on_resized)
	if not Signals.chat_model_changed.is_connected(_on_model_changed):
		Signals.chat_model_changed.connect(_on_model_changed)


## --- Mounting -----------------------------------------------------------------------

## Called when the chat module opens (and again on every resume).
func mount(chatroom: Chatroom) -> void:
	_cr = chatroom
	_load_ui()
	_topics = {}
	_mounted = true
	_view = ""
	_seen_active = _model().active
	_input_text = _model().draft_of(_seen_active)
	_cursor = _input_text.length()
	_blink_origin_ms = Time.get_ticks_msec()
	_dirty = true
	queue_redraw()


func unmount() -> void:
	if _mounted and _cr != null:
		_model().set_draft(_model().active, _input_text)
	_mounted = false
	_view = ""
	queue_redraw()


func is_mounted() -> bool:
	return _mounted


func _model() -> ChatModel:
	return _cr.model


func _load_ui() -> void:
	var parsed = ChatroomScript.read_json(ChatroomScript.data_dir() + "/" + UI_FILE)
	_ui = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	_keymap = []
	var keys: Dictionary = _ui.get("keys", {})
	for action in keys:
		var parsed_key := _parse_key(String(keys[action]))
		if not parsed_key.is_empty():
			parsed_key["action"] = String(action)
			_keymap.append(parsed_key)


func _str(key: String) -> String:
	return String(_ui.get("strings", {}).get(key, ""))


## "Ctrl+End" -> {key, ctrl, alt, jump}. A range such as "Alt+1..9" is a jump key.
static func _parse_key(spec: String) -> Dictionary:
	var ctrl := false
	var alt := false
	var name := ""
	for part in spec.split("+", false):
		match String(part):
			"Ctrl":
				ctrl = true
			"Alt":
				alt = true
			_:
				name = String(part)
	var jump := name.contains("..")
	var code := KEY_NONE
	if jump:
		code = KEY_1
	else:
		match name:
			"Enter":
				code = KEY_ENTER
			"Up":
				code = KEY_UP
			"Down":
				code = KEY_DOWN
			"Tab":
				code = KEY_TAB
			"PageUp":
				code = KEY_PAGEUP
			"PageDown":
				code = KEY_PAGEDOWN
			"Esc":
				code = KEY_ESCAPE
			"End":
				code = KEY_END
			_:
				if name.length() >= 2 and name.begins_with("F") and name.substr(1).is_valid_int():
					code = KEY_F1 + name.substr(1).to_int() - 1
				elif name.length() == 1:
					code = name.unicode_at(0)
	if code == KEY_NONE:
		return {}
	return {"key": code, "ctrl": ctrl, "alt": alt, "jump": jump}


## --- Input ------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _mounted or _cr == null:
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	var k: InputEventKey = event
	# The fullscreen toggles belong to the boot controller: never typed, never rebound.
	if k.keycode == KEY_F11 or (k.alt_pressed and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER)):
		return
	var editing := k.keycode in [KEY_BACKSPACE, KEY_DELETE, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END] or (k.unicode >= 32 and not k.ctrl_pressed and not k.alt_pressed)
	if k.echo and not editing:
		return
	_last_key_ms = Time.get_ticks_msec()
	var action := _action_for(k)
	if not action.is_empty():
		_run_action(action)
		_finish_key()
		return
	if editing:
		_edit(k)
		_finish_key()


func _finish_key() -> void:
	get_viewport().set_input_as_handled()
	_dirty = true
	queue_redraw()


func _action_for(k: InputEventKey) -> String:
	for entry in _keymap:
		if bool(entry["ctrl"]) != k.ctrl_pressed or bool(entry["alt"]) != k.alt_pressed:
			continue
		if bool(entry["jump"]):
			if k.keycode >= KEY_1 and k.keycode <= KEY_9:
				return "jump:%d" % (k.keycode - KEY_1 + 1)
		elif int(entry["key"]) == k.keycode or (int(entry["key"]) == KEY_ENTER and k.keycode == KEY_KP_ENTER):
			return String(entry["action"])
	return ""


func _run_action(action: String) -> void:
	if action.begins_with("jump:"):
		_switch_buffer(func(m: ChatModel): m.jump(action.substr(5).to_int()))
		return
	var m := _model()
	match action:
		"send":
			if _view.is_empty():
				_send()
			else:
				_confirm_selection()
		"history_prev":
			if _view.is_empty():
				_input_text = m.history_prev(_input_text)
				_cursor = _input_text.length()
			else:
				_move_selection(-1)
		"history_next":
			if _view.is_empty():
				_input_text = m.history_next()
				_cursor = _input_text.length()
			else:
				_move_selection(1)
		"nick_complete":
			_complete_name()
		"buffer_next":
			_switch_buffer(func(mm: ChatModel): mm.cycle(1))
		"buffer_prev":
			_switch_buffer(func(mm: ChatModel): mm.cycle(-1))
		"scroll_up":
			m.scroll_by(m.active, _page())
		"scroll_down":
			m.scroll_by(m.active, -_page())
		"scroll_live":
			m.scroll_live(m.active)
		"nav_rooms":
			_view = "rooms"
			_focus_dm = false
			_sel = maxi(m.open_order().find(m.active), 0)
		"nav_directory":
			_view = "directory"
			_sel = 0
		"nav_messages":
			var unread := m.newest_unread_dm()
			if not unread.is_empty():
				_view = ""
				_switch_buffer(func(mm: ChatModel): mm.switch_to(unread))
			else:
				_view = "rooms"
				_focus_dm = true
				var order := m.open_order()
				_sel = 0
				for i in range(order.size()):
					if m.is_dm(String(order[i])):
						_sel = i
						break
		"nav_people":
			_view = "people"
			_sel = 0
		"close_view":
			_view = ""
		"close_buffer":
			_submit("/part")
		"quit":
			_submit("leave")


func _page() -> int:
	var main: Rect2i = _layout.get("main", Rect2i(0, 0, 1, 10))
	return maxi(main.size.y - 2, 1)


func _edit(k: InputEventKey) -> void:
	if not _view.is_empty() and k.unicode >= 32:
		_view = ""
	match k.keycode:
		KEY_BACKSPACE:
			if _cursor > 0:
				_input_text = _input_text.substr(0, _cursor - 1) + _input_text.substr(_cursor)
				_cursor -= 1
		KEY_DELETE:
			_input_text = _input_text.substr(0, _cursor) + _input_text.substr(_cursor + 1)
		KEY_LEFT:
			_cursor = maxi(_cursor - 1, 0)
		KEY_RIGHT:
			_cursor = mini(_cursor + 1, _input_text.length())
		KEY_HOME:
			_cursor = 0
		KEY_END:
			_cursor = _input_text.length()
		_:
			if k.unicode >= 32 and _input_text.length() < ChatModel.MAX_INPUT:
				_input_text = _input_text.substr(0, _cursor) + char(k.unicode) + _input_text.substr(_cursor)
				_cursor += 1
				_tab_prefix = ""
	_model().set_draft(_model().active, _input_text)


func _send() -> void:
	var text := _input_text
	_input_text = ""
	_cursor = 0
	_tab_prefix = ""
	_model().set_draft(_model().active, "")
	if text.strip_edges().is_empty():
		return
	_model().history_push(text)
	_submit(text)


## The single way a line leaves the client: the shell's pass-through.
func _submit(text: String) -> void:
	Signals.terminal_line_submitted.emit(text)


func _switch_buffer(change: Callable) -> void:
	var m := _model()
	m.set_draft(m.active, _input_text)
	change.call(m)
	_view = ""
	_sync_active()


## Keeps the input line in step with the active buffer's draft.
func _sync_active() -> void:
	var m := _model()
	if m.active != _seen_active:
		m.set_draft(_seen_active, _input_text)
		_input_text = m.draft_of(m.active)
		_cursor = _input_text.length()
		_seen_active = m.active
		_tab_prefix = ""


func _complete_name() -> void:
	var m := _model()
	var head := _input_text.substr(0, _cursor)
	var at := head.rfind(" ") + 1
	var word := head.substr(at)
	if _tab_prefix.is_empty():
		_tab_prefix = word
		_tab_index = 0
		_tab_head = head.substr(0, at)
	else:
		_tab_index += 1
	var names: Array = m.roster(m.active).filter(func(h): return String(h) != m.self_handle)
	var done := ChatModel.complete_nick(_tab_prefix, names, _tab_index)
	if done.is_empty():
		return
	var suffix := ": " if _tab_head.is_empty() else " "
	_input_text = _tab_head + done + suffix + _input_text.substr(_cursor)
	_cursor = (_tab_head + done + suffix).length()
	_model().set_draft(m.active, _input_text)


func _move_selection(delta: int) -> void:
	var n := _selection_size()
	if n > 0:
		_sel = posmod(_sel + delta, n)


func _selection_size() -> int:
	var m := _model()
	match _view:
		"rooms":
			return m.open_order().size()
		"directory":
			return m.directory().size()
		"people":
			return m.roster(m.active).size()
	return 0


func _confirm_selection() -> void:
	var m := _model()
	var view := _view
	var pick := _sel
	_view = ""
	match view:
		"rooms":
			var order := m.open_order()
			if pick < order.size():
				_switch_buffer(func(mm: ChatModel): mm.switch_to(String(order[pick])))
		"directory":
			var entries := m.directory()
			if pick < entries.size():
				_submit("/join " + String(entries[pick]["id"]))
		"people":
			var who := m.roster(m.active)
			if pick < who.size():
				_submit("/msg " + String(who[pick]))


## --- Redraw triggers ---------------------------------------------------------------------

func _on_resized() -> void:
	_dirty = true
	queue_redraw()


func _on_model_changed() -> void:
	if _cr == null:
		return
	if _mounted:
		_sync_active()
	_dirty = true
	queue_redraw()


func _process(_delta: float) -> void:
	if not _mounted:
		return
	var minute := int(Time.get_time_dict_from_system()["minute"])
	if minute != _last_minute:
		_last_minute = minute
		_dirty = true
		queue_redraw()
	elif _cursor_on() != _cursor_drawn_on:
		queue_redraw()


func _cursor_on() -> bool:
	var now := Time.get_ticks_msec()
	if now - _last_key_ms < _cursor_solid_ms:
		return true
	return ((now - _blink_origin_ms) / _cursor_blink_ms) % 2 == 0


## --- Composition: model -> segments ----------------------------------------------------------

func _put(r: int, c: int, text: String, color: Color, bound: int, name_like: bool = false) -> void:
	if r < 0 or r >= _rows or c >= bound or text.is_empty():
		return
	var room := bound - c
	if text.length() > room:
		if name_like:
			_truncated += 1
		else:
			_overflow += 1
		text = text.substr(0, room)
	_segs.append({"r": r, "c": c, "t": text, "col": color})


func _fill(rect: Rect2i, color: Color) -> void:
	if rect.size.x > 0 and rect.size.y > 0:
		_fills.append({"rect": rect, "col": color})


func _clock() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(t["hour"]), int(t["minute"])]


func _row_color(row: Dictionary) -> Color:
	match String(row.get("kind", "")):
		ChatModel.ROW_VOICE:
			return Palette.TEAL if bool(row.get("clear", false)) else Palette.TEAL_DIM
		ChatModel.ROW_SELF:
			return Palette.TEAL_BRIGHT
		ChatModel.ROW_ACTION:
			return Palette.TEAL
		ChatModel.ROW_SYSTEM:
			return Palette.ORANGE
	return Palette.TEAL_DIM


func _tone_color(tone: String) -> Color:
	return Palette.TEAL


func _topic_for(room_id: String) -> String:
	if not _topics.has(room_id):
		var rules: Dictionary = _cr.room_script().get("scramble", {})
		var topic := String(_model().rooms[room_id]["topic"])
		_topics[room_id] = ChatroomScript.scramble(topic, _cr.session_seed() ^ room_id.hash(), rules)
	return String(_topics[room_id])


func _compose() -> void:
	_segs = []
	_fills = []
	_roster_cache = []
	_truncated = 0
	_overflow = 0
	var m := _model()
	_layout = ChatLayout.compute(int(size.x), int(size.y))
	_cols = int(_layout["cols"])
	_rows = int(_layout["rows"])
	var nav: Rect2i = _layout["nav"]
	var side: Rect2i = _layout["side"]
	var main: Rect2i = _layout["main"]
	var people: Rect2i = _layout["people"]
	var status: Rect2i = _layout["status"]
	var input: Rect2i = _layout["input"]
	var full := String(_layout["tier"]) == ChatLayout.FULL
	var active := m.active

	_fill(nav, Color(Palette.TEAL, 0.10))
	_fill(side, Color(Palette.TEAL, 0.04))
	_fill(main, Color(Palette.TEAL, 0.03))
	_fill(people, Color(Palette.TEAL, 0.04))
	_fill(input, Color(Palette.TEAL, 0.14))

	_compose_nav(m)
	_compose_header(m, main, side, people, full)
	if full:
		_compose_side(m, side)
		_compose_people(m, people)
	match _view:
		"directory":
			_compose_directory(m, main)
		_:
			_compose_buffer(m, main, active)
	# status line
	var title := String(m.buffers[active]["title"])
	_put(status.position.y, 1, title, Palette.TEAL_DIM, _cols - 1, true)
	var back := int(m.buffers[active]["scroll"])
	if back > 0:
		var tail := "%d BACK" % back
		_put(status.position.y, _cols - tail.length() - 1, tail, Palette.ORANGE, _cols)
	_compose_input(input)


func _active_nav_action(m: ChatModel) -> String:
	match _view:
		"rooms":
			return "nav_messages" if _focus_dm else "nav_rooms"
		"directory":
			return "nav_directory"
		"people":
			return "nav_people"
	return "nav_messages" if m.is_dm(m.active) else "nav_rooms"


func _compose_nav(m: ChatModel) -> void:
	var nav: Rect2i = _layout["nav"]
	var r := nav.position.y
	var x := 1
	var brand := String(_ui.get("nav", {}).get("brand", ""))
	_put(r, x, brand, Palette.ORANGE, _cols)
	x += brand.length() + 3
	var lit := _active_nav_action(m)
	for item in _ui.get("nav", {}).get("items", []):
		var label := String(item["label"])
		if String(item["action"]) == "nav_messages" and m.unread_total() > 0:
			label += " (%d)" % m.unread_total()
		var text := "[%s %s]" % [String(item["key"]), label]
		_put(r, x, text, Palette.ORANGE if String(item["action"]) == lit else Palette.TEAL, _cols)
		x += text.length() + 1
	var right := "%s  %s" % [_clock(), m.self_handle]
	_put(r, _cols - right.length() - 1, right, Palette.TEAL_DIM, _cols)


func _compose_header(m: ChatModel, main: Rect2i, side: Rect2i, people: Rect2i, full: bool) -> void:
	var r := 1
	var active := m.active
	if full:
		_put(r, 1, _str("rooms_title"), Palette.TEAL_DIM, side.size.x)
		var heading := "%s (%d)" % [_str("people_title"), m.roster(active).size()]
		_put(r, people.position.x + 1, heading, Palette.TEAL_DIM, people.position.x + people.size.x)
	var right_x := main.position.x + main.size.x
	var present := "%d %s" % [m.roster(active).size(), _str("present_suffix")]
	var left := ""
	if _view == "directory":
		left = _str("directory_title")
	elif m.is_room(active):
		left = "%s  ::  %s" % [String(m.rooms[active]["title"]), _topic_for(active)]
	else:
		left = "%s  ::  %s" % [_str("dm_header"), String(m.buffers[active]["title"])]
	var room := main.size.x - present.length() - 1
	if left.length() > room:
		left = left.substr(0, maxi(room, 0))
	_put(r, main.position.x, left, Palette.ORANGE, right_x)
	_put(r, right_x - present.length(), present, Palette.TEAL_DIM, right_x)


func _compose_side(m: ChatModel, side: Rect2i) -> void:
	var order := m.open_order()
	var y := side.position.y
	var bound := side.position.x + side.size.x
	var dm_title_drawn := false
	var line_of := {}
	for id in order:
		var buf: Dictionary = m.buffers[id]
		if String(buf["kind"]) == ChatModel.KIND_DM and not dm_title_drawn:
			y += 1
			_put(y, 1, _str("direct_title"), Palette.TEAL_DIM, bound)
			y += 1
			dm_title_drawn = true
		line_of[id] = y
		var is_active: bool = String(id) == m.active
		_put(y, 1, ">" if is_active else " ", Palette.ORANGE, bound)
		_put(y, 3, String(buf["title"]), Palette.TEAL_BRIGHT if is_active else Palette.TEAL, bound - 5, true)
		var unread := int(buf["unread"])
		if unread > 0:
			var mark := "*%d" % unread
			_put(y, bound - mark.length() - 1, mark, Palette.ORANGE, bound)
		y += 1
	if _view == "rooms" and _sel < order.size() and line_of.has(order[_sel]):
		_fill(Rect2i(side.position.x, int(line_of[order[_sel]]), side.size.x, 1), Color(Palette.TEAL, 0.22))


func _compose_people(m: ChatModel, people: Rect2i) -> void:
	var entries := ChatModel.roster_entries(m, m.active)
	var bound := people.position.x + people.size.x
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		var y := people.position.y + i
		if y >= people.position.y + people.size.y:
			break
		var color := _tone_color(String(e["tone"]))
		var text := String(e["handle"])
		_put(y, people.position.x + 1, text, color, bound - 2, true)
		var marker := String(e["marker"])
		if not marker.is_empty():
			_put(y, people.position.x + 1 + text.length() + 1, marker, Palette.ORANGE, bound)
		_roster_cache.append({"handle": String(e["handle"]), "marker": marker, "tone": String(e["tone"]), "color": color, "row": y, "text": (text + " " + marker).strip_edges()})
	if _view == "people" and _sel < entries.size():
		_fill(Rect2i(people.position.x, people.position.y + _sel, people.size.x, 1), Color(Palette.TEAL, 0.22))


func _compose_directory(m: ChatModel, main: Rect2i) -> void:
	var entries := m.directory()
	var bound := main.position.x + main.size.x
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		var y := main.position.y + i
		var selected := i == _sel
		var text := "%s %-10s %3d  %s" % [">" if selected else " ", String(e["name"]), int(e["count"]), _topic_for(String(e["id"]))]
		var color := Palette.TEAL_BRIGHT if bool(e["joined"]) else Palette.TEAL_DIM
		_put(y, main.position.x + 1, text, color, bound - 1)
		if selected:
			_fill(Rect2i(main.position.x, y, main.size.x, 1), Color(Palette.TEAL, 0.22))


func _compose_buffer(m: ChatModel, main: Rect2i, active: String) -> void:
	var rows: Array = m.rows_of(active)
	var last := rows.size() - 1 - int(m.buffers[active]["scroll"])
	var picked: Array = []
	var count := 0
	var i := last
	while i >= 0 and count < main.size.y:
		var row: Dictionary = rows[i]
		var lines := ChatModel.format_row(row, main.size.x - 1)
		picked.push_front({"lines": lines, "color": _row_color(row)})
		count += lines.size()
		i -= 1
	var flat: Array = []
	for p in picked:
		for j in range(p["lines"].size()):
			flat.append({"text": String(p["lines"][j]), "color": p["color"], "first": j == 0})
	var start := maxi(flat.size() - main.size.y, 0)
	var bound := main.position.x + main.size.x
	for n in range(start, flat.size()):
		var y := main.position.y + (n - start)
		var line: Dictionary = flat[n]
		var text: String = line["text"]
		if bool(line["first"]) and text.length() >= 8:
			_put(y, main.position.x, text.substr(0, 8), Palette.TEAL_DIM, bound)
			_put(y, main.position.x + 8, text.substr(8), line["color"], bound)
		else:
			_put(y, main.position.x, text, line["color"], bound)


func _compose_input(input: Rect2i) -> void:
	var prefix := "[%s] > " % _clock()
	var avail := maxi(_cols - prefix.length() - 2, 1)
	var start := maxi(_cursor - avail + 1, 0)
	var shown := _input_text.substr(start, avail)
	_put(input.position.y, 1, prefix, Palette.TEAL_DIM, _cols)
	_put(input.position.y, 1 + prefix.length(), shown, Palette.TEAL_BRIGHT, _cols)
	_input_cell = Vector2i(1 + prefix.length() + _cursor - start, input.position.y)


var _input_cell: Vector2i = Vector2i.ZERO


## --- Drawing ----------------------------------------------------------------------------------

func _draw() -> void:
	if not _mounted or _cr == null or _font == null:
		return
	if _dirty or _layout.is_empty() or int(size.x) / ChatLayout.CELL_W != _cols or int(size.y) / ChatLayout.CELL_H != _rows:
		_compose()
		_dirty = false
	draw_rect(Rect2(Vector2.ZERO, size), Palette.BG)
	for f in _fills:
		var rect: Rect2i = f["rect"]
		draw_rect(Rect2(rect.position.x * ChatLayout.CELL_W, rect.position.y * ChatLayout.CELL_H, rect.size.x * ChatLayout.CELL_W, rect.size.y * ChatLayout.CELL_H), f["col"])
	for s in _segs:
		var text: String = s["t"]
		var x := float(int(s["c"]) * ChatLayout.CELL_W)
		var y := float(int(s["r"]) * ChatLayout.CELL_H) + BASELINE
		for i in range(text.length()):
			var ch := text.unicode_at(i)
			if ch != 32:
				_font.draw_char(get_canvas_item(), Vector2(x, y), ch, FONT_SIZE, s["col"])
			x += ChatLayout.CELL_W
	_cursor_drawn_on = _cursor_on()
	if _cursor_drawn_on and _view.is_empty():
		draw_rect(Rect2(_input_cell.x * ChatLayout.CELL_W, _input_cell.y * ChatLayout.CELL_H + 2, ChatLayout.CELL_W, ChatLayout.CELL_H - 6), Palette.TEAL_BRIGHT)


## --- Snapshots for probes -----------------------------------------------------------------------

func _ensure_composed() -> void:
	if _mounted and _cr != null and (_dirty or _layout.is_empty()):
		_compose()
		_dirty = false


## Every cell the client drew, as `rows` strings of `cols` characters.
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


## Every row of every buffer, oldest first: [{buffer, text, color, kind}], where
## text is the row as it reads on screen ("[HH:MM] <HANDLE> body").
func rows_snapshot() -> Array:
	var out: Array = []
	if _cr == null:
		return out
	var m := _model()
	for id in m.buffers:
		for row in m.buffers[id]["rows"]:
			out.append({"buffer": String(id), "text": "[%s] %s" % [String(row["t"]), ChatModel.plain_line(row)], "color": _row_color(row), "kind": String(row["kind"])})
	return out


## The people pane as drawn: [{handle, marker, tone, color, row, text}].
func roster_snapshot() -> Array:
	_ensure_composed()
	return _roster_cache.duplicate(true)


func active_buffer() -> String:
	return _model().active if _cr != null else ""


func unread_total() -> int:
	return _model().unread_total() if _cr != null else 0


## Every drawn segment: [{r, c, t, col}] (probes derive style signatures from it).
func segments_snapshot() -> Array:
	_ensure_composed()
	return _segs.duplicate(true)


func fills_snapshot() -> Array:
	_ensure_composed()
	return _fills.duplicate(true)


func layout_snapshot() -> Dictionary:
	_ensure_composed()
	return _layout.duplicate(true)


## {truncated, overflow}: names cut to fit a pane, and text cut at a pane edge.
func stats_snapshot() -> Dictionary:
	_ensure_composed()
	return {"truncated": _truncated, "overflow": _overflow}


func input_text() -> String:
	return _input_text


func view_name() -> String:
	return _view


func selection_index() -> int:
	return _sel


func input_cell() -> Vector2i:
	_ensure_composed()
	return _input_cell
