#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_homestead_unit.sh -- Spec 576 S1 unit and fuzz harness for the homestead generator.
##
## Headless: no renderer, no GPU, no engine library needed by the generator. Runs
## tests/homestead_unit.gd three times in three separate processes, then merges the three records
## into unit.json (runs[].digest, cross_process_digest_equal, plus the last run's measurements).
## The numbers are measured by the script; the DoD's jq judges them.
##
## Env: OUT_DIR (required), XDG_DATA_HOME (default: a scratch dir, so user:// is never the real one),
##      ENGINE_LOCK / IMPORT_LOCK (optional lock files: shared lock while Godot loads the project,
##      exclusive lock around the editor import scan), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_homestead_unit: OUT_DIR is required}"
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
for run in 1 2 3; do : > "$OUT_DIR/unit_run_$run.json"; done

# New scripts and class names are invisible to a --script run until the editor has scanned the project.
with_lock "${IMPORT_LOCK:-}" -x timeout 180 "$GODOT" --headless --audio-driver Dummy --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

status=0
for run in 1 2 3; do
    UNIT_RUN="$run" with_lock "${ENGINE_LOCK:-}" -s timeout 300 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" \
        --script res://tests/homestead_unit.gd </dev/null 2>&1 \
        | grep -E '^(HOMESTEAD_|SCRIPT ERROR|ERROR:|Parse)'
    [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
done

for run in 1 2 3; do
    [ -s "$OUT_DIR/unit_run_$run.json" ] || { echo "verify_homestead_unit: run $run wrote no record" >&2; exit 1; }
done
jq -s '. as $r | $r[2] + {
    runs: [$r[] | {digest: .run_digest}],
    cross_process_digest_equal: (([$r[].run_digest] | unique | length) == 1)
}' "$OUT_DIR"/unit_run_1.json "$OUT_DIR"/unit_run_2.json "$OUT_DIR"/unit_run_3.json > "$OUT_DIR/unit.json" \
    || { echo "verify_homestead_unit: merge failed" >&2; exit 1; }
[ "$status" -eq 0 ] || { echo "verify_homestead_unit: at least one run reported a failure" >&2; exit 1; }
echo "verify_homestead_unit: three runs agree, record written" >&2
exit 0
