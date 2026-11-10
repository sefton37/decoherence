#ifndef STALAG_FLORA_H
#define STALAG_FLORA_H

// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545 -- C++ port of src/foliage-placement.js from the frozen Stalag prototype (tag
// prototype-final): the deterministic scatter of grass tufts, creeper cover, ferns, a shrub lump
// and four rock forms on the flat grass cap lids. The result must equal the oracle
// (tools/baseline/js_flora_oracle.mjs) bit for bit. Pure placement: the engine hands out
// instance transforms per chunk and form; materials and sprite policy live in game/world/.

#include <cstdint>
#include <string>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace stalag {

constexpr int NUM_FORMS = 10;
extern const char *const FORM_IDS[NUM_FORMS]; // SELECTED_FORMS order

struct FloraInstance {
	double x, y, z, yaw, scale, lid_x, lid_z;
};

// Placement over the lids whose centre lies in [x_min, x_max) x [z_min, z_max) (world metres),
// in the prototype's order (anchor row k ascending, then i ascending). out[f] is form f.
// Needs the shared plan (is_flooded, course_level_at); without it nothing is placed.
void place_flora_region(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, std::vector<FloraInstance> out[NUM_FORMS], int64_t *lid_count);

// Negative controls: 0 none, 1 lid_shift, 2 flood_ignore, 3 salt_swap.
void set_flora_mutation(int m);

} // namespace stalag

namespace godot {

class StalagFlora : public RefCounted {
	GDCLASS(StalagFlora, RefCounted)

protected:
	static void _bind_methods();

public:
	static PackedStringArray form_ids();
	// Whole-world placement (oracle comparison): {form id: PackedFloat64Array of x, y, z, yaw, scale,
	// lidX, lidZ per instance}. `lids` in the result key "_lids" counts the lids visited.
	static Dictionary place_global();
	// The same for the lids centred in chunk (cx, cz).
	static Dictionary place_chunk(int64_t p_cx, int64_t p_cz);
	// {form id: {count, buffer}}: buffer is the MultiMesh TRANSFORM_3D buffer (12 floats per instance),
	// positions relative to the chunk origin (cx * CHUNK_M, 0, cz * CHUNK_M).
	static Dictionary build_chunk_flora(int64_t p_cx, int64_t p_cz);
	// {builds, on_main_thread} of build_chunk_flora since the last reset.
	static Dictionary get_build_stats();
	static void reset_build_stats();
	// Off: build_chunk_flora returns nothing (the A/B perf control builds no flora at all).
	static void set_enabled(bool p_on);
	static void set_mutation(const String &p_name); // none | lid_shift | flood_ignore | salt_swap
};

} // namespace godot

#endif // STALAG_FLORA_H
