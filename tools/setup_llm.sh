#!/usr/bin/env bash
## tools/setup_llm.sh -- Spec #387 one-time llama-server + model acquisition.
##
## Tracked, executable. NEVER invoked automatically by the game itself --
## this is the one-time, disclosed, Kel-sanctioned network-egress point
## (llm_client.gd never calls this; it only ever reads what this script
## already staged). Every output path below is anchored to REPO_ROOT,
## resolved from this script's OWN location -- never $PWD -- so running
## it as `./tools/setup_llm.sh`, `bash tools/setup_llm.sh` from a parent
## directory, or via an absolute path all land in the same place.
##
## Two acquisition modes, selectable as the first positional arg (default
## "auto" picks whichever applies to this machine):
##
##   auto      Prefer the local-acceleration shortcut below when this
##             box already has the sources; fall back to the portable
##             fetch path per-artifact otherwise. Never performs network
##             egress when a local source already satisfies an artifact.
##   --local   Force the local-acceleration shortcut (fails loudly if this
##             box doesn't have the local sources).
##   --fetch   Force the portable path: builds llama.cpp from a fresh
##             clone and fetches the GGUF from Hugging Face via the `hf`
##             CLI. This is the path a machine with neither local source
##             must use, and the one real, disclosed network-egress point
##             this whole spec permits.
##
## Local-acceleration shortcut (this box, and any box with the same two
## local resources already present):
##   - Binary: copies the ENTIRE existing llama.cpp build/bin/ directory
##     (the llama-server executable together with every sibling .so it
##     links against -- ldd confirms they resolve relative to the
##     binary's own directory, so copying just the executable would
##     silently break at runtime) from ~/llm/llama.cpp/build/bin/.
##   - Model: copies (never moves/symlinks -- the source is Ollama's own
##     read-only blob store) the qwen3:4b GGUF blob Ollama already has on
##     disk, located via `ollama show qwen3:4b --modelfile`'s `FROM` line
##     -- that blob IS a plain GGUF file, just without the extension.
##
## Everything lands under $REPO_ROOT/llm/ (gitignored) -- nothing is ever
## written outside the repo, and nothing under llm/ is ever tracked.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLM_DIR="$REPO_ROOT/llm"
BUILD_BIN_DIR="$LLM_DIR/llama.cpp/build/bin"
MODELS_DIR="$LLM_DIR/models"

LOCAL_LLAMACPP_BUILD_BIN="$HOME/llm/llama.cpp/build/bin"

LLAMACPP_GIT_URL="https://github.com/ggml-org/llama.cpp.git"
HF_MODEL_REPO="Qwen/Qwen3-4B-GGUF"
HF_MODEL_INCLUDE="*Q4_K_M.gguf"
MODEL_DEST_NAME="qwen3-4b.gguf"

MODE="${1:-auto}"

log() {
    echo "[setup_llm] $*"
}

## Resolves Ollama's on-disk blob path for qwen3:4b, or prints nothing if
## Ollama isn't installed or doesn't have that model pulled.
resolve_ollama_qwen3_blob() {
    command -v ollama >/dev/null 2>&1 || return 1
    ollama show qwen3:4b --modelfile 2>/dev/null | awk '/^FROM /{print $2; exit}'
}

stage_binary_local() {
    if [ ! -x "$LOCAL_LLAMACPP_BUILD_BIN/llama-server" ]; then
        return 1
    fi
    log "Staging llama-server + sibling libraries from $LOCAL_LLAMACPP_BUILD_BIN (local, no network egress)"
    mkdir -p "$BUILD_BIN_DIR"
    cp -n "$LOCAL_LLAMACPP_BUILD_BIN/llama-server" "$BUILD_BIN_DIR/"
    for so in "$LOCAL_LLAMACPP_BUILD_BIN"/*.so*; do
        [ -e "$so" ] && cp -n "$so" "$BUILD_BIN_DIR/"
    done
    chmod +x "$BUILD_BIN_DIR/llama-server"
}

build_binary_from_source() {
    log "No local llama.cpp build available -- cloning + building from source (real network egress, ~10-20 min on a CUDA machine)"
    mkdir -p "$LLM_DIR"
    if [ ! -d "$LLM_DIR/llama.cpp" ]; then
        git clone "$LLAMACPP_GIT_URL" "$LLM_DIR/llama.cpp"
    fi
    (
        cd "$LLM_DIR/llama.cpp"
        cmake -B build -DGGML_CUDA=ON
        cmake --build build --config Release -j"$(nproc)" --target llama-server
    )
    mkdir -p "$BUILD_BIN_DIR"
}

stage_model_local() {
    local blob
    blob="$(resolve_ollama_qwen3_blob || true)"
    if [ -z "$blob" ] || [ ! -f "$blob" ]; then
        return 1
    fi
    log "Staging qwen3:4b GGUF from Ollama's own model blob at $blob (local, no network egress, read-only copy)"
    mkdir -p "$MODELS_DIR"
    cp -n "$blob" "$MODELS_DIR/$MODEL_DEST_NAME"
}

fetch_model_hf() {
    log "Fetching GGUF from Hugging Face: $HF_MODEL_REPO ($HF_MODEL_INCLUDE) -- real network egress"
    mkdir -p "$MODELS_DIR"
    hf download "$HF_MODEL_REPO" --include "$HF_MODEL_INCLUDE" --local-dir "$MODELS_DIR"
    if [ ! -f "$MODELS_DIR/$MODEL_DEST_NAME" ]; then
        local fetched
        fetched="$(find "$MODELS_DIR" -maxdepth 2 -iname '*.gguf' | head -1)"
        [ -n "$fetched" ] && mv "$fetched" "$MODELS_DIR/$MODEL_DEST_NAME"
    fi
}

case "$MODE" in
    --local)
        stage_binary_local || { echo "[setup_llm] ERROR: no local llama.cpp build at $LOCAL_LLAMACPP_BUILD_BIN" >&2; exit 1; }
        stage_model_local || { echo "[setup_llm] ERROR: no local Ollama qwen3:4b blob found" >&2; exit 1; }
        ;;
    --fetch)
        build_binary_from_source
        fetch_model_hf
        ;;
    auto)
        stage_binary_local || build_binary_from_source
        stage_model_local || fetch_model_hf
        ;;
    *)
        echo "[setup_llm] usage: $0 [auto|--local|--fetch]" >&2
        exit 1
        ;;
esac

log "Done."
log "Binary:    $BUILD_BIN_DIR/llama-server"
log "Model dir: $MODELS_DIR"
log "Nothing here is ever written outside $LLM_DIR (gitignored), and this script is never invoked automatically by the game."
