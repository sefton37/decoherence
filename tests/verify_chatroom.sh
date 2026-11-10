#!/usr/bin/env bash
## tests/verify_chatroom.sh -- Spec #542 chatroom end-to-end through the REAL frontdoor.
##
## MODE selects what the probe drives (every mode types through TerminalGrid's own
## line_submitted signal, the path a real Enter keypress takes):
##   flow     idle room, trigger negatives, first message, contact, lazy and asking
##            players, entry attacks, rendered-text scans        (fake model)
##   degrade  gate failure refuses; a mid-room outage degrades and recovers (fake model)
##   mutate   the room and the briefing are data: default / changed / legible-ratio-1
##            copies of the data directory (DECOHERENCE_CHATROOM_DIR)     (fake model)
##   leak     the #615 in-Godot think-leak check: three live runs with thinking-enabled
##            reasoning to compare against, plus three negative controls  (live Ollama + fake)
##   live     a keyword-asking scripted player on the live model, to the offer (live Ollama)
##   handoff  chat -> offer -> accept -> the REAL world -> back to a live shell (fake model, real engine)
## Each mode writes $OUT_DIR/<MODE>.json (merged from the probe's *.part.json files) with
## exactly the keys the DoD reads. This wrapper judges nothing; the DoD's jq does.
##
## Env: MODE (required), OUT_DIR (required), XDG_DATA_HOME (default: $OUT_DIR/xdg),
##      DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${MODE:?verify_chatroom: MODE is required}"
: "${OUT_DIR:?verify_chatroom: OUT_DIR is required}"
export DISPLAY=":99"
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR"
: "${XDG_DATA_HOME:=$OUT_DIR/xdg}"
export XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME"
case "$XDG_DATA_HOME" in
    "$HOME/.local/share"*) echo "verify_chatroom: refusing to use the real user data dir" >&2; exit 2 ;;
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

start_fake() {
    # start_fake <tag>: a fresh loopback fake model; sets FAKE_PORT, FAKE_LOG, FAKE_MODE_FILE
    FAKE_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
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
    echo "verify_chatroom: fake model did not come up" >&2
    exit 1
}

stop_fake() { cleanup; FAKE_PID=""; }

run_probe() {
    # run_probe <probe_mode> <log_tag> <timeout_s> [VAR=value ...]; uses FAKE_* when set
    local pmode="$1" tag="$2" tmo="$3"
    shift 3
    local fake_env=()
    if [ -n "$FAKE_PID" ]; then
        fake_env=(DECOHERENCE_OLLAMA_PORT="$FAKE_PORT" CHATROOM_FAKE_LOG="$FAKE_LOG" CHATROOM_FAKE_MODE_FILE="$FAKE_MODE_FILE")
    fi
    env DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE="$pmode" DECOHERENCE_PROBE_OUT_DIR="$OUT_DIR" \
        DECOHERENCE_PROBE_SCREENSHOT="$OUT_DIR/${tag}_final.png" "${fake_env[@]}" "$@" \
        timeout "$tmo" "$GODOT" --display-driver x11 --path "$REPO_ROOT" --resolution 1920x1080 </dev/null > "$OUT_DIR/$tag.log" 2>&1
    return $?
}

need_part() {
    # need_part <name>: the probe's part file must exist, be non-empty JSON and be newer than this run
    [ -s "$OUT_DIR/$1.part.json" ] && jq -e . "$OUT_DIR/$1.part.json" > /dev/null 2>&1 && [ "$OUT_DIR/$1.part.json" -nt "$OUT_DIR/.start" ] \
        || { echo "verify_chatroom: probe produced no fresh $1.part.json (see $OUT_DIR)" >&2; exit 1; }
}

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null > /dev/null 2>&1 || true
touch "$OUT_DIR/.start"
rm -f "$OUT_DIR/$MODE.json"
ec=0

case "$MODE" in
    flow)
        start_fake flow
        run_probe chatroom_flow flow 900; ec=$?
        need_part flow
        cp "$OUT_DIR/flow.part.json" "$OUT_DIR/flow.json"
        ;;
    degrade)
        start_fake degrade
        run_probe chatroom_degrade degrade 400; ec=$?
        need_part degrade
        stop_fake
        run_probe chatroom_gatefail gatefail 200 DECOHERENCE_FORCE_GATE_FAIL=1; ec2=$?
        need_part gatefail
        [ "$ec2" -eq 0 ] || ec=$ec2
        jq -n --slurpfile g "$OUT_DIR/gatefail.part.json" --slurpfile o "$OUT_DIR/degrade.part.json" '{gate_fail: $g[0], outage: $o[0]}' > "$OUT_DIR/degrade.json"
        ;;
    mutate)
        SRC="$REPO_ROOT/frontdoor/data/chatroom"
        for v in default changed ratio1; do
            rm -rf "$OUT_DIR/mut_$v"
            cp -r "$SRC" "$OUT_DIR/mut_$v"
        done
        jq '.rooms[0].ambient.lines |= map(.plain = "zqmarker " + .plain) | .scramble.reveal_words = ["zqmarker"]' "$SRC/room_script.json" > "$OUT_DIR/mut_changed/room_script.json"
        jq '.facts |= map(if .id == "f_entanglement" then .text += " ZQFACTMARK" else . end)' "$SRC/handler_briefing.json" > "$OUT_DIR/mut_changed/handler_briefing.json"
        jq '.scramble.legible_ratio = 1' "$SRC/room_script.json" > "$OUT_DIR/mut_ratio1/room_script.json"
        for v in default changed ratio1; do
            start_fake "mut_$v"
            run_probe chatroom_mutate "mutate_$v" 300 CHATROOM_MUTATE_VARIANT="$v" DECOHERENCE_CHATROOM_DIR="$OUT_DIR/mut_$v"; e=$?
            [ "$e" -eq 0 ] || ec=$e
            need_part "mutate_$v"
            stop_fake
        done
        jq -n --slurpfile d "$OUT_DIR/mutate_default.part.json" --slurpfile c "$OUT_DIR/mutate_changed.part.json" --slurpfile r "$OUT_DIR/mutate_ratio1.part.json" '{
            marker_visible_when_script_changed: $c[0].marker_visible,
            marker_visible_in_default: $d[0].marker_visible,
            legible_ratio_1_equals_plain: ($r[0].rows_equal_plain and $r[0].rows > 0),
            default_plaintext_leaks: $d[0].plaintext_leaks,
            briefing_marker_in_prompt: $c[0].briefing_marker_in_prompt}' > "$OUT_DIR/mutate.json"
        ;;
    leak)
        need_ollama
        run_probe chatroom_leak leak 1200; ec=$?
        need_part leak
        start_fake leak
        run_probe chatroom_leak_neg leak_neg 300; e=$?
        [ "$e" -eq 0 ] || ec=$e
        need_part leak_neg
        jq -s '.[0] + .[1]' "$OUT_DIR/leak.part.json" "$OUT_DIR/leak_neg.part.json" > "$OUT_DIR/leak.json"
        ;;
    live)
        need_ollama
        run_probe chatroom_live live 900; ec=$?
        need_part live
        cp "$OUT_DIR/live.part.json" "$OUT_DIR/live.json"
        ;;
    handoff)
        [ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
            || { echo "verify_chatroom: engine library missing; run tools/build_engine.sh" >&2; exit 1; }
        start_fake handoff
        run_probe chatroom_handoff handoff 600; ec=$?
        need_part handoff
        cp "$OUT_DIR/handoff.part.json" "$OUT_DIR/handoff.json"
        ;;
    *) echo "verify_chatroom: unknown MODE $MODE" >&2; exit 2 ;;
esac

[ -s "$OUT_DIR/$MODE.json" ] || { echo "verify_chatroom: no $MODE.json produced" >&2; exit 1; }
echo "verify_chatroom: $MODE finished (probe exit $ec)" >&2
exit "$ec"
