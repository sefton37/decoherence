#!/usr/bin/env bash
## tests/verify_stalag_walk.sh -- Spec #501 walk MEASUREMENT in the MAIN project.
##
## Launches res://engine/stalag/tests/walk_probe.tscn with the real renderer (NOT
## headless) on the xvfb display, which scripts a walk through the real world scene
## (streamer + walker + follow camera) and writes one record:
##   {generated_epoch, mutation, headless, adapter, project_name, classes, scale,
##    streaming{...}, controller{...}, camera{...}, frame{baseline,walk}, screens[...]}
## This wrapper only MEASURES. Exit 0 means "the probe ran to completion and wrote a
## record"; the DoD's jq judges. It deletes any stale STALAG_OUT first so a failed run
## can never be read as a fresh one.
##
## Env: STALAG_OUT (required)         output JSON path
##      STALAG_SHOTS_DIR              screenshot directory (default: a temp dir)
##      STALAG_MUTATE                 none | sync_build | float | sink (negative controls)
##      DISPLAY (default :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${STALAG_OUT:?verify_stalag_walk: STALAG_OUT is required}"
export DISPLAY="${DISPLAY:-:99}"
SHOTS="${STALAG_SHOTS_DIR:-$(mktemp -d)}"
MUTATE="${STALAG_MUTATE:-none}"
case "$MUTATE" in none|sync_build|float|sink) ;; *) echo "verify_stalag_walk: bad STALAG_MUTATE '$MUTATE'" >&2; exit 2 ;; esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_walk: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

RAW="$(mktemp)"
rm -f "$STALAG_OUT" "$RAW"
mkdir -p "$SHOTS"
find "$SHOTS" -maxdepth 1 -name 'screen_*.png' -delete

# Scan once so class names / the extension are registered before the real run.
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

STALAG_PROBE_RAW="$RAW" STALAG_SHOTS_DIR="$SHOTS" STALAG_MUTATE="$MUTATE" \
    timeout 900 "$GODOT" --path "$REPO_ROOT" --resolution 1280x720 res://engine/stalag/tests/walk_probe.tscn </dev/null >&2
ec=$?

if [ ! -s "$RAW" ]; then
    echo "verify_stalag_walk: probe wrote no record (godot exit $ec)" >&2
    rm -f "$RAW"
    exit 1
fi
jq . "$RAW" > "$STALAG_OUT"
rm -f "$RAW"
echo "verify_stalag_walk: wrote ${STALAG_OUT##*/} (mutation=$MUTATE, godot exit $ec)" >&2
exit 0
