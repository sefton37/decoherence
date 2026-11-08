#!/usr/bin/env bash
## tests/verify_intent_accuracy.sh -- Spec #519 router accuracy / degrade run.
##
## Boots the REAL frontdoor and feeds every row of tests/intent_utterances.json
## through the shell (Signals.terminal_line_submitted, the same path as a real
## Enter keypress) using the probe's `router` mode. Rows are resolved by the
## real game-owned llama-server (MODE=live) with state-changing effects held in
## a dry run, so 103 utterances can be judged in one session; or, with
## MODE=degrade, with the gate force-failed to prove the honest offline path.
##
## Writes $OUT_DIR/rows.json (one object per utterance: source, action, args,
## latency, rendered lines, ...) and $OUT_DIR/rendered.txt. Scoring is a separate
## step (tests/score_intent.sh); this script judges nothing and never reads a bar.
##
## Env: DECOHERENCE_LLM_SOURCE (ollama|owned; default from data/llm_config.json), MODE (live|degrade, default live), OUT_DIR (required), RUN_ID (label),
##      DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot),
##      XDG_DATA_HOME (default $OUT_DIR/xdg, so Kel's real user:// is never used)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
MODE="${MODE:-live}"
: "${OUT_DIR:?verify_intent_accuracy: OUT_DIR is required}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$OUT_DIR/xdg}"
mkdir -p "$XDG_DATA_HOME"

[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "PRECONDITION-UNMET: display $DISPLAY not available" >&2; exit 2; }
## Model source: config default, overridable by DECOHERENCE_LLM_SOURCE (Spec #519 A1).
SOURCE="${DECOHERENCE_LLM_SOURCE:-$(jq -r '.source // "ollama"' "$REPO_ROOT/data/llm_config.json")}"
if [ "$MODE" = "live" ]; then
    if [ "$SOURCE" = "ollama" ]; then
        # Ollama mode: no :8085 / 6000 MiB gate; the shared house model must be
        # resident, quiet and idle (ollama_ready.sh reads only, never loads).
        if ! "$REPO_ROOT/tests/ollama_ready.sh" >&2; then
            echo "PRECONDITION-UNMET: ollama_ready.sh refused (see UNMET line above)" >&2
            exit 2
        fi
    else
        if ss -ltn | grep -q ':8085 '; then
            echo "PRECONDITION-UNMET: port 8085 is bound (Kel's game?) -- refusing to touch it" >&2
            exit 2
        fi
        FREE="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)"
        if [ "${FREE:-0}" -lt 6000 ]; then
            echo "PRECONDITION-UNMET: only ${FREE} MiB GPU memory free (need >= 6000)" >&2
            exit 2
        fi
    fi
fi

rm -f "$OUT_DIR/rows.json" "$OUT_DIR/rendered.txt" "$OUT_DIR/start_epoch" "$OUT_DIR/end_epoch" "$OUT_DIR/ollama_ps.txt"
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

FORCE=0
date +%s > "$OUT_DIR/start_epoch"
[ "$MODE" = "degrade" ] && FORCE=1
DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=router DECOHERENCE_ROUTER_MODE="$MODE" \
    DECOHERENCE_FORCE_GATE_FAIL="$FORCE" \
    DECOHERENCE_UTTERANCES="$REPO_ROOT/tests/intent_utterances.json" DECOHERENCE_ROUTER_OUT="$OUT_DIR" \
    timeout 1500 "$GODOT" --path "$REPO_ROOT" --resolution 1280x720 </dev/null >"$OUT_DIR/godot.log" 2>&1
ec=$?
date +%s > "$OUT_DIR/end_epoch"
[ "$SOURCE" = "ollama" ] && ollama ps > "$OUT_DIR/ollama_ps.txt" 2>&1

if [ ! -s "$OUT_DIR/rows.json" ]; then
    echo "verify_intent_accuracy: no rows.json written (godot exit $ec)" >&2
    tail -5 "$OUT_DIR/godot.log" >&2
    exit 1
fi
n="$(jq '.rows|length' "$OUT_DIR/rows.json")"
echo "verify_intent_accuracy: mode=$MODE run=${RUN_ID:-} rows=$n request_count_delta=$(jq '.request_count_delta' "$OUT_DIR/rows.json") (godot exit $ec)" >&2
exit 0
