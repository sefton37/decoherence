#!/usr/bin/env bash
## tests/verify_handler.sh -- Spec #575 HANDLER module end to end through the REAL frontdoor.
##
## MODE selects what the probe drives (every action is a real InputEventKey or
## InputEventMouseButton into the viewport; the model is a loopback fake):
##   handler_flow       the funnel played to its end, then the module: entry, content, the accept
##                      control, the launch seam, the boundary attacks, scroll and focus      (1280x720)
##   handler_resume     restarts: before and after the mission was accepted, locked and unlocked,
##                      a damaged profile, the model down, Esc; then the frozen colonist       (1280x720)
##   handler_mutate     every player-visible word is data: the data copied with a marker      (1920x1080)
##   handler_layout     geometry, screenshot pixels, instrument controls and resize at
##                      1280x720, 1920x1080 and 3840x2160 (content-scaled)
##   handler_states     a screenshot per state, read back for text, lit rows and palette      (1280x720)
##   handler_world      the real engine entered through the route, then left                  (1280x720)
##   handler_isolation  the probe's user:// is a scratch dir, off-screen, with dummy audio     (no boot)
## Each mode writes $OUT_DIR/<MODE>.json (layout writes layout_<WxH>.json and layout_<WxH>.png) with
## exactly the keys the DoD reads. This wrapper judges nothing; the DoD's jq does.
##
## Isolation: DISPLAY is pinned to :99, WAYLAND_DISPLAY is unset, the session bus is a dead path,
## audio is the dummy driver, and XDG_DATA_HOME is forced to a fresh directory under $OUT_DIR
## (xdg.XXXXXX), so a run never reads another run's profile. A caller-supplied XDG_DATA_HOME under
## the real user data dir is REFUSED (exit 2) before anything starts.
##
## Env: MODE (required), OUT_DIR (required), DECOH_IMPORT_LOCK (optional lock file that serialises
##      the class-cache rescan), DECOH_ENGINE_LOCK (optional lock file held shared while a mode that
##      loads the world runs), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${MODE:?verify_handler: MODE is required}"
: "${OUT_DIR:?verify_handler: OUT_DIR is required}"
case "${XDG_DATA_HOME:-}" in
    "$HOME/.local/share"*) echo "verify_handler: refusing to use the real user data dir" >&2; exit 2 ;;
esac
export DISPLAY=":99"
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
mkdir -p "$OUT_DIR"
[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "PRECONDITION-UNMET: display $DISPLAY not available" >&2; exit 2; }

fresh_xdg() {
    # fresh_xdg: a new empty user data dir under OUT_DIR, exported as XDG_DATA_HOME
    XDG_DATA_HOME="$(mktemp -d "$OUT_DIR/xdg.XXXXXX")"
    export XDG_DATA_HOME
}

FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
trap cleanup EXIT

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

start_fake() {
    # start_fake <tag>: the loopback fake contact model; sets FAKE_PORT, FAKE_LOG, FAKE_MODE_FILE
    FAKE_PORT="$(free_port)"
    FAKE_LOG="$OUT_DIR/fake_$1.jsonl"
    FAKE_MODE_FILE="$OUT_DIR/fake_$1.mode"
    : > "$FAKE_LOG"
    echo ok > "$FAKE_MODE_FILE"
    python3 "$REPO_ROOT/tests/fake_handler.py" --port "$FAKE_PORT" --out "$FAKE_LOG" --mode-file "$FAKE_MODE_FILE" > "$OUT_DIR/fake_$1.out" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 50); do
        curl -fsS "http://127.0.0.1:$FAKE_PORT/api/tags" > /dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "verify_handler: fake model did not come up" >&2
    exit 1
}

stop_fake() { cleanup; FAKE_PID=""; }

run_probe() {
    # run_probe <probe_mode> <log_tag> <timeout_s> <resolution> [VAR=value ...]
    local pmode="$1" tag="$2" tmo="$3" res="$4"
    shift 4
    local lock=()
    if [ "$pmode" = "handler_world" ] && [ -n "${DECOH_ENGINE_LOCK:-}" ]; then
        lock=(flock -s "$DECOH_ENGINE_LOCK")
    fi
    env DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE="$pmode" DECOHERENCE_PROBE_OUT_DIR="$OUT_DIR" \
        DECOHERENCE_OLLAMA_PORT="$FAKE_PORT" CHATROOM_FAKE_LOG="$FAKE_LOG" CHATROOM_FAKE_MODE_FILE="$FAKE_MODE_FILE" "$@" \
        "${lock[@]}" timeout "$tmo" "$GODOT" --display-driver x11 --audio-driver Dummy --path "$REPO_ROOT" --resolution "$res" </dev/null > "$OUT_DIR/$tag.log" 2>&1
    return $?
}

## New class_name files are invisible to a run until the editor has registered them.
export XDG_DATA_HOME="$(mktemp -d "$OUT_DIR/xdg.XXXXXX")"
${DECOH_IMPORT_LOCK:+flock "$DECOH_IMPORT_LOCK"} timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null > /dev/null 2>&1 || true
: > "$OUT_DIR/$MODE.json"
ec=0

case "$MODE" in
    handler_flow|handler_mutate|handler_states|handler_world)
        res="1280x720"
        [ "$MODE" = "handler_mutate" ] && res="1920x1080"
        fresh_xdg
        start_fake "$MODE"
        run_probe "$MODE" "$MODE" 900 "$res"; ec=$?
        ;;
    handler_resume)
        # a profile that predates the module: finished the funnel, has a handle, holds no colonist
        fresh_xdg
        UD="$XDG_DATA_HOME/godot/app_userdata/$(sed -n 's/^config\/name="\(.*\)"/\1/p' "$REPO_ROOT/project.godot" | head -1)"
        mkdir -p "$UD"
        printf '%s' '{"schema":1,"player":{"designation":"newb4821","handle":"Ember_77"},"handler":{"name":"KIRN-17","kind":"empire","former":[]},"acceptance":{"accepted":true,"handler":"KIRN-17","handle":"Ember_77","launched":true},"assignments":[]}' > "$UD/profile.json"
        cp "$UD/profile.json" "$OUT_DIR/legacy_profile.json"
        start_fake "$MODE"
        run_probe "$MODE" "$MODE" 900 1280x720 HANDLER_PROBE_LEGACY="$OUT_DIR/legacy_profile.json"; ec=$?
        ;;
    handler_layout)
        for size in 1280x720 1920x1080 3840x2160; do
            # a stale result must never satisfy this run: empty the artefacts first
            : > "$OUT_DIR/layout_$size.json"
            : > "$OUT_DIR/layout_$size.png"
            fresh_xdg
            start_fake "layout_$size"
            resize=0
            [ "$size" = "1280x720" ] && resize=1
            run_probe handler_layout "layout_$size" 600 "$size" HANDLER_RESIZE="$resize"; e=$?
            [ "$e" -eq 0 ] || ec=$e
            stop_fake
            [ -s "$OUT_DIR/layout_$size.json" ] && [ -s "$OUT_DIR/layout_$size.png" ] \
                || { echo "verify_handler: no layout output for $size (see $OUT_DIR)" >&2; exit 1; }
        done
        echo '{"sizes": ["1280x720", "1920x1080", "3840x2160"]}' > "$OUT_DIR/handler_layout.json"
        ;;
    handler_isolation)
        fresh_xdg
        start_fake "$MODE"
        run_probe "$MODE" "$MODE" 120 1280x720; ec=$?
        ;;
    *) echo "verify_handler: unknown MODE $MODE" >&2; exit 2 ;;
esac

[ -s "$OUT_DIR/$MODE.json" ] || { echo "verify_handler: no $MODE.json produced" >&2; exit 1; }
echo "verify_handler: $MODE finished (probe exit $ec)" >&2
exit "$ec"
