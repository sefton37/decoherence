#!/usr/bin/env bash
## tests/verify_router_unit.sh -- Spec #519 unit + fuzz harness for the router core.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first
## (new class_name files are invisible to a --script run until the editor has
## registered them), then runs tests/router_unit.gd. The script's own output
## (UNIT_OK / UNIT_FAIL / UNIT_NEGCTL_OK / FUZZ_* / INJECTION_OK) is passed
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
timeout 300 "$GODOT" --headless --path "$REPO_ROOT" --script res://tests/router_unit.gd </dev/null 2>&1 \
    | grep -E '^(UNIT_|FUZZ_|INJECTION_|PROMPT_BUDGET|SCRIPT ERROR|ERROR:|Parse)' 
exit "${PIPESTATUS[0]}"
