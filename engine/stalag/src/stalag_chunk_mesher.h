#ifndef STALAG_CHUNK_MESHER_H
#define STALAG_CHUNK_MESHER_H

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Spec #501: the chunk mesher. Every method is static and reentrant -- the streamer
// calls build_chunk from WorkerThreadPool tasks. Everything (noise, column
// heights, cap decisions, base AND caps emission) happens in C++.
class StalagChunkMesher : public RefCounted {
	GDCLASS(StalagChunkMesher, RefCounted)

protected:
	static void _bind_methods();

public:
	// World-space {base:{vertices,normals,colors}, caps:{...}} for [x_min,x_max) x [z_min,z_max).
	static Dictionary build_region_arrays(double p_x_min, double p_x_max, double p_z_min, double p_z_max);
	// {mesh, vertices, tris} for chunk (cx, cz): one ArrayMesh surface (base then caps,
	// clockwise winding for Godot) whose vertices are LOCAL to the chunk origin
	// (cx * CHUNK_M, 0, cz * CHUNK_M), so the node's position places the chunk; `vertices`
	// is the same array that went to the renderer.
	static Dictionary build_chunk(int64_t p_cx, int64_t p_cz);
	// {builds, on_main_thread, tris_base_last} since the last reset (builds the mesher ran).
	static Dictionary get_build_stats();
	static void reset_build_stats();
};

} // namespace godot

#endif // STALAG_CHUNK_MESHER_H
