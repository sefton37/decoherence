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
