#!/usr/bin/env bash
## tests/verify_stalag_trees.sh -- Spec #549 tree, wildflower and shrub PLACEMENT measurement.
##
## HEADLESS and GPU-free. Runs the frozen prototype's oracle FRESH (tools/baseline/js_trees_oracle.mjs,
## tag prototype-final, clean-room primitives substituted), then the engine probe
## (engine/stalag/tests/trees_probe.gd), and merges both sides into one record whose keys are the
## contract of Spec #549 section 4: placement, flowers, shrubs, meadow_thinned (plus the asset and
## guard sections the later phases add).
## This wrapper only MEASURES. Exit 0 means "ran to completion and wrote a record"; the DoD's jq
## judges. It deletes any stale output first, so a failed run can never read as fresh.
##
## Env: TREES_OUT (required)   output JSON path
##      TREES_MUTATE           none | lid_shift | flood_ignore | clearing_off | salt_swap | grove_off |
##                             landmark_lean | hue_exempt | euler_order | asset_flip | flower_floor |
##                             sensor_gap_off | trunk_gate_off | flower_gate_off | thin_off | thin_all |
##                             tier_swap | u_asset_flip
##      GODOT (default ~/.local/bin/godot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${TREES_OUT:?verify_stalag_trees: TREES_OUT is required}"
MUTATE="${TREES_MUTATE:-none}"
case "$MUTATE" in
    none|lid_shift|flood_ignore|clearing_off|salt_swap|grove_off|landmark_lean|hue_exempt|euler_order|asset_flip) ;;
    flower_floor|sensor_gap_off|trunk_gate_off|flower_gate_off|thin_off|thin_all|tier_swap|u_asset_flip) ;;
    *) echo "verify_stalag_trees: bad TREES_MUTATE '$MUTATE'" >&2; exit 2 ;;
esac

[ -f "$REPO_ROOT/engine/stalag/bin/libstalag.linux.template_release.x86_64.so" ] \
    || { echo "verify_stalag_trees: engine library missing; run tools/build_engine.sh" >&2; exit 1; }

rm -f "$TREES_OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. the oracle, fresh
TREES_ORACLE_OUT="$WORK/oracle" "$REPO_ROOT/tools/baseline/js_trees_oracle.mjs" </dev/null >&2 \
    || { echo "verify_stalag_trees: oracle failed" >&2; exit 1; }

# 1b. the bake, fresh: the JS side of the asset comparison (the committed assets are what the engine loads)
"$REPO_ROOT/tools/bake_trees.mjs" "$WORK/bake" </dev/null >&2 \
    || { echo "verify_stalag_trees: bake failed" >&2; exit 1; }

# 2. scan the project once so class names and the extension are registered
timeout 180 "$GODOT" --headless --audio-driver Dummy --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

# 3. the engine probe
TREES_PROBE_RAW="$WORK/gd.json" TREES_BAKE_DIR="$WORK/bake" TREES_MUTATE="$MUTATE" \
    timeout 900 "$GODOT" --headless --audio-driver Dummy --path "$REPO_ROOT" -s res://engine/stalag/tests/trees_probe.gd </dev/null >&2
[ -s "$WORK/gd.json" ] || { echo "verify_stalag_trees: engine probe wrote nothing" >&2; exit 1; }

# 3b. the charter frequency guards, on the shipped shaders (full-expression resolver, negative controls)
"$REPO_ROOT/engine/stalag/tests/leaf_guard.mjs" "$REPO_ROOT" > "$WORK/guard.json" </dev/null \
    || { echo "verify_stalag_trees: frequency guard failed to run" >&2; exit 1; }

# 4. merge. The JS numbers come straight from the oracle's own JSON, never through Godot.
jq -n --slurpfile gd "$WORK/gd.json" --slurpfile o "$WORK/oracle/oracle.json" --slurpfile gu "$WORK/guard.json" --arg mut "$MUTATE" '
  $gd[0] as $g | $o[0] as $j |
  def zipobj($ids; $vals): [range(0; ($ids | length))] | map({key: $ids[.], value: $vals[.]}) | from_entries;
  {
    generated_epoch: now,
    mutation: $mut,
    headless: true,
    js_stalag_head: $j.stalag_head,
    oracle_subst: $j.oracle_subst,
    classes: $g.classes,
    world: $g.world,
    placement: {
      total_js: $j.placement.total,
      total_gd: $g.placement.total_gd,
      determinism_equal: $g.placement.determinism_equal,
      within_clearing: $g.placement.within_clearing,
      clearing_m: $g.placement.clearing_m,
      nearest_root_m_js: $j.placement.nearest_root_m,
      nearest_root_m_gd: $g.placement.nearest_root_m_gd,
      flooded_or_course: $g.placement.flooded_or_course,
      off_lid: $g.placement.off_lid,
      forms: [range(0; ($j.placement.forms | length))] | map(. as $i | {
        id: $j.placement.forms[$i].id,
        js_count: $j.placement.forms[$i].count, gd_count: $g.placement.forms[$i].gd_count,
        js_hash: $j.placement.forms[$i].hash, gd_hash: $g.placement.forms[$i].gd_hash,
        mx_js_hash: $j.placement.forms[$i].mx_hash, mx_gd_hash: $g.placement.forms[$i].mx_gd_hash,
        col_js_hash: $j.placement.forms[$i].col_hash, col_gd_hash: $g.placement.forms[$i].col_gd_hash }),
      chunks: {
        count: $g.placement.chunks.count,
        js_hash: $j.placement.chunks.hash, gd_union_hash: $g.placement.chunks.gd_union_hash,
        dup: ([$g.placement.chunks.sum - $j.placement.chunks.total, 0] | max),
        missing: ([$j.placement.chunks.total - $g.placement.chunks.sum, 0] | max)
      },
      ring: {
        rule: $g.placement.ring.rule, coord_min: $g.placement.ring.coord_min, coord_max: $g.placement.ring.coord_max,
        chunks: $g.placement.ring.chunks,
        trees_js: $j.placement.ring.trees, trees_gd: $g.placement.ring.trees_gd,
        chunks_with_trees_js: $j.placement.ring.chunks_with_trees, chunks_with_trees_gd: $g.placement.ring.chunks_with_trees_gd,
        per_form_js: zipobj([$j.placement.forms[].id]; $j.placement.ring.per_form),
        per_form_gd: $g.placement.ring.per_form_gd
      },
      ported_checks: $g.placement.ported_checks
    },
    flowers: {
      total_js: $j.flowers.total, total_gd: $g.flowers.total_gd,
      forms: [range(0; ($j.flowers.forms | length))] | map(. as $i | {
        id: $j.flowers.forms[$i].id,
        js_count: $j.flowers.forms[$i].count, gd_count: $g.flowers.forms[$i].gd_count,
        js_hash: $j.flowers.forms[$i].hash, gd_hash: $g.flowers.forms[$i].gd_hash,
        muted_js: $j.flowers.forms[$i].muted, vivid_js: $j.flowers.forms[$i].vivid,
        muted_gd: $g.flowers.forms[$i].muted_gd, vivid_gd: $g.flowers.forms[$i].vivid_gd }),
      lid_keys_js: $j.flowers.lid_keys, lid_keys_gd: $g.flowers.lid_keys_gd,
      off_lid: $g.flowers.off_lid, flooded_or_course: $g.flowers.flooded_or_course,
      sensor_min_gap_m: $g.flowers.sensor_min_gap_m,
      nearest_root_m_ring_js: $j.flowers.ring.nearest_root_m, nearest_root_m_ring_gd: $g.flowers.nearest_root_m_ring_gd,
      ported_checks: $g.flowers.ported_checks,
      ring: {
        total_js: $j.flowers.ring.total, total_gd: $g.flowers.ring.total_gd,
        per_form_js: zipobj($j.flowers.ids; $j.flowers.ring.per_form), per_form_gd: $g.flowers.ring.per_form_gd,
        chunks_with_js: $j.flowers.ring.chunks_with, chunks_with_gd: $g.flowers.ring.chunks_with_gd
      }
    },
    shrubs: {
      total_js: $j.shrubs.total, total_gd: $g.shrubs.total_gd,
      forms: [range(0; ($j.shrubs.forms | length))] | map(. as $i | {
        id: $j.shrubs.forms[$i].id,
        js_count: $j.shrubs.forms[$i].count, gd_count: $g.shrubs.forms[$i].gd_count,
        js_hash: $j.shrubs.forms[$i].hash, gd_hash: $g.shrubs.forms[$i].gd_hash }),
      lid_keys_js: $j.shrubs.lid_keys, lid_keys_gd: $g.shrubs.lid_keys_gd,
      off_lid: $g.shrubs.off_lid, flooded_or_course: $g.shrubs.flooded_or_course,
      clearing_m: $g.shrubs.clearing_m, within_clearing: $g.shrubs.within_clearing,
      min_tree_dist_m: $g.shrubs.min_tree_dist_m, in_flower_lids: $g.shrubs.in_flower_lids,
      nearest_root_m_ring_js: $j.shrubs.ring.nearest_root_m, nearest_root_m_ring_gd: $g.shrubs.nearest_root_m_ring_gd,
      ported_checks: $g.shrubs.ported_checks,
      ring: {
        total_js: $j.shrubs.ring.total, total_gd: $g.shrubs.ring.total_gd,
        per_form_js: zipobj($j.shrubs.ids; $j.shrubs.ring.per_form), per_form_gd: $g.shrubs.ring.per_form_gd,
        chunks_with_js: $j.shrubs.ring.chunks_with, chunks_with_gd: $g.shrubs.ring.chunks_with_gd
      }
    },
    leaf_guard: $gu[0].leaf_guard,
    shrub_guard: $gu[0].shrub_guard,
    assets: $g.assets,
    understory_assets: $g.understory_assets,
    meadow_thinned: {
      rule: $g.meadow_thinned.rule, grass_forms: $g.meadow_thinned.grass_forms,
      raw_total: $g.meadow_thinned.raw_total,
      world_total_js: $j.meadow_thinned.world_total, world_total_gd: $g.meadow_thinned.world_total_gd,
      ring_total_js: $j.meadow_thinned.ring_total, ring_total_gd: $g.meadow_thinned.ring_total_gd,
      removed_world: $g.meadow_thinned.removed_world, removed_ring: $g.meadow_thinned.removed_ring,
      non_grass_removed: $g.meadow_thinned.non_grass_removed,
      world_per_form_js: $j.meadow_thinned.world_per_form, world_per_form_gd: $g.meadow_thinned.world_per_form_gd,
      ring_per_form_js: $j.meadow_thinned.ring_per_form, ring_per_form_gd: $g.meadow_thinned.ring_per_form_gd
    }
  }' > "$TREES_OUT" || { echo "verify_stalag_trees: merge failed" >&2; rm -f "$TREES_OUT"; exit 1; }
echo "verify_stalag_trees: wrote ${TREES_OUT##*/} (mutation=$MUTATE)" >&2
exit 0
