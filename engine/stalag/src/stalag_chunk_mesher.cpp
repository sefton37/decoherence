#include "stalag_chunk_mesher.h"

#include "stalag_core.h"
#include "stalag_plan.h"
#include "stalag_water.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <atomic>

using namespace godot;

namespace {

std::atomic<int64_t> g_builds{ 0 };
std::atomic<int64_t> g_builds_on_main{ 0 };

void note_build() {
	g_builds++;
	OS *os = OS::get_singleton();
	if (os && os->get_thread_caller_id() == os->get_main_thread_id()) g_builds_on_main++;
}

// Appends a soup shifted by (-ox, 0, -oz). With `flip` the 2nd and 3rd vertex of every
// triangle swap: the prototype winds triangles counter-clockwise-outward (three.js) but
// Godot's front face is clockwise. Centroids and undirected edges are winding-blind, so
// the parity numbers do not depend on it; only the render path flips.
void append_soup(const stalag::Soup &s, double ox, double oz, bool flip, PackedVector3Array &v, PackedVector3Array &n, PackedColorArray &c, int64_t &at) {
	const size_t nv = s.pos.size() / 3;
	Vector3 *vw = v.ptrw();
	Vector3 *nw = n.ptrw();
	Color *cw = c.ptrw();
	for (size_t t = 0; t + 2 < nv; t += 3) {
		static const int ORDER_KEEP[3] = { 0, 1, 2 };
		static const int ORDER_FLIP[3] = { 0, 2, 1 };
		const int *ord = flip ? ORDER_FLIP : ORDER_KEEP;
		for (int k = 0; k < 3; k++, at++) {
			const size_t i = t + ord[k];
			vw[at] = Vector3((real_t)(s.pos[i * 3] - ox), s.pos[i * 3 + 1], (real_t)(s.pos[i * 3 + 2] - oz));
			nw[at] = Vector3(s.nrm[i * 3], s.nrm[i * 3 + 1], s.nrm[i * 3 + 2]);
			cw[at] = Color(s.col[i * 3], s.col[i * 3 + 1], s.col[i * 3 + 2], 1.0f);
		}
	}
}

Dictionary soup_dict(const stalag::Soup &s) {
	const int64_t nv = (int64_t)(s.pos.size() / 3);
	PackedVector3Array v, n;
	PackedColorArray c;
	v.resize(nv);
	n.resize(nv);
	c.resize(nv);
	int64_t at = 0;
	append_soup(s, 0, 0, false, v, n, c, at);
	Dictionary d;
	d["vertices"] = v;
	d["normals"] = n;
	d["colors"] = c;
	return d;
}

} // namespace

void StalagChunkMesher::_bind_methods() {
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("build_region_arrays", "x_min", "x_max", "z_min", "z_max"), &StalagChunkMesher::build_region_arrays);
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("build_chunk", "cx", "cz"), &StalagChunkMesher::build_chunk);
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("build_water_arrays", "x_min", "x_max", "z_min", "z_max"), &StalagChunkMesher::build_water_arrays);
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("get_build_stats"), &StalagChunkMesher::get_build_stats);
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("reset_build_stats"), &StalagChunkMesher::reset_build_stats);
}

Dictionary StalagChunkMesher::build_region_arrays(double p_x_min, double p_x_max, double p_z_min, double p_z_max) {
	note_build();
	stalag::SurfaceMesh sm;
	stalag::build_surface(stalag::WORLD_SEED, stalag::WORLD_EXTENT, p_x_min, p_x_max, p_z_min, p_z_max, sm, stalag::shared_plan());
	stalag::SkinnedSurface skin;
	stalag::skin_surface(sm, stalag::WORLD_SEED, stalag::shared_plan(), skin);
	Dictionary d;
	d["base"] = soup_dict(sm.base);
	d["caps"] = soup_dict(sm.caps);
	d["grass_tris"] = (int64_t)skin.grass.tris();
	d["dirt_tris"] = (int64_t)skin.dirt.tris();
	PackedInt64Array uvq;
	uvq.push_back(skin.uv_q_sum[0]);
	uvq.push_back(skin.uv_q_sum[1]);
	d["uv_q_sum"] = uvq;
	return d;
}

Dictionary StalagChunkMesher::build_water_arrays(double p_x_min, double p_x_max, double p_z_min, double p_z_max) {
	note_build();
	stalag::WaterSoup ws;
	const stalag::WaterPlan *plan = stalag::shared_plan();
	if (plan) stalag::build_occupancy_water(*plan, stalag::WORLD_SEED, p_x_min, p_x_max, p_z_min, p_z_max, ws);
	const int64_t nv = (int64_t)(ws.pos.size() / 3);
	PackedVector3Array v;
	PackedFloat32Array depth;
	PackedVector2Array flow;
	v.resize(nv);
	depth.resize(nv);
	flow.resize(nv);
	for (int64_t i = 0; i < nv; i++) {
		v[i] = Vector3(ws.pos[i * 3], ws.pos[i * 3 + 1], ws.pos[i * 3 + 2]);
		depth[i] = ws.depth[i];
		flow[i] = Vector2(ws.flow[i * 2], ws.flow[i * 2 + 1]);
	}
	Dictionary d;
	d["vertices"] = v;
	d["depth"] = depth;
	d["flow"] = flow;
	d["tris"] = (int64_t)(nv / 3);
	return d;
}

Dictionary StalagChunkMesher::build_chunk(int64_t p_cx, int64_t p_cz) {
	note_build();
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::SurfaceMesh sm;
	const stalag::WaterPlan *plan = stalag::shared_plan();
	stalag::build_surface(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, sm, plan);
	stalag::SkinnedSurface skin;
	stalag::skin_surface(sm, stalag::WORLD_SEED, plan, skin);
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	Dictionary res;
	res["mesh"] = mesh;
	PackedVector3Array all_v; // the rendered vertices of every surface, chunk-local (for rays)
	Array kinds;
	const stalag::SkinBucket *buckets[2] = { &skin.grass, &skin.dirt };
	const char *names[2] = { "grass", "dirt" };
	for (int bi = 0; bi < 2; bi++) {
		const stalag::SkinBucket &b = *buckets[bi];
		const int64_t nv = (int64_t)(b.pos.size() / 3);
		if (nv == 0) continue;
		PackedVector3Array v, n;
		PackedVector2Array uv;
		v.resize(nv);
		n.resize(nv);
		uv.resize(nv);
		Vector3 *vw = v.ptrw();
		Vector3 *nw = n.ptrw();
		Vector2 *uw = uv.ptrw();
		// Winding: the prototype is counter-clockwise-outward (three.js), Godot's front face is
		// clockwise, so the 2nd and 3rd vertex of every triangle swap.
		static const int ORD[3] = { 0, 2, 1 };
		int64_t at = 0;
		for (size_t t = 0; t + 2 < (size_t)nv; t += 3) {
			for (int k = 0; k < 3; k++, at++) {
				const size_t i = t + ORD[k];
				vw[at] = Vector3((real_t)(b.pos[i * 3] - x0), b.pos[i * 3 + 1], (real_t)(b.pos[i * 3 + 2] - z0));
				nw[at] = Vector3(b.nrm[i * 3], b.nrm[i * 3 + 1], b.nrm[i * 3 + 2]);
				uw[at] = Vector2(b.uv[i * 2], b.uv[i * 2 + 1]);
			}
		}
		Array arrays;
		arrays.resize(Mesh::ARRAY_MAX);
		arrays[Mesh::ARRAY_VERTEX] = v;
		arrays[Mesh::ARRAY_NORMAL] = n;
		arrays[Mesh::ARRAY_TEX_UV] = uv;
		mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
		kinds.push_back(String(names[bi]));
		all_v.append_array(v);
	}
	// Water: its own mesh (translucent material, no shadows), same chunk-local origin. The
	// vertex colour carries what the water shader needs: (flow x, flow z, band / 4, 1).
	stalag::WaterSoup ws;
	if (plan) stalag::build_occupancy_water(*plan, stalag::WORLD_SEED, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, ws);
	if (ws.tris() > 0) {
		const int64_t nv = (int64_t)(ws.pos.size() / 3);
		PackedVector3Array v, n;
		PackedColorArray c;
		v.resize(nv);
		n.resize(nv);
		c.resize(nv);
		static const int ORD[3] = { 0, 2, 1 };
		int64_t at = 0;
		for (int64_t t = 0; t + 2 < nv; t += 3) {
			for (int k = 0; k < 3; k++, at++) {
				const int64_t i = t + ORD[k];
				v[at] = Vector3((real_t)(ws.pos[i * 3] - x0), ws.pos[i * 3 + 1], (real_t)(ws.pos[i * 3 + 2] - z0));
				n[at] = Vector3(ws.nrm[i * 3], ws.nrm[i * 3 + 1], ws.nrm[i * 3 + 2]);
				c[at] = Color(ws.flow[i * 2] * 0.5f + 0.5f, ws.flow[i * 2 + 1] * 0.5f + 0.5f, ws.depth[i] / 4.0f, 1.0f);
			}
		}
		Array warrays;
		warrays.resize(Mesh::ARRAY_MAX);
		warrays[Mesh::ARRAY_VERTEX] = v;
		warrays[Mesh::ARRAY_NORMAL] = n;
		warrays[Mesh::ARRAY_COLOR] = c;
		Ref<ArrayMesh> wmesh;
		wmesh.instantiate();
		wmesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, warrays);
		Dictionary wd;
		wd["mesh"] = wmesh;
		wd["vertices"] = v;
		wd["tris"] = (int64_t)(nv / 3);
		res["water"] = wd;
	}
	res["vertices"] = all_v;
	res["tris"] = (int64_t)(all_v.size() / 3);
	res["surface_kinds"] = kinds; // surface index -> "grass" | "dirt" (a bucket may be empty)
	res["grass_tris"] = (int64_t)skin.grass.tris();
	res["dirt_tris"] = (int64_t)skin.dirt.tris();
	return res;
}

Dictionary StalagChunkMesher::get_build_stats() {
	Dictionary d;
	d["builds"] = (int64_t)g_builds.load();
	d["on_main_thread"] = (int64_t)g_builds_on_main.load();
	return d;
}

void StalagChunkMesher::reset_build_stats() {
	g_builds = 0;
	g_builds_on_main = 0;
}
