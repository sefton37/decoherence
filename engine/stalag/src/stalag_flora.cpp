// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545 -- C++ port of src/foliage-placement.js from the frozen Stalag prototype (tag prototype-final).
// See stalag_flora.h.

#include "stalag_flora.h"

#include "stalag_core.h"
#include "stalag_det.h"
#include "stalag_plan.h"
#include "stalag_understory.h"

#include <godot_cpp/variant/string.hpp>

#include <godot_cpp/classes/os.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>

namespace stalag {

const char *const FORM_IDS[NUM_FORMS] = {
	"tuft-billboard-baseline", "tuft-billboard-bladed", "cover-billboard-creep",
	"fern-billboard-frond", "fern-billboard-mirror", "shrub-billboard-lump",
	"rock-pebbles", "rock-cobble", "rock-boulder", "rock-outcrop"
};

namespace {

constexpr double PI_ = 3.141592653589793; // Math.PI
constexpr int TERRACE_LAT = 4;
constexpr double LID_JITTER = 0.15;
// SELECTED_FORMS indices of the groups
constexpr int GRASS_FORMS[3] = { 0, 1, 2 };
constexpr int FERNSHRUB_FORMS[3] = { 3, 4, 5 };
constexpr int ROCK_FORMS[4] = { 6, 7, 8, 9 };

std::atomic<int> g_mut{ 0 };
std::mutex g_mask_mutex;
std::shared_ptr<const GroundMask> g_mask;

inline int32_t xor_i32(int32_t a, uint32_t b) { return (int32_t)((uint32_t)a ^ b); }

inline double hTat(int32_t cx, int32_t cz, int32_t seed, const WaterPlan *plan) {
	return std::floor(surface_height(cx, cz, seed, plan) / TERRACE_LAT) * TERRACE_LAT;
}

FloraInstance make_instance(int32_t cx, int32_t cz, double wx, double wz, double base_y, int32_t seed, int salt) {
	int sx = salt, sz = salt + 1;
	if (g_mut.load() == 3) {
		sx = salt + 1;
		sz = salt;
	}
	const double jx = (hash_cell(cx, sx, cz, seed) - 0.5) * (2 * LID_JITTER);
	const double jz = (hash_cell(cx, sz, cz, seed) - 0.5) * (2 * LID_JITTER);
	const double yaw = hash_cell(cx, salt + 2, cz, seed) * PI_ * 2;
	const double scale = 0.85 + hash_cell(cx, salt + 3, cz, seed) * 0.30;
	return FloraInstance{ wx + jx, base_y, wz + jz, yaw, scale, wx, wz };
}

} // namespace

void set_flora_mutation(int m) { g_mut.store(m); }

void set_ground_mask(std::shared_ptr<const GroundMask> mask) {
	std::lock_guard<std::mutex> lock(g_mask_mutex);
	g_mask = std::move(mask);
}

std::shared_ptr<const GroundMask> ground_mask() {
	std::lock_guard<std::mutex> lock(g_mask_mutex);
	return g_mask;
}

bool ground_blocked(const GroundMask *mask, double x, double z) {
	if (!mask || mask->dim <= 0) return false;
	const int64_t gx = (int64_t)std::floor(x / 0.5) + mask->g0, gz = (int64_t)std::floor(z / 0.5) + mask->g0;
	if (gx < 0 || gz < 0 || gx >= mask->dim || gz >= mask->dim) return false;
	return mask->bits[(size_t)(gz * mask->dim + gx)] != 0;
}

void place_flora_region(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, std::vector<FloraInstance> out[NUM_FORMS], int64_t *lid_count) {
	for (int f = 0; f < NUM_FORMS; f++) out[f].clear();
	if (lid_count) *lid_count = 0;
	const WaterPlan *plan = shared_plan();
	if (!plan) return;
	const double floor_half = 4 * extent * SF;
	auto in_foot = [&](double x, double z) { return std::fabs(x * SF) <= floor_half + 1e-9 && std::fabs(z * SF) <= floor_half + 1e-9; };
	const int mut = g_mut.load();
	// Anchor rows: lid centre z = (2k * 2 + 2) * SF, so bound k loosely and filter exactly below.
	const bool all_z = !(z_min > -1e8 && z_max < 1e8);
	const bool all_x = !(x_min > -1e8 && x_max < 1e8);
	int32_t k_lo = -2 * extent, k_hi = 2 * extent;
	if (!all_z) {
		k_lo = std::max(k_lo, (int32_t)std::floor((z_min / SF - 2) / 2) - 1);
		k_hi = std::min(k_hi, (int32_t)std::ceil((z_max / SF - 2) / 2) + 1);
	}
	if (((k_lo % 2) + 2) % 2 != 0) k_lo++;
	for (int32_t k = k_lo; k <= k_hi; k += 2) {
		const int32_t cz = 2 * k;
		const double wz = (cz + 2) * SF;
		if (!all_z && !(wz >= z_min && wz < z_max)) continue;
		int32_t i_lo = -2 * extent, i_hi = 2 * extent;
		if (!all_x) {
			i_lo = std::max(i_lo, (int32_t)std::floor((x_min / SF - 2 - 2 * k) / 4) - 1);
			i_hi = std::min(i_hi, (int32_t)std::ceil((x_max / SF - 2 - 2 * k) / 4) + 1);
		}
		for (int32_t i = i_lo; i <= i_hi; i++) {
			const int32_t cx = 4 * i + 2 * k;
			const double wx = (cx + 2) * SF;
			if (!all_x && !(wx >= x_min && wx < x_max)) continue;
			if (!in_foot(cx, cz)) continue;
			const double H = hTat(cx, cz, seed, plan);
			bool ok = true;
			static const int D_REAL[4][2] = { { 4, 0 }, { 0, 4 }, { 4, 4 }, { 2, 2 } };
			static const int D_SHIFT[4][2] = { { 4, 0 }, { 0, 4 }, { 4, 4 }, { 2, 3 } };
			const int(*D)[2] = mut == 1 ? D_SHIFT : D_REAL;
			for (int d = 0; d < 4; d++) {
				if (!in_foot(cx + D[d][0], cz + D[d][1]) || hTat(cx + D[d][0], cz + D[d][1], seed, plan) != H) {
					ok = false;
					break;
				}
			}
			if (!ok) continue;
			if (lid_count) (*lid_count)++;
			const double base_y = (H + 2) * SF;
			const int32_t gx = (int32_t)std::floor(wx / 0.5), gz = (int32_t)std::floor(wz / 0.5);
			if (mut != 2 && (is_flooded(*plan, gx, gz) || course_level_at(*plan, gx, gz) != WATER_DRY)) continue;
			const double meadow = noise_value(wx * 0.07 + 3, wz * 0.07 + 7, xor_i32(seed, 0x5f3759dfu));
			if (meadow > 0.33) {
				const int n = 1 + (int)std::floor(hash_cell(cx, 1, cz, seed) * 3);
				for (int g = 0; g < n; g++) {
					const int form = GRASS_FORMS[(int)std::floor(hash_cell(cx, 10 + g, cz, seed) * 3)];
					out[form].push_back(make_instance(cx, cz, wx, wz, base_y, seed, 100 + g * 10));
				}
			}
			if (hash_cell(cx, 5, cz, seed) < 0.10) {
				const int form = FERNSHRUB_FORMS[(int)std::floor(hash_cell(cx, 6, cz, seed) * 3)];
				out[form].push_back(make_instance(cx, cz, wx, wz, base_y, seed, 200));
			}
			if (hash_cell(cx, 8, cz, seed) < 0.08) {
				const int form = ROCK_FORMS[(int)std::floor(hash_cell(cx, 9, cz, seed) * 4)];
				out[form].push_back(make_instance(cx, cz, wx, wz, base_y, seed, 300));
			}
		}
	}
}

} // namespace stalag

namespace {
std::atomic<int64_t> g_builds{ 0 };
std::atomic<int64_t> g_builds_on_main{ 0 };
std::atomic<bool> g_enabled{ true };
} // namespace

namespace godot {

void StalagFlora::_bind_methods() {
	ClassDB::bind_static_method("StalagFlora", D_METHOD("get_build_stats"), &StalagFlora::get_build_stats);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("reset_build_stats"), &StalagFlora::reset_build_stats);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("form_ids"), &StalagFlora::form_ids);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("place_global"), &StalagFlora::place_global);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("place_chunk", "cx", "cz"), &StalagFlora::place_chunk);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("build_chunk_flora", "cx", "cz"), &StalagFlora::build_chunk_flora);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("set_mutation", "name"), &StalagFlora::set_mutation);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("set_enabled", "on"), &StalagFlora::set_enabled);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("set_ground_mask", "mask", "dim", "g0"), &StalagFlora::set_ground_mask);
	ClassDB::bind_static_method("StalagFlora", D_METHOD("ground_mask_info"), &StalagFlora::ground_mask_info);
}

PackedStringArray StalagFlora::form_ids() {
	PackedStringArray a;
	for (int f = 0; f < stalag::NUM_FORMS; f++) a.push_back(String(stalag::FORM_IDS[f]));
	return a;
}

static Dictionary pack_f64(const std::vector<stalag::FloraInstance> out[stalag::NUM_FORMS], int64_t lids) {
	Dictionary d;
	for (int f = 0; f < stalag::NUM_FORMS; f++) {
		PackedFloat64Array a;
		a.resize((int64_t)out[f].size() * 7);
		int64_t at = 0;
		for (const stalag::FloraInstance &it : out[f]) {
			a[at++] = it.x;
			a[at++] = it.y;
			a[at++] = it.z;
			a[at++] = it.yaw;
			a[at++] = it.scale;
			a[at++] = it.lid_x;
			a[at++] = it.lid_z;
		}
		d[String(stalag::FORM_IDS[f])] = a;
	}
	d["_lids"] = lids;
	return d;
}

Dictionary StalagFlora::place_global() {
	std::vector<stalag::FloraInstance> out[stalag::NUM_FORMS];
	int64_t lids = 0;
	stalag::place_flora_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, -1e9, 1e9, -1e9, 1e9, out, &lids);
	return pack_f64(out, lids);
}

Dictionary StalagFlora::place_chunk(int64_t p_cx, int64_t p_cz) {
	std::vector<stalag::FloraInstance> out[stalag::NUM_FORMS];
	int64_t lids = 0;
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::place_flora_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, out, &lids);
	return pack_f64(out, lids);
}

Dictionary StalagFlora::get_build_stats() {
	Dictionary d;
	d["builds"] = (int64_t)g_builds.load();
	d["on_main_thread"] = (int64_t)g_builds_on_main.load();
	return d;
}

void StalagFlora::reset_build_stats() {
	g_builds = 0;
	g_builds_on_main = 0;
}

void StalagFlora::set_enabled(bool p_on) { g_enabled.store(p_on); }

Dictionary StalagFlora::build_chunk_flora(int64_t p_cx, int64_t p_cz) {
	if (!g_enabled.load()) return Dictionary();
	g_builds++;
	OS *os = OS::get_singleton();
	if (os && os->get_thread_caller_id() == os->get_main_thread_id()) g_builds_on_main++;
	std::vector<stalag::FloraInstance> out[stalag::NUM_FORMS];
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::place_flora_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, out, nullptr);
	// Spec #549: the grass forms are dropped on every lid that holds a wildflower or a shrub
	// (index.html GRASS_FOLIAGE_IDS thinning); place_global stays the raw, unthinned placement.
	// Spec #551: then every instance standing on a blocked ground column (mud, sand) is dropped, by the
	// instance's own position; the thinning above keys on the lid and is unaffected.
	const std::shared_ptr<const stalag::GroundMask> mask = stalag::ground_mask();
	for (int f = 0; f < stalag::NUM_FORMS; f++) {
		std::vector<stalag::FloraInstance> &v = out[f];
		v.erase(std::remove_if(v.begin(), v.end(), [f, &mask](const stalag::FloraInstance &it) {
			return stalag::meadow_thinned(f, it.lid_x, it.lid_z) || stalag::ground_blocked(mask.get(), it.x, it.z);
		}), v.end());
	}
	Dictionary res;
	for (int f = 0; f < stalag::NUM_FORMS; f++) {
		if (out[f].empty()) continue;
		PackedFloat32Array buf;
		buf.resize((int64_t)out[f].size() * 12);
		float *w = buf.ptrw();
		for (const stalag::FloraInstance &it : out[f]) {
			// Rotation about +Y by yaw (three.js rotation.y), uniform scale; rows of [basis | origin].
			const float c = (float)(stalag::det_cos(it.yaw) * it.scale), s = (float)(stalag::det_sin(it.yaw) * it.scale);
			w[0] = c; w[1] = 0; w[2] = s; w[3] = (float)(it.x - x0);
			w[4] = 0; w[5] = (float)it.scale; w[6] = 0; w[7] = (float)it.y;
			w[8] = -s; w[9] = 0; w[10] = c; w[11] = (float)(it.z - z0);
			w += 12;
		}
		Dictionary e;
		e["count"] = (int64_t)out[f].size();
		e["buffer"] = buf;
		res[String(stalag::FORM_IDS[f])] = e;
	}
	return res;
}

void StalagFlora::set_ground_mask(const PackedByteArray &p_mask, int64_t p_dim, int64_t p_g0) {
	if (p_mask.size() == 0 || p_dim <= 0 || p_mask.size() != p_dim * p_dim) {
		stalag::set_ground_mask(nullptr);
		return;
	}
	auto m = std::make_shared<stalag::GroundMask>();
	m->dim = (int)p_dim;
	m->g0 = (int)p_g0;
	m->bits.assign(p_mask.ptr(), p_mask.ptr() + p_mask.size());
	stalag::set_ground_mask(m);
}

Dictionary StalagFlora::ground_mask_info() {
	Dictionary d;
	const std::shared_ptr<const stalag::GroundMask> m = stalag::ground_mask();
	int64_t blocked = 0;
	if (m) for (uint8_t b : m->bits) blocked += b != 0;
	d["installed"] = (bool)m;
	d["dim"] = (int64_t)(m ? m->dim : 0);
	d["g0"] = (int64_t)(m ? m->g0 : 0);
	d["blocked"] = blocked;
	return d;
}

void StalagFlora::set_mutation(const String &p_name) {
	int m = 0;
	if (p_name == "lid_shift") m = 1;
	else if (p_name == "flood_ignore") m = 2;
	else if (p_name == "salt_swap") m = 3;
	stalag::set_flora_mutation(m);
}

} // namespace godot
