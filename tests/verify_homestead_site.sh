#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_homestead_site.sh -- Spec 576 S1 render probe wrapper for the first homestead.
##
## Runs res://tests/homestead_probe.tscn twice on a REAL renderer (never headless) on the test
## display, in one process each: once as the player sees it (MUTATION=none -> site.json, the stills
## and contact_sheet.png) and once with the whole homestead hidden before every capture
## (MUTATION=hidden -> site_hidden.json), the negative control that must fail the same visibility
## predicates. The Godot log of both runs goes to godot.log. This wrapper only MEASURES; exit 0 means
## both probes ran to completion and wrote their records. The DoD's jq judges.
##
## Env: OUT_DIR (required), XDG_DATA_HOME (default: a scratch dir, never the real user dir),
##      GPU_LOCK (default /tmp/decoh-gpu.lock; renders share one card, so they queue on it),
##      ENGINE_LOCK / IMPORT_LOCK (optional lock files: shared while the world is loaded, exclusive
##      around the editor import scan), COLONIST (default probe-colonist-1), GODOT

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_homestead_site: OUT_DIR is required}"
export DISPLAY=":99"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
if [ -z "${XDG_DATA_HOME:-}" ]; then
    XDG_DATA_HOME="$(mktemp -d)"
fi
export XDG_DATA_HOME
GPU_LOCK="${GPU_LOCK:-/tmp/decoh-gpu.lock}"
mkdir -p "$XDG_DATA_HOME" "$OUT_DIR"

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_homestead_site: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

# A stale record or still must never be read as a fresh one: empty every output first.
: > "$OUT_DIR/site.json"
: > "$OUT_DIR/site_hidden.json"
: > "$OUT_DIR/contact_sheet.png"
: > "$OUT_DIR/contact_sheet_hidden.png"
: > "$OUT_DIR/godot.log"

with_lock() {  # with_lock <lockfile-or-empty> <flock-mode> cmd...
    local lock="$1" mode="$2"
    shift 2
    if [ -n "$lock" ]; then flock "$mode" "$lock" "$@"; else "$@"; fi
}

# Register new scripts and the extension's classes before the real run.
with_lock "${IMPORT_LOCK:-}" -x timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

status=0
for mutation in none hidden; do
    cmd=(timeout 600 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT"
        --resolution 1280x720 res://tests/homestead_probe.tscn)
    cmd=(flock "$GPU_LOCK" "${cmd[@]}")
    if [ -n "${ENGINE_LOCK:-}" ]; then cmd=(flock -s "$ENGINE_LOCK" "${cmd[@]}"); fi
    MUTATION="$mutation" OUT_DIR="$OUT_DIR" COLONIST="${COLONIST:-probe-colonist-1}" \
        "${cmd[@]}" </dev/null >>"$OUT_DIR/godot.log" 2>&1
    ec=$?
    echo "verify_homestead_site: probe mutation=$mutation exited $ec" >&2
    [ "$ec" -eq 0 ] || status=1
done

[ -s "$OUT_DIR/site.json" ] && [ -s "$OUT_DIR/site_hidden.json" ] && [ -s "$OUT_DIR/contact_sheet.png" ] \
    || { echo "verify_homestead_site: a probe wrote no record" >&2; exit 1; }
[ "$status" -eq 0 ] || exit 1
echo "verify_homestead_site: both records written" >&2
exit 0
