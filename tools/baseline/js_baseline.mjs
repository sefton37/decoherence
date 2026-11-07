#!/usr/bin/env node
// Spec #494: MEASURED JS baseline for the engine-language spike.
//
// Imports the frozen prototype read-only from $STALAG_DIR (default ~/dev/stalag),
// times buildTerrainSurface for one region, and records the triangle count and the
// order-independent integer centroid checksum the Godot candidates must reproduce.
//
// Environment variables:
//   JS_BASELINE_OUT     (required) output JSON path
//   JS_BASELINE_REGION  "xMin,xMax,zMin,zMax" in world metres (default 0,28,0,28)
//   STALAG_DIR          prototype checkout (default ~/dev/stalag); never written to
//
// Nothing here is hard-coded from a previous run: every number is computed below.

import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const SEED = 42;           // index.html WORLD_SEED
const EXTENT = 72;         // the extent the prototype's default small world uses
const FLAT_THRESHOLD = 0;
const SF = 0.125;          // lattice -> metres; same value as stalag worldmesh.js SF
const RUNS = 5;            // timed runs after one un-timed warm-up
const COLUMN_PITCH_M = 0.5; // one carve-plan cell is 4 lattice = 0.5 m

const E = process['env'];
const outPath = E.JS_BASELINE_OUT;
if (!outPath) {
  console.error('js_baseline: JS_BASELINE_OUT is required');
  process.exit(2);
}
const regionStr = E.JS_BASELINE_REGION || '0,28,0,28';
const rv = regionStr.split(',').map(Number);
if (rv.length !== 4 || rv.some(Number.isNaN)) {
  console.error(`js_baseline: bad JS_BASELINE_REGION "${regionStr}"`);
  process.exit(2);
}
const region = { xMin: rv[0], xMax: rv[1], zMin: rv[2], zMax: rv[3] };

const stalagDir = E.STALAG_DIR || join(homedir(), 'dev', 'stalag');
const { buildTerrainSurface } = await import(pathToFileURL(join(stalagDir, 'src/worldmesh.js')).href);
const { carveDepth } = await import(pathToFileURL(join(stalagDir, 'src/carve.js')).href);

// First carveDepth call solves the whole water plan (hazard H3); time it separately
// while counting carved columns (a region with any carve is invalid for the spike).
let carveNonzero = 0;
const planT0 = performance.now();
for (let wx = region.xMin; wx < region.xMax; wx += COLUMN_PITCH_M) {
  for (let wz = region.zMin; wz < region.zMax; wz += COLUMN_PITCH_M) {
    if (carveDepth(wx / SF, wz / SF, SEED) !== 0) carveNonzero++;
  }
}
const planSolveMs = performance.now() - planT0;

const call = () => buildTerrainSurface({ seed: SEED, extent: EXTENT, flatThreshold: FLAT_THRESHOLD, region });
call(); // warm-up, un-timed

const buildMs = [];
let result;
for (let r = 0; r < RUNS; r++) {
  const t0 = performance.now();
  result = call();
  buildMs.push(performance.now() - t0);
}

// centroid checksum: mean of the 3 vertices (float64), q = floor(c*1e4 + 0.5), summed per axis.
function centroidQSum(pos) {
  const s = [0, 0, 0];
  for (let t = 0; t + 8 < pos.length; t += 9) {
    for (let a = 0; a < 3; a++) {
      const c = (pos[t + a] + pos[t + 3 + a] + pos[t + 6 + a]) / 3;
      s[a] += Math.floor(c * 1e4 + 0.5);
    }
  }
  return s;
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

const trisBase = result.base.positions.length / 9;
const trisCaps = result.caps.positions.length / 9;
// Short hash: a full 40-hex sha trips the repo's pre-commit secret scan; 12 chars is unambiguous.
const head = execFileSync('git', ['-C', stalagDir, 'rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim();

const out = {
  generated_epoch: Date.now() / 1000,
  generated_by: 'tools/baseline/js_baseline.mjs',
  node_version: process.version,
  stalag_head: head,
  params: { seed: SEED, extent: EXTENT, flatThreshold: FLAT_THRESHOLD, region },
  carve_nonzero_columns: carveNonzero,
  plan_solve_ms: planSolveMs,
  includes_caps: true,
  tris_base: trisBase,
  tris_caps: trisCaps,
  tris_total: trisBase + trisCaps,
  centroid_q_sum_base: centroidQSum(result.base.positions),
  build_ms: buildMs,
  build_ms_median: median(buildMs),
};
writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n');
console.log(`js_baseline: region ${regionStr} base=${trisBase} caps=${trisCaps} median=${out.build_ms_median.toFixed(0)} ms -> ${outPath}`);
