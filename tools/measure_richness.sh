#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
## tools/measure_richness.sh -- Spec 580: measure how rich, how far and how costly the Decoherence world looks.
##
## Renders three fixed poses (tools/scenic/bench_poses.json) from the REAL game world on a REAL renderer (never
## headless) with the game's own default look, then reads the world: chunks, instances, primitives, draw calls,
## video memory, draw distance in metres, species in frame, bare ground, and the crown colour families. The
## pixel statistics and the pass/fail judgement against tools/scenic/richness_bars.json are made by
## tools/scenic/post.py (mode `richness`). Exit 0 means every bar passed; a failing bar exits 1.
##
## Output (all under RICH_OUT): richness.json, bench-*.png (the three raw 1600x900 frames), raw.json, godot.log.
##
## It renders on the xvfb display :99 ONLY: any other DISPLAY is refused before Godot starts. User data, config
## and cache live in an isolated directory under /tmp, never in the real Decoherence user dir.
##
## Env: RICH_OUT (required)    output directory
##      RICH_VIEW              near | far | vista (default near): the game's view-distance level
##      RICH_MUTATE            none | thin | noskirt (default none): thin turns trees, meadow and understory off; noskirt
##                             removes the backdrop ring (both are controls)
##      RICH_XDG               isolated XDG base dir (default /tmp/decoh-richness-xdg-<uid>)
##      GPU_LOCK / ENGINE_LOCK / IMPORT_LOCK  lock files: the render queues exclusively on GPU_LOCK (one card),
##                             holds ENGINE_LOCK shared while the world is loaded, and takes IMPORT_LOCK
##                             exclusively around the editor import scan
##      GODOT                  the Godot binary (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${RICH_OUT:?measure_richness: RICH_OUT is required}"
export DISPLAY="${DISPLAY:-:99}"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
if [ "$DISPLAY" != ":99" ]; then
    echo "measure_richness: refusing DISPLAY=$DISPLAY (the real renderer runs on :99 only)" >&2
    exit 2
fi
RICH_VIEW="${RICH_VIEW:-near}"
RICH_MUTATE="${RICH_MUTATE:-none}"
case "$RICH_VIEW" in near|far|vista) ;; *) echo "measure_richness: bad RICH_VIEW '$RICH_VIEW'" >&2; exit 2 ;; esac
case "$RICH_MUTATE" in none|thin|noskirt) ;; *) echo "measure_richness: bad RICH_MUTATE '$RICH_MUTATE'" >&2; exit 2 ;; esac
export RICH_VIEW RICH_MUTATE
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
# The inherited XDG_DATA_HOME is ignored on purpose: it points at the real user's data.
RICH_XDG="${RICH_XDG:-/tmp/decoh-richness-xdg-$(id -u)}"
case "$RICH_XDG" in /tmp/*) ;; *) echo "measure_richness: RICH_XDG must be under /tmp/" >&2; exit 2 ;; esac
export XDG_DATA_HOME="$RICH_XDG/data" XDG_CONFIG_HOME="$RICH_XDG/config" XDG_CACHE_HOME="$RICH_XDG/cache"
GPU_LOCK="${GPU_LOCK:-/tmp/decoh-gpu.lock}"
ENGINE_LOCK="${ENGINE_LOCK:-/tmp/decoh-engine.lock}"
IMPORT_LOCK="${IMPORT_LOCK:-/tmp/decoh-import.lock}"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$RICH_OUT"
export RICH_OUT

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "measure_richness: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

# A stale frame or record must never be read as a fresh one: empty the output first.
rm -f "$RICH_OUT"/bench-*.png "$RICH_OUT"/edge-*.png "$RICH_OUT/richness.json" "$RICH_OUT/raw.json" "$RICH_OUT/godot.log"

# Register the new scripts and the extension's classes before the real run.
flock -x "$IMPORT_LOCK" timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

flock -s "$ENGINE_LOCK" flock "$GPU_LOCK" timeout 900 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1600x900 res://tools/scenic/richness_probe.tscn </dev/null >"$RICH_OUT/godot.log" 2>&1
ec=$?
if [ ! -s "$RICH_OUT/raw.json" ]; then
    echo "measure_richness: the probe wrote no record (godot exit $ec); log: $RICH_OUT/godot.log" >&2
    tail -n 20 "$RICH_OUT/godot.log" >&2
    exit 1
fi

python3 -I "$REPO_ROOT/tools/scenic/post.py" richness "$RICH_OUT"
pec=$?
echo "measure_richness: wrote $RICH_OUT/richness.json (view=$RICH_VIEW mutate=$RICH_MUTATE godot exit $ec, bars exit $pec)" >&2
exit "$pec"
