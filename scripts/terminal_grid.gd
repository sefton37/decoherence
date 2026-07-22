extends Control
class_name TerminalGrid

## Monospace glyph-grid terminal renderer (Spec #370 / plan-370, Risk 3).
## Draws every glyph at a FIXED cell pitch it controls directly -- never
## trusting the vendored font's own advance metric -- so the terminal reads
## as a true monospace grid regardless of font hinting. Instanced exactly
## once in scenes/boot.tscn and shared by BOTH the boot-theater driver
## (boot_controller.gd) and the Handler chat (handler_chat.gd): one
## renderer, many writers. Deliberately NOT a RichTextLabel -- BBCode-driven
## layout fights fixed-cell positioning, per-cell corruption swaps, and
## precise ASCII-art column alignment.

## Emitted when the player presses Enter while the input line is active.
## boot_controller.gd wires this to Signals.submit_player_line only once
## the chat-handoff stage begins -- before that, the input line is inactive
## and Enter does nothing.
signal line_submitted(text: String)

const FONT_PATH := "res://assets/fonts/DejaVuSansMono.ttf"

@export var cell_width: float = 10.0
@export var cell_height: float = 20.0
@export var font_size: int = 16
@export var max_cols: int = 100
@export var max_visible_rows: int = 34

var _font: Font
var _rows: Array = [] # Array[{"text": String, "color": Color}]
var _scrollback_limit: int = 500

var _stream_active: bool = false
var _stream_row_index: int = -1

var _input_active: bool = false
var _input_buffer: String = ""

## Curated Unicode pools for the deliberate "alien glyph" grammar -- Box
## Drawing (U+2500-257F), Block Elements (U+2580-259F), Braille Patterns
## (U+2800-28FF). DejaVu Sans Mono has broad coverage of all three blocks.
const _ALIEN_BOX := ["─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "═", "║", "╔", "╗", "╚", "╝", "╬"]
const _ALIEN_BLOCK := ["▀", "▄", "█", "▌", "▐", "░", "▒", "▓", "■"]
const _ALIEN_BRAILLE := ["⠁", "⠃", "⠉", "⠙", "⠑", "⠋", "⠛", "⠓", "⠊", "⠟", "⠽", "⠺", "⠮", "⠵", "⠫", "⠿"]


func _ready() -> void:
	_font = load(FONT_PATH)
	focus_mode = Control.FOCUS_ALL


func _draw() -> void:
	var visible: Array = _rows
	if _rows.size() > max_visible_rows:
		visible = _rows.slice(_rows.size() - max_visible_rows, _rows.size())
	for r in range(visible.size()):
		var row: Dictionary = visible[r]
		var y: float = (r + 1) * cell_height
		_draw_text_fixed_pitch(row["text"], Vector2(4, y), row["color"])
	if _input_active:
		var prompt := "> " + _input_buffer
		var y2: float = (visible.size() + 1) * cell_height
		_draw_text_fixed_pitch(prompt, Vector2(4, y2), Palette.TEAL)


func _draw_text_fixed_pitch(text: String, pos: Vector2, color: Color) -> void:
	if _font == null:
		return
	var x: float = pos.x
	for i in range(text.length()):
		var ch: int = text.unicode_at(i)
		_font.draw_char(get_canvas_item(), Vector2(x, pos.y), ch, font_size, color)
		x += cell_width


func _wrap(text: String, cols: int) -> Array:
	if cols <= 0 or text.length() <= cols:
		return [text]
	var result: Array = []
	var remaining := text
	while remaining.length() > cols:
		result.append(remaining.substr(0, cols))
		remaining = remaining.substr(cols)
	result.append(remaining)
	return result


func _trim_scrollback() -> void:
	while _rows.size() > _scrollback_limit:
		_rows.pop_front()


## Appends one logical line (word-wrapped to max_cols) in a single color.
func write_line(text: String, color = null) -> void:
	var col: Color = Palette.TEAL if color == null else color
	for wrapped in _wrap(text, max_cols):
		_rows.append({"text": wrapped, "color": col})
	_trim_scrollback()
	queue_redraw()


## Appends a multi-line ASCII-art block, one row per source line, preserving
## exact spacing (no word-wrap applied to art).
func write_ascii_art(art: String, color = null) -> void:
	var col: Color = Palette.TEAL if color == null else color
	for raw_line in art.split("\n"):
		_rows.append({"text": raw_line, "color": col})
	_trim_scrollback()
	queue_redraw()


## Overwrites the most recently written row in place -- used for the
## boot-gate spinner ("STANDBY -- CORTEX WARMING ...") so a slow model load
## reads as longer visible theater rather than a silent stall.
func update_last_line(text: String) -> void:
	if _rows.is_empty():
		_rows.append({"text": text, "color": Palette.ORANGE})
	else:
		_rows[_rows.size() - 1]["text"] = text
	queue_redraw()


## Begins a new in-progress row that append_stream_delta() will grow --
## used for the Handler's streamed chat replies.
func begin_stream_line(color = null) -> void:
	var col: Color = Palette.TEAL if color == null else color
	_rows.append({"text": "", "color": col})
	_stream_row_index = _rows.size() - 1
	_stream_active = true
	queue_redraw()


## Appends one streamed delta (never .thinking -- callers must only ever
## pass already-filtered message.content text) to the in-progress row.
func append_stream_delta(delta: String) -> void:
	if not _stream_active:
		begin_stream_line()
	var current: String = _rows[_stream_row_index]["text"]
	_rows[_stream_row_index]["text"] = current + delta
	_trim_scrollback()
	queue_redraw()


func end_stream_line() -> void:
	_stream_active = false
	queue_redraw()


## Activates/deactivates the input line. Only true once boot_controller.gd
## begins the chat-handoff stage -- while false, _input() below ignores all
## key events, matching "no input during boot theater".
func set_input_line_active(active: bool) -> void:
	_input_active = active
	_input_buffer = ""
	queue_redraw()


func _input(event: InputEvent) -> void:
	if not _input_active:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		var text := _input_buffer
		_input_buffer = ""
		queue_redraw()
		line_submitted.emit(text)
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_BACKSPACE:
		if _input_buffer.length() > 0:
			_input_buffer = _input_buffer.substr(0, _input_buffer.length() - 1)
		queue_redraw()
		get_viewport().set_input_as_handled()
	elif event.unicode > 0:
		_input_buffer += char(event.unicode)
		queue_redraw()
		get_viewport().set_input_as_handled()


## Deterministically composes a short 1-3 character "alien glyph" cluster
## from the curated Unicode pools above, seeded by `seed_value` so a
## recurring alien word looks stable within a session rather than
## re-randomized on every call (Risk 2). Pure composer -- does not write to
## the terminal itself; callers (boot_controller.gd) decide whether/where to
## display the returned string.
func draw_alien_glyph(seed_value: int, color = null) -> String:
	var _unused_color: Color = Palette.ORANGE if color == null else color
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var pools := [_ALIEN_BOX, _ALIEN_BLOCK, _ALIEN_BRAILLE]
	var length: int = 1 + rng.randi_range(0, 2)
	var glyph := ""
	for i in range(length):
		var pool: Array = pools[rng.randi_range(0, pools.size() - 1)]
		glyph += pool[rng.randi_range(0, pool.size() - 1)]
	return glyph


## Briefly swaps the most recent rendered row's leading characters for an
## alien-glyph corruption, then restores the original text after
## `duration_sec` -- the visual "the tech isn't fully sound" beat. Always
## triggered 1:1 alongside a CRT flicker Tween by boot_controller.gd at the
## same scripted narrative beat -- never on its own, never per-frame.
func corrupt_glyph_flash(duration_sec: float = 0.3) -> void:
	if _rows.is_empty():
		return
	var idx: int = _rows.size() - 1
	var original: String = _rows[idx]["text"]
	if original.is_empty():
		return
	var corrupted := draw_alien_glyph(Time.get_ticks_msec())
	var swap_len: int = mini(corrupted.length(), original.length())
	_rows[idx]["text"] = corrupted + original.substr(swap_len)
	queue_redraw()
	await get_tree().create_timer(duration_sec).timeout
	if idx < _rows.size():
		_rows[idx]["text"] = original
		queue_redraw()
