#include "stalag_world.h"

#include "stalag_core.h"
#include "stalag_plan.h"

#include <cmath>
#include <cstring>

using namespace godot;

void StalagWorld::_bind_methods() {
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_sf"), &StalagWorld::get_sf);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_seed"), &StalagWorld::get_seed);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_extent"), &StalagWorld::get_extent);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_chunk_m"), &StalagWorld::get_chunk_m);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_half_extent_m"), &StalagWorld::get_half_extent_m);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("surface_height_base", "cx", "cz"), &StalagWorld::surface_height_base);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("spawn_feet_y"), &StalagWorld::spawn_feet_y);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("set_pad", "half_m", "blend_m"), &StalagWorld::set_pad);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("pad_half_m"), &StalagWorld::pad_half_m);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("pad_blend_m"), &StalagWorld::pad_blend_m);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("is_solid_world", "cx", "cy", "cz"), &StalagWorld::is_solid_world);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("ground_envelope_at", "fx", "fz", "max_surface"), &StalagWorld::ground_envelope_at);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("ground_floor", "fx", "fz", "max_surface"), &StalagWorld::ground_floor);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("blocked_between", "fx", "fz", "from_y", "to_y"), &StalagWorld::blocked_between);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("start_plan"), &StalagWorld::start_plan);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_status"), &StalagWorld::plan_status);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_ready"), &StalagWorld::plan_ready);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_error"), &StalagWorld::plan_error);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("wait_plan"), &StalagWorld::wait_plan);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_hash"), &StalagWorld::plan_hash);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_solve_ms"), &StalagWorld::plan_solve_ms);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_solved_off_main_thread"), &StalagWorld::plan_solved_off_main_thread);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_type_counts"), &StalagWorld::plan_type_counts);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("compare_plan_array", "name", "bytes"), &StalagWorld::compare_plan_array);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("surface_height", "cx", "cz"), &StalagWorld::surface_height);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("carve_depth", "cx", "cz"), &StalagWorld::carve_depth);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("water_level_at", "gx", "gz"), &StalagWorld::water_level_at);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("is_flooded", "gx", "gz"), &StalagWorld::is_flooded);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("course_level_at", "gx", "gz"), &StalagWorld::course_level_at);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_flow_dir", "gx", "gz"), &StalagWorld::get_flow_dir);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("course_fall_top_at", "gx", "gz"), &StalagWorld::course_fall_top_at);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("is_river_column", "gx", "gz"), &StalagWorld::is_river_column);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("get_strahler_order", "gx", "gz"), &StalagWorld::get_strahler_order);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("water_dry_sentinel"), &StalagWorld::water_dry_sentinel);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_dim"), &StalagWorld::plan_dim);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("plan_g0"), &StalagWorld::plan_g0);
	ClassDB::bind_static_method("StalagWorld", D_METHOD("set_mutation", "name"), &StalagWorld::set_mutation);
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
	return (std::floor(stalag::surface_height_world(0, 0) / 4) * 4 + 2) * stalag::SF;
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

// ================================================================ Spec #517: water plan
namespace {
const stalag::WaterPlan *need_plan() { return stalag::shared_plan(); }
} // namespace

void StalagWorld::start_plan() { stalag::start_plan_solve(stalag::WORLD_SEED); }
int64_t StalagWorld::plan_status() { return stalag::plan_status(); }
bool StalagWorld::plan_ready() { return stalag::plan_status() == 2; }
String StalagWorld::plan_error() {
	const stalag::WaterPlan *p = stalag::failed_plan();
	return p ? String(p->error.c_str()) : String();
}
void StalagWorld::wait_plan() { stalag::wait_plan_ready(); }
String StalagWorld::plan_hash() {
	const stalag::WaterPlan *p = need_plan();
	return p ? String(stalag::plan_hash(*p).c_str()) : String();
}
double StalagWorld::plan_solve_ms() {
	const stalag::WaterPlan *p = need_plan();
	return p ? p->solve_ms : 0.0;
}
bool StalagWorld::plan_solved_off_main_thread() {
	const stalag::WaterPlan *p = need_plan();
	return p ? p->solved_off_caller : false;
}
PackedInt64Array StalagWorld::plan_type_counts() {
	PackedInt64Array out;
	out.resize(5);
	const stalag::WaterPlan *p = need_plan();
	for (int i = 0; i < 5; i++) out[i] = 0;
	if (p)
		for (uint8_t t : p->water_type) out[t]++;
	return out;
}
int64_t StalagWorld::water_dry_sentinel() { return stalag::WATER_DRY; }
int64_t StalagWorld::plan_dim() { return stalag::PLAN_DIM; }
int64_t StalagWorld::plan_g0() { return stalag::PLAN_G0; }

Dictionary StalagWorld::compare_plan_array(const String &p_name, const PackedByteArray &p_bytes) {
	Dictionary d;
	const stalag::WaterPlan *p = need_plan();
	d["name"] = p_name;
	if (!p) {
		d["error"] = "no plan";
		return d;
	}
	const String nm = p_name;
	int64_t n = 0, exact_mismatch = 0, over_tol = 0, bit_mismatch = 0;
	PackedInt64Array first_bad;
	double max_abs = 0;
	const uint8_t *raw = p_bytes.ptr();
	const int64_t nbytes = p_bytes.size();
	auto cmp_f64 = [&](const std::vector<double> &v) {
		n = (int64_t)v.size();
		if (nbytes != n * 8) {
			over_tol = n;
			exact_mismatch = n;
			return;
		}
		for (int64_t i = 0; i < n; i++) {
			double o;
			std::memcpy(&o, raw + i * 8, 8);
			const double g = v[i];
			if (std::memcmp(&o, &g, 8) != 0) {
				bit_mismatch++;
				if (first_bad.size() < 8) first_bad.push_back(i);
			}
			if (o == g) continue; // includes equal infinities
			exact_mismatch++;
			const double diff = std::fabs(o - g);
			if (std::isnan(diff) || diff > 1e-6) over_tol++;
			if (diff > max_abs || std::isnan(diff)) max_abs = std::isnan(diff) ? INFINITY : diff;
		}
	};
	auto cmp_f32 = [&](const std::vector<float> &v) {
		n = (int64_t)v.size();
		if (nbytes != n * 4) {
			over_tol = n;
			exact_mismatch = n;
			return;
		}
		for (int64_t i = 0; i < n; i++) {
			float o;
			std::memcpy(&o, raw + i * 4, 4);
			if (std::memcmp(&o, &v[i], 4) != 0) bit_mismatch++;
			if (o == v[i]) continue;
			exact_mismatch++;
			over_tol++;
			max_abs = std::max(max_abs, (double)std::fabs(o - v[i]));
		}
	};
	if (nm == "carve") cmp_f64(p->carve);
	else if (nm == "bedTargetLat") cmp_f64(p->bed_target_lat);
	else if (nm == "bankTargetLat") cmp_f64(p->bank_target_lat);
	else if (nm == "flowX") cmp_f32(p->flow_x);
	else if (nm == "flowZ") cmp_f32(p->flow_z);
	else if (nm == "waterTw") {
		n = (int64_t)p->water_tw.size();
		if (nbytes != n * 2) {
			exact_mismatch = n;
			over_tol = n;
		} else {
			for (int64_t i = 0; i < n; i++) {
				int16_t o;
				std::memcpy(&o, raw + i * 2, 2);
				if (o != p->water_tw[i]) {
					exact_mismatch++;
					over_tol++;
					max_abs = std::max(max_abs, (double)std::abs((int)o - (int)p->water_tw[i]));
				}
			}
		}
	} else if (nm == "waterType") {
		n = (int64_t)p->water_type.size();
		if (nbytes != n) {
			exact_mismatch = n;
			over_tol = n;
		} else {
			for (int64_t i = 0; i < n; i++) {
				if (raw[i] != p->water_type[i]) {
					exact_mismatch++;
					over_tol++;
					max_abs = std::max(max_abs, (double)std::abs((int)raw[i] - (int)p->water_type[i]));
				}
			}
		}
	} else {
		d["error"] = "unknown array";
		return d;
	}
	d["n"] = n;
	d["exact_mismatch"] = exact_mismatch;
	d["over_tol"] = over_tol;
	d["bit_mismatch"] = bit_mismatch;
	d["max_abs_diff"] = max_abs;
	d["first_bit_mismatch_index"] = first_bad;
	return d;
}

void StalagWorld::set_pad(double p_half_m, double p_blend_m) { stalag::set_pad_params(p_half_m, p_blend_m); }
double StalagWorld::pad_half_m() { return stalag::pad_half_m(); }
double StalagWorld::pad_blend_m() { return stalag::pad_blend_m(); }
double StalagWorld::surface_height(double p_cx, double p_cz) { return stalag::surface_height(p_cx, p_cz, stalag::WORLD_SEED, stalag::shared_plan()); }
double StalagWorld::carve_depth(double p_cx, double p_cz) { return stalag::carve_depth(p_cx, p_cz, stalag::WORLD_SEED, stalag::shared_plan()); }
int64_t StalagWorld::water_level_at(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	return p ? stalag::water_level_at(*p, (int32_t)p_gx, (int32_t)p_gz) : stalag::WATER_DRY;
}
bool StalagWorld::is_flooded(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	return p ? stalag::is_flooded(*p, (int32_t)p_gx, (int32_t)p_gz) : false;
}
int64_t StalagWorld::course_level_at(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	return p ? stalag::course_level_at(*p, (int32_t)p_gx, (int32_t)p_gz) : stalag::WATER_DRY;
}
Vector2 StalagWorld::get_flow_dir(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	double fx = 0, fz = 0;
	if (p && stalag::get_flow_dir(*p, (int32_t)p_gx, (int32_t)p_gz, fx, fz)) return Vector2((real_t)fx, (real_t)fz);
	return Vector2(0, 0);
}
int64_t StalagWorld::course_fall_top_at(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	return p ? stalag::course_fall_top_at(*p, (int32_t)p_gx, (int32_t)p_gz) : stalag::WATER_DRY;
}
bool StalagWorld::is_river_column(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	return p ? stalag::is_river_column(*p, (int32_t)p_gx, (int32_t)p_gz) : false;
}
int64_t StalagWorld::get_strahler_order(int64_t p_gx, int64_t p_gz) {
	const stalag::WaterPlan *p = need_plan();
	return p ? stalag::get_strahler_order(*p, (int32_t)p_gx, (int32_t)p_gz) : 0;
}

void StalagWorld::set_mutation(const String &p_name) {
	stalag::set_carve_disabled(p_name == "carve_off");
	stalag::set_flood_disabled(p_name == "flood_off");
}
