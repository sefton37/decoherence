# Prototype map: Stalag (three.js) to Decoherence (Godot)

Pinned to the `prototype-final` tag of `~/dev/stalag`, commit `8ee4d2b` (an annotated tag; resolve the commit with `git -C ~/dev/stalag rev-parse 'prototype-final^{commit}'`). 511 tracked files at that commit. The prototype is FROZEN and read-only; this map says which parts the port should read.

## Classes

- `canonical-reference`: read this when porting. The note marks ENGINE (goes under `engine/`) or GAME (goes under `game/`) where it applies.
- `superseded`: replaced by something named in the note; do not read for the port unless the note says a live dependency remains.
- `dead`: not used by the shipped prototype, or a recorded artefact; ignore.

A path ending `/` covers everything under it. A more specific row below a prefix row overrides it for that path (for example `explore/bot-nav-spike/nav-core.mjs` inside the superseded spike). Classifications beyond the pinned ones are judgment calls for Kel to veto.

## Port hazards

All verified against the code at `prototype-final`.

- **H1. The scale literal `SF = 0.125` is hand-copied.** It is declared separately in `src/worldmesh.js`, `src/hydrology.js`, `src/world-constants.js`, `src/character-controller.js`, `src/windfield.js`, `src/tree-placement.js`, `src/foliage-placement.js`, `src/shrub-placement.js`, `src/flower-placement.js`, plus `SF_W` in `index.html` and again in seven `explore/verb-vm` tests and drive pages. `src/world-constants.js` was an attempt at a single source but most modules never adopted it. Port with ONE definition in the Godot engine; the later Spellwright fork reached the same conclusion and centralised it in its own `to-cell.js`.
- **H2. Game policy lives inside engine code.** `src/waterplan.js` hard-codes the positions of game assets as protected discs and rectangles (`ASSET_DISCS`: spawn, reactor, the two bots, six sentinel footings, plus the bot patrol rectangle and the demo mesa) and `protectedCol` keeps water and carve away from them, throwing if a wet column lands inside one, and `src/world-constants.js` holds `HOMESTEAD_R = 70`, the radius of the uncarved build zone. The engine/game split in the port has to pull these out as parameters supplied by `game/`.
- **H3. `carveDepth` triggers the whole water-plan solve.** `src/carve.js` `carveDepth` calls into `src/rivers.js`, which solves the entire plan on first use. Measured here: the first call took about 2.4 s, the second 0.0 ms. The modules also form a legal-but-fragile import cycle (worldmesh, carve, rivers, waterplan, back to worldmesh). Terrain height depends on the plan, so a Godot port needs an explicit, schedulable plan-build step rather than a lazy first-call cost.
- **H4. Two A* copies.** `src/bot-nav.js` (production, used by `src/worker-bots.js`) and `explore/bot-nav-spike/nav-core.mjs` (used by `explore/verb-vm`, the only copy of the game loop). Pick one in the port; the verb VM was written against the spike copy.
- **H5. `index.html` is a 2,285-line composition root.** It owns the frame loop, wiring, shaders and UI. There is no module to port; reconstruct the assembly order from it.
- **H6. Not every note in the brief held.** `test/watervolume.test.mjs` passes at `prototype-final`, so the dead water mesher has no red test; it is dead because nothing in `src/` or `index.html` imports it.

## Map

| Path | Class | Note |
| ---- | ----- | ---- |
| `index.html` | canonical-reference | Composition root (2,285 lines): wires every system. Read for assembly order and per-frame ordering, do not port as a unit (hazard H5). |
| `README.md` | canonical-reference | v0 description of the BCC lattice and Kelvin cell; still accurate for the geometry. |
| `.gitignore` | dead | Stalag repo housekeeping. |
| `LANES.md` | dead | Multi-session worktree ownership registry; process doc, not product. |
| `package.json` | dead | npm script aliases for the Node/Playwright test suite; replaced by the Godot test harness. |
| `server.py` | dead | Dev static file server for the browser build. |
| `verify_cap.mjs` | superseded | Cap-fold investigation script; behaviour now covered by test/worldmesh.test.mjs. |
| `verify_cap2.mjs` | superseded | Cap-fold investigation script, second pass; see verify_cap.mjs. |
| `docs/plan-v0.3-worldmesh.md` | canonical-reference | Watertight terrain surface mesh rationale (Spec #205). |
| `docs/plan-rivers-v1.md` | canonical-reference | Rivers/streams design (Spec #281); the plan model is canonical. |
| `docs/plan-one-water.md` | canonical-reference | Rivers and brooks onto the occupancy water pipeline (Spec #318); explains why wateroccupancy exists. |
| `docs/plan-waterfall-continuity.md` | canonical-reference | Multi-terrace waterfall continuity (Spec #322); coset round/floor lesson. |
| `docs/plan-occupancy-water-wiring.md` | canonical-reference | Explains the BCC two-coset shoreline gap that wateroccupancy solves. Wiring steps name the dead watervolume.js. |
| `docs/plan-voxel-water-p1.md` | superseded | Volumetric pond body plan; its watervolume.js was replaced by wateroccupancy.js. |
| `docs/plan-water-v1.md` | superseded | Rung-1.5 ponds plan (Spec #280); replaced by the water-plan and occupancy designs. |
| `skins/` | canonical-reference | Pixel-art skin/texture generators and the art bible; index.html imports texgen, world-skin, cell-preview, trees, foliage, shrubs, wildflowers. Art reference for later slices; trees/foliage ports are out of scope for the first port. |
| `skins/voteserver.py` | dead | Local vote server used for art review sessions. |
| `skins/avatar-gallery.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/avatar-report.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/canopy.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/foliage.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/gallery.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/leaves-preview.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/shrubs.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/test-avatar.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-cell.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-cloudfield.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-foliage-ui.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-foliage.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-trees.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-ui.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-wildflowers.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-windfield.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-world-skin.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/test-world-ui.mjs` | superseded | Node/Playwright harness for the JS skin modules; re-specify in Godot rather than port. |
| `skins/trees.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/wildflowers.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `skins/world.html` | superseded | Browser preview page for the JS skin module; not portable. |
| `src/to-cell.js` | canonical-reference | ENGINE. Truncated-octahedron geometry, BCC basis, neighbour offsets, pointToCell. First file to port. |
| `src/cells.js` | canonical-reference | ENGINE. Cell material definitions (grass, dirt, water, ...). |
| `src/worldgen.js` | canonical-reference | ENGINE. Deterministic terrain height noise (hash-derived, no platform RNG). |
| `src/worldmesh.js` | canonical-reference | ENGINE. Terrain surface mesh (buildTerrainSurface), surfaceHeight, cliffLift. Holds a hand-copied SF (hazard H1). |
| `src/carve.js` | canonical-reference | ENGINE. Signed per-column carve depth (carveDepth). Triggers the water-plan solve on first call (hazard H3). |
| `src/hydrology.js` | canonical-reference | ENGINE. Priority-flood, DRY sentinel, terrace constants. Also declares a hand-copied SF (hazard H1). |
| `src/rivers.js` | canonical-reference | ENGINE. Rivers/brooks course queries over the water plan; module-cycle gateway (hazard H3). |
| `src/waterplan.js` | canonical-reference | ENGINE. Whole-world water plan solver. Contains game policy (protected-asset discs); see hazard H2. |
| `src/wateroccupancy.js` | canonical-reference | ENGINE. Cell-occupancy water mesher; the production water renderer. |
| `src/water-api.js` | canonical-reference | ENGINE. Append-only facade over the water query surface; port the contract, not the internals. |
| `src/chunk-worker.js` | canonical-reference | ENGINE. Off-thread chunk build (terrain surface + water). Maps to Godot threads or a task pool. |
| `src/character-controller.js` | canonical-reference | ENGINE. Walk/run kinematics, ground envelope, step and slope rules. Hand-copied SF (hazard H1). |
| `src/windfield.js` | canonical-reference | ENGINE. Analytic wind field, deterministic. Hand-copied SF (hazard H1). |
| `src/cloudfield.js` | canonical-reference | ENGINE. Analytic cloud cover field, written to port verbatim. |
| `src/world-constants.js` | canonical-reference | ENGINE. Single-source attempt for SF/COL/TERRACE_LAT/CHAN; also holds game constant HOMESTEAD_R (hazard H2). Imported by NO src/ module or index.html, only by tests and docs: the single source was never adopted (hazard H1). |
| `src/tree-placement.js` | canonical-reference | ENGINE. Deterministic tree placement. Hand-copied SF (hazard H1). Tree port is out of the first slice. |
| `src/foliage-placement.js` | canonical-reference | ENGINE. Deterministic foliage placement. Hand-copied SF (hazard H1). |
| `src/shrub-placement.js` | canonical-reference | ENGINE. Deterministic shrub placement. Hand-copied SF (hazard H1). |
| `src/flower-placement.js` | canonical-reference | ENGINE. Deterministic wildflower placement. Hand-copied SF (hazard H1). |
| `src/player-avatar.js` | canonical-reference | ENGINE. Chibi box-rig player avatar with swappable skin; three.js-specific construction, concept and rig layout canonical. |
| `src/homestead.js` | canonical-reference | GAME. Six-corner homestead with Sentinel posts and shield curtain. Game policy. |
| `src/reactor.js` | canonical-reference | GAME. Coronet Dynamo fusion reactor visual. Game content. |
| `src/worker-bots.js` | canonical-reference | GAME. Ostinato Mule and Noria worker bots, bot bodies and loop. Game content. |
| `src/bot-nav.js` | canonical-reference | GAME. Production grid A* + carrot follower; one of two A* copies (hazard H4). |
| `src/bot-locomotion.js` | canonical-reference | GAME. Archetype-parameterised kinematic locomotion stepper. |
| `src/perf-log.js` | superseded | Browser frame-time ring buffer and overlay; Godot has built-in monitors and profiler. |
| `src/sentinel.js` | dead | Sentinel mesh builder; no importer anywhere in the tree (homestead builds its own posts). Only prose mentions remain. |
| `src/watervolume.js` | dead | Volumetric water mesher replaced by wateroccupancy.js; imported only by its own test and explore/voxel-water/verify-production.html, never by src/ or index.html. |
| `explore/verb-vm/` | canonical-reference | GAME. The only copy of the verb VM, parser, Proxy and arbiter loop: canonical for the game loop, though porting is out of scope for the first slice. |
| `explore/bot-nav-spike/` | superseded | Navigation research spike, promoted to src/bot-nav.js. Two files inside are still live dependencies of verb-vm (see next rows, hazard H4). |
| `explore/bot-nav-spike/nav-core.mjs` | canonical-reference | Second A* copy; imported by explore/verb-vm/verbs.mjs and its drive pages (hazard H4). |
| `explore/bot-nav-spike/carrot-follower.mjs` | canonical-reference | Carrot-follower drive; imported by explore/verb-vm/verbs.mjs (hazard H4). |
| `explore/bot-physics-spike/` | superseded | Locomotion research spike, promoted to src/bot-locomotion.js. |
| `explore/leaf-rustle-proto/` | superseded | Six leaf-motion prototypes; winner shipped as LEAF_FLUTTER in index.html. |
| `explore/water-spike/` | superseded | Early water feasibility spike (Spec #279); findings absorbed into the water plan. |
| `explore/voxel-water/` | superseded | Voxel water research and screenshots; led to watervolume.js, itself replaced. |
| `explore/hydro-v2/` | superseded | Hydrology v2 design and constraints; the result is src/hydrology.js plus src/waterplan.js. |
| `explore/volumetric-water-v2/` | superseded | Volumetric water v2 research; source of src/wateroccupancy.js. |
| `explore/cap-cell.html` | superseded | One-off exploration page; conclusions live in src/. |
| `explore/scale-spike.html` | superseded | One-off exploration page; conclusions live in src/. |
| `explore/surface-compare.html` | superseded | One-off exploration page; conclusions live in src/. |
| `explore/hydrology-atlas.html` | superseded | One-off exploration page; conclusions live in src/. |
| `explore/verb-vm/shots/` | dead | Captured screenshots from past runs. |
| `explore/verb-vm/arbiter-render-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/arbiter-unit-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/editor-render-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/editor-unit-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/inspector-render-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/inspector-unit-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/living-render-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/living-unit-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/palette-render-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/palette-unit-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/pipeline-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/proxy-render-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/proxy-unit-results.json` | dead | Recorded test output artefact. |
| `explore/verb-vm/vm-unit-results.json` | dead | Recorded test output artefact. |
| `scratch/` | superseded | Throwaway attack/probe scripts, screenshots and a server log from the cap and walk investigations; their findings live in test/. |
| `test/auth_gate.test.sh` | dead | Tests the dev server auth gate. |
| `test/avatar-gallery.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/avatar-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/bot-animation.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/bot-locomotion.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/bot-nav-results.json` | dead | Recorded test output artefact. |
| `test/bot-nav.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/bot-orientation.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/bot-patrol-nav-results.json` | dead | Recorded test output artefact. |
| `test/bot-patrol-nav.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/canopy-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/carve-gravity.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/carve-guards.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/cells.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/character-controller.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/conifer-apex.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/constants-sync.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/flower-placement.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/flower-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/foliage-placement.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/foliage-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/geometry.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/homestead-fly.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/homestead-plot-removed.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/hydro-v2-init-message.test.mjs` | canonical-reference | Oracle for the PRODUCTION main -> chunk-worker Water Plan init-message contract (Spec #341 / #532); drives src/chunk-worker.js's real onmessage + waterplan.js. Name is historical, not a spike test. |
| `test/hydrology.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/import-cycle-guard.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/leaf-flutter-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/leaf-frequency-guard.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/leaves-preview.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/reactor-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/region-union.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/river-occupancy.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/rivers.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/sentinel-render.test.mjs` | dead | Render test of the dead sentinel.js. |
| `test/shrub-frequency-guard.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/shrub-gallery-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/shrub-gallery.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/shrub-placement.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/shrub-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/tree-crown-color-t2-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/tree-cull.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/tree-diversity-t1-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/tree-forest-mix.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/tree-placement-jitter.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/tree-warm-broadleaf-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/tree-warm-fence.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/trees-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/walk-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/walk-wedge.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/water-api-contract.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/water-p2-checks.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/wateroccupancy.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/waterplan.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/watervolume.test.mjs` | dead | Tests the dead watervolume.js (observed passing at prototype-final, so not a red test). |
| `test/worker-bots-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/world-render.test.mjs` | superseded | Browser render test (three.js plus Playwright); re-do as a Godot visual check. |
| `test/worldgen.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
| `test/worldmesh.test.mjs` | canonical-reference | Executable invariant for a canonical module; port as the oracle for the Godot implementation. |
