#!/usr/bin/env bash
## tests/verify_stalag_det.sh -- Spec #517 A2 bit-exactness of the engine's numeric primitives.
##
## Generates 5M+ test vectors in JavaScript (tools/baseline/proto_subst.mjs vectors), compiles
## engine/stalag/tests/det_check.cpp (plain g++, no Godot) and compares every result bitwise.
## Headless and GPU-free. Writes
##   {generated_epoch, variant, flags, n_total, pow2_exact_fail, families[{name, n, mismatch}]}
## and exits 0 when it ran to completion; the DoD's jq judges the numbers. A stale output
## file is removed first, so a failed run can never read as fresh.
##
## Env: DET_OUT (required)  output JSON path
##      DET_VARIANT         none (default) | fma | libm_hypot | libm_log2 | libm_trig
##        none          -std=c++17 -O2 -ffp-contract=off, the engine functions
##        fma           -O3 -march=native -ffp-contract=fast (negative control: must mismatch)
##        libm_hypot    the C library hypot instead (negative control)
##        libm_log2     the C library log2 instead (negative control)
##        libm_trig     the C library sin, cos and atan2 instead (negative control)
##        libm_exp      the C library exp and pow instead (negative control, Spec #545)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DET_OUT:?verify_stalag_det: DET_OUT is required}"
VARIANT="${DET_VARIANT:-none}"
case "$VARIANT" in
    none) FLAGS="-std=c++17 -O2 -ffp-contract=off" ;;
    fma) FLAGS="-std=c++17 -O3 -march=native -ffp-contract=fast" ;;
    libm_hypot) FLAGS="-std=c++17 -O2 -ffp-contract=off -DCHECK_LIBM_HYPOT" ;;
    libm_log2) FLAGS="-std=c++17 -O2 -ffp-contract=off -DCHECK_LIBM_LOG2" ;;
    libm_trig) FLAGS="-std=c++17 -O2 -ffp-contract=off -DCHECK_LIBM_TRIG" ;;
    libm_exp) FLAGS="-std=c++17 -O2 -ffp-contract=off -DCHECK_LIBM_EXP" ;;
    *) echo "verify_stalag_det: bad DET_VARIANT '$VARIANT'" >&2; exit 2 ;;
esac

rm -f "$DET_OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$REPO_ROOT/tools/baseline/proto_subst.mjs" vectors "$WORK" </dev/null >&2 \
    || { echo "verify_stalag_det: vector generation failed" >&2; exit 1; }
# shellcheck disable=SC2086
g++ $FLAGS -o "$WORK/det_check" "$REPO_ROOT/engine/stalag/tests/det_check.cpp" \
    || { echo "verify_stalag_det: compile failed" >&2; exit 1; }
"$WORK/det_check" "$WORK/vectors.bin" > "$WORK/result.json" \
    || { echo "verify_stalag_det: det_check failed" >&2; exit 1; }

jq -n --slurpfile r "$WORK/result.json" --arg v "$VARIANT" --arg fl "$FLAGS" \
    '{generated_epoch: now, variant: $v, flags: $fl} + $r[0]' > "$DET_OUT" \
    || { rm -f "$DET_OUT"; exit 1; }
echo "verify_stalag_det: wrote ${DET_OUT##*/} (variant=$VARIANT)" >&2
exit 0
