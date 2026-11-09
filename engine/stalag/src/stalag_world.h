#ifndef STALAG_WORLD_H
#define STALAG_WORLD_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

// Spec #501: the world constants and carve-free queries, exposed to GDScript. The cell
// scale lives only in stalag_core.h; scripts read it from here (hazard H1).
class StalagWorld : public RefCounted {
	GDCLASS(StalagWorld, RefCounted)

protected:
	static void _bind_methods();

public:
	static double get_sf();
	static int64_t get_seed();
	static int64_t get_extent();
	static double get_chunk_m();
	static double get_half_extent_m();
	static double surface_height_base(int64_t p_cx, int64_t p_cz);
	static double spawn_feet_y();
	static bool is_solid_world(int64_t p_cx, int64_t p_cy, int64_t p_cz);
	static double ground_envelope_at(double p_fx, double p_fz, double p_max_surface);
	static double ground_floor(double p_fx, double p_fz, double p_max_surface);
	static bool blocked_between(double p_fx, double p_fz, double p_from_y, double p_to_y);

	// ---- Spec #517: the water plan. start_plan runs the solve on a worker thread and
	// returns at once; plan_status is 0 never started, 1 solving, 2 ready, 3 failed.
	static void start_plan();
	static int64_t plan_status();
	static bool plan_ready();
	static String plan_error();
	static void wait_plan(); // tests only: blocks until the solve ends
	static String plan_hash();
	static double plan_solve_ms();
	static bool plan_solved_off_main_thread();
	static PackedInt64Array plan_type_counts();
	// Compares one plan array with the oracle's raw dump (little-endian bytes).
	static Dictionary compare_plan_array(const String &p_name, const PackedByteArray &p_bytes);
	// surfaceHeight (carved) at a lattice address, and the signed carve there.
	static double surface_height(double p_cx, double p_cz);
	static double carve_depth(double p_cx, double p_cz);
	// The seven water-API queries on plan columns (hydrology.js / rivers.js).
	static int64_t water_level_at(int64_t p_gx, int64_t p_gz);
	static bool is_flooded(int64_t p_gx, int64_t p_gz);
	static int64_t course_level_at(int64_t p_gx, int64_t p_gz);
	static Vector2 get_flow_dir(int64_t p_gx, int64_t p_gz); // zero vector when the JS returns null
	static int64_t course_fall_top_at(int64_t p_gx, int64_t p_gz);
	static bool is_river_column(int64_t p_gx, int64_t p_gz);
	static int64_t get_strahler_order(int64_t p_gx, int64_t p_gz);
	static int64_t water_dry_sentinel();
	static int64_t plan_dim();
	static int64_t plan_g0();
	// Negative controls: "none", "carve_off", "flood_off".
	static void set_mutation(const String &p_name);
};

} // namespace godot

#endif // STALAG_WORLD_H
