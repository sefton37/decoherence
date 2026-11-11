#ifndef STALAG_TREES_H
#define STALAG_TREES_H

// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- C++ port of src/tree-placement.js from the frozen Stalag prototype (tag
// prototype-final): the deterministic scatter of twelve tree forms in groves on the flat grass
// cap lids, with per-instance proportion, lean and colour jitter. The result must equal the
// oracle (tools/baseline/js_trees_oracle.mjs) bit for bit. Pure placement: the engine hands out
// instance transforms and crown colours per chunk and form; meshes, materials and the wind
// feed live in game/world/.
//
// The instance matrix composition follows three.js Object3D (MIT licence; Euler order XYZ turned
// into a quaternion, then Matrix4.compose), which is how the prototype built its instance
// matrices. The matrices are float32, 12 per instance, in the layout of a Godot MultiMesh
// TRANSFORM_3D buffer (three rows of basis and origin).

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace stalag {

constexpr int NUM_TREE_FORMS = 12;
extern const char *const TREE_FORM_IDS[NUM_TREE_FORMS]; // TREE_OPTIONS order

constexpr double SPAWN_CLEARING = 8.0; // m radius around (0,0) kept clear of trunks

struct TreeInstance {
	double x, y, z, yaw, scale, height, w_jit, h_jit, lean_x, lean_z, val_jit, hue_jit, lid_x, lid_z;
};

// One flat grass cap lid, in the order of the prototype's lid walk (anchor row k ascending, then i).
struct Lid {
	int32_t cx, cz;
	double H; // quantized terrace height, lattice units
};

// The lids whose centre lies in [x_min, x_max) x [z_min, z_max) (world metres), in the walk order.
// Needs the shared plan; without it nothing is listed. `lid_shift` is the negative-control hook.
void list_lids_region(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, std::vector<Lid> &out, bool lid_shift = false);

// Tree placement over the lids centred in the region; out[f] is form f, in the prototype's order.
void place_trees_region(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, std::vector<TreeInstance> out[NUM_TREE_FORMS]);

// Negative controls: 0 none, 1 lid_shift, 2 flood_ignore, 3 clearing_off, 4 salt_swap, 5 grove_off,
// 6 landmark_lean, 7 hue_exempt, 8 euler_order.
void set_tree_mutation(int m);
int tree_mutation();

// The 12 float32 of a MultiMesh TRANSFORM_3D entry for a tree, chunk-local (origin minus x0, z0).
void tree_matrix(const TreeInstance &t, double x0, double z0, float out[12]);
// Per-instance crown colour: hsv2rgb(128 + hueJit, 0.22, 1) * valJit, linear, float32.
void tree_crown_color(const TreeInstance &t, float out[3]);

} // namespace stalag

namespace godot {

class StalagTrees : public RefCounted {
	GDCLASS(StalagTrees, RefCounted)

protected:
	static void _bind_methods();

public:
	static PackedStringArray form_ids();
	// Whole-world placement: {form id: PackedFloat64Array of 14 doubles per instance (x, y, z, yaw,
	// scale, height, wJit, hJit, leanX, leanZ, valJit, hueJit, lidX, lidZ)}.
	static Dictionary place_global();
	// The same for the lids centred in chunk (cx, cz).
	static Dictionary place_chunk(int64_t p_cx, int64_t p_cz);
	// {form id: PackedFloat32Array of 12 floats per instance}: the chunk-local matrices, and
	// matrices_global for the world-space ones (used by the hash comparison).
	static Dictionary matrices_chunk(int64_t p_cx, int64_t p_cz);
	// {form id: PackedFloat32Array of 3 floats per instance}: crown colours (empty for dead forms).
	static Dictionary colors_chunk(int64_t p_cx, int64_t p_cz);
	// {form id: {count, buffer, colors}}: what the streamer adopts. Worker-thread safe.
	static Dictionary build_chunk_trees(int64_t p_cx, int64_t p_cz);
	static Dictionary get_build_stats();
	static void reset_build_stats();
	// Off: build_chunk_trees returns nothing (the A/B perf control builds no trees at all).
	static void set_enabled(bool p_on);
	static void set_mutation(const String &p_name);
	// Asset format helpers (tools/bake_trees.mjs writes the float32 vertex runs; layouts: "trunk" is
	// position3 normal3 colour3, "crown" adds uv2 heightFrac exposure clusterXZ2 cellY, "shadow" is
	// position3). decode_arrays turns one run into Mesh surface arrays with the winding swapped (the
	// prototype's triangles are counter-clockwise, Godot's front face is clockwise); flatten_arrays
	// undoes that and returns the run's floats again, so a hash of it proves what was loaded.
	static Array decode_arrays(const PackedByteArray &p_blob, int64_t p_offset, int64_t p_verts, const String &p_layout);
	static PackedFloat32Array flatten_arrays(const Array &p_arrays, const String &p_layout);
	// A copy of decoded surface arrays with bitwise-identical vertices merged behind an index buffer
	// (same triangles, same winding, same order; the two triangles of a quad share two vertices). The
	// GPU then runs the vertex shader once per distinct vertex instead of once per triangle corner.
	static Array index_arrays(const Array &p_arrays);
};

} // namespace godot

#endif // STALAG_TREES_H
