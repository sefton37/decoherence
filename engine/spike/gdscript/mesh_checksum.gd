class_name SpikeMeshChecksum
extends RefCounted
## Spec #494 parity measure, applied to the ArrayMesh a candidate actually returned.
##
## tris          = vertex count / 3
## centroid_q    = per-axis integer sum of floor(c * 1e4 + 0.5), c = mean of the triangle's
##                 3 vertices in float64. Order independent and exact.
##
## Vertices are single-precision in an ArrayMesh, but every coordinate here is a
## multiple of 0.125 m, which float32 stores exactly, so reading components back as
## doubles loses nothing. Components are summed as GDScript floats (double), never
## through Vector3 arithmetic (which would round to float32).


@warning_ignore("integer_division")
static func compute(mesh: ArrayMesh) -> Dictionary:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n := verts.size()
	var qx := 0
	var qy := 0
	var qz := 0
	var t := 0
	while t + 2 < n:
		var a := verts[t]
		var b := verts[t + 1]
		var c := verts[t + 2]
		qx += int(floorf(((a.x + b.x + c.x) / 3.0) * 1e4 + 0.5))
		qy += int(floorf(((a.y + b.y + c.y) / 3.0) * 1e4 + 0.5))
		qz += int(floorf(((a.z + b.z + c.z) / 3.0) * 1e4 + 0.5))
		t += 3
	return { "tris": n / 3, "centroid_q_sum": [qx, qy, qz] }
