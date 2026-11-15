// SPDX-License-Identifier: AGPL-3.0-only
// Spec 582 S2: CPU instrument for the macro relief and the mesher window.
// Provenance: written for this project; no outside code.
// Plain C++17, no Godot. Built from the engine sources by tests/verify_relief.sh.
// usage: relief_check <tall_extent> <poses.tsv>   -> one JSON object on stdout
#include "stalag_core.h"
#include "stalag_plan.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
using namespace stalag;
namespace {
uint64_t fnv(uint64_t h, const void *p, size_t n) {
	const unsigned char *c = (const unsigned char *)p;
	for (size_t i = 0; i < n; i++) { h ^= c[i]; h *= 1099511628211ULL; }
	return h;
}
const uint64_t FNV0 = 1469598103934665603ULL;
double Hw(double x, double z, const WaterPlan *pl) { return surface_height(x / SF, z / SF, WORLD_SEED, pl) * SF; }
double Hb(double x, double z) { return surface_height_base(x / SF, z / SF, WORLD_SEED) * SF; }
double now_ms() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
std::string hex(uint64_t v) { char b[32]; snprintf(b, sizeof b, "%016llx", (unsigned long long)v); return b; }
struct Tri { float a[9]; };
struct Cov { size_t tris = 0; long points = 0, hit = 0, bad = 0; double max_err = 0, ms = 0; };
// Coverage oracle: one vertical ray per 1 m cell centre against the built triangles, compared with the engine's
// own ground_envelope_at (which does not use the mesher window).
Cov coverage(const WaterPlan *pl, int ext, double x0, double z0, int nx, double top) {
	Cov c; std::vector<Tri> ts;
	for (int k = 0; k < nx; k++) {
		SurfaceMesh sm; double t0 = now_ms();
		build_surface(WORLD_SEED, ext, x0 + 28 * k, x0 + 28 * k + 28, z0, z0 + 28, sm, pl);
		c.ms += now_ms() - t0;
		for (const Soup *s : { &sm.base, &sm.caps }) {
			c.tris += s->tris();
			for (size_t t = 0; t < s->tris(); t++) { Tri q; memcpy(q.a, &s->pos[9 * t], 36); ts.push_back(q); }
		}
	}
	const int W = 28 * nx, D = 28;
	std::vector<std::vector<int>> bins((size_t)W * D);
	for (size_t i = 0; i < ts.size(); i++) {
		float mnx = 1e9f, mxx = -1e9f, mnz = 1e9f, mxz = -1e9f;
		for (int v = 0; v < 3; v++) { mnx = std::min(mnx, ts[i].a[3 * v]); mxx = std::max(mxx, ts[i].a[3 * v]); mnz = std::min(mnz, ts[i].a[3 * v + 2]); mxz = std::max(mxz, ts[i].a[3 * v + 2]); }
		for (int bx = (int)std::floor(mnx - x0); bx <= (int)std::floor(mxx - x0); bx++)
			for (int bz = (int)std::floor(mnz - z0); bz <= (int)std::floor(mxz - z0); bz++)
				if (bx >= 0 && bx < W && bz >= 0 && bz < D) bins[(size_t)bz * W + bx].push_back((int)i);
	}
	for (int bx = 0; bx < W; bx++) for (int bz = 0; bz < D; bz++) {
		double px = x0 + bx + 0.5, pz = z0 + bz + 0.5, truth = ground_envelope_at(px, pz, top), best = -1e9;
		c.points++;
		for (int i : bins[(size_t)bz * W + bx]) {
			const float *a = ts[i].a; double ax = a[0], az = a[2], bx_ = a[3], bz_ = a[5], cx = a[6], cz = a[8];
			double d = (bz_ - cz) * (ax - cx) + (cx - bx_) * (az - cz); if (std::fabs(d) < 1e-12) continue;
			double l1 = ((bz_ - cz) * (px - cx) + (cx - bx_) * (pz - cz)) / d, l2 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d, l3 = 1 - l1 - l2;
			if (l1 < -1e-9 || l2 < -1e-9 || l3 < -1e-9) continue;
			best = std::max(best, l1 * a[1] + l2 * a[4] + l3 * a[7]);
		}
		if (best > -1e8) { c.hit++; double e = std::fabs(best - truth); c.max_err = std::max(c.max_err, e); if (e > 2.5) c.bad++; }
	}
	return c;
}
double median(std::vector<double> v) { std::sort(v.begin(), v.end()); return v[v.size() / 2]; }
}
int main(int argc, char **argv) {
	const int tall_ext = argc > 1 ? atoi(argv[1]) : 1792;
	start_plan_solve(WORLD_SEED); wait_plan_ready(); const WaterPlan *pl = shared_plan();
	if (!pl) { fprintf(stderr, "no plan\n"); return 1; }
	std::ostringstream o; o.setf(std::ios::fixed); o.precision(4);
	o << "{\"tall_extent\":" << tall_ext;
	{ // valley: the plan domain plus its 2 m guard
		uint64_t hc = FNV0, hb = FNV0; long n = 0;
		for (int x = -226; x <= 226; x++) for (int z = -226; z <= 226; z++) { double a = Hw(x, z, pl), b = Hb(x, z); hc = fnv(hc, &a, 8); hb = fnv(hb, &b, 8); n++; }
		o << ",\"valley\":{\"samples\":" << n << ",\"carved_hash\":\"" << hex(hc) << "\",\"base_hash\":\"" << hex(hb) << "\",\"plan_hash\":\"" << plan_hash(*pl) << "\"}";
	}
	{ // the 64 chunks of the footprint
		uint64_t h = FNV0; size_t tris = 0;
		for (int cx = -4; cx <= 3; cx++) for (int cz = -4; cz <= 3; cz++) {
			SurfaceMesh sm; build_surface(WORLD_SEED, WORLD_EXTENT, cx * 28.0, cx * 28.0 + 28, cz * 28.0, cz * 28.0 + 28, sm, pl);
			for (const Soup *s : { &sm.base, &sm.caps }) { h = fnv(h, s->pos.data(), s->pos.size() * 4); h = fnv(h, s->nrm.data(), s->nrm.size() * 4); h = fnv(h, s->col.data(), s->col.size() * 4); tris += s->tris(); }
		}
		o << ",\"footprint\":{\"chunks\":64,\"tris\":" << tris << ",\"mesh_hash\":\"" << hex(h) << "\"}";
	}
	{ // relief in the highland ring (Chebyshev 346 to 850 m), 100 m windows
		std::vector<double> rel; double hmax = -1e9, hmin = 1e9, hs = 0; long hn = 0;
		for (double cx = -900; cx < 900; cx += 100) for (double cz = -900; cz < 900; cz += 100) {
			double q = std::max(std::fabs(cx + 50), std::fabs(cz + 50)); if (q < 346 || q > 850) continue;
			double mn = 1e9, mx = -1e9;
			for (double x = cx; x < cx + 100; x += 5) for (double z = cz; z < cz + 100; z += 5) { double h = Hb(x, z); mn = std::min(mn, h); mx = std::max(mx, h); hmax = std::max(hmax, h); hmin = std::min(hmin, h); hs += h; hn++; }
			rel.push_back(mx - mn);
		}
		std::sort(rel.begin(), rel.end());
		double step = 0; for (double x = -840; x < 840; x += 1) for (double z = -840; z < 840; z += 17) step = std::max(step, std::fabs(Hw(x + 1, z, pl) - Hw(x, z, pl)));
		o << ",\"relief\":{\"windows\":" << rel.size() << ",\"p10_m\":" << rel[rel.size() / 10] << ",\"p50_m\":" << rel[rel.size() / 2] << ",\"p90_m\":" << rel[rel.size() * 9 / 10]
		  << ",\"hmax_m\":" << hmax << ",\"hmin_m\":" << hmin << ",\"hmean_m\":" << hs / hn << ",\"step_max_1m_m\":" << step << "}";
	}
	{ // the tallest 28 m chunk in the highland ring, and a row of three across the plan-domain edge
		double bx = 0, bz = 0, bh = -1e9;
		for (int cx = -30; cx < 30; cx++) for (int cz = -30; cz < 30; cz++) {
			double x0 = cx * 28.0, z0 = cz * 28.0, q = std::max(std::fabs(x0 + 14), std::fabs(z0 + 14)); if (q < 346 || q > 850) continue;
			double h = -1e9; for (double x = x0; x < x0 + 28; x += 2) for (double z = z0; z < z0 + 28; z += 2) h = std::max(h, Hb(x, z));
			if (h > bh) { bh = h; bx = x0; bz = z0; }
		}
		Cov t = coverage(pl, tall_ext, bx, bz, 1, bh + 20);
		Cov e = coverage(pl, tall_ext, 196, 0, 3, 130);
		o << ",\"tall\":{\"x0\":" << bx << ",\"z0\":" << bz << ",\"hmax_m\":" << bh << ",\"tris\":" << t.tris << ",\"points\":" << t.points << ",\"hit_frac\":" << (double)t.hit / t.points << ",\"bad\":" << t.bad << ",\"max_err_m\":" << t.max_err << ",\"build_ms\":" << t.ms << "}";
		o << ",\"edge\":{\"x0\":196,\"chunks\":3,\"tris\":" << e.tris << ",\"points\":" << e.points << ",\"hit_frac\":" << (double)e.hit / e.points << ",\"bad\":" << e.bad << ",\"max_err_m\":" << e.max_err << "}";
		std::vector<double> vt, tt;
		for (int i = 0; i < 5; i++) { SurfaceMesh sm; double t0 = now_ms(); build_surface(WORLD_SEED, WORLD_EXTENT, 0, 28, 0, 28, sm, pl); vt.push_back(now_ms() - t0); }
		for (int i = 0; i < 3; i++) { SurfaceMesh sm; double t0 = now_ms(); build_surface(WORLD_SEED, tall_ext, bx, bx + 28, bz, bz + 28, sm, pl); tt.push_back(now_ms() - t0); }
		o << ",\"timing\":{\"valley_chunk_ms_median\":" << median(vt) << ",\"tall_chunk_ms_median\":" << median(tt) << "}";
	}
	{ // terrain-only skyline from each pose (rays over the engine's carved height to 840 m)
		std::ifstream f(argc > 2 ? argv[2] : "/dev/null"); std::string id; double x, z, h, head, hf, fov; o << ",\"skyline\":[";
		bool first = true;
		while (f >> id >> x >> z >> h >> head >> hf >> fov) {
			double cy = Hw(x, z, pl) + h, hfov = 2 * std::atan(std::tan(fov * M_PI / 360) * 16.0 / 9.0); std::vector<double> rise; const int N = 200;
			for (int c = 0; c < N; c++) {
				double az = head * M_PI / 180 + (((c + 0.5) / N) - 0.5) * hfov, dx = std::sin(az), dz = std::cos(az), best = -90;
				for (double d = 2; d <= 840; d += (d < 150 ? 1.0 : (d < 400 ? 2.0 : 4.0))) best = std::max(best, std::atan((Hw(x + dx * d, z + dz * d, pl) - cy) / d) * 180 / M_PI);
				rise.push_back(best);
			}
			std::sort(rise.begin(), rise.end());
			o << (first ? "" : ",") << "{\"id\":\"" << id << "\",\"rise_p10_deg\":" << rise[N / 10] << ",\"rise_med_deg\":" << rise[N / 2] << ",\"rise_max_deg\":" << rise[N - 1] << "}"; first = false;
		}
		o << "]";
	}
	o << "}\n"; printf("%s", o.str().c_str());
	shutdown_plan(); return 0;
}
