#ifndef STALAG_WORLD_H
#define STALAG_WORLD_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>

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
};

} // namespace godot

#endif // STALAG_WORLD_H
