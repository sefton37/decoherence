// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- C++ port of src/flower-placement.js and src/shrub-placement.js from the frozen Stalag
// prototype (tag prototype-final). See stalag_understory.h.

#include "stalag_understory.h"

#include "stalag_core.h"
#include "stalag_det.h"
#include "stalag_flora.h"
#include "stalag_plan.h"
#include "stalag_trees.h"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <mutex>
#include <unordered_map>

namespace stalag {

const char *const FLOWER_FORM_IDS[NUM_FLOWER_FORMS] = {
	"flower-spike-lupine", "flower-dot-forgetmenot", "flower-cushion-campion", "flower-sensor-bloom",
	"flower-spike-fireweed", "flower-cup-poppy", "flower-ray-arnica"
};
const char *const SHRUB_FORM_IDS[NUM_SHRUB_FORMS] = {
	"t1-mound-ramp", "t1-windlean-ramp", "t2-clump-cutout-huejitter", "t2-dome-cutout-ramp",
	"t3-crown-cutout-ramp", "t3-lowspread-cutout-ramp"
};

namespace {

constexpr double PI_ = 3.141592653589793;
constexpr double LID_JITTER = 0.15;
constexpr double PATCH_FREQ = 0.10;
constexpr double PATCH_FLOOR_REAL = 0.70;
constexpr double PATCH_FLOOR_LOW = 0.68; // flower_floor control
constexpr double PATCH_MAX_DENSITY = 0.45;
constexpr double MULTI_PROB = 0.35;
constexpr double TIER_FREQ = PATCH_FREQ / 3;
constexpr double TIER_VIVID_MIN = 0.65;
constexpr int SENSOR_SCORE_SALT = 900;
constexpr double SENSOR_MIN_GAP = 6.0;
constexpr double CLUSTER_R_GUARD = 3.5;
constexpr double FIREWEED_FREQ = 0.14;
constexpr double FIREWEED_FLOOR = 0.72;
constexpr double FIREWEED_MAX_DENSITY = 0.25;
// PATCH_SPECIES (lupine, forget-me-not, campion, poppy, arnica) as indices into FLOWER_FORM_IDS
constexpr int PATCH_SPECIES[5] = { 0, 1, 2, 5, 6 };
constexpr int FI_SENSOR = 3, FI_FIREWEED = 4;

constexpr double JITTER_MARGIN = 0.30;
constexpr double THICKET_FREQ = 0.05;
constexpr double THICKET_MIN = 0.30;
constexpr double THICKET_MAX_DENSITY = 0.30;
constexpr double TRUNK_BUCKET = 2.0;
// SHRUB_TABLE [id, weight] in the prototype's order, as indices into SHRUB_FORM_IDS
constexpr int SHRUB_TABLE_FORM[NUM_SHRUB_FORMS] = { 0, 1, 3, 2, 4, 5 };
constexpr int SHRUB_TABLE_W[NUM_SHRUB_FORMS] = { 24, 20, 14, 14, 8, 8 };
constexpr int SHRUB_TABLE_SUM = 88;

std::atomic<int> g_mut{ 0 };
std::mutex g_mx;
std::shared_ptr<const UnderstoryWorld> g_world;
int g_world_mut = -1, g_world_tree_mut = -1;

std::atomic<int64_t> g_builds{ 0 };
std::atomic<int64_t> g_builds_on_main{ 0 };
std::atomic<bool> g_enabled{ true };

inline int32_t xor_i32(int32_t a, uint32_t b) { return (int32_t)((uint32_t)a ^ b); }

struct OpenCand {
	int32_t cx, cz;
	double wx, wz, base_y, score;
};

double tier_n(double wx, double wz, int32_t seed) {
	return noise_value(wx * TIER_FREQ + 11, wz * TIER_FREQ + 5, xor_i32(seed, 0xB2001u));
}
int tier_at(double wx, double wz, int32_t seed) {
	const int t = tier_n(wx, wz, seed) >= TIER_VIVID_MIN ? 1 : 0;
	return g_mut.load() == 7 ? 1 - t : t; // tier_swap
}

void owner_and_val(double wx, double wz, int32_t seed, int &owner, double &val) {
	const double nL = noise_value(wx * PATCH_FREQ + 11, wz * PATCH_FREQ + 5, xor_i32(seed, 0xA1001u));
	const double nF = noise_value(wx * PATCH_FREQ + 23, wz * PATCH_FREQ + 17, xor_i32(seed, 0xA1002u));
	const double nC = noise_value(wx * PATCH_FREQ + 37, wz * PATCH_FREQ + 29, xor_i32(seed, 0xA1003u));
	const double nP = noise_value(wx * PATCH_FREQ + 43, wz * PATCH_FREQ + 41, xor_i32(seed, 0xA1004u));
	const double nA = noise_value(wx * PATCH_FREQ + 53, wz * PATCH_FREQ + 47, xor_i32(seed, 0xA1005u));
	owner = PATCH_SPECIES[0];
	val = nL;
	if (nF > val) { owner = PATCH_SPECIES[1]; val = nF; }
	if (nC > val) { owner = PATCH_SPECIES[2]; val = nC; }
	if (nP > val) { owner = PATCH_SPECIES[3]; val = nP; }
	if (nA > val) { owner = PATCH_SPECIES[4]; val = nA; }
}

int pick_shrub(double r) {
	double a = r * SHRUB_TABLE_SUM;
	for (int i = 0; i < NUM_SHRUB_FORMS; i++) {
		a -= SHRUB_TABLE_W[i];
		if (a < 0) return SHRUB_TABLE_FORM[i];
	}
	return SHRUB_TABLE_FORM[NUM_SHRUB_FORMS - 1];
}

std::shared_ptr<const UnderstoryWorld> compute_world() {
	const WaterPlan *plan = shared_plan();
	if (!plan) return nullptr;
	const int32_t seed = WORLD_SEED, extent = WORLD_EXTENT;
	const int mut = g_mut.load();
	auto w = std::make_shared<UnderstoryWorld>();

	std::vector<Lid> lids;
	list_lids_region(seed, extent, -1e9, 1e9, -1e9, 1e9, lids, false);

	// ---------------------------------------------------------------- wildflowers
	const double patch_floor = mut == 1 ? PATCH_FLOOR_LOW : PATCH_FLOOR_REAL;
	const int sensor_target = std::max(1, (int)std::floor((double)extent / 20 + 0.5)); // Math.round
	std::vector<OpenCand> open;
	for (const Lid &lid : lids) {
		const int32_t cx = lid.cx, cz = lid.cz;
		const double wx = (cx + 2) * SF, wz = (cz + 2) * SF;
		const double base_y = (lid.H + 2) * SF;
		const int32_t gx = (int32_t)std::floor(wx / 0.5), gz = (int32_t)std::floor(wz / 0.5);
		if (is_flooded(*plan, gx, gz) || course_level_at(*plan, gx, gz) != WATER_DRY) continue;
		int owner;
		double val;
		owner_and_val(wx, wz, seed, owner, val);
		if (val >= patch_floor) {
			const double density = PATCH_MAX_DENSITY * std::min(1.0, (val - patch_floor) / (1 - patch_floor));
			if (hash_cell(cx, 500, cz, seed) < density) {
				const int n = 1 + (hash_cell(cx, 501, cz, seed) < MULTI_PROB ? 1 : 0);
				const int tier = tier_at(wx, wz, seed);
				for (int k = 0; k < n; k++) {
					const double jx = (hash_cell(cx, 510 + k, cz, seed) - 0.5) * (2 * LID_JITTER);
					const double jz = (hash_cell(cx, 520 + k, cz, seed) - 0.5) * (2 * LID_JITTER);
					const double yaw = hash_cell(cx, 530 + k, cz, seed) * PI_ * 2;
					const double scale = 0.85 + hash_cell(cx, 540 + k, cz, seed) * 0.30;
					w->flowers[owner].push_back(FlowerInstance{ wx + jx, base_y, wz + jz, yaw, scale, wx, wz, tier, n });
				}
			}
		} else {
			const double fw = noise_value(wx * FIREWEED_FREQ + 61, wz * FIREWEED_FREQ + 59, xor_i32(seed, 0xA1006u));
			bool placed = false;
			if (fw >= FIREWEED_FLOOR) {
				const double density = FIREWEED_MAX_DENSITY * std::min(1.0, (fw - FIREWEED_FLOOR) / (1 - FIREWEED_FLOOR));
				if (hash_cell(cx, 800, cz, seed) < density) {
					const int tier = tier_at(wx, wz, seed);
					const double jx = (hash_cell(cx, 810, cz, seed) - 0.5) * (2 * LID_JITTER);
					const double jz = (hash_cell(cx, 820, cz, seed) - 0.5) * (2 * LID_JITTER);
					const double yaw = hash_cell(cx, 830, cz, seed) * PI_ * 2;
					const double scale = 0.85 + hash_cell(cx, 840, cz, seed) * 0.30;
					w->flowers[FI_FIREWEED].push_back(FlowerInstance{ wx + jx, base_y, wz + jz, yaw, scale, wx, wz, tier, 1 });
					placed = true;
				}
			}
			if (!placed) open.push_back(OpenCand{ cx, cz, wx, wz, base_y, hash_cell(cx, SENSOR_SCORE_SALT, cz, seed) });
		}
	}

	// sensor bloom: greedy min-gap pick over the score-sorted pool (stable, like Array.prototype.sort).
	// sensor_gap_off drops the gap test and the sort, so the first open lids in walk order are taken.
	std::vector<OpenCand> pool = open;
	if (mut != 2) std::stable_sort(pool.begin(), pool.end(), [](const OpenCand &a, const OpenCand &b) { return a.score > b.score; });
	std::vector<OpenCand> sensors;
	std::unordered_set<int64_t> used;
	for (const OpenCand &cand : pool) {
		if ((int)sensors.size() >= sensor_target) break;
		bool ok = true;
		if (mut != 2) {
			for (const OpenCand &s : sensors) {
				if (!(det_hypot(s.wx - cand.wx, s.wz - cand.wz) >= SENSOR_MIN_GAP)) {
					ok = false;
					break;
				}
			}
		}
		if (!ok) continue;
		sensors.push_back(cand);
		used.insert(((int64_t)cand.cx << 32) ^ (int64_t)(uint32_t)cand.cz);
		const double yaw = hash_cell(cand.cx, 600, cand.cz, seed) * PI_ * 2;
		const double scale = 0.85 + hash_cell(cand.cx, 601, cand.cz, seed) * 0.30;
		int tier = hash_cell(cand.cx, 602, cand.cz, seed) < 0.5 ? 1 : 0;
		if (mut == 7) tier = 1 - tier;
		w->flowers[FI_SENSOR].push_back(FlowerInstance{ cand.wx, cand.base_y, cand.wz, yaw, scale, cand.wx, cand.wz, tier, 1 });
	}

	// the guaranteed lone instance
	const int lone = PATCH_SPECIES[(int)std::floor(hash_cell(0, 700, 0, seed) * 5)];
	for (const OpenCand &cand : open) {
		if (used.count(((int64_t)cand.cx << 32) ^ (int64_t)(uint32_t)cand.cz)) continue;
		bool far_enough = true;
		for (const FlowerInstance &in : w->flowers[lone]) {
			if (!(det_hypot(in.x - cand.wx, in.z - cand.wz) > CLUSTER_R_GUARD)) {
				far_enough = false;
				break;
			}
		}
		if (far_enough) {
			const double yaw = hash_cell(cand.cx, 610, cand.cz, seed) * PI_ * 2;
			const double scale = 0.85 + hash_cell(cand.cx, 611, cand.cz, seed) * 0.30;
			const int tier = tier_at(cand.wx, cand.wz, seed);
			w->flowers[lone].push_back(FlowerInstance{ cand.wx, cand.base_y, cand.wz, yaw, scale, cand.wx, cand.wz, tier, 1 });
			break;
		}
	}
	for (int f = 0; f < NUM_FLOWER_FORMS; f++)
		for (const FlowerInstance &in : w->flowers[f]) w->flower_lids.insert(lid_key(in.lid_x, in.lid_z));

	// ---------------------------------------------------------------- shrubs
	std::vector<TreeInstance> trees[NUM_TREE_FORMS];
	place_trees_region(seed, extent, -1e9, 1e9, -1e9, 1e9, trees);
	std::unordered_map<int64_t, std::vector<std::pair<double, double>>> buckets;
	auto bkey = [](int64_t bx, int64_t bz) { return (bx << 32) ^ (bz & 0xffffffffLL); };
	for (int f = 0; f < NUM_TREE_FORMS; f++)
		for (const TreeInstance &t : trees[f])
			buckets[bkey((int64_t)std::floor(t.x / TRUNK_BUCKET), (int64_t)std::floor(t.z / TRUNK_BUCKET))].push_back({ t.x, t.z });
	auto near_any_tree = [&](double wx, double wz, double threshold) {
		const int64_t bx = (int64_t)std::floor(wx / TRUNK_BUCKET), bz = (int64_t)std::floor(wz / TRUNK_BUCKET);
		for (int64_t dx = -1; dx <= 1; dx++) {
			for (int64_t dz = -1; dz <= 1; dz++) {
				auto it = buckets.find(bkey(bx + dx, bz + dz));
				if (it == buckets.end()) continue;
				for (const auto &t : it->second)
					if (det_hypot(wx - t.first, wz - t.second) < threshold) return true;
			}
		}
		return false;
	};
	for (const Lid &lid : lids) {
		const int32_t cx = lid.cx, cz = lid.cz;
		const double wx = (cx + 2) * SF, wz = (cz + 2) * SF;
		const double base_y = (lid.H + 2) * SF;
		const int32_t gx = (int32_t)std::floor(wx / 0.5), gz = (int32_t)std::floor(wz / 0.5);
		if (is_flooded(*plan, gx, gz) || course_level_at(*plan, gx, gz) != WATER_DRY) continue;
		if (det_hypot(wx, wz) < SHRUB_SPAWN_CLEARING + JITTER_MARGIN) continue;
		if (mut != 3 && near_any_tree(wx, wz, MIN_TRUNK_DIST + JITTER_MARGIN)) continue;
		if (mut != 4 && w->flower_lids.count(lid_key(wx, wz))) continue;
		const double thicket = noise_value(wx * THICKET_FREQ + 19, wz * THICKET_FREQ + 13, xor_i32(seed, 1000u));
		if (thicket < THICKET_MIN) continue;
		const double density = THICKET_MAX_DENSITY * std::min(1.0, (thicket - THICKET_MIN) / (1 - THICKET_MIN));
		if (hash_cell(cx, 1001, cz, seed) >= density) continue;
		const int sp = pick_shrub(hash_cell(cx, 1002, cz, seed));
		const double yaw = hash_cell(cx, 1003, cz, seed) * PI_ * 2;
		const double jx = (hash_cell(cx, 1004, cz, seed) - 0.5) * (2 * LID_JITTER);
		const double jz = (hash_cell(cx, 1005, cz, seed) - 0.5) * (2 * LID_JITTER);
		const double scale = 0.85 + hash_cell(cx, 1006, cz, seed) * 0.30;
		w->shrubs[sp].push_back(ShrubInstance{ wx + jx, base_y, wz + jz, yaw, scale, wx, wz });
	}
	for (int f = 0; f < NUM_SHRUB_FORMS; f++)
		for (const ShrubInstance &in : w->shrubs[f]) w->shrub_lids.insert(lid_key(in.lid_x, in.lid_z));
	return w;
}

} // namespace

int64_t lid_key(double lid_x, double lid_z) {
	const int64_t a = (int64_t)std::llround(lid_x / SF), b = (int64_t)std::llround(lid_z / SF);
	return ((a + (1 << 20)) << 32) | (b + (1 << 20));
}

void set_understory_mutation(int m) {
	std::lock_guard<std::mutex> lock(g_mx);
	g_mut.store(m);
	g_world.reset();
}
int understory_mutation() { return g_mut.load(); }

std::shared_ptr<const UnderstoryWorld> understory_world() {
	std::lock_guard<std::mutex> lock(g_mx);
	const int mut = g_mut.load(), tmut = tree_mutation();
	if (g_world && g_world_mut == mut && g_world_tree_mut == tmut) return g_world;
	g_world = compute_world();
	g_world_mut = mut;
	g_world_tree_mut = tmut;
	return g_world;
}

bool meadow_thinned(int form, double lid_x, double lid_z) {
	const int mut = g_mut.load();
	if (mut == 5) return false; // thin_off
	if (form >= 3 && mut != 6) return false; // only the three grass forms (thin_all: every form)
	auto w = understory_world();
	if (!w) return false;
	const int64_t k = lid_key(lid_x, lid_z);
	return w->flower_lids.count(k) > 0 || w->shrub_lids.count(k) > 0;
}

} // namespace stalag

namespace godot {

void StalagUnderstory::_bind_methods() {
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("flower_ids"), &StalagUnderstory::flower_ids);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("shrub_ids"), &StalagUnderstory::shrub_ids);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("flowers_global"), &StalagUnderstory::flowers_global);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("shrubs_global"), &StalagUnderstory::shrubs_global);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("flowers_chunk", "cx", "cz"), &StalagUnderstory::flowers_chunk);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("shrubs_chunk", "cx", "cz"), &StalagUnderstory::shrubs_chunk);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("build_chunk_understory", "cx", "cz"), &StalagUnderstory::build_chunk_understory);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("get_build_stats"), &StalagUnderstory::get_build_stats);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("reset_build_stats"), &StalagUnderstory::reset_build_stats);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("set_enabled", "on"), &StalagUnderstory::set_enabled);
	ClassDB::bind_static_method("StalagUnderstory", D_METHOD("set_mutation", "name"), &StalagUnderstory::set_mutation);
}

PackedStringArray StalagUnderstory::flower_ids() {
	PackedStringArray a;
	for (int f = 0; f < stalag::NUM_FLOWER_FORMS; f++) a.push_back(String(stalag::FLOWER_FORM_IDS[f]));
	return a;
}

PackedStringArray StalagUnderstory::shrub_ids() {
	PackedStringArray a;
	for (int f = 0; f < stalag::NUM_SHRUB_FORMS; f++) a.push_back(String(stalag::SHRUB_FORM_IDS[f]));
	return a;
}

static bool in_region(double lx, double lz, double x0, double x1, double z0, double z1) {
	return lx >= x0 && lx < x1 && lz >= z0 && lz < z1;
}

static Dictionary pack_flowers(const stalag::UnderstoryWorld &w, double x0, double x1, double z0, double z1) {
	Dictionary d;
	for (int f = 0; f < stalag::NUM_FLOWER_FORMS; f++) {
		PackedFloat64Array a;
		for (const stalag::FlowerInstance &in : w.flowers[f]) {
			if (!in_region(in.lid_x, in.lid_z, x0, x1, z0, z1)) continue;
			const double v[9] = { in.x, in.y, in.z, in.yaw, in.scale, in.lid_x, in.lid_z, (double)in.tier, (double)in.count };
			for (int j = 0; j < 9; j++) a.push_back(v[j]);
		}
		d[String(stalag::FLOWER_FORM_IDS[f])] = a;
	}
	d["_lid_keys"] = (int64_t)w.flower_lids.size();
	return d;
}

static Dictionary pack_shrubs(const stalag::UnderstoryWorld &w, double x0, double x1, double z0, double z1) {
	Dictionary d;
	for (int f = 0; f < stalag::NUM_SHRUB_FORMS; f++) {
		PackedFloat64Array a;
		for (const stalag::ShrubInstance &in : w.shrubs[f]) {
			if (!in_region(in.lid_x, in.lid_z, x0, x1, z0, z1)) continue;
			const double v[7] = { in.x, in.y, in.z, in.yaw, in.scale, in.lid_x, in.lid_z };
			for (int j = 0; j < 7; j++) a.push_back(v[j]);
		}
		d[String(stalag::SHRUB_FORM_IDS[f])] = a;
	}
	d["_lid_keys"] = (int64_t)w.shrub_lids.size();
	return d;
}

Dictionary StalagUnderstory::flowers_global() {
	auto w = stalag::understory_world();
	return w ? pack_flowers(*w, -1e18, 1e18, -1e18, 1e18) : Dictionary();
}

Dictionary StalagUnderstory::shrubs_global() {
	auto w = stalag::understory_world();
	return w ? pack_shrubs(*w, -1e18, 1e18, -1e18, 1e18) : Dictionary();
}

Dictionary StalagUnderstory::flowers_chunk(int64_t p_cx, int64_t p_cz) {
	auto w = stalag::understory_world();
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	return w ? pack_flowers(*w, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M) : Dictionary();
}

Dictionary StalagUnderstory::shrubs_chunk(int64_t p_cx, int64_t p_cz) {
	auto w = stalag::understory_world();
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	return w ? pack_shrubs(*w, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M) : Dictionary();
}

// Yaw about +Y, uniform scale; rows of [basis | origin] (the layout stalag_flora.cpp uses).
static void yaw_matrix(double x, double y, double z, double yaw, double scale, double x0, double z0, float *w) {
	const float c = (float)(stalag::det_cos(yaw) * scale), s = (float)(stalag::det_sin(yaw) * scale);
	w[0] = c; w[1] = 0; w[2] = s; w[3] = (float)(x - x0);
	w[4] = 0; w[5] = (float)scale; w[6] = 0; w[7] = (float)y;
	w[8] = -s; w[9] = 0; w[10] = c; w[11] = (float)(z - z0);
}

Dictionary StalagUnderstory::build_chunk_understory(int64_t p_cx, int64_t p_cz) {
	if (!stalag::g_enabled.load()) return Dictionary();
	stalag::g_builds++;
	OS *os = OS::get_singleton();
	if (os && os->get_thread_caller_id() == os->get_main_thread_id()) stalag::g_builds_on_main++;
	auto w = stalag::understory_world();
	Dictionary res;
	if (!w) return res;
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	const double x1 = x0 + stalag::CHUNK_M, z1 = z0 + stalag::CHUNK_M;
	// Spec #551: instances standing on a blocked ground column (mud, sand) are dropped, by their own position.
	const std::shared_ptr<const stalag::GroundMask> mask = stalag::ground_mask();
	auto emit = [&](const String &key, const std::vector<std::array<double, 5>> &list) {
		if (list.empty()) return;
		PackedFloat32Array buf;
		buf.resize((int64_t)list.size() * 12);
		float *p = buf.ptrw();
		for (const auto &a : list) {
			yaw_matrix(a[0], a[1], a[2], a[3], a[4], x0, z0, p);
			p += 12;
		}
		Dictionary e;
		e["count"] = (int64_t)list.size();
		e["buffer"] = buf;
		res[key] = e;
	};
	for (int f = 0; f < stalag::NUM_FLOWER_FORMS; f++) {
		for (int tier = 0; tier < 2; tier++) {
			std::vector<std::array<double, 5>> list;
			for (const stalag::FlowerInstance &in : w->flowers[f])
				if (in.tier == tier && in_region(in.lid_x, in.lid_z, x0, x1, z0, z1) && !stalag::ground_blocked(mask.get(), in.x, in.z)) list.push_back({ in.x, in.y, in.z, in.yaw, in.scale });
			emit(String(stalag::FLOWER_FORM_IDS[f]) + (tier ? "/vivid" : "/muted"), list);
		}
	}
	for (int f = 0; f < stalag::NUM_SHRUB_FORMS; f++) {
		std::vector<std::array<double, 5>> list;
		for (const stalag::ShrubInstance &in : w->shrubs[f])
			if (in_region(in.lid_x, in.lid_z, x0, x1, z0, z1) && !stalag::ground_blocked(mask.get(), in.x, in.z)) list.push_back({ in.x, in.y, in.z, in.yaw, in.scale });
		emit(String(stalag::SHRUB_FORM_IDS[f]), list);
	}
	return res;
}

Dictionary StalagUnderstory::get_build_stats() {
	Dictionary d;
	d["builds"] = (int64_t)stalag::g_builds.load();
	d["on_main_thread"] = (int64_t)stalag::g_builds_on_main.load();
	return d;
}

void StalagUnderstory::reset_build_stats() {
	stalag::g_builds = 0;
	stalag::g_builds_on_main = 0;
}

void StalagUnderstory::set_enabled(bool p_on) { stalag::g_enabled.store(p_on); }

void StalagUnderstory::set_mutation(const String &p_name) {
	int m = 0;
	if (p_name == "flower_floor") m = 1;
	else if (p_name == "sensor_gap_off") m = 2;
	else if (p_name == "trunk_gate_off") m = 3;
	else if (p_name == "flower_gate_off") m = 4;
	else if (p_name == "thin_off") m = 5;
	else if (p_name == "thin_all") m = 6;
	else if (p_name == "tier_swap") m = 7;
	stalag::set_understory_mutation(m);
}

} // namespace godot
