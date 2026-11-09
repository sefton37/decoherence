#!/usr/bin/env bash
## tests/verify_stalag_plan.sh -- Spec #517 water-plan / terrain / water-mesh MEASUREMENT.
##
## HEADLESS and GPU-free (safe to run while the desktop is in use). Runs the frozen
## prototype's oracle FRESH (tools/baseline/js_world_oracle.mjs: world seed 7, carve ON, the
## frozen prototype with the three Spec #517 A2 primitives substituted), then the engine probe (engine/stalag/tests/plan_probe.gd) on the
## same regions, and merges both sides into one record:
##   {generated_epoch, mutation, headless, js_stalag_head,
##    plan{seed, dim, g0, js_hash, gd_hash, solve_ms, solve_on_main_thread, type_counts_js,
##         type_counts_gd, arrays[7]{name, n, exact_mismatch, over_tol, max_abs_diff, ...}},
##    queries{functions[7]{name, n, wet_n, mismatch}, surface_height{...}},
##    terrain{regions[{region, carve_nonzero_cols, js{}, gd{}}], neg_control{differs}, thread_safety},
##    water{regions[{kind, region, js{}, gd{}}], seam{full_tris,left_tris,right_tris},
##          neg_control{differs}, thread_safety}}
## This wrapper only MEASURES. Exit 0 means "ran to completion and wrote a record"; the DoD's
## jq judges. It deletes any stale output first, so a failed run can never read as fresh.
##
## Env: STALAG_PLAN_OUT (required)   output JSON path
##      STALAG_PLAN_ORACLE_SUBST     oracle substitution mode: lowbias32 (default) | none | hypot_native | log2_native;
##                                   recorded as oracle_subst (none is the negative control: the engine must then disagree)
##      STALAG_PLAN_MUTATE           none | carve_off | flood_off | water_shift (negative controls)
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${STALAG_PLAN_OUT:?verify_stalag_plan: STALAG_PLAN_OUT is required}"
MUTATE="${STALAG_PLAN_MUTATE:-none}"
SUBST="${STALAG_PLAN_ORACLE_SUBST:-lowbias32}"
case "$MUTATE" in none|carve_off|flood_off|water_shift) ;; *) echo "verify_stalag_plan: bad STALAG_PLAN_MUTATE '$MUTATE'" >&2; exit 2 ;; esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_plan: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

rm -f "$STALAG_PLAN_OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. the oracle, fresh (it chooses its regions from the plan it solves)
WORLD_ORACLE_SUBST="$SUBST" WORLD_ORACLE_OUT="$WORK/oracle" "$REPO_ROOT/tools/baseline/js_world_oracle.mjs" </dev/null >&2 \
    || { echo "verify_stalag_plan: oracle failed" >&2; exit 1; }

# 2. make sure the project is scanned (class names, extension) before the script run
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# 3. the engine probe
STALAG_PLAN_RAW="$WORK/gd.json" STALAG_PLAN_ORACLE="$WORK/oracle" STALAG_PLAN_MUTATE="$MUTATE" \
    timeout 900 "$GODOT" --headless --path "$REPO_ROOT" -s res://engine/stalag/tests/plan_probe.gd </dev/null >&2
[ -s "$WORK/gd.json" ] || { echo "verify_stalag_plan: engine probe wrote nothing" >&2; exit 1; }

# 4. merge. The JS numbers come straight from the oracle's own JSON, never through Godot.
jq -n --slurpfile gd "$WORK/gd.json" --slurpfile o "$WORK/oracle/oracle.json" --arg mut "$MUTATE" --arg subst "$SUBST" '
  $gd[0] as $g | $o[0] as $j |
  def strip_t: del(.region, .carve_nonzero_cols);
  def strip_w: del(.region, .kind);
  {
    generated_epoch: now,
    mutation: $mut,
    oracle_subst: $subst,
    headless: true,
    js_stalag_head: $j.stalag_head,
    plan: ($g.plan + {seed: $j.plan.seed, dim: $j.plan.dim, g0: $j.plan.g0}),
    queries: $g.queries,
    terrain: {
      regions: [range(0; ($j.terrain_regions | length))] | map(
        . as $i | {region: $j.terrain_regions[$i].region,
                   carve_nonzero_cols: $j.terrain_regions[$i].carve_nonzero_cols,
                   js: ($j.terrain_regions[$i] | strip_t),
                   gd: $g.terrain.regions[$i].gd}),
      neg_control: {region: $g.terrain.neg_control.region, shift_m: $g.terrain.neg_control.shift_m,
                    differs: (($j.terrain_regions[0] | strip_t) != $g.terrain.neg_control.gd_shifted)},
      thread_safety: $g.terrain.thread_safety
    },
    water: {
      regions: [range(0; ($j.water_regions | length))] | map(
        . as $i | {kind: $j.water_regions[$i].kind, region: $j.water_regions[$i].region,
                   js: ($j.water_regions[$i] | strip_w),
                   gd: $g.water.regions[$i].gd}),
      seam: $g.water.seam,
      neg_control: {region: $g.water.neg_control.region, shift_m: $g.water.neg_control.shift_m,
                    differs: ((first($j.water_regions[] | select(.kind == "seam")) | strip_w) != $g.water.neg_control.gd_shifted)},
      thread_safety: $g.water.thread_safety
    }
  }' > "$STALAG_PLAN_OUT" || { echo "verify_stalag_plan: merge failed" >&2; rm -f "$STALAG_PLAN_OUT"; exit 1; }
echo "verify_stalag_plan: wrote ${STALAG_PLAN_OUT##*/} (mutation=$MUTATE)" >&2
exit 0
