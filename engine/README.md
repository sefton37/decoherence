# engine/

Home of Stalag-in-Godot: the TO-voxel engine ported from the frozen three.js
prototype (`~/dev/stalag`, tag `prototype-final`, commit 8ee4d2b). Cell lattice,
world generation, chunk meshing, and character control will live here.

Read `docs/prototype-map.md` to see which prototype code is worth porting.

- `spike/` is the frozen Spec #494 engine-language benchmark (GDScript vs C++ GDExtension).
  Do not edit it; it is the record the engine choice rests on.
- `stalag/` is the real engine module (Spec #501): a C++ GDExtension (`StalagWorld`,
  `StalagChunkMesher`) that generates carve-free truncated-octahedron terrain with the
  prototype's base and caps meshes, plus the GDScript chunk streamer, kinematic walker and
  follow camera. Build it with `tools/build_engine.sh` (first run fetches godot-cpp and
  SCons; outputs under `engine/stalag/` are gitignored). Probes live in `engine/stalag/tests/`,
  committed measurement records in `engine/stalag/results/`.
