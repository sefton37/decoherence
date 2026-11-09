#ifndef STALAG_WATER_H
#define STALAG_WATER_H

// Spec #517 -- the cell-occupancy water mesher (port of wateroccupancy.js
// buildOccupancyWater / computeWaterOccupancy). Pure C++ and reentrant: it reads the
// immutable WaterPlan and carries no shared state, so chunk builds can run concurrently.

#include <cstdint>
#include <vector>

namespace stalag {

struct WaterPlan;

struct WaterSoup {
	std::vector<float> pos, nrm; // 3 floats per vertex, world metres
	std::vector<float> depth; // 1 float per vertex: band = clamp(tw - bedT, 1, 4)
	std::vector<float> flow; // 2 floats per vertex: [dx, dz] on course cells, [0,0] on ponds
	size_t tris() const { return pos.size() / 9; }
};

// Region is [x_min, x_max) x [z_min, z_max) in world metres, owner-clipped on the cell
// centre exactly like the terrain mesher, so adjacent regions partition the water.
void build_occupancy_water(const WaterPlan &plan, int32_t seed, double x_min, double x_max, double z_min, double z_max, WaterSoup &out);

} // namespace stalag

#endif // STALAG_WATER_H
