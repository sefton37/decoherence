extends RefCounted
## Spec #501 probe helper: an INDEPENDENT ground truth. Down-rays against the triangle
## arrays that were handed to the renderer (the chunk meshes), never against the
## controller's own occupancy model. Chunks are registered as the streamer builds them;
## each is binned on a 1 m grid the first time it is queried.

const BIN_M := 1.0

var _chunk_m: float
var _verts := {}  # Vector2i -> PackedVector3Array (chunk-local)
var _bins := {}  # Vector2i -> Dictionary(Vector2i -> PackedInt32Array of triangle indices)


func _init(chunk_m: float) -> void:
	_chunk_m = chunk_m


func add_chunk(coord: Vector2i, verts_local: PackedVector3Array) -> void:
	_verts[coord] = verts_local


func has_chunk(coord: Vector2i) -> bool:
	return _verts.has(coord)


func _bin(coord: Vector2i) -> Dictionary:
	if _bins.has(coord):
		return _bins[coord]
	var v: PackedVector3Array = _verts[coord]
	var ox := coord.x * _chunk_m
	var oz := coord.y * _chunk_m
	var bins := {}
	var n := v.size()
	var t := 0
	while t + 2 < n:
		var a := v[t]
		var b := v[t + 1]
		var c := v[t + 2]
		var x0 := minf(a.x, minf(b.x, c.x)) + ox
		var x1 := maxf(a.x, maxf(b.x, c.x)) + ox
		var z0 := minf(a.z, minf(b.z, c.z)) + oz
		var z1 := maxf(a.z, maxf(b.z, c.z)) + oz
		# Skip triangles that are vertical (no xz area): a down-ray cannot hit them.
		var area2 := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
		if absf(area2) > 1e-9:
			for bx in range(floori(x0 / BIN_M), floori(x1 / BIN_M) + 1):
				for bz in range(floori(z0 / BIN_M), floori(z1 / BIN_M) + 1):
					var key := Vector2i(bx, bz)
					if not bins.has(key):
						bins[key] = PackedInt32Array()
					var arr: PackedInt32Array = bins[key]
					arr.append(t)
					bins[key] = arr
		t += 3
	_bins[coord] = bins
	return bins


## Highest mesh surface at (x, z) with y <= y_max, or NAN when the ray finds nothing.
func height_at(x: float, z: float, y_max: float) -> float:
	var best := NAN
	var seen := {}
	for dx in [-0.4, 0.0, 0.4]:
		for dz in [-0.4, 0.0, 0.4]:
			var coord := Vector2i(floori((x + dx) / _chunk_m), floori((z + dz) / _chunk_m))
			if seen.has(coord) or not _verts.has(coord):
				continue
			seen[coord] = true
			var h := _chunk_height(coord, x, z, y_max)
			if not is_nan(h) and (is_nan(best) or h > best):
				best = h
	return best


func _chunk_height(coord: Vector2i, x: float, z: float, y_max: float) -> float:
	var bins := _bin(coord)
	var key := Vector2i(floori(x / BIN_M), floori(z / BIN_M))
	if not bins.has(key):
		return NAN
	var v: PackedVector3Array = _verts[coord]
	var lx := x - coord.x * _chunk_m
	var lz := z - coord.y * _chunk_m
	var best := NAN
	var tris: PackedInt32Array = bins[key]
	for t in tris:
		var a := v[t]
		var b := v[t + 1]
		var c := v[t + 2]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-12:
			continue
		var w0 := ((b.z - c.z) * (lx - c.x) + (c.x - b.x) * (lz - c.z)) / d
		var w1 := ((c.z - a.z) * (lx - c.x) + (a.x - c.x) * (lz - c.z)) / d
		var w2 := 1.0 - w0 - w1
		const EPS := -1e-6
		if w0 < EPS or w1 < EPS or w2 < EPS:
			continue
		var y := w0 * a.y + w1 * b.y + w2 * c.y
		if y <= y_max and (is_nan(best) or y > best):
			best = y
	return best


## First x in [x0, x1] where a ray along +x at height y and depth z meets the mesh (the
## triangle is projected along x onto the yz plane), or INF. A wall's front plane as the
## observer sees it, for a given height and depth.
func first_hit_x(x0: float, x1: float, y: float, z: float) -> float:
	var best := INF
	for bx in range(floori(x0 / BIN_M), floori(x1 / BIN_M) + 1):
		var seen := {}
		for dz in [-0.4, 0.0, 0.4]:
			var coord := Vector2i(floori((bx + 0.5) * BIN_M / _chunk_m), floori((z + dz) / _chunk_m))
			if seen.has(coord) or not _verts.has(coord):
				continue
			seen[coord] = true
			var bins := _bin(coord)
			var key := Vector2i(bx, floori(z / BIN_M))
			if not bins.has(key):
				continue
			var v: PackedVector3Array = _verts[coord]
			var ox := coord.x * _chunk_m
			var lz := z - coord.y * _chunk_m
			var tris: PackedInt32Array = bins[key]
			for t in tris:
				var a := v[t]
				var b := v[t + 1]
				var c := v[t + 2]
				var d := (b.z - c.z) * (a.y - c.y) + (c.y - b.y) * (a.z - c.z)
				if absf(d) < 1e-12:
					continue
				var w0 := ((b.z - c.z) * (y - c.y) + (c.y - b.y) * (lz - c.z)) / d
				var w1 := ((c.z - a.z) * (y - c.y) + (a.y - c.y) * (lz - c.z)) / d
				var w2 := 1.0 - w0 - w1
				if w0 < -1e-6 or w1 < -1e-6 or w2 < -1e-6:
					continue
				var hx := w0 * a.x + w1 * b.x + w2 * c.x + ox
				if hx >= x0 and hx <= x1 and hx < best:
					best = hx
	return best
