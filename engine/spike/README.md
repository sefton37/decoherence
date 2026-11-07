# engine/spike -- engine-language spike (Spec #494)

A standalone nested Godot project (its own `project.godot`, so a missing built `.so`
can never break `godot --editor` on the repo root). It builds ONE chunk of
truncated-octahedron terrain, the `base` mesh of stalag `buildTerrainSurface`, two ways
and measures both against the frozen JS prototype. The spike measures; Kel picks the language.

- `gdscript/` GDScript candidate plus the shared parity checksum.
- `ext/` C++ GDExtension candidate (`src/`), `SConstruct`, `stalagspike.gdextension`.
- `runner/` the Godot scene that times builds, checks parity, samples frame time.
- `results/js-baseline.json` and `results/spike-results.json` committed records.

Reproduce (from the repo root):

    tools/setup_gdext.sh                       # scons venv + godot-cpp 4.5 + the .so (all gitignored)
    JS_BASELINE_OUT=engine/spike/results/js-baseline.json tools/baseline/js_baseline.mjs
    SPIKE_OUT=engine/spike/results/spike-results.json engine/spike/run_spike.sh

Both scripts take a region (`JS_BASELINE_REGION` / `SPIKE_REGION`, "xMin,xMax,zMin,zMax").
Only carve-free regions are valid: the port uses `surfaceHeightBase`, not `surfaceHeight`.
Parity is the base mesh only (no caps): equal triangle count and equal integer centroid
checksum. `run_spike.sh` needs `DISPLAY=:99` (the user xvfb.service) for the real Vulkan run.
