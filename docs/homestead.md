# The first homestead (Spec 576, slice S1)

The place a colonist is carried down to: a Foundation Slab with scorch rings, a landed drop pod with
its door open, and the eight starting items laid out in front of it, on the engine's flat pad at the
world origin. This note says what the generator guarantees, what the two data files hold, how to edit
them, and what the arrival cutscene (S2) consumes.

## What it is

- `game/homestead/homestead_site.gd` is a pure, engine-free generator. Its inputs are a site seed and
  the two data files; its output is a layout (poses in metres, slab-local). It reads no clock and no
  global random generator, and it names no engine class.
- The seed is the assigned colonist's id hashed with FNV-1a (32 bit) over its UTF-8 bytes
  (`site_seed_for`). The homestead is therefore a pure function of the id and the template version:
  the same colonist always arrives at the same site, two colonists never share a layout, and nothing is
  written to the profile. Determinism is the persistence.
- `game/homestead/homestead_view.gd` builds the layout as procedural primitives (no imported art).
- `game/world/world_scene.gd` generates the site for `colonist_id` (empty means the default site, seed
  `default_site_seed`), builds it at the origin, keeps the meadow and understory off the pad through the
  game-side flora mask (`GroundLook.install_flora_mask`), and starts the player at the hand-off pose.
- The `world` shell command enters the homestead directly, with the player in control (no cutscene).

## What the generator guarantees (checked by `tests/verify_homestead_unit.sh`)

Every layout, over 2000 seeds, satisfies:

- the pod, every item, the hand-off pose and the scorch rings lie fully on the slab;
- footprints never overlap and keep at least `min_gap_m` apart;
- a clear walking lane of `door_path_clear_m` runs from the pod door to the hand-off pose;
- every item's centre lies inside the half-cone of `view_cone_deg` ahead of the hand-off facing, and
  none is hidden behind the pod;
- the rings are centred on the pod, jittered at most `ring_center_jitter_m`.

Variation per colonist: pod door direction, pod offset along the slab's back, ring jitter, and the
position and yaw of every item. Beyond the checked list, the generator keeps items out of a narrow
corridor straight ahead of the hand-off pose (`walker_shadow_deg`, so the follow camera's own character
never hides one) and puts tall items in the far part of the fan and low ones in the near part (so a
tall item never hides a low one from the hand-off view).

## The data files

`game/homestead/data/site_template.json` (all lengths in metres):

| Key | Meaning |
| --- | --- |
| `slab.half_x_m`, `slab.half_z_m` | Slab half-extents (4 to 5 m; the corner must stay inside the engine's 8 m clear zone) |
| `slab.thickness_m`, `slab.lift_m` | Slab depth; its top stands this far above the pad (no z-fight) |
| `pad_margin_m`, `pad_blend_m` | The pad extends this far past the slab edge; the terrain blends into the surrounding terraces within `pad_blend_m` in steps of at most one terrace (0.5 m) |
| `scorch_rings[]` | Ring radius and width, ascending radius |
| `pod.*` | Footprint radius, height, door height, wall panels, door opening angle, door base direction, per-colonist yaw jitter and offset range |
| `handoff.distance_m` | Hand-off pose distance out from the door |
| `view_cone_deg`, `walker_shadow_deg`, `door_path_clear_m`, `min_gap_m` | Layout rules above |
| `colors` | Hex palette (Empire livery: white hull, red hexagon, dark underside, scorched slab) |
| `taste_defaults` | The knobs a design owner is expected to turn |

`game/homestead/data/starter_equipment.json` holds the eight items. Each cites a line of
`lore/charter.md` (`canon_ref`) that must contain its `canon_term`; the unit check enforces that, one
droid only, and the reactor dormant. A `shape` is a list of parts (`box`, `cyl`, `sphere`) with a centre
`pos` relative to the item's base and a palette colour; `footprint_r_m` must hold the whole shape (the
unit check enforces that too).

To change the homestead: edit a number or an item, run `world`, and it shows up. To add or remove an
item, edit the list; the generator places whatever is there (the layout rules still hold, but a much
larger list may not fit the slab, in which case the unit check fails and the slab or footprints need to
change). Both data files are marked `"draft": true`.

## The engine's part: the flat pad

The terrain around the origin is terraced with about 3 m of relief, so a slab could not sit flush on
it. The engine's height function levels a pad centred on the origin (the slab half-extent plus
`pad_margin_m`), blended into the surrounding terraces over `pad_blend_m`; the world scene passes both numbers
to the engine (`StalagWorld.set_pad`) from the template, which is the one statement of them. No water and no
tree stands inside the pad. Column heights in the blend differ by at most one terrace per column and one per
two columns; the engine's rendered surface can still show a 0.75 m jump at a few step corners (mesher cap
cells), which the probe reports as `pairs_over_half_m`. The
render probe measures all of this against the rendered mesh and the engine query.

## The S2 contract

`HomesteadSite.generate(...)["handoff"] = {x, z, yaw, dir_angle}` is the pose S2 hands the free follow
camera to (`yaw` is in the world camera's convention) and `["door"]` is the door pose. The world scene
starts the player there facing along `dir_angle`, with the follow camera swung `HANDOFF_CAM_YAW_DEG` to one
side (its minimum boom would otherwise put it under the pod's roof), so it stands outside the pod volume.
The assigned colonist's id arrives through `colonist_id` on the world scene.

## Checks

- `tests/verify_homestead_unit.sh` -- headless unit and fuzz harness (determinism across processes,
  data-driven results, the constraint set with its negative controls).
- `tests/verify_homestead_site.sh` -- render probe on the test display: six stills, a hidden-homestead
  control run and a contact sheet.
