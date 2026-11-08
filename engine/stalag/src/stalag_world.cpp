#include "stalag_world.h"

#include "stalag_core.h"

#include <cmath>

using namespace godot;

void StalagWorld::_bind_methods() {
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_sf"), &StalagWorld::get_sf);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_seed"), &StalagWorld::get_seed);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_extent"), &StalagWorld::get_extent);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_chunk_m"), &StalagWorld::get_chunk_m);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_half_extent_m"), &StalagWorld::get_half_extent_m);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("surface_height_base", "cx", "cz"), &StalagWorld::surface_height_base);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("spawn_feet_y"), &StalagWorld::spawn_feet_y);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("is_solid_world", "cx", "cy", "cz"), &StalagWorld::is_solid_world);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("ground_envelope_at", "fx", "fz", "max_surface"), &StalagWorld::ground_envelope_at);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("ground_floor", "fx", "fz", "max_surface"), &StalagWorld::ground_floor);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("blocked_between", "fx", "fz", "from_y", "to_y"), &StalagWorld::blocked_between);
}

double StalagWorld::get_sf() { return stalag::SF; }
int64_t StalagWorld::get_seed() { return stalag::WORLD_SEED; }
int64_t StalagWorld::get_extent() { return stalag::WORLD_EXTENT; }
double StalagWorld::get_chunk_m() { return stalag::CHUNK_M; }
// Footprint half-size: cells with |x| or |z| beyond this do not exist (index.html: 4 * extent * SF).
double StalagWorld::get_half_extent_m() { return 4.0 * stalag::WORLD_EXTENT * stalag::SF; }
double StalagWorld::surface_height_base(int64_t p_cx, int64_t p_cz) {
	return stalag::surface_height_base((int32_t)p_cx, (int32_t)p_cz, stalag::WORLD_SEED);
}
// index.html spawnFeetY: feet on the lid of the column above the world centre.
double StalagWorld::spawn_feet_y() {
	return (std::floor(stalag::surface_height_base(0, 0, stalag::WORLD_SEED) / 4) * 4 + 2) * stalag::SF;
}
bool StalagWorld::is_solid_world(int64_t p_cx, int64_t p_cy, int64_t p_cz) {
	return stalag::is_solid_world((int32_t)p_cx, (int32_t)p_cy, (int32_t)p_cz);
}
double StalagWorld::ground_envelope_at(double p_fx, double p_fz, double p_max_surface) {
	return stalag::ground_envelope_at(p_fx, p_fz, p_max_surface);
}
double StalagWorld::ground_floor(double p_fx, double p_fz, double p_max_surface) {
	return stalag::ground_floor(p_fx, p_fz, p_max_surface);
}
bool StalagWorld::blocked_between(double p_fx, double p_fz, double p_from_y, double p_to_y) {
	return stalag::blocked_between(p_fx, p_fz, p_from_y, p_to_y);
}
