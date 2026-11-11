#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_grass_look.sh -- Spec #551 phase 1: the meadow ground, measured through the REAL
## world entry. The frozen Stalag prototype (tag prototype-final) drew one grass tile on a grid;
## this wrapper boots the real app exactly as tests/verify_world_entry.sh does
## (DECOHERENCE_PROBE=1, mode world: `dir`, `world`, entry shot through the CRT overlay), and
## with GRASS_OUT set the probe driver runs engine/stalag/tests/grass_probe.gd after the entry
## shot. This wrapper only MEASURES: exit 0 means the entry ran to completion with all five
## markers in order; the numbers are judged by the stored checks.
##
## Env: GRASS_OUT (required: the JSON record), GRASS_LOG (required: the five marker lines),
##      STALAG_SHOTS_DIR (default: a temp dir), GRASS_MUTATE = none | single_variant | old_shader |
##      no_decals | no_tint | smooth_tint | unsnapped_tint | burn, and the phase 2 controls (Spec #551)
##      mask_off | wall_rotate | fields_swapped | no_fields | mud_black | old_dirt_wall (a negative control,
##      read by the probe only), DISPLAY (default :99), GODOT (default ~/.local/bin/godot)
## Phase 2 adds the record's .ground section (the ground materials and the flora exclusion). On an
## unmutated run this wrapper also runs the independent JS filter (tools/bake_ground_fields.mjs
## oracle-flora) over the chunks the probe reports and merges its counts beside the probe's.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${GRASS_OUT:?verify_grass_look: GRASS_OUT is required}"
: "${GRASS_LOG:?verify_grass_look: GRASS_LOG is required}"
export DISPLAY="${DISPLAY:-:99}"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
if [ "$DISPLAY" != ":99" ]; then
    echo "verify_grass_look: refusing DISPLAY=$DISPLAY (the real renderer runs on :99 only)" >&2
    exit 1
fi
SHOTS="${STALAG_SHOTS_DIR:-$(mktemp -d)}"
mkdir -p "$SHOTS"
rm -f "$SHOTS/entry_world.png" "$SHOTS"/grass_entry_new.png "$SHOTS"/grass_entry_old.png "$SHOTS"/grass_nadir_new.png "$SHOTS"/grass_nadir_old.png
: > "$GRASS_OUT"
: > "$GRASS_LOG"

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_grass_look: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

RAW="$(mktemp)"
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=world STALAG_SHOTS_DIR="$SHOTS" GRASS_OUT="$GRASS_OUT" GRASS_MUTATE="${GRASS_MUTATE:-none}" \
    timeout 600 "$GODOT" --audio-driver Dummy --display-driver x11 --path "$REPO_ROOT" --resolution 1280x720 </dev/null >"$RAW" 2>&1
ec=$?

grep -E '^PROBE_WORLD_' "$RAW" > "$GRASS_LOG"
ERRS="$(grep -cE 'SCRIPT ERROR|SHADER ERROR|Parse Error|Shader compilation failed' "$RAW")"
[ "$ERRS" -eq 0 ] || grep -E 'SCRIPT ERROR|SHADER ERROR|Parse Error|Shader compilation failed' "$RAW" | head -5 >&2
rm -f "$RAW"

order_ok=1
prev=0
for pat in '^PROBE_WORLD_LISTED$' '^PROBE_WORLD_ENTERED chunks=[0-9]+ grounded=1$' '^PROBE_WORLD_SHOT ' '^PROBE_WORLD_EXITED shell_alive=1$' '^PROBE_WORLD_UNKNOWN_REJECTED$'; do
    ln="$(grep -nE "$pat" "$GRASS_LOG" | head -1 | cut -d: -f1)"
    if [ -z "$ln" ] || [ "$ln" -le "$prev" ]; then
        echo "verify_grass_look: marker missing or out of order: $pat (godot exit $ec)" >&2
        order_ok=0
        break
    fi
    prev="$ln"
done

# Merge what only the wrapper knows (the markers, the error count) into the probe's record.
if [ -s "$GRASS_OUT" ]; then
    LISTED=false; grep -qE '^PROBE_WORLD_LISTED$' "$GRASS_LOG" && LISTED=true
    ENTERED=false; GROUNDED=false; CHUNKS=0
    L="$(grep -E '^PROBE_WORLD_ENTERED ' "$GRASS_LOG" | head -1)"
    if [ -n "$L" ]; then
        ENTERED=true
        CHUNKS="$(echo "$L" | sed -E 's/.*chunks=([0-9]+).*/\1/')"
        echo "$L" | grep -q 'grounded=1' && GROUNDED=true
    fi
    ORDER=false; [ "$order_ok" -eq 1 ] && ORDER=true
    MERGED="$(mktemp)"
    jq --argjson listed "$LISTED" --argjson entered "$ENTERED" --argjson grounded "$GROUNDED" --argjson chunks "$CHUNKS" \
        --argjson order "$ORDER" --argjson errs "$ERRS" \
        '.entry += {listed: $listed, entered: $entered, grounded: $grounded, chunks: $chunks, markers_in_order: $order} | .log = {shader_script_errors: $errs}' \
        "$GRASS_OUT" > "$MERGED" && cp "$MERGED" "$GRASS_OUT"
    rm -f "$MERGED"
    # Phase 2: the independent JS filter of the flora and understory over the ring the probe reports
    # (unmutated runs only; the oracle needs no GPU and is deterministic).
    if [ "${GRASS_MUTATE:-none}" = none ] && jq -e '(.ground.flora.ring_chunks // []) | length > 0' "$GRASS_OUT" >/dev/null 2>&1; then
        CHUNKS_JSON="$(mktemp)"; ORACLE_OUT="$(mktemp)"; MERGED="$(mktemp)"
        jq '{chunks: .ground.flora.ring_chunks}' "$GRASS_OUT" > "$CHUNKS_JSON"
        if "$REPO_ROOT/tools/bake_ground_fields.mjs" oracle-flora "$REPO_ROOT/game/world/assets/ground" "$CHUNKS_JSON" </dev/null 2>/dev/null | tail -n 1 > "$ORACLE_OUT" && jq -e '.filtered_total' "$ORACLE_OUT" >/dev/null 2>&1; then
            jq --slurpfile o "$ORACLE_OUT" \
                '.ground.flora += {oracle_filtered: $o[0].filtered_total, oracle_unfiltered: $o[0].unfiltered_total, oracle_meadow_filtered: $o[0].meadow, oracle_understory_filtered: ($o[0].flowers + $o[0].shrubs), oracle_removed_meadow: $o[0].removed_meadow, oracle_removed_understory: $o[0].removed_understory, oracle_flowers_filtered: $o[0].flowers, oracle_shrubs_filtered: $o[0].shrubs, oracle_per_form: $o[0].per_form, per_form_equals_oracle: (.ground.flora.per_form == $o[0].per_form)}' \
                "$GRASS_OUT" > "$MERGED" && cp "$MERGED" "$GRASS_OUT"
        else
            echo "verify_grass_look: the flora oracle failed" >&2
        fi
        rm -f "$CHUNKS_JSON" "$ORACLE_OUT" "$MERGED"
    fi
else
    echo "verify_grass_look: the probe wrote no record (godot exit $ec)" >&2
    exit 1
fi
[ "$order_ok" -eq 1 ] || exit 1
echo "verify_grass_look: all markers in order, record written" >&2   # no digits: the DoD harness reads the first integer of the output
exit 0
