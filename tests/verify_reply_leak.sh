#!/usr/bin/env bash
## tests/verify_reply_leak.sh -- Spec #519 / #615 in-Godot reply leak check.
##
## Runs tests/leak_check.gd against the active model source (default: the house
## Ollama; DECOHERENCE_LLM_SOURCE=owned spawns the game-owned llama-server, ctx and
## reasoning flags from data/llm_config.json) through the real LlmClient and
## passes its LEAK_* lines through. Exit code is the Godot script's.
## Refuses (PRECONDITION-UNMET, exit 2) when port 8085 is bound or the GPU is short.
##
## Env: XDG_DATA_HOME (scratch dir recommended: user:// holds the server PID file),
##      DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
: "${XDG_DATA_HOME:?verify_reply_leak: XDG_DATA_HOME must point at a scratch dir}"
mkdir -p "$XDG_DATA_HOME"

## Model source: config default, overridable by DECOHERENCE_LLM_SOURCE (Spec #519 A1).
SOURCE="${DECOHERENCE_LLM_SOURCE:-$(jq -r '.source // "ollama"' "$REPO_ROOT/data/llm_config.json")}"
if [ "$SOURCE" = "ollama" ]; then
    # The leak check is behavioural, not a speed measurement: GPU util is not gated.
    if ! MAX_UTIL="${MAX_UTIL:-100}" "$REPO_ROOT/tests/ollama_ready.sh" >&2; then
        echo "PRECONDITION-UNMET: ollama_ready.sh refused (see UNMET line above)" >&2
        exit 2
    fi
else
    if ss -ltn | grep -q ':8085 '; then
        echo "PRECONDITION-UNMET: port 8085 is bound" >&2
        exit 2
    fi
    FREE="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)"
    if [ "${FREE:-0}" -lt 6000 ]; then
        echo "PRECONDITION-UNMET: only ${FREE} MiB GPU memory free (need >= 6000)" >&2
        exit 2
    fi
fi

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true
timeout 600 "$GODOT" --headless --path "$REPO_ROOT" --script res://tests/leak_check.gd </dev/null 2>&1 \
    | grep -E '^(LEAK_|SCRIPT ERROR)'
exit "${PIPESTATUS[0]}"
