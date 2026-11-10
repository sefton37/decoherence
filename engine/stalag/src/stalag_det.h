#ifndef STALAG_DET_H
#define STALAG_DET_H

// Spec #517 A2 -- deterministic numeric primitives. No Godot types.
//
// Every function here is plain IEEE-754 double + - * / and sqrt, evaluated in the exact order
// written. The JavaScript twin lives in tools/baseline/proto_subst.mjs; the two agree bit for
// bit as long as the compiler neither fuses multiply-adds nor reorders (SConstruct pins
// -ffp-contract=off and uses no fast-math). A library hypot or log2 would differ in the last
// bit and move the water plan, so they are never used in the plan path.

#include <cmath>
#include <cstdint>
#include <limits>

namespace stalag {

// Euclidean length of 2 or 3 components, summed left to right. Domain: finite arguments of
// magnitude below 1e150 (world values stay below 1e4).
inline double det_hypot(double a, double b) { return std::sqrt(a * a + b * b); }
inline double det_hypot3(double a, double b, double c) { return std::sqrt((a * a + b * b) + c * c); }

// Base-2 logarithm from the calculus identity ln m = 2 * atanh(s) = 2 * (s + s^3/3 + s^5/5 + ...),
// with s = (m - 1) / (m + 1) after splitting x = m * 2^e. The series is summed by Horner's rule
// from the k = 23 term down to k = 1.
inline double det_log2(double x) {
	if (!(x > 0.0)) {
		if (x == 0.0) return -std::numeric_limits<double>::infinity();
		return std::numeric_limits<double>::quiet_NaN();
	}
	if (x == std::numeric_limits<double>::infinity()) return x;
	double m = x;
	double e = 0.0;
	while (m >= 2.0) {
		m = m * 0.5;
		e = e + 1.0;
	}
	while (m < 1.0) {
		m = m * 2.0;
		e = e - 1.0;
	}
	if (m > 1.4142135623730951) {
		m = m * 0.5;
		e = e + 1.0;
	}
	const double s = (m - 1.0) / (m + 1.0);
	const double z = s * s;
	double p = 1.0 / 23.0;
	for (int k = 21; k >= 1; k -= 2) p = p * z + 1.0 / (double)k;
	return e + ((2.0 * s) * p) * 1.4426950408889634;
}

// ---- trigonometry (Spec #517 A4.2): clean-room sin, cos and atan2 -----------------------------
// Plain IEEE + - * / and sqrt plus the exact operations floor and abs, in a fixed order.
// Reduction by quarter turns: n = nearest integer to x * (2/pi), r = x - n * (pi/2) with pi/2
// carried in three pieces whose products with a small integer n are exact, then Taylor
// kernels in nested (Horner) form on r, |r| <= pi/4. Domain |x| < 1e6, otherwise NaN.
// The constants are derived values (pi/2 split on a 26-bit grid), listed in engine/PROVENANCE.md.
namespace det_trig_detail {
constexpr double TWO_OVER_PI = 0.6366197723675814;
constexpr double CW_A = 1.570796325802803;
constexpr double CW_B = 9.920935739593517e-10;
constexpr double CW_C = 5.721188726109832e-18;
constexpr double PIO2 = 1.5707963267948966;
constexpr double PI = 3.141592653589793;

inline double poly_sin(double r) {
	const double z = r * r;
	double ps = 1.0;
	for (int k = 10; k >= 1; k--) {
		const double kd = (double)k;
		ps = 1.0 - (z / ((2.0 * kd) * (2.0 * kd + 1.0))) * ps;
	}
	return r * ps;
}
inline double poly_cos(double r) {
	const double z = r * r;
	double pc = 1.0;
	for (int k = 10; k >= 1; k--) {
		const double kd = (double)k;
		pc = 1.0 - (z / ((2.0 * kd - 1.0) * (2.0 * kd))) * pc;
	}
	return pc;
}
// reduces x; returns r and the quadrant q in {0, 1, 2, 3}; false when out of domain
inline bool reduce(double x, double &r, int &q) {
	if (!(std::fabs(x) < 1e6)) return false;
	const double n = std::floor(x * TWO_OVER_PI + 0.5);
	r = ((x - n * CW_A) - n * CW_B) - n * CW_C;
	q = (int)(n - 4.0 * std::floor(n / 4.0));
	return true;
}
// arctangent of t in [0, 1]: three half-angle steps (atan t = 2 atan(t / (1 + sqrt(1 + t^2)))),
// then the alternating series in nested form
inline double atan01(double t) {
	double u = t;
	for (int i = 0; i < 3; i++) u = u / (1.0 + std::sqrt(1.0 + u * u));
	const double z = u * u;
	double p = 0.0;
	for (int k = 10; k >= 0; k--) p = 1.0 / (2.0 * (double)k + 1.0) - z * p;
	return 8.0 * (u * p);
}
} // namespace det_trig_detail

inline double det_sin(double x) {
	double r;
	int q;
	if (!det_trig_detail::reduce(x, r, q)) return std::numeric_limits<double>::quiet_NaN();
	switch (q) {
		case 0: return det_trig_detail::poly_sin(r);
		case 1: return det_trig_detail::poly_cos(r);
		case 2: return -det_trig_detail::poly_sin(r);
		default: return -det_trig_detail::poly_cos(r);
	}
}
inline double det_cos(double x) {
	double r;
	int q;
	if (!det_trig_detail::reduce(x, r, q)) return std::numeric_limits<double>::quiet_NaN();
	switch (q) {
		case 0: return det_trig_detail::poly_cos(r);
		case 1: return -det_trig_detail::poly_sin(r);
		case 2: return -det_trig_detail::poly_cos(r);
		default: return det_trig_detail::poly_sin(r);
	}
}
inline double det_atan2(double y, double x) {
	using namespace det_trig_detail;
	if (!std::isfinite(y) || !std::isfinite(x)) return std::numeric_limits<double>::quiet_NaN();
	const double ay = std::fabs(y), ax = std::fabs(x);
	double r;
	if (ay == 0.0) r = 0.0;
	else if (ax == 0.0) r = PIO2;
	else if (ax >= ay) r = atan01(ay / ax);
	else r = PIO2 - atan01(ax / ay);
	if (x < 0.0 || std::signbit(x)) r = PI - r;
	return (y < 0.0 || std::signbit(y)) ? -r : r;
}

// ---- exponential and power (Spec #545 Phase A): clean-room exp and pow ------------------------
// The prototype's windfield.js (tag prototype-final) calls Math.exp and Math.pow; the oracle
// substitutes the twins in tools/baseline/proto_subst.mjs (installExpPow), in this exact order.
// exp: x = k * ln 2 + r with k the nearest integer to x * (1 / ln 2) and ln 2 carried in three
// pieces on a 30-bit grid (so k times a piece is exact for |k| < 2^23), then the Taylor series
// of exp r in nested form for |r| <= ln2 / 2, then k exact doublings or halvings. Domain: all
// doubles; NaN in gives NaN, results above the largest double give infinity, below the
// smallest subnormal give 0. The pieces are derived values, listed in engine/PROVENANCE.md.
// pow(x, y) = exp(y * ln x) with ln x = log2 x * ln 2, for x > 0; the usual special cases
// (y = 0, x = 0, x = infinity) are handled first and x < 0 gives NaN (not used by the game).
namespace det_exp_detail {
constexpr double LOG2E = 1.4426950408889634;
constexpr double LN2 = 0.6931471805599453;
constexpr double LN2_A = 0.6931471796706319;
constexpr double LN2_B = 8.893134232496047e-10;
constexpr double LN2_C = 6.390629507645039e-19;
} // namespace det_exp_detail

inline double det_exp(double x) {
	using namespace det_exp_detail;
	if (x != x) return std::numeric_limits<double>::quiet_NaN();
	if (x > 709.782712893384) return std::numeric_limits<double>::infinity();
	if (x < -745.2) return 0.0;
	const double k = std::floor(x * LOG2E + 0.5);
	const double r = ((x - k * LN2_A) - k * LN2_B) - k * LN2_C;
	double p = 1.0;
	for (int n = 18; n >= 1; n--) p = 1.0 + (r / (double)n) * p;
	int ki = (int)k;
	while (ki > 0) {
		p = p * 2.0;
		ki--;
	}
	while (ki < 0) {
		p = p * 0.5;
		ki++;
	}
	return p;
}

inline double det_pow(double x, double y) {
	using namespace det_exp_detail;
	if (y == 0.0) return 1.0;
	if (x != x || y != y) return std::numeric_limits<double>::quiet_NaN();
	if (x == 0.0) return y > 0.0 ? 0.0 : std::numeric_limits<double>::infinity();
	if (x < 0.0) return std::numeric_limits<double>::quiet_NaN();
	if (x == std::numeric_limits<double>::infinity()) return y > 0.0 ? x : 0.0;
	return det_exp(y * (det_log2(x) * LN2));
}

// SPDX-License-Identifier: LicenseRef-PublicDomain
// lowbias32: Chris Wellons, "Prospecting for Hash Functions", https://nullprogram.com/blog/2018/07/31/ (public domain)
inline uint32_t lowbias32(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

} // namespace stalag

#endif // STALAG_DET_H
