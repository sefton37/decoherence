#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
## tests/verify_relief.sh -- Spec 582 S2. Builds engine/stalag/tests/relief_check.cpp
## from the engine sources with plain g++ (never a prebuilt library) and writes RELIEF_OUT.
## Provenance: written for this project; pattern of tests/verify_stalag_det.sh.
## Env: RELIEF_OUT (required)  RELIEF_VARIANT none|window26|ext224|mutate_valley  RELIEF_SRC (default engine/stalag/src)
set -uo pipefail
REPO_ROOT="${RELIEF_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${RELIEF_OUT:?verify_relief: RELIEF_OUT is required}"
V="${RELIEF_VARIANT:-none}"
SRC="${RELIEF_SRC:-$REPO_ROOT/engine/stalag/src}"
case "$V" in none|window26|ext224|mutate_valley) ;; *) echo "verify_relief: bad RELIEF_VARIANT '$V'" >&2; exit 2 ;; esac
rm -f "$RELIEF_OUT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$SRC"/*.cpp "$SRC"/*.h "$WORK"/ || exit 1
applied=true; ext=1792
case "$V" in
  window26) sed -i -E 's/^([[:space:]]*(const )?int cy_hi_const = ).*;/\126;/' "$WORK/stalag_core.cpp"; /usr/bin/grep -qE 'int cy_hi_const = 26;' "$WORK/stalag_core.cpp" || applied=false ;;
  mutate_valley) sed -i 's/return terrain_height(cx, cz, seed)/return 0.5 + terrain_height(cx, cz, seed)/' "$WORK/stalag_core.cpp"; /usr/bin/grep -q 'return 0.5 + terrain_height(cx, cz, seed)' "$WORK/stalag_core.cpp" || applied=false ;;
  ext224) ext=224 ;;
esac
jq -r '.poses[]|[.id,.cam[0],.cam[1],.height_m,.heading_deg,.horizon_frac,.fov_deg]|@tsv' "$REPO_ROOT/tools/scenic/horizon_poses.json" > "$WORK/poses.tsv" || exit 1
g++ -std=c++17 -O2 -ffp-contract=off -fexceptions -I"$WORK" -o "$WORK/relief_check" "$REPO_ROOT/engine/stalag/tests/relief_check.cpp" "$WORK/stalag_core.cpp" "$WORK/stalag_plan.cpp" -lpthread || { echo "verify_relief: compile failed" >&2; exit 1; }
"$WORK/relief_check" "$ext" "$WORK/poses.tsv" > "$WORK/r.json" || { echo "verify_relief: relief_check failed" >&2; exit 1; }
jq --arg v "$V" --argjson ap "$applied" --arg head "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)" '{generated_epoch: now, variant: $v, control_applied: $ap, repo_head: $head} + .' "$WORK/r.json" > "$RELIEF_OUT" || { rm -f "$RELIEF_OUT"; exit 1; }
echo "verify_relief: wrote $RELIEF_OUT (variant=$V)" >&2
