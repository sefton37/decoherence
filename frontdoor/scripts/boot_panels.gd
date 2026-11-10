extends Control
class_name BootPanels

## Wire-room chrome for the Q-Ent boot and shell (Spec #519): framed glyph
## panes drawn on the SAME fixed 10x20 cell pitch and font as TerminalGrid,
## in the existing palette only. The widget set and the four gallery presets
## (field_bar, ticker, wire_room, full_bus) are data in boot_panels.json;
## geometry comes from PanelLayout (a pure function of the viewport size).
##
## Honesty rules (spec 4a): every widget is declared live or synthetic in
## the data file. Lamps flip ONLY on real stage events pushed in by
## boot_controller.gd, the CORTEX lamp is bound to the real model_ready gate
## (FAIL on failure, never UP before the gate resolves), and the rollup text
## is computed from lamp states. Synthetic widgets are driven by a frame
## counter and pure position formulas -- no wall clock, no random source.
##
## Smooth scrolling (issue #865): the ticker, the hex stream and the sparkline
## traces are conveyors. Their cells are still composed on the 12 Hz grid tick
## (so density, motion and the gallery stay what they were), but what you SEE
## is a LiveStrip child Control per conveyor, redrawn every frame at a pixel
## offset that advances by real frame delta (px/s speeds are data in
## boot_panels.json "smooth_scroll"). Each strip clips to its slot. Gallery
## frames (set_frame) derive the offsets from the frame number, so they stay
## deterministic. Neither text_speed nor the CRT flicker is read here.

const DATA_PATH := "res://frontdoor/data/boot_panels.json"
const CW := PanelLayout.CELL_W
const CH := PanelLayout.CELL_H
const FONT_SIZE := 16

const _SPARK := ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
const _NOISE := ["░", "▒", "▓", "▚", "▞", "◆", "◇", "※", "┼", "╬", "⠿", "⠛"]
const _DIGITS := {
	"0": ["███", "█ █", "█ █", "█ █", "███"],
	"1": [" █ ", "██ ", " █ ", " █ ", "███"],
	"2": ["███", "  █", "███", "█  ", "███"],
	"3": ["███", "  █", "███", "  █", "███"],
	"4": ["█ █", "█ █", "███", "  █", "  █"],
	"5": ["███", "█  ", "███", "  █", "███"],
	"6": ["███", "█  ", "███", "█ █", "███"],
	"7": ["███", "  █", "  █", "  █", "  █"],
	"8": ["███", "█ █", "███", "█ █", "███"],
	"9": ["███", "█ █", "███", "  █", "███"],
}

var _font: Font
var _data: Dictionary = {}
var _preset_id: String = ""
var _widgets: Array = []
var _widget_slots: Dictionary = {}
var _layout: Dictionary = {}
var _viewport: Vector2i = Vector2i.ZERO
var _frame: int = 0
var _accum: float = 0.0
var _tick_hz: float = 12.0
var _synthetic: bool = false
var _shell_mode: bool = false
var _auto_advance: bool = true
var _module_count: int = 0
var _gate_resolved: bool = false
var _gate_success: bool = false
var _cortex_up_before_gate: int = 0
var _lamps: Dictionary = {}
var _cells: Dictionary = {}
var _clip: Rect2i = Rect2i()
var _seen: Dictionary = {}
var _active_sum: int = 0
var _active_samples: int = 0
# Smooth-scroll state (issue #865): unwrapped pixel offsets, advanced by frame
# delta in _process, derived from the frame number in set_frame (gallery).
var _scroll: Dictionary = {"ticker_boot": 120.0, "ticker_shell": 40.0, "hex": 120.0, "spark": 60.0}
var _ticker_px: float = 0.0
var _hex_px: float = 0.0
var _spark_px: float = 0.0
var _geom: Dictionary = {}  # strip kind -> [c0, r0, cols, rows] for the composed widget
var _strips: Dictionary = {}  # strip kind -> LiveStrip
var _flag_strip: bool = false  # while true, _put marks cells as strip-drawn
var _hex_lines: Dictionary = {}  # line index * 8 + group -> PackedInt32Array of 16 bytes


## Per-frame child that draws one conveyor over its slot, clipped to it.
class LiveStrip extends Control:
	var panels: BootPanels
	var kind: String

	func _init(p: BootPanels, k: String) -> void:
		panels = p
		kind = k
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false

	func _draw() -> void:
		panels.draw_strip(self, kind)


func _ready() -> void:
	_font = load(TerminalGrid.FONT_PATH)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for kind in ["ticker", "hex", "spark"]:
		var strip := LiveStrip.new(self, kind)
		_strips[kind] = strip
		add_child(strip)


## Loads the data file and selects a preset. `preset_id` "off" shows nothing
## (today's boot, used as the density and timing baseline). Synthetic mode
## never reads live facts (gallery byte-identity).
func setup(preset_id: String, viewport: Vector2i, synthetic: bool = false) -> void:
	var parsed = IntentRouter.load_json(DATA_PATH)
	_data = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	_synthetic = synthetic
	_tick_hz = float(_data.get("tick_hz", 12))
	# Spec #541 D2: one dial dims all chrome (this node and its conveyor strips)
	# without touching the terminal.
	modulate = Color(1, 1, 1, clampf(float(_data.get("chrome_alpha", 1.0)), 0.0, 1.0))
	var sc = _data.get("smooth_scroll", {})
	if typeof(sc) == TYPE_DICTIONARY:
		for k in _scroll:
			_scroll[k] = float(sc.get(k + "_px_per_sec", _scroll[k]))
	_preset_id = preset_id
	_widgets = []
	_widget_slots = {}
	var wanted: Array = []
	for p in _data.get("presets", []):
		if String(p.get("id", "")) == preset_id:
			wanted = p.get("widgets", [])
	for w in _data.get("widgets", []):
		if String(w.get("id", "")) in wanted:
			_widgets.append(w)
			_widget_slots[String(w["id"])] = String(w.get("slot", ""))
	for l in _data.get("lamps", []):
		_lamps[String(l["id"])] = "PEND"
	visible = not _widgets.is_empty()
	set_viewport(viewport)


func default_preset() -> String:
	return String(_data.get("selected", "wire_room"))


static func selected_preset_from_data() -> String:
	var parsed = IntentRouter.load_json(DATA_PATH)
	if typeof(parsed) == TYPE_DICTIONARY:
		return String(parsed.get("selected", "wire_room"))
	return "wire_room"


func preset_name(preset_id: String) -> String:
	for p in _data.get("presets", []):
		if String(p.get("id", "")) == preset_id:
			return String(p.get("name", preset_id)).to_upper()
	return preset_id.to_upper()


func set_viewport(size: Vector2i) -> void:
	_viewport = size
	_layout = PanelLayout.compute(size)
	_compose()
	Signals.layout_reported.emit(layout_report())
	queue_redraw()


func set_auto_advance(on: bool) -> void:
	_auto_advance = on


func set_module_count(n: int) -> void:
	_module_count = n


## A real boot stage began (INIT) or finished (UP). The gate stage reports
## its outcome through mark_gate() instead.
func set_stage_state(stage_id: String, state: String) -> void:
	for l in _data.get("lamps", []):
		if String(l.get("stage", "")) != stage_id:
			continue
		if bool(l.get("gate", false)) and state == "UP":
			return  # the gate lamp only ever goes UP via mark_gate(true)
		_lamps[String(l["id"])] = state


func mark_gate(success: bool) -> void:
	_gate_resolved = true
	_gate_success = success
	for l in _data.get("lamps", []):
		if bool(l.get("gate", false)):
			_lamps[String(l["id"])] = "UP" if success else "FAIL"


## Test/gallery hook: force a lamp state without a stage event.
func force_lamp(lamp_id: String, state: String) -> void:
	if lamp_id == "cortex" and state == "UP" and not _gate_resolved:
		_cortex_up_before_gate += 1
	_lamps[lamp_id] = state


## Retire the boot panes at handoff; the title bar, status bar and ticker
## persist into the shell (decision D3).
func enter_shell_mode() -> void:
	_shell_mode = true
	_compose()
	queue_redraw()
	_redraw_strips()


## Gallery: the scripted lamp events for frame `f`, a pure function of f.
## Lamp i goes INIT at 6+14i and UP 10 frames later; the gate lamp resolves
## through mark_gate() like the real boot does.
func apply_gallery_script(f: int) -> void:
	var lamps: Array = _data.get("lamps", [])
	for i in range(lamps.size()):
		var l: Dictionary = lamps[i]
		var stage := String(l.get("stage", ""))
		if f == 6 + 14 * i:
			set_stage_state(stage, "INIT")
		elif f == 16 + 14 * i:
			if bool(l.get("gate", false)):
				mark_gate(true)
			else:
				set_stage_state(stage, "UP")


func set_frame(n: int) -> void:
	_frame = n
	# Gallery: the offsets are a pure function of the frame number (boot speeds),
	# equal to the old one-cell-per-tick positions at whole frames.
	var secs := float(n) / _tick_hz
	_ticker_px = secs * float(_scroll["ticker_boot"])
	_hex_px = secs * float(_scroll["hex"])
	_spark_px = secs * float(_scroll["spark"])
	_compose()
	queue_redraw()
	_redraw_strips()


func _process(delta: float) -> void:
	if not visible or not _auto_advance:
		return
	_advance_scroll(delta)
	_accum += delta
	var period := 1.0 / _tick_hz
	while _accum >= period:
		_accum -= period
		_frame += 1
		_compose()
		if not _shell_mode:
			_sample()
		queue_redraw()
	_redraw_strips()


## Real elapsed time -> pixel offsets. Every frame, independent of the 12 Hz
## grid tick and of the text_speed setting.
func _advance_scroll(delta: float) -> void:
	var key := "ticker_shell" if _shell_mode else "ticker_boot"
	_ticker_px += delta * float(_scroll[key])
	_hex_px += delta * float(_scroll["hex"])
	_spark_px += delta * float(_scroll["spark"])


## Only the conveyor strips redraw per frame; the grid stays at the tick rate.
func _redraw_strips() -> void:
	for kind in _strips:
		(_strips[kind] as Control).queue_redraw()


## Test hook: the unwrapped ticker pixel offset (monotone while advancing).
func ticker_offset_px() -> float:
	return _ticker_px


func hex_offset_px() -> float:
	return _hex_px


func spark_offset_px() -> float:
	return _spark_px


## Records one measurement frame (density + motion) for the boot period.
func _sample() -> void:
	# One pass; the same formulas as active_cells() and signature() below.
	var n := 0
	var h := 7
	for k in _cells:
		var cell: Vector2i = k
		var o: int = (_cells[k][0] as String).unicode_at(0)
		if o != 32:
			n += 1
		h = (h + (cell.x * 7919 + cell.y * 104729 + 1) * (o + 977)) % 1000000007
	_active_sum += n
	_active_samples += 1
	_seen[h] = true


## Gallery/probe: record the current composed frame as a sample.
func sample_now() -> void:
	_sample()


func active_cells() -> int:
	var n := 0
	for k in _cells:
		if String(_cells[k][0]) != " ":
			n += 1
	return n


func signature() -> int:
	# Order-independent (a sum of per-cell terms), so no per-sample key sort.
	var h := 7
	for k in _cells:
		var c: Array = _cells[k]
		var cell: Vector2i = k
		# Position and glyph are multiplied, so moving a glyph changes the sum.
		h = (h + (cell.x * 7919 + cell.y * 104729 + 1) * (String(c[0]).unicode_at(0) + 977)) % 1000000007
	return h


func mean_active_cells() -> float:
	return float(_active_sum) / maxf(1.0, float(_active_samples))


func unique_frames() -> int:
	return _seen.size()


func panel_count() -> int:
	return _visible_panels().size()


func lamp_state(lamp_id: String) -> String:
	return String(_lamps.get(lamp_id, "PEND"))


func up_count() -> int:
	var n := 0
	for k in _lamps:
		if _lamps[k] == "UP":
			n += 1
	return n


func cortex_up_before_gate() -> int:
	return _cortex_up_before_gate


## One-line rollup derived purely from lamp states.
func rollup_text() -> String:
	var total: int = _lamps.size()
	var fails := 0
	var ups := up_count()
	for k in _lamps:
		if _lamps[k] == "FAIL":
			fails += 1
	if fails > 0:
		return "DEGRADED -- %d/%d UP, %d FAILED" % [ups, total, fails]
	if ups == total and total > 0:
		return "ALL %d SUBSYSTEMS UP" % total
	return "BRINGING UP %d/%d" % [ups, total]


func layout_report() -> Dictionary:
	var panels: Array = _visible_panels()
	var rects: Array = []
	for p in panels:
		var r: Rect2i = p["rect"]
		rects.append([r.position.x, r.position.y, r.size.x, r.size.y])
	var t: Rect2i = _layout["term"]
	return {
		"viewport": [_viewport.x, _viewport.y],
		"tier": _layout["tier"],
		"term": [t.position.x, t.position.y, t.size.x, t.size.y],
		"panels": rects,
		"panel_count": rects.size(),
		"overlaps": PanelLayout.overlap_count(t, panels),
		"in_bounds": PanelLayout.all_in_bounds(_viewport, panels),
	}


func _visible_panels() -> Array:
	var slots: Dictionary = {}
	for w in _widgets:
		if _shell_mode and not _persists(w):
			continue
		slots[String(w["id"])] = _widget_slots[String(w["id"])]
	return PanelLayout.panels_for(_layout, slots)


func _persists(w: Dictionary) -> bool:
	return String(w.get("motif", "")) in ["titlebar_dots", "status_bar", "ticker"]


## --- Drawing --------------------------------------------------------------

func _draw() -> void:
	if _font == null:
		return
	var ci := get_canvas_item()
	# Pass 1: backgrounds, merging horizontal runs of one colour into a single
	# rect (cells never overlap, so drawing all backgrounds first is identical
	# to drawing them cell by cell under their own glyph).
	var run_w := 0.0
	var run_x := 0.0
	var run_y := 0.0
	var run_col: Variant = null
	for k in _cells:
		var c: Array = _cells[k]
		if c[2] == null:
			continue
		var cell: Vector2i = k
		var x: float = cell.x * CW
		var y: float = cell.y * CH
		if run_w > 0.0 and y == run_y and x == run_x + run_w and c[2] == run_col:
			run_w += CW
			continue
		if run_w > 0.0:
			draw_rect(Rect2(run_x, run_y, run_w, CH), run_col)
		run_x = x
		run_y = y
		run_w = CW
		run_col = c[2]
	if run_w > 0.0:
		draw_rect(Rect2(run_x, run_y, run_w, CH), run_col)
	# Pass 2: glyphs. Baseline 4 px above the row's bottom edge so the
	# bottom-most row's descenders stay inside the viewport.
	for k in _cells:
		var c: Array = _cells[k]
		var o: int = (c[0] as String).unicode_at(0)
		if o == 32 or c.size() > 3:
			continue  # blank, or drawn per frame by a LiveStrip
		var cell: Vector2i = k
		_font.draw_char(ci, Vector2(cell.x * CW, cell.y * CH + CH - 4), o, FONT_SIZE, c[1])


## --- Per-frame conveyor strips (called by LiveStrip._draw) ----------------

## Draws strip `kind` into `ctl` (local coordinates, origin = the strip's slot
## corner). Whole pixels only, so glyphs stay crisp; the Control clips to its
## slot, so the partially scrolled glyph at either edge is cut, never spilled.
func draw_strip(ctl: Control, kind: String) -> void:
	if _font == null or not _geom.has(kind):
		return
	var ci := ctl.get_canvas_item()
	var g: Array = _geom[kind]
	var base_y := CH - 4  # same baseline as the grid
	match kind:
		"ticker":
			var strip := _ticker_strip()
			if strip.is_empty():
				return
			var px := fposmod(_ticker_px, float(strip.length() * CW))
			var cell0: int = floori(px / float(CW))
			var shift: int = floori(px - float(cell0 * CW))
			for i in range(int(g[2]) - 5 + 1):
				var ch := _ticker_char(strip, cell0 + i)
				if ch == " ":
					continue
				var col: Color = Palette.ORANGE if ch == ":" else Palette.TEAL
				_font.draw_char(ci, Vector2(i * CW - shift, base_y), ch.unicode_at(0), FONT_SIZE, col)
		"hex":
			var k0: int = _hex_base()
			var shift: int = floori(_hex_px - float(k0 * CH))
			var rows: int = g[3]
			for g_i in range(_hex_groups(int(g[2]))):
				for r in range(rows + 1):
					var y: float = r * CH - shift + base_y
					var k: int = k0 + r
					var x0: int = g_i * 48 * CW
					var label := "%04d " % ((k + g_i * 997) % 10000)
					for c in range(label.length()):
						if label[c] != " ":
							_font.draw_char(ci, Vector2(x0 + c * CW, y), label.unicode_at(c), FONT_SIZE, Palette.ORANGE)
					var bytes := _hex_bytes(k, g_i)
					for j in range(16):
						var b: int = bytes[j]
						var hx := "%02X" % b
						var col: Color = Palette.TEAL if b % 3 == 0 else Palette.TEAL_DIM
						var bx: int = x0 + (5 + j * 2 + j / 4) * CW
						_font.draw_char(ci, Vector2(bx, y), hx.unicode_at(0), FONT_SIZE, col)
						_font.draw_char(ci, Vector2(bx + CW, y), hx.unicode_at(1), FONT_SIZE, col)
		"spark":
			var n0: int = floori(_spark_px / float(CW))
			var shift: int = floori(_spark_px - float(n0 * CW))
			for i in range(3):
				var col: Color = Palette.TEAL_DIM if i != 1 else Palette.ORANGE_DIM
				for j in range(-1, _spark_width(int(g[2]))):
					var glyph := _spark_glyph(n0 - j, i)
					_font.draw_char(ci, Vector2(j * CW + shift, i * CH + base_y), glyph.unicode_at(0), FONT_SIZE, col)


func _put(col: int, row: int, text: String, fg: Color, bg = null) -> void:
	if row < _clip.position.y or row >= _clip.position.y + _clip.size.y:
		return
	var lo := maxi(0, _clip.position.x - col)
	var hi := mini(text.length(), _clip.position.x + _clip.size.x - col)
	for i in range(lo, hi):
		if _flag_strip:
			_cells[Vector2i(col + i, row)] = [text[i], fg, bg, true]
		else:
			_cells[Vector2i(col + i, row)] = [text[i], fg, bg]


func _fill_bg(col: int, row: int, count: int, bg: Color) -> void:
	for i in range(count):
		var cx := col + i
		if cx < _clip.position.x or cx >= _clip.position.x + _clip.size.x:
			continue
		_cells[Vector2i(cx, row)] = [" ", bg, bg]


# Provenance: an original combination of public mathematical constants, no code copied:
# 73856093 / 19349663 / 83492791 are the spatial-hash primes from Teschner et al. 2003 ("Optimized
# Spatial Hashing for Collision Detection of Deformable Objects"); 48271 is the Park-Miller (1993)
# MINSTD multiplier. Visual noise only; not used for world generation.
func _hash2(a: int, b: int) -> int:
	var x: int = (a * 73856093 + b * 19349663 + 83492791) % 2147483629
	x = (x ^ (x >> 11)) % 2147483629
	return (x * 48271) % 2147483629


func _wave(frame: int, phase: int, period: int) -> float:
	var ang: float = float(frame + phase * 7) * TAU / float(period)
	return 0.5 + 0.5 * sin(ang)


func _box(c0: int, r0: int, cols: int, rows: int, title: String, rt: String) -> void:
	if cols < 6 or rows < 2:
		return
	var head := "┌─[ " + title + " ]"
	var tail := "─┐"
	var right := ""
	if rt != "":
		right = " " + rt + " "
	var fill := cols - head.length() - tail.length() - right.length()
	if fill < 0:
		right = ""
		fill = maxi(0, cols - head.length() - tail.length())
	_put(c0, r0, "┌─[ ", Palette.TEAL_DIM)
	_put(c0 + 4, r0, title, Palette.ORANGE)
	_put(c0 + 4 + title.length(), r0, " ]" + "─".repeat(fill), Palette.TEAL_DIM)
	if right != "":
		_put(c0 + head.length() + fill, r0, right, Palette.ORANGE)
	_put(c0 + cols - 2, r0, tail, Palette.TEAL_DIM)
	for r in range(1, rows - 1):
		_put(c0, r0 + r, "│", Palette.TEAL_DIM)
		_put(c0 + cols - 1, r0 + r, "│", Palette.TEAL_DIM)
	_put(c0, r0 + rows - 1, "└" + "─".repeat(cols - 2) + "┘", Palette.TEAL_DIM)


func _meter(value: float, segs: int) -> String:
	var on: int = clampi(int(round(value * segs)), 0, segs)
	return "▮".repeat(on) + "▯".repeat(segs - on)


## Widgets whose output is a pure function of (frame / divisor, rect): their
## cells are computed once per divisor step and replayed in between, so the
## costly per-cell hashing runs at 2-8 Hz instead of every 12 Hz tick.
const _STEP_DIVISORS := {"hex_stream": 2, "glyph_noise": 6, "framed_pane": 8}

var _widget_cache: Dictionary = {}


func _compose() -> void:
	_cells.clear()
	_geom.clear()
	for w in _widgets:
		if _shell_mode and not _persists(w):
			continue
		var slot_name: String = _widget_slots[String(w["id"])]
		if not _layout.get("slots", {}).has(slot_name):
			continue
		var px: Rect2i = _layout["slots"][slot_name]
		var c0: int = px.position.x / CW
		var r0: int = px.position.y / CH
		var cols: int = px.size.x / CW
		var rows: int = px.size.y / CH
		_clip = Rect2i(c0, r0, cols, rows)
		var motif := String(w.get("motif", ""))
		match motif:
			"ticker":
				_geom["ticker"] = [c0, r0, cols, rows]
			"hex_stream":
				_geom["hex"] = [c0, r0, cols, rows]
			"sparkline":
				_geom["spark"] = [c0, r0, cols, rows]
		if not _STEP_DIVISORS.has(motif):
			_draw_widget(w, c0, r0, cols, rows)
			continue
		var wid := String(w["id"])
		var step: int = _frame / int(_STEP_DIVISORS[motif])
		if motif == "hex_stream":
			step = _hex_base()  # the cached cells follow the real scroll offset
		var hit = _widget_cache.get(wid, null)
		if hit != null and hit["step"] == step and hit["rect"] == px:
			_cells.merge(hit["cells"])
			continue
		var master := _cells
		_cells = {}
		_draw_widget(w, c0, r0, cols, rows)
		_widget_cache[wid] = {"step": step, "rect": px, "cells": _cells}
		master.merge(_cells)
		_cells = master
	_place_strips()


## Position each LiveStrip over its slot; hidden when its widget is not composed.
func _place_strips() -> void:
	for kind in _strips:
		var strip: Control = _strips[kind]
		if not _geom.has(kind) or (kind == "ticker" and _ticker_strip().is_empty()):
			strip.visible = false
			continue
		var g: Array = _geom[kind]
		var c0: int = g[0]
		var r0: int = g[1]
		var cols: int = g[2]
		var rows: int = g[3]
		match kind:
			"ticker":  # after the "BUS>" label
				strip.position = Vector2((c0 + 5) * CW, r0 * CH)
				strip.size = Vector2(maxi(0, cols - 5) * CW, CH)
			"hex":
				strip.position = Vector2(c0 * CW, r0 * CH)
				strip.size = Vector2(cols * CW, rows * CH)
			"spark":
				strip.position = Vector2((c0 + 14) * CW, (r0 + 1) * CH)
				strip.size = Vector2(_spark_width(cols) * CW, 3 * CH)
		strip.visible = true
		strip.queue_redraw()


func _draw_widget(w: Dictionary, c0: int, r0: int, cols: int, rows: int) -> void:
	match String(w.get("motif", "")):
		"titlebar_dots":
			_w_titlebar(c0, r0, cols)
		"status_bar":
			_w_status(c0, r0, cols)
		"lamp_list":
			_w_lamps(String(w.get("label", "")), c0, r0, cols, rows)
		"ticker":
			_w_ticker(c0, r0, cols)
		"segmented_meter":
			if String(w["id"]) == "mem_meter":
				_w_memory(String(w.get("label", "")), c0, r0, cols, rows)
			else:
				_w_meters(String(w.get("label", "")), c0, r0, cols, rows)
		"sparkline":
			_w_sparklines(String(w.get("label", "")), c0, r0, cols, rows)
		"section_rule":
			_w_rules(c0, r0, cols, rows)
		"led_numerals":
			_w_led(String(w.get("label", "")), c0, r0, cols, rows)
		"rollup_banner":
			_w_rollup(String(w.get("label", "")), c0, r0, cols, rows)
		"hex_stream":
			_w_hex(c0, r0, cols, rows)
		"framed_pane":
			_w_daemon(String(w.get("label", "")), c0, r0, cols, rows)
		"glyph_noise":
			_w_noise(c0, r0, cols, rows)


func _w_titlebar(c0: int, r0: int, cols: int) -> void:
	var d1: Color = Palette.TEAL if up_count() >= 1 else Palette.TEAL_DIM
	var d2: Color = Palette.TEAL_DIM
	match lamp_state("cortex"):
		"INIT":
			d2 = Palette.ORANGE
		"UP":
			d2 = Palette.TEAL
		"FAIL":
			d2 = Palette.ORANGE_DIM
	var d3: Color = Palette.TEAL if _shell_mode else Palette.TEAL_DIM
	_put(c0 + 1, r0, "●", d1)
	_put(c0 + 3, r0, "●", d2)
	_put(c0 + 5, r0, "●", d3)
	_put(c0 + 8, r0, "Q-ENT OS :: ENTANGLED NODE", Palette.TEAL)
	var secs: int = int(float(_frame) / _tick_hz)
	var clock := "T+%02d:%02d" % [(secs / 60) % 100, secs % 60]
	_put(c0 + cols - clock.length() - 1, r0, clock, Palette.ORANGE)


func _cortex_chip() -> String:
	if _gate_resolved:
		return "UP" if _gate_success else "FAIL"
	return "WARMING" if lamp_state("cortex") == "INIT" else "PENDING"


func _w_status(c0: int, r0: int, cols: int) -> void:
	_fill_bg(c0, r0, cols, Palette.TEAL)
	var x := c0 + 1
	var mode := "[ SHELL ]" if _shell_mode else "[ BOOT ]"
	_put(x, r0, mode, Palette.BG, Palette.TEAL)
	x += mode.length() + 2
	var chip := "[ CORTEX " + _cortex_chip() + " ]"
	var chip_bg: Color = Palette.ORANGE if (_gate_resolved and not _gate_success) else Palette.TEAL
	_fill_bg(x - 1, r0, chip.length() + 2, chip_bg)
	_put(x, r0, chip, Palette.BG, chip_bg)
	x += chip.length() + 2
	var mods := "[ %d MODULES ]" % _module_count
	_put(x, r0, mods, Palette.BG, Palette.TEAL)
	var brand := "Q-ENT"
	_put(c0 + cols - brand.length() - 1, r0, brand, Palette.BG, Palette.TEAL)


func _w_lamps(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	var lamps: Array = _data.get("lamps", [])
	_box(c0, r0, cols, rows, title, "UP %d/%d" % [up_count(), lamps.size()])
	for i in range(lamps.size()):
		var l: Dictionary = lamps[i]
		var st: String = lamp_state(String(l["id"]))
		var glyph := "○"
		var col: Color = Palette.TEAL_DIM
		match st:
			"INIT":
				glyph = "◐"
				col = Palette.ORANGE
			"UP":
				glyph = "●"
				col = Palette.TEAL
			"FAIL":
				glyph = "✕"
				col = Palette.ORANGE
		var label := String(l.get("label", ""))
		var leader := " " + ".".repeat(maxi(1, cols - 6 - label.length() - 6)) + " "
		_put(c0 + 2, r0 + 1 + i, glyph, col)
		_put(c0 + 4, r0 + 1 + i, label, col)
		_put(c0 + 4 + label.length(), r0 + 1 + i, leader, Palette.TEAL_DIM)
		_put(c0 + cols - 6, r0 + 1 + i, st.substr(0, 4), col)


func _ticker_strip() -> String:
	var strip := ""
	for m in _data.get("ticker_messages", []):
		strip += String(m) + "  ::  "
	return strip


func _ticker_char(strip: String, idx: int) -> String:
	return strip.substr(idx % strip.length(), 1)


## The ticker cells are composed at the whole-cell part of the pixel offset
## (what the density and motion measurements see); the LiveStrip draws the
## same glyphs at the exact pixel offset every frame.
func _w_ticker(c0: int, r0: int, cols: int) -> void:
	var strip := _ticker_strip()
	if strip.is_empty():
		return
	var off: int = floori(_ticker_px / float(CW))
	_put(c0, r0, "BUS>", Palette.ORANGE)
	_flag_strip = true
	for i in range(cols - 5):
		var ch := _ticker_char(strip, off + i)
		_put(c0 + 5 + i, r0, ch, Palette.ORANGE if ch == ":" else Palette.TEAL)
	_flag_strip = false


func _w_meters(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	_box(c0, r0, cols, rows, title, "")
	var names := ["LATTICE COHERENCE", "LINK JITTER", "BUS TRAFFIC"]
	var periods := [97, 61, 43]
	var seg: int = clampi(cols - 26, 4, 14)
	for i in range(3):
		var v: float = _wave(_frame, i * 5, periods[i])
		_put(c0 + 2, r0 + 1 + i, names[i], Palette.TEAL)
		_put(c0 + 20, r0 + 1 + i, _meter(v, seg), Palette.ORANGE if v > 0.85 else Palette.TEAL_DIM)
		_put(c0 + 21 + seg, r0 + 1 + i, "%3d%%" % int(v * 100.0), Palette.TEAL)


func _w_memory(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	_box(c0, r0, cols, rows, title, "")
	var used := 0.5
	var detail := "SYNTHETIC"
	if not _synthetic:
		var info: Dictionary = OS.get_memory_info()
		var total: float = float(info.get("physical", -1))
		var avail: float = float(info.get("available", -1))
		if total > 0.0 and avail >= 0.0:
			used = clampf(1.0 - avail / total, 0.0, 1.0)
			detail = "%.1f/%.1f GB" % [(total - avail) / 1073741824.0, total / 1073741824.0]
		else:
			detail = "UNRESOLVED"
			used = 0.0
	var seg: int = clampi(cols - 28, 4, 16)
	_put(c0 + 2, r0 + 1, "USED", Palette.TEAL)
	_put(c0 + 7, r0 + 1, _meter(used, seg), Palette.TEAL_DIM)
	_put(c0 + 8 + seg, r0 + 1, "%3d%%  %s" % [int(used * 100.0), detail], Palette.TEAL)


func _spark_width(cols: int) -> int:
	return clampi(cols - 20, 6, 24)


## Sample n of trace i: a pure function of (n, i). The trace is a conveyor
## moving right one sample per 2 ticks (6 samples/s at the default tick rate).
func _spark_glyph(n: int, i: int) -> String:
	var v: float = _wave(2 * n, i * 3, 29 + i * 11) * 0.7 + float(_hash2(n, i) % 100) / 100.0 * 0.3
	return _SPARK[clampi(int(v * 8.0), 0, 7)]


func _w_sparklines(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	_box(c0, r0, cols, rows, title, "")
	var names := ["FIDELITY", "DRIFT", "RELAY LAG"]
	var width: int = _spark_width(cols)
	var head: int = floori(_spark_px / float(CW))
	for i in range(3):
		var trace := ""
		for j in range(width):
			trace += _spark_glyph(head - j, i)
		_put(c0 + 2, r0 + 1 + i, names[i].substr(0, 11), Palette.TEAL)
		_flag_strip = true
		_put(c0 + 14, r0 + 1 + i, trace, Palette.TEAL_DIM if i != 1 else Palette.ORANGE_DIM)
		_flag_strip = false


func _w_rules(c0: int, r0: int, cols: int, rows: int) -> void:
	var tick: int = _frame / 12
	var rules := [
		["LATTICE", "NODES %d  EPOCH %04d" % [7 + (tick / 9) % 2, 412 + tick], "PAIRS %d  WINDOW OPEN" % (11 + (tick / 5) % 3)],
		["TRANSPORT", "CHANNELS 3  QUEUE %d" % ((tick * 7) % 5), "LAG %d MS  CHECKSUM OK" % (11 + (tick * 3) % 6)],
	]
	var row := r0
	for rl in rules:
		if row >= r0 + rows:
			break
		var title: String = "── " + String(rl[0]) + " "
		_put(c0, row, title, Palette.ORANGE)
		_put(c0 + title.length(), row, "·".repeat(maxi(0, cols - title.length())), Palette.TEAL_DIM)
		_put(c0 + 2, row + 1, String(rl[1]), Palette.TEAL)
		_put(c0 + 2, row + 2, String(rl[2]), Palette.TEAL)
		row += 3


func _w_led(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	_box(c0, r0, cols, rows, title, "SYNTHETIC")
	var value := "%04d" % ((412 + _frame / 12) % 10000)
	var left: int = c0 + maxi(1, (cols - 15) / 2)
	for d in range(value.length()):
		var glyph: Array = _DIGITS[value.substr(d, 1)]
		for gr in range(5):
			_put(left + d * 4, r0 + 2 + gr, String(glyph[gr]), Palette.TEAL if d < 3 else Palette.ORANGE)


func _w_rollup(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	_box(c0, r0, cols, rows, title, "")
	var txt := rollup_text()
	var col: Color = Palette.ORANGE if txt.begins_with("DEGRADED") else Palette.TEAL
	_put(c0 + 2, r0 + 1, txt, col)


func _hex_base() -> int:
	return floori(_hex_px / float(CH))


## The 16 bytes of hex line k in group g (cached: a line is re-read every frame
## while it scrolls past, but hashed once).
func _hex_bytes(k: int, g: int) -> PackedInt32Array:
	var key := k * 8 + g
	if _hex_lines.has(key):
		return _hex_lines[key]
	if _hex_lines.size() > 512:
		_hex_lines.clear()
	var out := PackedInt32Array()
	var addr: int = (k + g * 997) * 16
	for j in range(16):
		out.append(_hash2(addr + j, g) % 256)
	_hex_lines[key] = out
	return out


func _hex_groups(cols: int) -> int:
	return 2 if cols >= 90 else 1


func _w_hex(c0: int, r0: int, cols: int, rows: int) -> void:
	var base: int = _hex_base()
	_flag_strip = true
	for g in range(_hex_groups(cols)):
		for r in range(rows):
			var k: int = base + r
			_put(c0 + g * 48, r0 + r, "%04d " % ((k + g * 997) % 10000), Palette.ORANGE)
			var bytes := _hex_bytes(k, g)
			for j in range(16):
				var b: int = bytes[j]
				_put(c0 + g * 48 + 5 + j * 2 + j / 4, r0 + r, "%02X" % b, Palette.TEAL if b % 3 == 0 else Palette.TEAL_DIM)
	_flag_strip = false


func _w_daemon(title: String, c0: int, r0: int, cols: int, rows: int) -> void:
	_box(c0, r0, cols, rows, title, "")
	var lines: Array = _data.get("daemon_log_lines", [])
	if lines.is_empty():
		return
	var head: int = _frame / 8
	var shown: int = rows - 2
	for k in range(shown):
		var idx: int = head - (shown - 1 - k)
		if idx < 0:
			continue
		var stamp := "T+%04d " % (idx % 10000)
		_put(c0 + 2, r0 + 1 + k, stamp, Palette.ORANGE)
		_put(c0 + 2 + stamp.length(), r0 + 1 + k, String(lines[idx % lines.size()]), Palette.TEAL)


func _w_noise(c0: int, r0: int, cols: int, rows: int) -> void:
	var step: int = _frame / 6
	for r in range(rows):
		for c in range(cols):
			var h: int = _hash2(c * 131 + r, step + r * 7)
			if h % 29 == 0:
				_put(c0 + c, r0 + r, _NOISE[h % _NOISE.size()], Palette.TEAL_DIM)
			elif h % 211 == 1:
				_put(c0 + c, r0 + r, _NOISE[(h / 7) % _NOISE.size()], Palette.ORANGE_DIM)
