# lore/

The Decoherence lore canon, exported from Notion on 2026-11-07.

## Source of truth

Kel ruled on 2026-11-07 that **Notion and `lore/` are both canonical**. Two sources only stay true if
they are kept in sync, so the rule is: **an edit to either one is mirrored to the other in the same
sitting.** Each file starts with a provenance header (`Source:` / `Notion-page:` / `Exported:`); bump
`Exported:` when you re-sync.

| File | Notion page | Mirrored |
|---|---|---|
| `charter.md` | "Decoherence" (the Project Charter & Vision body) | yes |
| `narrative.md` | "Narrative of Game" | yes |
| `homestead-kits.md` | "Homestead Kits" | yes (its "Modular Homestead Economy" research sub-page is linked, not mirrored) |

The Notion page titled "Charter and Vision" is empty; the charter lives in the body of the
"Decoherence" page.

## Known drift between the charter and the game as built

The charter text is kept verbatim. These places are where later decisions superseded it, so read
them as history, not as instructions:

- **§0 / §3 / §7, "2.5D Hex Grid top down", "2D hex grid", "Art & Aesthetic Direction (2D Hex)":**
  superseded. The world is a 3D truncated-octahedron voxel world (the Stalag engine); "hex" survives
  only as the shield territory of a homestead.
- **§9.1, engine:** Godot, shipping on Steam (decided 2026-11-07, research #210). The three.js
  build in `~/dev/stalag` (tag `prototype-final`) is the prototype; see `docs/prototype-map.md`.
- **§4.3, "Hauler programmable in Python":** refined in the prototype. The player writes a
  whitelisted Python subset run by a verb-VM. Bots run scripts; the Proxy runs a *policy*: your
  code is a suggestion its own arbiter weighs against its drives and Focus, and direct control
  owes a recovery debt.
- **Intro arc** (`narrative.md`): the Godot front door (`frontdoor/`) implements the Q-Ent boot,
  shell, and Handler chat. The chatroom recruitment is the next unbuilt beat.
