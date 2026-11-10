extends Node
## Global signal bus (Spec #370 / plan-370). Frozen contract, tester-owned —
## the implementer must not change this public surface (add signals in a
## follow-up spec if ever needed; do not repurpose these three).
##
## Autoloaded as "Signals". This is the ONLY channel through which boot
## theater, the Handler chat, and the automated e2e probe (probe_driver.gd)
## communicate. Routing everything through here (rather than direct node
## references) guarantees the automated probe drives the identical
## send-path a real player's Enter keypress uses -- it cannot bypass the
## real boot -> chat pipeline by reaching into scene-tree nodes directly.

## Emitted once boot theater has finished and the Handler chat is ready to
## receive player input (the input line is live, Enter is wired to
## submit_player_line).
signal chat_ready

## Emitted by the Handler chat once a full streamed reply has finished
## arriving. `text` is the complete accumulated reply string.
signal handler_reply_complete(text: String)

## Emitted whenever a line of player input is submitted -- by a real
## Enter keypress in the terminal input line, or by probe_driver.gd
## simulating one. Both paths MUST emit this same signal so the probe
## proves the real send-path, not a shortcut.
signal submit_player_line(text: String)

## --- Additive contract, Spec #371 / plan-371. The three signals above
## stay byte-identical (DOD-9) -- do not edit them. Everything below is
## new surface for the general-OS boot / module-shell slice.

## Emitted every time TerminalGrid actually renders a line to screen --
## from `write_line()` and `update_last_line()` ONLY (never the
## streamed-delta methods `begin_stream_line()`/`append_stream_delta()`,
## which grow a row incrementally rather than rendering a finished line;
## see plan-371 Judgment calls). `text` is the exact string just written.
## This is the state-fidelity echo the tester's probe subscribes to so
## every DoD content assertion (hardware readout, dir listing, gate
## honesty) inspects what was actually put on screen, never a value the
## probe re-derives itself via a parallel API call.
signal line_rendered(text: String)

## Emitted once by boot_controller.gd when the boot theater has finished
## and the minimal OS shell is live and accepting `dir`/module-name input
## (fires regardless of `_gate_success` -- the OS always finishes booting
## to a shell; only the chat *launch* is gated on the model-ready result).
signal shell_ready

## Emitted once by ShellController, only on a successful chat-module
## launch, the moment control hands off from the shell to the real
## Handler chatroom.
signal chat_opened

## The SINGLE upstream channel for every keystroke-equivalent line of
## input -- a real Enter keypress forwarded by boot_controller.gd, or
## probe_driver.gd simulating one. Pre-dates the SHELL/CHAT fork: while in
## SHELL state, ShellController is the sole listener and parses `dir` /
## the module-launch command / unknown-command text; only once state has
## flipped to CHAT does its pass-through re-emit `submit_player_line`
## above. Nothing else may emit `submit_player_line` directly (DOD-37 /
## TRAP-1) -- this is the one legitimate front door for simulated input.
signal terminal_line_submitted(text: String)

## --- Additive contract, Spec #519 (busier boot + conversational shell).
## Everything above stays byte-identical; these are new surface only.

## Emitted by ShellController once per free-form or exact command line that
## was resolved in SHELL state. `source` is "fast" (exact-command table, zero
## LLM requests), "llm" (validated router result) or "degraded" (router
## unavailable / timed out / invalid). `action` is the validated action id
## ("unclear" when nothing was dispatchable); `args` the validated args.
signal intent_resolved(source: String, action: String, args: Dictionary)

## True when the in-fiction "translating" row appears, false when it clears.
signal intent_thinking(active: bool)

## A setting was validated, applied and persisted.
signal setting_changed(key: String, value: String)

## BootPanels reports its computed layout (viewport size, terminal rect, panel
## rects, overlap count) once per layout pass; the density probe records it.
signal layout_reported(report: Dictionary)

## --- Additive contract, Spec #542 (chatroom). Everything above stays
## byte-identical; these are new surface only.

## The player entered the room (first open or a resume).
signal chatroom_opened

## An ordinary voice in the room reached out after the player's first sent
## message. Carries no label: the signal name is internal and never rendered.
signal chatroom_handler_found

## Code (never model text) judged the player ready and the offer was spoken.
signal chatroom_entry_offered

## The player typed an exact accept command while the offer stood. The shell
## re-checks Chatroom.entry_allowed() before it launches the world.
signal chatroom_entry_granted

## The player typed a leave command; the shell takes the keyboard back.
signal chatroom_left
