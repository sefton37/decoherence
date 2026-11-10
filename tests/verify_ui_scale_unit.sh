#!/usr/bin/env bash
## tests/verify_ui_scale_unit.sh -- Spec #541 unit test for UiScale.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first
## (a new class_name file is invisible to a --script run until the editor has
## registered it), then runs tests/ui_scale_unit.gd. UISCALE_* lines are passed
## through; this wrapper exits with the Godot script's exit code.
##
## Env: XDG_DATA_HOME (recommended: a scratch dir), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
if [ -z "${XDG_DATA_HOME:-}" ]; then
    export XDG_DATA_HOME="$(mktemp -d)"
fi
mkdir -p "$XDG_DATA_HOME"

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --path "$REPO_ROOT" --script res://tests/ui_scale_unit.gd </dev/null 2>&1 \
    | grep -E '^(UISCALE_|SCRIPT ERROR|ERROR:|Parse)'
exit "${PIPESTATUS[0]}"
