#!/usr/bin/env bash
## tests/verify_colonist_unit.sh -- Spec #575 unit harness for the HANDLER module core.
##
## Headless (no renderer, no GPU, no model). Rescans the class_name cache first (new
## class_name files are invisible to a --script run until the editor has registered
## them), then runs tests/colonist_unit.gd. The script's own output (COLONIST_UNIT_OK,
## COLONIST_UNIT_FAIL, COLONIST_NEGCTL_OK and the COLONIST_* summary lines) is passed
## through; this wrapper exits with the Godot script's exit code.
##
## Env: XDG_DATA_HOME (recommended: a scratch dir, so user:// is not the real one),
##      DECOH_IMPORT_LOCK (optional: a lock file that serialises the class-cache rescan),
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
if [ -z "${XDG_DATA_HOME:-}" ]; then
    XDG_DATA_HOME="$(mktemp -d)"
fi
export XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME"
case "$XDG_DATA_HOME" in
    "$HOME/.local/share"*) echo "verify_colonist_unit: refusing to use the real user data dir" >&2; exit 2 ;;
esac
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus

${DECOH_IMPORT_LOCK:+flock "$DECOH_IMPORT_LOCK"} timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" --script res://tests/colonist_unit.gd </dev/null 2>&1 \
    | grep -E '^(COLONIST_|SCRIPT ERROR|ERROR:|Parse)'
exit "${PIPESTATUS[0]}"
