extends RefCounted
## Spec #501: order-independent checksums + edge-multiplicity topology over a triangle
## soup (PackedVector3Array, 3 vertices per triangle). Mirrors centroidQSum / edgeStats
## in tools/baseline/js_baseline.mjs formula-for-formula, so JS and engine numbers are
## directly comparable. Pure measurement: nothing here judges a result.


## Mean of the 3 vertices, q = floor(c * 1e4 + 0.5), summed per axis.
static func centroid_q_sum(v: PackedVector3Array) -> Array:
	var sx := 0
	var sy := 0
	var sz := 0
	var i := 0
	var n := v.size()
	while i + 2 < n:
		var a := v[i]
		var b := v[i + 1]
		var c := v[i + 2]
		sx += floori((a.x + b.x + c.x) / 3.0 * 1e4 + 0.5)
		sy += floori((a.y + b.y + c.y) / 3.0 * 1e4 + 0.5)
		sz += floori((a.z + b.z + c.z) / 3.0 * 1e4 + 0.5)
		i += 3
	return [sx, sy, sz]


static func _q(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x * 1e4 + 0.5), floori(p.y * 1e4 + 0.5), floori(p.z * 1e4 + 0.5))


## Edge-multiplicity topology over several soups (base then caps). `reg` = {xMin,xMax,zMin,zMax}.
static func edge_stats(soups: Array, reg: Dictionary) -> Dictionary:
	var ids := {}
	var vx := PackedFloat64Array()
	var vz := PackedFloat64Array()
	var degenerate := 0
	var edges := {}
	for soup in soups:
		var v: PackedVector3Array = soup
		var i := 0
		var n := v.size()
		while i + 2 < n:
			var id := [0, 0, 0]
			for k in range(3):
				var p := v[i + k]
				var key := _q(p)
				var got = ids.get(key)
				if got == null:
					got = ids.size()
					ids[key] = got
					vx.append(p.x)
					vz.append(p.z)
				id[k] = got
			for k in range(3):
				var a: int = id[k]
				var b: int = id[(k + 1) % 3]
				if a == b:
					degenerate += 1
					continue
				var lo := mini(a, b)
				var hi := maxi(a, b)
				var ek := lo * 16777216 + hi
				edges[ek] = int(edges.get(ek, 0)) + 1
			i += 3
	var m1 := 0
	var m2 := 0
	var m3p := 0
	var open_interior := 0
	var x_lo: float = float(reg["xMin"]) + 1.0
	var x_hi: float = float(reg["xMax"]) - 1.0
	var z_lo: float = float(reg["zMin"]) + 1.0
	var z_hi: float = float(reg["zMax"]) - 1.0
	for ek in edges:
		var cnt: int = edges[ek]
		if cnt == 1:
			m1 += 1
			var lo2: int = ek / 16777216
			var hi2: int = ek - lo2 * 16777216
			if _inside(vx, vz, lo2, x_lo, x_hi, z_lo, z_hi) and _inside(vx, vz, hi2, x_lo, x_hi, z_lo, z_hi):
				open_interior += 1
		elif cnt == 2:
			m2 += 1
		else:
			m3p += 1
	return {"verts": ids.size(), "edges": edges.size(), "m1": m1, "m2": m2, "m3p": m3p, "open_interior": open_interior, "degenerate": degenerate}


static func _inside(vx: PackedFloat64Array, vz: PackedFloat64Array, i: int, x_lo: float, x_hi: float, z_lo: float, z_hi: float) -> bool:
	return vx[i] > x_lo and vx[i] < x_hi and vz[i] > z_lo and vz[i] < z_hi


## Full measurement record for one region built by the engine.
static func measure(arrays: Dictionary, reg: Dictionary) -> Dictionary:
	var base: PackedVector3Array = arrays["base"]["vertices"]
	var caps: PackedVector3Array = arrays["caps"]["vertices"]
	return {
		"tris_base": base.size() / 3,
		"tris_caps": caps.size() / 3,
		"centroid_q_sum_base": centroid_q_sum(base),
		"centroid_q_sum_caps": centroid_q_sum(caps),
		"edge_stats": edge_stats([base, caps], reg),
	}
