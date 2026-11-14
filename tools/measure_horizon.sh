#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
## tools/measure_horizon.sh -- Spec 582 S1: measure how far the Decoherence world really shows terrain.
##
## Renders five fixed poses (tools/scenic/horizon_poses.json) from the REAL game world on a REAL renderer (never
## headless), each as a lit frame, a depth frame and a sky-only frame, then reads the world: primitives, draw
## calls, video memory, the far terrain's height error against the engine's own surface, coverage, trees against
## the engine's placements, build cost and a 1,000 m traverse. tools/scenic/post.py (modes horizon and sheet) makes
## the pixel measurements and judges tools/scenic/horizon_bars.json. Exit 0 means every bar that applies to that
## configuration passed; a failing bar exits 1.
##
## Output (all under HZ_OUT): horizon.json (measure) or sheet.json and contact.png (sheet), the raw frames,
## raw.json, godot.log.
##
## It renders on the xvfb display :99 ONLY: any other DISPLAY is refused before Godot starts. User data, config
## and cache live in an isolated directory under /tmp, never in the real Decoherence user dir.
##
## Env: HZ_OUT (required)    output directory
##      HZ_VIEW              near | far | vista | horizon (default horizon): the game's view-distance level
##      HZ_ATMO              classic | clear | amber (default clear): the atmosphere preset
##      HZ_MODE              measure (default) | sheet (three presets at four poses, plus a contact sheet)
##      HZ_MUTATE            none (default) | nolod (no far terrain) | flat (flat far terrain) | fogwall (heavy fog)
##                           | noclouds (clouds off) | seam (far ground haze made a different colour)
##                           | noatmo (the atmosphere code bypassed); every one but none is a negative control
##      HZ_XDG               isolated XDG base dir (default /tmp/decoh-horizon-xdg-<uid>)
##      GPU_LOCK / ENGINE_LOCK / IMPORT_LOCK  lock files: the render queues exclusively on GPU_LOCK (one card),
##                           holds ENGINE_LOCK shared while the world is loaded, and takes IMPORT_LOCK
##                           exclusively around the editor import scan
##      GODOT                the Godot binary (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${HZ_OUT:?measure_horizon: HZ_OUT is required}"
export DISPLAY="${DISPLAY:-:99}"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
if [ "$DISPLAY" != ":99" ]; then
    echo "measure_horizon: refusing DISPLAY=$DISPLAY (the real renderer runs on :99 only)" >&2
    exit 2
fi
HZ_VIEW="${HZ_VIEW:-horizon}"
HZ_ATMO="${HZ_ATMO:-clear}"
HZ_MODE="${HZ_MODE:-measure}"
HZ_MUTATE="${HZ_MUTATE:-none}"
case "$HZ_VIEW" in near|far|vista|horizon) ;; *) echo "measure_horizon: bad HZ_VIEW '$HZ_VIEW'" >&2; exit 2 ;; esac
case "$HZ_ATMO" in classic|clear|amber) ;; *) echo "measure_horizon: bad HZ_ATMO '$HZ_ATMO'" >&2; exit 2 ;; esac
case "$HZ_MODE" in measure|sheet) ;; *) echo "measure_horizon: bad HZ_MODE '$HZ_MODE'" >&2; exit 2 ;; esac
case "$HZ_MUTATE" in none|nolod|flat|fogwall|noclouds|seam|noatmo) ;; *) echo "measure_horizon: bad HZ_MUTATE '$HZ_MUTATE'" >&2; exit 2 ;; esac
export HZ_VIEW HZ_ATMO HZ_MODE HZ_MUTATE
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
# The inherited XDG_DATA_HOME is ignored on purpose: it points at the real user's data.
HZ_XDG="${HZ_XDG:-/tmp/decoh-horizon-xdg-$(id -u)}"
case "$HZ_XDG" in /tmp/*) ;; *) echo "measure_horizon: HZ_XDG must be under /tmp/" >&2; exit 2 ;; esac
export XDG_DATA_HOME="$HZ_XDG/data" XDG_CONFIG_HOME="$HZ_XDG/config" XDG_CACHE_HOME="$HZ_XDG/cache"
GPU_LOCK="${GPU_LOCK:-/tmp/decoh-gpu.lock}"
ENGINE_LOCK="${ENGINE_LOCK:-/tmp/decoh-engine.lock}"
IMPORT_LOCK="${IMPORT_LOCK:-/tmp/decoh-import.lock}"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$HZ_OUT"
export HZ_OUT

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "measure_horizon: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

# A stale frame or record must never be read as a fresh one: empty the output first.
rm -f "$HZ_OUT"/hz-*.png "$HZ_OUT"/sheet-*.png "$HZ_OUT/contact.png" "$HZ_OUT/horizon.json" "$HZ_OUT/sheet.json" "$HZ_OUT/raw.json" "$HZ_OUT/godot.log"

# Register the new scripts and the extension's classes before the real run.
flock -x "$IMPORT_LOCK" timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

flock -s "$ENGINE_LOCK" flock "$GPU_LOCK" timeout 1500 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1600x900 res://tools/scenic/horizon_probe.tscn </dev/null >"$HZ_OUT/godot.log" 2>&1
ec=$?
if [ ! -s "$HZ_OUT/raw.json" ]; then
    echo "measure_horizon: the probe wrote no record (godot exit $ec); log: $HZ_OUT/godot.log" >&2
    tail -n 20 "$HZ_OUT/godot.log" >&2
    exit 1
fi

python3 -I "$REPO_ROOT/tools/scenic/post.py" "$([ "$HZ_MODE" = sheet ] && echo sheet || echo horizon)" "$HZ_OUT"
pec=$?
echo "measure_horizon: wrote $HZ_OUT (mode=$HZ_MODE view=$HZ_VIEW atmosphere=$HZ_ATMO mutate=$HZ_MUTATE godot exit $ec, post exit $pec)" >&2
exit "$pec"
