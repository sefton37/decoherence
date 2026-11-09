#ifndef STALAG_TO_CELL_H
#define STALAG_TO_CELL_H

// Spec #501/#517 -- the truncated-octahedron (TO) cell tables of the prototype's to-cell.js
// (VERTICES, faces, NEIGHBOR_OFFSETS), defined once and shared by the terrain mesher and
// the water mesher. Face index == NEIGHBOR_OFFSETS index; 6 squares then 8 hexagons.

namespace stalag {

inline constexpr int TO_VERTICES[24][3] = {
	{ -2, -1, 0 }, { -2, 0, -1 }, { -2, 0, 1 }, { -2, 1, 0 },
	{ -1, -2, 0 }, { -1, 0, -2 }, { -1, 0, 2 }, { -1, 2, 0 },
	{ 0, -2, -1 }, { 0, -2, 1 }, { 0, -1, -2 }, { 0, -1, 2 },
	{ 0, 1, -2 }, { 0, 1, 2 }, { 0, 2, -1 }, { 0, 2, 1 },
	{ 1, -2, 0 }, { 1, 0, -2 }, { 1, 0, 2 }, { 1, 2, 0 },
	{ 2, -1, 0 }, { 2, 0, -1 }, { 2, 0, 1 }, { 2, 1, 0 }
};

// 14 faces: 6 squares (4 verts) then 8 hexagons (6 verts); index == NEIGHBOR_OFFSETS index.
inline constexpr int TO_FACE_LEN[14] = { 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 6, 6 };
inline constexpr int TO_FACES[14][6] = {
	{ 22, 20, 21, 23, -1, -1 }, { 1, 0, 2, 3, -1, -1 }, { 14, 7, 15, 19, -1, -1 },
	{ 9, 4, 8, 16, -1, -1 }, { 13, 6, 11, 18, -1, -1 }, { 10, 5, 12, 17, -1, -1 },
	{ 19, 15, 13, 18, 22, 23 }, { 21, 17, 12, 14, 19, 23 }, { 18, 11, 9, 16, 20, 22 },
	{ 20, 16, 8, 10, 17, 21 }, { 7, 3, 2, 6, 13, 15 }, { 12, 5, 1, 3, 7, 14 },
	{ 6, 2, 0, 4, 9, 11 }, { 8, 4, 0, 1, 5, 10 }
};

inline constexpr int TO_NEIGHBOR_OFFSETS[14][3] = {
	{ 4, 0, 0 }, { -4, 0, 0 }, { 0, 4, 0 }, { 0, -4, 0 }, { 0, 0, 4 }, { 0, 0, -4 },
	{ 2, 2, 2 }, { 2, 2, -2 }, { 2, -2, 2 }, { 2, -2, -2 },
	{ -2, 2, 2 }, { -2, 2, -2 }, { -2, -2, 2 }, { -2, -2, -2 }
};


} // namespace stalag

#endif // STALAG_TO_CELL_H
