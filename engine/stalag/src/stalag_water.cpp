// Spec #517 -- cell-occupancy water mesher, native port of the prototype's wateroccupancy.js.
//
// The BCC lattice has two cosets, and the low coset's column centre tops 2 lattice units
// below the high coset; defining water as a per-CELL occupancy set over BOTH cosets and
// meshing the boundary of that volume is what closed the shoreline-gap saga there. This
// is a faithful port of that algorithm (OPEN cells over flooded columns, one-ring SHORE
// dilation with the course SLACK rule, burial-guard deferral and the rescue pass), not a
// redesign. The decisions are pure functions of the plan, so the output is seam-safe.

#include "stalag_water.h"

#include "stalag_core.h"
#include "stalag_plan.h"
#include "stalag_to_cell.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <unordered_map>
#include <unordered_set>

namespace stalag {

namespace {

constexpr double COL = 0.5; // column pitch, metres
constexpr int MARGIN = 8; // cell-enumeration margin ring (lattice units)
constexpr int LAT_Y_MIN = -8, LAT_Y_MAX = 64;

enum Src : uint8_t { SRC_POND = 0, SRC_COURSE = 1, SRC_FALL = 2 };

inline int64_t cell_key(int32_t cx, int32_t cy, int32_t cz) {
	return ((int64_t)(cx + 16384) << 40) | ((int64_t)(cy + 16384) << 20) | (int64_t)(cz + 16384);
}
inline int pos_mod4(int v) { return ((v % 4) + 4) % 4; }

struct WCell {
	int32_t tw;
	Src src;
};

struct Occupancy {
	const WaterPlan &plan;
	int32_t seed;
	int latXMin = 0, latXMax = 0, latZMin = 0, latZMax = 0;
	std::unordered_map<int64_t, int32_t> tt_cache;
	struct Flood {
		bool wet;
		int32_t tw;
		Src src;
	};
	std::unordered_map<int64_t, Flood> flood_cache;
	std::unordered_map<int64_t, WCell> water; // OPEN, SHORE and rescued cells
	std::vector<int64_t> open_order; // OPEN keys in insertion order (the rescue pass depends on it)
	std::vector<std::array<int32_t, 3>> open_cells;

	Occupancy(const WaterPlan &p, int32_t s) :
			plan(p), seed(s) {}

	// terrainTop is evaluated at the CELL's own lattice address (both cosets), not the column centre.
	int32_t terrain_top(int32_t cx, int32_t cz) {
		const int64_t k = (int64_t)cx * 100003 + cz;
		auto it = tt_cache.find(k);
		if (it != tt_cache.end()) return it->second;
		const int32_t v = (int32_t)(std::floor(surface_height(cx, cz, seed, &plan) / TERRACE_LAT) * TERRACE_LAT + 2);
		tt_cache.emplace(k, v);
		return v;
	}
	bool is_solid(int32_t cx, int32_t cy, int32_t cz) { return cy <= terrain_top(cx, cz) + 1e-6; }
	static void col_of(int32_t cx, int32_t cz, int32_t &gx, int32_t &gz) {
		gx = (int32_t)std::floor(cx * SF / COL);
		gz = (int32_t)std::floor(cz * SF / COL);
	}
	const Flood &flood_src(int32_t gx, int32_t gz) {
		const int64_t k = (int64_t)gx * 100003 + gz;
		auto it = flood_cache.find(k);
		if (it != flood_cache.end()) return it->second;
		Flood f{ false, 0, SRC_POND };
		const int32_t ctw = course_level_at(plan, gx, gz);
		if (ctw != WATER_DRY) {
			f = { true, ctw, SRC_COURSE };
		} else {
			const int32_t tw = water_level_at(plan, gx, gz);
			if (tw != WATER_DRY) f = { true, tw, SRC_POND };
		}
		return flood_cache.emplace(k, f).first->second;
	}
	bool in_box(int32_t cx, int32_t cy, int32_t cz) const {
		return cx >= latXMin && cx <= latXMax && cy >= LAT_Y_MIN && cy <= LAT_Y_MAX && cz >= latZMin && cz <= latZMax;
	}
};

bool any_flooded_near(const WaterPlan &plan, double x_min, double x_max, double z_min, double z_max) {
	const int gx0 = (int)std::floor(x_min / COL) - 1, gx1 = (int)std::ceil(x_max / COL) + 1;
	const int gz0 = (int)std::floor(z_min / COL) - 1, gz1 = (int)std::ceil(z_max / COL) + 1;
	for (int gx = gx0; gx <= gx1; gx++) {
		for (int gz = gz0; gz <= gz1; gz++) {
			if (is_flooded(plan, gx, gz)) return true;
			if (course_level_at(plan, gx, gz) != WATER_DRY) return true;
		}
	}
	return false;
}

} // namespace

void build_occupancy_water(const WaterPlan &plan, int32_t seed, double x_min, double x_max, double z_min, double z_max, WaterSoup &out) {
	if (!any_flooded_near(plan, x_min, x_max, z_min, z_max)) return; // every dry chunk takes this exit

	Occupancy O(plan, seed);
	O.latXMin = (int)std::floor(x_min / SF) - MARGIN;
	O.latXMax = (int)std::ceil(x_max / SF) + MARGIN;
	O.latZMin = (int)std::floor(z_min / SF) - MARGIN;
	O.latZMax = (int)std::ceil(z_max / SF) + MARGIN;

	// ---- OPEN WATER: air cell over a flooded column, at/below its surface.
	for (int k = (int)std::floor(O.latZMin / 2.0); k <= (int)std::ceil(O.latZMax / 2.0); k++) {
		const int cz = 2 * k;
		if (cz < O.latZMin || cz > O.latZMax) continue;
		const int par = pos_mod4(cz);
		const int cx0 = O.latXMin + pos_mod4(par - O.latXMin);
		for (int cx = cx0; cx <= O.latXMax; cx += 4) {
			int32_t gx, gz;
			Occupancy::col_of(cx, cz, gx, gz);
			const Occupancy::Flood fs = O.flood_src(gx, gz);
			if (!fs.wet) continue;
			const int tw = fs.tw;
			const int tt = O.terrain_top(cx, cz);
			const int fallTop = course_fall_top_at(plan, gx, gz);
			const int effTw = (fallTop != WATER_DRY && fallTop > tw) ? fallTop : tw;
			const int yCap = std::min(4 * effTw + 2, LAT_Y_MAX);
			int cy0 = std::max(LAT_Y_MIN, tt + 1);
			cy0 = cy0 + pos_mod4(par - cy0);
			for (int cy = cy0; cy <= yCap; cy += 4) {
				const int64_t key = cell_key(cx, cy, cz);
				WCell wc;
				if (fallTop != WATER_DRY && cy > 4 * tw + 2) {
					wc.tw = std::min((int)std::ceil(cy / 4.0), fallTop);
					wc.src = SRC_FALL;
				} else {
					wc.tw = tw;
					wc.src = fs.src;
				}
				O.water[key] = wc;
				O.open_order.push_back(key);
				O.open_cells.push_back({ cx, cy, cz });
			}
		}
	}
	std::unordered_set<int64_t> open_set(O.open_order.begin(), O.open_order.end());

	// ---- SHORE FILL: one-ring dilation of OPEN over BOTH cosets (PATH-C slack for courses).
	struct ShoreAdd {
		int cx, cy, cz, tw;
		Src src;
	};
	std::vector<ShoreAdd> shoreAdds;
	struct Deferred {
		int tw;
		Src src;
	};
	std::unordered_map<int64_t, Deferred> deferredBuried;
	std::unordered_set<int64_t> candSeen;
	for (const auto &oc : O.open_cells) {
		for (const auto &off : TO_NEIGHBOR_OFFSETS) {
			const int cx = oc[0] + off[0], cy = oc[1] + off[1], cz = oc[2] + off[2];
			const int64_t ck = cell_key(cx, cy, cz);
			if (open_set.count(ck) || candSeen.count(ck)) continue;
			candSeen.insert(ck);
			if (!O.in_box(cx, cy, cz)) continue;
			if (O.is_solid(cx, cy, cz)) continue;
			bool haveMax = false;
			int maxTw = 0;
			bool slack = false;
			for (const auto &o2 : TO_NEIGHBOR_OFFSETS) {
				const int64_t nk = cell_key(cx + o2[0], cy + o2[1], cz + o2[2]);
				if (!open_set.count(nk)) continue;
				const WCell &wc = O.water[nk];
				const bool courseLike = wc.src == SRC_COURSE || wc.src == SRC_FALL;
				if (!haveMax || wc.tw > maxTw) {
					haveMax = true;
					maxTw = wc.tw;
					slack = courseLike;
				} else if (wc.tw == maxTw && courseLike) {
					slack = true;
				}
			}
			if (!haveMax) continue;
			const int SLACK = slack ? 2 : 0;
			if (cy > 4 * maxTw + 2 + SLACK) continue;
			if (SLACK > 0 && O.terrain_top(cx, cz) >= 4 * maxTw + 2) {
				const int rescueTw = (int)std::floor((O.terrain_top(cx, cz) - 2) / 4.0) + 1;
				deferredBuried[ck] = { rescueTw, slack ? SRC_COURSE : SRC_POND };
				continue;
			}
			shoreAdds.push_back({ cx, cy, cz, maxTw, slack ? SRC_COURSE : SRC_POND });
		}
	}
	std::sort(shoreAdds.begin(), shoreAdds.end(), [](const ShoreAdd &a, const ShoreAdd &b) {
		if (a.cz != b.cz) return a.cz < b.cz;
		if (a.cx != b.cx) return a.cx < b.cx;
		return a.cy < b.cy;
	});
	for (const ShoreAdd &s : shoreAdds) O.water[cell_key(s.cx, s.cy, s.cz)] = { s.tw, s.src };

	// ---- Rescue pass: admit a deferred (would-be-buried) candidate only when skipping it
	// would leave a course OPEN cell with no face-adjacent water at all.
	if (!deferredBuried.empty()) {
		for (size_t oi = 0; oi < O.open_cells.size(); oi++) {
			const int64_t kc = O.open_order[oi];
			const WCell oc_cell = O.water[kc];
			if (oc_cell.src != SRC_COURSE && oc_cell.src != SRC_FALL) continue;
			const auto &oc = O.open_cells[oi];
			bool hasNeighbor = false;
			for (const auto &off : TO_NEIGHBOR_OFFSETS) {
				if (O.water.count(cell_key(oc[0] + off[0], oc[1] + off[1], oc[2] + off[2]))) {
					hasNeighbor = true;
					break;
				}
			}
			if (hasNeighbor) continue;
			for (const auto &off : TO_NEIGHBOR_OFFSETS) {
				const int64_t nk = cell_key(oc[0] + off[0], oc[1] + off[1], oc[2] + off[2]);
				auto it = deferredBuried.find(nk);
				if (it == deferredBuried.end()) continue;
				O.water[nk] = { it->second.tw, it->second.src };
				break;
			}
		}
	}

	// ---- buildOccupancyWater: the boundary of the occupancy set, owner-clipped to the region.
	auto push_tri = [&](const int *a, const int *b, const int *c, float band, float fx, float fz) {
		const double ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
		const double vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
		double nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
		const double len = det_hypot3(nx, ny, nz);
		if (len < 1e-9) return; // zero-area triangle (the flatness clamp can collapse a face)
		nx /= len;
		ny /= len;
		nz /= len;
		const int *vv[3] = { a, b, c };
		for (int q = 0; q < 3; q++) {
			for (int ax = 0; ax < 3; ax++) out.pos.push_back((float)(vv[q][ax] * SF));
		}
		for (int q = 0; q < 3; q++) {
			out.nrm.push_back((float)nx);
			out.nrm.push_back((float)ny);
			out.nrm.push_back((float)nz);
			out.depth.push_back(band);
			out.flow.push_back(fx);
			out.flow.push_back(fz);
		}
	};

	for (const auto &kv : O.water) {
		const int64_t key = kv.first;
		const int cx = (int)((key >> 40) & 0xFFFFF) - 16384;
		const int cy = (int)((key >> 20) & 0xFFFFF) - 16384;
		const int cz = (int)(key & 0xFFFFF) - 16384;
		const double wx = cx * SF, wz = cz * SF;
		if (wx < x_min || wx >= x_max || wz < z_min || wz >= z_max) continue;
		const int tw = kv.second.tw;
		const int surf = 4 * tw + 2;
		int32_t gx, gz;
		Occupancy::col_of(cx, cz, gx, gz);
		const double bedT = std::floor(surface_height((gx + 0.5) * COL / SF, (gz + 0.5) * COL / SF, seed, &plan) / TERRACE_LAT);
		const double band = std::max(1.0, std::min(4.0, tw - bedT));
		float fx = 0, fz = 0;
		if (kv.second.src == SRC_COURSE || kv.second.src == SRC_FALL) {
			double dx, dz;
			if (get_flow_dir(plan, gx, gz, dx, dz)) {
				fx = (float)dx;
				fz = (float)dz;
			}
		}
		for (int fi = 0; fi < 14; fi++) {
			const int *off = TO_NEIGHBOR_OFFSETS[fi];
			const int nx = cx + off[0], ny = cy + off[1], nz = cz + off[2];
			if (O.water.count(cell_key(nx, ny, nz))) continue; // interior face
			if (O.is_solid(nx, ny, nz)) continue; // flush bank, hidden
			const int len = TO_FACE_LEN[fi];
			int vs[6][3];
			for (int q = 0; q < len; q++) {
				const int *v = TO_VERTICES[TO_FACES[fi][q]];
				vs[q][0] = cx + v[0];
				vs[q][1] = std::min(cy + v[1], surf); // flatness: pinned down to the water surface
				vs[q][2] = cz + v[2];
			}
			if (len == 4) {
				push_tri(vs[0], vs[1], vs[2], (float)band, fx, fz);
				push_tri(vs[0], vs[2], vs[3], (float)band, fx, fz);
			} else {
				for (int t = 1; t <= 4; t++) push_tri(vs[0], vs[t], vs[t + 1], (float)band, fx, fz);
			}
		}
	}
}

} // namespace stalag
