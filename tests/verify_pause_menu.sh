#!/usr/bin/env bash
## tests/verify_pause_menu.sh -- Spec #578 pause menu end to end through the REAL frontdoor.
##
## PM_MODE selects the run (every action is a real key or mouse event pushed into the engine):
##   surfaces  Esc on boot, prompt, chat, HANDLER and world at 1920x1080, chat-pane coexistence, the world's
##             details, Exit to Q-Ent OS, the Settings display toggle, F11 and Alt+Enter   -> surfaces.log
##   control   the same run with the overlay removed at startup (the negative control)    -> control.log
##   sizes     the menu over the prompt at 1280x720, 1920x1080 and 3840x2160, with a PNG each
##             (pm_<WxH>.png)                                                            -> sizes.log
##   exit      Exit to desktop by real keys from ONE surface (PM_SURFACE = boot|shell|chat|handler|world).
##             Before the exit it proves its own process scan can see the live game (the run's tag
##             is found), after it proves nothing carrying the tag is left. Prints one line:
##             PM_EXIT_OK surface=<s> ec=<n> timed_out=<0|1> orphans=<n> scan_control=<0|1>
##             when all four hold, PM_EXIT_FAIL with the same fields otherwise      -> <surface>.log
## The wrapper copies only the probe's ^PROBE_PM_ lines into the log and judges no number but the
## exit run's own four fields.
##
## Env: PM_MODE (required), PM_LOG_DIR (required), PM_SURFACE (exit mode), GODOT (default ~/.local/bin/godot)
## Display and user data are pinned here: the off-screen test display, an empty session bus, and a
## scratch user data dir per launch, so the player's saves and settings are never touched.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${PM_MODE:?verify_pause_menu: PM_MODE is required}"
: "${PM_LOG_DIR:?verify_pause_menu: PM_LOG_DIR is required}"
export DISPLAY=":99"
# An inherited WAYLAND_DISPLAY would override DISPLAY and open the window on the real desktop.
unset WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
mkdir -p "$PM_LOG_DIR"
[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "PRECONDITION-UNMET: display $DISPLAY not available" >&2; exit 2; }

FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
trap cleanup EXIT

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("localhost", 0)); print(s.getsockname()[1]); s.close()'; }

start_fake() {
    # the loopback fake contact model: the boot gate and the chat open need an answering model
    FAKE_PORT="$(free_port)"
    FAKE_LOG="$PM_LOG_DIR/fake_$1.jsonl"
    FAKE_MODE_FILE="$PM_LOG_DIR/fake_$1.mode"
    : > "$FAKE_LOG"
    echo ok > "$FAKE_MODE_FILE"
    python3 "$REPO_ROOT/tests/fake_handler.py" --port "$FAKE_PORT" --out "$FAKE_LOG" --mode-file "$FAKE_MODE_FILE" > "$PM_LOG_DIR/fake_$1.out" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 50); do
        curl -fsS "http://localhost:$FAKE_PORT/api/tags" > /dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "verify_pause_menu: fake model did not come up" >&2
    exit 1
}

## launch <tag> <resolution> [VAR=value ...]: one game process, a scratch user dir, raw output to $PM_LOG_DIR/<tag>.raw
launch() {
    local tag="$1" res="$2"
    shift 2
    local xdg
    xdg="$(mktemp -d)"
    XDG_DATA_HOME="$xdg" env DECOHERENCE_PROBE=1 DECOHERENCE_PROBE_MODE=pause_menu DECOHERENCE_PROBE_OUT_DIR="$PM_LOG_DIR" \
        PM_MODE="$PM_MODE" PM_LOG_DIR="$PM_LOG_DIR" \
        DECOHERENCE_OLLAMA_PORT="$FAKE_PORT" CHATROOM_FAKE_LOG="$FAKE_LOG" CHATROOM_FAKE_MODE_FILE="$FAKE_MODE_FILE" "$@" \
        timeout 600 "$GODOT" --display-driver x11 --audio-driver Dummy --path "$REPO_ROOT" --resolution "$res" </dev/null > "$PM_LOG_DIR/$tag.raw" 2>&1
}

## New class_name files are invisible to a run until the editor has registered them.
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null > /dev/null 2>&1 || true

case "$PM_MODE" in
    surfaces|control)
        log="$PM_LOG_DIR/$PM_MODE.log"
        : > "$log"
        start_fake "$PM_MODE"
        launch "$PM_MODE" 1920x1080
        ec=$?
        grep -E '^PROBE_PM_' "$PM_LOG_DIR/$PM_MODE.raw" > "$log"
        echo "verify_pause_menu: $PM_MODE finished (godot exit $ec)" >&2
        exit "$ec"
        ;;
    sizes)
        log="$PM_LOG_DIR/sizes.log"
        : > "$log"
        start_fake sizes
        rc=0
        for size in 1280x720 1920x1080 3840x2160; do
            rm -f "$PM_LOG_DIR/pm_$size.png"
            launch "sizes_$size" "$size" PM_SIZE="$size"
            ec=$?
            [ "$ec" -eq 0 ] || rc=$ec
            grep -E '^PROBE_PM_' "$PM_LOG_DIR/sizes_$size.raw" >> "$log"
        done
        echo "verify_pause_menu: sizes finished (worst godot exit $rc)" >&2
        exit "$rc"
        ;;
    exit)
        : "${PM_SURFACE:?verify_pause_menu: PM_SURFACE is required for exit mode}"
        case "$PM_SURFACE" in boot|shell|chat|handler|world) ;; *) echo "verify_pause_menu: bad PM_SURFACE" >&2; exit 2 ;; esac
        log="$PM_LOG_DIR/$PM_SURFACE.log"
        : > "$log"
        rm -f "$PM_LOG_DIR/$PM_SURFACE.go"
        start_fake "exit_$PM_SURFACE"
        run_tag="pm578-$$-$RANDOM$RANDOM"
        scan() {
            # processes whose environment carries this run's tag (the game, its wrapper, anything it spawned)
            local n=0 p
            for p in /proc/[0-9]*; do
                if { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qx "PM_RUN_TAG=$run_tag"; then
                    n=$((n + 1))
                fi
            done
            echo "$n"
        }
        launch "exit_$PM_SURFACE" 1920x1080 PM_SURFACE="$PM_SURFACE" PM_RUN_TAG="$run_tag" &
        gpid=$!
        # positive control: the scan must see the live game before the exit is allowed
        scan_control=0
        for _ in $(seq 1 1200); do
            if grep -q '^PROBE_PM_EXIT_ARMED' "$PM_LOG_DIR/exit_$PM_SURFACE.raw" 2>/dev/null; then
                [ "$(scan)" -ge 1 ] && scan_control=1
                break
            fi
            kill -0 "$gpid" 2>/dev/null || break
            sleep 0.25
        done
        : > "$PM_LOG_DIR/$PM_SURFACE.go"
        wait "$gpid"
        ec=$?
        grep -E '^PROBE_PM_' "$PM_LOG_DIR/exit_$PM_SURFACE.raw" > "$log"
        sleep 1
        orphans="$(scan)"
        timed_out=0
        [ "$ec" -eq 124 ] && timed_out=1
        verdict=FAIL
        [ "$ec" -eq 0 ] && [ "$timed_out" -eq 0 ] && [ "$orphans" -eq 0 ] && [ "$scan_control" -eq 1 ] && verdict=OK
        echo "PM_EXIT_$verdict surface=$PM_SURFACE ec=$ec timed_out=$timed_out orphans=$orphans scan_control=$scan_control"
        [ "$verdict" = OK ]
        exit $?
        ;;
    *)
        echo "verify_pause_menu: unknown PM_MODE '$PM_MODE'" >&2
        exit 2
        ;;
esac
