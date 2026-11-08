# game/

Home of the Decoherence game layer built on top of `engine/`: the game loop,
homestead, and bots. Game policy stays here, not in the engine.

The prototype's game-side code is catalogued in `docs/prototype-map.md`.

- `world/` is the `world` module of the frontdoor shell (Spec #501): `world_module.gd`
  (engine-free launcher that degrades gracefully when the engine library is not built) and
  `world.tscn` / `world_scene.gd` (spawn point, key bindings and exit; the engine scripts
  stay policy-free).
