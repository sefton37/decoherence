#!/usr/bin/env bash
## tests/verify_router_unit.sh -- Spec #542 unit harness for the chatroom core.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first
## (new class_name files are invisible to a --script run until the editor has
## registered them), then runs tests/chatroom_unit.gd. The script's own output
## (CHATROOM_UNIT_OK / CHATROOM_UNIT_FAIL / CHATROOM_NEGCTL_OK) is passed
## through; this wrapper exits with the Godot script's exit code.
##
## Env: XDG_DATA_HOME (recommended: a scratch dir, so user:// is not Kel's),
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
if [ -z "${XDG_DATA_HOME:-}" ]; then
    export XDG_DATA_HOME="$(mktemp -d)"
fi
mkdir -p "$XDG_DATA_HOME"

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --path "$REPO_ROOT" --script res://tests/chatroom_unit.gd </dev/null 2>&1 \
    | grep -E '^(CHATROOM_|SCRIPT ERROR|ERROR:|Parse)' 
exit "${PIPESTATUS[0]}"
