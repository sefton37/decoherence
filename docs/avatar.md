# The player avatar (Spec 581, slice S1)

The body the player sees in the world: a third-person colonist in the Empire's white soft-shell suit, the
"Open Ledger" direction (the suit broadcasts its wearer's vitals; the face sits behind a clear visor, dark
and faceless for now). It replaces the walker's placeholder capsule and visor. It is drawn entirely from
primitives and posed by a pure gait function, so it carries no imported art and no licence.

## What it is

- `game/avatar/avatar_template.json` holds the whole look and the gait as data: the colours, the presets,
  the stride and swing numbers. `draft` is true: the look is a starting point, not a locked design.
- `game/avatar/avatar_body.gd` builds the body from a preset (boxes, cylinders, spheres sized in code),
  hands out its named joints, and writes a pose onto them. Origin on the ground under the feet, front -Z.
- `game/avatar/avatar_gait.gd` is pure and engine-free. It turns the distance the body really travelled
  into joint angles with a two-bone inverse-kinematics walk. No clock and no random number appear in it.
- `game/avatar/avatar_view.gd` is the node that wires the body into the world. `game/world/world.tscn`
  carries one `Avatar` node after `Walker`; on `_ready` it removes the walker's capsule and visor and hangs
  the body under `walker.body_node()`, so the walker's yaw, `body_offset_y` and every probe's
  hide-the-body differential keep working unchanged. No engine script was edited.

The gait is driven by measured ground displacement, never by input or velocity: a walker pushing into a
wall, or frozen by a probe, does not run on the spot. The stance foot is placed so its ground position is
constant (it slides back under the body at exactly the body's speed), so the feet do not skate. Airborne,
the cycle holds a fixed pose and does not advance. Stopping blends back to the standing pose in the
template's `stop_settle_s`. Breath and the vitals light's slow pulse run off accumulated frame time.

## Known limits

- The body is seated on the walker's own feet position. The walker lifts its feet up to 0.45 m above the
  ground under its centre when its footprint straddles a terrace edge (`MAX_FOOTPRINT_LIFT`, an engine
  choice from Spec 501), so on stepped terrain the avatar hovers by that much at those frames. The seating
  probe therefore walks the flat, cleared slab; a view-side seat offset (lowering the body by the hover)
  is possible but changes how the body meets risers, so it is left as a decision.
- The feet are not placed on the terrain: the stance foot is locked to the ground plane under the body,
  so a stride across a step has one foot floating or sunk by the step height.
- The face is dark glass, the vitals light is a static strip with a slow pulse, and the look is one
  colour set. Per-person variation, a face plate and stat binding are later slices.

## Contract for the arrival cutscene

The arrival cutscene (Spec 576 S2) has the colonist step out of the pod and walk to the hand-off pose.
S1 leaves these hooks on the view node (`Avatar`), all documented and none exercised by the cutscene yet:

- `attach(walker)` hangs the body under that walker's body node (the view does this itself on `_ready`).
- `hold_pose(phase, moving)` freezes the body at a point of the stride cycle (`phase` 0..1; `moving`
  true for a striding pose, false for standing). The walker stops driving the body until `release_pose()`.
- `release_pose()` hands the body back to the walker.
- `set_preset(id)` switches to another preset of the template (false for an id it lacks).
- `stats()` returns the view's per-frame update time over the last 2048 frames (calls, mean, p95, max, in
  microseconds), which is what the cost probe reads. The first 120 frames after attach are left out: they
  share their frame with world start-up (two start-up frames of 6 and 12 ms were measured; afterwards the
  update takes about 70 microseconds, p95 80, max about 120).
- `body()`, `joint_nodes()` and `preset_id()` expose the built body for probes.

S2 adds one more entry, a drive for a body that is not the walker (a scripted distance and speed in place
of the walker's), so the cutscene can walk the body with the same gait. S1 deliberately does not build
what S2 will define against real geometry.

## Presets and how to choose

The template ships three interpretations of the one line of description AV3 has ("Empire white soft-shell
broadcasting vitals; face in clear visor"). They differ in silhouette, not only in colour (the front
silhouettes overlap by at most 85 percent, checked), and all stand 1.70 m tall, the controller's collision
height.

| id | heads | read |
| -- | ----- | ---- |
| plain | 6.5 | slim soft-shell, thin chest vitals band, wide visor |
| bulk | 6.0 | insulated: stacked ring seams on the limbs, a small back pack, vitals on the chest and the left forearm |
| tall | 7.5 | fitted suit, narrower torso, smaller head dome, a narrow visor slit |

`default_preset` in the template is `plain` until the owner picks. To see the three side by side, run
`tests/verify_avatar_sheet.sh` (see the probe records below): `contact_sheet.png` shows each preset from
the front, three-quarter, side and back (one row per preset, in template order), and `walk_strip.png`
shows eight phases of the default preset's stride from the side. To choose, change `default_preset`, then
type `world` in the shell.

## Adding a preset

1. Copy one entry of `presets` in `avatar_template.json` and give it a new `id` (lower case, letters,
   digits and underscores) and a `label`.
2. Set its proportions. `heads` is the body height over the head height (at least 5; the disliked chibi
   was 2.8). `shoulder_half_m` is the outer half-width of the shoulder line. `chest_half_m`,
   `torso_depth_m`, `hip_half_m`, `arm_r_m`, `thigh_r_m` and `shin_r_m` size the torso and limbs;
   `leg_frac` is the hip joint's height as a share of the body height; `head_width_scale`,
   `visor_width_frac` and `visor_height_frac` shape the head; `rings`, `pack` and `vitals_arm` switch the
   extras on.
3. Keep the body inside the controller: the half-width the body reaches while walking must stay at or
   under `collision_half_width_m` (0.3 m), or it visibly clips walls the controller stopped at. The unit
   harness measures this over the whole cycle.
4. Run `tests/verify_avatar_unit.sh` (silhouette distinctness, structure, gait) and
   `tests/verify_avatar_sheet.sh`: the sheet now has a row for the new preset.

## Provenance

Every mesh, material and motion is generated in code from `avatar_template.json`. No model, texture, rig,
animation clip or sound is imported, and no third-party code is ported. The gait is a two-bone
inverse-kinematics walk written for this project from the law of cosines. The body and gait scripts carry
a `## Provenance:` line saying so, and the DoD checks that no binary asset is loaded or committed under
`game/avatar`.

## Probe records

All three harnesses isolate the player's own data: `DBUS_SESSION_BUS_ADDRESS` points at a dead path,
`--audio-driver Dummy`, a scratch `XDG_DATA_HOME`, and the two that render hold the test display (`:99`)
and a GPU lock.

- `tests/verify_avatar_unit.sh` (headless, no GPU) runs `tests/avatar_unit.gd` in two processes and
  writes `unit.json`: the built bodies (height, proportions, joints, triangle and node counts, silhouettes),
  the gait measured from the rig's joint and foot-marker nodes (swing, correlations, stride, stop settle,
  foot skate against a planted stride 1.6 times too long, lateral extent), determinism digests across
  processes, a fuzz run with a hit count for every branch it claims to cover, and a negative control for
  every fuzz check.
- `tests/verify_avatar_world.sh` boots the real world five times (the player's view and four negative
  controls: body hidden, capsule restored, gait frozen, body lifted) and writes `avatar*.json` and six shots
  taken through the real follow camera. It measures the wiring from the scene tree, seating against the
  triangles handed to the renderer, animation from the joint nodes while the walker walks, visibility as a
  hide-the-body pixel differential, and cost as the view's update time plus the draw calls and primitives
  the body adds to one frozen frame.
- `tests/verify_avatar_sheet.sh` renders the contact sheet and the walk strip on a plain stage, plus a
  hidden-body control.
