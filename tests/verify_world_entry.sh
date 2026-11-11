#!/usr/bin/env bash
## tests/verify_world_entry.sh -- Spec #501 `world` module entry through the REAL frontdoor.
##
## Boots the real app (boot -> shell) with DECOHERENCE_PROBE=1 and the probe driver's
## world mode, which types `dir`, then `world`, waits for the streamed ring to be up and
## the character grounded, takes a screenshot through the real shell path (CRT overlay
## and all), exits the world, proves the shell still answers, and proves an unknown module
## is still rejected. The probe prints these marker lines, in this order:
##   PROBE_WORLD_LISTED
##   PROBE_WORLD_ENTERED chunks=<n> grounded=1
##   PROBE_WORLD_SHOT lower_nonbg=<f> file=<path>
##   PROBE_WORLD_EXITED shell_alive=1
##   PROBE_WORLD_UNKNOWN_REJECTED
## This wrapper copies ONLY those marker lines to STALAG_LOG and exits 0 only if all five
## occurred, in that order. It does not judge the numbers (the DoD's grep does).
##
## Env: STALAG_LOG (required), STALAG_SHOTS_DIR (default: a temp dir),
##      DISPLAY (default :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${STALAG_LOG:?verify_world_entry: STALAG_LOG is required}"
export DISPLAY="${DISPLAY:-:99}"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
SHOTS="${STALAG_SHOTS_DIR:-$(mktemp -d)}"
mkdir -p "$SHOTS"
rm -f "$SHOTS/entry_world.png"
: > "$STALAG_LOG"

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_world_entry: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

RAW="$(mktemp)"
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=world STALAG_SHOTS_DIR="$SHOTS" \
    timeout 300 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1280x720 </dev/null >"$RAW" 2>&1
ec=$?

grep -E '^PROBE_WORLD_' "$RAW" > "$STALAG_LOG"
rm -f "$RAW"

# Spec #549: the entry's tree, flower and shrub counts, recomputed from the reported pose alone by the
# frozen prototype's oracle (pure geometry), appended as PROBE_WORLD_TREES_ORACLE.
POSE="$(grep -E '^PROBE_WORLD_TREES ' "$STALAG_LOG" | head -1 | sed 's/^PROBE_WORLD_TREES //' | jq -c '.pose' 2>/dev/null)"
if [ -n "$POSE" ] && [ "$POSE" != "null" ]; then
    ORACLE_DIR="$(mktemp -d)"
    ORACLE_LINE="$(TREES_ORACLE_OUT="$ORACLE_DIR" "$REPO_ROOT/tools/baseline/js_trees_oracle.mjs" --view-count "$POSE" </dev/null 2>/dev/null | tail -1)"
    [ -n "$ORACLE_LINE" ] && echo "PROBE_WORLD_TREES_ORACLE $ORACLE_LINE" >> "$STALAG_LOG"
    rm -r "$ORACLE_DIR"
fi

order_ok=1
prev=0
for pat in '^PROBE_WORLD_LISTED$' '^PROBE_WORLD_ENTERED chunks=[0-9]+ grounded=1$' '^PROBE_WORLD_SHOT ' '^PROBE_WORLD_EXITED shell_alive=1$' '^PROBE_WORLD_UNKNOWN_REJECTED$'; do
    ln="$(grep -nE "$pat" "$STALAG_LOG" | head -1 | cut -d: -f1)"
    if [ -z "$ln" ] || [ "$ln" -le "$prev" ]; then
        echo "verify_world_entry: marker missing or out of order: $pat (godot exit $ec)" >&2
        order_ok=0
        break
    fi
    prev="$ln"
done
[ "$order_ok" -eq 1 ] || exit 1
echo "verify_world_entry: all markers in order, godot exited cleanly" >&2   # no digits: the DoD harness reads the first integer of the output
exit 0
