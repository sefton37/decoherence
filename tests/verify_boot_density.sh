#!/usr/bin/env bash
## tests/verify_boot_density.sh -- Spec #519 busier-boot measurement harness.
##
## Boots the REAL frontdoor (gate force-failed, so no model is needed; only the
## renderer on the Xvfb display) once per configuration and collects the probe's
## PROBE_DENSITY row into $OUT_DIR/summary.jsonl:
##   off,field_bar,ticker,wire_room,full_bus at 1920x1080, plus wire_room and
##   full_bus at 1280x720  = 7 rows (off = today's plain boot, the density and
##   timing baseline). Spec #541 adds calm_bus at both sizes = 9 rows in all.
## Each row carries layout rects, overlap count, mean active panel cells, unique
## frames, boot time to shell_ready, lamp state, and palette pixel fractions.
##
## Env: OUT_DIR (required), DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_boot_density: OUT_DIR is required}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR"
: > "$OUT_DIR/summary.jsonl"

[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "verify_boot_density: display $DISPLAY not available" >&2; exit 2; }
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# Scratch user dir (settings.json, pid file) lives under OUT_DIR so Kel's real user:// is never touched.
export XDG_DATA_HOME="$OUT_DIR/xdg"
mkdir -p "$XDG_DATA_HOME"
fail=0
run_one() {
    local preset="$1" size="$2"
    local raw="$OUT_DIR/raw_${preset}_${size}.log"
    DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=density DECOHERENCE_FORCE_GATE_FAIL=1 \
        DECOHERENCE_BOOT_PRESET="$preset" \
        timeout 200 "$GODOT" --path "$REPO_ROOT" --resolution "$size" </dev/null >"$raw" 2>&1
    local ec=$?
    local line
    line="$(grep -m1 '^PROBE_DENSITY ' "$raw" | sed 's/^PROBE_DENSITY //')"
    if [ -z "$line" ]; then
        echo "verify_boot_density: no PROBE_DENSITY row for $preset $size (godot exit $ec)" >&2
        fail=1
        return
    fi
    printf '%s\n' "$line" >> "$OUT_DIR/summary.jsonl"
    echo "verify_boot_density: $preset $size ok (godot exit $ec)" >&2
}

for preset in off field_bar ticker wire_room full_bus; do
    run_one "$preset" 1920x1080
done
run_one wire_room 1280x720
run_one full_bus 1280x720
## Spec #541: the calm default, at both sizes (9 rows in all).
run_one calm_bus 1920x1080
run_one calm_bus 1280x720

exit "$fail"
