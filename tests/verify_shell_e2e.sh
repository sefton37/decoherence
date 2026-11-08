#!/usr/bin/env bash
## tests/verify_shell_e2e.sh -- Spec #519 shell end-to-end through the real frontdoor.
##
## E2E_MODE selects what the probe drives (every mode types into the shell via
## Signals.terminal_line_submitted, the real Enter path):
##   fastpath   exact commands: zero LLM requests, fast resolve, legacy dir lines,
##              legacy unknown-command line
##   thinking   in-fiction thinking row timing, stale-result drop, busy-router fast
##              path, timeout -> honest degraded line
##   dispatch   real model picks each action and the echo + state agree
##   settings   every setting applied and read back, persistence across a relaunch,
##              invalid values rejected, corrupt file defaulted, real user dir
##              untouched (three launches; the gate is force-failed, the model is
##              not involved in settings)
## All PROBE_* lines (including PROBE_RENDERED echoes) go to $OUT_FILE.
##
## Env: DECOHERENCE_LLM_SOURCE (ollama|owned; default from data/llm_config.json),
##      E2E_MODE (required), OUT_FILE (required), XDG_DATA_HOME (required; a scratch
##      dir), DISPLAY (ignored; always :99), GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${E2E_MODE:?verify_shell_e2e: E2E_MODE is required}"
: "${OUT_FILE:?verify_shell_e2e: OUT_FILE is required}"
: "${XDG_DATA_HOME:?verify_shell_e2e: XDG_DATA_HOME must point at a scratch dir}"
## Always the Xvfb test display, never an inherited desktop DISPLAY (Kel may be on :0).
export DISPLAY=":99"
## Never reach Kel's Wayland desktop: Godot prefers WAYLAND_DISPLAY over DISPLAY.
unset WAYLAND_DISPLAY
mkdir -p "$XDG_DATA_HOME" "$(dirname "$OUT_FILE")"
: > "$OUT_FILE"

[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "PRECONDITION-UNMET: display $DISPLAY not available" >&2; exit 2; }
case "$XDG_DATA_HOME" in
    "$HOME/.local/share"*) echo "verify_shell_e2e: refusing to use the real user data dir" >&2; exit 2 ;;
esac

timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

run_probe() {
    # run_probe <probe_mode> <force_gate_fail 0|1> [extra godot args...]
    local pmode="$1" force="$2"
    shift 2
    DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE="$pmode" DECOHERENCE_FORCE_GATE_FAIL="$force" \
        timeout 600 "$GODOT" --path "$REPO_ROOT" "$@" </dev/null 2>&1 | grep -E '^PROBE_' >> "$OUT_FILE"
    return "${PIPESTATUS[0]}"
}

## Model source: config default, overridable by DECOHERENCE_LLM_SOURCE (Spec #519 A1).
SOURCE="${DECOHERENCE_LLM_SOURCE:-$(jq -r '.source // "ollama"' "$REPO_ROOT/data/llm_config.json")}"
if [ "$E2E_MODE" != "settings" ]; then
    if [ "$SOURCE" = "ollama" ]; then
        # Behavioural (not accuracy) runs: GPU utilisation is not gated here.
        if ! MAX_UTIL="${MAX_UTIL:-100}" "$REPO_ROOT/tests/ollama_ready.sh" >&2; then
            echo "PRECONDITION-UNMET: ollama_ready.sh refused (see UNMET line above)" >&2
            exit 2
        fi
    else
        FREE="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)"
        if ss -ltn | grep -q ':8085 ' || [ "${FREE:-0}" -lt 6000 ]; then
            echo "PRECONDITION-UNMET: port 8085 bound or GPU free ${FREE} MiB < 6000" >&2
            exit 2
        fi
    fi
fi

case "$E2E_MODE" in
    fastpath) run_probe e2e_fastpath 0 --resolution 1280x720 ;;
    thinking) run_probe e2e_thinking 0 --resolution 1280x720 ;;
    dispatch) run_probe e2e_dispatch 0 --resolution 1280x720 ;;
    settings)
        REAL="$HOME/.local/share/godot/app_userdata/Decoherence/settings.json"
        before="$(stat -c '%Y %s' "$REAL" 2>/dev/null || echo absent)"
        USERDIR="$XDG_DATA_HOME/godot/app_userdata/Decoherence"
        # 1. apply every setting, persist, reject invalid
        run_probe e2e_settings 1 --resolution 1920x1080
        # 2. relaunch with no window flag: persisted values must come back and apply
        run_probe e2e_relaunch 1
        # 3. corrupt the file: defaults plus an honest line
        mkdir -p "$USERDIR"
        printf '%s' '{"crt": not json at all' > "$USERDIR/settings.json"
        run_probe e2e_corrupt 1 --resolution 1920x1080
        after="$(stat -c '%Y %s' "$REAL" 2>/dev/null || echo absent)"
        if [ "$before" = "$after" ]; then
            echo "REAL_USER_DIR_UNTOUCHED" >> "$OUT_FILE"
        fi
        ;;
    *) echo "verify_shell_e2e: unknown E2E_MODE $E2E_MODE" >&2; exit 2 ;;
esac
exit 0
