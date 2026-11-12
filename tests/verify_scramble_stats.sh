#!/usr/bin/env bash
## tests/verify_scramble_stats.sh -- Spec #562 A1: ambient scramble variability.
##
## Headless (no renderer, no GPU, no model). Runs tests/scramble_stats.gd, which
## measures a seeded sample of ambient lines (shaped vs the pre-A1 legacy scramble),
## checks every drawable glyph against the chat font, and writes the JSON to
## $OUT_FILE. This wrapper judges nothing; the DoD's jq does.
##
## Env: OUT_FILE (required), XDG_DATA_HOME (default: a temp dir), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_FILE:?verify_scramble_stats: OUT_FILE is required}"
export OUT_FILE
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
if [ -z "${XDG_DATA_HOME:-}" ]; then
    export XDG_DATA_HOME="$(mktemp -d)"
fi
mkdir -p "$XDG_DATA_HOME" "$(dirname "$OUT_FILE")"
: > "$OUT_FILE"

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 300 "$GODOT" --headless --path "$REPO_ROOT" --script res://tests/scramble_stats.gd </dev/null 2>&1 \
    | grep -E '^(SCRAMBLE_STATS_FAIL|SCRIPT ERROR|ERROR:|Parse)'
rc=${PIPESTATUS[0]}
[ -s "$OUT_FILE" ] || { echo "verify_scramble_stats: no output written" >&2; exit 1; }
exit "$rc"
