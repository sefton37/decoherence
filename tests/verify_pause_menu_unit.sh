#!/usr/bin/env bash
## tests/verify_pause_menu_unit.sh -- Spec #578 unit harness for the global pause menu.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first, then runs
## tests/pause_menu_unit.gd for one group. The script's own output (PM_UNIT_<GROUP>_OK /
## PM_UNIT_FAIL) is passed through; this wrapper exits with the Godot script's exit code
## (an unknown group exits 2).
##
## Env: PM_GROUP (required): state | seam | chatclock | exitflush
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${PM_GROUP:?verify_pause_menu_unit: PM_GROUP is required}"
export PM_GROUP
# The unit run boots on a scratch user dir: the player's saves are never touched.
XDG_DATA_HOME="$(mktemp -d)"
export XDG_DATA_HOME
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
unset WAYLAND_DISPLAY

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" --script res://tests/pause_menu_unit.gd </dev/null 2>&1 \
    | grep -E '^(PM_|SCRIPT ERROR|ERROR:|Parse)'
exit "${PIPESTATUS[0]}"
