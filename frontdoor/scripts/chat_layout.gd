extends RefCounted
class_name ChatLayout

## Pure layout of the chat client (Spec #562). The client fills the logical
## viewport with a glyph grid of CELL_W x CELL_H cells (the same pitch the
## terminal uses) and this file decides where each pane sits, in cells. No
## scene, no font, no clock: the unit harness and the layout probe both call it.
##
## Rows: 0 navigation bar, 1 header, then the body, the second-last row is the
## status line and the last row is the input line. Columns of the full tier:
## sidebar, one gutter, the main pane (whatever is left), one gutter, the
## people pane. The gutters carry no glyphs at all.

const CELL_W := 10
const CELL_H := 20
const SIDE_COLS := 26
const PEOPLE_COLS := 24
const GUTTER_COLS := 1
## Below this logical viewport (not a game size) the sidebar and the people pane
## fold away and the main pane takes the width.
const MIN_FULL_W := 1200
const MIN_FULL_H := 700

const FULL := "full"
const REDUCED := "reduced"


static func tier_for(width: int, height: int) -> String:
	return FULL if width >= MIN_FULL_W and height >= MIN_FULL_H else REDUCED


## Pane rectangles in cells for a viewport of `width` x `height` logical pixels:
## {tier, cols, rows, nav, header, side, gutter_a, main, gutter_b, people,
## status, input}. Every Rect2i is {x, y, w, h} in cells.
static func compute(width: int, height: int) -> Dictionary:
	var cols := maxi(width / CELL_W, 1)
	var rows := maxi(height / CELL_H, 6)
	var tier := tier_for(width, height)
	var body_y := 2
	var body_h := maxi(rows - 4, 1)
	var side := 0
	var people := 0
	var gutter := 0
	if tier == FULL:
		side = SIDE_COLS
		people = PEOPLE_COLS
		gutter = GUTTER_COLS
	var main_x := side + gutter
	var main_w := maxi(cols - side - people - 2 * gutter, 1)
	return {
		"tier": tier,
		"cols": cols,
		"rows": rows,
		"nav": Rect2i(0, 0, cols, 1),
		"header": Rect2i(0, 1, cols, 1),
		"side": Rect2i(0, body_y, side, body_h),
		"gutter_a": Rect2i(side, body_y, gutter, body_h),
		"main": Rect2i(main_x, body_y, main_w, body_h),
		"gutter_b": Rect2i(main_x + main_w, body_y, gutter, body_h),
		"people": Rect2i(main_x + main_w + gutter, body_y, people, body_h),
		"status": Rect2i(0, rows - 2, cols, 1),
		"input": Rect2i(0, rows - 1, cols, 1),
	}


## The pane names a layout carries, in a fixed order.
static func pane_names() -> Array:
	return ["nav", "header", "side", "gutter_a", "main", "gutter_b", "people", "status", "input"]


## Number of pairs of non-empty rectangles that share at least one cell.
static func overlap_count(rects: Array) -> int:
	var n := 0
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			var a: Rect2i = rects[i]
			var b: Rect2i = rects[j]
			if a.size.x > 0 and a.size.y > 0 and b.size.x > 0 and b.size.y > 0 and a.intersects(b):
				n += 1
	return n


## Number of non-empty rectangles that are not wholly inside the cols x rows grid.
static func out_of_bounds_count(rects: Array, cols: int, rows: int) -> int:
	var n := 0
	var grid := Rect2i(0, 0, cols, rows)
	for r in rects:
		var rect: Rect2i = r
		if rect.size.x > 0 and rect.size.y > 0 and not grid.encloses(rect):
			n += 1
	return n


## Every pane of a computed layout as an Array of Rect2i (the gutters included).
static func rect_list(layout: Dictionary) -> Array:
	var out: Array = []
	for name in pane_names():
		out.append(layout[name])
	return out
