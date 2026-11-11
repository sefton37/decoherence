#!/usr/bin/env bash
## tests/verify_stalag_treeview.sh -- Spec #549 REAL-RENDERER forest, understory and crown-shadow
## measurement (DISPLAY=:99 only, never Kel's desktop).
##
## Runs the frozen prototype's oracle FRESH (tools/baseline/js_trees_oracle.mjs, tag prototype-final,
## clean-room primitives substituted) for the ring counts and the plan hash, then the real-renderer
## probe (engine/stalag/tests/treeview_probe.tscn) on the xvfb display, and writes the probe's record
## with the epoch and the mutation merged in. The record's keys are the contract of Spec #549
## section 4 (ring, seating, visibility, look, motion, wind_feed, perf, lifecycle, shots,
## understory_seating, understory_visibility, understory_look, understory_motion, shadows).
## This wrapper only MEASURES. Exit 0 means "ran to completion and wrote a record"; the DoD's jq
## judges. It deletes stale output first, so a failed run can never read as fresh.
##
## Env: TREEVIEW_OUT (required)       output JSON path
##      TREEVIEW_SHOTS_DIR            screenshot directory (default: a temp dir)
##      TREEVIEW_MUTATE               none | trees_hidden | float | sunk | wind_off | flutter_off | flutter_frozen |
##                                    alpha_solid | tint_flat | sync_trees | clock_split | shadows_off |
##                                    understory_hidden | tier_swap_render | shrub_flutter_off |
##                                    u_sprite_flip | u_float
##      DISPLAY (must be :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${TREEVIEW_OUT:?verify_stalag_treeview: TREEVIEW_OUT is required}"
export DISPLAY="${DISPLAY:-:99}"
[ "$DISPLAY" = ":99" ] || { echo "verify_stalag_treeview: DISPLAY must be :99 (got $DISPLAY)" >&2; exit 2; }
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
SHOTS="${TREEVIEW_SHOTS_DIR:-$(mktemp -d)}"
MUTATE="${TREEVIEW_MUTATE:-none}"
case "$MUTATE" in
    none|trees_hidden|float|sunk|wind_off|flutter_off|flutter_frozen|alpha_solid|tint_flat|sync_trees|clock_split) ;;
    shadows_off|understory_hidden|tier_swap_render|shrub_flutter_off|u_sprite_flip|u_float) ;;
    *) echo "verify_stalag_treeview: bad TREEVIEW_MUTATE '$MUTATE'" >&2; exit 2 ;;
esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_treeview: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -f "$TREEVIEW_OUT"
mkdir -p "$SHOTS"
find "$SHOTS" -maxdepth 1 -name '*.png' -delete

TREES_ORACLE_OUT="$WORK/oracle" "$REPO_ROOT/tools/baseline/js_trees_oracle.mjs" </dev/null >&2 \
    || { echo "verify_stalag_treeview: oracle failed" >&2; exit 1; }

# Scan once so class names and the extension are registered before the real run.
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

RAW="$WORK/raw.json"
TREEVIEW_PROBE_RAW="$RAW" TREEVIEW_SHOTS_DIR="$SHOTS" TREEVIEW_ORACLE_DIR="$WORK/oracle" TREEVIEW_MUTATE="$MUTATE" \
    timeout 1500 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1280x720 res://engine/stalag/tests/treeview_probe.tscn </dev/null >&2
ec=$?
if [ ! -s "$RAW" ]; then
    echo "verify_stalag_treeview: probe wrote no record (godot exit $ec)" >&2
    exit 1
fi
jq --arg mut "$MUTATE" '{generated_epoch: now, mutation: $mut, headless: false} + .' "$RAW" > "$TREEVIEW_OUT" \
    || { rm -f "$TREEVIEW_OUT"; exit 1; }
echo "verify_stalag_treeview: wrote ${TREEVIEW_OUT##*/} (mutation=$MUTATE, godot exit $ec)" >&2
exit 0
