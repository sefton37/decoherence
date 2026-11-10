#!/usr/bin/env bash
## tests/verify_stalag_flora.sh -- Spec #545 wind field and flora PLACEMENT measurement.
##
## HEADLESS and GPU-free. Runs the frozen prototype's oracle FRESH (tools/baseline/js_flora_oracle.mjs,
## tag prototype-final, clean-room primitives substituted), then the engine probe
## (engine/stalag/tests/flora_probe.gd) against the same samples, and merges both sides into one record:
##   {generated_epoch, mutation, headless, js_stalag_head, oracle_subst, classes, world,
##    placement{selected_forms, total_js, total_gd, lids_js, lids_gd, determinism_equal,
##              excluded_forms_leaked, off_lid, flooded_or_course, forms[10]{id, js_count, gd_count, js_hash, gd_hash},
##              chunks{count, js_hash, gd_union_hash, dup, missing}, ported_checks{4}},
##    wind{samples, mismatch, max_abs_err, parts[11]{name, n, mismatch}, exercised{...},
##         ported_checks{15}, js_checks{16}}}
## This wrapper only MEASURES. Exit 0 means "ran to completion and wrote a record"; the DoD's jq
## judges. It deletes any stale output first, so a failed run can never read as fresh.
##
## Env: FLORA_OUT (required)   output JSON path
##      FLORA_MUTATE           none | lid_shift | flood_ignore | salt_swap | wind_no_gust | wind_flow_sign | wind_no_terrain
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${FLORA_OUT:?verify_stalag_flora: FLORA_OUT is required}"
MUTATE="${FLORA_MUTATE:-none}"
case "$MUTATE" in none|lid_shift|flood_ignore|salt_swap|wind_no_gust|wind_flow_sign|wind_no_terrain) ;; *) echo "verify_stalag_flora: bad FLORA_MUTATE '$MUTATE'" >&2; exit 2 ;; esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_flora: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

rm -f "$FLORA_OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. the oracle, fresh
FLORA_ORACLE_OUT="$WORK/oracle" "$REPO_ROOT/tools/baseline/js_flora_oracle.mjs" </dev/null >&2 \
    || { echo "verify_stalag_flora: oracle failed" >&2; exit 1; }

# 2. scan the project once so class names and the extension are registered
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# 3. the engine probe
FLORA_PROBE_RAW="$WORK/gd.json" FLORA_ORACLE_DIR="$WORK/oracle" FLORA_MUTATE="$MUTATE" \
    timeout 900 "$GODOT" --headless --path "$REPO_ROOT" -s res://engine/stalag/tests/flora_probe.gd </dev/null >&2
[ -s "$WORK/gd.json" ] || { echo "verify_stalag_flora: engine probe wrote nothing" >&2; exit 1; }

# 4. merge. The JS numbers come straight from the oracle's own JSON, never through Godot.
jq -n --slurpfile gd "$WORK/gd.json" --slurpfile o "$WORK/oracle/oracle.json" --arg mut "$MUTATE" '
  $gd[0] as $g | $o[0] as $j |
  {
    generated_epoch: now,
    mutation: $mut,
    headless: true,
    js_stalag_head: $j.stalag_head,
    oracle_subst: $j.oracle_subst,
    classes: $g.classes,
    world: $g.world,
    placement: {
      selected_forms: ($j.placement.forms | length),
      total_js: $j.placement.total,
      total_gd: $g.placement.total_gd,
      lids_js: $j.placement.lids,
      lids_gd: $g.placement.lids_gd,
      determinism_equal: $g.placement.determinism_equal,
      excluded_forms_leaked: $g.placement.excluded_forms_leaked,
      off_lid: $g.placement.off_lid,
      flooded_or_course: $g.placement.flooded_or_course,
      forms: [range(0; ($j.placement.forms | length))] | map(. as $i | {
        id: $j.placement.forms[$i].id,
        js_count: $j.placement.forms[$i].count, gd_count: $g.placement.forms[$i].gd_count,
        js_hash: $j.placement.forms[$i].hash, gd_hash: $g.placement.forms[$i].gd_hash }),
      chunks: {
        count: $g.placement.chunks.count,
        js_hash: $j.placement.chunks.hash, gd_union_hash: $g.placement.chunks.gd_union_hash,
        dup: ([$g.placement.chunks.sum - $j.placement.chunks.total, 0] | max),
        missing: ([$j.placement.chunks.total - $g.placement.chunks.sum, 0] | max)
      },
      ported_checks: $g.placement.ported_checks
    },
    wind: {
      samples: $g.wind.samples,
      mismatch: $g.wind.mismatch,
      max_abs_err: $g.wind.max_abs_err,
      parts: $g.wind.parts,
      exercised: $j.wind.exercised,
      ported_checks: $g.wind.ported_checks,
      js_checks: $j.wind.js_checks
    }
  }' > "$FLORA_OUT" || { echo "verify_stalag_flora: merge failed" >&2; rm -f "$FLORA_OUT"; exit 1; }
echo "verify_stalag_flora: wrote ${FLORA_OUT##*/} (mutation=$MUTATE)" >&2
exit 0
