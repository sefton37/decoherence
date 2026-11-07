#ifndef STALAG_MESHER_H
#define STALAG_MESHER_H

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>

namespace godot {

// Spec #494 spike: native port of the stalag `base` terrain mesh (boundary-face
// extraction over truncated-octahedron cells). Everything -- noise, column
// heights, side/bottom/top cap decisions, face emission, ArrayMesh creation --
// happens in C++; nothing calls back into GDScript.
class StalagMesher : public RefCounted {
	GDCLASS(StalagMesher, RefCounted)

protected:
	static void _bind_methods();

public:
	// Region is [x_min, x_max) x [z_min, z_max) in world metres (cell-centre gate).
	Ref<ArrayMesh> build(int64_t p_seed, int64_t p_extent, double p_x_min, double p_x_max, double p_z_min, double p_z_max);
};

} // namespace godot

#endif // STALAG_MESHER_H
