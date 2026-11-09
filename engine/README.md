# engine/

Home of Stalag-in-Godot: the TO-voxel engine ported from the frozen three.js
prototype (`~/dev/stalag`, tag `prototype-final`, commit 8ee4d2b). Cell lattice,
world generation, chunk meshing, and character control will live here.

Read `docs/prototype-map.md` to see which prototype code is worth porting.

- `spike/` is the frozen Spec #494 engine-language benchmark (GDScript vs C++ GDExtension).
  Do not edit it; it is the record the engine choice rests on.
- `stalag/` is the real engine module (Spec #501): a C++ GDExtension (`StalagWorld`,
  `StalagChunkMesher`) that generates truncated-octahedron terrain with the prototype's base
  and caps meshes, plus the GDScript chunk streamer, kinematic walker and
  follow camera. Build it with `tools/build_engine.sh` (first run fetches godot-cpp and
  SCons; outputs under `engine/stalag/` are gitignored). Probes live in `engine/stalag/tests/`,
  committed measurement records in `engine/stalag/results/`.
  Spec #517 ("the ground") adds the whole-world water plan (`stalag_plan.*`: priority-flood
  solve, carve, the seven water-API queries), the cell-occupancy water mesher
  (`stalag_water.*`) and the world look (shaders in `engine/stalag/shaders/`, skin tiles baked
  from the frozen generators by `tools/bake_skin.mjs`). Oracle: `tools/baseline/js_world_oracle.mjs`;
  headless gate `tests/verify_stalag_plan.sh`, real-renderer gate `tests/verify_stalag_world.sh`.
  Numeric provenance (Spec #517 A2): the plan path uses no library `hypot`, `log2` or hash
  other than the first-principles `det_hypot`, `det_log2` and `lowbias32` of
  `engine/stalag/src/stalag_det.h` (built with `-ffp-contract=off`). The oracle runs the frozen
  prototype with exactly those three primitives substituted (`tools/baseline/proto_subst.mjs`);
  `tests/verify_stalag_det.sh` proves them bit-exact. Every long numeric literal is listed in
  `engine/PROVENANCE.md`. The engine world is seed 7 (a game-policy choice), the Spec #494
  spike stays on seed 42.
