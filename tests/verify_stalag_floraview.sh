#!/usr/bin/env bash
## tests/verify_stalag_floraview.sh -- Spec #545 REAL-RENDERER flora measurement (DISPLAY=:99 only).
##
## Runs the oracle fresh (per-chunk instance counts and the plan hash), then launches
## res://engine/stalag/tests/floraview_probe.tscn with the real renderer (NOT headless) on the
## xvfb display. The probe reads the MultiMesh buffers the renderer was given, rays them against
## the chunk meshes, compares rendered frames with the flora shown and hidden, renders isolated
## sprites and rocks, and runs a flora-on / flora-off walk. It only MEASURES; the DoD's jq judges.
## It deletes any stale output first, so a failed run can never read as fresh.
##   {generated_epoch, mutation, headless, adapter, project_name, classes, plan, ring, seating,
##    sprites[6], rocks, visibility{poses[]}, motion, perf{on, off, adopt}, lifecycle, shots[]}
##
## Env: FLORAVIEW_OUT (required)        output JSON path
##      FLORAVIEW_SHOTS_DIR             screenshot directory (default: a temp dir)
##      FLORAVIEW_MUTATE                none | flora_hidden | float | sunk | wind_off | sprite_flip | rock_srgb | sync_flora
##      DISPLAY (must be :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${FLORAVIEW_OUT:?verify_stalag_floraview: FLORAVIEW_OUT is required}"
export DISPLAY="${DISPLAY:-:99}"
[ "$DISPLAY" = ":99" ] || { echo "verify_stalag_floraview: DISPLAY must be :99 (got $DISPLAY)" >&2; exit 2; }
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
SHOTS="${FLORAVIEW_SHOTS_DIR:-$(mktemp -d)}"
MUTATE="${FLORAVIEW_MUTATE:-none}"
case "$MUTATE" in none|flora_hidden|float|sunk|wind_off|sprite_flip|rock_srgb|sync_flora) ;; *) echo "verify_stalag_floraview: bad FLORAVIEW_MUTATE '$MUTATE'" >&2; exit 2 ;; esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_floraview: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -f "$FLORAVIEW_OUT"
mkdir -p "$SHOTS"
find "$SHOTS" -maxdepth 1 -name '*.png' -delete

FLORA_ORACLE_OUT="$WORK/oracle" "$REPO_ROOT/tools/baseline/js_flora_oracle.mjs" </dev/null >&2 \
    || { echo "verify_stalag_floraview: oracle failed" >&2; exit 1; }

# Scan once so class names and the extension are registered before the real run.
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

RAW="$WORK/raw.json"
FLORAVIEW_PROBE_RAW="$RAW" FLORAVIEW_SHOTS_DIR="$SHOTS" FLORAVIEW_ORACLE_DIR="$WORK/oracle" FLORAVIEW_MUTATE="$MUTATE" \
    timeout 1500 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1280x720 res://engine/stalag/tests/floraview_probe.tscn </dev/null >&2
ec=$?
if [ ! -s "$RAW" ]; then
    echo "verify_stalag_floraview: probe wrote no record (godot exit $ec)" >&2
    exit 1
fi
jq --arg mut "$MUTATE" '{generated_epoch: now, mutation: $mut, headless: false} + .' "$RAW" > "$FLORAVIEW_OUT" \
    || { rm -f "$FLORAVIEW_OUT"; exit 1; }
echo "verify_stalag_floraview: wrote ${FLORAVIEW_OUT##*/} (mutation=$MUTATE, godot exit $ec)" >&2
exit 0
