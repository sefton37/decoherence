#ifndef STALAG_CORE_H
#define STALAG_CORE_H

// Spec #501 -- pure C++ core of the Stalag engine module (no Godot types).

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "stalag_det.h"

namespace stalag {

struct WaterPlan; // stalag_plan.h

// Lattice units -> world metres (cell diameter 0.5 m / 4 lattice). The ONE definition
// of the scale in the whole new engine tree; GDScript reads it through StalagWorld.
constexpr double SF = 0.125;

// World seed 7: a game-policy choice (Spec #517 A3), not the prototype's own seed. The oracle
// (tools/baseline/js_world_oracle.mjs) uses the same value; the Spec #494 spike keeps its own.
constexpr int32_t WORLD_SEED = 7;
constexpr int32_t WORLD_EXTENT = 224; // index.html default; footprint +-(4*extent*SF) = +-112 m
constexpr double CHUNK_M = 28.0; // index.html CHUNK_M

// Triangle soup: 3 floats per vertex, 9 per triangle.
struct Soup {
	std::vector<float> pos, nrm, col;
	std::vector<double> tri_nrm; // 3 doubles per triangle: the un-rounded face normal (skin UVs)
	size_t tris() const { return pos.size() / 9; }
};

struct SurfaceMesh {
	Soup base;
	Soup caps;
};

// world-skin.js skinGeometry on a built surface: every triangle is classified grass or dirt
// and gets world-space UVs (tileWorld 0.5 m). Buckets carry float arrays for rendering;
// uv_q_sum is the order-independent parity checksum, summed in double from the same
// un-rounded values the prototype uses (sum over all vertices of floor(uv * 1e4 + 0.5)).
struct SkinBucket {
	std::vector<float> pos, nrm, uv, col;
	size_t tris() const { return pos.size() / 9; }
};
struct SkinnedSurface {
	SkinBucket grass, dirt;
	int64_t uv_q_sum[2] = { 0, 0 };
};
void skin_surface(const SurfaceMesh &in, int32_t seed, const WaterPlan *plan, SkinnedSurface &out);

// Region is [x_min, x_max) x [z_min, z_max) in world metres (cell-centre gate).
// Reentrant: no shared mutable state.
void build_surface(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, SurfaceMesh &out, const WaterPlan *plan);

// ---- hashing and noise (Spec #545: shared by the wind and flora ports)
double hash_cell(int32_t cx, int32_t cy, int32_t cz, int32_t seed); // worldmesh.js cellHash, [0, 1)
double noise_value(double x, double z, int32_t seed); // worldgen.js valueNoise, [0, 1)

// ---- world queries (carved by the shared plan, seed WORLD_SEED, unbounded footprint like isSolidWorld)
double surface_height_base(double cx, double cz, int32_t seed); // lattice units, pre-carve
double cliff_lift_at(double cx, double cz, int32_t seed); // worldmesh.js cliffLift
double surface_height_world(int32_t cx, int32_t cz); // surfaceHeight (carved, shared plan) for seed WORLD_SEED
bool is_solid_world(int32_t cx, int32_t cy, int32_t cz); // solid terrain or cap-interstitial cell
double ground_envelope_at(double fx, double fz, double max_surface); // centre-point ground height (m), -inf if none
double ground_floor(double fx, double fz, double max_surface); // footprint-sampled (max of 5 points)
bool blocked_between(double fx, double fz, double from_y, double to_y);

} // namespace stalag

#endif // STALAG_CORE_H
