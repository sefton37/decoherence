extends CanvasLayer

## The one global pause menu (Spec #578). An autoload, so it exists before any scene and
## survives every scene change: Esc opens it from the boot sequence, the Q-Ent OS prompt, the
## chatroom, the HANDLER screen, the world (homestead included) and any screen built later,
## with no code in that screen. The tree is paused while it is open; this layer and its children
## run in PROCESS_MODE_ALWAYS so only the menu hears the keyboard.
##
## Esc is read in _unhandled_input. A screen that has a sub-pane Esc should close first claims the
## key by handling it (set_input_as_handled) only when it actually closed something; with nothing
## to close it leaves the key alone and the menu opens (docs/pause_menu.md, "Seam for new surfaces").
##
## Items: the world-only one appears only while a node of the group `stalag_world` is mounted. The
## settings row is the display toggle: it only asks (display_toggle_requested); the boot controller
## owns the window and the persisted setting, so F11, Alt+Enter and this row share one path.
##
## Exit: exit_to_desktop() flushes every node of the group `quit_flush` (each defines
## flush_for_exit()), once, in tree order, then quits once. Nothing else in the game may quit.
## The game-owned model server is killed by the language client's own _exit_tree on that quit.
##
## Every word lives in frontdoor/data/pause_menu.json (DRAFT placeholders). No word is spelled here.

const LAYER := 100  ## above the CRT overlay layer (10): the menu is not scanlined
const DATA_PATH := "res://frontdoor/data/pause_menu.json"
const FONT_PATH := "res://assets/fonts/DejaVuSansMono.ttf"
const WORLD_GROUP := "stalag_world"
const FLUSH_GROUP := "quit_flush"
const ITEM_EXIT_SHELL := "exit_shell"
const ID_FIRST_ROW := "resume"
const ID_DISPLAY_ROW := "settings"
const ITEM_EXIT_DESKTOP := "exit_desktop"

const FONT_SIZE := 22
const ROW_H := 40.0
const PANEL_W := 680.0
const PAD := 28.0
const BORDER := 3.0
const BACKDROP := Color(0.0, 0.0, 0.0, 0.62)
const PANEL_FILL := Color(0.03, 0.10, 0.10, 1.0)
const SELECTED_FILL := Color(0.55, 0.32, 0.10, 1.0)
const SELECTED_TEXT := Color(1.0, 0.88, 0.7, 1.0)

signal opened
signal closed(paused_msec: int)
signal display_toggle_requested

## Test seam: when valid it is called with the exit code instead of quitting the tree.
var quit_fn: Callable = Callable()

var _data: Dictionary = {}
var _open: bool = false
var _selected: int = 0
var _opened_ms: int = 0
var _prior_paused: bool = false
var _saved_mouse: int = Input.MOUSE_MODE_VISIBLE
var _quitting: bool = false
var _view: Control = null
var _font: Font = null


## The drawn panel. It owns only drawing and the mouse; the menu node owns the state.
class MenuView extends Control:
	var menu: Node = null

	func _draw() -> void:
		if menu != null and menu.is_open():
			menu.paint(self)

	func _gui_input(event: InputEvent) -> void:
		if menu == null or not menu.is_open():
			return
		if event is InputEventMouseMotion:
			var hit: int = menu.row_at(event.position)
			if hit >= 0 and hit != menu.selected_index():
				menu.set_selection(hit)
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var hit: int = menu.row_at(event.position)
			if hit >= 0:
				menu.set_selection(hit)
				menu.activate()
		accept_event()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER
	visible = false
	_font = load(FONT_PATH)
	_load_data()
	_view = MenuView.new()
	_view.menu = self
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_view)
	set_process(false)


func _load_data() -> void:
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		_data = {}
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	_data = parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## --- State -------------------------------------------------------------------------------

func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	_selected = 0
	_opened_ms = Time.get_ticks_msec()
	_prior_paused = get_tree().paused
	_saved_mouse = Input.mouse_mode
	if _saved_mouse != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true
	get_tree().paused = true
	set_process(true)
	_view.queue_redraw()
	opened.emit()


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	set_process(false)
	get_tree().paused = _prior_paused
	Input.mouse_mode = _saved_mouse as Input.MouseMode
	closed.emit(Time.get_ticks_msec() - _opened_ms)


func toggle() -> void:
	if _open:
		close()
	else:
		open()


## The ids of the rows on show, in data order.
func item_ids() -> Array:
	var ids: Array = []
	var world := not get_tree().get_nodes_in_group(WORLD_GROUP).is_empty()
	for it in _data.get("items", []):
		var id := String(it.get("id", ""))
		if id == ITEM_EXIT_SHELL and not world:
			continue
		ids.append(id)
	return ids


## The text of row `i`: the data label, and for the settings row the current display state.
func item_label(i: int) -> String:
	var ids := item_ids()
	if i < 0 or i >= ids.size():
		return ""
	var id := String(ids[i])
	var label := ""
	for it in _data.get("items", []):
		if String(it.get("id", "")) == id:
			label = String(it.get("label", ""))
	if id == ID_DISPLAY_ROW:
		var key := "settings_display_fullscreen" if _is_fullscreen() else "settings_display_windowed"
		return "%s  [%s]" % [label, String(_data.get(key, ""))]
	return label


func selected_index() -> int:
	return _selected


func selected_id() -> String:
	var ids := item_ids()
	return String(ids[_selected]) if _selected >= 0 and _selected < ids.size() else ""


func set_selection(i: int) -> void:
	_selected = clampi(i, 0, maxi(item_ids().size() - 1, 0))
	_view.queue_redraw()


func move_selection(delta: int) -> void:
	var n := item_ids().size()
	if n == 0:
		return
	_selected = posmod(_selected + delta, n)
	_view.queue_redraw()


func activate() -> void:
	match selected_id():
		ID_FIRST_ROW:
			close()
		ID_DISPLAY_ROW:
			display_toggle_requested.emit()
			_view.queue_redraw()
		ITEM_EXIT_SHELL:
			close()
			for w in get_tree().get_nodes_in_group(WORLD_GROUP):
				if w.has_method("request_exit"):
					w.request_exit()
		ITEM_EXIT_DESKTOP:
			exit_to_desktop()


## The one way out of the game. Flushes the `quit_flush` group once, in tree order, then quits once.
func exit_to_desktop() -> void:
	if _quitting:
		return
	_quitting = true
	for node in get_tree().get_nodes_in_group(FLUSH_GROUP):
		if node.has_method("flush_for_exit"):
			node.flush_for_exit()
	if quit_fn.is_valid():
		quit_fn.call(0)
	else:
		get_tree().quit(0)


func _is_fullscreen() -> bool:
	var mode := get_window().mode
	return mode == Window.MODE_FULLSCREEN or mode == Window.MODE_EXCLUSIVE_FULLSCREEN


## --- Input -------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k: InputEventKey = event
	var is_esc: bool = k.keycode == KEY_ESCAPE
	if not _open:
		if is_esc and not k.echo:
			open()
			get_viewport().set_input_as_handled()
		return
	# Open: the menu takes every key. The display chords still work (the boot controller is paused).
	if k.keycode == KEY_F11 or (k.alt_pressed and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER)):
		if not k.echo:
			display_toggle_requested.emit()
	elif is_esc:
		if not k.echo:
			close()
	elif k.keycode == KEY_UP or k.keycode == KEY_W:
		move_selection(-1)
	elif k.keycode == KEY_DOWN or k.keycode == KEY_S:
		move_selection(1)
	elif (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER or k.keycode == KEY_SPACE) and not k.echo:
		activate()
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_view.queue_redraw()  # the settings row follows the live window mode


## --- Drawing and hit testing (logical pixels of the viewport) ---------------------------------

func _viewport_size() -> Vector2:
	return _view.size if _view != null else Vector2(1920.0, 1080.0)


## The panel: centered, sized by the rows on show.
func panel_rect() -> Rect2:
	var rows := item_ids().size()
	var h := PAD * 2.0 + ROW_H * 2.0 + float(rows) * ROW_H + ROW_H
	var vs := _viewport_size()
	return Rect2(floorf((vs.x - PANEL_W) * 0.5), floorf((vs.y - h) * 0.5), PANEL_W, h)


func row_rect(i: int) -> Rect2:
	var p := panel_rect()
	return Rect2(p.position.x + PAD, p.position.y + PAD + ROW_H * 2.0 + float(i) * ROW_H, PANEL_W - PAD * 2.0, ROW_H)


func row_at(pos: Vector2) -> int:
	for i in range(item_ids().size()):
		if row_rect(i).has_point(pos):
			return i
	return -1


func paint(c: Control) -> void:
	var vs := c.size
	c.draw_rect(Rect2(Vector2.ZERO, vs), BACKDROP)
	var p := panel_rect()
	c.draw_rect(p, Palette.TEAL)
	c.draw_rect(p.grow(-BORDER), PANEL_FILL)
	var base_y := FONT_SIZE + (ROW_H - FONT_SIZE) * 0.5 - 2.0
	c.draw_string(_font, Vector2(p.position.x + PAD, p.position.y + PAD + base_y), String(_data.get("title", "")), HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, Palette.ORANGE)
	var sep_y := p.position.y + PAD + ROW_H + ROW_H * 0.5
	c.draw_rect(Rect2(p.position.x + PAD, sep_y, PANEL_W - PAD * 2.0, 2.0), Palette.TEAL_DIM)
	for i in range(item_ids().size()):
		var r := row_rect(i)
		var on := i == _selected
		if on:
			c.draw_rect(r, SELECTED_FILL)
		var text := ("> " if on else "  ") + item_label(i)
		c.draw_string(_font, Vector2(r.position.x + 12.0, r.position.y + base_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, SELECTED_TEXT if on else Palette.TEAL_BRIGHT)
	var hint_y := p.position.y + p.size.y - PAD - ROW_H * 0.5 + base_y
	c.draw_string(_font, Vector2(p.position.x + PAD, hint_y), String(_data.get("hint", "")), HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 6, Palette.TEAL_DIM)
