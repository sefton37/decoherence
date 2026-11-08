#!/usr/bin/env bash
## tools/build_engine.sh -- Spec #501 build for the Stalag engine GDExtension.
##
## Idempotent. Creates, all gitignored and all under engine/stalag/:
##   .venv/       a Python venv holding SCons (nothing installed system-wide)
##   godot-cpp/   the godot-cpp C++ bindings, pinned to tag godot-4.5-stable
##   bin/         the built shared library (libstalag.linux.template_release.x86_64.so)
##
## The one disclosed network-egress point (pip + git clone) happens on the FIRST run
## only; later runs just let SCons rebuild whatever changed. Linux x86_64
## template_release only, like the Spec #494 spike (tools/setup_gdext.sh, untouched).
##
## Usage: tools/build_engine.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="$REPO_ROOT/engine/stalag"
VENV_DIR="$EXT_DIR/.venv"
CPP_DIR="$EXT_DIR/godot-cpp"
GODOT_CPP_URL="https://github.com/godotengine/godot-cpp.git"
GODOT_CPP_TAG="godot-4.5-stable"
LIB="$EXT_DIR/bin/libstalag.linux.template_release.x86_64.so"

log() { echo "[build_engine] $*"; }

if [ ! -x "$VENV_DIR/bin/scons" ]; then
    log "creating venv + installing scons"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet scons
fi

if [ ! -d "$CPP_DIR/.git" ]; then
    log "cloning godot-cpp @ $GODOT_CPP_TAG"
    git clone --quiet --depth 1 --branch "$GODOT_CPP_TAG" "$GODOT_CPP_URL" "$CPP_DIR"
fi

# Keep the Godot editor from scanning the toolchain trees (thousands of files).
touch "$VENV_DIR/.gdignore" "$CPP_DIR/.gdignore"

log "building (template_release, linux x86_64, -j$(nproc))"
(cd "$EXT_DIR" && PATH="$VENV_DIR/bin:$PATH" scons platform=linux arch=x86_64 target=template_release -j"$(nproc)")

log "library: ${LIB#"$REPO_ROOT"/}"
file -b "$LIB"
