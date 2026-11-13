#!/usr/bin/env bash
## tests/verify_funnel_unit.sh -- Spec #573 unit harness for the recruitment funnel core.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first
## (new class_name files are invisible to a --script run until the editor has
## registered them), then runs tests/funnel_unit.gd. The script's own output
## (FUNNEL_UNIT_OK / FUNNEL_UNIT_FAIL / FUNNEL_NEGCTL_OK and the FUNNEL_* summary
## lines) is passed through; this wrapper exits with the Godot script's exit code.
##
## Env: XDG_DATA_HOME (recommended: a scratch dir, so user:// is not the real one),
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
if [ -z "${XDG_DATA_HOME:-}" ]; then
    XDG_DATA_HOME="$(mktemp -d)"
fi
export XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" --script res://tests/funnel_unit.gd </dev/null 2>&1 \
    | grep -E '^(FUNNEL_|SCRIPT ERROR|ERROR:|Parse)'
exit "${PIPESTATUS[0]}"
