#!/usr/bin/env bash
## tests/verify_stalag_parity.sh -- Spec #501 engine-vs-JS parity MEASUREMENT.
##
## Runs the frozen prototype's buildTerrainSurface FRESH (tools/baseline/js_baseline.mjs,
## one process per region, extent 224 = the Godot world) and the engine's
## StalagChunkMesher on the same regions, then merges both sides into one record:
##   {generated_epoch, js_stalag_head, regions:[{region, carve_mode, js:{...}, gd:{...}}],
##    neg_control:{differs,...}, thread_safety:{threads,equal}}
## where js/gd each carry tris_base, tris_caps, centroid_q_sum_base, centroid_q_sum_caps and
## edge_stats (base+caps edge-multiplicity topology).
##
## This wrapper only MEASURES. Exit 0 means "ran to completion"; the DoD's jq judges
## equality. Regions beyond the carve band use the carve-OFF oracle (the prototype
## applies a water-plan carve to ~half the world, which the Godot terrain does not have);
## the three #494 pinned regions and [0,28]x[0,28] are carve-free and use the unmodified
## prototype (carve_mode "on"), and DOD-3 proves both modes agree there.
##
## Env: STALAG_OUT (required) output JSON path; GODOT (default ~/.local/bin/godot).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
: "${STALAG_OUT:?verify_stalag_parity: STALAG_OUT is required}"

# region (xMin,xMax,zMin,zMax) : oracle carve mode
REGIONS=(
    "0,28,0,28:on"
    "-28,0,-28,0:on"
    "-56,-28,0,28:on"
    "28,56,0,28:off"
    "90,112,0,28:off"
    "-112,-90,-56,-28:off"
    "90,112,90,112:off"
    "-14,14,-14,14:off"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ids=""
i=0
for entry in "${REGIONS[@]}"; do
    reg="${entry%%:*}"
    mode="${entry##*:}"
    ids="${ids}${ids:+;}${reg}"
    JS_BASELINE_REGION="$reg" JS_BASELINE_CARVE="$mode" JS_BASELINE_EXTENT=224 JS_BASELINE_RUNS=1 \
        JS_BASELINE_OUT="$WORK/js_$i.json" "$REPO_ROOT/tools/baseline/js_baseline.mjs" </dev/null >&2
    i=$((i + 1))
done

# Make sure the project is scanned (class names, extension) before the script run.
timeout 180 "$GODOT" --headless --editor --quit --path "$REPO_ROOT" </dev/null >/dev/null 2>&1 || true

STALAG_PARITY_RAW="$WORK/gd.json" STALAG_PARITY_REGIONS="$ids" STALAG_PARITY_NEG="${REGIONS[0]%%:*}" \
    timeout 600 "$GODOT" --headless --path "$REPO_ROOT" -s res://engine/stalag/tests/parity_probe.gd </dev/null >&2
[ -s "$WORK/gd.json" ] || { echo "verify_stalag_parity: engine probe wrote nothing" >&2; exit 1; }

jq -n --slurpfile gd "$WORK/gd.json" --slurpfile js <(for ((k = 0; k < ${#REGIONS[@]}; k++)); do cat "$WORK/js_$k.json"; done) '
  $gd[0] as $g
  | {
      generated_epoch: now,
      js_stalag_head: $js[0].stalag_head,
      regions: [range(0; ($js | length)) as $r | {
        region: $g.regions[$r].region,
        carve_mode: $js[$r].carve_mode,
        carve_nonzero_columns: $js[$r].carve_nonzero_columns,
        js: ($js[$r] | {tris_base, tris_caps, centroid_q_sum_base, centroid_q_sum_caps, edge_stats}),
        gd: ($g.regions[$r].gd | del(.build_ms)),
        gd_build_ms: $g.regions[$r].gd.build_ms
      }],
      neg_control: {
        region: $g.neg_control.region,
        shift_m: $g.neg_control.shift_m,
        js_unshifted_centroid_q_sum_base: $js[0].centroid_q_sum_base,
        gd_shifted_centroid_q_sum_base: $g.neg_control.gd_shifted.centroid_q_sum_base,
        differs: (($g.neg_control.gd_shifted.centroid_q_sum_base != $js[0].centroid_q_sum_base)
                  or ($g.neg_control.gd_shifted.tris_base != $js[0].tris_base))
      },
      thread_safety: $g.thread_safety
    }' > "$STALAG_OUT"
echo "verify_stalag_parity: wrote ${STALAG_OUT##*/}" >&2
