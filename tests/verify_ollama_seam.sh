#!/usr/bin/env bash
## tests/verify_ollama_seam.sh -- Spec #519 A1 model-source seam, against a FAKE Ollama.
##
## No GPU and no real model: tests/fake_ollama.py (stdlib, loopback, scratch port) records every
## request the game makes. Three phases, each one real frontdoor boot (probe mode `seam`):
##   ollama_ok       gate succeeds (/api/tags, warm-up), one routed line, one send_chat
##   gate_fail       the fake lists no model: the gate must fail honestly, free text degrades
##   owned_forcefail DECOHERENCE_LLM_SOURCE=owned + DECOHERENCE_FORCE_GATE_FAIL=1: the fake must
##                   see ZERO requests (owned mode never talks to Ollama) and nothing spawns
## Writes $OUT_DIR/requests.jsonl (one object per request: phase, method, path, body) and
## $OUT_DIR/seam.log (SEAM_* lines). Judged by the DoD (jq over requests.jsonl, grep over seam.log).
##
## Env: OUT_DIR (required), XDG_DATA_HOME (required; scratch), DISPLAY (ignored; always :99),
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${OUT_DIR:?verify_ollama_seam: OUT_DIR is required}"
: "${XDG_DATA_HOME:?verify_ollama_seam: XDG_DATA_HOME must point at a scratch dir}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$OUT_DIR" "$XDG_DATA_HOME"
case "$XDG_DATA_HOME" in
    "$HOME/.local/share"*) echo "verify_ollama_seam: refusing to use the real user data dir" >&2; exit 2 ;;
esac
[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "PRECONDITION-UNMET: display $DISPLAY not available" >&2; exit 2; }

REQ="$OUT_DIR/requests.jsonl"
LOG="$OUT_DIR/seam.log"
: > "$REQ"
: > "$LOG"
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
FAKE_PID=""
stop_fake() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; FAKE_PID=""; }
trap stop_fake EXIT

start_fake() {
    python3 "$REPO_ROOT/tests/fake_ollama.py" --port "$PORT" --out "$REQ" --phase "$1" --mode "$2" >"$OUT_DIR/fake_$1.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 50); do
        grep -q FAKE_OLLAMA_LISTENING "$OUT_DIR/fake_$1.log" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "verify_ollama_seam: fake did not start" >&2
    return 1
}

# Owned llama-server children of the game (argv0 basename llama-server AND --port 8085).
# Ollama's own runners are also called llama-server, so match the owned port exactly.
owned_server_count() {
    local n=0 f
    for f in /proc/[0-9]*/cmdline; do
        local argv
        argv="$( { tr '\0' '\n' < "$f"; } 2>/dev/null )" || continue
        [ "$(basename "$(printf '%s\n' "$argv" | head -1)")" = "llama-server" ] || continue
        printf '%s\n' "$argv" | grep -qx -- '8085' && n=$((n + 1))
    done
    echo "$n"
}

run_phase() {
    # run_phase <phase> <fake_mode> <source> <force_fail 0|1>
    local phase="$1" fmode="$2" source="$3" force="$4"
    local raw="$OUT_DIR/raw_$phase.log"
    start_fake "$phase" "$fmode" || return 1
    DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=seam DECOHERENCE_BOOT_PRESET=off \
        DECOHERENCE_LLM_SOURCE="$source" DECOHERENCE_OLLAMA_PORT="$PORT" DECOHERENCE_FORCE_GATE_FAIL="$force" \
        timeout 240 "$GODOT" --path "$REPO_ROOT" --resolution 1280x720 </dev/null >"$raw" 2>&1
    local ec=$?
    stop_fake
    echo "SEAM_PHASE $phase godot_exit=$ec" >> "$LOG"
    grep -E '^PROBE_SEAM ' "$raw" | sed "s/^PROBE_SEAM /SEAM_ROUTE phase=$phase /" >> "$LOG"
}

count_phase() { grep -c "\"phase\": \"$1\"" "$REQ" || true; }

run_phase ollama_ok ok ollama 0
run_phase gate_fail nomodel ollama 0
run_phase owned_forcefail ok owned 1

# --- verdict lines -------------------------------------------------------------
spawned=$(cat "$OUT_DIR"/raw_*.log | grep -cE '^(LLM_SPAWNED|LLM_ALREADY_RUNNING)' || true)
pidf=0
[ -e "$XDG_DATA_HOME/godot/app_userdata/Decoherence/llm_server.pid" ] && pidf=1
echo "SEAM_NO_SPAWN pid_file=$((pidf + spawned)) llama_server_procs=$(owned_server_count)" >> "$LOG"

link_failed=$(grep -c 'CORTEX LINK FAILED' "$OUT_DIR/raw_gate_fail.log" || true)
degraded=$(grep -c 'route_source=degraded' "$OUT_DIR/raw_gate_fail.log" || true)
exact=$(grep -c 'EXACT COMMANDS' "$OUT_DIR/raw_gate_fail.log" || true)
chat_in_gate_fail=$(jq -s '[.[]|select(.phase=="gate_fail" and .path=="/api/chat")]|length' "$REQ")
if [ "${link_failed:-0}" -ge 1 ] && [ "${degraded:-0}" -ge 1 ] && [ "${exact:-0}" -ge 1 ] && [ "$chat_in_gate_fail" = 0 ]; then
    echo "SEAM_GATE_FAIL_HONEST link_failed=$link_failed degraded=$degraded exact_commands_line=$exact chat_requests=0" >> "$LOG"
fi

echo "SEAM_OWNED_NO_OLLAMA requests=$(jq -s '[.[]|select(.phase=="owned_forcefail")]|length' "$REQ")" >> "$LOG"
cat "$LOG"
[ -s "$REQ" ] || exit 1
exit 0
