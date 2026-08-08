#!/usr/bin/env bash
## tests/verify_no_think_leak.sh -- Spec #387 DOD-33 (MARQUEE) live proof.
##
## Tester-owned, standalone: does NOT call into scripts/llm_client.gd's
## in-game spawn logic at all. Spins up the real llama-server binary
## directly, using the SAME flags the game will use (reasoning-format,
## jinja, ctx from data/llm_config.json), and asserts against the real
## streaming /v1/chat/completions response that:
##
##   (a) leak-zero        -- no literal <think tag and no reasoning_content
##                            text ever appears in the assembled `content`
##                            (displayed) stream;
##   (b) genuine-reasoning -- the reasoning_content delta stream is
##                            NON-EMPTY (closes the "a model that never
##                            reasons trivially passes a leak-absence check"
##                            residual named in spec #387 section 6);
##   (c) terminal `data: [DONE]` was observed.
##
## Expected state RIGHT NOW (Phase 1, before any implementation lands
## data/llm_config.json or tools/setup_llm.sh's output): exits nonzero with
## a PRECONDITION-UNMET diagnostic on stderr. That is this script's honest
## red state, not a bug.
##
## Never touches port 8085 (the game's suggested default) or any other
## pre-bound port -- always asks the OS for a free scratch port. Never
## touches the system Ollama daemon (never references it at all). Always
## kills its own spawned server on every exit path (EXIT trap), and
## verifies the PID is actually gone before reporting success.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$REPO_ROOT/data/llm_config.json"

SRV_PID=""
SRV_LOG=""
RESP_FILE=""

cleanup() {
    if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill "$SRV_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$SRV_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -0 "$SRV_PID" 2>/dev/null && kill -9 "$SRV_PID" 2>/dev/null
    fi
    [ -n "$SRV_LOG" ] && rm -f "$SRV_LOG"
    [ -n "$RESP_FILE" ] && rm -f "$RESP_FILE"
}
trap cleanup EXIT

fail_precondition() {
    echo "PRECONDITION-UNMET: $1" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail_precondition "jq not found on PATH"
command -v curl >/dev/null 2>&1 || fail_precondition "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || fail_precondition "python3 not found on PATH"

if [ ! -f "$CONFIG_PATH" ]; then
    fail_precondition "data/llm_config.json not found at $CONFIG_PATH -- implementer has not created the config seam yet"
fi

REL_SERVER_BINARY="$(jq -r '.server_binary // empty' "$CONFIG_PATH" 2>/dev/null)"
REL_MODEL_PATH="$(jq -r '.model_path // empty' "$CONFIG_PATH" 2>/dev/null)"
CTX_SIZE="$(jq -r '.ctx_size // empty' "$CONFIG_PATH" 2>/dev/null)"
REASONING_FORMAT="$(jq -r '.reasoning_format // empty' "$CONFIG_PATH" 2>/dev/null)"

if [ -z "$REL_SERVER_BINARY" ] || [ -z "$REL_MODEL_PATH" ]; then
    fail_precondition "server_binary/model_path missing or unreadable in $CONFIG_PATH"
fi

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

# Ask the OS for a genuinely free scratch port -- never assume 8085 (or any
# other fixed port) is free, and never touch it if something else holds it.
SCRATCH_PORT="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
SCRATCH_HOST="127.0.0.1"

SRV_LOG="$(mktemp /tmp/verify_no_think_leak.XXXXXX.log)"

"$SERVER_BINARY" \
    -m "$MODEL_PATH" \
    --host "$SCRATCH_HOST" \
    --port "$SCRATCH_PORT" \
    -c "$CTX_SIZE" \
    --reasoning-format "$REASONING_FORMAT" \
    --jinja \
    >"$SRV_LOG" 2>&1 &
SRV_PID=$!

# Poll /health. Connection-refused (curl exit nonzero, code "000") is
# treated as still-loading (listen socket not open yet); HTTP 503 is the
# documented "Loading model" shape; HTTP 200 {"status":"ok"} means ready.
HEALTH_URL="http://$SCRATCH_HOST:$SCRATCH_PORT/health"
READY=0
for _ in $(seq 1 300); do
    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        echo "PRECONDITION-UNMET: llama-server exited before becoming ready -- see $SRV_LOG" >&2
        cat "$SRV_LOG" >&2
        exit 1
    fi
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo 000)"
    if [ "$HTTP_CODE" = "200" ]; then
        READY=1
        break
    fi
    sleep 0.5
done

if [ "$READY" -ne 1 ]; then
    echo "FAIL: llama-server never reported healthy on $HEALTH_URL within budget" >&2
    exit 1
fi

RESP_FILE="$(mktemp /tmp/verify_no_think_leak.XXXXXX.sse)"

curl -s -N \
    -H 'Content-Type: application/json' \
    -X POST "http://$SCRATCH_HOST:$SCRATCH_PORT/v1/chat/completions" \
    -d '{
        "stream": true,
        "messages": [
            {"role": "user", "content": "What is 17 * 24? Think step by step."}
        ]
    }' >"$RESP_FILE"

python3 - "$RESP_FILE" <<'PY'
import json
import sys

path = sys.argv[1]

reasoning_chars = []
content_chars = []
saw_done = False

with open(path, "r", errors="replace") as f:
    for raw_line in f:
        line = raw_line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if payload == "[DONE]":
            saw_done = True
            continue
        if not payload:
            continue
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue
        for choice in obj.get("choices", []):
            delta = choice.get("delta", {}) or {}
            rc = delta.get("reasoning_content")
            if rc:
                reasoning_chars.append(rc)
            c = delta.get("content")
            if c:
                content_chars.append(c)

reasoning_text = "".join(reasoning_chars)
content_text = "".join(content_chars)

errors = []

if not saw_done:
    errors.append("never observed terminal 'data: [DONE]'")

if len(reasoning_text) == 0:
    errors.append(
        "reasoning_content stream was empty -- model never genuinely "
        "reasoned on this prompt (the 'trivial pass' residual named in "
        "spec #387 section 6)"
    )

lowered = content_text.lower()
if "<think" in lowered or "</think" in lowered:
    errors.append("literal <think> tag leaked into the assembled content stream")

if reasoning_text and reasoning_text in content_text:
    errors.append("reasoning_content text leaked verbatim into the assembled content stream")

print("reasoning_content total chars: %d" % len(reasoning_text))
print("content total chars: %d" % len(content_text))
print("saw terminal [DONE]: %s" % saw_done)

if errors:
    for e in errors:
        print("LEAK-CHECK-FAIL: %s" % e, file=sys.stderr)
    sys.exit(1)

print("LEAK-CHECK-OK")
sys.exit(0)
PY
PYTHON_STATUS=$?

# Explicit kill on top of the EXIT trap (belt-and-suspenders).
if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$SRV_PID" 2>/dev/null || break
        sleep 0.2
    done
fi

if kill -0 "$SRV_PID" 2>/dev/null; then
    echo "FAIL: spawned llama-server (pid $SRV_PID) did not exit after kill" >&2
    kill -9 "$SRV_PID" 2>/dev/null
    exit 1
fi

if [ "$PYTHON_STATUS" -ne 0 ]; then
    exit 1
fi

echo "PASS: no think-leak, genuine reasoning observed, clean shutdown (pid $SRV_PID confirmed gone)"
exit 0
