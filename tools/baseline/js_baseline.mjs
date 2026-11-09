#!/usr/bin/env node
// Spec #494: MEASURED JS baseline for the engine-language spike.
//
// Runs the frozen prototype read-only from $STALAG_DIR (default ~/dev/stalag), with the
// Spec #517 A2 primitive substitutions of tools/baseline/proto_subst.mjs by default,
// times buildTerrainSurface for one region, and records the triangle count and the
// order-independent integer centroid checksum the Godot candidates must reproduce.
//
// Environment variables:
//   JS_BASELINE_OUT     (required) output JSON path
//   JS_BASELINE_REGION  "xMin,xMax,zMin,zMax" in world metres (default 0,28,0,28)
//   JS_BASELINE_EXTENT  world extent (default 72; the Godot world uses 224 = +-112 m)
//   JS_BASELINE_RUNS    timed runs after the warm-up (default 5)
//   JS_BASELINE_CARVE   "on" (default) = the prototype as it is; "off" = Spec #501 carve-free
//                       oracle: the frozen src/ is COPIED to a temp dir, carve.js is stubbed
//                       there to carveDepth => 0, and the copy is what runs. STALAG_DIR is
//                       never written to, in either mode.
//   JS_BASELINE_SUBST   lowbias32 (default: hash finalizer, hypot and log2 substituted, the
//                       same world the engine builds) | none (the historical, unsubstituted
//                       prototype, which only the retired Spec #494/#501 records describe)
//   STALAG_DIR          prototype checkout (default ~/dev/stalag); never written to
//
// Nothing here is hard-coded from a previous run: every number is computed below.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { installMath, prepareTree } from './proto_subst.mjs';

const SEED = 42;           // the Spec #494 spike keeps seed 42 (the engine world uses 7); index.html uses 42 too
const EXTENT = Number(process['env'].JS_BASELINE_EXTENT || 72); // 72 = the #494 small world
const FLAT_THRESHOLD = 0;
const SF = 0.125;          // lattice -> metres; same value as stalag worldmesh.js SF
const RUNS = Number(process['env'].JS_BASELINE_RUNS || 5); // timed runs after one un-timed warm-up
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
const carveMode = E.JS_BASELINE_CARVE || 'on';
if (carveMode !== 'on' && carveMode !== 'off') {
  console.error(`js_baseline: bad JS_BASELINE_CARVE "${carveMode}"`);
  process.exit(2);
}

// The prototype always runs from a COPY (so the hash substitution never touches the original);
// with carve off (Spec #501) carve.js in the copy is stubbed as well.
const substMode = E.JS_BASELINE_SUBST || 'lowbias32';
const tmpCopy = mkdtempSync(join(tmpdir(), 'stalag-oracle-'));
const runDir = prepareTree(stalagDir, tmpCopy, substMode).dir;
installMath(substMode);
if (carveMode === 'off') {
  writeFileSync(join(runDir, 'src', 'carve.js'),
    'export const GUARD_INNER = 70;\nexport const GUARD_OUTER = 110;\n' +
    'export function carveDepth() { return 0; }\nexport function channelAt() { return 0; }\n');
}
const { buildTerrainSurface } = await import(pathToFileURL(join(runDir, 'src/worldmesh.js')).href);
const { carveDepth } = await import(pathToFileURL(join(runDir, 'src/carve.js')).href);

// First carveDepth call solves the whole water plan (hazard H3); time it separately
// while counting carved columns (a region with any carve is invalid for the spike).
let carveNonzero = carveMode === 'on' ? 0 : null; // null: the stub makes the count meaningless
const planT0 = performance.now();
for (let wx = region.xMin; wx < region.xMax; wx += COLUMN_PITCH_M) {
  for (let wz = region.zMin; wz < region.zMax; wz += COLUMN_PITCH_M) {
    if (carveNonzero !== null && carveDepth(wx / SF, wz / SF, SEED) !== 0) carveNonzero++;
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

// Edge-multiplicity topology over base+caps (Spec #501): vertices quantised at 1e-4 m,
// undirected edges counted by multiplicity. open_interior = edges used exactly once whose
// endpoints both lie more than 1 m inside the region (the mesh is cut at the region
// border, so border edges are legitimately open). The prototype mesh is NOT watertight
// at this quantisation, so the contract is equality with the Godot side, not zero.
function edgeStats(meshes, reg) {
  const q = (v) => Math.floor(v * 1e4 + 0.5);
  const ids = new Map();
  const vx = [];
  const vz = [];
  let degenerate = 0;
  const edges = new Map();
  for (const pos of meshes) {
    for (let t = 0; t + 8 < pos.length; t += 9) {
      const id = [0, 0, 0];
      for (let k = 0; k < 3; k++) {
        const x = pos[t + 3 * k], y = pos[t + 3 * k + 1], z = pos[t + 3 * k + 2];
        const key = q(x) + ',' + q(y) + ',' + q(z);
        let v = ids.get(key);
        if (v === undefined) { v = ids.size; ids.set(key, v); vx.push(x); vz.push(z); }
        id[k] = v;
      }
      for (let k = 0; k < 3; k++) {
        const a = id[k], b = id[(k + 1) % 3];
        if (a === b) { degenerate++; continue; }
        const lo = Math.min(a, b), hi = Math.max(a, b);
        const ek = lo * 16777216 + hi;
        edges.set(ek, (edges.get(ek) || 0) + 1);
      }
    }
  }
  let m1 = 0, m2 = 0, m3p = 0, openInterior = 0;
  const inside = (i) => vx[i] > reg.xMin + 1 && vx[i] < reg.xMax - 1 && vz[i] > reg.zMin + 1 && vz[i] < reg.zMax - 1;
  for (const [ek, n] of edges) {
    if (n === 1) {
      m1++;
      const lo = Math.floor(ek / 16777216), hi = ek - lo * 16777216;
      if (inside(lo) && inside(hi)) openInterior++;
    } else if (n === 2) m2++;
    else m3p++;
  }
  return { verts: ids.size, edges: edges.size, m1, m2, m3p, open_interior: openInterior, degenerate };
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
  carve_mode: carveMode,
  subst_mode: substMode,
  params: { seed: SEED, extent: EXTENT, flatThreshold: FLAT_THRESHOLD, region },
  carve_nonzero_columns: carveNonzero,
  plan_solve_ms: planSolveMs,
  includes_caps: true,
  tris_base: trisBase,
  tris_caps: trisCaps,
  tris_total: trisBase + trisCaps,
  centroid_q_sum_base: centroidQSum(result.base.positions),
  centroid_q_sum_caps: centroidQSum(result.caps.positions),
  edge_stats: edgeStats([result.base.positions, result.caps.positions], region),
  build_ms: buildMs,
  build_ms_median: median(buildMs),
};
writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n');
rmSync(tmpCopy, { recursive: true, force: true });
console.log(`js_baseline[${carveMode}]: region ${regionStr} base=${trisBase} caps=${trisCaps} median=${out.build_ms_median.toFixed(0)} ms -> ${outPath}`);
