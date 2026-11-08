#!/usr/bin/env bash
## tests/verify_ticker_smooth.sh -- issue #865 (follow-up to Spec #519): the BUS>
## ticker and the other conveyors scroll by sub-cell pixel offsets driven by
## real frame delta. Runs tests/ticker_smooth.gd headless (offset logic) and,
## with RENDER=1, again on the Xvfb display :99 against real rendered frames.
## Markers: TICKER_UNIT_OK / TICKER_NEGCTL_OK / TICKER_RENDER_OK; exit 0 on pass.
## Env: RENDER (1 = also run the :99 render pass), TICKER_DUMP (dir for crops),
##      XDG_DATA_HOME (scratch recommended), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
if [ -z "${XDG_DATA_HOME:-}" ]; then
    export XDG_DATA_HOME="$(mktemp -d)"
fi
mkdir -p "$XDG_DATA_HOME"

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 120 "$GODOT" --headless --path "$REPO_ROOT" res://tests/ticker_smooth.tscn </dev/null 2>&1 \
    | grep -E '^(TICKER_|SCRIPT ERROR|ERROR:|Parse)'
ec="${PIPESTATUS[0]}"
[ "$ec" -eq 0 ] || exit "$ec"

if [ "${RENDER:-0}" = "1" ]; then
    ## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
    export DISPLAY=":99"
    unset WAYLAND_DISPLAY
    [ -S "/tmp/.X11-unix/X99" ] || { echo "verify_ticker_smooth: display :99 not available" >&2; exit 2; }
    TICKER_RENDER=1 timeout 120 "$GODOT" --path "$REPO_ROOT" --resolution 1920x1080 res://tests/ticker_smooth.tscn </dev/null 2>&1 \
        | grep -E '^(TICKER_(FRAMES mode=render|RENDER|UNIT_FAIL)|SCRIPT ERROR|ERROR:|Parse)'
    exit "${PIPESTATUS[0]}"
fi
exit 0
