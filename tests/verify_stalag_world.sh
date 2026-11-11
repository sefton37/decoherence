#!/usr/bin/env bash
## tests/verify_stalag_world.sh -- Spec #517 world look MEASUREMENT in the MAIN project.
##
## Launches res://engine/stalag/tests/world_probe.tscn with the REAL renderer (NOT headless) on
## the xvfb display. The probe loads the same world scene the shell loads, then measures
##   plan readiness, rendered-terrain-vs-engine carved surface (down-rays), water placement /
##   ownership / burial, the skin (tile hashes + pixel change), sky colours, the fog factor from
##   pixels at 60 m and 150 m, shadows, a yaw sweep, and four named screenshots.
## Record: {generated_epoch, mutation, headless, adapter, project_name, classes, scale, plan,
##          ground, water, skin, sky, fog, shadow, sweep, shots[]}
## The tile hashes and the plan hash of the JS side come from the oracle run fresh here
## (tools/baseline/js_world_oracle.mjs, lite mode). This wrapper only MEASURES; exit 0 means
## "the probe ran to completion and wrote a record". It deletes stale output and the previous
## log first, so a failed run can never read as a fresh one. The Godot log is kept at
## $STALAG_SHOTS_DIR/godot.log.
##
## Env: STALAG_WORLD_OUT (required)   output JSON path
##      STALAG_SHOTS_DIR (required)   screenshot + log directory
##      STALAG_MUTATE                 none | water_off | water_sunk | tint_match | no_skin | no_fog | no_shadow | hole_punch
##      DISPLAY (default :99; other displays are refused unless STALAG_ALLOW_DISPLAY=1)
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${STALAG_WORLD_OUT:?verify_stalag_world: STALAG_WORLD_OUT is required}"
: "${STALAG_SHOTS_DIR:?verify_stalag_world: STALAG_SHOTS_DIR is required}"
export DISPLAY="${DISPLAY:-:99}"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
if [ "$DISPLAY" != ":99" ] && [ "${STALAG_ALLOW_DISPLAY:-0}" != "1" ]; then
    echo "verify_stalag_world: refusing DISPLAY=$DISPLAY (the real renderer runs on :99 only)" >&2
    exit 2
fi
MUTATE="${STALAG_MUTATE:-none}"
case "$MUTATE" in none|water_off|water_sunk|tint_match|no_skin|no_fog|no_shadow|hole_punch) ;; *) echo "verify_stalag_world: bad STALAG_MUTATE '$MUTATE'" >&2; exit 2 ;; esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_world: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -f "$STALAG_WORLD_OUT"
mkdir -p "$STALAG_SHOTS_DIR"
rm -f "$STALAG_SHOTS_DIR"/*.png "$STALAG_SHOTS_DIR/godot.log"

# 1. the oracle, fresh (lite: plan hash and tile hashes)
WORLD_ORACLE_LITE=1 WORLD_ORACLE_OUT="$WORK/oracle" "$REPO_ROOT/tools/baseline/js_world_oracle.mjs" </dev/null >&2 \
    || { echo "verify_stalag_world: oracle failed" >&2; exit 1; }

# 2. scan once so class names / the extension / imports are registered before the real run
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# 3. the probe, on the real renderer
STALAG_WORLD_RAW="$WORK/raw.json" STALAG_WORLD_ORACLE="$WORK/oracle" STALAG_SHOTS_DIR="$STALAG_SHOTS_DIR" STALAG_MUTATE="$MUTATE" \
    timeout 900 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1280x720 res://engine/stalag/tests/world_probe.tscn \
    </dev/null >"$STALAG_SHOTS_DIR/godot.log" 2>&1
ec=$?
if [ ! -s "$WORK/raw.json" ]; then
    echo "verify_stalag_world: probe wrote no record (godot exit $ec); log: $STALAG_SHOTS_DIR/godot.log" >&2
    tail -n 20 "$STALAG_SHOTS_DIR/godot.log" >&2
    exit 1
fi
jq '. + {generated_epoch: now}' "$WORK/raw.json" > "$STALAG_WORLD_OUT"
echo "verify_stalag_world: wrote ${STALAG_WORLD_OUT##*/} (mutation=$MUTATE, godot exit $ec)" >&2
exit 0
