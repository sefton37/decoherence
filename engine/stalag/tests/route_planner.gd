extends RefCounted
## Spec #501 probe helper: plans a walkable polyline from engine height queries.
##
## Every leg is checked the way the controller will meet it: sampled every SAMPLE_M, no
## sample may rise more than MAX_RISE (the controller auto-climbs up to 1.0 m), no drop
## beyond MAX_DROP, and the body band above the previous ground must be clear. This keeps
## "wedge" a property of the controller, not of an impassable route.

const SAMPLE_M := 0.25
const LEG_M := 2.0
const MAX_RISE := 0.60
const MAX_DROP := 0.90
const BODY_FROM := 1.05
const BODY_TO := 1.70
const OFFSETS_DEG := [0.0, 12.0, -12.0, 24.0, -24.0, 36.0, -36.0, 50.0, -50.0, 70.0, -70.0, 90.0, -90.0, 120.0, -120.0]


static func ground(p: Vector2) -> float:
	return StalagWorld.ground_envelope_at(p.x, p.y, INF)


static func segment_ok(a: Vector2, b: Vector2, limit: float) -> bool:
	var len := a.distance_to(b)
	var n := int(ceil(len / SAMPLE_M))
	var prev_h := ground(a)
	var prev := a
	for i in range(1, n + 1):
		var p := a.lerp(b, float(i) / n)
		if absf(p.x) > limit or absf(p.y) > limit:
			return false
		var h := ground(p)
		if h - prev_h > MAX_RISE or prev_h - h > MAX_DROP:
			return false
		if StalagWorld.blocked_between(p.x, p.y, prev_h + BODY_FROM, prev_h + BODY_TO):
			return false
		prev_h = h
		prev = p
	return true


## Polyline from `start` through each target in turn (within ~LEG_M of each).
static func plan(start: Vector2, targets: Array, limit: float) -> Array:
	var pts: Array = [start]
	var cur := start
	var turn_pref := 1.0
	for t in targets:
		var tgt: Vector2 = t
		var guard := 0
		while cur.distance_to(tgt) > LEG_M and guard < 600:
			guard += 1
			var bearing := (tgt - cur).angle()
			var chosen = null
			for off in OFFSETS_DEG:
				var ang: float = bearing + deg_to_rad(off * turn_pref)
				var cand := cur + Vector2.from_angle(ang) * LEG_M
				if segment_ok(cur, cand, limit):
					chosen = cand
					if off != 0.0:
						turn_pref = turn_pref  # keep the preferred side
					break
			if chosen == null:
				return []
			# Do not double back onto the last few points (greedy loop guard).
			var looped := false
			for k in range(maxi(0, pts.size() - 8), pts.size() - 1):
				if (pts[k] as Vector2).distance_to(chosen) < 0.8:
					looped = true
			if looped:
				turn_pref = -turn_pref
			pts.append(chosen)
			cur = chosen
		if guard >= 600:
			return []
	return pts


static func length(pts: Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += (pts[i - 1] as Vector2).distance_to(pts[i])
	return l
