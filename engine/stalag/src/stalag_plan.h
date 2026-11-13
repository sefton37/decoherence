#ifndef STALAG_PLAN_H
#define STALAG_PLAN_H

// Spec #517 -- the Stalag whole-world water plan (port of waterplan.js, hydrology.js,
// rivers.js, water-api.js, carve.js). Pure C++, no Godot types. The plan is solved once
// per seed, published immutable, and read concurrently by every chunk build.

#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace stalag {

// Lattice units per terrace step. The ONE definition (stalag_core.cpp and
// stalag_plan.cpp both include this header); the prototype hand-copied it into six modules.
constexpr int TERRACE_LAT = 4;

// The plan covers the production world in one solve: PLAN_DIM columns per side, column
// (0,0) of the domain at global column index PLAN_G0 (0.5 m columns, so +-224 m).
constexpr int PLAN_DIM = 896;
constexpr int PLAN_G0 = -448;

constexpr int TYPE_DRY = 0;
constexpr int TYPE_LAKE = 1;
constexpr int TYPE_RIVER = 2;
constexpr int TYPE_SPRING = 3;
constexpr int TYPE_FALL = 4;

constexpr int32_t WATER_DRY = -32768; // hydrology.js DRY: the not-flooded sentinel

// Game policy inside the solver (hazard H2): where water may NOT be. One labelled table;
// the values are the prototype's, unchanged (waterplan.js ASSET_DISCS, PATROL, MESA).
struct AssetDisc {
	double x, z, r;
};
struct AssetRect {
	double x0, x1, z0, z1;
};
const std::vector<AssetDisc> &asset_discs();
extern const AssetRect ASSET_PATROL;
extern const AssetRect ASSET_MESA;

struct PlanFall {
	int32_t gx, gz, tw_top, tw_bottom; // gx,gz = the RECEIVING column
};
struct PlanRiver {
	int32_t order;
	std::vector<int32_t> nodes; // domain column indices
};

struct WaterPlan {
	int32_t seed = 0;
	bool ok = false;
	std::string error; // set when the solve failed an invariant (ok == false)
	double solve_ms = 0;
	bool solved_off_caller = false; // the shared-plan solve ran on a worker, not the thread that asked
	std::vector<double> carve, bed_target_lat, bank_target_lat;
	std::vector<float> flow_x, flow_z;
	std::vector<int16_t> water_tw;
	std::vector<uint8_t> water_type;
	std::vector<PlanFall> falls;
	std::vector<PlanRiver> rivers;
	std::unordered_map<int32_t, int32_t> fall_top; // receiving column -> highest twTop
	std::unordered_map<int32_t, int32_t> course_order; // course node column -> highest order
};

inline int64_t plan_idx(int32_t gx, int32_t gz) { return (int64_t)(gz - PLAN_G0) * PLAN_DIM + (gx - PLAN_G0); }
inline bool plan_in_domain(int32_t gx, int32_t gz) {
	return gx >= PLAN_G0 && gz >= PLAN_G0 && gx < PLAN_G0 + PLAN_DIM && gz < PLAN_G0 + PLAN_DIM;
}

// Solve the plan for a seed (default dials) on the CALLING thread. Takes seconds.
// Never throws: a failed invariant leaves ok == false and error set.
void solve_plan(int32_t seed, WaterPlan &out);

// FNV-1a over the raw bytes of the seven arrays, hex (waterplan.js planHash).
std::string plan_hash(const WaterPlan &p);

// ---- the shared plan: published once, immutable afterwards (thread-safe reads).
// start_plan_solve launches the solve on a worker thread and returns at once.
void start_plan_solve(int32_t seed);
// 0 = never started, 1 = solving, 2 = ready, 3 = failed.
// Joins the worker thread (module unload). Idempotent.
void shutdown_plan();
int plan_status();
// Blocks until the solve ends (tests only; never call from the game's main thread).
void wait_plan_ready();
const WaterPlan *shared_plan(); // nullptr unless the status is ready
const WaterPlan *failed_plan(); // the failed record (error set) when the status is failed

// ---- carve (carve.js)
// Signed carve depth at a lattice address; 0 outside the domain or without a plan.
double carve_depth(double cx, double cz, int32_t seed, const WaterPlan *plan);
// surfaceHeight = surfaceHeightBase - carveDepth (worldmesh.js:116).
double surface_height(double cx, double cz, int32_t seed, const WaterPlan *plan);
// Test hook (mutation carve_off): carve queries return 0 while set.
void set_carve_disabled(bool off);
bool carve_disabled();

// ---- water-API (hydrology.js, rivers.js) on a plan
int32_t water_level_at(const WaterPlan &p, int32_t gx, int32_t gz); // LAKE|SPRING tw else WATER_DRY
bool is_flooded(const WaterPlan &p, int32_t gx, int32_t gz);
int32_t course_level_at(const WaterPlan &p, int32_t gx, int32_t gz); // RIVER|FALL tw else WATER_DRY
bool get_flow_dir(const WaterPlan &p, int32_t gx, int32_t gz, double &fx, double &fz);
int32_t course_fall_top_at(const WaterPlan &p, int32_t gx, int32_t gz);
bool is_river_column(const WaterPlan &p, int32_t gx, int32_t gz);
int32_t get_strahler_order(const WaterPlan &p, int32_t gx, int32_t gz);
// Spec 576: the homestead pad's half-width and blend width in metres (the game passes the template's).
void set_pad_params(double half_m, double blend_m);
double pad_half_m();
double pad_blend_m();
void set_flood_disabled(bool off); // test hook (mutation flood_off): water_level_at -> dry
bool flood_disabled();

} // namespace stalag

#endif // STALAG_PLAN_H
