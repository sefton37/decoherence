#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
## tools/render_scenic.sh -- Spec 577 S2a: the Decoherence scenic render tool.
##
## Renders the authored shots in tools/scenic/shots.json (12 candidates and 1 flat control) from the REAL
## game world on a REAL renderer (never headless), then post-processes them: pixel statistics, a pass/fail
## judgement against tools/scenic/thresholds.json, 1600 and 800 px WebP copies, a contact sheet and
## manifest.json. A better render later is a re-run of this script, not a one-off.
##
## Output (all under SCENIC_OUT): shot-<id>.png (the raw 1600x900 frame), shot-<id>-1600.webp,
## shot-<id>-800.webp, contact.png (the 12 candidates, labelled), manifest.json, godot.log.
##
## It renders on the xvfb display :99 ONLY: any other DISPLAY is refused before Godot starts, so no window
## can open on a desktop. User data, config and cache live in an isolated directory under /tmp, never in
## the real Decoherence user dir.
##
## Env: SCENIC_OUT (required)   output directory
##      SCENIC_ONLY             one shot id, a comma list of ids, @first (first candidate) or @control
##      SCENIC_SHOTS            an alternative shots.json (default: tools/scenic/shots.json)
##      SCENIC_XDG              isolated XDG base dir (default /tmp/decoh-scenic-xdg-<uid>)
##      GPU_LOCK                lock file the render queues on (default /tmp/decoh-gpu.lock; one card)
##      ENGINE_LOCK / IMPORT_LOCK  optional lock files: shared while the world is loaded, exclusive around
##                              the editor import scan
##      GODOT                   the Godot binary (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${SCENIC_OUT:?render_scenic: SCENIC_OUT is required}"
export DISPLAY="${DISPLAY:-:99}"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
if [ "$DISPLAY" != ":99" ]; then
    echo "render_scenic: refusing DISPLAY=$DISPLAY (the real renderer runs on :99 only)" >&2
    exit 2
fi
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
# The inherited XDG_DATA_HOME is ignored on purpose: it points at the real user's data.
SCENIC_XDG="${SCENIC_XDG:-/tmp/decoh-scenic-xdg-$(id -u)}"
case "$SCENIC_XDG" in /tmp/*) ;; *) echo "render_scenic: SCENIC_XDG must be under /tmp/" >&2; exit 2 ;; esac
export XDG_DATA_HOME="$SCENIC_XDG/data" XDG_CONFIG_HOME="$SCENIC_XDG/config" XDG_CACHE_HOME="$SCENIC_XDG/cache"
GPU_LOCK="${GPU_LOCK:-/tmp/decoh-gpu.lock}"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$SCENIC_OUT"
export SCENIC_OUT

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "render_scenic: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

# A stale frame or record must never be read as a fresh one: empty the output first.
rm -f "$SCENIC_OUT"/shot-*.png "$SCENIC_OUT"/shot-*.webp "$SCENIC_OUT"/aux-*.png "$SCENIC_OUT/contact.png" "$SCENIC_OUT/manifest.json" \
    "$SCENIC_OUT/raw.json" "$SCENIC_OUT/godot.log"

with_lock() {  # with_lock <lockfile-or-empty> <flock-mode> cmd...
    local lock="$1" mode="$2"
    shift 2
    if [ -n "$lock" ]; then flock "$mode" "$lock" "$@"; else "$@"; fi
}

# Register the new scripts and the extension's classes before the real run.
with_lock "${IMPORT_LOCK:-}" -x timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

cmd=(timeout 900 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1600x900 res://tools/scenic/scenic_shots.tscn)
cmd=(flock "$GPU_LOCK" "${cmd[@]}")
if [ -n "${ENGINE_LOCK:-}" ]; then cmd=(flock -s "$ENGINE_LOCK" "${cmd[@]}"); fi
"${cmd[@]}" </dev/null >"$SCENIC_OUT/godot.log" 2>&1
ec=$?
if [ ! -s "$SCENIC_OUT/raw.json" ]; then
    echo "render_scenic: the probe wrote no record (godot exit $ec); log: $SCENIC_OUT/godot.log" >&2
    tail -n 20 "$SCENIC_OUT/godot.log" >&2
    exit 1
fi

python3 -I "$REPO_ROOT/tools/scenic/post.py" finish "$SCENIC_OUT" || { echo "render_scenic: post-processing failed" >&2; exit 1; }
echo "render_scenic: wrote $SCENIC_OUT/manifest.json (godot exit $ec)" >&2
exit 0
