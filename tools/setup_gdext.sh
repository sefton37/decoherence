#!/usr/bin/env bash
## tools/setup_gdext.sh -- Spec #494 GDExtension toolchain for the engine-language spike.
##
## Idempotent. Creates, all gitignored and all under engine/spike/ext/:
##   .venv/       a Python venv holding SCons (nothing installed system-wide)
##   godot-cpp/   the godot-cpp C++ bindings, pinned to tag godot-4.5-stable
##                (matches the 4.5.stable Godot build; the extension must also
##                target the single-precision editor, not the double sibling)
##   bin/         the built shared library (libstalagspike.linux.template_release.x86_64.so)
##
## This is the one disclosed network-egress point of the spike (pip + git clone).
## The Godot-side spike code never calls it; run_spike.sh only reads what it staged.
##
## Usage: tools/setup_gdext.sh [--force]    (--force rebuilds the library)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="$REPO_ROOT/engine/spike/ext"
VENV_DIR="$EXT_DIR/.venv"
CPP_DIR="$EXT_DIR/godot-cpp"
GODOT_CPP_URL="https://github.com/godotengine/godot-cpp.git"
GODOT_CPP_TAG="godot-4.5-stable"
LIB="$EXT_DIR/bin/libstalagspike.linux.template_release.x86_64.so"

log() { echo "[setup_gdext] $*"; }

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

if [ "${1:-}" = "--force" ] || [ ! -f "$LIB" ]; then
    log "building (template_release, linux x86_64, -j$(nproc))"
    (cd "$EXT_DIR" && PATH="$VENV_DIR/bin:$PATH" scons platform=linux arch=x86_64 target=template_release -j"$(nproc)")
fi

log "library: $LIB"
file -b "$LIB"
