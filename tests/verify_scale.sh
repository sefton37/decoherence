#!/usr/bin/env bash
## tests/verify_scale.sh -- Spec #541 fullscreen content-scale measurement.
##
## Boots the REAL frontdoor (gate force-failed) once per window size on the Xvfb
## display and runs probe mode `scale`, writing $OUT_DIR/scale_<WxH>.json and
## scale_<WxH>.png for 1280x720, 1920x1080 and 3840x2160. The 1920x1080 run
## also drives the F11 / Alt+Enter toggle and writes $OUT_DIR/toggle.json.
## (A real 6144x3456 fullscreen cannot be measured on Xvfb; that is the
## user-observable check. The factor rule for it is in tests/ui_scale_unit.gd.)
##
## Env: OUT_DIR (required), DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_scale: OUT_DIR is required}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR"
[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "verify_scale: display $DISPLAY not available" >&2; exit 2; }
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

fail=0
for size in 1280x720 1920x1080 3840x2160; do
    # A stale result must never satisfy this run: empty the artefact first.
    : > "$OUT_DIR/scale_$size.json"
    # Fresh scratch user dir per run (settings.json, pid file) under OUT_DIR.
    export XDG_DATA_HOME="$OUT_DIR/xdg_${size}_$$"
    mkdir -p "$XDG_DATA_HOME"
    toggle=0
    if [ "$size" = "1920x1080" ]; then
        toggle=1
        : > "$OUT_DIR/toggle.json"
    fi
    DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=scale DECOHERENCE_FORCE_GATE_FAIL=1 \
        DECOHERENCE_PROBE_OUT_DIR="$OUT_DIR" DECOHERENCE_SCALE_TOGGLE="$toggle" \
        timeout 300 "$GODOT" --path "$REPO_ROOT" --resolution "$size" </dev/null >"$OUT_DIR/run_$size.log" 2>&1
    ec=$?
    if [ ! -s "$OUT_DIR/scale_$size.json" ]; then
        echo "verify_scale: no scale_$size.json (godot exit $ec)" >&2
        fail=1
    else
        echo "verify_scale: $size ok (godot exit $ec)" >&2
    fi
done
[ -s "$OUT_DIR/toggle.json" ] || { echo "verify_scale: no toggle.json" >&2; fail=1; }
exit "$fail"
