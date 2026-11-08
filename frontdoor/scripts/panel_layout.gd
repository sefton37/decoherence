extends RefCounted
class_name PanelLayout

## Pure layout for the boot/shell chrome (Spec #519): viewport size in,
## named pixel rects out. The terminal rect is a fixed 1008x700 block at
## the top-left and is NEVER moved or resized; every panel slot lives in
## the space around it. No clock, no randomness, no node access.
##
## Tiers: wide (>= 1600x900): title strip + two-column right pane + bottom
## ticker and status bar + a bottom-left bus pane. compact (>= 1200x700):
## a single right rail plus a status strip. none: terminal only.

const CELL_W := 10
const CELL_H := 20
const TERM_W := 1008
const TERM_H := 700
const RIGHT_X := 1010


static func tier_for(viewport: Vector2i) -> String:
	if viewport.x >= 1600 and viewport.y >= 900:
		return "wide"
	if viewport.x >= 1200 and viewport.y >= 700:
		return "compact"
	return "none"


## Returns {tier, term: Rect2i, slots: {slot_name: Rect2i}}.
static func compute(viewport: Vector2i) -> Dictionary:
	var tier := tier_for(viewport)
	var term := Rect2i(0, 0, TERM_W, TERM_H)
	var slots: Dictionary = {}
	var w := viewport.x
	var h := viewport.y
	if tier == "wide":
		var rw := w - RIGHT_X - 10
		var cw := ((rw - 10) / 2 / CELL_W) * CELL_W
		var col_a := RIGHT_X
		var col_b := RIGHT_X + cw + 10
		slots["title"] = Rect2i(RIGHT_X, 0, w - RIGHT_X, CELL_H)
		slots["s1"] = Rect2i(col_a, 40, cw, 200)
		slots["s2"] = Rect2i(col_b, 40, cw, 200)
		slots["s3"] = Rect2i(col_a, 260, cw, 120)
		slots["s4"] = Rect2i(col_b, 260, cw, 120)
		slots["s5"] = Rect2i(col_a, 400, cw, 140)
		slots["s6"] = Rect2i(col_b, 400, cw, 140)
		slots["s7"] = Rect2i(RIGHT_X, 560, rw, 60)
		slots["s8"] = Rect2i(RIGHT_X, 640, rw, 60)
		slots["bl1"] = Rect2i(0, 720, 1000, h - 60 - 720)
		slots["m1"] = Rect2i(RIGHT_X, 720, rw, h - 60 - 720)
		slots["ticker"] = Rect2i(0, h - 40, w, CELL_H)
		slots["status"] = Rect2i(0, h - 20, w, CELL_H)
	elif tier == "compact":
		var rw2 := w - RIGHT_X - 10
		slots["title"] = Rect2i(RIGHT_X, 0, w - RIGHT_X, CELL_H)
		slots["s1"] = Rect2i(RIGHT_X, 40, rw2, 200)
		slots["s2"] = Rect2i(RIGHT_X, 260, rw2, 120)
		slots["s3"] = Rect2i(RIGHT_X, 400, rw2, 140)
		# Rollup banner and live memory meter: without these slots the compact
		# tier dropped every full_bus extra and drew wire_room (found at 1280x720,
		# where both presets measured the identical 427.39 active cells).
		slots["s7"] = Rect2i(RIGHT_X, 560, rw2, 60)
		slots["s8"] = Rect2i(RIGHT_X, 640, rw2, 60)
		slots["status"] = Rect2i(0, TERM_H, w, h - TERM_H)
	return {"tier": tier, "term": term, "slots": slots}


## Panels actually shown: [{id, rect}] for each widget whose slot exists in
## this tier. `widget_slots` maps widget id -> slot name.
static func panels_for(layout: Dictionary, widget_slots: Dictionary) -> Array:
	var out: Array = []
	var slots: Dictionary = layout["slots"]
	for wid in widget_slots:
		var slot_name: String = widget_slots[wid]
		if slots.has(slot_name):
			out.append({"id": wid, "rect": slots[slot_name]})
	return out


## Number of overlapping pairs among panel rects and the terminal rect.
static func overlap_count(term: Rect2i, panels: Array) -> int:
	var rects: Array = [term]
	for p in panels:
		rects.append(p["rect"])
	var n := 0
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2i).intersects(rects[j]):
				n += 1
	return n


## True when every panel rect lies fully inside the viewport.
static func all_in_bounds(viewport: Vector2i, panels: Array) -> bool:
	var bounds := Rect2i(0, 0, viewport.x, viewport.y)
	for p in panels:
		if not bounds.encloses(p["rect"]):
			return false
	return true
