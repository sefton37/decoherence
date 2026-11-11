#ifndef STALAG_UNDERSTORY_H
#define STALAG_UNDERSTORY_H

// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- C++ port of src/flower-placement.js and src/shrub-placement.js from the frozen
// Stalag prototype (tag prototype-final), plus the grass thinning rule of index.html line 1414
// (a grass tuft or cover is dropped on every lid that holds a wildflower or a shrub). The result
// must equal the oracle (tools/baseline/js_trees_oracle.mjs) bit for bit.
//
// Wildflowers are placed from the whole world at once: the sensor bloom is a greedy pick over the
// score-sorted pool of every open lid, and the guaranteed lone instance scans the same pool, so
// neither can be decided chunk by chunk. Shrubs are gated by every tree within 1.5 m (which crosses
// chunk borders) and by every flower lid. Both are therefore computed once for the world, cached,
// and handed out by chunk (the chunk of the lid centre). The cache is dropped when a mutation moves.

#include <cstdint>
#include <memory>
#include <unordered_set>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace stalag {

constexpr int NUM_FLOWER_FORMS = 7;
constexpr int NUM_SHRUB_FORMS = 6;
extern const char *const FLOWER_FORM_IDS[NUM_FLOWER_FORMS]; // PLACED_FLOWERS order
extern const char *const SHRUB_FORM_IDS[NUM_SHRUB_FORMS]; // PLACED_SHRUBS order

constexpr double SHRUB_SPAWN_CLEARING = 5.0;
constexpr double MIN_TRUNK_DIST = 1.2;

struct FlowerInstance {
	double x, y, z, yaw, scale, lid_x, lid_z;
	int tier; // 0 muted, 1 vivid
	int count; // instances of this species on the lid (1 or 2)
};
struct ShrubInstance {
	double x, y, z, yaw, scale, lid_x, lid_z;
};

struct UnderstoryWorld {
	std::vector<FlowerInstance> flowers[NUM_FLOWER_FORMS];
	std::vector<ShrubInstance> shrubs[NUM_SHRUB_FORMS];
	std::unordered_set<int64_t> flower_lids; // lattice key of the lid centre
	std::unordered_set<int64_t> shrub_lids;
};

// The cached world placement (computed on first use, on whichever thread asks first; later callers
// wait for it). Null while the shared plan is not ready.
std::shared_ptr<const UnderstoryWorld> understory_world();
// Lattice key of a lid centre given in world metres (exact for lid centres, which are multiples of SF).
int64_t lid_key(double lid_x, double lid_z);
// Negative controls: 0 none; 1 flower_floor, 2 sensor_gap_off, 3 trunk_gate_off, 4 flower_gate_off,
// 5 thin_off, 6 thin_all, 7 tier_swap.
void set_understory_mutation(int m);
int understory_mutation();
// The thinning predicate for the meadow: should instance of form `form` on lid (lid_x, lid_z) be dropped?
// `form` is the S2 form index (0..2 are the grass forms).
bool meadow_thinned(int form, double lid_x, double lid_z);

} // namespace stalag

namespace godot {

class StalagUnderstory : public RefCounted {
	GDCLASS(StalagUnderstory, RefCounted)

protected:
	static void _bind_methods();

public:
	static PackedStringArray flower_ids();
	static PackedStringArray shrub_ids();
	// {id: PackedFloat64Array}: 9 doubles per flower (x, y, z, yaw, scale, lidX, lidZ, tier, count),
	// 7 per shrub (x, y, z, yaw, scale, lidX, lidZ). "_lid_keys" counts the distinct lids.
	static Dictionary flowers_global();
	static Dictionary shrubs_global();
	static Dictionary flowers_chunk(int64_t p_cx, int64_t p_cz);
	static Dictionary shrubs_chunk(int64_t p_cx, int64_t p_cz);
	// {"<flower id>/muted" | "<flower id>/vivid" | "<shrub id>": {count, buffer}}: MultiMesh TRANSFORM_3D
	// buffers (12 floats per instance, yaw about +Y, uniform scale), chunk-local. Worker-thread safe.
	static Dictionary build_chunk_understory(int64_t p_cx, int64_t p_cz);
	static Dictionary get_build_stats();
	static void reset_build_stats();
	static void set_enabled(bool p_on);
	static void set_mutation(const String &p_name);
};

} // namespace godot

#endif // STALAG_UNDERSTORY_H
