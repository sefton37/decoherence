#!/usr/bin/env bash
## tests/verify_chat_client_unit.sh -- Spec #562 unit harness for the chat client core.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first
## (new class_name files are invisible to a --script run until the editor has
## registered them), then runs tests/chat_client_unit.gd. The script's own output
## (CHATCLIENT_UNIT_OK / _FAIL / _NEGCTL_OK / _FUZZ) is passed through; this
## wrapper exits with the Godot script's exit code.
##
## Env: XDG_DATA_HOME (recommended: a scratch dir), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
## Off-screen only: never an inherited desktop display, never the session bus.
export DISPLAY=":99"
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
if [ -z "${XDG_DATA_HOME:-}" ]; then
    export XDG_DATA_HOME="$(mktemp -d)"
fi
mkdir -p "$XDG_DATA_HOME"

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" --script res://tests/chat_client_unit.gd </dev/null 2>&1 \
    | grep -E '^(CHATCLIENT_|SCRIPT ERROR|ERROR:|Parse)'
exit "${PIPESTATUS[0]}"
