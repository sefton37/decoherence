#!/usr/bin/env bash
## tests/verify_boot_gallery.sh -- Spec #519 gallery harness.
##
## Runs DECOHERENCE_BOOT_GALLERY=1 twice (the PROBE_RENDERED transcript plus the
## PROBE_GALLERY_TREATMENT lines go to run1.txt / run2.txt, which must be
## byte-identical), saves one screenshot per treatment from run 1, then proves
## the older DECOHERENCE_ANIM_GALLERY=1 mode still works. Markers on stdout:
##   GALLERY_BYTE_IDENTICAL, ANIM_GALLERY_STILL_OK
## Env: OUT_DIR (required), DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_boot_gallery: OUT_DIR is required}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR/shots"

[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "verify_boot_gallery: display $DISPLAY not available" >&2; exit 2; }
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

export XDG_DATA_HOME="$OUT_DIR/xdg"
mkdir -p "$XDG_DATA_HOME"
for n in 1 2; do
    shots=""
    [ "$n" -eq 1 ] && shots="$OUT_DIR/shots"
    DECOHERENCE_PROBE=1 DECOHERENCE_BOOT_GALLERY=1 DECOHERENCE_GALLERY_SHOTS="$shots" \
        timeout 200 "$GODOT" --path "$REPO_ROOT" --resolution 1920x1080 </dev/null >"$OUT_DIR/raw$n.log" 2>&1
    ec=$?
    grep -E '^(PROBE_RENDERED: |PROBE_GALLERY_TREATMENT )' "$OUT_DIR/raw$n.log" > "$OUT_DIR/run$n.txt"
    echo "verify_boot_gallery: run $n godot exit $ec" >&2
    [ "$ec" -eq 0 ] || { echo "verify_boot_gallery: run $n failed" >&2; exit 1; }
done

if cmp -s "$OUT_DIR/run1.txt" "$OUT_DIR/run2.txt"; then
    echo "GALLERY_BYTE_IDENTICAL"
else
    echo "verify_boot_gallery: runs differ" >&2
    diff "$OUT_DIR/run1.txt" "$OUT_DIR/run2.txt" | head -20 >&2
    exit 1
fi

DECOHERENCE_PROBE=1 DECOHERENCE_ANIM_GALLERY=1 \
    timeout 120 "$GODOT" --path "$REPO_ROOT" --resolution 1280x720 </dev/null >"$OUT_DIR/anim.log" 2>&1
aec=$?
if [ "$aec" -eq 0 ] && grep -q '^PROBE_RENDERED: GALLERY COMPLETE' "$OUT_DIR/anim.log"; then
    echo "ANIM_GALLERY_STILL_OK"
else
    echo "verify_boot_gallery: ANIM gallery regressed (exit $aec)" >&2
    exit 1
fi
exit 0
