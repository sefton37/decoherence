# The pause menu (Spec 578)

One global overlay. Esc opens it from anywhere in the game: the boot sequence, the Q-Ent OS prompt, the
chatroom, the world (the homestead is part of the world scene), and any screen built later. It has four rows:
resume, settings (the display toggle), exit to the Q-Ent OS (shown only while the world is mounted) and exit to
the desktop. All of its words are in `frontdoor/data/pause_menu.json`. They are DRAFT placeholders in the
Q-Ent register; the wording and the look are an open taste call.

## How it works

- `PauseMenu` is an autoload (`frontdoor/scripts/pause_menu.gd`, a `CanvasLayer` at layer 100, above the CRT
  overlay at layer 10, `PROCESS_MODE_ALWAYS`). It exists before any scene and survives every scene change.
- Opening pauses the tree. Everything that ticks in `_process`, every physics step and every
  `create_timer(t, false)` stops with it. The menu and its probes are the only nodes that still run.
- The mouse is freed while the menu is open and put back to the mode it was in on close (the world captures it).
- Esc is read in `_unhandled_input`. A screen that handled Esc itself never opens the menu (see below).
- Signals: `opened`, `closed(paused_msec)`, `display_toggle_requested`. The signal bus stays untouched; the
  settings row only asks, and the boot controller applies and persists the display setting through the same
  path as F11 and Alt+Enter, which keep working unchanged.
- Exit: `PauseMenu.exit_to_desktop()` flushes every node of the group `quit_flush` (each defines
  `flush_for_exit()`), once, in tree order, then quits once. The game-owned model server is killed by the
  language client's own `_exit_tree`, which runs on any normal quit. The world joins `quit_flush` to shut its
  streamer down.
- Exit to the Q-Ent OS asks the mounted world (group `stalag_world`) to `request_exit()` after the menu has
  closed and the tree runs again.

## What waits for the player

The chatroom's funnel, outbox, direct-message replies and ambient timers run on wall-clock milliseconds, so a
paused tree would otherwise let them come due behind the menu. The chatroom connects `PauseMenu.closed` and moves
every pending time forward by the paused milliseconds. The boot sequence's stage waits are pausable timers, and a
stage's minimum duration does not count paused time.

## Seam for new surfaces

For the builders of Spec 575 (the HANDLER module) and Spec 576 (the homestead and its cutscene), and of any
cutscene or screen after them. DRAFT rules; amend them with the menu.

1. The HANDLER screen, the homestead and any cutscene get the menu with no code. Do not bind Esc to leave your
   screen.
2. If your screen has a sub-pane Esc should close first, claim Esc: handle it and call `set_input_as_handled()`
   only when you actually closed something. With nothing to close, leave the key unhandled so the menu opens.
3. A cutscene "skip" must use another key. Esc is the menu.
4. Anything keyed to wall-clock milliseconds (`Time.get_ticks_msec()`) must connect `PauseMenu.closed(paused_msec)`
   and shift forward by `paused_msec`. Nodes that tick in `_process` pause with the tree. Awaited timers that must
   freeze use `create_timer(t, false)`.
5. Never quit the tree directly. Call `PauseMenu.exit_to_desktop()`. To be flushed first, join the group
   `quit_flush` and define `flush_for_exit()`.
6. A probe for your screen must run with `process_mode = PROCESS_MODE_ALWAYS` if it awaits across a paused tree
   (the probe driver's own awaits use frame signals and engine timers that keep running, so it needs nothing).

## HANDLER screen

Esc opens the menu on the HANDLER screen as everywhere else. HANDLER's own `back` control (leave the module for
the prompt) is Backspace, read from `frontdoor/data/handler/handler_ui.json`; Esc is never a HANDLER key.

## Tests

- `tests/verify_pause_menu_unit.sh` (headless; `PM_GROUP` = `state`, `seam`, `chatclock`, `exitflush`).
- `tests/verify_pause_menu.sh` (off-screen; `PM_MODE` = `surfaces`, `control`, `sizes`, `exit`; probe mode
  `pause_menu` in `frontdoor/scripts/probe_pause_menu.gd`, real key and mouse events only).
