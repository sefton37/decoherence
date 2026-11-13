#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_water_bank.sh -- Spec #928 river-bank water MEASUREMENT (headless, CPU only).
##
## Runs engine/stalag/tests/water_bank_probe.gd on the engine's own world and writes its record
## (see the probe header for the definitions). This wrapper only MEASURES: exit 0 means "ran to
## completion and wrote a record"; the definition of done's jq judges. It clears any stale output
## first, so a failed run can never read as a fresh one.
##
## Env: WATERBANK_OUT (required)   output JSON path
##      WATERBANK_MUTATE           none | drop_all | punch | sink | lift | far_nudge | zone_nudge | flow_leak
##                                 | wall_sheet | tile_break | drop_new | lift_new | max_pick | coplanar (negative controls) | ideal | naive_base (positive controls)
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${WATERBANK_OUT:?verify_water_bank: WATERBANK_OUT is required}"
MUTATE="${WATERBANK_MUTATE:-none}"
case "$MUTATE" in none|drop_all|punch|sink|lift|far_nudge|zone_nudge|flow_leak|wall_sheet|tile_break|drop_new|lift_new|max_pick|coplanar|ideal|naive_base) ;; *) echo "verify_water_bank: bad WATERBANK_MUTATE '$MUTATE'" >&2; exit 2 ;; esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_water_bank: engine library missing; run tools/build_engine.sh" >&2; exit 1; }
[ -f "$REPO_ROOT/engine/stalag/tests/fixtures/water_bank_baseline.json" ] \
    || { echo "verify_water_bank: baseline fixture missing" >&2; exit 1; }

# Headless never opens a window, but keep the desktop out of reach and the idle inhibitor off the bus.
unset WAYLAND_DISPLAY
export DISPLAY=:99
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus

: > "$WATERBANK_OUT"
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
WATERBANK_OUT="$WATERBANK_OUT" WATERBANK_MUTATE="$MUTATE" \
    timeout 900 "$GODOT" --audio-driver Dummy --headless --path "$REPO_ROOT" -s res://engine/stalag/tests/water_bank_probe.gd </dev/null >&2
[ -s "$WATERBANK_OUT" ] || { echo "verify_water_bank: probe wrote nothing" >&2; exit 1; }
echo "verify_water_bank: wrote $WATERBANK_OUT (mutation=$MUTATE)" >&2
