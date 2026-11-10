// Spec #501 -- the Stalag engine core: pure C++ (no Godot types), reentrant.
//
// Native port of the stalag terrain: truncated-octahedron (TO) boundary-face
// extraction over BCC lattice cells, flat-shaded, world metres, BASE mesh and CAPS
// mesh (top caps, side caps, seam triangles), plus the occupancy / ground queries the
// character controller needs. Promoted from the Spec #494 spike (engine/spike, kept
// frozen); the spike never emitted the caps mesh -- that is the new code here.
// Sources ported (frozen reference, read at implementation time, NOT at run time):
// to-cell.js (VERTICES, faces, NEIGHBOR_OFFSETS, pointToCell, toTopOffset), cells.js
// (faceNormal, GRASS/CAP colours), worldgen.js (hash2/valueNoise/terrainHeight),
// worldmesh.js (surfaceHeightBase, cap passes, caps emission, isSolidWorld),
// character-controller.js (groundEnvelopeAt, groundFloor, blockedBetween).
//
// Spec #517: the terrain is carved. Surface height is surfaceHeightBase minus the water
// plan's carveDepth (worldmesh.js surfaceHeight); without a plan (not yet solved, or the
// carve_off test mutation) the carve is 0.
//
// Float discipline: all noise is double precision with the same operation order as the
// JS; the SConstruct adds -ffp-contract=off so no fused multiply-add changes rounding.
// Nothing here has mutable global state except thread_local caches, so concurrent
// builds are safe.

#include "stalag_core.h"

#include "stalag_plan.h"
#include "stalag_to_cell.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace stalag {

namespace {


// (SF, the lattice -> metres scale, is declared once in stalag_core.h.)
// Solid cells below each column's surface. The prototype's default is 4 (2 m), which is enough
// for its carve-free terrain but not for carved cliffs: two neighbouring columns can differ by
// 32 lattice units (4 m) in this world, and a wall taller than the slab leaves an open gap in the
// middle of the face, so the ground reads as sky from the side (Spec #517 A4.5). 12 cells (6 m)
// covers the steepest measured neighbour step with margin. The oracle passes the same depth to
// the prototype's own slabDepth parameter (js_world_oracle.mjs SLAB_DEPTH).
constexpr int SLAB_DEPTH = 12;
constexpr int RMARGIN = 4;
constexpr int JMARGIN = 8;
constexpr int SIDE_WALL_MIN = 12;
constexpr double SIDE_PLACE_MIN = 0.4;
constexpr double SIDE_ROUGH = 0.12;
constexpr int32_t UNSET = std::numeric_limits<int32_t>::min();

// ---------------------------------------------------------------- TO cell tables
constexpr auto &VERTICES = TO_VERTICES;
constexpr auto &FACE_LEN = TO_FACE_LEN;
constexpr auto &FACES = TO_FACES;
constexpr auto &NEIGHBOR_OFFSETS = TO_NEIGHBOR_OFFSETS;

struct FaceTables {
	std::vector<int> tris[14]; // flat triples of VERTICES indices
	std::vector<int> tris_alt[14]; // squares only: the other diagonal
	float normal[14][3];
	double normald[14][3]; // the same normals un-rounded (skin UVs are computed from these)
	bool grass[14]; // outward normal y above GRASS.upThreshold (0.3) -> grass colour, else dirt
	FaceTables() {
		for (int fi = 0; fi < 14; fi++) {
			double cx = 0, cy = 0, cz = 0;
			for (int v = 0; v < FACE_LEN[fi]; v++) {
				cx += VERTICES[FACES[fi][v]][0];
				cy += VERTICES[FACES[fi][v]][1];
				cz += VERTICES[FACES[fi][v]][2];
			}
			cx /= FACE_LEN[fi];
			cy /= FACE_LEN[fi];
			cz /= FACE_LEN[fi];
			double len = std::sqrt(cx * cx + cy * cy + cz * cz);
			normald[fi][0] = cx / len;
			normald[fi][1] = cy / len;
			normald[fi][2] = cz / len;
			normal[fi][0] = (float)(cx / len);
			normal[fi][1] = (float)(cy / len);
			normal[fi][2] = (float)(cz / len);
			grass[fi] = (cy / len) > 0.3;
			const int *f = FACES[fi];
			if (FACE_LEN[fi] == 4) {
				// Default split along the horizontal (constant-Y) diagonal v0-v2 when it exists.
				bool use_v02 = VERTICES[f[0]][1] == VERTICES[f[2]][1];
				const int a[6] = { f[0], f[1], f[2], f[0], f[2], f[3] }; // v02
				const int b[6] = { f[1], f[2], f[3], f[1], f[3], f[0] }; // v13
				tris[fi].assign(use_v02 ? a : b, (use_v02 ? a : b) + 6);
				tris_alt[fi].assign(use_v02 ? b : a, (use_v02 ? b : a) + 6);
			} else {
				for (int t = 1; t <= 4; t++) {
					tris[fi].push_back(f[0]);
					tris[fi].push_back(f[t]);
					tris[fi].push_back(f[t + 1]);
				}
			}
		}
	}
};

// ---------------------------------------------------------------- hashing and noise
// worldgen.js hash2: the JS products are exact doubles reduced mod 2^32 by `|0`.
inline double hash2(int64_t ix, int64_t iz, int32_t seed) {
	uint32_t h = (uint32_t)seed ^ (uint32_t)(ix * 2654435761LL) ^ (uint32_t)(iz * 1234567891LL);
	return (double)lowbias32(h) / 4294967296.0;
}

inline double fade(double t) { return t * t * t * (t * (t * 6 - 15) + 10); }
inline double lerp_(double a, double b, double t) { return a + t * (b - a); }

double value_noise(double x, double z, int32_t seed) {
	double fxl = std::floor(x), fzl = std::floor(z);
	int64_t ix = (int64_t)fxl, iz = (int64_t)fzl;
	double fx = x - fxl, fz = z - fzl;
	double v00 = hash2(ix, iz, seed);
	double v10 = hash2(ix + 1, iz, seed);
	double v01 = hash2(ix, iz + 1, seed);
	double v11 = hash2(ix + 1, iz + 1, seed);
	double ux = fade(fx), uz = fade(fz);
	return lerp_(lerp_(v00, v10, ux), lerp_(v01, v11, ux), uz);
}

inline int32_t to_i32(int64_t v) { return (int32_t)(uint32_t)v; }

double terrain_height(double x, double z, int32_t seed) {
	int32_t s0 = seed;
	int32_t s1 = to_i32((int64_t)seed * 1234567LL + 7);
	int32_t s2 = to_i32((int64_t)seed * 9876541LL + 13);
	int32_t s3 = to_i32((int64_t)seed * 3141592LL + 3);
	double n0 = value_noise(x / 32, z / 32, s0) * 14.0;
	double n1 = value_noise(x / 16, z / 16, s1) * 6.0;
	double n2 = value_noise(x / 8, z / 8, s2) * 3.0;
	double n3 = value_noise(x / 4, z / 4, s3) * 1.5;
	return n0 + n1 + n2 + n3 - 2.0;
}

// worldmesh.js cellHash (integer avalanche).
double cell_hash(int32_t cx, int32_t cy, int32_t cz, int32_t seed) {
	uint32_t h = (uint32_t)seed ^ ((uint32_t)cx * 0x27d4eb2du) ^ ((uint32_t)cy * 0x165667b1u) ^ ((uint32_t)cz * 0x9e3779b1u);
	h = (h ^ (h >> 15)) * 0x85ebca6bu;
	h = (h ^ (h >> 13)) * 0xc2b2ae35u;
	return (double)(h ^ (h >> 16)) / 4294967296.0;
}

inline int32_t xor_seed(int32_t seed, uint32_t k) { return (int32_t)((uint32_t)seed ^ k); }

double mesa_lift(double cx, double cz, int32_t seed) {
	const double MESA_CX = 6.0, MESA_CZ = 0.0, MESA_HALF = 2.5;
	const int MESA_LIFT = 16;
	double wx = cx * SF, wz = cz * SF;
	if (std::fabs(wx - MESA_CX) <= MESA_HALF && std::fabs(wz - MESA_CZ) <= MESA_HALF) return MESA_LIFT;
	const double G = 16;
	int32_t gi = (int32_t)std::floor(wx / G + 0.5), gj = (int32_t)std::floor(wz / G + 0.5);
	if (cell_hash(gi, 7, gj, seed) >= 0.45) return 0;
	double half_x = 2.5 + cell_hash(gi, 8, gj, seed) * 2.5;
	double half_z = 2.5 + cell_hash(gi, 9, gj, seed) * 2.5;
	if (std::fabs(wx - gi * G) > half_x || std::fabs(wz - gj * G) > half_z) return 0;
	double gx = gi * G / SF, gz = gj * G / SF;
	double h0 = std::floor(terrain_height(gx, gz, seed) / TERRACE_LAT);
	static const int OFFS[8][2] = { { 44, 0 }, { -44, 0 }, { 0, 44 }, { 0, -44 }, { 32, 32 }, { -32, -32 }, { 32, -32 }, { -32, 32 } };
	for (const auto &o : OFFS) {
		if (std::floor(terrain_height(gx + o[0], gz + o[1], seed) / TERRACE_LAT) != h0) return 0;
	}
	return 12 + std::floor(cell_hash(gi, 10, gj, seed) * 4) * 4;
}

double cliff_lift(double cx, double cz, int32_t seed) {
	double wx = cx * SF, wz = cz * SF;
	double a = value_noise(wx * 0.045 + 17, wz * 0.045 + 4, xor_seed(seed, 0x1f83d9abu));
	if (a <= 0.80) return 0;
	double lift = 16;
	double b = value_noise(wx * 0.09 + 31, wz * 0.09 + 19, xor_seed(seed, 0x5be0cd19u));
	if (b > 0.7) lift += 12;
	return lift;
}

double ridged_relief(double cx, double cz, int32_t seed) {
	const double FEAT = 56, AMP = 12, GUARD_INNER = 70, GUARD_OUTER = 110;
	double wx = cx * SF, wz = cz * SF;
	double r = det_hypot(wx, wz);
	if (r <= GUARD_INNER) return 0;
	double t = (r - GUARD_INNER) / (GUARD_OUTER - GUARD_INNER);
	double gm = r >= GUARD_OUTER ? 1 : t * t * (3 - 2 * t);
	auto ridged = [&](double feat, double amp, int32_t s) {
		return amp * (1 - std::fabs(2 * value_noise(wx / feat, wz / feat, s) - 1));
	};
	return gm * (ridged(FEAT, AMP, xor_seed(seed, 0x9E37u)) + ridged(FEAT / 2, AMP / 2, xor_seed(seed, 0x85EBu)));
}

// worldmesh.js surfaceHeightBase (pre-carve; valid on carve-free regions only).
double shb(double cx, double cz, int32_t seed) {
	return terrain_height(cx, cz, seed) + ridged_relief(cx, cz, seed) + mesa_lift(cx, cz, seed) + cliff_lift(cx, cz, seed);
}

// ---------------------------------------------------------------- side-cap wall facings
struct SideDir {
	int mating[4][3];
	int mating_face[4];
	int backing[3];
	int backing_face;
	int open[3];
	int run[2][3];
	bool z_wall;
};
const SideDir SIDE_DIRS[4] = {
	{ { { 2, 2, 2 }, { 2, 2, -2 }, { 2, -2, 2 }, { 2, -2, -2 } }, { 13, 12, 11, 10 }, { 4, 0, 0 }, 1, { -4, 0, 0 }, { { 0, 0, 4 }, { 0, 0, -4 } }, false },
	{ { { 2, 2, -2 }, { -2, 2, -2 }, { 2, -2, -2 }, { -2, -2, -2 } }, { 12, 8, 10, 6 }, { 0, 0, -4 }, 4, { 0, 0, 4 }, { { 4, 0, 0 }, { -4, 0, 0 } }, true },
	{ { { -2, 2, -2 }, { -2, 2, 2 }, { -2, -2, -2 }, { -2, -2, 2 } }, { 8, 9, 6, 7 }, { -4, 0, 0 }, 0, { 4, 0, 0 }, { { 0, 0, 4 }, { 0, 0, -4 } }, false },
	{ { { -2, 2, 2 }, { 2, 2, 2 }, { -2, -2, 2 }, { 2, -2, 2 } }, { 9, 13, 7, 11 }, { 0, 0, 4 }, 5, { 0, 0, -4 }, { { 4, 0, 0 }, { -4, 0, 0 } }, true },
};

// ---------------------------------------------------------------- cap tables (worldmesh.js)
// Lattice vertices of the flat top cap relative to its anchor column (cx, H, cz).
const int CAP_VERTS[16][3] = {
	{ 1, 2, 0 }, { 3, 2, 0 }, { 4, 2, 1 }, { 4, 2, 3 }, { 3, 2, 4 }, { 1, 2, 4 }, { 0, 2, 3 }, { 0, 2, 1 },
	{ 0, 1, 2 }, { 1, 0, 2 }, { 2, 0, 1 }, { 2, 1, 0 }, { 3, 0, 2 }, { 4, 1, 2 }, { 2, 0, 3 }, { 2, 1, 4 }
};
const int CAP_TOP[6][3] = { { 0, 2, 1 }, { 0, 3, 2 }, { 0, 4, 3 }, { 0, 5, 4 }, { 0, 6, 5 }, { 0, 7, 6 } };
const int CAP_SLOPES[16][3] = {
	{ 0, 8, 7 }, { 0, 9, 8 }, { 0, 10, 9 }, { 0, 11, 10 }, { 1, 10, 11 }, { 1, 12, 10 }, { 1, 13, 12 }, { 1, 2, 13 },
	{ 14, 8, 9 }, { 14, 6, 8 }, { 14, 5, 6 }, { 14, 15, 5 }, { 13, 14, 12 }, { 13, 15, 14 }, { 13, 4, 15 }, { 13, 3, 4 }
};
const int CAP_FLOOR[2][3] = { { 9, 10, 12 }, { 9, 12, 14 } };
const int CAP_EXPOSED[4][3] = { { 0, 1, 11 }, { 2, 3, 13 }, { 4, 5, 15 }, { 6, 7, 8 } };
const int CAP_ACROSS[4][3] = { { 2, 2, -2 }, { 6, 2, 2 }, { 2, 2, 6 }, { -2, 2, 2 } };

// Side cap: the top cap rotated to vertical. Base geometry faces -X; the other facings are
// rotations about Y, in SIDE_DIRS order (xneg, zpos, xpos, zneg).
const int SIDE_XNEG[16][3] = {
	{ 0, -1, -2 }, { 0, 1, -2 }, { 0, 2, -1 }, { 0, 2, 1 }, { 0, 1, 2 }, { 0, -1, 2 }, { 0, -2, 1 }, { 0, -2, -1 },
	{ 1, -2, 0 }, { 2, -1, 0 }, { 2, 0, -1 }, { 1, 0, -2 }, { 2, 1, 0 }, { 1, 2, 0 }, { 2, 0, 1 }, { 1, 0, 2 }
};
struct SideVerts {
	int v[4][16][3];
	SideVerts() {
		for (int i = 0; i < 16; i++) {
			const int *b = SIDE_XNEG[i];
			const int r[4][3] = { { b[0], b[1], b[2] }, { b[2], b[1], -b[0] }, { -b[0], b[1], -b[2] }, { -b[2], b[1], b[0] } };
			for (int d = 0; d < 4; d++)
				for (int a = 0; a < 3; a++) v[d][i][a] = r[d][a];
		}
	}
};
const SideVerts SIDE_VERTS_TABLE;
const int SIDE_ACROSS[4][4][3] = {
	{ { 0, 0, -4 }, { 0, 4, 0 }, { 0, 0, 4 }, { 0, -4, 0 } },
	{ { -4, 0, 0 }, { 0, 4, 0 }, { 4, 0, 0 }, { 0, -4, 0 } },
	{ { 0, 0, 4 }, { 0, 4, 0 }, { 0, 0, -4 }, { 0, -4, 0 } },
	{ { 4, 0, 0 }, { 0, 4, 0 }, { -4, 0, 0 }, { 0, -4, 0 } },
};

// worldmesh.js Phase 1c wall test: is the EMPTY interstitial cell (cx,cy,cz) part of a tall
// blocky wall? Shared by the mesher (footprint-gated sp) and the controller's occupancy
// (unbounded sp), so a wall cell is never a bottom cap in either.
template <class SP, class HT>
const SideDir *find_side_wall(SP &&sp, HT &&col_ht, int32_t cx, int32_t cy, int32_t cz, int32_t seed) {
	for (const SideDir &D : SIDE_DIRS) {
		const int *op = D.open;
		const int *bo = D.backing;
		if (sp(cx + op[0], cy + op[1], cz + op[2])) continue;
		if (!sp(cx + bo[0], cy + bo[1], cz + bo[2])) continue;
		bool mated = true;
		for (int m = 0; m < 4; m++) {
			if (!sp(cx + D.mating[m][0], cy + D.mating[m][1], cz + D.mating[m][2])) { mated = false; break; }
		}
		if (!mated) continue;
		if (col_ht(cx + bo[0], cz + bo[2]) - col_ht(cx + op[0], cz + op[2]) < SIDE_WALL_MIN) continue;
		if (mesa_lift(cx + bo[0], cz + bo[2], seed) <= 0) continue;
		bool flat = true;
		for (int r = 0; r < 2; r++) {
			const int *rn = D.run[r];
			if (sp(cx + rn[0] + op[0], cy + rn[1] + op[1], cz + rn[2] + op[2])) { flat = false; break; }
			if (!sp(cx + rn[0] + bo[0], cy + rn[1] + bo[1], cz + rn[2] + bo[2])) { flat = false; break; }
		}
		if (!flat) continue;
		return &D;
	}
	return nullptr;
}

// ---------------------------------------------------------------- the mesher
inline int64_t col_key(int32_t cx, int32_t cz) { return ((int64_t)(cx + 4096) << 16) | (int64_t)(cz + 4096); }
inline int64_t cell_key(int32_t cx, int32_t cy, int32_t cz) {
	return ((int64_t)(cx + 4096) << 32) | ((int64_t)(cy + 4096) << 16) | (int64_t)(cz + 4096);
}
inline int64_t face_key(int32_t cx, int32_t cy, int32_t cz, int fi) { return (cell_key(cx, cy, cz) << 4) | fi; }

struct TopCell {
	int32_t hT;
	int32_t cy;
};

struct Mesher {
	int32_t seed;
	const WaterPlan *plan = nullptr;
	double floor_half;
	double x_min, x_max, z_min, z_max;
	// dense lazy column cache indexed by lattice (i, k): cx = 4i + 2k, cz = 2k
	int32_t i0 = 0, k0 = 0, i_n = 0, k_n = 0;
	std::vector<int32_t> ht_cache;

	std::unordered_map<int64_t, TopCell> top_cells;
	std::unordered_set<int64_t> bottom_caps;
	std::unordered_set<int64_t> suppress;
	std::unordered_set<int64_t> force_x_split;
	struct SideCap {
		int dir;
		int32_t cx, cy, cz;
	};
	struct TopCap {
		int32_t cx, cz, H;
	};
	std::vector<SideCap> side_caps;
	std::vector<TopCap> top_caps;

	// Quantised terrace height of a column (lattice), no footprint gate.
	int32_t col_ht(int32_t cx, int32_t cz) {
		int32_t k = cz / 2;
		int32_t i = (cx - cz) / 4;
		bool in_range = ((cx - cz) & 3) == 0 && i >= i0 && i < i0 + i_n && k >= k0 && k < k0 + k_n;
		if (in_range) {
			int32_t &slot = ht_cache[(size_t)(i - i0) * k_n + (k - k0)];
			if (slot == UNSET) slot = compute_ht(cx, cz);
			return slot;
		}
		return compute_ht(cx, cz);
	}
	int32_t compute_ht(int32_t cx, int32_t cz) const {
		double h = surface_height(cx, cz, seed, plan);
		return (int32_t)(std::floor(h / TERRACE_LAT) * TERRACE_LAT);
	}
	bool in_foot(int32_t cx, int32_t cz) const {
		return !(std::fabs(cx * SF) > floor_half + 1e-9 || std::fabs(cz * SF) > floor_half + 1e-9);
	}
	bool sp(int32_t cx, int32_t cy, int32_t cz) {
		if (!in_foot(cx, cz)) return false;
		int32_t hT = col_ht(cx, cz);
		return cy <= hT && cy >= hT - SLAB_DEPTH * TERRACE_LAT;
	}
	bool solid_or_cap(int32_t cx, int32_t cy, int32_t cz) {
		return sp(cx, cy, cz) || bottom_caps.count(cell_key(cx, cy, cz)) > 0;
	}
	bool in_region(int32_t cx, int32_t cz) const {
		return (cx * SF) >= x_min && (cx * SF) < x_max && (cz * SF) >= z_min && (cz * SF) < z_max;
	}
};

} // anonymous namespace

void build_surface(int32_t p_seed, int32_t extent, double p_x_min, double p_x_max, double p_z_min, double p_z_max, SurfaceMesh &out, const WaterPlan *p_plan) {
	static const FaceTables FT;

	Mesher M;
	M.seed = p_seed;
	M.plan = p_plan;
	M.floor_half = 4.0 * extent * SF;
	M.x_min = p_x_min;
	M.x_max = p_x_max;
	M.z_min = p_z_min;
	M.z_max = p_z_max;

	// ---- iteration bounds (region + RMARGIN ring), as worldmesh.js
	const int32_t k_min = -2 * extent - 2, k_max = 2 * extent + 2;
	const int32_t i_min = -2 * extent - 2, i_max = 2 * extent + 2;
	const int32_t k_lo = std::max(k_min, (int32_t)std::floor(p_z_min / (2 * SF)) - RMARGIN);
	const int32_t k_hi = std::min(k_max, (int32_t)std::ceil(p_z_max / (2 * SF)) + RMARGIN);
	auto i_range = [&](int32_t k, int32_t &lo, int32_t &hi) {
		lo = std::max(i_min, (int32_t)std::floor((p_x_min / SF - 2 * k) / 4) - RMARGIN);
		hi = std::min(i_max, (int32_t)std::ceil((p_x_max / SF - 2 * k) / 4) + RMARGIN);
	};
	const int cy_lo_const = -10 - SLAB_DEPTH * TERRACE_LAT;
	const int cy_hi_const = 26;
	const int32_t j_min = (int32_t)std::floor((double)(cy_lo_const - 2 * k_hi) / 4) - JMARGIN;
	const int32_t j_max = (int32_t)std::ceil((double)(cy_hi_const - 2 * k_lo) / 4) + JMARGIN;

	// ---- column cache extent (padded so neighbour queries stay inside)
	const int PAD = 6;
	int32_t gi_lo = INT32_MAX, gi_hi = INT32_MIN;
	for (int32_t k = k_lo; k <= k_hi; k++) {
		int32_t lo, hi;
		i_range(k, lo, hi);
		gi_lo = std::min(gi_lo, lo);
		gi_hi = std::max(gi_hi, hi);
	}
	M.i0 = gi_lo - PAD;
	M.i_n = gi_hi - gi_lo + 1 + 2 * PAD;
	M.k0 = k_lo - PAD;
	M.k_n = k_hi - k_lo + 1 + 2 * PAD;
	M.ht_cache.assign((size_t)M.i_n * M.k_n, UNSET);

	// Per-column bound of the cy values that can matter. Any empty cell that yields
	// output (side cap / bottom cap) needs a solid cell within |dy| <= 4 inside the
	// 13-column box below, and solid cells span [hT - 4*SLAB_DEPTH, hT]; hence
	// [Hmin - 4*SLAB_DEPTH - 4, Hmax + 4].
	static const int BOX[13][2] = { { 0, 0 }, { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 }, { 4, 4 }, { 4, -4 }, { -4, 4 }, { -4, -4 }, { 2, 2 }, { 2, -2 }, { -2, 2 }, { -2, -2 } };
	auto cy_bounds = [&](int32_t cx, int32_t cz, int32_t &lo, int32_t &hi) -> bool {
		bool any = false;
		int32_t hmin = 0, hmax = 0;
		for (const auto &b : BOX) {
			int32_t nx = cx + b[0], nz = cz + b[1];
			if (!M.in_foot(nx, nz)) continue;
			int32_t h = M.col_ht(nx, nz);
			if (!any) { hmin = hmax = h; any = true; }
			hmin = std::min(hmin, h);
			hmax = std::max(hmax, h);
		}
		lo = hmin - SLAB_DEPTH * TERRACE_LAT - 4;
		hi = hmax + 4;
		return any;
	};
	// j-row bounds for a column given its cy bounds, clamped to the JS row range.
	auto j_bounds = [&](int32_t k, int32_t cy_a, int32_t cy_b, int32_t &ja, int32_t &jb) {
		ja = std::max(j_min, (int32_t)std::ceil((double)(cy_a - 2 * k) / 4));
		jb = std::min(j_max, (int32_t)std::floor((double)(cy_b - 2 * k) / 4));
	};

	// ---------------------------------------------------------------- Phase 1
	for (int32_t k = k_lo; k <= k_hi; k++) {
		const int32_t cz = 2 * k;
		int32_t ilo, ihi;
		i_range(k, ilo, ihi);
		for (int32_t i = ilo; i <= ihi; i++) {
			const int32_t cx = 4 * i + 2 * k;
			int32_t cy_a, cy_b;
			if (!cy_bounds(cx, cz, cy_a, cy_b)) continue;
			int32_t ja, jb;
			j_bounds(k, cy_a, cy_b, ja, jb);
			for (int32_t j = ja; j <= jb; j++) {
				const int32_t cy = 4 * j + 2 * k;
				if (!M.sp(cx, cy, cz)) {
					// Side cap: this empty interstitial cell sits in a tall blocky wall.
					const SideDir *wall = find_side_wall(
							[&](int32_t x, int32_t y, int32_t z) { return M.sp(x, y, z); },
							[&](int32_t x, int32_t z) { return M.col_ht(x, z); }, cx, cy, cz, M.seed);
					if (wall) {
						double ter = (double)(cy - M.col_ht(cx + wall->open[0], cz + wall->open[2])) / TERRACE_LAT;
						double place_prob = std::max(SIDE_PLACE_MIN, 1 - SIDE_ROUGH * ter);
						if (cell_hash(cx, cy, cz, M.seed) < place_prob) {
							for (int m = 0; m < 4; m++) {
								M.suppress.insert(face_key(cx + wall->mating[m][0], cy + wall->mating[m][1], cz + wall->mating[m][2], wall->mating_face[m]));
							}
							M.suppress.insert(face_key(cx + wall->backing[0], cy + wall->backing[1], cz + wall->backing[2], wall->backing_face));
							M.side_caps.push_back({ (int)(wall - SIDE_DIRS), cx, cy, cz });
							if (wall->z_wall) {
								if (M.sp(cx, cy - 4, cz)) M.force_x_split.insert(face_key(cx, cy - 4, cz, 2));
								if (M.sp(cx, cy + 4, cz)) M.force_x_split.insert(face_key(cx, cy + 4, cz, 3));
							}
						}
						continue;
					}
					// Bottom cap: seated on solid below, with an overhanging solid hex above.
					if (M.sp(cx, cy - 4, cz) &&
							(M.sp(cx + 2, cy + 2, cz + 2) || M.sp(cx + 2, cy + 2, cz - 2) ||
									M.sp(cx - 2, cy + 2, cz + 2) || M.sp(cx - 2, cy + 2, cz - 2))) {
						M.bottom_caps.insert(cell_key(cx, cy, cz));
					}
					continue;
				}
				if (!M.sp(cx, cy + 4, cz)) {
					M.top_cells[col_key(cx, cz)] = TopCell{ M.col_ht(cx, cz), cy };
				}
			}
		}
	}

	// ---------------------------------------------------------------- Phase 2
	// Flat cap decision: four same-height HIGH columns around a half-offset column.
	// Each cap anchored here suppresses the five base faces it replaces; its geometry is
	// emitted by the caps pass below.
	for (const auto &kv : M.top_cells) {
		const TopCell &cell = kv.second;
		if (cell.cy != cell.hT) continue;
		const int32_t cx = (int32_t)(kv.first >> 16) - 4096;
		const int32_t cz = (int32_t)(kv.first & 0xFFFF) - 4096;
		const int32_t H = cell.hT;
		auto find = [&](int32_t x, int32_t z) -> const TopCell * {
			auto it = M.top_cells.find(col_key(x, z));
			return it == M.top_cells.end() ? nullptr : &it->second;
		};
		const TopCell *B = find(cx + 4, cz);
		const TopCell *C = find(cx, cz + 4);
		const TopCell *Dd = find(cx + 4, cz + 4);
		const TopCell *G = find(cx + 2, cz + 2);
		if (!B || B->hT != H) continue;
		if (!C || C->hT != H) continue;
		if (!Dd || Dd->hT != H) continue;
		if (!G || G->hT != H) continue;
		M.top_caps.push_back({ cx, cz, H });
		M.suppress.insert(face_key(cx, H, cz, 6));
		M.suppress.insert(face_key(cx + 4, H, cz, 10));
		M.suppress.insert(face_key(cx, H, cz + 4, 7));
		M.suppress.insert(face_key(cx + 4, H, cz + 4, 11));
		M.suppress.insert(face_key(cx + 2, G->cy, cz + 2, 2));
	}

	// ---------------------------------------------------------------- Base extraction
	static const float GRASS_COL[3] = { 0.30f, 0.55f, 0.22f };
	static const float DIRT_COL[3] = { 0.42f, 0.28f, 0.15f };
	static const float CAP_COL[3] = { 0.40f, 0.80f, 0.28f };
	Soup &base = out.base;
	Soup &caps = out.caps;
	base.pos.reserve(1 << 20);
	base.nrm.reserve(1 << 20);
	base.col.reserve(1 << 20);
	for (int32_t k = k_lo; k <= k_hi; k++) {
		const int32_t cz = 2 * k;
		int32_t ilo, ihi;
		i_range(k, ilo, ihi);
		for (int32_t i = ilo; i <= ihi; i++) {
			const int32_t cx = 4 * i + 2 * k;
			if (!M.in_region(cx, cz)) continue;
			int32_t cy_a, cy_b;
			if (!cy_bounds(cx, cz, cy_a, cy_b)) continue;
			int32_t ja, jb;
			j_bounds(k, cy_a, cy_b, ja, jb);
			for (int32_t j = ja; j <= jb; j++) {
				const int32_t cy = 4 * j + 2 * k;
				if (!M.solid_or_cap(cx, cy, cz)) continue;
				for (int fi = 0; fi < 14; fi++) {
					const int *off = NEIGHBOR_OFFSETS[fi];
					if (M.solid_or_cap(cx + off[0], cy + off[1], cz + off[2])) continue;
					if (M.suppress.count(face_key(cx, cy, cz, fi))) continue;
					const std::vector<int> &tr =
							(fi == 2 || fi == 3) && M.force_x_split.count(face_key(cx, cy, cz, fi)) ? FT.tris_alt[fi] : FT.tris[fi];
					const float *colr = FT.grass[fi] ? GRASS_COL : DIRT_COL;
					for (size_t ti = 0; ti + 2 < tr.size(); ti += 3) {
						base.tri_nrm.push_back(FT.normald[fi][0]);
						base.tri_nrm.push_back(FT.normald[fi][1]);
						base.tri_nrm.push_back(FT.normald[fi][2]);
					}
					for (int vi : tr) {
						base.pos.push_back((float)((cx + VERTICES[vi][0]) * SF));
						base.pos.push_back((float)((cy + VERTICES[vi][1]) * SF));
						base.pos.push_back((float)((cz + VERTICES[vi][2]) * SF));
						base.nrm.push_back(FT.normal[fi][0]);
						base.nrm.push_back(FT.normal[fi][1]);
						base.nrm.push_back(FT.normal[fi][2]);
						base.col.push_back(colr[0]);
						base.col.push_back(colr[1]);
						base.col.push_back(colr[2]);
					}
				}
			}
		}
	}

	// ---------------------------------------------------------------- Caps
	// A cap instance = 16 absolute lattice vertices + the cell across each of the 4 seams.
	struct CapInst {
		int32_t v[16][3];
		int32_t across[4][3];
		int32_t ox, oz;
	};
	// One triangle of lattice-space vertices; the outward normal comes from the CCW winding.
	auto push_cap_tri = [&](const int32_t *a, const int32_t *b, const int32_t *c, const float *colr) {
		double p[3][3];
		const int32_t *vv[3] = { a, b, c };
		for (int q = 0; q < 3; q++)
			for (int ax = 0; ax < 3; ax++) p[q][ax] = vv[q][ax] * SF;
		const double ux = p[1][0] - p[0][0], uy = p[1][1] - p[0][1], uz = p[1][2] - p[0][2];
		const double vx = p[2][0] - p[0][0], vy = p[2][1] - p[0][1], vz = p[2][2] - p[0][2];
		double nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
		double len = det_hypot3(nx, ny, nz); // worldmesh.js pushCapTri: Math.hypot(...) || 1
		if (len == 0) len = 1;
		nx /= len;
		ny /= len;
		nz /= len;
		caps.tri_nrm.push_back(nx);
		caps.tri_nrm.push_back(ny);
		caps.tri_nrm.push_back(nz);
		for (int q = 0; q < 3; q++) {
			for (int ax = 0; ax < 3; ax++) caps.pos.push_back((float)p[q][ax]);
			caps.nrm.push_back((float)nx);
			caps.nrm.push_back((float)ny);
			caps.nrm.push_back((float)nz);
			caps.col.push_back(colr[0]);
			caps.col.push_back(colr[1]);
			caps.col.push_back(colr[2]);
		}
	};
	struct Seam {
		int count;
		int32_t la[3], lb[3], lc[3], across[3];
		int32_t ocx, ocz;
	};
	// Lid + slopes + floor for every in-region cap (decisions stay global; only emission is
	// clipped), then the vertical seam triangles deduplicated over ALL caps: an interior
	// cap<->cap seam appears twice and cancels; a boundary seam is kept only if the cell
	// across it is empty and its owner cap lies in the region.
	auto emit_family = [&](const std::vector<CapInst> &insts, const float *colr) {
		for (const CapInst &c : insts) {
			if (!M.in_region(c.ox, c.oz)) continue;
			for (const auto &t : CAP_TOP) push_cap_tri(c.v[t[0]], c.v[t[1]], c.v[t[2]], colr);
			for (const auto &t : CAP_SLOPES) push_cap_tri(c.v[t[0]], c.v[t[1]], c.v[t[2]], colr);
			for (const auto &t : CAP_FLOOR) push_cap_tri(c.v[t[0]], c.v[t[1]], c.v[t[2]], colr);
		}
		std::map<std::array<int32_t, 9>, Seam> seams;
		for (const CapInst &c : insts) {
			for (int e = 0; e < 4; e++) {
				const int32_t *la = c.v[CAP_EXPOSED[e][0]];
				const int32_t *lb = c.v[CAP_EXPOSED[e][1]];
				const int32_t *lc = c.v[CAP_EXPOSED[e][2]];
				std::array<std::array<int32_t, 3>, 3> pts = { { { la[0], la[1], la[2] }, { lb[0], lb[1], lb[2] }, { lc[0], lc[1], lc[2] } } };
				std::sort(pts.begin(), pts.end());
				std::array<int32_t, 9> key;
				for (int q = 0; q < 3; q++)
					for (int ax = 0; ax < 3; ax++) key[q * 3 + ax] = pts[q][ax];
				auto it = seams.find(key);
				if (it != seams.end()) {
					it->second.count++;
				} else {
					Seam sm;
					sm.count = 1;
					for (int ax = 0; ax < 3; ax++) {
						sm.la[ax] = la[ax];
						sm.lb[ax] = lb[ax];
						sm.lc[ax] = lc[ax];
						sm.across[ax] = c.across[e][ax];
					}
					sm.ocx = c.ox;
					sm.ocz = c.oz;
					seams.emplace(key, sm);
				}
			}
		}
		for (const auto &kv : seams) {
			const Seam &sm = kv.second;
			if (sm.count != 1) continue;
			if (!M.in_region(sm.ocx, sm.ocz)) continue;
			if (M.sp(sm.across[0], sm.across[1], sm.across[2])) continue;
			push_cap_tri(sm.la, sm.lb, sm.lc, colr);
		}
	};

	std::vector<CapInst> top_insts, side_insts;
	top_insts.reserve(M.top_caps.size());
	for (const auto &tc : M.top_caps) {
		CapInst c;
		for (int vi = 0; vi < 16; vi++) {
			c.v[vi][0] = tc.cx + CAP_VERTS[vi][0];
			c.v[vi][1] = tc.H + CAP_VERTS[vi][1];
			c.v[vi][2] = tc.cz + CAP_VERTS[vi][2];
		}
		for (int e = 0; e < 4; e++) {
			c.across[e][0] = tc.cx + CAP_ACROSS[e][0];
			c.across[e][1] = tc.H + CAP_ACROSS[e][1];
			c.across[e][2] = tc.cz + CAP_ACROSS[e][2];
		}
		c.ox = tc.cx;
		c.oz = tc.cz;
		top_insts.push_back(c);
	}
	for (const auto &sc : M.side_caps) {
		CapInst c;
		for (int vi = 0; vi < 16; vi++) {
			const int *rv = SIDE_VERTS_TABLE.v[sc.dir][vi];
			c.v[vi][0] = sc.cx + rv[0];
			c.v[vi][1] = sc.cy + rv[1];
			c.v[vi][2] = sc.cz + rv[2];
		}
		for (int e = 0; e < 4; e++) {
			c.across[e][0] = sc.cx + SIDE_ACROSS[sc.dir][e][0];
			c.across[e][1] = sc.cy + SIDE_ACROSS[sc.dir][e][1];
			c.across[e][2] = sc.cz + SIDE_ACROSS[sc.dir][e][2];
		}
		c.ox = sc.cx;
		c.oz = sc.cz;
		side_insts.push_back(c);
	}
	emit_family(top_insts, CAP_COL);
	emit_family(side_insts, DIRT_COL);
}


// ================================================================ world-skin.js
namespace {
inline double dot3(const double *a, const double *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline void norm3(const double *a, double *o) {
	double l = det_hypot3(a[0], a[1], a[2]);
	if (l == 0) l = 1;
	o[0] = a[0] / l;
	o[1] = a[1] / l;
	o[2] = a[2] / l;
}
inline void cross3(const double *a, const double *b, double *o) {
	o[0] = a[1] * b[2] - a[2] * b[1];
	o[1] = a[2] * b[0] - a[0] * b[2];
	o[2] = a[0] * b[1] - a[1] * b[0];
}
// Tangent frame: bit = world-up projected into the face plane (+Z on top/bottom faces).
void face_frame(const double *n, double *tan, double *bit) {
	double up[3] = { 0, 1, 0 };
	if (std::fabs(dot3(up, n)) > 0.99) {
		up[0] = 0;
		up[1] = 0;
		up[2] = 1;
	}
	const double d = dot3(up, n);
	const double t[3] = { up[0] - n[0] * d, up[1] - n[1] * d, up[2] - n[2] * d };
	norm3(t, bit);
	double c[3];
	cross3(bit, n, c);
	norm3(c, tan);
}
} // namespace

void skin_surface(const SurfaceMesh &in, int32_t seed, const WaterPlan *plan, SkinnedSurface &out) {
	const double TILE_WORLD = 0.5, SURF_TOL = 0.35, UP_THRESHOLD = 0.3;
	auto surf_y = [&](double wx, double wz) {
		const double hT = std::floor(surface_height(wx / SF, wz / SF, seed, plan) / 4) * 4;
		return (hT + 2) * SF;
	};
	const Soup *parts[2] = { &in.base, &in.caps };
	for (const Soup *part : parts) {
		const size_t nt = part->pos.size() / 9;
		for (size_t ti = 0; ti < nt; ti++) {
			const size_t t = ti * 9;
			double fn[3];
			norm3(&part->tri_nrm[ti * 3], fn);
			bool is_grass = fn[1] > UP_THRESHOLD;
			if (is_grass) {
				const double cxw = ((double)part->pos[t] + part->pos[t + 3] + part->pos[t + 6]) / 3;
				const double czw = ((double)part->pos[t + 2] + part->pos[t + 5] + part->pos[t + 8]) / 3;
				const double top_y = std::max({ (double)part->pos[t + 1], (double)part->pos[t + 4], (double)part->pos[t + 7] });
				if (top_y < surf_y(cxw, czw) - SURF_TOL) is_grass = false;
			}
			SkinBucket &b = is_grass ? out.grass : out.dirt;
			double tan[3], bit[3];
			face_frame(fn, tan, bit);
			for (int v = 0; v < 3; v++) {
				const size_t o = t + v * 3;
				const double p[3] = { part->pos[o], part->pos[o + 1], part->pos[o + 2] };
				const double u = dot3(p, tan) / TILE_WORLD, w = dot3(p, bit) / TILE_WORLD;
				b.pos.push_back(part->pos[o]);
				b.pos.push_back(part->pos[o + 1]);
				b.pos.push_back(part->pos[o + 2]);
				b.nrm.push_back(part->nrm[o]);
				b.nrm.push_back(part->nrm[o + 1]);
				b.nrm.push_back(part->nrm[o + 2]);
				b.col.push_back(part->col[o]);
				b.col.push_back(part->col[o + 1]);
				b.col.push_back(part->col[o + 2]);
				b.uv.push_back((float)u);
				b.uv.push_back((float)w);
				// the prototype stores UVs in a Float32Array and checksums those values
				out.uv_q_sum[0] += (int64_t)std::floor((double)(float)u * 1e4 + 0.5);
				out.uv_q_sum[1] += (int64_t)std::floor((double)(float)w * 1e4 + 0.5);
			}
		}
	}
}

// ================================================================ world queries
// Carve-free occupancy for the controller: worldmesh.js isSolidWorld (unbounded footprint).
namespace {

struct HtSlot {
	int32_t cx, cz;
	double h;
	bool valid;
};
constexpr int HT_SLOTS = 8192;

// Per-thread memo of surfaceHeight: ground scans ask the same few columns hundreds
// of times; recomputing five noise octaves per probe would dominate the controller.
// The memo is keyed to the published plan (and the carve test switch), so a query
// answered before the plan was ready can never outlive it.
double cached_height(int32_t cx, int32_t cz) {
	thread_local std::vector<HtSlot> slots(HT_SLOTS, HtSlot{ 0, 0, 0.0, false });
	thread_local const WaterPlan *slots_plan = nullptr;
	thread_local bool slots_carve_off = false;
	const WaterPlan *plan = shared_plan();
	const bool carve_off = carve_disabled();
	if (plan != slots_plan || carve_off != slots_carve_off) {
		for (HtSlot &s : slots) s.valid = false;
		slots_plan = plan;
		slots_carve_off = carve_off;
	}
	uint32_t hh = ((uint32_t)cx * 73856093u) ^ ((uint32_t)cz * 19349663u);
	HtSlot &s = slots[hh & (HT_SLOTS - 1)];
	if (s.valid && s.cx == cx && s.cz == cz) return s.h;
	s.cx = cx;
	s.cz = cz;
	s.h = surface_height(cx, cz, WORLD_SEED, plan);
	s.valid = true;
	return s.h;
}

inline int32_t col_hT(int32_t cx, int32_t cz) { return (int32_t)(std::floor(cached_height(cx, cz) / TERRACE_LAT) * TERRACE_LAT); }

inline bool solid_pred_inf(int32_t cx, int32_t cy, int32_t cz) {
	int32_t hT = col_hT(cx, cz);
	return cy <= hT && cy >= hT - SLAB_DEPTH * TERRACE_LAT;
}

// worldmesh.js isCapCell: the interstitial cap cell over a flat 4-column junction.
bool is_cap_cell(int32_t cx, int32_t cy, int32_t cz) {
	if ((cx & 3) != 2 || (cy & 3) != 2 || (cz & 3) != 2) return false;
	const int32_t H = cy - 2;
	static const int C[4][2] = { { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } };
	for (const auto &c : C) {
		if (!solid_pred_inf(cx + c[0], H, cz + c[1]) || solid_pred_inf(cx + c[0], H + 4, cz + c[1])) return false;
	}
	return col_hT(cx, cz) == H;
}

// worldmesh.js Phase 1b bottom cap: an empty interstitial cell seated on a solid cell, with
// an overhanging solid hex above, that the mesher SOLIDIFIES and renders. The prototype's
// isSolidWorld ignores these, so its walker sinks into the rendered shelf; Spec #501 puts
// the controller on the rendered surface, so occupancy includes them (and, as in the
// mesher, a wall cell is never a bottom cap).
bool is_bottom_cap_cell(int32_t cx, int32_t cy, int32_t cz) {
	if (solid_pred_inf(cx, cy, cz)) return false;
	if (!solid_pred_inf(cx, cy - 4, cz)) return false;
	if (!(solid_pred_inf(cx + 2, cy + 2, cz + 2) || solid_pred_inf(cx + 2, cy + 2, cz - 2) ||
				solid_pred_inf(cx - 2, cy + 2, cz + 2) || solid_pred_inf(cx - 2, cy + 2, cz - 2)))
		return false;
	return find_side_wall(
				   [](int32_t x, int32_t y, int32_t z) { return solid_pred_inf(x, y, z); },
				   [](int32_t x, int32_t z) { return col_hT(x, z); }, cx, cy, cz, WORLD_SEED) == nullptr;
}

inline double js_round(double v) { return std::floor(v + 0.5); }

// to-cell.js pointToCell (Conway-Sloane D3* quantiser).
void point_to_cell(double px, double py, double pz, int32_t out[3]) {
	double A[3] = { 4 * js_round(px / 4), 4 * js_round(py / 4), 4 * js_round(pz / 4) };
	double B[3] = { 4 * js_round((px - 2) / 4) + 2, 4 * js_round((py - 2) / 4) + 2, 4 * js_round((pz - 2) / 4) + 2 };
	auto d = [&](const double *a) { return (px - a[0]) * (px - a[0]) + (py - a[1]) * (py - a[1]) + (pz - a[2]) * (pz - a[2]); };
	const double *pick = d(A) <= d(B) ? A : B;
	for (int i = 0; i < 3; i++) out[i] = (int32_t)pick[i];
}

bool solid_at(double wx, double wy, double wz) {
	int32_t c[3];
	point_to_cell(wx / SF, wy / SF, wz / SF, c);
	return is_solid_world(c[0], c[1], c[2]);
}

constexpr double PLAYER_RADIUS = 0.3; // character-controller.js PLAYER_RADIUS

} // namespace

double surface_height_base(double cx, double cz, int32_t seed) { return shb(cx, cz, seed); }
double cliff_lift_at(double cx, double cz, int32_t seed) { return cliff_lift(cx, cz, seed); }
double surface_height_world(int32_t cx, int32_t cz) { return cached_height(cx, cz); }
double hash_cell(int32_t cx, int32_t cy, int32_t cz, int32_t seed) { return cell_hash(cx, cy, cz, seed); }
double noise_value(double x, double z, int32_t seed) { return value_noise(x, z, seed); }

bool is_solid_world(int32_t cx, int32_t cy, int32_t cz) {
	return solid_pred_inf(cx, cy, cz) || is_cap_cell(cx, cy, cz) || is_bottom_cap_cell(cx, cy, cz);
}

// character-controller.js groundEnvelopeAt: highest TO surface at or below max_surface
// over the candidate BCC columns covering (fx, fz).
double ground_envelope_at(double fx, double fz, double max_surface) {
	const double lx = fx / SF, lz = fz / SF;
	double best = -std::numeric_limits<double>::infinity();
	const double axBase = 4 * js_round(lx / 4), azBase = 4 * js_round(lz / 4);
	const double bxBase = 4 * js_round((lx - 2) / 4) + 2, bzBase = 4 * js_round((lz - 2) / 4) + 2;
	// Scan ceiling capped at lattice 60 when unbounded (as the JS), floor well below terrain.
	const int32_t scan_top = std::isfinite(max_surface) ? (int32_t)std::ceil(max_surface / SF + 2) : 60;
	const int32_t scan_bot = -20;
	for (int coset = 0; coset < 2; coset++) {
		const double cxBase = coset == 0 ? axBase : bxBase;
		const double czBase = coset == 0 ? azBase : bzBase;
		const int cy_mod = coset == 0 ? 0 : 2;
		for (int dcx = -4; dcx <= 4; dcx += 4) {
			for (int dcz = -4; dcz <= 4; dcz += 4) {
				const int32_t cx = (int32_t)cxBase + dcx, cz = (int32_t)czBase + dcz;
				const double qx = lx - cx, qz = lz - cz;
				if (std::fabs(qx) > 2 || std::fabs(qz) > 2 || std::fabs(qx) + std::fabs(qz) > 3) continue;
				const double offset = std::min(2.0, 3 - std::fabs(qx) - std::fabs(qz));
				const int32_t cy_start = (int32_t)(std::floor((double)(scan_top - cy_mod) / 4) * 4) + cy_mod;
				for (int32_t cy = cy_start; cy >= scan_bot; cy -= 4) {
					if (!is_solid_world(cx, cy, cz)) continue;
					double surface;
					if (cy_mod == 2 && is_cap_cell(cx, cy, cz)) {
						surface = cy * SF; // top-cap cell: lid at the equatorial plane
					} else {
						surface = (cy + offset) * SF;
					}
					if (surface <= max_surface) {
						if (surface > best) best = surface;
						break;
					}
				}
			}
		}
	}
	return best;
}

double ground_floor(double fx, double fz, double max_surface) {
	const double r = PLAYER_RADIUS;
	return std::max({ ground_envelope_at(fx, fz, max_surface), ground_envelope_at(fx + r, fz, max_surface), ground_envelope_at(fx - r, fz, max_surface),
			ground_envelope_at(fx, fz + r, max_surface), ground_envelope_at(fx, fz - r, max_surface) });
}

bool blocked_between(double fx, double fz, double from_y, double to_y) {
	const double r = PLAYER_RADIUS;
	const double offs[3] = { -r, 0, r };
	for (double wy = from_y; wy <= to_y + 1e-6; wy += 0.4) {
		for (double dx : offs)
			for (double dz : offs)
				if (solid_at(fx + dx, wy, fz + dz)) return true;
	}
	return false;
}

} // namespace stalag
