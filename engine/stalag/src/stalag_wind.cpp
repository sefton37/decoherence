// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545 -- C++ port of src/windfield.js from the frozen Stalag prototype (tag prototype-final).
// See stalag_wind.h. Constants are the prototype's, named as there.

#include "stalag_wind.h"

#include "stalag_core.h"
#include "stalag_det.h"
#include "stalag_plan.h"

#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <cmath>
#include <vector>

namespace stalag {

namespace {

constexpr double PI_ = 3.141592653589793; // Math.PI

constexpr double PREVAIL_SPEED = 2.0;
constexpr double PREVAIL_DIR0 = 0.6;
constexpr double TURB_FEAT = 28.0;
constexpr double TURB_AMP = 6.0;
constexpr double TIME_DRIFT = 0.05;
constexpr double GUST_FEAT = 45.0, GUST_SPEED = 2.0, GUST_LO = 0.55, GUST_HI = 0.82, GUST_BOOST = 1.8;
constexpr double BL_ZREF = 8.0, BL_EXP = 0.143, BL_FLOOR = 0.35;
constexpr double MAX_SPEED = 6.0;

constexpr double DAY_LEN = 600, DAY_PHASE0 = 0.30;
constexpr double TC_E = 1.0;
constexpr double THERM_AMP = 1.4, THERM_FEAT = 55.0, THERM_HEIGHT = 18.0, THERM_LO = 0.42, THERM_HI = 0.80, THERM_FLATK = 1.6;
constexpr double KATA_AMP = 1.1, KATA_HEIGHT = 4.0, KATA_SINK = 0.30, KATA_SLOPE0 = 0.04;
constexpr double CHAN_LO = 0.18, CHAN_HI = 0.75, CURV_REF = 0.04, DEFLECT_SHELTER = 0.45, DEFLECT_RIDGE = 0.40;

constexpr double VORT_CELL = 22.0, VORT_BUCKET = 18.0;
constexpr double VORT_SPAWN = 0.22, VORT_FLOOR = 0.55;
constexpr double VORT_RADIUS = 9.0, VORT_STRENGTH = 2.6, VORT_LIFT = 0.5, VORT_DRIFT = 0.6, VORT_INFLOW = 0.35;
constexpr double FRONT_PERIOD = 110.0, FRONT_CHANCE = 0.30;
constexpr double FRONT_BAND = 28.0, FRONT_SPEED = 3.0, FRONT_GAIN = 2.4, FRONT_ENTER = 90.0;

std::atomic<int> g_mut{ 0 };

// worldgen.js fade and lerp.
inline double fade_(double t) { return t * t * t * (t * (t * 6 - 15) + 10); }
inline double lerp_(double a, double b, double t) { return a + t * (b - a); }

// JS `x | 0` on a double of modest size.
inline int32_t i32(double v) { return (int32_t)(int64_t)v; }
inline int32_t xor_i32(int32_t a, int64_t b) { return (int32_t)((uint32_t)a ^ (uint32_t)b); }

inline double smooth(double a, double b, double x) {
	const double t = std::min(1.0, std::max(0.0, (x - a) / (b - a)));
	return t * t * (3 - 2 * t);
}

inline double snoise3(double x, double y, double z, int32_t s) { return vnoise3(x, y, z, s) * 2 - 1; }

double fbm3(double x, double y, double z, int32_t s) {
	double a = 0, amp = 0.5, f = 1;
	for (int o = 0; o < 3; o++) {
		a += amp * snoise3(x * f, y * f, z * f, xor_i32(s, (int64_t)o * 0x9e37));
		f *= 2;
		amp *= 0.5;
	}
	return a;
}

// terrain: gradient and curvature of the local lid, metres (finite differences of the carved surface).
inline double sh_m(double x, double z, int32_t seed) { return surface_height(x / SF, z / SF, seed, shared_plan()) * SF; }

void terrain_grad(double x, double z, int32_t seed, double out[2]) {
	if (g_mut.load() == 3) {
		out[0] = 0;
		out[1] = 0;
		return;
	}
	const double hpx = sh_m(x + TC_E, z, seed), hmx = sh_m(x - TC_E, z, seed);
	const double hpz = sh_m(x, z + TC_E, seed), hmz = sh_m(x, z - TC_E, seed);
	out[0] = (hpx - hmx) / (2 * TC_E);
	out[1] = (hpz - hmz) / (2 * TC_E);
}

double terrain_curvature(double x, double z, int32_t seed) {
	if (g_mut.load() == 3) return 0;
	const double h0 = sh_m(x, z, seed);
	const double hpx = sh_m(x + TC_E, z, seed), hmx = sh_m(x - TC_E, z, seed);
	const double hpz = sh_m(x, z + TC_E, seed), hmz = sh_m(x, z - TC_E, seed);
	return (hpx + hmx + hpz + hmz - 4 * h0) / (TC_E * TC_E);
}

double vorticle_gate(double t) {
	const double dp = diurnal(t);
	const double afternoon = smooth(0.40, 0.54, dp) * (1 - smooth(0.70, 0.84, dp));
	return VORT_FLOOR + (1 - VORT_FLOOR) * afternoon;
}

struct Vorticle {
	double cx, cz, env, dir_th;
	int kind; // 0 vortex, 1 linear, 2 down
	int32_t ci, cj, tb;
};

template <typename F>
void for_each_vorticle(double x, double z, double t, int32_t seed, F cb) {
	const double gate = vorticle_gate(t), thr = gate * VORT_SPAWN;
	const double tbd = std::floor(t / VORT_BUCKET);
	const int32_t tb = i32(tbd);
	const double env = det_sin(PI_ * (t / VORT_BUCKET - tbd));
	const double th = prevail_heading(t, seed), drift = (t - tbd * VORT_BUCKET) * VORT_DRIFT;
	const int32_t ci0 = i32(std::floor(x / VORT_CELL)), cj0 = i32(std::floor(z / VORT_CELL));
	for (int di = -1; di <= 1; di++) {
		for (int dj = -1; dj <= 1; dj++) {
			const int32_t ci = ci0 + di, cj = cj0 + dj;
			if (hash_cell(ci, cj, tb, xor_i32(seed, 0x4f1)) > thr) continue;
			const double jx = hash_cell(ci, cj, tb ^ 0x1a3, seed), jz = hash_cell(cj, ci, tb ^ 0x2b7, seed);
			const double cx = (ci + jx) * VORT_CELL + det_cos(th) * drift;
			const double cz = (cj + jz) * VORT_CELL + det_sin(th) * drift;
			const double kr = hash_cell(ci, cj, tb ^ 0x77, xor_i32(seed, 0x55));
			const int kind = kr < 0.7 ? 0 : kr < 0.88 ? 1 : 2;
			cb(Vorticle{ cx, cz, env, th, kind, ci, cj, tb });
		}
	}
}

} // namespace

void set_wind_mutation(int m) { g_mut.store(m); }
int wind_mutation() { return g_mut.load(); }

double vnoise3(double x, double y, double z, int32_t seed) {
	const double fx0 = std::floor(x), fy0 = std::floor(y), fz0 = std::floor(z);
	const int32_t ix = i32(fx0), iy = i32(fy0), iz = i32(fz0);
	const double fx = fade_(x - fx0), fy = fade_(y - fy0), fz = fade_(z - fz0);
	auto c = [&](int dx, int dy, int dz) { return hash_cell(ix + dx, iy + dy, iz + dz, seed); };
	const double x00 = lerp_(c(0, 0, 0), c(1, 0, 0), fx), x10 = lerp_(c(0, 1, 0), c(1, 1, 0), fx);
	const double x01 = lerp_(c(0, 0, 1), c(1, 0, 1), fx), x11 = lerp_(c(0, 1, 1), c(1, 1, 1), fx);
	return lerp_(lerp_(x00, x10, fy), lerp_(x01, x11, fy), fz);
}

double prevail_heading(double t, int32_t seed) {
	return PREVAIL_DIR0 + 0.35 * (noise_value(t * 0.008, 0, xor_i32(seed, 0x51ed)) * 2 - 1);
}

double diurnal(double t) { return std::fmod(std::fmod((t / DAY_LEN) + DAY_PHASE0, 1.0) + 1, 1.0); }

double boundary_layer(double h_above_ground) {
	const double h = std::max(0.0, h_above_ground);
	return std::min(1.0, std::max(BL_FLOOR, det_pow(h / BL_ZREF, BL_EXP)));
}

void horizontal_curl(double x, double z, double t, int32_t seed, double th, double out[2]) {
	const double tt = t * TIME_DRIFT, ct = det_cos(th), st = det_sin(th);
	auto psi = [&](double px, double pz) {
		return PREVAIL_SPEED * (ct * pz - st * px) + TURB_AMP * fbm3(px / TURB_FEAT, pz / TURB_FEAT, tt, xor_i32(seed, 0x1bd));
	};
	const double e = 0.5;
	out[0] = (psi(x, z + e) - psi(x, z - e)) / (2 * e);
	out[1] = -(psi(x + e, z) - psi(x - e, z)) / (2 * e);
	if (g_mut.load() == 2) {
		out[0] = -out[0];
		out[1] = -out[1];
	}
}

double gust_gain(double x, double z, double t, int32_t seed, double dx, double dz) {
	if (g_mut.load() == 1) return 1.0;
	const double ax = x - dx * GUST_SPEED * t, az = z - dz * GUST_SPEED * t;
	return 1 + GUST_BOOST * smooth(GUST_LO, GUST_HI, vnoise3(ax / GUST_FEAT, az / GUST_FEAT, t * 0.03, xor_i32(seed, 0x2f17)));
}

double thermal_updraft(double x, double z, double t, int32_t seed, double h_ground) {
	const double midday = 0.5 - 0.5 * det_cos(2 * PI_ * diurnal(t));
	double g[2];
	terrain_grad(x, z, seed, g);
	const double flat = std::max(0.0, 1 - det_hypot(g[0], g[1]) * THERM_FLATK);
	const double patch = smooth(THERM_LO, THERM_HI, vnoise3(x / THERM_FEAT, z / THERM_FEAT, t * 0.02, xor_i32(seed, 0x7a13)));
	const double decay = det_exp(-std::max(0.0, h_ground) / THERM_HEIGHT);
	return THERM_AMP * midday * flat * patch * decay;
}

void katabatic_drain(double x, double z, double t, int32_t seed, double h_ground, double out[3]) {
	const double night = 0.5 + 0.5 * det_cos(2 * PI_ * diurnal(t));
	double g[2];
	terrain_grad(x, z, seed, g);
	const double slope = det_hypot(g[0], g[1]);
	if (slope < KATA_SLOPE0 || night <= 0) {
		out[0] = out[1] = out[2] = 0;
		return;
	}
	const double dirx = -g[0] / slope, dirz = -g[1] / slope;
	const double near_ground = det_exp(-std::max(0.0, h_ground) / KATA_HEIGHT);
	const double mag = KATA_AMP * night * std::min(1.0, slope) * near_ground;
	out[0] = dirx * mag;
	out[1] = -KATA_SINK * mag;
	out[2] = dirz * mag;
}

void obstacle_deflect(double x, double z, int32_t seed, double hx, double hz, double out[2]) {
	double g[2];
	terrain_grad(x, z, seed, g);
	const double slope = det_hypot(g[0], g[1]);
	// JS: `slope || 1` -- zero (or NaN) slope falls back to 1.
	const double cl = slope != 0 ? slope : 1, cx = -g[1] / cl, cz = g[0] / cl;
	const double along = hx * cx + hz * cz;
	const double chan = smooth(CHAN_LO, CHAN_HI, slope);
	const double dhx = hx * (1 - chan) + along * cx * chan;
	const double dhz = hz * (1 - chan) + along * cz * chan;
	const double curv = terrain_curvature(x, z, seed);
	const double exposure = 1 + DEFLECT_RIDGE * smooth(0, CURV_REF, -curv) - DEFLECT_SHELTER * smooth(0, CURV_REF, curv);
	out[0] = dhx * exposure;
	out[1] = dhz * exposure;
}

void vorticle_field(double x, double z, double t, int32_t seed, double out[3]) {
	double vx = 0, vy = 0, vz = 0;
	for_each_vorticle(x, z, t, seed, [&](const Vorticle &v) {
		const double dx = x - v.cx, dz = z - v.cz, dist = det_hypot(dx, dz);
		const double fall = std::max(0.0, 1 - dist / VORT_RADIUS);
		if (fall <= 0) return;
		const double amp = VORT_STRENGTH * fall * v.env;
		if (v.kind == 0) {
			const double il = dist > 1e-3 ? 1 / dist : 0;
			vx += amp * (-dz * il - VORT_INFLOW * dx * il);
			vz += amp * (dx * il - VORT_INFLOW * dz * il);
			vy += amp * VORT_LIFT;
		} else if (v.kind == 1) {
			vx += amp * det_cos(v.dir_th);
			vz += amp * det_sin(v.dir_th);
		} else {
			vy -= amp;
		}
	});
	out[0] = vx;
	out[1] = vy;
	out[2] = vz;
}

// windfield.js activeVorticles: unique vorticles near (cx, cz); out is {cx, cz, kind, ci, cj, tb} rows.
void active_vorticles(double t, int32_t seed, double cx, double cz, double range, std::vector<std::vector<double>> &out) {
	std::vector<std::vector<int32_t>> seen;
	for (double x = cx - range; x <= cx + range; x += VORT_CELL) {
		for (double z = cz - range; z <= cz + range; z += VORT_CELL) {
			for_each_vorticle(x, z, t, seed, [&](const Vorticle &v) {
				for (const auto &k : seen)
					if (k[0] == v.ci && k[1] == v.cj && k[2] == v.tb) return;
				seen.push_back({ v.ci, v.cj, v.tb });
				out.push_back({ v.cx, v.cz, (double)v.kind, (double)v.ci, (double)v.cj, (double)v.tb });
			});
		}
	}
}

Front current_front(double t, int32_t seed) {
	const double fbd = std::floor(t / FRONT_PERIOD);
	const int32_t fb = i32(fbd);
	if (hash_cell(fb, 0x1f, 0, xor_i32(seed, 0x4f1)) > FRONT_CHANCE) return Front{ 0, 1, 0, 0, 0 };
	const double fth = hash_cell(fb, 0x2e, 1, seed) * PI_ * 2;
	const double peak = 0.6 + 0.4 * hash_cell(fb, 0x3d, 2, seed);
	return Front{ 1, det_cos(fth), det_sin(fth), FRONT_SPEED * (t - fbd * FRONT_PERIOD) - FRONT_ENTER, peak };
}

FrontGain front_at(double x, double z, double t, int32_t seed) {
	const Front f = current_front(t, seed);
	if (!f.active) return FrontGain{ 1, 1.5 };
	const double s = (f.nx * x + f.nz * z) - f.offset;
	const double band = std::max(0.0, 1 - std::fabs(s) / FRONT_BAND);
	return FrontGain{ 1 + (FRONT_GAIN - 1) * f.peak * band, 1.5 + 4.5 * f.peak * band };
}

WindSample wind_at(double x, double y, double z, double t, int32_t seed) {
	const double th = prevail_heading(t, seed), dx = det_cos(th), dz = det_sin(th);
	double h[2];
	horizontal_curl(x, z, t, seed, th, h);
	double hx = h[0], hz = h[1];
	const double g = gust_gain(x, z, t, seed, dx, dz);
	const double h_ground = y - sh_m(x, z, seed);
	const double bl = boundary_layer(h_ground);
	double d[2];
	obstacle_deflect(x, z, seed, hx, hz, d);
	hx = d[0];
	hz = d[1];
	const double fg = front_at(x, z, t, seed).gain;
	double vx = hx * g * bl * fg, vz = hz * g * bl * fg;
	double o[3];
	vorticle_field(x, z, t, seed, o);
	const double vyT = thermal_updraft(x, z, t, seed, h_ground);
	double k[3];
	katabatic_drain(x, z, t, seed, h_ground, k);
	vx += k[0] + o[0];
	vz += k[2] + o[2];
	const double vy = vyT + k[1] + o[1];
	const double speed = det_hypot3(vx, vy, vz);
	WindSample w;
	w.vec[0] = vx;
	w.vec[1] = vy;
	w.vec[2] = vz;
	w.strength = std::min(1.0, speed / MAX_SPEED);
	return w;
}

} // namespace stalag

namespace godot {

void StalagWind::_bind_methods() {
	ClassDB::bind_static_method("StalagWind", D_METHOD("current_front", "t"), &StalagWind::current_front);
	ClassDB::bind_static_method("StalagWind", D_METHOD("wind_at", "x", "y", "z", "t"), &StalagWind::wind_at);
	ClassDB::bind_static_method("StalagWind", D_METHOD("heading", "t"), &StalagWind::heading);
	ClassDB::bind_static_method("StalagWind", D_METHOD("wind_at_seed", "x", "y", "z", "t", "seed"), &StalagWind::wind_at_seed);
	ClassDB::bind_static_method("StalagWind", D_METHOD("vorticle_field", "x", "z", "t", "seed"), &StalagWind::vorticle_field);
	ClassDB::bind_static_method("StalagWind", D_METHOD("active_vorticles", "t", "seed", "cx", "cz", "range"), &StalagWind::active_vorticles);
	ClassDB::bind_static_method("StalagWind", D_METHOD("front_gain", "x", "z", "t", "seed"), &StalagWind::front_gain);
	ClassDB::bind_static_method("StalagWind", D_METHOD("katabatic", "x", "z", "t", "seed", "h"), &StalagWind::katabatic);
	ClassDB::bind_static_method("StalagWind", D_METHOD("thermal", "x", "z", "t", "seed", "h"), &StalagWind::thermal);
	ClassDB::bind_static_method("StalagWind", D_METHOD("run_samples", "samples"), &StalagWind::run_samples);
	ClassDB::bind_static_method("StalagWind", D_METHOD("set_mutation", "name"), &StalagWind::set_mutation);
}

Dictionary StalagWind::current_front(double p_t) {
	const stalag::Front f = stalag::current_front(p_t, stalag::WORLD_SEED);
	Dictionary d;
	d["active"] = f.active;
	d["nx"] = f.nx;
	d["nz"] = f.nz;
	d["offset"] = f.offset;
	d["peak"] = f.peak;
	return d;
}

Dictionary StalagWind::wind_at(double p_x, double p_y, double p_z, double p_t) {
	const stalag::WindSample w = stalag::wind_at(p_x, p_y, p_z, p_t, stalag::WORLD_SEED);
	Dictionary d;
	d["vx"] = w.vec[0];
	d["vy"] = w.vec[1];
	d["vz"] = w.vec[2];
	d["strength"] = w.strength;
	return d;
}

Dictionary StalagWind::wind_at_seed(double p_x, double p_y, double p_z, double p_t, int64_t p_seed) {
	const stalag::WindSample w = stalag::wind_at(p_x, p_y, p_z, p_t, (int32_t)p_seed);
	Dictionary d;
	d["vx"] = w.vec[0];
	d["vy"] = w.vec[1];
	d["vz"] = w.vec[2];
	d["strength"] = w.strength;
	return d;
}

PackedFloat64Array StalagWind::vorticle_field(double p_x, double p_z, double p_t, int64_t p_seed) {
	double o[3];
	stalag::vorticle_field(p_x, p_z, p_t, (int32_t)p_seed, o);
	PackedFloat64Array a;
	a.push_back(o[0]);
	a.push_back(o[1]);
	a.push_back(o[2]);
	return a;
}

Array StalagWind::active_vorticles(double p_t, int64_t p_seed, double p_cx, double p_cz, double p_range) {
	std::vector<std::vector<double>> rows;
	stalag::active_vorticles(p_t, (int32_t)p_seed, p_cx, p_cz, p_range, rows);
	Array out;
	for (const auto &r : rows) {
		Dictionary d;
		d["cx"] = r[0];
		d["cz"] = r[1];
		d["kind"] = r[2] == 0 ? String("vortex") : (r[2] == 1 ? String("linear") : String("down"));
		out.push_back(d);
	}
	return out;
}

Dictionary StalagWind::front_gain(double p_x, double p_z, double p_t, int64_t p_seed) {
	const stalag::FrontGain g = stalag::front_at(p_x, p_z, p_t, (int32_t)p_seed);
	Dictionary d;
	d["gain"] = g.gain;
	d["sbs"] = g.sbs;
	return d;
}

PackedFloat64Array StalagWind::katabatic(double p_x, double p_z, double p_t, int64_t p_seed, double p_h) {
	double k[3];
	stalag::katabatic_drain(p_x, p_z, p_t, (int32_t)p_seed, p_h, k);
	PackedFloat64Array a;
	a.push_back(k[0]);
	a.push_back(k[1]);
	a.push_back(k[2]);
	return a;
}

double StalagWind::thermal(double p_x, double p_z, double p_t, int64_t p_seed, double p_h) {
	return stalag::thermal_updraft(p_x, p_z, p_t, (int32_t)p_seed, p_h);
}

double StalagWind::heading(double p_t) { return stalag::prevail_heading(p_t, stalag::WORLD_SEED); }

Dictionary StalagWind::run_samples(const PackedFloat64Array &p_samples) {
	using namespace stalag;
	const int32_t seed = WORLD_SEED;
	const int64_t n = p_samples.size() / 4;
	std::vector<double> boundary, deflect, flow, front, gust, katabatic, prevail, thermal, vn, vorticle, windat;
	for (int64_t i = 0; i < n; i++) {
		const double x = p_samples[i * 4], y = p_samples[i * 4 + 1], z = p_samples[i * 4 + 2], t = p_samples[i * 4 + 3];
		vn.push_back(vnoise3(x * 0.1, t * 0.05, z * 0.1, seed));
		const double th = prevail_heading(t, seed);
		prevail.push_back(th);
		double fl[2];
		horizontal_curl(x, z, t, seed, th, fl);
		flow.push_back(fl[0]);
		flow.push_back(fl[1]);
		gust.push_back(gust_gain(x, z, t, seed, det_cos(th), det_sin(th)));
		boundary.push_back(boundary_layer(y));
		double de[2];
		obstacle_deflect(x, z, seed, fl[0], fl[1], de);
		deflect.push_back(de[0]);
		deflect.push_back(de[1]);
		thermal.push_back(thermal_updraft(x, z, t, seed, y));
		double ka[3];
		katabatic_drain(x, z, t, seed, y, ka);
		for (int k = 0; k < 3; k++) katabatic.push_back(ka[k]);
		double vo[3];
		stalag::vorticle_field(x, z, t, seed, vo);
		for (int k = 0; k < 3; k++) vorticle.push_back(vo[k]);
		const FrontGain fg = front_at(x, z, t, seed);
		const Front cf = stalag::current_front(t, seed);
		front.push_back(fg.gain);
		front.push_back(fg.sbs);
		front.push_back(cf.active);
		front.push_back(cf.nx);
		front.push_back(cf.nz);
		front.push_back(cf.offset);
		front.push_back(cf.peak);
		const WindSample w = stalag::wind_at(x, y, z, t, seed);
		windat.push_back(w.vec[0]);
		windat.push_back(w.vec[1]);
		windat.push_back(w.vec[2]);
		windat.push_back(w.strength);
	}
	auto pack = [](const std::vector<double> &v) {
		PackedFloat64Array a;
		a.resize((int64_t)v.size());
		for (size_t i = 0; i < v.size(); i++) a[(int64_t)i] = v[i];
		return a;
	};
	Dictionary d;
	d["boundary"] = pack(boundary);
	d["deflect"] = pack(deflect);
	d["flow"] = pack(flow);
	d["front"] = pack(front);
	d["gust"] = pack(gust);
	d["katabatic"] = pack(katabatic);
	d["prevail"] = pack(prevail);
	d["thermal"] = pack(thermal);
	d["vnoise3"] = pack(vn);
	d["vorticle"] = pack(vorticle);
	d["windat"] = pack(windat);
	return d;
}

void StalagWind::set_mutation(const String &p_name) {
	int m = 0;
	if (p_name == "no_gust") m = 1;
	else if (p_name == "flow_sign") m = 2;
	else if (p_name == "no_terrain") m = 3;
	stalag::set_wind_mutation(m);
}

} // namespace godot
