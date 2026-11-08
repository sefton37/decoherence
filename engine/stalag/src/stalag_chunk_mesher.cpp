#include "stalag_chunk_mesher.h"

#include "stalag_core.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
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
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("get_build_stats"), &StalagChunkMesher::get_build_stats);
	ClassDB::bind_static_method("StalagChunkMesher", D_METHOD("reset_build_stats"), &StalagChunkMesher::reset_build_stats);
}

Dictionary StalagChunkMesher::build_region_arrays(double p_x_min, double p_x_max, double p_z_min, double p_z_max) {
	note_build();
	stalag::SurfaceMesh sm;
	stalag::build_surface(stalag::WORLD_SEED, stalag::WORLD_EXTENT, p_x_min, p_x_max, p_z_min, p_z_max, sm);
	Dictionary d;
	d["base"] = soup_dict(sm.base);
	d["caps"] = soup_dict(sm.caps);
	return d;
}

Dictionary StalagChunkMesher::build_chunk(int64_t p_cx, int64_t p_cz) {
	note_build();
	const double x0 = (double)p_cx * stalag::CHUNK_M, z0 = (double)p_cz * stalag::CHUNK_M;
	stalag::SurfaceMesh sm;
	stalag::build_surface(stalag::WORLD_SEED, stalag::WORLD_EXTENT, x0, x0 + stalag::CHUNK_M, z0, z0 + stalag::CHUNK_M, sm);
	const int64_t nv = (int64_t)((sm.base.pos.size() + sm.caps.pos.size()) / 3);
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	Dictionary res;
	res["mesh"] = mesh;
	if (nv == 0) { // outside the footprint: an empty mesh, no surface
		res["vertices"] = PackedVector3Array();
		res["tris"] = (int64_t)0;
		return res;
	}
	PackedVector3Array v, n;
	PackedColorArray c;
	v.resize(nv);
	n.resize(nv);
	c.resize(nv);
	int64_t at = 0;
	append_soup(sm.base, x0, z0, true, v, n, c, at);
	append_soup(sm.caps, x0, z0, true, v, n, c, at);
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = v;
	arrays[Mesh::ARRAY_NORMAL] = n;
	arrays[Mesh::ARRAY_COLOR] = c;
	mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	res["vertices"] = v; // the very array handed to the renderer (chunk-local, flipped winding)
	res["tris"] = (int64_t)(nv / 3);
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
