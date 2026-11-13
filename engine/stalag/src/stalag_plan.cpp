// Spec #517 -- the Stalag whole-world water plan, native port.
//
// Faithful port (no redesign) of the frozen prototype's waterplan.js (the solve),
// hydrology.js (priorityFlood, still-water facade), rivers.js (moving-water facade),
// water-api.js and carve.js, read at implementation time from the frozen tag; the
// prototype is the oracle (tests/verify_stalag_plan.sh compares all seven plan arrays).
// Section numbers in the comments (1, 1b, 5b, 7a, 7b', 7d ...) are the prototype's own,
// kept so the two files can be read side by side.
//
// The solve is deterministic and pure: one seed in, one immutable WaterPlan out. Game
// policy that decides where water may not be (asset discs, patrol rectangle, demo mesa,
// shield radius) is the labelled data below, with the prototype's values.

#include "stalag_plan.h"

#include "stalag_core.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <thread>
#include <unordered_set>
#include <vector>

namespace stalag {

namespace {

struct PlanFail : std::runtime_error {
	explicit PlanFail(const std::string &m) :
			std::runtime_error(m) {}
};

constexpr double INF = std::numeric_limits<double>::infinity();
constexpr int DIM = PLAN_DIM;
constexpr int G0 = PLAN_G0;
constexpr int T = TERRACE_LAT;
constexpr double COLM = 0.5; // column pitch, metres
constexpr double EPS = 1e-4; // priority-flood +epsilon (lattice units)
constexpr int16_t DRY = -32768;

// Homestead plug (routing obstacle only; real heights untouched).
constexpr double PLUG_LAT = 40;
constexpr double PLUG_R0 = 70;
constexpr double PLUG_R1 = 78;

// Tarn (waterplan.js "SOUTH-GATE TARN").
constexpr int TARN_TW = 2;
constexpr double TARN_LEV_LAT = TARN_TW * T;
constexpr double TARN_SILL_LAT = 11.5;
constexpr double TARN_JUNC_LAT = TARN_LEV_LAT + 0.05;
constexpr double TARN_NOTCH_W = 4.0;
constexpr double TARN_CHAN_W = 1.0;
constexpr double TARN_WALL_SLOPE = 8;
constexpr int TARN_FOOT_MIN = 300, TARN_FOOT_MAX = 800;

constexpr double BANK_RAISE_CAP = 24; // lattice units

// Deliberate falls.
constexpr int FALL_DROP = 2;
constexpr int FALL_WIN = 8;
constexpr int FALL_STEEP = 4;
constexpr int FALL_CLIFF_R = 4;
constexpr double FALL_MIN_R = 90;
constexpr int FALL_RIM_GAP = 16;
constexpr int FALL_LAKE_GAP = 2;
constexpr int FALL_ESCAPE = 5;
constexpr int FALL_SPACING = 40;

// Solver dials (the prototype's defaults; changing them changes the world).
constexpr double ACC_THR = 5200;
constexpr double MIN_LAKE_DEPTH_M = 1.0;
constexpr int MIN_LAKE_AREA_COLS = 500;
constexpr int MAX_LAKE_AREA_COLS = 6000;
constexpr double LAKE_ACC_MULT = 4;
constexpr int SPRING_POOL_R = 1;

const int NDX[8] = { -1, 0, 1, -1, 1, -1, 0, 1 };
const int NDZ[8] = { -1, -1, -1, 0, 0, 1, 1, 1 };
const double NDIST[8] = { M_SQRT2, 1, M_SQRT2, 1, 1, M_SQRT2, 1, M_SQRT2 };

inline double smoothstep(double t) { return t * t * (3 - 2 * t); }
inline double clampd(double v, double a, double b) { return std::max(a, std::min(b, v)); }
inline double jround(double v) { return std::floor(v + 0.5); }

// ------------------------------------------------------------- hydrology.js primitives
struct MinHeap {
	std::vector<double> k;
	std::vector<int32_t> v;
	int n = 0;
	explicit MinHeap(size_t cap) :
			k(cap), v(cap) {}
	void push(double key, int32_t val) {
		int i = n++;
		k[i] = key;
		v[i] = val;
		while (i > 0) {
			int p = (i - 1) >> 1;
			if (k[p] <= k[i]) break;
			std::swap(k[p], k[i]);
			std::swap(v[p], v[i]);
			i = p;
		}
	}
	int32_t pop() {
		int32_t topV = v[0];
		int nn = --n;
		k[0] = k[nn];
		v[0] = v[nn];
		int i = 0;
		for (;;) {
			int l = 2 * i + 1, r = l + 1, m = i;
			if (l < nn && k[l] < k[m]) m = l;
			if (r < nn && k[r] < k[m]) m = r;
			if (m == i) break;
			std::swap(k[m], k[i]);
			std::swap(v[m], v[i]);
			i = m;
		}
		return topV;
	}
};

// Barnes priority-flood with the pit-FIFO fast path (hydrology.js priorityFlood).
std::vector<double> priority_flood(const std::vector<double> &h, int dim, double eps) {
	const int n = dim * dim;
	std::vector<double> fill(h);
	std::vector<uint8_t> visited(n, 0);
	MinHeap heap((size_t)n + 8);
	std::vector<int32_t> pitQ(n);
	int pitHead = 0, pitTail = 0;
	for (int i = 0; i < dim; i++) {
		const int edges[4] = { i, (dim - 1) * dim + i, i * dim, i * dim + dim - 1 };
		for (int e = 0; e < 4; e++) {
			int c = edges[e];
			if (!visited[c]) {
				visited[c] = 1;
				heap.push(fill[c], c);
			}
		}
	}
	while (pitHead < pitTail || heap.n > 0) {
		int c;
		if (pitHead < pitTail && (heap.n == 0 || fill[pitQ[pitHead]] <= heap.k[0])) {
			c = pitQ[pitHead++];
		} else {
			c = heap.pop();
		}
		const double cf = fill[c];
		const int ci = c % dim, cj = c / dim;
		for (int k = 0; k < 8; k++) {
			const int ni = ci + NDX[k], nj = cj + NDZ[k];
			if (ni < 0 || nj < 0 || ni >= dim || nj >= dim) continue;
			const int m = nj * dim + ni;
			if (visited[m]) continue;
			visited[m] = 1;
			const double raised = cf + eps;
			if (fill[m] <= raised) {
				fill[m] = raised;
				pitQ[pitTail++] = m;
			} else {
				heap.push(fill[m], m);
			}
		}
	}
	return fill;
}

// ------------------------------------------------------------- protected assets
// waterplan.js PROTECTED-ASSET MASK (C4.12). SHIELD_R is also the tarn inlet's outer reach.
inline double shield_r() { return 120 / std::sqrt(3.0); }
const AssetRect PATROL_RECT = { 13, 21, -5, 5 };
const AssetRect MESA_RECT = { 3.5, 8.5, -2.5, 2.5 };

inline double col_r(int gx, int gz) {
	const double x = (gx + 0.5) * COLM, z = (gz + 0.5) * COLM;
	return std::sqrt(x * x + z * z);
}

bool protected_col(int gx, int gz, double pad) {
	const double x = (gx + 0.5) * COLM, z = (gz + 0.5) * COLM;
	if (x >= PATROL_RECT.x0 - pad && x <= PATROL_RECT.x1 + pad && z >= PATROL_RECT.z0 - pad && z <= PATROL_RECT.z1 + pad) return true;
	if (x >= MESA_RECT.x0 - pad && x <= MESA_RECT.x1 + pad && z >= MESA_RECT.z0 - pad && z <= MESA_RECT.z1 + pad) return true;
	for (const AssetDisc &a : asset_discs()) {
		if (det_hypot(x - a.x, z - a.z) <= a.r + pad) return true;
	}
	return false;
}
constexpr double WATER_PAD = 1.5; // 1.5 m standoff beyond each asset
inline bool water_blocked(int gx, int gz) { return protected_col(gx, gz, WATER_PAD); }

// ------------------------------------------------------------- plan solve records
struct Dep {
	int id;
	int area = 0;
	double maxDepth = 0, spill = 0, floor = INF, sumWX = 0, sumWZ = 0, minR = INF;
	double inflowAcc = 0;
	std::vector<int32_t> cells;
};
struct Lake {
	int id;
	int tw;
	int area;
	int outIdx;
	int dep; // index into deps
};
enum SinkKind { SINK_DEAD, SINK_RIM, SINK_LAKE };
struct Course {
	std::vector<int32_t> idxs;
	int sinkKind = SINK_DEAD;
	bool sourceSpring = true; // else lake outlet
	int headIdx = 0;
	int fromLake = -1;
	int sinkIdx = -1;
	std::vector<int32_t> tw;
	std::vector<float> nfx, nfz;
	double maxAcc = 0;
	int order = 1;
};
struct PlannedFall {
	int lipIdx, recvIdx, twTop, twBottom;
};
struct FallPair {
	int lipC, recvC, twTop, twBottom;
};

} // namespace

const AssetRect ASSET_PATROL = PATROL_RECT;
const AssetRect ASSET_MESA = MESA_RECT;

const std::vector<AssetDisc> &asset_discs() {
	static const std::vector<AssetDisc> discs = [] {
		std::vector<AssetDisc> d = {
			{ 0, 0, 8 }, // spawn (covers the reactor, r 6)
			{ 12.0, -3.0, 2.5 }, // bot mule
			{ 14.2, 1.2, 2.5 }, // bot dray
		};
		const double R = 120 / std::sqrt(3.0); // sentinel hex circumradius
		for (int k = 0; k < 6; k++) {
			const double th = (k * 60) * M_PI / 180;
			d.push_back({ R * det_cos(th), R * det_sin(th), 3 });
		}
		return d;
	}();
	return discs;
}

namespace {

// ============================================================================
// The solve. One long function, like the prototype, so every section reads the same
// locals as the JS does.
// ============================================================================
void solve_impl(int32_t seed, WaterPlan &plan) {
	const double accThr = ACC_THR;
	const int n = DIM * DIM;
	auto planIdxL = [](int gx, int gz) { return (gz - G0) * DIM + (gx - G0); };

	// Protected-asset masks, precomputed once.
	std::vector<uint8_t> protMask(n, 0), blockMask(n, 0);
	{
		const int lim = (int)std::ceil(95 / COLM);
		const int i0 = std::max(0, -lim - G0), i1 = std::min(DIM - 1, lim - G0);
		for (int j = i0; j <= i1; j++) {
			for (int i = i0; i <= i1; i++) {
				const int gx = G0 + i, gz = G0 + j, c = j * DIM + i;
				if (protected_col(gx, gz, 0)) protMask[c] = 1;
				if (water_blocked(gx, gz)) blockMask[c] = 1;
			}
		}
	}

	// 1. Heights: real field hCont (natural display terrain, coset-B representative)
	std::vector<double> hCont(n);
	for (int j = 0; j < DIM; j++) {
		const int gz = G0 + j, cz = 4 * gz + 2;
		for (int i = 0; i < DIM; i++) hCont[j * DIM + i] = surface_height_base(4 * (G0 + i) + 2, cz, seed);
	}

	// 1b-pre. Per-seed tarn pocket search.
	int tarnSeedGx = 40, tarnSeedGz = -49;
	{
		const int BANDS[3][2] = { { 20, 55 }, { 15, 60 }, { 10, 66 } };
		int bestC = -1;
		double bestH = INF;
		for (const auto &band : BANDS) {
			const double r0 = band[0], r1 = band[1];
			const int lim = (int)std::ceil(r1 / COLM);
			const int i0 = std::max(0, -lim - G0), i1 = std::min(DIM - 1, lim - G0);
			for (int j = i0; j <= i1; j++) {
				const int gz = G0 + j;
				for (int i = i0; i <= i1; i++) {
					const int gx = G0 + i, c = j * DIM + i;
					const double r = col_r(gx, gz);
					if (r < r0 || r > r1) continue;
					if (blockMask[c]) continue;
					if (hCont[c] < bestH) {
						bestH = hCont[c];
						bestC = c;
					}
				}
			}
			if (bestC >= 0) break;
		}
		if (bestC >= 0) {
			tarnSeedGx = G0 + (bestC % DIM);
			tarnSeedGz = G0 + bestC / DIM;
		}
	}
	const double tarnSeedX = (tarnSeedGx + 0.5) * COLM, tarnSeedZ = (tarnSeedGz + 0.5) * COLM;
	const double tarnBearing = det_atan2(tarnSeedZ, tarnSeedX);
	const double SHIELD_R = shield_r();

	// Per-seed inlet corridor.
	const double TARN_R_OUTER = SHIELD_R;
	std::vector<std::array<double, 2>> tarnGully;
	double sillX = 0, sillZ = 0;
	bool tarnHasInlet = false;
	{
		const double cosB = det_cos(tarnBearing), sinB = det_sin(tarnBearing);
		const double rInner = std::max(col_r(tarnSeedGx, tarnSeedGz) - 2, 4.0);
		bool clear = true;
		const int STEPS = 160;
		for (int s = 0; s <= STEPS && clear; s++) {
			const double r = rInner + (TARN_R_OUTER - rInner) * s / STEPS;
			const double x = r * cosB, z = r * sinB;
			if (water_blocked((int)std::floor(x / COLM), (int)std::floor(z / COLM))) clear = false;
		}
		if (clear) {
			tarnGully = { { TARN_R_OUTER * cosB, TARN_R_OUTER * sinB }, { SHIELD_R * cosB, SHIELD_R * sinB }, { rInner * cosB, rInner * sinB } };
			sillX = SHIELD_R * cosB;
			sillZ = SHIELD_R * sinB;
			tarnHasInlet = true;
		}
	}

	// 1b. South-gate tarn design pass.
	std::vector<double> dsgnCeil(n, INF), dsgnFloor(n, -INF);
	std::vector<uint8_t> notchMask(n, 0), tarnMask(n, 0), inletMask(n, 0);
	std::vector<int32_t> inletCells;

	if (tarnHasInlet) {
		const auto &P = tarnGully;
		std::vector<double> segLen, segS = { 0 };
		for (size_t k = 0; k + 1 < P.size(); k++) {
			const double L = det_hypot(P[k + 1][0] - P[k][0], P[k + 1][1] - P[k][1]);
			segLen.push_back(L);
			segS.push_back(segS[k] + L);
		}
		const double sEnd = segS.back();
		auto project = [&](double x, double z, double &dOut, double &sOut) {
			double bd = INF, bs = 0;
			for (size_t k = 0; k + 1 < P.size(); k++) {
				const double ax = P[k][0], az = P[k][1];
				const double bx = P[k + 1][0], bz = P[k + 1][1];
				const double vx = bx - ax, vz = bz - az;
				const double t = clampd(((x - ax) * vx + (z - az) * vz) / (vx * vx + vz * vz), 0, 1);
				const double px = ax + t * vx, pz = az + t * vz;
				const double d = det_hypot(x - px, z - pz);
				if (d < bd) {
					bd = d;
					bs = segS[k] + t * segLen[k];
				}
			}
			dOut = bd;
			sOut = bs;
		};
		double dd, sSill;
		project(sillX, sillZ, dd, sSill);
		double xMin = INF, xMax = -INF, zMin = INF, zMax = -INF;
		for (const auto &p : P) {
			xMin = std::min(xMin, p[0]);
			xMax = std::max(xMax, p[0]);
			zMin = std::min(zMin, p[1]);
			zMax = std::max(zMax, p[1]);
		}
		const double pad = TARN_NOTCH_W + 0.5;
		const int gi0 = (int)std::max(0.0, std::floor((xMin - pad) / COLM - 0.5) - G0);
		const int gi1 = (int)std::min((double)(DIM - 1), std::ceil((xMax + pad) / COLM) - G0);
		const int gj0 = (int)std::max(0.0, std::floor((zMin - pad) / COLM - 0.5) - G0);
		const int gj1 = (int)std::min((double)(DIM - 1), std::ceil((zMax + pad) / COLM) - G0);
		for (int j = gj0; j <= gj1; j++) {
			for (int i = gi0; i <= gi1; i++) {
				const double x = (G0 + i + 0.5) * COLM, z = (G0 + j + 0.5) * COLM;
				double d, s;
				project(x, z, d, s);
				if (d > TARN_NOTCH_W) continue;
				const int c = j * DIM + i;
				notchMask[c] = 1;
				if (s < sSill) continue;
				const double centre = TARN_SILL_LAT - (TARN_SILL_LAT - TARN_JUNC_LAT) * (s - sSill) / (sEnd - sSill);
				const double target = centre + TARN_WALL_SLOPE * std::max(0.0, d - TARN_CHAN_W);
				if (protMask[c]) continue;
				if (target < dsgnCeil[c]) dsgnCeil[c] = target;
			}
		}
	}

	// Pond footprint: guaranteed excavation, 4-conn flood, 8-conn boundary ring, bowl.
	{
		const int seedIdx = planIdxL(tarnSeedGx, tarnSeedGz);
		const int FORCE_RADII[5] = { 12, 14, 17, 20, 24 };
		bool haveCells = false;
		std::vector<int32_t> tarnCells;
		for (int R : FORCE_RADII) {
			std::fill(tarnMask.begin(), tarnMask.end(), 0);
			for (int dj = -R; dj <= R; dj++) {
				for (int di = -R; di <= R; di++) {
					if (di * di + dj * dj > R * R) continue;
					const int gx = tarnSeedGx + di, gz = tarnSeedGz + dj;
					const int i = gx - G0, j = gz - G0;
					if (i < 0 || j < 0 || i >= DIM || j >= DIM) continue;
					const int c = j * DIM + i;
					if (protMask[c]) continue;
					const double forced = TARN_LEV_LAT - 0.5;
					if (forced < dsgnCeil[c]) dsgnCeil[c] = forced;
				}
			}
			std::vector<int32_t> stack = { seedIdx };
			tarnMask[seedIdx] = 1;
			std::vector<int32_t> cells = { seedIdx };
			while (!stack.empty()) {
				const int c = stack.back();
				stack.pop_back();
				const int i = c % DIM, j = c / DIM;
				const int nb[4] = { c + 1, c - 1, c + DIM, c - DIM };
				for (int m : nb) {
					if (m < 0 || m >= n || tarnMask[m]) continue;
					if (std::abs((m % DIM) - i) + std::abs((m / DIM) - j) != 1) continue;
					const int mi = m % DIM, mj = m / DIM;
					if (col_r(G0 + mi, G0 + mj) > 74) continue;
					if (!(dsgnCeil[m] < TARN_LEV_LAT)) continue;
					tarnMask[m] = 1;
					stack.push_back(m);
					cells.push_back(m);
				}
			}
			std::vector<int32_t> ring;
			for (int c : cells) {
				const int i = c % DIM, j = c / DIM;
				for (int k = 0; k < 8; k++) {
					const int ni = i + NDX[k], nj = j + NDZ[k];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					if (tarnMask[m]) continue;
					const double h = std::min(hCont[m], dsgnCeil[m]);
					if (h < TARN_LEV_LAT || h >= TARN_LEV_LAT + T) continue;
					if (col_r(G0 + ni, G0 + nj) >= PLUG_R0) continue;
					if (blockMask[m]) continue;
					tarnMask[m] = 1;
					ring.push_back(m);
				}
			}
			for (int m : ring) cells.push_back(m);
			if ((int)cells.size() < TARN_FOOT_MIN || (int)cells.size() > TARN_FOOT_MAX) continue;
			tarnCells = cells;
			haveCells = true;
			break;
		}
		if (!haveCells) {
			throw PlanFail("tarn pocket at (" + std::to_string(tarnSeedGx) + "," + std::to_string(tarnSeedGz) + ") could not reach the designed 300-800 col window at any tried radius");
		}
		std::vector<int32_t> dist(n, -1);
		std::vector<int32_t> frontier;
		for (int c : tarnCells) {
			bool edge = false;
			const int nb[4] = { c + 1, c - 1, c + DIM, c - DIM };
			for (int m : nb) {
				if (!tarnMask[m]) {
					edge = true;
					break;
				}
			}
			if (edge) {
				dist[c] = 1;
				frontier.push_back(c);
			}
		}
		int dCur = 1;
		while (!frontier.empty()) {
			std::vector<int32_t> next;
			for (int c : frontier) {
				const int nb[4] = { c + 1, c - 1, c + DIM, c - DIM };
				for (int m : nb) {
					if (!tarnMask[m] || dist[m] >= 0) continue;
					dist[m] = dCur + 1;
					next.push_back(m);
				}
			}
			frontier.swap(next);
			dCur++;
		}
		const double APRON = TARN_LEV_LAT - 0.5;
		for (int c : tarnCells) {
			const int d = dist[c] < 0 ? 1 : dist[c];
			const double bed = std::max(APRON - 2 * std::max(0, d - 2), 0.5);
			dsgnCeil[c] = std::min(dsgnCeil[c], bed);
			dsgnFloor[c] = bed;
			if (hCont[c] - bed < -16) throw PlanFail("tarn bowl floor raise exceeds 2 m");
			if (blockMask[c]) throw PlanFail("tarn footprint overlaps a protected asset buffer");
		}
	}

	// Design surface + routing copy with the (notched) homestead plug.
	std::vector<double> hDesign(n), hRoute(n);
	const int plugLim = (int)std::ceil(PLUG_R1 / COLM) + 1;
	for (int j = 0; j < DIM; j++) {
		const int gz = G0 + j;
		const bool rowInPlug = std::abs(gz) <= plugLim;
		for (int i = 0; i < DIM; i++) {
			const int c = j * DIM + i;
			hDesign[c] = std::max(std::min(hCont[c], dsgnCeil[c]), dsgnFloor[c]);
			double plug = 0;
			if (rowInPlug && std::abs(G0 + i) <= plugLim && !notchMask[c] && !tarnMask[c]) {
				const double r = col_r(G0 + i, gz);
				plug = r <= PLUG_R0 ? PLUG_LAT : r >= PLUG_R1 ? 0 : PLUG_LAT * (1 - smoothstep((r - PLUG_R0) / (PLUG_R1 - PLUG_R0)));
			}
			hRoute[c] = hDesign[c] + plug;
		}
	}

	// 2. Priority-flood (eps=0) on the routing field, label depressions (4-conn).
	const std::vector<double> fill0 = priority_flood(hRoute, DIM, 0);
	std::vector<int32_t> depId(n, -1);
	std::vector<Dep> deps;
	{
		std::vector<int32_t> stack(n);
		for (int c0 = 0; c0 < n; c0++) {
			if (depId[c0] >= 0 || fill0[c0] <= hRoute[c0] + 1e-9) continue;
			const int id = (int)deps.size();
			Dep d;
			d.id = id;
			d.spill = fill0[c0];
			int sp = 0;
			stack[sp++] = c0;
			depId[c0] = id;
			while (sp > 0) {
				const int c = stack[--sp];
				d.area++;
				d.cells.push_back(c);
				const double depth = fill0[c] - hRoute[c];
				if (depth > d.maxDepth) d.maxDepth = depth;
				if (hRoute[c] < d.floor) d.floor = hRoute[c];
				const int i = c % DIM, j = c / DIM;
				d.sumWX += (G0 + i + 0.5) * COLM;
				d.sumWZ += (G0 + j + 0.5) * COLM;
				const double r = col_r(G0 + i, G0 + j);
				if (r < d.minR) d.minR = r;
				if (i + 1 < DIM) { const int m = c + 1; if (depId[m] < 0 && fill0[m] > hRoute[m] + 1e-9) { depId[m] = id; stack[sp++] = m; } }
				if (i - 1 >= 0) { const int m = c - 1; if (depId[m] < 0 && fill0[m] > hRoute[m] + 1e-9) { depId[m] = id; stack[sp++] = m; } }
				if (j + 1 < DIM) { const int m = c + DIM; if (depId[m] < 0 && fill0[m] > hRoute[m] + 1e-9) { depId[m] = id; stack[sp++] = m; } }
				if (j - 1 >= 0) { const int m = c - DIM; if (depId[m] < 0 && fill0[m] > hRoute[m] + 1e-9) { depId[m] = id; stack[sp++] = m; } }
			}
			deps.push_back(std::move(d));
		}
	}

	// 3. D8 + accumulation on the all-breached routing field.
	std::vector<double> hBall(n);
	for (int c = 0; c < n; c++) hBall[c] = depId[c] >= 0 ? fill0[c] : hRoute[c];
	const std::vector<double> fillEps = priority_flood(hBall, DIM, EPS);
	std::vector<int32_t> d8(n, -1);
	int nOff[8];
	for (int k = 0; k < 8; k++) nOff[k] = NDZ[k] * DIM + NDX[k];
	for (int j = 1; j < DIM - 1; j++) {
		const int row = j * DIM;
		for (int i = 1; i < DIM - 1; i++) {
			const int c = row + i;
			const double hc = fillEps[c];
			double best = 0;
			int bestIdx = -1;
			for (int k = 0; k < 8; k++) {
				const int m = c + nOff[k];
				const double slope = (hc - fillEps[m]) / NDIST[k];
				if (slope > best) {
					best = slope;
					bestIdx = m;
				}
			}
			d8[c] = bestIdx;
		}
	}
	std::vector<uint32_t> acc(n, 0);
	std::vector<uint16_t> indeg(n, 0);
	for (int c = 0; c < n; c++)
		if (d8[c] >= 0) indeg[d8[c]]++;
	{
		std::vector<int32_t> queue(n);
		int qh = 0, qt = 0;
		for (int c = 0; c < n; c++) {
			const int gx = G0 + (c % DIM), gz = G0 + c / DIM;
			acc[c] = col_r(gx, gz) <= PLUG_R1 ? 0 : 1;
			if (indeg[c] == 0) queue[qt++] = c;
		}
		while (qh < qt) {
			const int c = queue[qh++], dn = d8[c];
			if (dn >= 0) {
				acc[dn] += acc[c];
				if (--indeg[dn] == 0) queue[qt++] = dn;
			}
		}
	}
	for (Dep &d : deps) {
		double m = 0;
		for (int c : d.cells)
			if (acc[c] > m) m = acc[c];
		d.inflowAcc = m;
	}

	// 4. Threshold lake selection.
	const double minDepthLat = MIN_LAKE_DEPTH_M * 8;
	const double lakeAccThr = LAKE_ACC_MULT * accThr;
	std::vector<int> candidates; // indices into deps
	for (size_t di = 0; di < deps.size(); di++) {
		const Dep &d = deps[di];
		if (d.maxDepth >= minDepthLat && d.area >= MIN_LAKE_AREA_COLS && d.area <= MAX_LAKE_AREA_COLS && d.inflowAcc >= lakeAccThr && d.minR > PLUG_R1) candidates.push_back((int)di);
	}
	std::vector<uint8_t> keptMask(n, 0);
	std::vector<int16_t> lakeOf(n, -1);
	for (size_t li = 0; li < candidates.size(); li++) {
		for (int c : deps[candidates[li]].cells) {
			keptMask[c] = 1;
			lakeOf[c] = (int16_t)li;
		}
	}
	for (int c = 0; c < n; c++)
		if (tarnMask[c]) keptMask[c] = 1;

	std::vector<double> raise(n, 0), raiseDisp(n, 0);
	for (const Dep &d : deps) {
		for (int c : d.cells) {
			if (keptMask[c]) continue;
			raise[c] = fill0[c] - hRoute[c];
			const int gx = G0 + (c % DIM), gz = G0 + c / DIM;
			raiseDisp[c] = col_r(gx, gz) <= PLUG_R1 ? 0 : raise[c];
		}
	}
	std::vector<double> hBed(n), hB(n);
	for (int c = 0; c < n; c++) {
		hBed[c] = hDesign[c] + raiseDisp[c];
		hB[c] = hRoute[c] + raise[c];
	}

	// 5. River mask, sources, lake outlets, course tracing.
	std::vector<uint8_t> riverMask(n, 0);
	for (int c = 0; c < n; c++)
		if (acc[c] > accThr && !keptMask[c]) riverMask[c] = 1;
	std::vector<uint8_t> upRiver(n, 0);
	for (int c = 0; c < n; c++) {
		if (!riverMask[c]) continue;
		const int dn = d8[c];
		if (dn >= 0 && riverMask[dn] && upRiver[dn] < 255) upRiver[dn]++;
	}
	std::vector<int32_t> sources;
	for (int c = 0; c < n; c++)
		if (riverMask[c] && upRiver[c] == 0) sources.push_back(c);

	std::vector<Lake> lakes;
	for (size_t li = 0; li < candidates.size(); li++) {
		const Dep &d = deps[candidates[li]];
		int outIdx = -1;
		double outH = INF;
		for (int c : d.cells) {
			const int i = c % DIM, j = c / DIM;
			for (int k = 0; k < 8; k++) {
				const int ni = i + NDX[k], nj = j + NDZ[k];
				if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
				const int m = nj * DIM + ni;
				if (lakeOf[m] == (int)li) continue;
				if (hB[m] < outH) {
					outH = hB[m];
					outIdx = m;
				}
			}
		}
		Lake lk;
		lk.id = (int)li;
		lk.tw = (int)std::floor(d.spill / T);
		lk.area = d.area;
		lk.outIdx = outIdx;
		lk.dep = candidates[li];
		lakes.push_back(lk);
	}

	auto trace = [&](int startIdx, Course &co) {
		co.idxs.assign(1, startIdx);
		int cur = startIdx;
		co.sinkKind = SINK_DEAD;
		for (int step = 0; step < n; step++) {
			const int dn = d8[cur];
			if (dn < 0) {
				const int i = cur % DIM, j = cur / DIM;
				co.sinkKind = (i == 0 || j == 0 || i == DIM - 1 || j == DIM - 1) ? SINK_RIM : SINK_DEAD;
				break;
			}
			if (keptMask[dn]) {
				co.sinkKind = SINK_LAKE;
				break;
			}
			co.idxs.push_back(dn);
			cur = dn;
		}
	};

	std::vector<Course> courses;
	for (int s : sources) {
		Course co;
		trace(s, co);
		co.sourceSpring = true;
		co.headIdx = s;
		courses.push_back(std::move(co));
	}
	for (const Lake &lk : lakes) {
		if (lk.outIdx < 0) continue;
		Course co;
		trace(lk.outIdx, co);
		co.sourceSpring = false;
		co.headIdx = lk.outIdx;
		co.fromLake = lk.id;
		courses.push_back(std::move(co));
	}

	// Designed inlet (C4.10).
	if (tarnHasInlet) {
		std::vector<std::array<double, 2>> wp = tarnGully;
		wp.push_back({ tarnSeedX, tarnSeedZ });
		std::vector<int32_t> idxs;
		int sinkIdx = -1;
		int cgx = (int)jround(wp[0][0] / COLM - 0.5);
		int cgz = (int)jround(wp[0][1] / COLM - 0.5);
		for (size_t k = 0; k < wp.size() && sinkIdx < 0; k++) {
			const int tgx = (int)jround(wp[k][0] / COLM - 0.5);
			const int tgz = (int)jround(wp[k][1] / COLM - 0.5);
			for (int guard = 0; guard < 4 * DIM; guard++) {
				const int c = planIdxL(cgx, cgz);
				if (tarnMask[c]) {
					sinkIdx = c;
					break;
				}
				if (idxs.empty() || idxs.back() != c) idxs.push_back(c);
				if (cgx == tgx && cgz == tgz) break;
				cgx += (tgx > cgx) - (tgx < cgx);
				cgz += (tgz > cgz) - (tgz < cgz);
			}
		}
		if (sinkIdx < 0) throw PlanFail("designed inlet never reaches the tarn footprint");
		for (int c : idxs) inletMask[c] = 1;
		inletCells = idxs;
		Course co;
		co.idxs = idxs;
		co.sinkKind = SINK_LAKE;
		co.sourceSpring = true;
		co.headIdx = idxs[0];
		co.sinkIdx = sinkIdx;
		courses.push_back(std::move(co));
	}

	// Levels: suffix-max of bed heights downstream, terraced; caps; order.
	for (Course &co : courses) {
		const int m = (int)co.idxs.size();
		co.tw.assign(m, 0);
		double lvl = -INF;
		for (int i = m - 1; i >= 0; i--) {
			lvl = std::max(lvl, hBed[co.idxs[i]]);
			co.tw[i] = (int32_t)std::floor(lvl / T);
		}
		for (int i = 0; i + 1 < m; i++) {
			const int capLevel = co.tw[i] - FALL_DROP;
			if (co.tw[i + 1] < capLevel) co.tw[i + 1] = capLevel;
		}
		for (int i = 0; i < m; i++) {
			const int cc = co.idxs[i];
			const double r = col_r(G0 + (cc % DIM), G0 + cc / DIM);
			if (r < PLUG_R0 && co.tw[i] > TARN_TW) co.tw[i] = TARN_TW;
		}
		for (int i = 1; i < m; i++)
			if (co.tw[i] > co.tw[i - 1]) co.tw[i] = co.tw[i - 1];
		double maxAcc = 0;
		for (int c : co.idxs)
			if (acc[c] > maxAcc) maxAcc = acc[c];
		co.maxAcc = maxAcc;
		co.order = (int)clampd(jround(det_log2(std::max(maxAcc, accThr) / accThr)), 1, 5);
	}
	std::stable_sort(courses.begin(), courses.end(), [](const Course &a, const Course &b) {
		if (b.maxAcc != a.maxAcc) return b.maxAcc < a.maxAcc;
		if (b.idxs.size() != a.idxs.size()) return b.idxs.size() < a.idxs.size();
		return a.headIdx < b.headIdx;
	});

	// 5b. Deliberate fall placement.
	std::vector<PlannedFall> plannedFalls;
	{
		std::vector<std::array<int, 2>> chosenLips;
		std::unordered_set<int> lipSeen;
		for (Course &co : courses) {
			for (int i = 0; i + 1 < (int)co.idxs.size(); i++) {
				const int hiTw = co.tw[i];
				int j = i + 1;
				while (j < (int)co.idxs.size() && hiTw - co.tw[j] < FALL_DROP && j - i <= FALL_WIN) j++;
				if (j >= (int)co.idxs.size() || hiTw - co.tw[j] < FALL_DROP || j - i > FALL_WIN) continue;
				const int lipC = co.idxs[i], recvC = co.idxs[i + 1];
				if (lipSeen.count(lipC)) continue;
				const int li = lipC % DIM, lj = lipC / DIM;
				const int lgx = G0 + li, lgz = G0 + lj;
				const int rimDist = std::min({ li, lj, DIM - 1 - li, DIM - 1 - lj });
				if (rimDist < FALL_RIM_GAP) continue;
				if (col_r(lgx, lgz) <= FALL_MIN_R) continue;
				bool tooClose = false;
				for (const auto &lp : chosenLips)
					if (std::max(std::abs(lp[0] - li), std::abs(lp[1] - lj)) < FALL_SPACING) tooClose = true;
				if (tooClose) continue;
				if (j - i > FALL_STEEP) {
					double cliff = 0;
					for (int dj = -FALL_CLIFF_R; dj <= FALL_CLIFF_R && cliff <= 0; dj++) {
						for (int di = -FALL_CLIFF_R; di <= FALL_CLIFF_R; di++) {
							const double cl = cliff_lift_at(4 * (lgx + di) + 2, 4 * (lgz + dj) + 2, seed);
							if (cl > 0) {
								cliff = cl;
								break;
							}
						}
					}
					if (cliff <= 0) continue;
				}
				const int ri = recvC % DIM, rj = recvC / DIM;
				bool nearLake = false;
				for (int dj = -FALL_LAKE_GAP; dj <= FALL_LAKE_GAP && !nearLake; dj++) {
					for (int di = -FALL_LAKE_GAP; di <= FALL_LAKE_GAP; di++) {
						const int bases[2][2] = { { li, lj }, { ri, rj } };
						for (const auto &bb : bases) {
							const int ni = bb[0] + di, nj = bb[1] + dj;
							if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
							if (keptMask[nj * DIM + ni]) {
								nearLake = true;
								break;
							}
						}
						if (nearLake) break;
					}
				}
				if (nearLake) continue;
				{
					std::unordered_set<int> own;
					for (int k = std::max(0, i - 3); k <= std::min((int)co.idxs.size() - 1, i + 14); k++) own.insert(co.idxs[k]);
					double escape = INF;
					for (const Course &co2 : courses) {
						for (int q = 0; q < (int)co2.idxs.size() && escape >= FALL_ESCAPE; q++) {
							if (co2.tw[q] < hiTw) continue;
							const int qc = co2.idxs[q];
							if (own.count(qc)) continue;
							const int qi = qc % DIM, qj = qc / DIM;
							for (int k = i + 1; k <= std::min(i + 10, (int)co.idxs.size() - 1); k++) {
								const int kc = co.idxs[k];
								const double d = std::max(std::abs((kc % DIM) - qi), std::abs(kc / DIM - qj));
								if (d < escape) escape = d;
							}
						}
						if (escape < FALL_ESCAPE) break;
					}
					if (escape < FALL_ESCAPE) continue;
				}
				bool masked = false;
				for (int dj = -3; dj <= 3 && !masked; dj++) {
					for (int di = -3; di <= 3; di++) {
						const int ni = li + di, nj = lj + dj;
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						if (protMask[m] || blockMask[m]) {
							masked = true;
							break;
						}
					}
				}
				if (masked) continue;
				lipSeen.insert(lipC);
				chosenLips.push_back({ li, lj });
				plannedFalls.push_back({ lipC, recvC, hiTw, hiTw - FALL_DROP });
				i = j - 1;
			}
		}
		for (const PlannedFall &pf : plannedFalls) {
			for (Course &co : courses) {
				for (int i = 0; i + 1 < (int)co.idxs.size(); i++) {
					if (co.idxs[i] != pf.lipIdx || co.idxs[i + 1] != pf.recvIdx) continue;
					if (co.tw[i] != pf.twTop) continue;
					for (int k = i + 1; k < (int)co.idxs.size(); k++)
						if (co.tw[k] > pf.twBottom) co.tw[k] = pf.twBottom;
					break;
				}
			}
		}
	}

	std::vector<int16_t> courseTwMax(n, -32768);
	for (const Course &co : courses) {
		for (size_t i = 0; i < co.idxs.size(); i++) {
			const int c = co.idxs[i];
			if (co.tw[i] > courseTwMax[c]) courseTwMax[c] = (int16_t)co.tw[i];
		}
	}

	// 6. Fill plan fields.
	std::vector<int16_t> waterTw(n, DRY);
	std::vector<uint8_t> waterType(n, 0);
	std::vector<float> flowX(n, 0), flowZ(n, 0);
	for (const Lake &lk : lakes) {
		for (int c : deps[lk.dep].cells) {
			waterTw[c] = (int16_t)lk.tw;
			waterType[c] = TYPE_LAKE;
		}
	}
	for (int c = 0; c < n; c++) {
		if (tarnMask[c]) {
			waterTw[c] = TARN_TW;
			waterType[c] = TYPE_LAKE;
		}
	}
	for (const Course &co : courses) {
		for (size_t i = 0; i < co.idxs.size(); i++) {
			const int c = co.idxs[i];
			if (blockMask[c]) continue;
			if (waterType[c] == TYPE_LAKE) continue;
			if (waterTw[c] == DRY) {
				waterTw[c] = (int16_t)co.tw[i];
				waterType[c] = TYPE_RIVER;
			}
		}
	}
	std::vector<PlanFall> falls;
	std::vector<FallPair> fallPairs;
	std::unordered_set<int> fallSeen;
	for (const Course &co : courses) {
		for (int i = 0; i + 1 < (int)co.idxs.size(); i++) {
			if (co.tw[i] - co.tw[i + 1] < 2) continue;
			const int c = co.idxs[i + 1];
			if (waterType[c] != TYPE_RIVER || fallSeen.count(c)) continue;
			fallSeen.insert(c);
			waterType[c] = TYPE_FALL;
			falls.push_back({ G0 + (c % DIM), G0 + c / DIM, co.tw[i], co.tw[i + 1] });
			fallPairs.push_back({ co.idxs[i], c, co.tw[i], co.tw[i + 1] });
		}
	}
	std::vector<int16_t> fallZoneHi(n, -1), fallZoneLo(n, -1);
	for (size_t fi = 0; fi < fallPairs.size(); fi++) {
		const FallPair &pf = fallPairs[fi];
		for (int which = 0; which < 2; which++) {
			const int zc = which == 0 ? pf.lipC : pf.recvC;
			std::vector<int16_t> &arr = which == 0 ? fallZoneHi : fallZoneLo;
			const int zi = zc % DIM, zj = zc / DIM;
			for (int dj = -1; dj <= 1; dj++) {
				for (int di = -1; di <= 1; di++) {
					const int ni = zi + di, nj = zj + dj;
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					arr[nj * DIM + ni] = (int16_t)fi;
				}
			}
		}
	}
	auto fallFaceExempt = [&](int a, int twA, int b, int twB) {
		if (twA < twB) {
			std::swap(a, b);
			std::swap(twA, twB);
		}
		const int fi = fallZoneHi[a];
		if (fi < 0 || fallZoneLo[b] != fi) return false;
		const FallPair &pf = fallPairs[fi];
		return twA == pf.twTop && twB == pf.twBottom;
	};
	std::vector<uint8_t> fallShadow(n, 0);
	for (const FallPair &pf : fallPairs) {
		const int zcs[2] = { pf.lipC, pf.recvC };
		for (int zc : zcs) {
			const int zi = zc % DIM, zj = zc / DIM;
			for (int dj = -2; dj <= 2; dj++) {
				for (int di = -2; di <= 2; di++) {
					const int ni = zi + di, nj = zj + dj;
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					fallShadow[nj * DIM + ni] = 1;
				}
			}
		}
	}
	auto fallPinned = [&](int c, int tw) {
		return (fallZoneHi[c] >= 0 && c == fallPairs[fallZoneHi[c]].lipC && tw == fallPairs[fallZoneHi[c]].twTop) ||
				(fallZoneLo[c] >= 0 && c == fallPairs[fallZoneLo[c]].recvC && tw == fallPairs[fallZoneLo[c]].twBottom);
	};
	std::vector<uint8_t> fallFrozen(n, 0);
	for (const FallPair &pf : fallPairs) fallFrozen[pf.recvC] = 1;

	// outlet masks are needed by lakeCapAt (declared below in the JS, before first use there too)
	std::vector<uint8_t> outletMask(n, 0);
	for (const Lake &lk : lakes)
		if (lk.outIdx >= 0) outletMask[lk.outIdx] = 1;

	auto lakeCapAt = [&](int i, int j) -> double {
		double cap = INF;
		for (int dq = 1; dq <= 6; dq++) {
			const int ring = (dq + 1) >> 1;
			if (cap <= ring) break;
			for (int qj = -dq; qj <= dq; qj++) {
				const int xj = j + qj;
				if (xj < 0 || xj >= DIM) continue;
				for (int qi = -dq; qi <= dq; qi++) {
					if (std::max(std::abs(qi), std::abs(qj)) != dq) continue;
					const int xi = i + qi;
					if (xi < 0 || xi >= DIM) continue;
					const int q = xj * DIM + xi;
					if (waterTw[q] != DRY && (keptMask[q] || outletMask[q] || fallFrozen[q])) {
						const double v = waterTw[q] + ring;
						if (v < cap) cap = v;
					}
				}
			}
		}
		return cap;
	};

	// Flow vectors: exact D8-hop unit directions per course node.
	std::vector<uint8_t> flowClaimed(n, 0);
	for (Course &co : courses) {
		const int m = (int)co.idxs.size();
		co.nfx.assign(m, 0);
		co.nfz.assign(m, 0);
		for (int i = 0; i < m; i++) {
			const int c = co.idxs[i];
			int dn = i + 1 < m ? co.idxs[i + 1] : (co.sinkIdx >= 0 ? co.sinkIdx : d8[c]);
			if (dn < 0 && i > 0) {
				co.nfx[i] = co.nfx[i - 1];
				co.nfz[i] = co.nfz[i - 1];
				continue;
			}
			if (dn < 0) continue;
			const double dx = (dn % DIM) - (c % DIM);
			const double dz = (dn / DIM) - (c / DIM);
			double len = det_hypot(dx, dz);
			if (len == 0) len = 1;
			co.nfx[i] = (float)(dx / len);
			co.nfz[i] = (float)(dz / len);
		}
		for (int i = 0; i < m; i++) {
			const int c = co.idxs[i];
			if (flowClaimed[c]) continue;
			flowClaimed[c] = 1;
			flowX[c] = co.nfx[i];
			flowZ[c] = co.nfz[i];
		}
	}

	// 7. Target-elevation carve (C1.2): ceilings in bedT, raise floors in breachT/bank7cT/floorT.
	std::vector<double> bedT(n, INF), breachT(n, -INF), bank7cT(n, -INF), floorT(dsgnFloor);
	for (int c = 0; c < n; c++)
		if (dsgnCeil[c] < bedT[c]) bedT[c] = dsgnCeil[c];
	for (int c = 0; c < n; c++)
		if (raiseDisp[c] > 0) breachT[c] = std::min(hBed[c], hCont[c] + BANK_RAISE_CAP);

	// Springs: every spring-kind course head that is not a lake outlet -> small ponded bowl.
	for (const Course &co : courses) {
		if (!co.sourceSpring || outletMask[co.headIdx]) continue;
		const int head = co.headIdx, htw = co.tw[0];
		const int hi = head % DIM, hj = head / DIM;
		const int R = SPRING_POOL_R;
		for (int dj = -R; dj <= R; dj++) {
			for (int di = -R; di <= R; di++) {
				const double dist = det_hypot(di, dj);
				if (dist > R + 1e-9) continue;
				const int ni = hi + di, nj = hj + dj;
				if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
				const int c = nj * DIM + ni;
				if (blockMask[c]) continue;
				if (keptMask[c]) continue;
				if (htw > lakeCapAt(ni, nj)) continue;
				const double origT = std::floor(hBed[c] / T);
				if (origT < htw - 1 || origT > htw + 2) continue;
				const double extra = T * (1 - smoothstep(clampd(dist / (R + 0.5), 0, 1)));
				const double target = htw * T - 0.5 - extra;
				if (target < bedT[c]) bedT[c] = target;
				if (waterTw[c] == DRY) {
					waterTw[c] = (int16_t)htw;
					waterType[c] = TYPE_SPRING;
				}
			}
		}
		if (waterType[head] == TYPE_RIVER || waterType[head] == TYPE_FALL) waterType[head] = TYPE_SPRING;
	}

	// 7a. Valley carve along river polylines.
	auto chanW = [](double o) { return 1.3 + 0.5 * o; };
	const double CARVE_CAP = 40;
	for (const Course &co : courses) {
		for (size_t i = 0; i < co.idxs.size(); i++) {
			const int c = co.idxs[i];
			const double o = clampd(det_log2(std::max((double)acc[c], accThr) / accThr), 0, 4);
			const double Wbed = 1 + 0.5 * o;
			const double Wchan = chanW(o);
			const double Wtop = std::min(6.0, Wchan + 2);
			const double Dfull = T * (1.5 + 0.6 * o);
			const double levLat = co.tw[i] * T;
			const int ci = c % DIM, cj = c / DIM;
			const int Rr = (int)std::ceil(Wtop);
			for (int dj = -Rr; dj <= Rr; dj++) {
				for (int di = -Rr; di <= Rr; di++) {
					const double dist = det_hypot(di, dj);
					if (dist > Wtop) continue;
					const int ni = ci + di, nj = cj + dj;
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					if (keptMask[m]) continue;
					if (protMask[m]) continue;
					if (courseTwMax[m] > co.tw[i]) continue;
					double target;
					if (dist <= Wchan) {
						target = dist <= Wbed ? levLat - Dfull : levLat - Dfull * (1 - smoothstep((dist - Wbed) / (Wchan - Wbed)));
					} else {
						if (hBed[m] <= levLat) continue;
						const double fallB = 1 - smoothstep((dist - Wchan) / (Wtop - Wchan));
						target = hBed[m] - fallB * (hBed[m] - levLat);
					}
					target = std::max(target, hBed[m] - CARVE_CAP);
					if (target < bedT[m]) bedT[m] = target;
				}
			}
		}
	}

	// 7a'. Lake deepening.
	for (const Lake &lk : lakes) {
		const Dep &d = deps[lk.dep];
		for (int c : d.cells) {
			const double t = clampd((fill0[c] - hRoute[c]) / std::max(d.spill - d.floor, 1.0), 0, 1);
			const double target = (lk.tw - 1) * T - 0.5 - 2 * T * smoothstep(t);
			if (target < bedT[c]) bedT[c] = target;
		}
	}

	// 7a''. Headroom enforcement (both cosets).
	for (int c = 0; c < n; c++) {
		if (waterTw[c] == DRY || waterType[c] == TYPE_LAKE) continue;
		const double target = waterTw[c] * T - 0.5;
		if (target < bedT[c]) bedT[c] = target;
	}

	// 7b. Widen water to fill the carved channel.
	std::vector<uint8_t> widened(n, 0);
	for (const Course &co : courses) {
		for (size_t i = 0; i < co.idxs.size(); i++) {
			const int c = co.idxs[i];
			const double o = clampd(det_log2(std::max((double)acc[c], accThr) / accThr), 0, 4);
			const double Wwet = chanW(o) + 0.25;
			const int tw = co.tw[i];
			const double levLat = tw * T;
			const int ci = c % DIM, cj = c / DIM;
			const int Rr = (int)std::ceil(Wwet);
			for (int dj = -Rr; dj <= Rr; dj++) {
				for (int di = -Rr; di <= Rr; di++) {
					if (det_hypot(di, dj) > Wwet) continue;
					const int ni = ci + di, nj = cj + dj;
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					if (keptMask[m]) continue;
					if (blockMask[m]) continue;
					const bool claimable = waterTw[m] == DRY || (widened[m] && tw < waterTw[m]);
					if (!claimable) continue;
					if (std::min(hBed[m], bedT[m]) >= levLat - 1e-9) continue;
					bool lakeClash = false;
					for (int k = 0; k < 8; k++) {
						const int qi = ni + NDX[k], qj = nj + NDZ[k];
						if (qi < 0 || qj < 0 || qi >= DIM || qj >= DIM) continue;
						const int q = qj * DIM + qi;
						if (keptMask[q] && waterTw[q] != DRY && tw - waterTw[q] >= 2) {
							lakeClash = true;
							break;
						}
					}
					if (lakeClash) continue;
					waterTw[m] = (int16_t)tw;
					waterType[m] = TYPE_RIVER;
					flowX[m] = co.nfx[i];
					flowZ[m] = co.nfz[i];
					widened[m] = 1;
				}
			}
		}
	}
	for (int c = 0; c < n; c++) {
		if (!widened[c]) continue;
		const double target = waterTw[c] * T - 0.5;
		if (target < bedT[c]) bedT[c] = target;
	}

	// 7b'. Junction reconciliation -- joint fixpoint of level relaxation and the worklist.
	{
		auto cutEdge = [&](int a, int b) {
			return (fallZoneHi[a] >= 0 && fallZoneHi[a] == fallZoneLo[b]) || (fallZoneHi[b] >= 0 && fallZoneHi[b] == fallZoneLo[a]);
		};
		const int RBUCKETS = 160;
		std::vector<int16_t> Rv(n, 0), Rcap(n, 0);
		auto relaxLevels = [&]() {
			std::fill(Rcap.begin(), Rcap.end(), (int16_t)32767);
			std::vector<std::vector<int32_t>> bq(RBUCKETS);
			for (int c = 0; c < n; c++) {
				if (waterTw[c] == DRY) continue;
				if (keptMask[c] || outletMask[c] || fallFrozen[c]) {
					const int v = 2 * waterTw[c] + 1;
					if (v < Rcap[c]) {
						Rcap[c] = (int16_t)v;
						bq[v].push_back(c);
					}
				}
			}
			for (int v = 0; v < RBUCKETS; v++) {
				std::vector<int32_t> &bucket = bq[v];
				for (size_t x = 0; x < bucket.size(); x++) {
					const int c = bucket[x];
					if (Rcap[c] != v) continue;
					const int i = c % DIM, j = c / DIM;
					for (int k = 0; k < 8; k++) {
						const int ni = i + NDX[k], nj = j + NDZ[k];
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						if (waterTw[m] == DRY || cutEdge(c, m)) continue;
						const int cand = v + 1;
						if (cand < Rcap[m] && cand < RBUCKETS) {
							Rcap[m] = (int16_t)cand;
							bq[cand].push_back(m);
						}
					}
				}
				std::vector<int32_t>().swap(bucket);
			}
			bq.assign(RBUCKETS, std::vector<int32_t>());
			int vmax = 0;
			for (int c = 0; c < n; c++) {
				if (waterTw[c] == DRY) {
					Rv[c] = -1;
					continue;
				}
				const int v = 2 * waterTw[c];
				Rv[c] = (int16_t)v;
				bq[v].push_back(c);
				if (v > vmax) vmax = v;
			}
			for (int v = vmax; v >= 0; v--) {
				std::vector<int32_t> &bucket = bq[v];
				for (size_t x = 0; x < bucket.size(); x++) {
					const int c = bucket[x];
					if (Rv[c] != v) continue;
					const int i = c % DIM, j = c / DIM;
					for (int k = 0; k < 8; k++) {
						const int ni = i + NDX[k], nj = j + NDZ[k];
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						if (waterTw[m] == DRY || cutEdge(c, m)) continue;
						int cand = v - 1;
						if (cand > Rcap[m]) cand = Rcap[m];
						if (cand > Rv[m]) {
							Rv[m] = (int16_t)cand;
							bq[cand].push_back(m);
						}
					}
				}
				std::vector<int32_t>().swap(bucket);
			}
			std::vector<int32_t> raised;
			for (int c = 0; c < n; c++) {
				if (waterTw[c] == DRY) continue;
				const int lv = Rv[c] >> 1;
				if (lv > waterTw[c] && !keptMask[c] && !outletMask[c] && !fallPinned(c, waterTw[c])) {
					waterTw[c] = (int16_t)lv;
					raised.push_back(c);
				}
			}
			return raised;
		};

		std::vector<uint8_t> queued(n, 0);
		std::vector<int32_t> qChanged;
		auto queuePass = [&](const std::vector<int32_t> *seeds) -> int {
			qChanged.clear();
			std::vector<int32_t> queue;
			auto consider = [&](int c) {
				if (!queued[c]) {
					queued[c] = 1;
					queue.push_back(c);
				}
			};
			if (seeds) {
				for (int s : *seeds) {
					const int si = s % DIM, sj = s / DIM;
					for (int dj = -2; dj <= 2; dj++) {
						const int nj = sj + dj;
						if (nj < 0 || nj >= DIM) continue;
						for (int di = -2; di <= 2; di++) {
							const int ni = si + di;
							if (ni < 0 || ni >= DIM) continue;
							consider(nj * DIM + ni);
						}
					}
				}
			} else {
				for (int j = 0; j < DIM; j++) {
					const int row = j * DIM;
					for (int i = 0; i < DIM; i++) {
						const int c = row + i;
						bool nearWet = waterTw[c] != DRY;
						for (int k = 0; k < 8 && !nearWet; k++) {
							const int ni = i + NDX[k], nj = j + NDZ[k];
							if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
							if (waterTw[nj * DIM + ni] != DRY) nearWet = true;
						}
						if (nearWet) consider(c);
					}
				}
			}
			int events = 0;
			for (size_t qh = 0; qh < queue.size(); qh++) {
				const int c = queue[qh];
				queued[c] = 0;
				if (keptMask[c]) continue;
				const int i = c % DIM, j = c / DIM;
				const int twC = waterTw[c];
				bool changed = false;
				bool touchedNbr = false;
				if (twC == DRY) {
					double loAdj = INF;
					for (int k = 0; k < 8; k++) {
						const int ni = i + NDX[k], nj = j + NDZ[k];
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int tw = waterTw[nj * DIM + ni];
						if (tw != DRY && tw < loAdj) loAdj = tw;
					}
					if (loAdj == INF) continue;
					double F = -INF;
					for (int dj = -2; dj <= 2; dj++) {
						const int nj = j + dj;
						if (nj < 0 || nj >= DIM) continue;
						for (int di = -2; di <= 2; di++) {
							if (di == 0 && dj == 0) continue;
							const int ni = i + di;
							if (ni < 0 || ni >= DIM) continue;
							const int tw = waterTw[nj * DIM + ni];
							if (tw != DRY && tw > F) F = tw;
						}
					}
					if (F < loAdj + 1) continue;
					const bool masked = protMask[c] == 1 || blockMask[c] == 1;
					bool lakeAdj = false;
					for (int k = 0; k < 8; k++) {
						const int ni = i + NDX[k], nj = j + NDZ[k];
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						if (keptMask[m] && waterTw[m] != DRY) {
							lakeAdj = true;
							break;
						}
					}
					auto bridge = [&]() {
						waterTw[c] = (int16_t)loAdj;
						waterType[c] = TYPE_RIVER;
						const double target = loAdj * T - 0.5;
						if (target < bedT[c]) bedT[c] = target;
						changed = true;
					};
					if (!masked && (fallShadow[c] || lakeAdj)) {
						bridge();
					} else {
						bool wrote = false;
						for (int k = 0; k < 8; k++) {
							const int ni = i + NDX[k], nj = j + NDZ[k];
							if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
							const int m = nj * DIM + ni;
							const int tw = waterTw[m];
							if (tw == DRY || tw >= F || keptMask[m] || fallPinned(m, tw)) continue;
							if (outletMask[m]) continue;
							const double tgt = std::min(F, lakeCapAt(ni, nj));
							if (tgt <= tw) continue;
							waterTw[m] = (int16_t)tgt;
							wrote = true;
							touchedNbr = true;
							qChanged.push_back(m);
						}
						if (wrote)
							changed = true;
						else if (!masked)
							bridge();
						else
							throw PlanFail("masked column (" + std::to_string(G0 + i) + "," + std::to_string(G0 + j) + ") trapped between levels " + std::to_string((int)F) + "/" + std::to_string((int)loAdj) + " with no legal move");
					}
				} else {
					if (fallPinned(c, twC)) continue;
					if (outletMask[c]) continue;
					double need = -INF;
					for (int k = 0; k < 8; k++) {
						const int ni = i + NDX[k], nj = j + NDZ[k];
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						const int twN = waterTw[m];
						if (twN == DRY || twN - twC < 2) continue;
						if (fallFaceExempt(m, twN, c, twC)) continue;
						if (twN > need) need = twN;
					}
					if (need != -INF) {
						const double tgt = std::min(need - 1, lakeCapAt(i, j));
						if (tgt > twC) {
							waterTw[c] = (int16_t)tgt;
							changed = true;
						}
					}
					if (!changed) {
						const int twNow = waterTw[c];
						static const int DIRS[4][2] = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } };
						for (const auto &dd : DIRS) {
							const int dx = dd[0], dz = dd[1];
							const int ai = i + dx, aj = j + dz, bi = i - dx, bj = j - dz;
							if (ai < 0 || aj < 0 || ai >= DIM || aj >= DIM) continue;
							if (bi < 0 || bj < 0 || bi >= DIM || bj >= DIM) continue;
							const int a = aj * DIM + ai, b = bj * DIM + bi;
							const int twA = waterTw[a], twB = waterTw[b];
							const bool hiA = twA == DRY || twA > twNow;
							const bool hiB = twB == DRY || twB > twNow;
							int low = -1, li = 0, lj = 0, hiDry = -1, hi_i = 0, hi_j = 0;
							if (hiA && twB != DRY && twB < twNow) {
								low = b;
								li = bi;
								lj = bj;
								if (twA == DRY) {
									hiDry = a;
									hi_i = ai;
									hi_j = aj;
								}
							} else if (hiB && twA != DRY && twA < twNow) {
								low = a;
								li = ai;
								lj = aj;
								if (twB == DRY) {
									hiDry = b;
									hi_i = bi;
									hi_j = bj;
								}
							}
							if (low < 0) continue;
							const int twL = waterTw[low];
							const bool lowPinned = keptMask[low] || outletMask[low] || fallPinned(low, twL) || lakeCapAt(li, lj) < twNow;
							if (!lowPinned) {
								waterTw[low] = (int16_t)twNow;
								changed = true;
								touchedNbr = true;
								qChanged.push_back(low);
								continue;
							}
							if (hiDry >= 0 && !protMask[hiDry] && !blockMask[hiDry] && lakeCapAt(hi_i, hi_j) >= twNow) {
								waterTw[hiDry] = (int16_t)twNow;
								waterType[hiDry] = TYPE_RIVER;
								const double target = twNow * T - 0.5;
								if (target < bedT[hiDry]) bedT[hiDry] = target;
								changed = true;
								touchedNbr = true;
								qChanged.push_back(hiDry);
							}
						}
					}
				}
				if (changed) {
					if (++events > 500000) throw PlanFail("junction reconciliation exceeded 500k events");
					qChanged.push_back(c);
					const int RQ = touchedNbr ? 3 : 2;
					for (int dj = -RQ; dj <= RQ; dj++) {
						const int nj = j + dj;
						if (nj < 0 || nj >= DIM) continue;
						for (int di = -RQ; di <= RQ; di++) {
							const int ni = i + di;
							if (ni < 0 || ni >= DIM) continue;
							consider(nj * DIM + ni);
						}
					}
				}
			}
			return events;
		};

		{
			bool haveSeeds = false;
			std::vector<int32_t> seeds;
			for (int round = 0;; round++) {
				const std::vector<int32_t> raised = relaxLevels();
				if (haveSeeds)
					for (int c : raised) seeds.push_back(c);
				const int events = queuePass(haveSeeds ? &seeds : nullptr);
				if (events == 0) break;
				if (round >= 5) throw PlanFail("junction reconciliation did not converge in 6 rounds");
				seeds = qChanged;
				haveSeeds = true;
			}
		}
		for (int j = 0; j < DIM; j++) {
			for (int i = 0; i < DIM; i++) {
				const int c = j * DIM + i;
				if (waterTw[c] != DRY || !(protMask[c] || blockMask[c])) continue;
				double loAdj = INF;
				for (int k = 0; k < 8; k++) {
					const int ni = i + NDX[k], nj = j + NDZ[k];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int tw = waterTw[nj * DIM + ni];
					if (tw != DRY && tw < loAdj) loAdj = tw;
				}
				if (loAdj == INF) continue;
				double F = -INF;
				for (int dj = -2; dj <= 2; dj++) {
					const int nj = j + dj;
					if (nj < 0 || nj >= DIM) continue;
					for (int di = -2; di <= 2; di++) {
						if (di == 0 && dj == 0) continue;
						const int ni = i + di;
						if (ni < 0 || ni >= DIM) continue;
						const int tw = waterTw[nj * DIM + ni];
						if (tw != DRY && tw > F) F = tw;
					}
				}
				if (F >= loAdj + 1) throw PlanFail("masked column trapped between water levels");
			}
		}
	}

	// 7b'''. Bank-raise reconciliation (C2.6).
	std::vector<uint8_t> reconMask(n, 0);
	{
		std::vector<int32_t> visited(n, -1);
		std::vector<int32_t> cellsBuf(n);
		for (int pass = 0;; pass++) {
			bool anyLowered = false;
			std::fill(visited.begin(), visited.end(), -1);
			int stamp = 0;
			for (int c0 = 0; c0 < n; c0++) {
				if (visited[c0] >= 0) continue;
				const int tw0 = waterTw[c0];
				if (tw0 == DRY || keptMask[c0]) {
					visited[c0] = -2;
					continue;
				}
				int len = 0;
				cellsBuf[len++] = c0;
				visited[c0] = stamp;
				int qi = 0;
				while (qi < len) {
					const int c = cellsBuf[qi++];
					const int i = c % DIM, j = c / DIM;
					for (int k = 0; k < 8; k++) {
						const int ni = i + NDX[k], nj = j + NDZ[k];
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						if (visited[m] == stamp || waterTw[m] != tw0 || keptMask[m]) continue;
						visited[m] = stamp;
						cellsBuf[len++] = m;
					}
				}
				stamp++;
				bool pinned = false;
				for (int q = 0; q < len && !pinned; q++) {
					const int c = cellsBuf[q];
					if (fallZoneHi[c] >= 0 || fallZoneLo[c] >= 0) pinned = true;
				}
				if (pinned) continue;
				double worst = 0;
				for (int q = 0; q < len; q++) {
					const int c = cellsBuf[q];
					const int i = c % DIM, j = c / DIM;
					for (int dj = -2; dj <= 2; dj++) {
						for (int di = -2; di <= 2; di++) {
							if (di == 0 && dj == 0) continue;
							const int ni = i + di, nj = j + dj;
							if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
							const int m = nj * DIM + ni;
							if (waterTw[m] != DRY || protMask[m]) continue;
							const double need = tw0 * T + 0.01 - hCont[m];
							if (need > worst) worst = need;
						}
					}
				}
				if (worst > BANK_RAISE_CAP) {
					for (int q = 0; q < len; q++) {
						waterTw[cellsBuf[q]] = (int16_t)(tw0 - 1);
						reconMask[cellsBuf[q]] = 1;
					}
					anyLowered = true;
				}
			}
			if (!anyLowered) break;
			if (pass >= 8) throw PlanFail("bank-raise reconciliation did not converge within 8 terraces");
		}
		for (Course &co : courses) {
			for (size_t i = 0; i < co.idxs.size(); i++) {
				const int g = waterTw[co.idxs[i]];
				if (g != DRY && g < co.tw[i]) co.tw[i] = g;
			}
			for (size_t i = 1; i < co.tw.size(); i++)
				if (co.tw[i] > co.tw[i - 1]) co.tw[i] = co.tw[i - 1];
		}
	}

	// 7c. Bank enforcement (2-column Chebyshev ring, both cosets).
	for (int j = 0; j < DIM; j++) {
		for (int i = 0; i < DIM; i++) {
			const int c = j * DIM + i;
			if (waterTw[c] != DRY) continue;
			double needTw = -INF;
			for (int dj = -2; dj <= 2; dj++) {
				for (int di = -2; di <= 2; di++) {
					if (di == 0 && dj == 0) continue;
					const int ni = i + di, nj = j + dj;
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					if (waterTw[m] == DRY) continue;
					if (waterTw[m] > needTw) needTw = waterTw[m];
				}
			}
			if (needTw == -INF) continue;
			if (protMask[c]) continue;
			bank7cT[c] = std::min(needTw * T + 0.01, hCont[c] + BANK_RAISE_CAP);
		}
	}

	// 7d. Walkability shaping (i): exact wet-bed shaping.
	std::vector<int32_t> dDry(n, -1);
	{
		std::vector<int32_t> frontier;
		for (int j = 0; j < DIM; j++) {
			for (int i = 0; i < DIM; i++) {
				const int c = j * DIM + i;
				if (waterTw[c] == DRY) continue;
				bool edge = i == 0 || j == 0 || i == DIM - 1 || j == DIM - 1;
				if (!edge) {
					for (int k = 0; k < 8; k++) {
						if (waterTw[(j + NDZ[k]) * DIM + (i + NDX[k])] == DRY) {
							edge = true;
							break;
						}
					}
				}
				if (edge) {
					dDry[c] = 1;
					frontier.push_back(c);
				}
			}
		}
		int d = 1;
		while (!frontier.empty()) {
			std::vector<int32_t> next;
			for (int c : frontier) {
				const int i = c % DIM, j = c / DIM;
				for (int k = 0; k < 8; k++) {
					const int ni = i + NDX[k], nj = j + NDZ[k];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					if (waterTw[m] != DRY && dDry[m] < 0) {
						dDry[m] = d + 1;
						next.push_back(m);
					}
				}
			}
			frontier.swap(next);
			d++;
		}
	}
	std::vector<int32_t> dJunc(n, -1);
	{
		std::vector<int32_t> frontier;
		for (int j = 1; j < DIM - 1; j++) {
			for (int i = 1; i < DIM - 1; i++) {
				const int c = j * DIM + i;
				if (waterTw[c] == DRY) continue;
				for (int k = 0; k < 8; k++) {
					const int m = (j + NDZ[k]) * DIM + (i + NDX[k]);
					if (waterTw[m] != DRY && (waterTw[m] != waterTw[c] || reconMask[m] != reconMask[c])) {
						dJunc[c] = 1;
						frontier.push_back(c);
						break;
					}
				}
			}
		}
		int d = 1;
		while (!frontier.empty()) {
			std::vector<int32_t> next;
			for (int c : frontier) {
				const int i = c % DIM, j = c / DIM;
				for (int k = 0; k < 8; k++) {
					const int ni = i + NDX[k], nj = j + NDZ[k];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					if (waterTw[m] != DRY && dJunc[m] < 0) {
						dJunc[m] = d + 1;
						next.push_back(m);
					}
				}
			}
			frontier.swap(next);
			d++;
		}
	}
	for (int c = 0; c < n; c++) {
		if (waterTw[c] == DRY) continue;
		const double lev = waterTw[c] * T;
		const int dEff = dJunc[c] > 0 ? std::min(dDry[c], dJunc[c]) : dDry[c];
		const double band = std::floor(std::max(0, dEff - 1) / 2.0);
		const double depthCap = waterType[c] == TYPE_LAKE ? 12.5 : 6.5;
		double bed = std::max({ lev - 0.5 - 4 * band, lev - depthCap, 0.5 });
		bed = std::min(bed, lev - 0.5);
		bedT[c] = bed;
		floorT[c] = std::min(bed, hCont[c] + BANK_RAISE_CAP);
	}

	// (ii) Shore cap.
	for (int j = 0; j < DIM; j++) {
		for (int i = 0; i < DIM; i++) {
			const int c = j * DIM + i;
			if (waterTw[c] != DRY || protMask[c]) continue;
			double maxTw = -INF;
			for (int k = 0; k < 8; k++) {
				const int ni = i + NDX[k], nj = j + NDZ[k];
				if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
				const int m = nj * DIM + ni;
				if (waterTw[m] != DRY && waterTw[m] > maxTw) maxTw = waterTw[m];
			}
			if (maxTw == -INF) continue;
			const double cap = (maxTw + 1) * T - 0.01;
			if (cap < bedT[c]) bedT[c] = cap;
		}
	}

	auto foldSurf = [&](int c) { return std::max({ std::min(hCont[c], bedT[c]), std::min(bedT[c], breachT[c]), bank7cT[c], floorT[c] }); };

	// (iii) Transect cone repair.
	{
		std::vector<int32_t> shore;
		for (int j = 0; j < DIM; j++) {
			for (int i = 0; i < DIM; i++) {
				const int c = j * DIM + i;
				if (waterTw[c] == DRY) continue;
				bool dry8 = false;
				for (int k = 0; k < 8; k++) {
					const int ni = i + NDX[k], nj = j + NDZ[k];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					if (waterTw[nj * DIM + ni] == DRY) {
						dry8 = true;
						break;
					}
				}
				if (dry8) shore.push_back(c);
			}
		}
		std::vector<int32_t> surfT(n);
		for (int c = 0; c < n; c++) surfT[c] = (int32_t)std::floor(foldSurf(c) / T);
		for (int sweep = 0; sweep < 16; sweep++) {
			int changed = 0;
			for (int c0 : shore) {
				const int i0 = c0 % DIM, j0 = c0 / DIM;
				for (int k = 0; k < 8; k++) {
					int prev = surfT[c0];
					bool prevUp = false;
					int mPrev = -1;
					for (int s = 1; s <= 8; s++) {
						const int ni = i0 + NDX[k] * s, nj = j0 + NDZ[k] * s;
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) break;
						const int m = nj * DIM + ni;
						int t = surfT[m];
						const int allow = prevUp ? prev : prev + 1;
						if (t > allow) {
							if (waterTw[m] == DRY && !protMask[m]) {
								const double cap = (allow + 1) * T - 0.01;
								if (cap < bedT[m]) {
									bedT[m] = cap;
									surfT[m] = (int32_t)std::floor(foldSurf(m) / T);
									changed++;
								}
								t = surfT[m];
							}
							if (t > allow && prevUp && mPrev >= 0 && waterTw[mPrev] == DRY && !protMask[mPrev]) {
								const double treadCap = prev * T - 0.01;
								if (treadCap < bedT[mPrev]) bedT[mPrev] = treadCap;
								int tp = (int)std::floor(foldSurf(mPrev) / T);
								if (tp == prev) {
									bool shoreAdj = false;
									const int pi = mPrev % DIM, pj = mPrev / DIM;
									for (int q = 0; q < 8 && !shoreAdj; q++) {
										const int qi = pi + NDX[q], qj = pj + NDZ[q];
										if (qi < 0 || qj < 0 || qi >= DIM || qj >= DIM) continue;
										if (waterTw[qj * DIM + qi] != DRY) shoreAdj = true;
									}
									const double lift = t * T + 0.01;
									if (!shoreAdj && lift <= hCont[mPrev] + 16) {
										if (lift > floorT[mPrev]) floorT[mPrev] = lift;
										tp = (int)std::floor(foldSurf(mPrev) / T);
									}
								}
								if (tp != prev) {
									surfT[mPrev] = tp;
									changed++;
									break;
								}
							}
						}
						prevUp = t == prev + 1;
						prev = t;
						mPrev = m;
					}
				}
			}
			if (changed == 0) break;
		}
	}

	// 7d'. Fall-face beds + plunge pools.
	std::vector<int32_t> plungeCells;
	for (size_t fi = 0; fi < fallPairs.size(); fi++) {
		const FallPair &pf = fallPairs[fi];
		const double hiB = (pf.twBottom + 1) * T - 0.5;
		const double loB = pf.twBottom * T - 0.5;
		const int li0 = pf.lipC % DIM, lj0 = pf.lipC / DIM;
		for (int zj = -2; zj <= 2; zj++) {
			for (int zi = -2; zi <= 2; zi++) {
				const int ci = li0 + zi, cj = lj0 + zj;
				if (ci < 0 || cj < 0 || ci >= DIM || cj >= DIM) continue;
				const int c = cj * DIM + ci;
				if (waterTw[c] != pf.twTop && fallZoneLo[c] != (int)fi) continue;
				bool dryAdj = false, dryNear2 = false;
				for (int dj = -2; dj <= 2; dj++) {
					for (int di = -2; di <= 2; di++) {
						if (di == 0 && dj == 0) continue;
						const int ni = ci + di, nj = cj + dj;
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						if (waterTw[nj * DIM + ni] == DRY) {
							dryNear2 = true;
							if (std::max(std::abs(di), std::abs(dj)) == 1) dryAdj = true;
						}
					}
				}
				if (waterTw[c] == pf.twTop) {
					if (c == pf.lipC && dryAdj) throw PlanFail("fall lip touches dry shore -- site survey must reject this");
					if (c == pf.lipC || !dryNear2) {
						bedT[c] = hiB;
						floorT[c] = std::min(hiB, hCont[c] + BANK_RAISE_CAP);
					}
				} else if (fallZoneLo[c] == (int)fi && waterTw[c] == pf.twBottom) {
					bedT[c] = loB;
					floorT[c] = std::min(loB, hCont[c] + BANK_RAISE_CAP);
				}
			}
		}
		const int ri = pf.recvC % DIM, rj = pf.recvC / DIM;
		const double plungeB = (pf.twBottom - 1) * T - 0.5;
		for (int dj = -2; dj <= 2; dj++) {
			for (int di = -2; di <= 2; di++) {
				const int ni = ri + di, nj = rj + dj;
				if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
				const int c = nj * DIM + ni;
				if (waterTw[c] != pf.twBottom || dDry[c] < 2) continue;
				bool hiAdj = false;
				for (int k = 0; k < 8; k++) {
					const int qi = ni + NDX[k], qj = nj + NDZ[k];
					if (qi < 0 || qj < 0 || qi >= DIM || qj >= DIM) continue;
					const int tw = waterTw[qj * DIM + qi];
					if (tw != DRY && tw > pf.twBottom) {
						hiAdj = true;
						break;
					}
				}
				if (hiAdj) continue;
				bedT[c] = plungeB;
				floorT[c] = std::min(plungeB, hCont[c] + BANK_RAISE_CAP);
				plungeCells.push_back(c);
			}
		}
	}

	// 7d''. Local walkability repair at falls + lake outlets.
	{
		const int WALK_RZ = 10;
		std::vector<int32_t> anchorCells;
		for (const FallPair &pf : fallPairs) {
			anchorCells.push_back(pf.lipC);
			anchorCells.push_back(pf.recvC);
		}
		for (const Lake &lk : lakes)
			if (lk.outIdx >= 0) anchorCells.push_back(lk.outIdx);
		if (!anchorCells.empty()) {
			std::vector<uint8_t> noTouch(n, 0);
			for (const FallPair &pf : fallPairs) {
				noTouch[pf.lipC] = 1;
				noTouch[pf.recvC] = 1;
			}
			for (int c : plungeCells) noTouch[c] = 1;
			std::vector<int32_t> zoneList;
			{
				std::vector<uint8_t> zone(n, 0);
				for (int a : anchorCells) {
					const int ai = a % DIM, aj = a / DIM;
					for (int dj = -WALK_RZ; dj <= WALK_RZ; dj++) {
						const int nj = aj + dj;
						if (nj < 0 || nj >= DIM) continue;
						for (int di = -WALK_RZ; di <= WALK_RZ; di++) {
							const int ni = ai + di;
							if (ni < 0 || ni >= DIM) continue;
							const int m = nj * DIM + ni;
							if (!zone[m]) {
								zone[m] = 1;
								zoneList.push_back(m);
							}
						}
					}
				}
				std::sort(zoneList.begin(), zoneList.end());
			}
			auto ter = [&](int c) { return (int)std::floor(foldSurf(c) / T); };
			auto wetShore = [&](int c) {
				if (waterTw[c] == DRY) return false;
				const int i = c % DIM, j = c / DIM;
				for (int k = 0; k < 8; k++) {
					const int ni = i + NDX[k], nj = j + NDZ[k];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) return true;
					if (waterTw[nj * DIM + ni] == DRY) return true;
				}
				return false;
			};
			auto lowerTo = [&](int c, int t) {
				if (noTouch[c] || protMask[c] || keptMask[c]) return false;
				if (waterTw[c] != DRY) {
					if (t < waterTw[c] - 3) return false;
					const double v = (t + 1) * T - 0.5;
					if (v < bedT[c]) bedT[c] = v;
					const double f = std::min(v, hCont[c] + BANK_RAISE_CAP);
					if (f < floorT[c]) floorT[c] = f;
				} else {
					const double v = (t + 1) * T - 0.01;
					if (v < bedT[c]) bedT[c] = v;
					if (bank7cT[c] > v) {
						const int ci = c % DIM, cj = c / DIM;
						double needTw = -INF;
						for (int ddj = -2; ddj <= 2; ddj++) {
							for (int ddi = -2; ddi <= 2; ddi++) {
								if (ddi == 0 && ddj == 0) continue;
								const int nni = ci + ddi, nnj = cj + ddj;
								if (nni < 0 || nnj < 0 || nni >= DIM || nnj >= DIM) continue;
								const int nm = nnj * DIM + nni;
								if (waterTw[nm] != DRY && waterTw[nm] > needTw) needTw = waterTw[nm];
							}
						}
						const double req = needTw == -INF ? -INF : std::min(needTw * T + 0.01, hCont[c] + BANK_RAISE_CAP);
						bank7cT[c] = std::max(req, v);
					}
				}
				return ter(c) <= t;
			};
			int widenBudget = 24;
			auto runWiden = [&](int rim, int tw) {
				if (waterTw[rim] != DRY || protMask[rim] || blockMask[rim]) return false;
				if (fallZoneHi[rim] >= 0 || fallZoneLo[rim] >= 0) return false;
				if (widenBudget <= 0) return false;
				const int ri = rim % DIM, rj = rim / DIM;
				for (int dj = -2; dj <= 2; dj++) {
					for (int di = -2; di <= 2; di++) {
						if (di == 0 && dj == 0) continue;
						const int ni = ri + di, nj = rj + dj;
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						const int twN = waterTw[m];
						const int ring = std::max(std::abs(di), std::abs(dj));
						if (twN != DRY) {
							if (twN > tw) return false;
							if (ring == 1 && tw - twN >= 2) return false;
						} else if (ter(m) < tw) {
							return false;
						}
					}
				}
				waterTw[rim] = (int16_t)tw;
				waterType[rim] = TYPE_SPRING;
				const double v = tw * T - 0.5;
				if (v < bedT[rim]) bedT[rim] = v;
				floorT[rim] = std::min(v, hCont[rim] + BANK_RAISE_CAP);
				bank7cT[rim] = -INF;
				for (int dj = -2; dj <= 2; dj++) {
					for (int di = -2; di <= 2; di++) {
						if (di == 0 && dj == 0) continue;
						const int ni = ri + di, nj = rj + dj;
						if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
						const int m = nj * DIM + ni;
						if (waterTw[m] == DRY && !protMask[m]) {
							const double f = tw * T + 0.01;
							if (f > bank7cT[m]) bank7cT[m] = f;
						}
					}
				}
				widenBudget--;
				return true;
			};
			bool done = false;
			for (int sweep = 0; sweep < 32 && !done; sweep++) {
				int changed = 0;
				for (int c : zoneList) {
					const int i = c % DIM, j = c / DIM;
					for (int k = 0; k < 8; k++) {
						const int dx = NDX[k], dz = NDZ[k];
						const int i1 = i + dx, j1 = j + dz;
						if (i1 < 0 || j1 < 0 || i1 >= DIM || j1 >= DIM) continue;
						const int m1 = j1 * DIM + i1;
						const int t0 = ter(c), t1 = ter(m1);
						if (std::abs(t1 - t0) >= 2 && (waterTw[c] != DRY || waterTw[m1] != DRY)) {
							const int hi = t1 > t0 ? m1 : c;
							const int lo = std::min(t0, t1);
							if (lowerTo(hi, lo + 1)) {
								changed++;
								continue;
							}
							const int loC = hi == m1 ? c : m1;
							if (waterTw[hi] == DRY && waterTw[loC] != DRY && runWiden(hi, waterTw[loC])) {
								changed++;
								continue;
							}
							continue;
						}
						const int i2 = i + 2 * dx, j2 = j + 2 * dz;
						if (i2 < 0 || j2 < 0 || i2 >= DIM || j2 >= DIM) continue;
						const int m2 = j2 * DIM + i2;
						const int t2 = ter(m2);
						if (t1 - t0 == 1 && t2 - t1 == 1) {
							bool visible = false;
							for (int s = 0; s <= 6 && !visible; s++) {
								const int pi = i - dx * s, pj = j - dz * s;
								if (pi < 0 || pj < 0 || pi >= DIM || pj >= DIM) break;
								visible = wetShore(pj * DIM + pi);
							}
							if (!visible) continue;
							if (lowerTo(m2, t1)) {
								changed++;
								continue;
							}
							if (waterTw[m2] == DRY && waterTw[m1] != DRY && runWiden(m2, waterTw[m1])) {
								changed++;
								continue;
							}
						}
					}
				}
				if (changed == 0) done = true;
			}
		}
	}

	// Flow hygiene (final).
	for (int c = 0; c < n; c++) {
		const int ty = waterType[c];
		if (ty == TYPE_RIVER || ty == TYPE_FALL) {
			if (det_hypot(flowX[c], flowZ[c]) < 0.5) {
				waterType[c] = TYPE_SPRING;
				flowX[c] = 0;
				flowZ[c] = 0;
			}
		} else {
			flowX[c] = 0;
			flowZ[c] = 0;
		}
	}

	// Homestead disc enforcement.
	{
		const int BUF = 5;
		std::vector<uint8_t> nearInlet(n, 0);
		for (int c : inletCells) {
			const int i = c % DIM, j = c / DIM;
			for (int dj = -BUF; dj <= BUF; dj++) {
				const int nj = j + dj;
				if (nj < 0 || nj >= DIM) continue;
				for (int di = -BUF; di <= BUF; di++) {
					const int ni = i + di;
					if (ni < 0 || ni >= DIM) continue;
					nearInlet[nj * DIM + ni] = 1;
				}
			}
		}
		for (int j = 0; j < DIM; j++) {
			for (int i = 0; i < DIM; i++) {
				const int c = j * DIM + i;
				if (waterTw[c] == DRY || tarnMask[c]) continue;
				const int gx = G0 + i, gz = G0 + j;
				if (col_r(gx, gz) >= PLUG_R0) continue;
				if (nearInlet[c]) {
					if (waterTw[c] > TARN_TW) waterTw[c] = TARN_TW;
					continue;
				}
				waterTw[c] = DRY;
				waterType[c] = TYPE_DRY;
				flowX[c] = 0;
				flowZ[c] = 0;
			}
		}
		for (int c = 0; c < n; c++) {
			if (waterTw[c] == DRY || waterType[c] == TYPE_LAKE) continue;
			const double target = waterTw[c] * T - 0.5;
			if (target < bedT[c]) bedT[c] = target;
		}
	}

	// Stray-cliff reconciliation.
	{
		std::vector<uint8_t> inQ(n, 0);
		std::vector<int32_t> queue(n);
		long qh = 0, qt = 0;
		for (int c = 0; c < n; c++)
			if (waterTw[c] != DRY) {
				queue[qt++] = c;
				inQ[c] = 1;
			}
		long guard = 0;
		while (qh < qt && guard < 8L * n) {
			guard++;
			const int c = queue[qh % n];
			qh++;
			inQ[c] = 0;
			const int twC = waterTw[c];
			if (twC == DRY) continue;
			const int i = c % DIM, j = c / DIM;
			for (int k = 0; k < 8; k++) {
				const int ni = i + NDX[k], nj = j + NDZ[k];
				if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
				const int m = nj * DIM + ni;
				const int twN = waterTw[m];
				if (twN == DRY || std::abs(twN - twC) < 2) continue;
				if (fallFaceExempt(c, twC, m, twN)) continue;
				if (keptMask[c] || keptMask[m]) continue;
				const int hi = twC > twN ? c : m;
				const int hiTw = twC > twN ? twC : twN;
				waterTw[hi] = (int16_t)(hiTw - 1);
				bedT[hi] = std::min(bedT[hi], (hiTw - 1) * T - 0.5);
				const int qs[2] = { c, m };
				for (int q : qs) {
					if (!inQ[q]) {
						inQ[q] = 1;
						queue[qt % n] = q;
						qt++;
					}
				}
			}
		}
	}

	// 8. Fold targets + derive the signed carve.
	std::vector<double> bankTargetLat(n);
	for (int c = 0; c < n; c++) bankTargetLat[c] = std::max({ std::min(bedT[c], breachT[c]), bank7cT[c], floorT[c] });
	std::vector<double> carve(n);
	for (int c = 0; c < n; c++) {
		const double sB = std::max(std::min(hCont[c], bedT[c]), bankTargetLat[c]);
		carve[c] = hCont[c] - sB;
	}

	// 9. Homestead invariants (C4).
	{
		int tarnArea = 0, still70 = 0;
		for (int c = 0; c < n; c++) {
			if (tarnMask[c]) {
				tarnArea++;
				if (waterTw[c] != TARN_TW) throw PlanFail("tarn cell not at the tw=2 hard ceiling");
			}
			const int ty = waterType[c];
			if ((ty == TYPE_LAKE || ty == TYPE_SPRING) && waterTw[c] != DRY) {
				const int gx = G0 + (c % DIM), gz = G0 + c / DIM;
				if (col_r(gx, gz) < PLUG_R0 && waterTw[c] <= 2) still70++;
			}
			if (waterTw[c] != DRY && blockMask[c]) throw PlanFail("wet column inside a protected-asset standoff");
			if (protMask[c] && carve[c] != 0) throw PlanFail("nonzero carve on a protected-asset column");
		}
		if (still70 < 150) throw PlanFail("only " + std::to_string(still70) + " still-water columns inside r<70 (need >=150)");
		for (const Course &co : courses) {
			bool wasInside = false;
			for (size_t i = 0; i < co.idxs.size(); i++) {
				const int c = co.idxs[i];
				const double r = col_r(G0 + (c % DIM), G0 + c / DIM);
				if (r < PLUG_R0) {
					wasInside = true;
					if (co.tw[i] > 2) throw PlanFail("course node inside r<70 with tw>2");
				} else if (wasInside && r > PLUG_R0 + 2) {
					throw PlanFail("course exits the homestead disc (tarn must be endorheic)");
				}
			}
		}
	}

	// 9b. Falls invariants (the registry is CLOSED).
	{
		if (falls.size() > 3) throw PlanFail(std::to_string(falls.size()) + " falls exceed the designed max of 3");
		for (const PlanFall &f : falls)
			if (f.tw_top - f.tw_bottom != FALL_DROP) throw PlanFail("fall drops other than exactly 2 terraces");
		for (const PlannedFall &pf : plannedFalls) {
			const int gx = G0 + (pf.recvIdx % DIM), gz = G0 + pf.recvIdx / DIM;
			bool found = false;
			for (const PlanFall &f : falls)
				if (f.gx == gx && f.gz == gz) found = true;
			if (!found) throw PlanFail("planned fall missing from the registry");
		}
		for (int j = 0; j < DIM; j++) {
			for (int i = 0; i < DIM; i++) {
				const int c = j * DIM + i;
				const int twC = waterTw[c];
				if (twC == DRY) continue;
				static const int DD[4][2] = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } };
				for (const auto &dd : DD) {
					const int ni = i + dd[0], nj = j + dd[1];
					if (ni < 0 || nj < 0 || ni >= DIM || nj >= DIM) continue;
					const int m = nj * DIM + ni;
					const int twN = waterTw[m];
					if (twN == DRY || std::abs(twN - twC) < 2) continue;
					if (!fallFaceExempt(c, twC, m, twN)) throw PlanFail("stray water cliff at (" + std::to_string(G0 + i) + "," + std::to_string(G0 + j) + ") -- not a registered fall");
				}
			}
		}
	}

	// ---- publish into the plan record
	plan.seed = seed;
	plan.carve = std::move(carve);
	plan.bed_target_lat = std::move(bedT);
	plan.bank_target_lat = std::move(bankTargetLat);
	plan.flow_x = std::move(flowX);
	plan.flow_z = std::move(flowZ);
	plan.water_tw = std::move(waterTw);
	plan.water_type = std::move(waterType);
	plan.falls = falls;
	for (const Course &co : courses) {
		PlanRiver rv;
		rv.order = co.order;
		rv.nodes = co.idxs;
		plan.rivers.push_back(std::move(rv));
	}
	for (const PlanFall &f : plan.falls) {
		const int32_t c = (int32_t)plan_idx(f.gx, f.gz);
		auto it = plan.fall_top.find(c);
		if (it == plan.fall_top.end() || f.tw_top > it->second) plan.fall_top[c] = f.tw_top;
	}
	for (const PlanRiver &rv : plan.rivers) {
		for (int32_t c : rv.nodes) {
			auto it = plan.course_order.find(c);
			if (it == plan.course_order.end() || rv.order > it->second) plan.course_order[c] = rv.order;
		}
	}
}

} // namespace

void solve_plan(int32_t seed, WaterPlan &out) {
	const auto t0 = std::chrono::steady_clock::now();
	out = WaterPlan();
	try {
		solve_impl(seed, out);
		out.ok = true;
	} catch (const std::exception &e) {
		out = WaterPlan();
		out.error = e.what();
		out.ok = false;
	}
	out.seed = seed;
	out.solve_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

std::string plan_hash(const WaterPlan &p) {
	uint32_t h = 0x811c9dc5u;
	auto feed = [&h](const void *data, size_t bytes) {
		const uint8_t *b = (const uint8_t *)data;
		for (size_t i = 0; i < bytes; i++) {
			h ^= b[i];
			h *= 0x01000193u;
		}
	};
	feed(p.carve.data(), p.carve.size() * sizeof(double));
	feed(p.water_tw.data(), p.water_tw.size() * sizeof(int16_t));
	feed(p.water_type.data(), p.water_type.size());
	feed(p.flow_x.data(), p.flow_x.size() * sizeof(float));
	feed(p.flow_z.data(), p.flow_z.size() * sizeof(float));
	feed(p.bed_target_lat.data(), p.bed_target_lat.size() * sizeof(double));
	feed(p.bank_target_lat.data(), p.bank_target_lat.size() * sizeof(double));
	char buf[16];
	snprintf(buf, sizeof(buf), "%08x", h);
	return buf;
}

// ============================================================================
// The shared plan, carve, and the water-API queries
// ============================================================================
namespace {
std::mutex g_mu;
std::condition_variable g_cv;
std::atomic<int> g_status{ 0 };
std::unique_ptr<WaterPlan> g_plan;
std::thread g_worker;
std::atomic<bool> g_carve_off{ false };
std::atomic<bool> g_flood_off{ false };
} // namespace

void start_plan_solve(int32_t seed) {
	std::lock_guard<std::mutex> lk(g_mu);
	if (g_status.load() != 0) return;
	g_status = 1;
	// The solve always runs on its own thread; the caller returns at once.
	const std::thread::id caller = std::this_thread::get_id();
	g_worker = std::thread([seed, caller] {
		auto p = std::make_unique<WaterPlan>();
		solve_plan(seed, *p);
		p->solved_off_caller = std::this_thread::get_id() != caller;
		{
			std::lock_guard<std::mutex> lk2(g_mu);
			const bool ok = p->ok;
			g_plan = std::move(p);
			g_status = ok ? 2 : 3;
		}
		g_cv.notify_all();
	});
}

void shutdown_plan() {
	std::thread t;
	{
		std::lock_guard<std::mutex> lk(g_mu);
		if (g_worker.joinable()) t = std::move(g_worker);
	}
	if (t.joinable()) t.join(); // outside the lock: the worker takes it to publish
}

int plan_status() { return g_status.load(); }

void wait_plan_ready() {
	std::unique_lock<std::mutex> lk(g_mu);
	g_cv.wait(lk, [] { return g_status.load() >= 2 || g_status.load() == 0; });
}

const WaterPlan *shared_plan() {
	if (g_status.load() != 2) return nullptr;
	return g_plan.get();
}

const WaterPlan *failed_plan() {
	if (g_status.load() != 3) return nullptr;
	return g_plan.get();
}

void set_carve_disabled(bool off) { g_carve_off = off; }
bool carve_disabled() { return g_carve_off.load(); }
void set_flood_disabled(bool off) { g_flood_off = off; }
bool flood_disabled() { return g_flood_off.load(); }

// carve.js carveDepth: base - max(min(base, bedTarget), bankTarget) at the exact lattice address.
double carve_depth(double cx, double cz, int32_t seed, const WaterPlan *plan) {
	if (!plan || g_carve_off.load()) return 0;
	const double fgx = std::floor(cx / 4), fgz = std::floor(cz / 4);
	if (fgx < PLAN_G0 || fgz < PLAN_G0 || fgx >= PLAN_G0 + PLAN_DIM || fgz >= PLAN_G0 + PLAN_DIM) return 0;
	const int32_t gx = (int32_t)fgx, gz = (int32_t)fgz;
	const int64_t c = plan_idx(gx, gz);
	const double base = surface_height_base(cx, cz, seed);
	return base - std::max(std::min(base, plan->bed_target_lat[c]), plan->bank_target_lat[c]);
}

static double natural_height(double cx, double cz, int32_t seed, const WaterPlan *plan) {
	return surface_height_base(cx, cz, seed) - carve_depth(cx, cz, seed, plan);
}

// Spec 576 A1: the homestead's flat pad. The world's terrain is terraced with metres of relief near the
// origin, so a slab could not sit flush on it. The height function levels a square pad centred on the
// origin (columns of 0.5 m: PAD_LO..PAD_HI, a half-width of 5.5 m, inside the 8 m tree and water clear
// zone) to the terrace of the origin column, and blends it into the surrounding terraces over PAD_BLEND-1
// columns so that no two neighbouring columns differ by more than one terrace (0.5 m). Columns of the
// water plan that are flooded or river are left natural (water is never buried), as is everything
// beyond the blend. Only the world seed is touched: other seeds keep the prototype's heights.
namespace {
// Pad half-width and blend width in 0.5 m columns. Defaults match game/homestead/data/site_template.json
// (slab half 5.0 m + margin 0.5 m; pad_blend_m 6.0); the game hands the template's numbers in through
// set_pad_params before the world is built, so the template is the one statement of the blend width.
std::atomic<int> g_pad_cols{ 11 };
std::atomic<int> g_blend_cols{ 12 };

struct PadTable {
	const WaterPlan *plan = nullptr;
	bool carve_off = false, flood_off = false;
	int cols = 0, blend = 0, lo = 0, hi = 0, wlo = 0, whi = 0, n = 0;
	std::vector<int32_t> h;
	std::vector<uint8_t> controlled;
};
std::mutex g_pad_mu;
std::shared_ptr<const PadTable> g_pad;

std::shared_ptr<const PadTable> build_pad_table(const WaterPlan *plan, int cols, int blend) {
	auto t = std::make_shared<PadTable>();
	t->plan = plan;
	t->carve_off = g_carve_off.load();
	t->flood_off = g_flood_off.load();
	t->cols = cols;
	t->blend = blend;
	// The engine reads BCC centres at 4k and 4k+2, so the +x and +z sides need one more column.
	t->lo = -cols;
	t->hi = cols;
	t->wlo = t->lo - blend;
	t->whi = t->hi + blend;
	t->n = t->whi - t->wlo + 1;
	const int N = t->n, WLO = t->wlo;
	t->h.assign((size_t)N * N, 0);
	t->controlled.assign((size_t)N * N, 0);
	std::vector<int32_t> nat((size_t)N * N);
	std::vector<uint8_t> fixed((size_t)N * N, 0);
	auto at = [N, WLO](int gx, int gz) { return (size_t)((gz - WLO) * N + (gx - WLO)); };
	const int32_t h0 = (int32_t)(std::floor(natural_height(0, 0, WORLD_SEED, plan) / T) * T);
	for (int gz = t->wlo; gz <= t->whi; gz++) {
		for (int gx = t->wlo; gx <= t->whi; gx++) {
			const size_t i = at(gx, gz);
			nat[i] = (int32_t)(std::floor(natural_height(4 * gx + 2, 4 * gz + 2, WORLD_SEED, plan) / T) * T);
			t->h[i] = nat[i];
			const bool in_pad = gx >= t->lo && gx <= t->hi && gz >= t->lo && gz <= t->hi;
			const bool edge = gx == t->wlo || gx == t->whi || gz == t->wlo || gz == t->whi;
			bool wet = false;
			if (plan && !in_pad) wet = water_level_at(*plan, gx, gz) != WATER_DRY || is_river_column(*plan, gx, gz);
			if (in_pad) {
				t->h[i] = h0;
				fixed[i] = 1;
			} else if (edge || wet) {
				fixed[i] = 1;
			}
		}
	}
	// Relax: move each free column toward its neighbours until no column differs from a neighbour by more
	// than one terrace, and none from the column two away by more than one terrace (a slope of at most half
	// a terrace per column, which keeps the mesher's cap cells from doubling a step).
	for (int sweep = 0; sweep < 2000; sweep++) {
		bool changed = false;
		for (int gz = t->wlo; gz <= t->whi; gz++) {
			for (int gx = t->wlo; gx <= t->whi; gx++) {
				const size_t i = at(gx, gz);
				if (fixed[i]) continue;
				int32_t v = t->h[i];
				const int nb[12][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 }, { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } };
				for (const auto &o : nb) {
					const int nx = gx + o[0], nz = gz + o[1];
					if (nx < t->wlo || nx > t->whi || nz < t->wlo || nz > t->whi) continue;
					const int32_t hn = t->h[at(nx, nz)];
					v = std::min(std::max(v, hn - T), hn + T);
				}
				if (v != t->h[i]) {
					t->h[i] = v;
					changed = true;
				}
			}
		}
		if (!changed) break;
	}
	for (int gz = t->wlo; gz <= t->whi; gz++) {
		for (int gx = t->wlo; gx <= t->whi; gx++) {
			const size_t i = at(gx, gz);
			const bool in_pad = gx >= t->lo && gx <= t->hi && gz >= t->lo && gz <= t->hi;
			t->controlled[i] = (in_pad || (!fixed[i] && t->h[i] != nat[i])) ? 1 : 0;
		}
	}
	return t;
}

std::shared_ptr<const PadTable> pad_table(const WaterPlan *plan) {
	std::lock_guard<std::mutex> lk(g_pad_mu);
	const int cols = g_pad_cols.load(), blend = g_blend_cols.load();
	if (!g_pad || g_pad->plan != plan || g_pad->carve_off != g_carve_off.load() || g_pad->flood_off != g_flood_off.load() || g_pad->cols != cols || g_pad->blend != blend)
		g_pad = build_pad_table(plan, cols, blend);
	return g_pad;
}
} // namespace

void set_pad_params(double half_m, double blend_m) {
	g_pad_cols = std::max(1, (int)std::lround(half_m / 0.5));
	g_blend_cols = std::max(1, (int)std::lround(blend_m / 0.5));
}
double pad_half_m() { return g_pad_cols.load() * 0.5; }
double pad_blend_m() { return g_blend_cols.load() * 0.5; }

double surface_height(double cx, double cz, int32_t seed, const WaterPlan *plan) {
	if (seed == WORLD_SEED) {
		const int cols = g_pad_cols.load(), reach = cols + g_blend_cols.load();
		const int gx = (int)std::floor(cx / 4), gz = (int)std::floor(cz / 4);
		if (gx >= -reach && gx <= reach && gz >= -reach && gz <= reach) {
			const std::shared_ptr<const PadTable> t = pad_table(plan);
			if (gx >= t->wlo && gx <= t->whi && gz >= t->wlo && gz <= t->whi) {
				const size_t i = (size_t)((gz - t->wlo) * t->n + (gx - t->wlo));
				if (t->controlled[i]) return (double)t->h[i];
			}
		}
	}
	return natural_height(cx, cz, seed, plan);
}

int32_t water_level_at(const WaterPlan &p, int32_t gx, int32_t gz) {
	if (g_flood_off.load()) return WATER_DRY;
	if (!plan_in_domain(gx, gz)) return WATER_DRY;
	const int64_t c = plan_idx(gx, gz);
	const int ty = p.water_type[c];
	return (ty == TYPE_LAKE || ty == TYPE_SPRING) ? p.water_tw[c] : WATER_DRY;
}
bool is_flooded(const WaterPlan &p, int32_t gx, int32_t gz) { return water_level_at(p, gx, gz) != WATER_DRY; }
int32_t course_level_at(const WaterPlan &p, int32_t gx, int32_t gz) {
	if (!plan_in_domain(gx, gz)) return WATER_DRY;
	const int64_t c = plan_idx(gx, gz);
	const int ty = p.water_type[c];
	return (ty == TYPE_RIVER || ty == TYPE_FALL) ? p.water_tw[c] : WATER_DRY;
}
bool get_flow_dir(const WaterPlan &p, int32_t gx, int32_t gz, double &fx, double &fz) {
	if (!plan_in_domain(gx, gz)) return false;
	const int64_t c = plan_idx(gx, gz);
	fx = p.flow_x[c];
	fz = p.flow_z[c];
	return det_hypot(fx, fz) >= 0.5;
}
int32_t course_fall_top_at(const WaterPlan &p, int32_t gx, int32_t gz) {
	if (!plan_in_domain(gx, gz)) return WATER_DRY;
	auto it = p.fall_top.find((int32_t)plan_idx(gx, gz));
	return it == p.fall_top.end() ? WATER_DRY : it->second;
}
bool is_river_column(const WaterPlan &p, int32_t gx, int32_t gz) {
	if (!plan_in_domain(gx, gz)) return false;
	const int ty = p.water_type[plan_idx(gx, gz)];
	return ty == TYPE_RIVER || ty == TYPE_FALL;
}
int32_t get_strahler_order(const WaterPlan &p, int32_t gx, int32_t gz) {
	if (!plan_in_domain(gx, gz)) return 0;
	auto it = p.course_order.find((int32_t)plan_idx(gx, gz));
	return it == p.course_order.end() ? 0 : it->second;
}

} // namespace stalag
