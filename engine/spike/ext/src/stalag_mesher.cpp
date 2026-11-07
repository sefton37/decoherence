// Spec #494 spike -- C++ GDExtension candidate.
//
// A from-scratch native port of the stalag `base` terrain mesh: truncated-octahedron
// (TO) boundary-face extraction over BCC lattice cells, flat-shaded, world metres.
// Sources ported (frozen reference, read at implementation time, NOT at run time):
// to-cell.js (VERTICES, faces, NEIGHBOR_OFFSETS), cells.js (faceNormal), worldgen.js
// (hash2/valueNoise/terrainHeight), worldmesh.js (surfaceHeightBase and the cap
// decision passes that decide which base faces are suppressed).
//
// NOT ported (spec #494): the `caps` mesh output, skin, water, carve. surfaceHeight is
// taken as surfaceHeightBase, valid only on carve-free regions.
//
// Float discipline: all noise is double precision with the same operation order as the
// JS; the SConstruct adds -ffp-contract=off so no fused multiply-add changes rounding.

#include "stalag_mesher.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace godot;

namespace {

// Lattice units -> world metres (cell diameter 0.5 m / 4 lattice). ONE definition here.
constexpr double SF = 0.125;
constexpr int TERRACE_LAT = 4;
constexpr int SLAB_DEPTH = 4;
constexpr int RMARGIN = 4;
constexpr int JMARGIN = 8;
constexpr int SIDE_WALL_MIN = 12;
constexpr double SIDE_PLACE_MIN = 0.4;
constexpr double SIDE_ROUGH = 0.12;
constexpr int32_t UNSET = std::numeric_limits<int32_t>::min();

// ---------------------------------------------------------------- TO cell tables
const int VERTICES[24][3] = {
	{ -2, -1, 0 }, { -2, 0, -1 }, { -2, 0, 1 }, { -2, 1, 0 },
	{ -1, -2, 0 }, { -1, 0, -2 }, { -1, 0, 2 }, { -1, 2, 0 },
	{ 0, -2, -1 }, { 0, -2, 1 }, { 0, -1, -2 }, { 0, -1, 2 },
	{ 0, 1, -2 }, { 0, 1, 2 }, { 0, 2, -1 }, { 0, 2, 1 },
	{ 1, -2, 0 }, { 1, 0, -2 }, { 1, 0, 2 }, { 1, 2, 0 },
	{ 2, -1, 0 }, { 2, 0, -1 }, { 2, 0, 1 }, { 2, 1, 0 }
};

// 14 faces: 6 squares (4 verts) then 8 hexagons (6 verts); index == NEIGHBOR_OFFSETS index.
const int FACE_LEN[14] = { 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 6, 6 };
const int FACES[14][6] = {
	{ 22, 20, 21, 23, -1, -1 }, { 1, 0, 2, 3, -1, -1 }, { 14, 7, 15, 19, -1, -1 },
	{ 9, 4, 8, 16, -1, -1 }, { 13, 6, 11, 18, -1, -1 }, { 10, 5, 12, 17, -1, -1 },
	{ 19, 15, 13, 18, 22, 23 }, { 21, 17, 12, 14, 19, 23 }, { 18, 11, 9, 16, 20, 22 },
	{ 20, 16, 8, 10, 17, 21 }, { 7, 3, 2, 6, 13, 15 }, { 12, 5, 1, 3, 7, 14 },
	{ 6, 2, 0, 4, 9, 11 }, { 8, 4, 0, 1, 5, 10 }
};

const int NEIGHBOR_OFFSETS[14][3] = {
	{ 4, 0, 0 }, { -4, 0, 0 }, { 0, 4, 0 }, { 0, -4, 0 }, { 0, 0, 4 }, { 0, 0, -4 },
	{ 2, 2, 2 }, { 2, 2, -2 }, { 2, -2, 2 }, { 2, -2, -2 },
	{ -2, 2, 2 }, { -2, 2, -2 }, { -2, -2, 2 }, { -2, -2, -2 }
};

struct FaceTables {
	std::vector<int> tris[14]; // flat triples of VERTICES indices
	std::vector<int> tris_alt[14]; // squares only: the other diagonal
	float normal[14][3];
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
			normal[fi][0] = (float)(cx / len);
			normal[fi][1] = (float)(cy / len);
			normal[fi][2] = (float)(cz / len);
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
inline uint32_t mix32(uint32_t h) {
	h = (h ^ (h >> 16)) * 0x45d9f3bu;
	h = (h ^ (h >> 16)) * 0x45d9f3bu;
	h = h ^ (h >> 16);
	return h;
}

// worldgen.js hash2: the JS products are exact doubles reduced mod 2^32 by `|0`.
inline double hash2(int64_t ix, int64_t iz, int32_t seed) {
	uint32_t h = (uint32_t)seed ^ (uint32_t)(ix * 2654435761LL) ^ (uint32_t)(iz * 1234567891LL);
	return (double)mix32(h) / 4294967296.0;
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

double mesa_lift(int32_t cx, int32_t cz, int32_t seed) {
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

double cliff_lift(int32_t cx, int32_t cz, int32_t seed) {
	double wx = cx * SF, wz = cz * SF;
	double a = value_noise(wx * 0.045 + 17, wz * 0.045 + 4, xor_seed(seed, 0x1f83d9abu));
	if (a <= 0.80) return 0;
	double lift = 16;
	double b = value_noise(wx * 0.09 + 31, wz * 0.09 + 19, xor_seed(seed, 0x5be0cd19u));
	if (b > 0.7) lift += 12;
	return lift;
}

double ridged_relief(int32_t cx, int32_t cz, int32_t seed) {
	const double FEAT = 56, AMP = 12, GUARD_INNER = 70, GUARD_OUTER = 110;
	double wx = cx * SF, wz = cz * SF;
	double r = std::sqrt(wx * wx + wz * wz);
	if (r <= GUARD_INNER) return 0;
	double t = (r - GUARD_INNER) / (GUARD_OUTER - GUARD_INNER);
	double gm = r >= GUARD_OUTER ? 1 : t * t * (3 - 2 * t);
	auto ridged = [&](double feat, double amp, int32_t s) {
		return amp * (1 - std::fabs(2 * value_noise(wx / feat, wz / feat, s) - 1));
	};
	return gm * (ridged(FEAT, AMP, xor_seed(seed, 0x9E37u)) + ridged(FEAT / 2, AMP / 2, xor_seed(seed, 0x85EBu)));
}

// worldmesh.js surfaceHeightBase (pre-carve; valid on carve-free regions only).
double surface_height_base(int32_t cx, int32_t cz, int32_t seed) {
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
	double floor_half;
	double x_min, x_max, z_min, z_max;
	// dense lazy column cache indexed by lattice (i, k): cx = 4i + 2k, cz = 2k
	int32_t i0 = 0, k0 = 0, i_n = 0, k_n = 0;
	std::vector<int32_t> ht_cache;

	std::unordered_map<int64_t, TopCell> top_cells;
	std::unordered_set<int64_t> bottom_caps;
	std::unordered_set<int64_t> suppress;
	std::unordered_set<int64_t> force_x_split;
	std::vector<float> pos, nrm;

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
		double h = surface_height_base(cx, cz, seed);
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

} // namespace

void StalagMesher::_bind_methods() {
	ClassDB::bind_method(D_METHOD("build", "seed", "extent", "x_min", "x_max", "z_min", "z_max"), &StalagMesher::build);
}

Ref<ArrayMesh> StalagMesher::build(int64_t p_seed, int64_t p_extent, double p_x_min, double p_x_max, double p_z_min, double p_z_max) {
	static const FaceTables FT;

	Mesher M;
	M.seed = (int32_t)p_seed;
	const int32_t extent = (int32_t)p_extent;
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
	// 13-column box below, and solid cells span [hT-16, hT]; hence [Hmin-20, Hmax+4].
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
		lo = hmin - 20;
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
					const SideDir *wall = nullptr;
					for (const SideDir &D : SIDE_DIRS) {
						const int *op = D.open;
						const int *bo = D.backing;
						if (M.sp(cx + op[0], cy + op[1], cz + op[2])) continue;
						if (!M.sp(cx + bo[0], cy + bo[1], cz + bo[2])) continue;
						bool mated = true;
						for (int m = 0; m < 4; m++) {
							if (!M.sp(cx + D.mating[m][0], cy + D.mating[m][1], cz + D.mating[m][2])) { mated = false; break; }
						}
						if (!mated) continue;
						if (M.col_ht(cx + bo[0], cz + bo[2]) - M.col_ht(cx + op[0], cz + op[2]) < SIDE_WALL_MIN) continue;
						if (mesa_lift(cx + bo[0], cz + bo[2], M.seed) <= 0) continue;
						bool flat = true;
						for (int r = 0; r < 2; r++) {
							const int *rn = D.run[r];
							if (M.sp(cx + rn[0] + op[0], cy + rn[1] + op[1], cz + rn[2] + op[2])) { flat = false; break; }
							if (!M.sp(cx + rn[0] + bo[0], cy + rn[1] + bo[1], cz + rn[2] + bo[2])) { flat = false; break; }
						}
						if (!flat) continue;
						wall = &D;
						break;
					}
					if (wall) {
						double ter = (double)(cy - M.col_ht(cx + wall->open[0], cz + wall->open[2])) / TERRACE_LAT;
						double place_prob = std::max(SIDE_PLACE_MIN, 1 - SIDE_ROUGH * ter);
						if (cell_hash(cx, cy, cz, M.seed) < place_prob) {
							for (int m = 0; m < 4; m++) {
								M.suppress.insert(face_key(cx + wall->mating[m][0], cy + wall->mating[m][1], cz + wall->mating[m][2], wall->mating_face[m]));
							}
							M.suppress.insert(face_key(cx + wall->backing[0], cy + wall->backing[1], cz + wall->backing[2], wall->backing_face));
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
	// Only the suppression of the five base faces the cap would replace matters here
	// (the cap solids themselves belong to the un-ported `caps` mesh).
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
		M.suppress.insert(face_key(cx, H, cz, 6));
		M.suppress.insert(face_key(cx + 4, H, cz, 10));
		M.suppress.insert(face_key(cx, H, cz + 4, 7));
		M.suppress.insert(face_key(cx + 4, H, cz + 4, 11));
		M.suppress.insert(face_key(cx + 2, G->cy, cz + 2, 2));
	}

	// ---------------------------------------------------------------- Base extraction
	M.pos.reserve(1 << 20);
	M.nrm.reserve(1 << 20);
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
					for (int vi : tr) {
						M.pos.push_back((float)((cx + VERTICES[vi][0]) * SF));
						M.pos.push_back((float)((cy + VERTICES[vi][1]) * SF));
						M.pos.push_back((float)((cz + VERTICES[vi][2]) * SF));
						M.nrm.push_back(FT.normal[fi][0]);
						M.nrm.push_back(FT.normal[fi][1]);
						M.nrm.push_back(FT.normal[fi][2]);
					}
				}
			}
		}
	}

	// ---------------------------------------------------------------- ArrayMesh
	const int64_t n_verts = (int64_t)(M.pos.size() / 3);
	PackedVector3Array verts;
	PackedVector3Array norms;
	verts.resize(n_verts);
	norms.resize(n_verts);
	Vector3 *vw = verts.ptrw();
	Vector3 *nw = norms.ptrw();
	for (int64_t v = 0; v < n_verts; v++) {
		vw[v] = Vector3(M.pos[v * 3], M.pos[v * 3 + 1], M.pos[v * 3 + 2]);
		nw[v] = Vector3(M.nrm[v * 3], M.nrm[v * 3 + 1], M.nrm[v * 3 + 2]);
	}
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = verts;
	arrays[Mesh::ARRAY_NORMAL] = norms;
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	return mesh;
}
