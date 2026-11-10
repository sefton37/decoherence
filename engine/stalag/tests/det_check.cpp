// Spec #517 A2: bit-exactness check of the engine's deterministic primitives (stalag_det.h)
// against vectors generated in JavaScript by tools/baseline/proto_subst.mjs. Plain C++17, no
// Godot. Run by tests/verify_stalag_det.sh, which builds it in several variants:
//   (none)               the engine's own functions
//   -DCHECK_LIBM_HYPOT the C library hypot instead (must show hypot mismatches only)
//   -DCHECK_LIBM_LOG2  the C library log2 instead (must show log2 mismatches only)
//   -DCHECK_LIBM_TRIG  the C library sin, cos, atan2 instead (trig families only)
//   -DCHECK_LIBM_EXP   the C library exp and pow instead (exp and pow families only; Spec #545)
// and one build with fused multiply-add contraction enabled (must show mismatches).
// Comparison is bitwise; NaN equals NaN.
//
// usage: det_check <vectors.bin>   -> one JSON object on stdout

#include "../src/stalag_det.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

double f_hypot2(double a, double b) {
#ifdef CHECK_LIBM_HYPOT
	return std::hypot(a, b);
#else
	return stalag::det_hypot(a, b);
#endif
}
double f_hypot3(double a, double b, double c) {
#ifdef CHECK_LIBM_HYPOT
	return std::hypot(a, b, c);
#else
	return stalag::det_hypot3(a, b, c);
#endif
}
double f_log2(double x) {
#ifdef CHECK_LIBM_LOG2
	return std::log2(x);
#else
	return stalag::det_log2(x);
#endif
}

double f_sin(double x) {
#ifdef CHECK_LIBM_TRIG
	return std::sin(x);
#else
	return stalag::det_sin(x);
#endif
}
double f_cos(double x) {
#ifdef CHECK_LIBM_TRIG
	return std::cos(x);
#else
	return stalag::det_cos(x);
#endif
}
double f_atan2(double y, double x) {
#ifdef CHECK_LIBM_TRIG
	return std::atan2(y, x);
#else
	return stalag::det_atan2(y, x);
#endif
}

double f_exp(double x) {
#ifdef CHECK_LIBM_EXP
	return std::exp(x);
#else
	return stalag::det_exp(x);
#endif
}
double f_pow(double x, double y) {
#ifdef CHECK_LIBM_EXP
	return std::pow(x, y);
#else
	return stalag::det_pow(x, y);
#endif
}

bool same(double a, double b) {
	if (std::isnan(a) && std::isnan(b)) return true;
	uint64_t x, y;
	std::memcpy(&x, &a, 8);
	std::memcpy(&y, &b, 8);
	return x == y;
}

} // namespace

int main(int argc, char **argv) {
	if (argc < 2) {
		std::fprintf(stderr, "usage: det_check <vectors.bin>\n");
		return 2;
	}
	std::FILE *f = std::fopen(argv[1], "rb");
	if (!f) {
		std::fprintf(stderr, "det_check: cannot open %s\n", argv[1]);
		return 2;
	}
	uint32_t nfam = 0;
	if (std::fread(&nfam, 4, 1, f) != 1) return 2;
	std::string families;
	uint64_t total = 0;
	for (uint32_t fi = 0; fi < nfam; fi++) {
		char name[25] = { 0 };
		uint32_t n = 0, arity = 0;
		if (std::fread(name, 1, 24, f) != 24 || std::fread(&n, 4, 1, f) != 1 || std::fread(&arity, 4, 1, f) != 1) return 2;
		std::vector<double> in((size_t)n * arity), expect(n);
		if (std::fread(in.data(), 8, in.size(), f) != in.size() || std::fread(expect.data(), 8, n, f) != n) return 2;
		const std::string nm(name);
		uint64_t bad = 0;
		for (uint32_t i = 0; i < n; i++) {
			const double *v = &in[(size_t)i * arity];
			double got;
			if (nm == "hypot2") got = f_hypot2(v[0], v[1]);
			else if (nm == "hypot3") got = f_hypot3(v[0], v[1], v[2]);
			else if (nm == "sin") got = f_sin(v[0]);
			else if (nm == "cos") got = f_cos(v[0]);
			else if (nm == "atan2") got = f_atan2(v[0], v[1]);
			else if (nm == "trig_special") got = v[0] == 0 ? f_sin(v[1]) : (v[0] == 1 ? f_cos(v[1]) : f_atan2(v[1], v[2]));
			else if (nm.rfind("exp", 0) == 0) got = f_exp(v[0]);
			else if (nm.rfind("pow", 0) == 0) got = f_pow(v[0], v[1]);
			else if (nm == "lowbias32") got = (double)stalag::lowbias32((uint32_t)v[0]);
			else got = f_log2(v[0]);
			if (!same(got, expect[i])) bad++;
		}
		total += n;
		char buf[160];
		std::snprintf(buf, sizeof buf, "%s{\"name\":\"%s\",\"n\":%u,\"mismatch\":%llu}", families.empty() ? "" : ",", name, n, (unsigned long long)bad);
		families += buf;
	}
	std::fclose(f);
	// every exact power of two must come back as its exact integer exponent
	int pow2_fail = 0;
	for (int k = -1074; k <= 1023; k++) {
		if (f_log2(std::ldexp(1.0, k)) != (double)k) pow2_fail++;
	}
	std::printf("{\"n_total\":%llu,\"pow2_exact_fail\":%d,\"families\":[%s]}\n", (unsigned long long)total, pow2_fail, families.c_str());
	return 0;
}
