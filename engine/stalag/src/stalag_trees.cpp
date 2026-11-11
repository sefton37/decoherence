// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- C++ port of src/tree-placement.js from the frozen Stalag prototype (tag prototype-final).
// See stalag_trees.h.

#include "stalag_trees.h"

#include "stalag_core.h"
#include "stalag_det.h"
#include "stalag_plan.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <cmath>
#include <cstring>
#include <unordered_map>

namespace stalag {

const char *const TREE_FORM_IDS[NUM_TREE_FORMS] = {
	"frost-sapling", "scrub-birch", "young-spire", "boreal-fir", "broadleaf-lump", "tall-pine",
	"northwatch-larch", "twin-trunk", "elder-pine", "standing-snag", "cut-stump", "sensor-pine"
};

namespace {

constexpr double PI_ = 3.141592653589793; // Math.PI
constexpr int TERRACE_LAT = 4;
constexpr double GROVE_FREQ = 0.035;
constexpr double GROVE_MIN = 0.42;
constexpr double GROVE_MAX_DENSITY = 0.17;

// TREE_OPTIONS heightRange per form, in TREE_FORM_IDS order.
constexpr double RANGE[NUM_TREE_FORMS][2] = {
	{ 1.0, 1.6 }, { 1.5, 2.6 }, { 3.0, 4.2 }, { 4.0, 5.6 }, { 4.0, 5.2 }, { 7.0, 9.0 },
	{ 6.0, 8.0 }, { 5.0, 7.0 }, { 10.0, 12.5 }, { 4.0, 6.0 }, { 0.4, 0.7 }, { 5.0, 7.0 }
};
constexpr int FI_ELDER = 8, FI_SENSOR = 11;

// FOREST: role-weighted table [form index, weight], in the prototype's order.
constexpr int FOREST_FORM[NUM_TREE_FORMS] = { 3, 2, 6, 0, 1, 4, 7, 11, 9, 10, 5, 8 };
constexpr int FOREST_W[NUM_TREE_FORMS] = { 20, 16, 10, 12, 12, 15, 10, 3, 4, 4, 3, 1 };
constexpr int WSUM = 110;

std::atomic<int> g_mut{ 0 };
std::atomic<int64_t> g_builds{ 0 };
std::atomic<int64_t> g_builds_on_main{ 0 };
std::atomic<bool> g_enabled{ true };

inline int32_t xor_i32(int32_t a, uint32_t b) { return (int32_t)((uint32_t)a ^ b); }

inline double hTat(int32_t cx, int32_t cz, int32_t seed, const WaterPlan *plan) {
	return std::floor(surface_height(cx, cz, seed, plan) / TERRACE_LAT) * TERRACE_LAT;
}

int pick_form(double r) {
	double a = r * WSUM;
	for (int i = 0; i < NUM_TREE_FORMS; i++) {
		a -= FOREST_W[i];
		if (a < 0) return FOREST_FORM[i];
	}
	return FOREST_FORM[0];
}

// hsv2rgb of index.html (h in degrees).
void hsv2rgb(double h, double s, double v, double out[3]) {
	h = std::fmod(std::fmod(h, 360.0) + 360.0, 360.0);
	const double c = v * s, x = c * (1 - std::fabs(std::fmod(h / 60, 2.0) - 1)), m = v - c;
	double r, g, b;
	if (h < 60) { r = c; g = x; b = 0; }
	else if (h < 120) { r = x; g = c; b = 0; }
	else if (h < 180) { r = 0; g = c; b = x; }
	else if (h < 240) { r = 0; g = x; b = c; }
	else if (h < 300) { r = x; g = 0; b = c; }
	else { r = c; g = 0; b = x; }
	out[0] = r + m;
	out[1] = g + m;
	out[2] = b + m;
}

} // namespace

void set_tree_mutation(int m) { g_mut.store(m); }
int tree_mutation() { return g_mut.load(); }

void list_lids_region(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, std::vector<Lid> &out, bool lid_shift) {
	out.clear();
	const WaterPlan *plan = shared_plan();
	if (!plan) return;
	const double floor_half = 4 * extent * SF;
	auto in_foot = [&](double x, double z) { return std::fabs(x * SF) <= floor_half + 1e-9 && std::fabs(z * SF) <= floor_half + 1e-9; };
	const bool all_z = !(z_min > -1e8 && z_max < 1e8);
	const bool all_x = !(x_min > -1e8 && x_max < 1e8);
	int32_t k_lo = -2 * extent, k_hi = 2 * extent;
	if (!all_z) {
		k_lo = std::max(k_lo, (int32_t)std::floor((z_min / SF - 2) / 2) - 1);
		k_hi = std::min(k_hi, (int32_t)std::ceil((z_max / SF - 2) / 2) + 1);
	}
	if (((k_lo % 2) + 2) % 2 != 0) k_lo++;
	static const int D_REAL[4][2] = { { 4, 0 }, { 0, 4 }, { 4, 4 }, { 2, 2 } };
	static const int D_SHIFT[4][2] = { { 4, 0 }, { 0, 4 }, { 4, 4 }, { 2, 3 } };
	const int(*D)[2] = lid_shift ? D_SHIFT : D_REAL;
	for (int32_t k = k_lo; k <= k_hi; k += 2) {
		const int32_t cz = 2 * k;
		const double wz = (cz + 2) * SF;
		if (!all_z && !(wz >= z_min && wz < z_max)) continue;
		int32_t i_lo = -2 * extent, i_hi = 2 * extent;
		if (!all_x) {
			i_lo = std::max(i_lo, (int32_t)std::floor((x_min / SF - 2 - 2 * k) / 4) - 1);
			i_hi = std::min(i_hi, (int32_t)std::ceil((x_max / SF - 2 - 2 * k) / 4) + 1);
		}
		for (int32_t i = i_lo; i <= i_hi; i++) {
			const int32_t cx = 4 * i + 2 * k;
			const double wx = (cx + 2) * SF;
			if (!all_x && !(wx >= x_min && wx < x_max)) continue;
			if (!in_foot(cx, cz)) continue;
			const double H = hTat(cx, cz, seed, plan);
			bool ok = true;
			for (int d = 0; d < 4; d++) {
				if (!in_foot(cx + D[d][0], cz + D[d][1]) || hTat(cx + D[d][0], cz + D[d][1], seed, plan) != H) {
					ok = false;
					break;
				}
			}
			if (ok) out.push_back(Lid{ cx, cz, H });
		}
	}
}

void place_trees_region(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, std::vector<TreeInstance> out[NUM_TREE_FORMS]) {
	for (int f = 0; f < NUM_TREE_FORMS; f++) out[f].clear();
	const WaterPlan *plan = shared_plan();
	if (!plan) return;
	const int mut = g_mut.load();
	std::vector<Lid> lids;
	list_lids_region(seed, extent, x_min, x_max, z_min, z_max, lids, mut == 1);
	const int salt_form = mut == 4 ? 702 : 701; // salt_swap: the form pick and the height trade salts
	const int salt_height = mut == 4 ? 701 : 702;
	for (const Lid &lid : lids) {
		const int32_t cx = lid.cx, cz = lid.cz;
		// lid_shift: the shifted lid test (list_lids_region) AND the lid centre moved one lattice step in x,
		// so the roots themselves leave the lid grid (the nearest root to the origin moves too)
		const double wx = (cx + (mut == 1 ? 3 : 2)) * SF, wz = (cz + 2) * SF;
		const double base_y = (lid.H + 2) * SF;
		if (mut != 3 && det_hypot(wx, wz) < SPAWN_CLEARING) continue;
		const int32_t gx = (int32_t)std::floor(wx / 0.5), gz = (int32_t)std::floor(wz / 0.5);
		if (mut != 2 && (is_flooded(*plan, gx, gz) || course_level_at(*plan, gx, gz) != WATER_DRY)) continue;
		const double grove = noise_value(wx * GROVE_FREQ + 11, wz * GROVE_FREQ + 5, xor_i32(seed, 0x7a5c19u));
		double density;
		if (mut == 5) {
			density = GROVE_MAX_DENSITY * 0.5; // grove_off: no stands, no clearings
		} else {
			if (grove < GROVE_MIN) continue;
			density = GROVE_MAX_DENSITY * ((grove - GROVE_MIN) / (1 - GROVE_MIN));
		}
		if (hash_cell(cx, 700, cz, seed) >= density) continue;

		const int form = pick_form(hash_cell(cx, salt_form, cz, seed));
		const double lo = RANGE[form][0], hi = RANGE[form][1];
		const double height = lo + hash_cell(cx, salt_height, cz, seed) * (hi - lo);
		const double yaw = hash_cell(cx, 703, cz, seed) * PI_ * 2;
		const double jx = (hash_cell(cx, 704, cz, seed) - 0.5) * 0.3;
		const double jz = (hash_cell(cx, 705, cz, seed) - 0.5) * 0.3;
		const double w_jit = 0.85 + hash_cell(cx, 706, cz, seed) * 0.30;
		const double h_jit = 0.90 + hash_cell(cx, 707, cz, seed) * 0.22;
		const bool landmark = form == FI_ELDER || form == FI_SENSOR;
		const double lean_mag = (landmark && mut != 6) ? 0.0 : hash_cell(cx, 708, cz, seed) * 0.0698;
		const double lean_ang = hash_cell(cx, 709, cz, seed) * PI_ * 2;
		const double lean_x = det_cos(lean_ang) * lean_mag, lean_z = det_sin(lean_ang) * lean_mag;
		const double val_jit = 0.92 + hash_cell(cx, 710, cz, seed) * 0.16;
		const double hue_jit = (landmark && mut == 7) ? 0.0 : (hash_cell(cx, 711, cz, seed) - 0.5) * 8;
		const double nominal = (lo + hi) / 2;
		out[form].push_back(TreeInstance{ wx + jx, base_y, wz + jz, yaw, height / nominal, height, w_jit, h_jit, lean_x, lean_z, val_jit, hue_jit, wx, wz });
	}
}

void tree_matrix(const TreeInstance &t, double x0, double z0, float out[12]) {
	// Object3D: rotation.set(leanX, yaw, leanZ) in order XYZ -> quaternion.setFromEuler -> Matrix4.compose.
	const double c1 = det_cos(t.lean_x / 2), c2 = det_cos(t.yaw / 2), c3 = det_cos(t.lean_z / 2);
	const double s1 = det_sin(t.lean_x / 2), s2 = det_sin(t.yaw / 2), s3 = det_sin(t.lean_z / 2);
	double qx, qy, qz, qw;
	if (g_mut.load() == 8) { // euler_order: order ZYX instead of XYZ
		qx = s1 * c2 * c3 - c1 * s2 * s3;
		qy = c1 * s2 * c3 + s1 * c2 * s3;
		qz = c1 * c2 * s3 - s1 * s2 * c3;
		qw = c1 * c2 * c3 + s1 * s2 * s3;
	} else {
		qx = s1 * c2 * c3 + c1 * s2 * s3;
		qy = c1 * s2 * c3 - s1 * c2 * s3;
		qz = c1 * c2 * s3 + s1 * s2 * c3;
		qw = c1 * c2 * c3 - s1 * s2 * s3;
	}
	const double sx = t.scale * t.w_jit, sy = t.scale * t.h_jit, sz = t.scale * t.w_jit;
	const double x2 = qx + qx, y2 = qy + qy, z2 = qz + qz;
	const double xx = qx * x2, xy = qx * y2, xz = qx * z2;
	const double yy = qy * y2, yz = qy * z2, zz = qz * z2;
	const double wx = qw * x2, wy = qw * y2, wz = qw * z2;
	// column-major te[] of Matrix4.compose, written out row by row for the MultiMesh buffer
	const double te0 = (1 - (yy + zz)) * sx, te1 = (xy + wz) * sx, te2 = (xz - wy) * sx;
	const double te4 = (xy - wz) * sy, te5 = (1 - (xx + zz)) * sy, te6 = (yz + wx) * sy;
	const double te8 = (xz + wy) * sz, te9 = (yz - wx) * sz, te10 = (1 - (xx + yy)) * sz;
	out[0] = (float)te0; out[1] = (float)te4; out[2] = (float)te8; out[3] = (float)(t.x - x0);
	out[4] = (float)te1; out[5] = (float)te5; out[6] = (float)te9; out[7] = (float)t.y;
	out[8] = (float)te2; out[9] = (float)te6; out[10] = (float)te10; out[11] = (float)(t.z - z0);
}

void tree_crown_color(const TreeInstance &t, float out[3]) {
	double c[3];
	hsv2rgb(128 + t.hue_jit, 0.22, 1, c);
	out[0] = (float)(c[0] * t.val_jit);
	out[1] = (float)(c[1] * t.val_jit);
	out[2] = (float)(c[2] * t.val_jit);
}

} // namespace stalag

namespace godot {

void StalagTrees::_bind_methods() {
	ClassDB::bind_static_method("StalagTrees", D_METHOD("get_build_stats"), &StalagTrees::get_build_stats);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("reset_build_stats"), &StalagTrees::reset_build_stats);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("form_ids"), &StalagTrees::form_ids);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("place_global"), &StalagTrees::place_global);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("place_chunk", "cx", "cz"), &StalagTrees::place_chunk);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("matrices_chunk", "cx", "cz"), &StalagTrees::matrices_chunk);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("colors_chunk", "cx", "cz"), &StalagTrees::colors_chunk);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("build_chunk_trees", "cx", "cz"), &StalagTrees::build_chunk_trees);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("set_mutation", "name"), &StalagTrees::set_mutation);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("set_enabled", "on"), &StalagTrees::set_enabled);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("decode_arrays", "blob", "offset", "verts", "layout"), &StalagTrees::decode_arrays);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("flatten_arrays", "arrays", "layout"), &StalagTrees::flatten_arrays);
	ClassDB::bind_static_method("StalagTrees", D_METHOD("index_arrays", "arrays"), &StalagTrees::index_arrays);
}

PackedStringArray StalagTrees::form_ids() {
	PackedStringArray a;
	for (int f = 0; f < stalag::NUM_TREE_FORMS; f++) a.push_back(String(stalag::TREE_FORM_IDS[f]));
	return a;
}

static Dictionary pack_f64(const std::vector<stalag::TreeInstance> out[stalag::NUM_TREE_FORMS]) {
	Dictionary d;
	for (int f = 0; f < stalag::NUM_TREE_FORMS; f++) {
		PackedFloat64Array a;
		a.resize((int64_t)out[f].size() * 14);
		int64_t at = 0;
		for (const stalag::TreeInstance &t : out[f]) {
			const double v[14] = { t.x, t.y, t.z, t.yaw, t.scale, t.height, t.w_jit, t.h_jit, t.lean_x, t.lean_z, t.val_jit, t.hue_jit, t.lid_x, t.lid_z };
			for (int j = 0; j < 14; j++) a[at++] = v[j];
		}
		d[String(stalag::TREE_FORM_IDS[f])] = a;
	}
	return d;
}

Dictionary StalagTrees::place_global() {
	std::vector<stalag::TreeInstance> out[stalag::NUM_TREE_FORMS];
	stalag::place_trees_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, -1e9, 1e9, -1e9, 1e9, out);
	return pack_f64(out);
}

Dictionary StalagTrees::place_chunk(int64_t p_cx, int64_t p_cz) {
	std::vector<stalag::TreeInstance> out[stalag::NUM_TREE_FORMS];
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::place_trees_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, out);
	return pack_f64(out);
}

Dictionary StalagTrees::matrices_chunk(int64_t p_cx, int64_t p_cz) {
	std::vector<stalag::TreeInstance> out[stalag::NUM_TREE_FORMS];
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::place_trees_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, out);
	Dictionary d;
	for (int f = 0; f < stalag::NUM_TREE_FORMS; f++) {
		PackedFloat32Array buf;
		buf.resize((int64_t)out[f].size() * 12);
		float *w = buf.ptrw();
		for (const stalag::TreeInstance &t : out[f]) {
			stalag::tree_matrix(t, x0, z0, w);
			w += 12;
		}
		d[String(stalag::TREE_FORM_IDS[f])] = buf;
	}
	return d;
}

Dictionary StalagTrees::colors_chunk(int64_t p_cx, int64_t p_cz) {
	std::vector<stalag::TreeInstance> out[stalag::NUM_TREE_FORMS];
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::place_trees_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, out);
	Dictionary d;
	for (int f = 0; f < stalag::NUM_TREE_FORMS; f++) {
		PackedFloat32Array buf;
		if (f != 9 && f != 10) { // the two dead forms carry no crown
			buf.resize((int64_t)out[f].size() * 3);
			float *w = buf.ptrw();
			for (const stalag::TreeInstance &t : out[f]) {
				stalag::tree_crown_color(t, w);
				w += 3;
			}
		}
		d[String(stalag::TREE_FORM_IDS[f])] = buf;
	}
	return d;
}

Dictionary StalagTrees::get_build_stats() {
	Dictionary d;
	d["builds"] = (int64_t)stalag::g_builds.load();
	d["on_main_thread"] = (int64_t)stalag::g_builds_on_main.load();
	return d;
}

void StalagTrees::reset_build_stats() {
	stalag::g_builds = 0;
	stalag::g_builds_on_main = 0;
}

void StalagTrees::set_enabled(bool p_on) { stalag::g_enabled.store(p_on); }

Dictionary StalagTrees::build_chunk_trees(int64_t p_cx, int64_t p_cz) {
	if (!stalag::g_enabled.load()) return Dictionary();
	stalag::g_builds++;
	OS *os = OS::get_singleton();
	if (os && os->get_thread_caller_id() == os->get_main_thread_id()) stalag::g_builds_on_main++;
	std::vector<stalag::TreeInstance> out[stalag::NUM_TREE_FORMS];
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::place_trees_region(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, out);
	Dictionary res;
	for (int f = 0; f < stalag::NUM_TREE_FORMS; f++) {
		if (out[f].empty()) continue;
		PackedFloat32Array mat, col;
		mat.resize((int64_t)out[f].size() * 12);
		float *w = mat.ptrw();
		for (const stalag::TreeInstance &t : out[f]) {
			stalag::tree_matrix(t, x0, z0, w);
			w += 12;
		}
		Dictionary e;
		if (f != 9 && f != 10) {
			// living forms: the crown MultiMesh also carries the per-instance colour (16 floats per
			// instance: the 12 of the transform, then r, g, b, 1)
			col.resize((int64_t)out[f].size() * 16);
			float *c = col.ptrw();
			const float *m = mat.ptr();
			for (const stalag::TreeInstance &t : out[f]) {
				for (int j = 0; j < 12; j++) c[j] = m[j];
				stalag::tree_crown_color(t, c + 12);
				c[15] = 1.0f;
				c += 16;
				m += 12;
			}
			e["crown_buffer"] = col;
		}
		e["count"] = (int64_t)out[f].size();
		e["buffer"] = mat;
		res[String(stalag::TREE_FORM_IDS[f])] = e;
	}
	return res;
}

void StalagTrees::set_mutation(const String &p_name) {
	int m = 0;
	if (p_name == "lid_shift") m = 1;
	else if (p_name == "flood_ignore") m = 2;
	else if (p_name == "clearing_off") m = 3;
	else if (p_name == "salt_swap") m = 4;
	else if (p_name == "grove_off") m = 5;
	else if (p_name == "landmark_lean") m = 6;
	else if (p_name == "hue_exempt") m = 7;
	else if (p_name == "euler_order") m = 8;
	stalag::set_tree_mutation(m);
}

} // namespace godot

namespace godot {

static int layout_floats(const String &p_layout) {
	if (p_layout == "trunk") return 9;
	if (p_layout == "crown") return 16;
	if (p_layout == "shadow") return 3;
	return 0;
}

// triangle t's vertices (a, b, c) are stored as (a, c, b): the winding swap
static inline int64_t swapped(int64_t i) {
	const int64_t r = i % 3;
	return r == 0 ? i : (r == 1 ? i + 1 : i - 1);
}

Array StalagTrees::decode_arrays(const PackedByteArray &p_blob, int64_t p_offset, int64_t p_verts, const String &p_layout) {
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	const int fpv = layout_floats(p_layout);
	if (fpv == 0 || p_verts <= 0 || p_verts % 3 != 0 || p_offset < 0 || p_offset + p_verts * fpv * 4 > p_blob.size()) return arrays;
	const float *src = reinterpret_cast<const float *>(p_blob.ptr() + p_offset);
	PackedVector3Array pos;
	pos.resize(p_verts);
	for (int64_t i = 0; i < p_verts; i++) {
		const float *f = src + swapped(i) * fpv;
		pos[i] = Vector3(f[0], f[1], f[2]);
	}
	arrays[Mesh::ARRAY_VERTEX] = pos;
	if (fpv >= 9) {
		PackedVector3Array nrm;
		PackedColorArray col;
		nrm.resize(p_verts);
		col.resize(p_verts);
		for (int64_t i = 0; i < p_verts; i++) {
			const float *f = src + swapped(i) * fpv;
			nrm[i] = Vector3(f[3], f[4], f[5]);
			col[i] = Color(f[6], f[7], f[8], 1.0f);
		}
		arrays[Mesh::ARRAY_NORMAL] = nrm;
		arrays[Mesh::ARRAY_COLOR] = col;
	}
	if (fpv == 16) {
		PackedVector2Array uv, clu;
		PackedFloat32Array custom;
		uv.resize(p_verts);
		clu.resize(p_verts);
		custom.resize(p_verts * 4);
		for (int64_t i = 0; i < p_verts; i++) {
			const float *f = src + swapped(i) * fpv;
			uv[i] = Vector2(f[9], f[10]);
			clu[i] = Vector2(f[13], f[14]);
			custom[i * 4 + 0] = f[11]; // heightFrac
			custom[i * 4 + 1] = f[12]; // exposure
			custom[i * 4 + 2] = f[15]; // the cell's own y
			custom[i * 4 + 3] = 0.0f;
		}
		arrays[Mesh::ARRAY_TEX_UV] = uv;
		arrays[Mesh::ARRAY_TEX_UV2] = clu;
		arrays[Mesh::ARRAY_CUSTOM0] = custom;
	}
	return arrays;
}

PackedFloat32Array StalagTrees::flatten_arrays(const Array &p_arrays, const String &p_layout) {
	PackedFloat32Array out;
	const int fpv = layout_floats(p_layout);
	if (fpv == 0 || p_arrays.size() < Mesh::ARRAY_MAX) return out;
	const PackedVector3Array pos = p_arrays[Mesh::ARRAY_VERTEX];
	const int64_t n = pos.size();
	out.resize(n * fpv);
	PackedVector3Array nrm;
	PackedColorArray col;
	PackedVector2Array uv, clu;
	PackedFloat32Array custom;
	if (fpv >= 9) {
		nrm = p_arrays[Mesh::ARRAY_NORMAL];
		col = p_arrays[Mesh::ARRAY_COLOR];
	}
	if (fpv == 16) {
		uv = p_arrays[Mesh::ARRAY_TEX_UV];
		clu = p_arrays[Mesh::ARRAY_TEX_UV2];
		custom = p_arrays[Mesh::ARRAY_CUSTOM0];
	}
	float *w = out.ptrw();
	for (int64_t i = 0; i < n; i++) {
		const int64_t s = swapped(i); // back to the baked order
		float *d = w + s * fpv;
		d[0] = pos[i].x; d[1] = pos[i].y; d[2] = pos[i].z;
		if (fpv >= 9) {
			d[3] = nrm[i].x; d[4] = nrm[i].y; d[5] = nrm[i].z;
			d[6] = col[i].r; d[7] = col[i].g; d[8] = col[i].b;
		}
		if (fpv == 16) {
			d[9] = uv[i].x; d[10] = uv[i].y;
			d[11] = custom[i * 4 + 0]; d[12] = custom[i * 4 + 1];
			d[13] = clu[i].x; d[14] = clu[i].y;
			d[15] = custom[i * 4 + 2];
		}
	}
	return out;
}

namespace {
// One vertex's attributes as raw floats (position3, normal3, colour4, uv2, uv2, custom4 = 19 at most).
struct VertexKey {
	float f[19];
	int n;
	bool operator==(const VertexKey &o) const { return n == o.n && std::memcmp(f, o.f, sizeof(float) * n) == 0; }
};
struct VertexKeyHash {
	size_t operator()(const VertexKey &k) const {
		uint64_t h = 14695981039346656037ULL; // FNV-1a over the bytes
		const unsigned char *b = reinterpret_cast<const unsigned char *>(k.f);
		for (size_t i = 0; i < sizeof(float) * k.n; i++) {
			h ^= b[i];
			h *= 1099511628211ULL;
		}
		return static_cast<size_t>(h);
	}
};
} // namespace

Array StalagTrees::index_arrays(const Array &p_arrays) {
	Array out;
	out.resize(Mesh::ARRAY_MAX);
	if (p_arrays.size() < Mesh::ARRAY_MAX) return out;
	const PackedVector3Array pos = p_arrays[Mesh::ARRAY_VERTEX];
	const int64_t n = pos.size();
	if (n == 0 || n % 3 != 0) return out;
	PackedVector3Array nrm = p_arrays[Mesh::ARRAY_NORMAL];
	PackedColorArray col = p_arrays[Mesh::ARRAY_COLOR];
	PackedVector2Array uv = p_arrays[Mesh::ARRAY_TEX_UV];
	PackedVector2Array clu = p_arrays[Mesh::ARRAY_TEX_UV2];
	PackedFloat32Array custom = p_arrays[Mesh::ARRAY_CUSTOM0];
	const bool has_n = nrm.size() == n, has_c = col.size() == n, has_uv = uv.size() == n, has_u2 = clu.size() == n, has_cu = custom.size() == n * 4;

	std::unordered_map<VertexKey, int32_t, VertexKeyHash> seen;
	seen.reserve(static_cast<size_t>(n));
	PackedInt32Array index;
	index.resize(n);
	std::vector<int64_t> first; // source vertex of each merged vertex
	first.reserve(static_cast<size_t>(n));
	for (int64_t i = 0; i < n; i++) {
		VertexKey k;
		k.n = 0;
		k.f[k.n++] = pos[i].x; k.f[k.n++] = pos[i].y; k.f[k.n++] = pos[i].z;
		if (has_n) { k.f[k.n++] = nrm[i].x; k.f[k.n++] = nrm[i].y; k.f[k.n++] = nrm[i].z; }
		if (has_c) { k.f[k.n++] = col[i].r; k.f[k.n++] = col[i].g; k.f[k.n++] = col[i].b; k.f[k.n++] = col[i].a; }
		if (has_uv) { k.f[k.n++] = uv[i].x; k.f[k.n++] = uv[i].y; }
		if (has_u2) { k.f[k.n++] = clu[i].x; k.f[k.n++] = clu[i].y; }
		if (has_cu) { for (int c = 0; c < 4; c++) k.f[k.n++] = custom[i * 4 + c]; }
		auto it = seen.find(k);
		if (it == seen.end()) {
			const int32_t id = static_cast<int32_t>(first.size());
			seen.emplace(k, id);
			first.push_back(i);
			index.set(i, id);
		} else {
			index.set(i, it->second);
		}
	}
	const int64_t m = static_cast<int64_t>(first.size());
	PackedVector3Array opos;
	opos.resize(m);
	PackedVector3Array onrm;
	PackedColorArray ocol;
	PackedVector2Array ouv, oclu;
	PackedFloat32Array ocustom;
	if (has_n) onrm.resize(m);
	if (has_c) ocol.resize(m);
	if (has_uv) ouv.resize(m);
	if (has_u2) oclu.resize(m);
	if (has_cu) ocustom.resize(m * 4);
	for (int64_t j = 0; j < m; j++) {
		const int64_t i = first[static_cast<size_t>(j)];
		opos.set(j, pos[i]);
		if (has_n) onrm.set(j, nrm[i]);
		if (has_c) ocol.set(j, col[i]);
		if (has_uv) ouv.set(j, uv[i]);
		if (has_u2) oclu.set(j, clu[i]);
		if (has_cu) for (int c = 0; c < 4; c++) ocustom.set(j * 4 + c, custom[i * 4 + c]);
	}
	out[Mesh::ARRAY_VERTEX] = opos;
	if (has_n) out[Mesh::ARRAY_NORMAL] = onrm;
	if (has_c) out[Mesh::ARRAY_COLOR] = ocol;
	if (has_uv) out[Mesh::ARRAY_TEX_UV] = ouv;
	if (has_u2) out[Mesh::ARRAY_TEX_UV2] = oclu;
	if (has_cu) out[Mesh::ARRAY_CUSTOM0] = ocustom;
	out[Mesh::ARRAY_INDEX] = index;
	return out;
}

} // namespace godot
