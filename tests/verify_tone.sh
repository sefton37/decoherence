#!/usr/bin/env bash
## tests/verify_tone.sh -- Spec #541 tone measurement through the real frontdoor.
##
## Boots the REAL frontdoor (gate force-failed, so no model is needed; only the
## renderer on the Xvfb display) at 1920x1080 and runs probe mode `tone`, which
## measures RENDERED pixels: backdrop luma, terminal text vs chrome luma, the
## input-row bar, the cursor blink (3 s of pixel samples at the cursor cell,
## plus a flat negative control), solid-while-typing, and the player-line echo.
## Writes $OUT_DIR/tone.json (and tone.png).
##
## Env: OUT_DIR (required), DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_tone: OUT_DIR is required}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR"
## A stale result must never satisfy this run: clear the artefacts first.
: > "$OUT_DIR/tone.json"
[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "verify_tone: display $DISPLAY not available" >&2; exit 2; }
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# Scratch user dir (settings.json, pid file) lives under OUT_DIR so the real user:// is never touched.
export XDG_DATA_HOME="$OUT_DIR/xdg_$$"
mkdir -p "$XDG_DATA_HOME"

DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=tone DECOHERENCE_FORCE_GATE_FAIL=1 \
    DECOHERENCE_PROBE_OUT_DIR="$OUT_DIR" \
    timeout 300 "$GODOT" --path "$REPO_ROOT" --resolution 1920x1080 </dev/null >"$OUT_DIR/tone.log" 2>&1
ec=$?
grep -E '^PROBE_TONE ' "$OUT_DIR/tone.log" >&2 || echo "verify_tone: no PROBE_TONE row (godot exit $ec)" >&2
[ -s "$OUT_DIR/tone.json" ] || exit 1
exit "$ec"
