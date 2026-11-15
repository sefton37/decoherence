# Horizon: Minecraft-scale view distance (Spec 582, slice S1)

The `horizon` view level draws real terrain, forest and water out to about 840 m under the `amber` look (the owner's pick; the `clear` look is a preset and the one the probes measure) and a
light haze. It is the default level of the game (the player setting `view_distance`, schema default `horizon`); the
world scene's own default stays `near`, so every probe and the Spec 580 baselines read what they always read. S1 touches
no engine code and does not grow the world: the world is still the 224 m footprint and its terrain is still under 8 m of
relief, so far away the view is a forested rolling plain (mountains are S2, room to walk toward them S3).

Files: `game/world/atmosphere.gd` with `game/world/data/atmosphere.json` and `game/world/sky_clear.gdshader` (the
presets), `game/world/far_terrain.gd` with `game/world/far_terrain.gdshader` (the far terrain), the `horizon` line of
`VIEW_LEVELS` in `game/world/world_scene.gd`, and the probe `tools/measure_horizon.sh`.

## Atmosphere presets

`game/world/data/atmosphere.json` holds three presets as data; `atmosphere.gd` writes one into the world's sun, ambient
light and sky and returns the haze colours, which the world scene pushes to every shader that carries fog.

| preset | what it is | sun | fog density | sky |
| ------ | ---------- | --- | ----------- | --- |
| `classic` | the world as it always was: it writes back the values the scene and the engine sky shader already carry | the scene's own direction | the level's own | engine gradient, no clouds |
| `clear` | daylight, clear air, a light haze | 50 degrees up, energy 1.25 | 0.0014 (half opacity at about 595 m) | a deeper blue, clouds from `sky_clear.gdshader` |
| `amber` | a frozen copy of the low golden sun picked on the 2026-11-14 contact sheet | 16 degrees up, colour (1, 0.68, 0.34), energy 2.6 | 0.005 | the mesa-sidelight sky, no clouds |

The world property `atmosphere` (default `classic`) with `atmosphere_from_level` true means "the look the view level
asks for": `horizon` asks for `amber`, every other level for `classic`. Any other value of `atmosphere` is a deliberate
choice and always wins. A player-facing choice of preset is not part of S1. `fog.ground_haze` is the colour the far
terrain fades to: about a tenth darker than the sky's horizon colour, which is how distant ground reads in clear air and
is what keeps the far ground from being exactly the sky's colour (so a hole in it is measurable). The sky holds its
horizon colour from the horizon line down, so the fogged far ground and the sky meet in nearly one colour.

## Far terrain levels

The far terrain is a camera-centred pyramid of heightfield tiles. Heights are `StalagWorld.surface_height`, the engine's
bound height function (0.16 microseconds a call, carved, so lakes and rivers inside the water plan's domain are right);
the builder never calls `ground_envelope_at` (240 times dearer, the rendered surface), which only the probe uses as
truth. Beyond the plan's +-224 m the engine returns the plain terrain, so the far tiles take whatever the engine returns:
S2's mountains show up in them without touching this code.

| level | cell | tile | window (half side around the focus chunk) | seam skirt |
| ----- | ---- | ---- | ------------------------------------------ | ---------- |
| l1 | 2 m | one chunk (28 m) | out to 154 m (the loaded ring ends at 98 m at `horizon`) | 1 m |
| l2 | 4 m | 112 m | out to 336 m | 2 m |
| l3 | 16 m | 448 m | out to 840 m | 6 m |

A level draws only inside its own window and outside the finer level's window (the shader discards the rest), so levels
meet on one line and never overlap; the first level is hidden exactly where the streamer has the chunk loaded. Beyond the
last window a flat skirt under the world, painted with the far haze, runs to the camera's far plane (200 km while the far
terrain is on), so ground goes on to the horizon instead of ending in a band of sky. The outer fifth of the last window
fades into that haze by Chebyshev distance from the focus, so the last tile and the skirt are one colour.

Trees: the real placements (`StalagTrees.place_chunk`) of every footprint chunk, drawn as upright billboards with the
real species colours, shown while that chunk's own trees are not attached; hashed impostors outside the footprint to
560 m (an integer hash of the cell, no noise and no random numbers); cluster billboards from 560 to 960 m. About 47,000
instances in all. Tiles and tree tiles are computed on worker threads; the main thread only turns finished arrays into
meshes, one per frame, and only while the streamer has nothing pending (a mesh upload that lands in the same frames as a
chunk's several megabytes can stall for milliseconds). No collision, no clock, no loaded image.

## Budgets

Measured by `tools/measure_horizon.sh` on the xvfb display (one RTX-class card, shared with the model server), five
poses, `horizon` and `clear`. The bars are in `tools/scenic/horizon_bars.json`.

| budget | bar | measured |
| ------ | --- | -------- |
| primitives in a frame | at most 18 M | 6.2 M at the pad pose, 0.06 to 0.16 M at the three edge poses, 4.2 M at eye height |
| draw calls | at most 900 | 486 at the pad pose, under 100 at the edge poses, 274 at eye height |
| video memory | at most 1,250 MB | 835 MB at the pad pose, 643 to 747 MB at the others (`vista` holds 1,090 MB, `near` 430 to 530 MB) |
| loaded chunks | at most 64 per pose | 40 to 49 (the ring is 49 chunks; each pose enters on a fresh world) |
| far terrain triangles | at most 1.5 M | 0.32 M built (terrain tiles only; the tree impostors add two triangles each) |
| main-thread step of the far terrain | 99th percentile at most 5 ms, longest at most 15 ms | first world: 99th percentile 0.3 ms, longest 2.8 to 3.1 ms; adoption 0.4 ms |
| 1,000 m traverse | same bars for step and adoption, zero gaps | 61 steps, 1,002 m, zero gaps; 99th percentile 0.85 ms, longest 1.0 ms in most runs and a single 5 to 11 ms frame in about one run in three (scheduler and driver jitter, see the spec's amendment 6) |
| walk frame CPU | median of three at most 20 ms, each at most 33, p99 at most 6 | three horizon walks: max 13.2, 17.2 and 10.9 ms, p99 4.9, 3.6 and 4.5 ms |
| GPU time | reported, never gated (the card is shared) | about 4.3 ms per pose frame |

The probe times the far terrain with its own viewport idle: a mesh upload that waits for a busy card is the card's time,
not the far terrain's. The same adoption measured while the viewport was drawing 6 M primitives, and while chunks were
uploading in the same frames, showed single stalls of 5 to 25 ms; that is why the far terrain adopts only while the
streamer is settled.

## How relief and world size plug in

S2 (relief, section Relief below) adds a macro-relief term to the engine's height function beyond the plan's domain; the far
tiles ask the engine for heights, so mountains appear in them with no change to their heights. The mesher's vertical window
is derived from the heights in S2; the far tiles have no such window. S3 (world size)
grows the footprint; the far terrain follows the focus chunk and takes its chunk grid from the streamer's own grid
(`StalagWorld.get_half_extent_m`), and its real-tree tier reads `place_chunk` for every chunk of that grid, so a bigger
grid is picked up as is. Hard-coded copies of 224, 112 and 448 elsewhere are S3's list, not this file's. S4 retires the
Spec 580 backdrop ring (kept at `far` and `vista`), makes every far tree a real placement and adds the pause-menu row for
the setting.

## Relief

Spec 582 S2 gives the world mountains. The engine's height function gains one term, `macro_relief`
(`engine/stalag/src/stalag_core.cpp`), added last to `shb`. It is exactly zero out to 226 m (Chebyshev) from the origin:
the water plan's domain is +-224 m, so the plan domain, every carve, the plan hash and every footprint chunk are bit
for bit what they were (hashes pinned by `tests/verify_relief.sh`). Past 226 m a smoothstep ramp over 120 m brings in
two ridged octaves of value noise (300 m and 120 m features, 70 m and 30 m tall). Measured on the 100 m windows of the
highland ring (Chebyshev 346 to 850 m): relief p10 / p50 / p90 of 16.9 / 30.6 / 47.8 m, tallest point
105.7 m, largest 1 m step 4.75 m. Nothing walks there in S2 (the footprint is +-112 m, finding M of the spec):
the mountains are seen, through the far tiles, which take the engine's own height and so need no change.

The mesher's vertical window was a constant that made tall terrain disappear (a 28 m chunk beyond the plan domain at
100 m high meshed to zero triangles). `cy_hi_const` in `build_surface` is now one line derived from the region's own
pre-carve heights (`region_cy_hi`: the tallest `shb` over the region and its ring, plus margins), never below the old
26, so every chunk that fitted the old window meshes byte for byte as before. Proof is CPU-only and needs no Godot:
`tests/verify_relief.sh` builds `engine/stalag/tests/relief_check.cpp` from the engine sources with plain g++ and writes
a record (valley hashes, the 64 footprint chunks' mesh hash, relief numbers, a tall chunk and a row of chunks across the
plan domain's edge checked by vertical rays against `ground_envelope_at` with a finite ceiling, chunk build times, and a
terrain-only skyline from each horizon pose). `RELIEF_VARIANT=window26` rebuilds with the old constant (the tall chunk
meshes to zero triangles: the control), `mutate_valley` moves one valley term (the hashes must change).

The far tiles carry slope-derived rock facing in vertex colour (`far_terrain.gd:_ground_color`): rock shows from about
20 degrees of slope and is all rock at 44, no canopy tint stands on rock, and the height ramp of the ground colour spans
90 m, not the 9 m of the valley. Real chunks and the walker stay as they were (S3).

Pixel measures of relief, per pose, in `horizon.json`: `skyline_rise_med_deg` (the median over the frame's columns of
the angle between the horizon row and the topmost row that is not sky; signed) and `far_height_p90_m` (the 90th
percentile of the world height of the far non-sky pixels, rebuilt from the depth frame and the camera). The record's
`lod.relief` compares the far tiles with `ground_envelope_at` in the highland ring and `lod.rock` the rock weight of
steep and flat vertices of `l3`. All truth calls pass a finite ceiling (`TRUTH_CEIL_M` in the probe): with an unbounded
ceiling the engine's scan starts at lattice 60 and returns -inf above 7.5 m. `HZ_MUTATE=norelief` makes the far terrain
read the height clamped into the plan domain (Chebyshev 224 m): the valley without highlands, which must fail the
skyline and far-height bars. Measured at the four tower poses (first GPU run): the silhouette rises 13.6, 12.1, 8.2 and 8.7 degrees and the far pixels' 90th percentile height is 101, 97, 97 and 82 m; the far tiles' tallest vertex is 105.9 m against the engine's 106.1 m, height error mean 0.62 m and 95th percentile 1.9 m, steep vertices of `l3` carry a rock weight of 0.76 and flat ones 0.0. The ground pose (`hz-ground-east`) is
recorded and not gated in pixels: it stands in forest and no clear ground-level sightline exists in the valley.

## Probe records

`tools/measure_horizon.sh` (display `:99` only, isolated user data, dead D-Bus, engine and GPU locks) writes
`horizon.json` (measure mode) or `sheet.json` and `contact.png` (sheet mode) under `HZ_OUT`. Controls, all through
`HZ_MUTATE`: `nolod` (no far terrain), `flat` (flat tiles), `fogwall` (density 0.012), `noclouds`, `seam` (far haze made
another colour) and `noatmo` (the atmosphere code bypassed). Each pose is rendered three times: lit, with every surface
drawn by `tools/scenic/depth_pass.gdshader` (linear distance in the RGB bits of the frame, white for no surface), and
with the world hidden (pure sky). All pixel metrics are read from those frames in the observer's frame by
`tools/scenic/post.py`:

- `depth_p90_nonsky_m`: the 90th percentile of distance over non-sky pixels whose fog opacity is at most 80 percent.
  For flat ground a camera `h` metres up sees this at about `h / tan(0.1 * theta)`, with `theta` the part of the frame
  below the horizon, once the pixels beyond the fog limit are left out: about 360 m at 24 m with a 40 degree lens (and
  about 310 m with the 50 degree lens of the pad pose), so the floors of this bar are set against that ceiling, not
  against the 590 m that the same formula gives without the fog filter. Measured: 374, 395, 393 and 298 m at the four
  tower poses, against 121, 137, 162 and 146 m at `vista` and 0, 0, 0 and 56 m at `near` (at `near` the three edge poses
  see no terrain at all: the world ends 26 m ahead).
- `sky_frac`, `far_detail` (8 by 8 blocks beyond 300 m with a luma deviation of 3), `far_contrast` (p95 minus p5 of luma
  beyond 300 m), `far_px_frac`, `cloud_frac` (16 by 16 all-sky blocks that are not a flat gradient), `seam_de` (pixels
  6 above and 6 below the terrain and sky boundary where the terrain is beyond 600 m) and `hole_px_frac` (pixels below
  the horizon line that equal the world-hidden frame).
- From the engine: `lod.levels[].err_*` (the tile meshes against `ground_envelope_at` at random points, per level),
  `lod.height_err_mean_m`, coverage gaps and overlap by sample points, `lod.trees.real_match` (the far real-tier
  placements equal `place_chunk`), and the traverse.

## Provenance

Everything here is procedural and written for this project: the tile meshes come from the engine's own height function;
the tree sprites and the cross mesh are drawn in code (adapted from `game/world/backdrop_ring.gd`, Spec 580 S4, same
project and licence); the sky clouds are fractal value noise on a hash lattice in `sky_clear.gdshader`; the depth
encoding in `depth_pass.gdshader` is a plain 24-bit pack. No image, mesh or sound is loaded from disk and no third-party
code is used. The amber preset's numbers are the project's own mesa-sidelight look. Licence: AGPL-3.0-only.
