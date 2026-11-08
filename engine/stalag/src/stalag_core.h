#ifndef STALAG_CORE_H
#define STALAG_CORE_H

// Spec #501 -- pure C++ core of the Stalag engine module (no Godot types).

#include <cstdint>
#include <vector>

namespace stalag {

// Lattice units -> world metres (cell diameter 0.5 m / 4 lattice). The ONE definition
// of the scale in the whole new engine tree; GDScript reads it through StalagWorld.
constexpr double SF = 0.125;

constexpr int32_t WORLD_SEED = 42; // index.html WORLD_SEED
constexpr int32_t WORLD_EXTENT = 224; // index.html default; footprint +-(4*extent*SF) = +-112 m
constexpr double CHUNK_M = 28.0; // index.html CHUNK_M

// Triangle soup: 3 floats per vertex, 9 per triangle.
struct Soup {
	std::vector<float> pos, nrm, col;
	size_t tris() const { return pos.size() / 9; }
};

struct SurfaceMesh {
	Soup base;
	Soup caps;
};

// Region is [x_min, x_max) x [z_min, z_max) in world metres (cell-centre gate).
// Reentrant: no shared mutable state.
void build_surface(int32_t seed, int32_t extent, double x_min, double x_max, double z_min, double z_max, SurfaceMesh &out);

// ---- world queries (carve-free, seed WORLD_SEED, unbounded footprint like isSolidWorld)
double surface_height_base(int32_t cx, int32_t cz, int32_t seed); // lattice units
bool is_solid_world(int32_t cx, int32_t cy, int32_t cz); // solid terrain or cap-interstitial cell
double ground_envelope_at(double fx, double fz, double max_surface); // centre-point ground height (m), -inf if none
double ground_floor(double fx, double fz, double max_surface); // footprint-sampled (max of 5 points)
bool blocked_between(double fx, double fz, double from_y, double to_y);

} // namespace stalag

#endif // STALAG_CORE_H
