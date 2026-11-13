extends RefCounted
class_name HandlerLayout

## Pure layout of the HANDLER screen (Spec #575). Same glyph cell grid as the chat
## client (10 x 20), same minimum viewport for the full tier. Row 0 is the title bar,
## the body is the two panes with one gutter between them, and the three rows above the
## last (empty) one are the bottom bar: the status line on the left and the Launch button on the right. A
## gutter carries no glyphs at all. Below the full tier the panes fold to one at a time.

const CELL_W := ChatLayout.CELL_W
const CELL_H := ChatLayout.CELL_H
const GUTTER_COLS := 1
const PROFILE_MIN_COLS := 40
const PROFILE_MAX_COLS := 64
const BAR_ROWS := 3
## The last row stays empty, so the button frame never touches the edge of the window.
const BOTTOM_MARGIN := 1
const BUTTON_PAD := 6
const FULL := ChatLayout.FULL
const REDUCED := ChatLayout.REDUCED


## `launch_cells` is the label length; `shown` is the pane a folded layout keeps ("dossier" or "profile").
## {tier, cols, rows, title, dossier, gutter, profile, status, launch}; every rectangle is a Rect2i in cells.
static func compute(width: int, height: int, launch_cells: int, shown: String = "dossier") -> Dictionary:
	var cols := maxi(width / CELL_W, 1)
	var rows := maxi(height / CELL_H, BAR_ROWS + BOTTOM_MARGIN + 3)
	var tier := ChatLayout.tier_for(width, height)
	var body_h := maxi(rows - 1 - BAR_ROWS - BOTTOM_MARGIN, 1)
	var dossier := Rect2i(0, 1, cols, body_h)
	var gutter := Rect2i(cols, 1, 0, body_h)
	var profile := Rect2i(cols, 1, 0, body_h)
	if tier == FULL:
		var pc := clampi(cols * 3 / 10, PROFILE_MIN_COLS, PROFILE_MAX_COLS)
		var dc := maxi(cols - pc - GUTTER_COLS, 1)
		dossier = Rect2i(0, 1, dc, body_h)
		gutter = Rect2i(dc, 1, GUTTER_COLS, body_h)
		profile = Rect2i(dc + GUTTER_COLS, 1, maxi(cols - dc - GUTTER_COLS, 0), body_h)
	elif shown == "profile":
		dossier = Rect2i(0, 1, 0, body_h)
		profile = Rect2i(0, 1, cols, body_h)
		gutter = Rect2i(0, 1, 0, body_h)
	var bw := mini(maxi(launch_cells + BUTTON_PAD, 14), maxi(cols - 2, 1))
	var bar_y := rows - BAR_ROWS - BOTTOM_MARGIN
	return {
		"tier": tier,
		"cols": cols,
		"rows": rows,
		"title": Rect2i(0, 0, cols, 1),
		"dossier": dossier,
		"gutter": gutter,
		"profile": profile,
		"status": Rect2i(0, bar_y + 1, maxi(cols - bw - 3, 1), 1),
		"launch": Rect2i(cols - bw - 1, bar_y, bw, BAR_ROWS),
	}


static func pane_names() -> Array:
	return ["title", "dossier", "gutter", "profile", "status", "launch"]


static func rect_list(layout: Dictionary) -> Array:
	var out: Array = []
	for name in pane_names():
		out.append(layout[name])
	return out


static func overlap_count(rects: Array) -> int:
	return ChatLayout.overlap_count(rects)


static func out_of_bounds_count(rects: Array, cols: int, rows: int) -> int:
	return ChatLayout.out_of_bounds_count(rects, cols, rows)
