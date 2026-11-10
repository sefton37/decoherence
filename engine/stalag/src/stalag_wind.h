#ifndef STALAG_WIND_H
#define STALAG_WIND_H

// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545 -- C++ port of src/windfield.js from the frozen Stalag prototype (tag prototype-final).
// The analytic wind field: curl-of-streamfunction flow, gust gain, boundary layer, terrain coupling,
// vorticles and the weather front. Every expression keeps the prototype's operation order so the
// results agree with the oracle (tools/baseline/js_flora_oracle.mjs) bit for bit; trigonometry,
// hypot, exp and pow come from stalag_det.h (the oracle installs the matching substitutes).

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace stalag {

struct Front {
	double active, nx, nz, offset, peak;
};
struct FrontGain {
	double gain, sbs;
};
struct WindSample {
	double vec[3];
	double strength;
};

double vnoise3(double x, double y, double z, int32_t seed);
double prevail_heading(double t, int32_t seed);
double diurnal(double t);
double boundary_layer(double h_above_ground);
void horizontal_curl(double x, double z, double t, int32_t seed, double th, double out[2]);
double gust_gain(double x, double z, double t, int32_t seed, double dx, double dz);
double thermal_updraft(double x, double z, double t, int32_t seed, double h_ground);
void katabatic_drain(double x, double z, double t, int32_t seed, double h_ground, double out[3]);
void obstacle_deflect(double x, double z, int32_t seed, double hx, double hz, double out[2]);
void vorticle_field(double x, double z, double t, int32_t seed, double out[3]);
Front current_front(double t, int32_t seed);
FrontGain front_at(double x, double z, double t, int32_t seed);
WindSample wind_at(double x, double y, double z, double t, int32_t seed);
void active_vorticles(double t, int32_t seed, double cx, double cz, double range, std::vector<std::vector<double>> &out);

// Negative controls: 0 none, 1 no_gust, 2 flow_sign, 3 no_terrain.
void set_wind_mutation(int m);
int wind_mutation();

} // namespace stalag

namespace godot {

// Static GDScript surface of the wind field (world seed). Game policy (amplitudes, the per-frame
// uniform feed) stays in game/world/.
class StalagWind : public RefCounted {
	GDCLASS(StalagWind, RefCounted)

protected:
	static void _bind_methods();

public:
	// {active, nx, nz, offset, peak} of the front at time t (windfield.js currentFront).
	static Dictionary current_front(double p_t);
	// {vx, vy, vz, strength} (windfield.js windAt).
	static Dictionary wind_at(double p_x, double p_y, double p_z, double p_t);
	// prevailingWind heading (rad) at t.
	static double heading(double p_t);
	// The same pieces with an explicit seed, for the ported windfield invariants.
	static Dictionary wind_at_seed(double p_x, double p_y, double p_z, double p_t, int64_t p_seed);
	static PackedFloat64Array vorticle_field(double p_x, double p_z, double p_t, int64_t p_seed);
	static Array active_vorticles(double p_t, int64_t p_seed, double p_cx, double p_cz, double p_range);
	static Dictionary front_gain(double p_x, double p_z, double p_t, int64_t p_seed);
	static PackedFloat64Array katabatic(double p_x, double p_z, double p_t, int64_t p_seed, double p_h);
	static double thermal(double p_x, double p_z, double p_t, int64_t p_seed, double p_h);
	// Bulk evaluation for the oracle: samples is 4 doubles (x, y, z, t) per sample. Returns one
	// PackedFloat64Array per part name (boundary, deflect, flow, front, gust, katabatic, prevail,
	// thermal, vnoise3, vorticle, windat), each a fixed number of doubles per sample.
	static Dictionary run_samples(const PackedFloat64Array &p_samples);
	static void set_mutation(const String &p_name); // none | no_gust | flow_sign | no_terrain
};

} // namespace godot

#endif // STALAG_WIND_H
