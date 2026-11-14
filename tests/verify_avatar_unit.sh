#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_avatar_unit.sh -- Spec 581 S1 unit and fuzz harness for the player avatar.
##
## Headless: no renderer and no GPU. Runs tests/avatar_unit.gd in two separate processes, then merges the
## two records into unit.json (the second run's measurements plus cross_process.digests, the determinism
## digest of each process). The numbers are measured by the script; the DoD's jq judges. The whole Godot
## log of both runs goes to godot.log in OUT_DIR.
##
## Env: OUT_DIR (required), XDG_DATA_HOME (default: a scratch dir, so user:// is never the real one),
##      ENGINE_LOCK / IMPORT_LOCK (optional lock files: shared lock while Godot loads the project,
##      exclusive lock around the editor import scan), FUZZ_TRIALS, GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_avatar_unit: OUT_DIR is required}"
if [ -z "${XDG_DATA_HOME:-}" ]; then
    XDG_DATA_HOME="$(mktemp -d)"
fi
export XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME" "$OUT_DIR"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
# The unit run is headless, but never let an inherited desktop display reach Godot.
export DISPLAY=":99"
unset WAYLAND_DISPLAY

with_lock() {  # with_lock <lockfile-or-empty> <flock-mode> cmd...
    local lock="$1" mode="$2"
    shift 2
    if [ -n "$lock" ]; then flock "$mode" "$lock" "$@"; else "$@"; fi
}

# A stale record must never be read as a fresh one: empty every output first.
: > "$OUT_DIR/unit.json"
: > "$OUT_DIR/godot.log"
for run in 1 2; do : > "$OUT_DIR/unit_run_$run.json"; done

# New scripts and class names are invisible to a --script run until the editor has scanned the project.
with_lock "${IMPORT_LOCK:-}" -x timeout 180 "$GODOT" --headless --audio-driver Dummy --editor --quit --path "$REPO_ROOT" </dev/null >>"$OUT_DIR/godot.log" 2>&1 || true

status=0
for run in 1 2; do
    UNIT_RUN="$run" with_lock "${ENGINE_LOCK:-}" -s timeout 900 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" \
        --script res://tests/avatar_unit.gd </dev/null >>"$OUT_DIR/godot.log" 2>&1
    ec=$?
    echo "verify_avatar_unit: run $run exited $ec" >&2
    [ "$ec" -eq 0 ] || status=1
done
grep -E '^AVATAR_UNIT_(FAIL|DONE|SKATE|IOU|FUZZ)' "$OUT_DIR/godot.log" >&2

for run in 1 2; do
    [ -s "$OUT_DIR/unit_run_$run.json" ] || { echo "verify_avatar_unit: run $run wrote no record" >&2; exit 1; }
done
jq -s '.[1] + {cross_process: {digests: [.[0].determinism.runs_digest[0], .[1].determinism.runs_digest[0]]}}' \
    "$OUT_DIR/unit_run_1.json" "$OUT_DIR/unit_run_2.json" > "$OUT_DIR/unit.json" \
    || { echo "verify_avatar_unit: merge failed" >&2; exit 1; }
[ "$status" -eq 0 ] || { echo "verify_avatar_unit: at least one run reported a failure" >&2; exit 1; }
echo "verify_avatar_unit: two processes ran, record written" >&2
exit 0
