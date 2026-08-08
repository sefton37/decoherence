#!/usr/bin/env bash
## tests/verify_crash_recovery.sh -- Spec #387 Amendment 4 DOD-39 (MARQUEE
## for this amendment) live proof.
##
## Encodes the Gate-3 re-audit's live-reproduced finding: OS.is_process_running()
## on this Godot build has CHILD-ONLY semantics, so a genuinely-alive
## crash-orphan llama-server bound to the configured port survives a
## relaunch+quit cycle undetected -- a false LLM_ORPHAN_CLEANED marker, the
## replacement spawn dying on port bind, chat silently served by the
## orphan, and the orphan still holding the port + GPU memory after a
## normal quit. This script SEEDS that exact crash state (a real
## llama-server bound to the configured port + a stale PID-file pointing at
## it, written by THIS script, not by any Godot instance), drives one full
## DECOHERENCE_PROBE=1 boot, and asserts the game reclaimed it.
##
## Standalone -- does not call into scripts/llm_client.gd directly, only
## drives the real app the same way the DOD-34 harness does.
##
## Expected state RIGHT NOW (pre-Amendment-4-fix): FAILS on the "zero
## same-kind survivors system-wide" assertion -- the seeded orphan is still
## alive after the probe's clean quit. That is this script's honest red
## state, not a bug in the script.
##
## Never touches port 8085 (or whatever the configured port is) unless
## nothing but a prior aborted run of THIS test already holds it (a
## foreign process on that port aborts the run rather than being touched).
## Never references or touches the system Ollama daemon. Always attempts
## to leave the box clean on every exit path (EXIT trap), even on failure.
##
## Amendment 5 (identity precision, third Gate-3 audit red-team): the
## reclaim pass's identity check on this box is a plain substring search
## over the joined cmdline, which a harmless process can accidentally (or
## deliberately) satisfy via its own argument TEXT without genuinely being
## llama-server. ASSERT-E seeds a decoy alongside the genuine orphan --
## argv[0] is NOT "llama-server", but one argument's TEXT contains both
## needle substrings ("llama-server" and "--port <configured port>") the
## same way the auditor's live repro did. The decoy must SURVIVE the
## probe's reclaim pass; only the genuine orphan may be reclaimed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$REPO_ROOT/data/llm_config.json"
PID_FILE="$HOME/.local/share/godot/app_userdata/Decoherence/llm_server.pid"

SEED_PID=""
SEED_LOG=""
PROBE_LOG=""
PORT=""
DECOY_PID=""
FAILURES=()

fail_precondition() {
    echo "PRECONDITION-UNMET: $1" >&2
    exit 1
}

record_failure() {
    FAILURES+=("$1")
    echo "FAIL-$1" >&2
}

sweep_port_survivors() {
    # Any process anywhere on the box that IS a llama-server bound to the
    # configured port -- not just the pid this script itself spawned.
    # Prints matching pids, one per line.
    #
    # Argv-token-exact identity (Spec #387 Amendment 5), mirroring
    # _argv_matches_llama_server()/_cmdline_argv() in scripts/llm_client.gd
    # verbatim: /proc/<pid>/cmdline is split on its real NUL boundaries
    # into an argv array (never joined into one string and substring
    # matched -- that was the Amendment-4-era heuristic this replaces, and
    # it is exactly what ASSERT-E's decoy is designed to defeat). A pid
    # counts as a survivor only if basename(argv[0]) is EXACTLY
    # "llama-server" AND an adjacent "--port"/"<port>" pair appears as two
    # separate, exact argv elements.
    [ -n "$PORT" ] || return 0
    local d p argv base i found
    for d in /proc/[0-9]*; do
        p="${d#/proc/}"
        [ -r "$d/cmdline" ] || continue
        argv=()
        mapfile -d '' -t argv <"$d/cmdline" 2>/dev/null
        [ "${#argv[@]}" -eq 0 ] && continue
        base="${argv[0]##*/}"
        [ "$base" = "llama-server" ] || continue
        found=0
        for ((i = 0; i < ${#argv[@]} - 1; i++)); do
            if [ "${argv[i]}" = "--port" ] && [ "${argv[i + 1]}" = "$PORT" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] && echo "$p"
    done
}

cleanup() {
    # Kill the pid this script itself seeded, if still alive.
    if [ -n "$SEED_PID" ] && kill -0 "$SEED_PID" 2>/dev/null; then
        kill "$SEED_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$SEED_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$SEED_PID" 2>/dev/null && kill -9 "$SEED_PID" 2>/dev/null
    fi
    # Belt-and-suspenders: sweep for ANY surviving same-port llama-server,
    # in case a different pid (e.g. a replacement spawn) is the one that
    # actually leaked -- the box must be clean even when the test fails.
    for p in $(sweep_port_survivors); do
        kill "$p" 2>/dev/null
    done
    sleep 0.3
    for p in $(sweep_port_survivors); do
        kill -9 "$p" 2>/dev/null
    done
    # ASSERT-E's decoy (Amendment 5) -- kill it regardless of whether it
    # survived (expected, the pass case) or was wrongly reclaimed (the
    # fail case) -- either way it must not outlive this script.
    if [ -n "$DECOY_PID" ] && kill -0 "$DECOY_PID" 2>/dev/null; then
        kill "$DECOY_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$DECOY_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$DECOY_PID" 2>/dev/null && kill -9 "$DECOY_PID" 2>/dev/null
    fi
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
    [ -n "$SEED_LOG" ] && rm -f "$SEED_LOG"
    [ -n "$PROBE_LOG" ] && rm -f "$PROBE_LOG"
}
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || fail_precondition "jq not found on PATH"
command -v curl >/dev/null 2>&1 || fail_precondition "curl not found on PATH"

if [ ! -f "$CONFIG_PATH" ]; then
    fail_precondition "data/llm_config.json not found at $CONFIG_PATH -- implementer has not created the config seam yet"
fi

REL_SERVER_BINARY="$(jq -r '.server_binary // empty' "$CONFIG_PATH" 2>/dev/null)"
REL_MODEL_PATH="$(jq -r '.model_path // empty' "$CONFIG_PATH" 2>/dev/null)"
HOST="$(jq -r '.host // empty' "$CONFIG_PATH" 2>/dev/null)"
PORT="$(jq -r '.port // empty' "$CONFIG_PATH" 2>/dev/null)"
CTX_SIZE="$(jq -r '.ctx_size // empty' "$CONFIG_PATH" 2>/dev/null)"
REASONING_FORMAT="$(jq -r '.reasoning_format // empty' "$CONFIG_PATH" 2>/dev/null)"

if [ -z "$REL_SERVER_BINARY" ] || [ -z "$REL_MODEL_PATH" ] || [ -z "$PORT" ]; then
    fail_precondition "server_binary/model_path/port missing or unreadable in $CONFIG_PATH"
fi

[ -n "$HOST" ] && [ "$HOST" != "null" ] || HOST=127.0.0.1
[ -n "$CTX_SIZE" ] && [ "$CTX_SIZE" != "null" ] || CTX_SIZE=8192
[ -n "$REASONING_FORMAT" ] && [ "$REASONING_FORMAT" != "null" ] || REASONING_FORMAT=deepseek

# Resolve repo-relative config paths against the REPO ROOT, never $PWD.
SERVER_BINARY="$REPO_ROOT/$REL_SERVER_BINARY"
MODEL_PATH="$REPO_ROOT/$REL_MODEL_PATH"

if [ ! -x "$SERVER_BINARY" ]; then
    fail_precondition "server_binary not present/executable at $SERVER_BINARY (run tools/setup_llm.sh)"
fi

if [ ! -f "$MODEL_PATH" ]; then
    fail_precondition "model_path not present at $MODEL_PATH (run tools/setup_llm.sh)"
fi

# Same GODOT resolution fallback chain as the stored DOD-34 check.
GODOT="$(command -v godot || true)"
if [ -z "$GODOT" ] && [ -x "$HOME/.local/bin/godot" ]; then
    GODOT="$HOME/.local/bin/godot"
fi
if [ -z "$GODOT" ]; then
    GODOT="$HOME/Godot/godot.linuxbsd.editor.x86_64"
fi
if [ ! -x "$GODOT" ]; then
    fail_precondition "no godot binary found (checked PATH, ~/.local/bin/godot, ~/Godot/godot.linuxbsd.editor.x86_64)"
fi

# --- Refuse to seed onto a port held by anything foreign ------------------
port_owner_pids() {
    ss -tlnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ (p"$") { print }' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

EXISTING_PIDS="$(port_owner_pids)"
if [ -n "$EXISTING_PIDS" ]; then
    for p in $EXISTING_PIDS; do
        CL="$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)"
        case "$CL" in
            *llama-server*)
                # Leftover from a prior aborted run of this exact test --
                # our own kind, safe to reclaim before seeding a fresh one.
                kill "$p" 2>/dev/null
                for _ in $(seq 1 20); do
                    kill -0 "$p" 2>/dev/null || break
                    sleep 0.2
                done
                ;;
            *)
                echo "PORT-BUSY-FOREIGN: configured port $PORT is already bound by pid $p (cmdline: $CL), which is not a llama-server process -- refusing to seed, aborting" >&2
                exit 1
                ;;
        esac
    done
fi

# --- Seed the crash-orphan state (the auditor's exact repro) --------------
SEED_LOG="$(mktemp /tmp/verify_crash_recovery.XXXXXX.log)"

"$SERVER_BINARY" \
    -m "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT" \
    -c "$CTX_SIZE" \
    --reasoning-format "$REASONING_FORMAT" \
    --jinja \
    >"$SEED_LOG" 2>&1 &
SEED_PID=$!

HEALTH_URL="http://$HOST:$PORT/health"
SEED_READY=0
for _ in $(seq 1 300); do
    if ! kill -0 "$SEED_PID" 2>/dev/null; then
        echo "PRECONDITION-UNMET: seeded llama-server exited before becoming healthy -- see $SEED_LOG" >&2
        cat "$SEED_LOG" >&2
        exit 1
    fi
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ]; then
        SEED_READY=1
        break
    fi
    sleep 0.5
done

if [ "$SEED_READY" -ne 1 ]; then
    echo "FAIL-SEED-NOT-READY: seeded llama-server never reported healthy on $HEALTH_URL within budget" >&2
    exit 1
fi

echo "SEEDED pid=$SEED_PID port=$PORT"

# Write the stale PID-file at the exact path the game reads (user://
# llm_server.pid resolves here for this project) -- this is the
# crash-orphan state: a genuinely-alive process this Godot instance did
# not spawn, tracked only by a leftover file.
mkdir -p "$(dirname "$PID_FILE")"
printf '%s' "$SEED_PID" >"$PID_FILE"

# --- Seed a harmless decoy alongside the genuine orphan (ASSERT-E, --------
# Amendment 5) ---------------------------------------------------------------
# argv[0] is deliberately NOT "llama-server" -- a real never-exiting `sleep`
# whose own argv[0] is overridden (via `exec -a`) to the auditor's exact
# repro text, a single argument whose free-form TEXT happens to contain
# both needle substrings a naive substring-over-joined-cmdline identity
# check would key on. A correct (argv-token-exact) identity check must
# never touch this process; only a substring-matching one would.
DECOY_TAG="--tag=watching for llama-server --port $PORT in logs"
bash -c 'exec -a "$1" sleep 600' _ "$DECOY_TAG" &
DECOY_PID=$!
sleep 0.3
if ! kill -0 "$DECOY_PID" 2>/dev/null; then
    echo "FAIL-ASSERT-E-SEED-FAILED: decoy process (pid $DECOY_PID) did not stay alive after spawn" >&2
    exit 1
fi
DECOY_CMDLINE="$(tr '\0' ' ' <"/proc/$DECOY_PID/cmdline" 2>/dev/null)"
case "$DECOY_CMDLINE" in
    *llama-server*"--port $PORT"*) : ;;
    *)
        echo "FAIL-ASSERT-E-SEED-FAILED: decoy cmdline does not contain both needles -- got: [$DECOY_CMDLINE]" >&2
        exit 1
        ;;
esac
echo "DECOY-SEEDED pid=$DECOY_PID cmdline=[$DECOY_CMDLINE]"

# --- Run one full DECOHERENCE_PROBE=1 boot (DOD-34-style) ------------------
PROBE_LOG="$(mktemp /tmp/verify_crash_recovery.XXXXXX.probelog)"
DECOHERENCE_PROBE=1 DISPLAY=:99 timeout 300 "$GODOT" --path "$REPO_ROOT" >"$PROBE_LOG" 2>&1

# --- Assertions -------------------------------------------------------------

# (a) probe completed with a real reply.
REPLY_LEN="$(grep -oE 'PROBE_OK reply_len=[0-9]+' "$PROBE_LOG" | tail -1 | grep -oE '[0-9]+$')"
[ -z "$REPLY_LEN" ] && REPLY_LEN=0
if [ "$REPLY_LEN" -ge 1 ]; then
    echo "ASSERT-A-OK: probe completed with a real reply, reply_len=$REPLY_LEN"
else
    record_failure "ASSERT-A-NO-REPLY: probe never printed 'PROBE_OK reply_len=<N>=1'; transcript tail follows"
    tail -30 "$PROBE_LOG" >&2
fi

# Grace period before checking post-quit process/port state, mirrors
# DOD-34's own 1s post-quit liveness check.
sleep 1

# (b) zero processes system-wide (not merely "the pid this run spawned")
# whose cmdline contains both llama-server and the configured --port.
SURVIVORS="$(sweep_port_survivors | sort -u | tr '\n' ' ')"
SURVIVORS="$(echo "$SURVIVORS" | xargs)"
if [ -z "$SURVIVORS" ]; then
    echo "ASSERT-B-OK: zero llama-server processes bound to port $PORT survive system-wide"
else
    record_failure "ASSERT-B-ORPHAN-SURVIVED: surviving pid(s) [$SURVIVORS] still bound to port $PORT after clean quit (seeded pid was $SEED_PID)"
fi

# (c) the configured port is free.
if ss -tln 2>/dev/null | awk -v p=":$PORT" '$4 ~ (p"$") { found=1 } END { exit !found }'; then
    record_failure "ASSERT-C-PORT-STILL-BOUND: port $PORT still has a listener after quit"
else
    echo "ASSERT-C-OK: port $PORT is free"
fi

# (d) marker honesty -- if LLM_ORPHAN_CLEANED was printed, the seeded pid
# must actually be dead by end-of-run (the marker must not lie).
if grep -q "LLM_ORPHAN_CLEANED" "$PROBE_LOG"; then
    if kill -0 "$SEED_PID" 2>/dev/null; then
        record_failure "ASSERT-D-MARKER-LIED: transcript printed LLM_ORPHAN_CLEANED but seeded pid $SEED_PID is still alive"
    else
        echo "ASSERT-D-OK: LLM_ORPHAN_CLEANED printed and seeded pid $SEED_PID is genuinely dead"
    fi
else
    echo "ASSERT-D-OK: LLM_ORPHAN_CLEANED not printed this run (nothing to verify)"
fi

# (e) identity precision (Amendment 5) -- the decoy's argv[0] was never
# "llama-server"; a correct (argv-token-exact) identity check must leave it
# alone even though its argument TEXT contains both needle substrings. If
# the reclaim pass killed it, identity matching is (still) a naive
# substring search over the joined cmdline, not argv-token-exact.
if kill -0 "$DECOY_PID" 2>/dev/null; then
    echo "ASSERT-E-OK: decoy pid $DECOY_PID survived -- identity check did not substring-match its argument text"
else
    record_failure "ASSERT-E-FAIL: decoy pid $DECOY_PID was killed -- identity check substring-matched its argument text instead of requiring argv-token-exact identity"
fi

if [ "${#FAILURES[@]}" -eq 0 ]; then
    echo "PASS: crash-orphan reclaimed cleanly -- real reply, zero survivors, port free, markers honest"
    exit 0
else
    echo "OVERALL-FAIL: ${#FAILURES[@]} assertion(s) failed: ${FAILURES[*]}" >&2
    exit 1
fi
