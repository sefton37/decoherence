#!/usr/bin/env bash
## engine/spike/run_spike.sh -- Spec #494 engine-language spike runner.
##
## Builds one TO-voxel terrain chunk in Godot with each candidate (GDScript, C++
## GDExtension), checks both against each other's checksum, renders each mesh from a
## fixed camera, and writes one results JSON. The Godot side measures; this wrapper
## only merges in the committed JS baseline for the SAME region and derives the
## recommendation line from the measured numbers (no number is typed in by hand).
##
## Env:  SPIKE_OUT     (required) output JSON path
##       SPIKE_REGION  "xMin,xMax,zMin,zMax" in world metres (default 0,28,0,28)
##       SPIKE_JS      JS baseline record to merge (default results/js-baseline.json)
##       DISPLAY       X display for the real Vulkan run (default :99, the xvfb.service one)
##
## Produce the JS record first with tools/baseline/js_baseline.mjs and the .so with
## tools/setup_gdext.sh. Exit 0 only if both candidates produced a mesh and, when a JS
## record for the same region exists, both match it on triangle count and checksum.

set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SPIKE_DIR/../.." && pwd)"
GODOT="${GODOT:-$HOME/.local/bin/godot}"
LIB="$SPIKE_DIR/ext/bin/libstalagspike.linux.template_release.x86_64.so"

: "${SPIKE_OUT:?run_spike: SPIKE_OUT is required}"
REGION="${SPIKE_REGION:-0,28,0,28}"
JS_RECORD="${SPIKE_JS:-$SPIKE_DIR/results/js-baseline.json}"
export DISPLAY="${DISPLAY:-:99}"

if [ ! -f "$LIB" ]; then
    echo "[run_spike] GDExtension library missing; running tools/setup_gdext.sh" >&2
    "$REPO_ROOT/tools/setup_gdext.sh" >&2
fi

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

# Godot only imports project resources on a first scan; do it quietly so the run is clean.
if [ ! -d "$SPIKE_DIR/.godot" ]; then
    timeout 180 "$GODOT" --headless --editor --quit --path "$SPIKE_DIR" </dev/null >/dev/null 2>&1 || true
fi

SPIKE_RAW="$RAW" SPIKE_REGION="$REGION" timeout 900 "$GODOT" --path "$SPIKE_DIR" </dev/null >&2

[ -s "$RAW" ] || { echo "run_spike: Godot wrote no result" >&2; exit 1; }

JS_ARG=null
if [ -f "$JS_RECORD" ]; then JS_ARG="$(cat "$JS_RECORD")"; fi

jq --argjson js "$JS_ARG" '
  def r1: (. * 10 | round) / 10;
  def r2: (. * 100 | round) / 100;
  . as $s
  | ($js != null and
     ([$js.params.region.xMin, $js.params.region.xMax, $js.params.region.zMin, $js.params.region.zMax]
      == [$s.params.region.xMin, $s.params.region.xMax, $s.params.region.zMin, $s.params.region.zMax])) as $same
  | ($s.candidates.gdscript.build_ms_median) as $g
  | ($s.candidates.gdextension.build_ms_median) as $e
  | ($s.frame.frame_ms_median.gdscript) as $fg
  | ($s.frame.frame_ms_median.gdextension) as $fe
  | (if $e < $g then "gdextension" else "gdscript" end) as $winner
  | (if $e < $g then ($g / $e) else ($e / $g) end) as $ratio
  | .js = (if $same then {
        build_ms_median: $js.build_ms_median, build_ms: $js.build_ms,
        tris_base: $js.tris_base, tris_caps: $js.tris_caps, tris_total: $js.tris_total,
        includes_caps: $js.includes_caps, plan_solve_ms: $js.plan_solve_ms,
        node_version: $js.node_version, stalag_head: $js.stalag_head
      } else null end)
  | .parity = (if $same then {
        gdscript: ($s.candidates.gdscript.tris_base == $js.tris_base and $s.candidates.gdscript.centroid_q_sum == $js.centroid_q_sum_base),
        gdextension: ($s.candidates.gdextension.tris_base == $js.tris_base and $s.candidates.gdextension.centroid_q_sum == $js.centroid_q_sum_base)
      } else null end)
  | .recommendation_line = (
      "Recommendation (data only, Kel picks the language): " + $winner + " has the lowest chunk build median, "
      + ($ratio | r1 | tostring) + "x faster than "
      + (if $winner == "gdextension" then "gdscript" else "gdextension" end)
      + " (build ms median: gdscript " + ($g | r1 | tostring) + ", gdextension " + ($e | r1 | tostring)
      + (if $same then ", js " + ($js.build_ms_median | r1 | tostring) + " incl. caps" else "" end)
      + "; frame ms median: gdscript " + ($fg | r2 | tostring) + ", gdextension " + ($fe | r2 | tostring)
      + "); csharp unavailable in this Godot build; region "
      + ([$s.params.region.xMin, $s.params.region.xMax, $s.params.region.zMin, $s.params.region.zMax] | map(tostring) | join(","))
      + ", seed " + ($s.params.seed | tostring) + ".")
  | .generated_by = "engine/spike/run_spike.sh"
' "$RAW" > "$SPIKE_OUT"

# Fail loudly if a same-region JS record disagrees with either candidate.
jq -e '(.parity == null) or (.parity.gdscript and .parity.gdextension)' "$SPIKE_OUT" >/dev/null \
    || { echo "run_spike: PARITY MISMATCH vs JS baseline" >&2; exit 1; }
jq -e '.candidates.gdextension.class_loaded' "$SPIKE_OUT" >/dev/null \
    || { echo "run_spike: GDExtension class not loaded" >&2; exit 1; }

echo "run_spike: wrote $SPIKE_OUT"
