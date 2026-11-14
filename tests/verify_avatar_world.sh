#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_avatar_world.sh -- Spec 581 S1 in-world probe wrapper for the player avatar.
##
## Runs res://tests/avatar_probe.tscn five times, each in its own process on a REAL renderer (never headless)
## on the test display: once as the player sees it (MUTATION=none -> avatar.json) and four negative controls
## that must fail the same predicates (hidden, capsule, frozen, float -> avatar_<mutation>.json). The shots
## go under OUT_DIR/shots*, the Godot log of every run to godot.log. This wrapper only MEASURES; exit 0 means
## every probe ran to completion and wrote its record. The DoD's jq judges.
##
## Env: OUT_DIR (required), XDG_DATA_HOME (default: a scratch dir, never the real user dir),
##      GPU_LOCK (default /tmp/decoh-gpu.lock; renders share one card, so they queue on it),
##      ENGINE_LOCK / IMPORT_LOCK (optional lock files: shared while the world is loaded, exclusive
##      around the editor import scan), COLONIST (default probe-colonist-1), GODOT

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_avatar_world: OUT_DIR is required}"
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
    || { echo "verify_avatar_world: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

MUTATIONS="none hidden capsule frozen float"
SHOT_IDS="handoff_idle follow_walk_mid follow_run close_min_boom side_walk front_idle"

# A stale record or still must never be read as a fresh one: empty every output first.
: > "$OUT_DIR/godot.log"
: > "$OUT_DIR/avatar.json"
for m in hidden capsule frozen float; do : > "$OUT_DIR/avatar_$m.json"; done
for m in $MUTATIONS; do
    dir="$OUT_DIR/shots"
    [ "$m" = none ] || dir="$OUT_DIR/shots_$m"
    n=0
    for id in $SHOT_IDS; do
        n=$((n + 1))
        [ -e "$dir/${n}_$id.png" ] && : > "$dir/${n}_$id.png"
    done
done

with_lock() {  # with_lock <lockfile-or-empty> <flock-mode> cmd...
    local lock="$1" mode="$2"
    shift 2
    if [ -n "$lock" ]; then flock "$mode" "$lock" "$@"; else "$@"; fi
}

# Register new scripts and the extension's classes before the real runs.
with_lock "${IMPORT_LOCK:-}" -x timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >>"$OUT_DIR/godot.log" 2>&1 || true

status=0
for mutation in $MUTATIONS; do
    cmd=(timeout 600 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT"
        --resolution 1280x720 res://tests/avatar_probe.tscn)
    cmd=(flock "$GPU_LOCK" "${cmd[@]}")
    if [ -n "${ENGINE_LOCK:-}" ]; then cmd=(flock -s "$ENGINE_LOCK" "${cmd[@]}"); fi
    MUTATION="$mutation" OUT_DIR="$OUT_DIR" COLONIST="${COLONIST:-probe-colonist-1}" \
        "${cmd[@]}" </dev/null >>"$OUT_DIR/godot.log" 2>&1
    ec=$?
    echo "verify_avatar_world: probe mutation=$mutation exited $ec" >&2
    [ "$ec" -eq 0 ] || status=1
done

for f in avatar avatar_hidden avatar_capsule avatar_frozen avatar_float; do
    [ -s "$OUT_DIR/$f.json" ] || { echo "verify_avatar_world: a probe wrote no $f.json" >&2; exit 1; }
done
[ "$status" -eq 0 ] || exit 1
echo "verify_avatar_world: all five records written" >&2
exit 0
