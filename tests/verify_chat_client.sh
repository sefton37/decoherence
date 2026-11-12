#!/usr/bin/env bash
## tests/verify_chat_client.sh -- Spec #562 chat client end-to-end through the REAL frontdoor.
##
## MODE selects what the probe drives (every action is a real InputEventKey into the viewport):
##   features   entry and mount, nav bar, people, switching, directory, direct messages, unread,
##              the chat room itself, slash commands, every key, leaving, entry attacks (fake model)
##   canon      idle traffic in five rooms, the first-message trigger from four places, the model
##              boundary, the roster, what is drawn, the room after contact           (fake model)
##   layout     geometry, screenshot pixels, instrument controls and resize at 1280x720,
##              1920x1080 and 3840x2160 (content-scaled)                              (fake model)
##   leak_fake  #615: the send_chat stream path against a leaky NDJSON fake, and the contact path
##              through the client's own buffers                                       (fakes)
##   leak_live  #615: the same checks on the live model                                (live Ollama)
## Each mode writes $OUT_DIR/<MODE>.json (layout writes layout_<WxH>.json and layout_<WxH>.png)
## with exactly the keys the DoD reads. This wrapper judges nothing; the DoD's jq does.
##
## Env: MODE (required), OUT_DIR (required), XDG_DATA_HOME (default: $OUT_DIR/xdg),
##      DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${MODE:?verify_chat_client: MODE is required}"
: "${OUT_DIR:?verify_chat_client: OUT_DIR is required}"
## Off-screen only: never an inherited desktop display, never the session bus.
export DISPLAY=":99"
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
mkdir -p "$OUT_DIR"
: "${XDG_DATA_HOME:=$OUT_DIR/xdg}"
export XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME"
case "$XDG_DATA_HOME" in
    "$HOME/.local/share"*) echo "verify_chat_client: refusing to use the real user data dir" >&2; exit 2 ;;
esac
[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "PRECONDITION-UNMET: display $DISPLAY not available" >&2; exit 2; }

FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
trap cleanup EXIT

need_ollama() {
    if ! MAX_UTIL="${MAX_UTIL:-100}" "$REPO_ROOT/tests/ollama_ready.sh" >&2; then
        echo "PRECONDITION-UNMET: ollama_ready.sh refused (see UNMET line above)" >&2
        exit 2
    fi
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

wait_fake() {
    for _ in $(seq 1 50); do
        curl -fsS "http://127.0.0.1:$FAKE_PORT/api/tags" > /dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "verify_chat_client: fake model did not come up" >&2
    exit 1
}

start_fake() {
    # start_fake <tag>: the loopback fake contact model; sets FAKE_PORT, FAKE_LOG, FAKE_MODE_FILE
    FAKE_PORT="$(free_port)"
    FAKE_LOG="$OUT_DIR/fake_$1.jsonl"
    FAKE_MODE_FILE="$OUT_DIR/fake_$1.mode"
    : > "$FAKE_LOG"
    echo ok > "$FAKE_MODE_FILE"
    python3 "$REPO_ROOT/tests/fake_handler.py" --port "$FAKE_PORT" --out "$FAKE_LOG" --mode-file "$FAKE_MODE_FILE" > "$OUT_DIR/fake_$1.out" 2>&1 &
    FAKE_PID=$!
    wait_fake
}

start_stream_fake() {
    # start_stream_fake <tag> <mode>: the NDJSON streaming fake (ok, leaky_stream, benign_stream)
    FAKE_PORT="$(free_port)"
    FAKE_LOG="$OUT_DIR/fake_$1.jsonl"
    FAKE_MODE_FILE=""
    : > "$FAKE_LOG"
    python3 "$REPO_ROOT/tests/fake_ollama.py" --port "$FAKE_PORT" --out "$FAKE_LOG" --phase "$1" --mode "$2" > "$OUT_DIR/fake_$1.out" 2>&1 &
    FAKE_PID=$!
    wait_fake
}

stop_fake() { cleanup; FAKE_PID=""; }

run_probe() {
    # run_probe <probe_mode> <log_tag> <timeout_s> <resolution> [VAR=value ...]; uses FAKE_* when set
    local pmode="$1" tag="$2" tmo="$3" res="$4"
    shift 4
    local fake_env=()
    if [ -n "$FAKE_PID" ]; then
        fake_env=(DECOHERENCE_OLLAMA_PORT="$FAKE_PORT" CHATROOM_FAKE_LOG="$FAKE_LOG" SENDCHAT_FAKE_LOG="$FAKE_LOG")
        [ -n "$FAKE_MODE_FILE" ] && fake_env+=(CHATROOM_FAKE_MODE_FILE="$FAKE_MODE_FILE")
    fi
    env DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE="$pmode" DECOHERENCE_PROBE_OUT_DIR="$OUT_DIR" \
        DECOHERENCE_PROBE_SCREENSHOT="$OUT_DIR/${tag}_final.png" "${fake_env[@]}" "$@" \
        timeout "$tmo" "$GODOT" --display-driver x11 --audio-driver Dummy --path "$REPO_ROOT" --resolution "$res" </dev/null > "$OUT_DIR/$tag.log" 2>&1
    return $?
}

need_part() {
    # need_part <name>: the probe's part file must exist, be non-empty JSON and be newer than this run
    [ -s "$OUT_DIR/$1.part.json" ] && jq -e . "$OUT_DIR/$1.part.json" > /dev/null 2>&1 && [ "$OUT_DIR/$1.part.json" -nt "$OUT_DIR/.start" ] \
        || { echo "verify_chat_client: probe produced no fresh $1.part.json (see $OUT_DIR)" >&2; exit 1; }
}

## New class_name files are invisible to a run until the editor has registered them.
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null > /dev/null 2>&1 || true
touch "$OUT_DIR/.start"
: > "$OUT_DIR/$MODE.json"
ec=0

case "$MODE" in
    features)
        start_fake features
        run_probe chat_features features 1450 1920x1080; ec=$?
        need_part features
        cp "$OUT_DIR/features.part.json" "$OUT_DIR/features.json"
        ;;
    canon)
        start_fake canon
        # 1280x720: the narrowest game size, where a long reply from the model-backed thread must wrap
        run_probe chat_canon canon 1450 1280x720; ec=$?
        need_part canon
        cp "$OUT_DIR/canon.part.json" "$OUT_DIR/canon.json"
        ;;
    layout)
        for size in 1280x720 1920x1080 3840x2160; do
            # a stale result must never satisfy this run: empty the artefacts first
            : > "$OUT_DIR/layout_$size.json"
            : > "$OUT_DIR/layout_$size.png"
            start_fake "layout_$size"
            resize=0
            [ "$size" = "1280x720" ] && resize=1
            run_probe chat_layout "layout_$size" 400 "$size" DECOHERENCE_CHAT_RESIZE="$resize"; e=$?
            [ "$e" -eq 0 ] || ec=$e
            stop_fake
            [ -s "$OUT_DIR/layout_$size.json" ] && [ -s "$OUT_DIR/layout_$size.png" ] \
                || { echo "verify_chat_client: no layout output for $size (see $OUT_DIR)" >&2; exit 1; }
        done
        echo '{"sizes": ["1280x720", "1920x1080", "3840x2160"]}' > "$OUT_DIR/layout.json"
        ;;
    leak_fake)
        start_stream_fake sendchat_leaky leaky_stream
        run_probe chat_sendchat sendchat_leaky 400 1920x1080 SENDCHAT_VARIANT=leaky; ec=$?
        need_part sendchat_leaky
        stop_fake
        start_stream_fake sendchat_benign benign_stream
        run_probe chat_sendchat sendchat_benign 400 1920x1080 SENDCHAT_VARIANT=benign; e=$?
        [ "$e" -eq 0 ] || ec=$e
        need_part sendchat_benign
        stop_fake
        start_fake contact
        run_probe chat_contact_fake contact 900 1920x1080; e=$?
        [ "$e" -eq 0 ] || ec=$e
        need_part contact_fake
        stop_fake
        jq -n --slurpfile l "$OUT_DIR/sendchat_leaky.part.json" --slurpfile b "$OUT_DIR/sendchat_benign.part.json" --slurpfile c "$OUT_DIR/contact_fake.part.json" '{
            send_chat: ($l[0] + {benign_text_survives: $b[0].benign_text_survives}),
            contact: $c[0]}' > "$OUT_DIR/leak_fake.json"
        ;;
    leak_live)
        need_ollama
        run_probe chat_leak_live leak_live 1450 1920x1080; ec=$?
        need_part leak_live
        jq -n --slurpfile v "$OUT_DIR/leak_live.part.json" '{live: $v[0]}' > "$OUT_DIR/leak_live.json"
        ;;
    *) echo "verify_chat_client: unknown MODE $MODE" >&2; exit 2 ;;
esac

[ -s "$OUT_DIR/$MODE.json" ] || { echo "verify_chat_client: no $MODE.json produced" >&2; exit 1; }
echo "verify_chat_client: $MODE finished (probe exit $ec)" >&2
exit "$ec"
