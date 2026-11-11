#!/usr/bin/env bash
## SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_ground_fields.sh -- Spec #551 phase 2: the ground fields, measured against a FRESH
## survey of the world. The frozen Stalag prototype (tag prototype-final) is the origin of the world;
## this wrapper asks the engine for it again, headless and GPU-free, through its own bound queries
## (engine/stalag/tests/ground_survey.gd), re-bakes the fields (tools/bake_ground_fields.mjs), and
## compares them with the committed images in game/world/assets/ground/. It also runs the independent
## oracle and the rule-order invariants. It only MEASURES: exit 0 means "ran to completion and wrote
## a record"; the stored checks judge. A stale record can never read as fresh: the output is
## truncated first, and so is the survey's metadata before the survey runs.
##
## Record: {generated_epoch, phase, plan_hash, survey_columns, fresh_equals_committed{top, wall, sha},
##          oracle_equals_committed, oracle_equals_fresh, counts{...}, violations{...}, field_sha256{...}}
##
## Env: GFIELDS_OUT (required)   the JSON record; the survey lands beside it in <GFIELDS_OUT>.survey/
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${GFIELDS_OUT:?verify_ground_fields: GFIELDS_OUT is required}"
unset WAYLAND_DISPLAY

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_ground_fields: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

SURVEY="$GFIELDS_OUT.survey"
mkdir -p "$SURVEY"
: > "$GFIELDS_OUT"
: > "$SURVEY/meta.json"

# 1. make sure the project is scanned (class names, extension) before the script run
timeout 180 "$GODOT" --audio-driver Dummy --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# 2. the survey, through the engine's bound queries
GFIELDS_SURVEY_DIR="$SURVEY" \
    timeout 600 "$GODOT" --audio-driver Dummy --headless --path "$REPO_ROOT" -s res://engine/stalag/tests/ground_survey.gd </dev/null >&2
[ -s "$SURVEY/meta.json" ] || { echo "verify_ground_fields: the survey wrote nothing" >&2; exit 1; }

# 3. bake fresh, compare with the committed images, run the oracle and the invariants
"$REPO_ROOT/tools/bake_ground_fields.mjs" check "$SURVEY" "$REPO_ROOT/game/world/assets/ground" "$GFIELDS_OUT" </dev/null >&2 \
    || { echo "verify_ground_fields: the baker failed" >&2; exit 1; }
[ -s "$GFIELDS_OUT" ] || { echo "verify_ground_fields: the baker wrote no record" >&2; exit 1; }
echo "verify_ground_fields: record written" >&2
exit 0
