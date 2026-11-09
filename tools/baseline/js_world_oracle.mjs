#!/usr/bin/env node
// Spec #517: the S1 "ground" oracle.
//
// Runs the frozen prototype from $STALAG_DIR (default ~/dev/stalag, tag prototype-final),
// read-only, with exactly three numeric primitives substituted (tools/baseline/proto_subst.mjs:
// the hash finalizer inside hash2, Math.hypot, Math.log2; WORLD_ORACLE_SUBST picks the mode).
// Every other line of the prototype is executed unchanged, from a copy made in the
// "proto" subdirectory of the output directory. It solves the whole-world water plan for
// world seed 7 (the engine's WORLD_SEED, a game-policy choice recorded in Spec #517 A3)
// with carve ON, and writes everything the Godot engine must reproduce:
//
//   <out>/plan_{carve,waterTw,waterType,flowX,flowZ,bedTargetLat,bankTargetLat}.bin
//        raw typed-array bytes (little endian), the contract for the seven plan arrays
//   <out>/oracle.json
//        {generated_epoch, stalag_head, subst{mode, files_changed, math_overrides},
//         plan{seed, hash, type_counts[5]}, footprint{...},
//         terrain_regions[{region, carve_nonzero_cols, ...terrain numbers}],
//         water_regions[{kind, region, ...water numbers}],
//         tiles{grass_hash, dirt_hash}, query_samples{...}}
//
// Regions are CHOSEN FROM THE PLAN (nearest lake, river reach, spring head, a chunk
// seam that has water on both sides, a dry chunk), not hard-coded, so a different
// plan would pick different regions. No number is carried over from an earlier run.
//
// Environment:
//   WORLD_ORACLE_OUT   (required) output directory
//   WORLD_ORACLE_LITE  "1" = plan arrays, plan hash and tile hashes only (a few seconds); the
//                      terrain/water regions and query samples are left out. The renderer
//                      harness only needs the hashes.
//   WORLD_ORACLE_SUBST lowbias32 (default) | none | hypot_native | log2_native
//   STALAG_DIR         prototype checkout (default ~/dev/stalag); never written to

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { installMath, lowbias32, prepareTree } from './proto_subst.mjs';

const E = process['env'];
const outDir = E.WORLD_ORACLE_OUT;
if (!outDir) {
  console.error('js_world_oracle: WORLD_ORACLE_OUT is required');
  process.exit(2);
}
mkdirSync(outDir, { recursive: true });
const stalagDir = E.STALAG_DIR || join(homedir(), 'dev', 'stalag');

const SUBST_MODE = E.WORLD_ORACLE_SUBST || 'lowbias32';
const tree = prepareTree(stalagDir, outDir, SUBST_MODE); // copies; rewrites hash2 in the copy only
installMath(SUBST_MODE);
const imp = (rel) => import(pathToFileURL(join(tree.dir, rel)).href);

const SEED = 7;
// Solid cells below each column surface, passed to the prototype's own slabDepth parameter. The
// prototype's default (4) leaves see-through gaps in carved cliffs taller than 2 m; the engine
// uses the same depth (stalag_core.cpp SLAB_DEPTH). Spec #517 A4.5.
const SLAB_DEPTH = 12;
const EXTENT = 224; // index.html default: footprint +-112 m
const CHUNK_M = 28;
const SF = 0.125;
const TILE_WORLD = 0.5;
const COL = 0.5;

const WP = await imp('src/waterplan.js');
const WM = await imp('src/worldmesh.js');
const RV = await imp('src/rivers.js');
const HY = await imp('src/hydrology.js');
const OCC = await imp('src/wateroccupancy.js');
const SKIN = await imp('skins/world-skin.js');
const TEX = await imp('skins/texgen.js');

const { DIM, G0, TYPE_LAKE, TYPE_RIVER, TYPE_SPRING, TYPE_FALL } = WP;
const plan = WP.computeWaterPlan(SEED);
const planHashStr = WP.planHash(plan);
const n = DIM * DIM;

// ---- raw plan dumps ----------------------------------------------------------
const FIELDS = [
  ['carve', 'plan_carve.bin'], ['waterTw', 'plan_waterTw.bin'], ['waterType', 'plan_waterType.bin'],
  ['flowX', 'plan_flowX.bin'], ['flowZ', 'plan_flowZ.bin'],
  ['bedTargetLat', 'plan_bedTargetLat.bin'], ['bankTargetLat', 'plan_bankTargetLat.bin'],
];
for (const [f, name] of FIELDS) {
  const a = plan[f];
  writeFileSync(join(outDir, name), Buffer.from(a.buffer, a.byteOffset, a.byteLength));
}
const typeCounts = [0, 0, 0, 0, 0];
for (let c = 0; c < n; c++) typeCounts[plan.waterType[c]]++;

// ---- deterministic sampler -----------------------------------------------------
let sampleCounter = 0;
const rnd = () => lowbias32(517 + 2 * sampleCounter++) / 4294967296; // counter-based, deterministic
const pick = (arr) => arr[Math.floor(rnd() * arr.length)];

// ---- region choice from the plan -------------------------------------------------
const HALF = 4 * EXTENT * SF; // 112 m footprint half-size
const colAt = (gx, gz) => (gz - G0) * DIM + (gx - G0);
const typeAt = (gx, gz) => plan.waterType[colAt(gx, gz)];
const wetAt = (gx, gz) => plan.waterTw[colAt(gx, gz)] !== -32768;
const inFoot = (gx, gz) => Math.abs((gx + 0.5) * COL) < HALF - 1 && Math.abs((gz + 0.5) * COL) < HALF - 1;

const chunkRegion = (cx, cz) => ({ xMin: cx * CHUNK_M, xMax: (cx + 1) * CHUNK_M, zMin: cz * CHUNK_M, zMax: (cz + 1) * CHUNK_M });
// per-chunk counts of each water type over columns inside the footprint (chunk-aligned)
const chunkStats = new Map();
for (let gz = G0; gz < G0 + DIM; gz++) {
  for (let gx = G0; gx < G0 + DIM; gx++) {
    if (!inFoot(gx, gz)) continue;
    const cx = Math.floor((gx * COL) / CHUNK_M), cz = Math.floor((gz * COL) / CHUNK_M);
    const key = cx + ',' + cz;
    let s = chunkStats.get(key);
    if (!s) { s = { cx, cz, lake: 0, river: 0, spring: 0, wet: 0, carve: 0 }; chunkStats.set(key, s); }
    const t = typeAt(gx, gz);
    if (t === TYPE_LAKE) s.lake++;
    else if (t === TYPE_RIVER || t === TYPE_FALL) s.river++;
    else if (t === TYPE_SPRING) s.spring++;
    if (wetAt(gx, gz)) s.wet++;
    if (plan.carve[colAt(gx, gz)] !== 0) s.carve++;
  }
}
const chunks = [...chunkStats.values()];
const distOrigin = (s) => Math.hypot((s.cx + 0.5) * CHUNK_M, (s.cz + 0.5) * CHUNK_M);
const byDist = (a, b) => distOrigin(a) - distOrigin(b) || a.cx - b.cx || a.cz - b.cz;
const take = (pred, skip = new Set()) => chunks.filter((s) => pred(s) && !skip.has(s.cx + ',' + s.cz)).sort(byDist)[0];
const used = new Set();
const mark = (s) => { used.add(s.cx + ',' + s.cz); return s; };
const lake1 = mark(take((s) => s.lake >= 40, used));
const river1 = mark(take((s) => s.river >= 40 && s.lake === 0, used));
const spring1 = mark(take((s) => s.spring >= 3, used));
// a chunk that has no water within its own columns, nor within 4 columns around it
const wetNear = (s) => {
  const r = chunkRegion(s.cx, s.cz);
  for (let gz = Math.floor(r.zMin / COL) - 4; gz < Math.ceil(r.zMax / COL) + 4; gz++) {
    for (let gx = Math.floor(r.xMin / COL) - 4; gx < Math.ceil(r.xMax / COL) + 4; gx++) {
      if (gx < G0 || gz < G0 || gx >= G0 + DIM || gz >= G0 + DIM) continue;
      if (wetAt(gx, gz)) return true;
    }
  }
  return false;
};
const dry1 = mark(take((s) => s.wet === 0 && s.carve > 0 && !wetNear(s), used));
const lake2 = mark(take((s) => s.lake >= 40, used));
const river2 = mark(take((s) => s.river >= 40, used));
const spawnChunk = { cx: -1, cz: -1, carve: 0 };
const cornerChunk = { cx: 3, cz: 3, carve: 0 };
// seam: x = 28*k with real water on both sides within the same z chunk
function wetCols(r) {
  let c = 0;
  for (let gz = Math.floor(r.zMin / COL); gz < Math.ceil(r.zMax / COL); gz++) {
    for (let gx = Math.floor(r.xMin / COL); gx < Math.ceil(r.xMax / COL); gx++) if (wetAt(gx, gz)) c++;
  }
  return c;
}
let seam = null;
for (const s of chunks.slice().sort(byDist)) {
  const r = { xMin: s.cx * CHUNK_M - 14, xMax: s.cx * CHUNK_M + 14, zMin: s.cz * CHUNK_M, zMax: (s.cz + 1) * CHUNK_M };
  if (Math.abs(r.xMin) > HALF - 1 || Math.abs(r.xMax) > HALF - 1) continue;
  const left = wetCols({ ...r, xMax: s.cx * CHUNK_M }), right = wetCols({ ...r, xMin: s.cx * CHUNK_M });
  if (left >= 20 && right >= 20) { seam = r; break; }
}
if (!seam) throw new Error('js_world_oracle: no chunk seam with water on both sides');

// the nearest fall (both lie outside the walkable footprint: water-only region)
let fallRegion = null;
for (let c = 0; c < n && !fallRegion; c++) {
  if (plan.waterType[c] === TYPE_FALL) {
    const gx = G0 + (c % DIM), gz = G0 + Math.floor(c / DIM);
    const cx = Math.floor((gx * COL) / CHUNK_M), cz = Math.floor((gz * COL) / CHUNK_M);
    fallRegion = chunkRegion(cx, cz);
  }
}

const terrainRegions = [lake1, river1, spring1, dry1, lake2, river2, spawnChunk, cornerChunk].map((s) => chunkRegion(s.cx, s.cz));
terrainRegions.push(seam);

// ---- terrain stats (carve ON, skin classification exactly as index.html) ----------------------
const q = (v) => Math.floor(v * 1e4 + 0.5);
function centroidQSum(pos) {
  const s = [0, 0, 0];
  for (let t = 0; t + 8 < pos.length; t += 9) {
    for (let a = 0; a < 3; a++) s[a] += q((pos[t + a] + pos[t + 3 + a] + pos[t + 6 + a]) / 3);
  }
  return s;
}
function edgeStats(meshes, reg) {
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
  for (const [ek, cnt] of edges) {
    if (cnt === 1) {
      m1++;
      const lo = Math.floor(ek / 16777216), hi = ek - lo * 16777216;
      if (inside(lo) && inside(hi)) openInterior++;
    } else if (cnt === 2) m2++;
    else m3p++;
  }
  return { verts: ids.size, edges: edges.size, m1, m2, m3p, open_interior: openInterior, degenerate };
}
const surfaceWorldY = (wx, wz) => {
  const hT = Math.floor(WM.surfaceHeight(wx / SF, wz / SF, SEED) / 4) * 4;
  return (hT + 2) * SF;
};
function carveNonzeroCols(r) {
  let c = 0;
  for (let gz = Math.floor(r.zMin / COL); gz < Math.ceil(r.zMax / COL); gz++) {
    for (let gx = Math.floor(r.xMin / COL); gx < Math.ceil(r.xMax / COL); gx++) {
      if (gx < G0 || gz < G0 || gx >= G0 + DIM || gz >= G0 + DIM) continue;
      if (plan.carve[colAt(gx, gz)] !== 0) c++;
    }
  }
  return c;
}
function terrainRecord(region) {
  const { base, caps } = WM.buildTerrainSurface({ seed: SEED, extent: EXTENT, flatThreshold: 0, slabDepth: SLAB_DEPTH, region });
  const skin = SKIN.skinGeometry([base, caps], { tileWorld: TILE_WORLD, surfaceWorldY, surfaceTol: 0.35 });
  const uv = [0, 0];
  for (const k of ['grass', 'dirt']) {
    const u = skin[k].uvs;
    for (let i = 0; i < u.length; i += 2) { uv[0] += q(u[i]); uv[1] += q(u[i + 1]); }
  }
  return {
    region,
    carve_nonzero_cols: carveNonzeroCols(region),
    tris_base: base.positions.length / 9,
    tris_caps: caps.positions.length / 9,
    grass_tris: skin.grass.positions.length / 9,
    dirt_tris: skin.dirt.positions.length / 9,
    centroid_q_sum_base: centroidQSum(base.positions),
    centroid_q_sum_caps: centroidQSum(caps.positions),
    uv_q_sum: uv,
    edge_stats: edgeStats([base.positions, caps.positions], region),
  };
}
const LITE = E.WORLD_ORACLE_LITE === '1';
const terrain_regions = LITE ? [] : terrainRegions.map(terrainRecord);

// ---- water stats ---------------------------------------------------------------
function waterRecord(kind, region) {
  const w = OCC.buildOccupancyWater({ seed: SEED, region });
  const nV = w.positions.length / 3;
  let depthQ = 0;
  for (let i = 0; i < w.depth.length; i++) depthQ += q(w.depth[i]);
  let flowTris = 0;
  for (let t = 0; t < nV; t += 3) if (w.flow[t * 2] !== 0 || w.flow[t * 2 + 1] !== 0) flowTris++;
  return {
    kind, region,
    tris: w.positions.length / 9,
    centroid_q_sum: centroidQSum(w.positions),
    depth_q_sum: depthQ,
    flow_nonzero_tris: flowTris,
  };
}
const water_regions = LITE ? [] : [
  waterRecord('lake', chunkRegion(lake1.cx, lake1.cz)),
  waterRecord('river', chunkRegion(river1.cx, river1.cz)),
  waterRecord('spring', chunkRegion(spring1.cx, spring1.cz)),
  waterRecord('seam', seam),
  waterRecord('dry', chunkRegion(dry1.cx, dry1.cz)),
  waterRecord('lake', chunkRegion(lake2.cx, lake2.cz)),
  waterRecord('river', chunkRegion(river2.cx, river2.cz)),
  ...(fallRegion ? [waterRecord('fall', fallRegion)] : []), // the plan of world seed 7 has no fall column
];

// ---- footprint: what the walkable +-111 m square holds (column centres inside both axes) -----------
const footprint = (() => {
  const half = HALF - 1;
  const cols = { lake: 0, river: 0, spring: 0 };
  const near = { lake: Infinity, river: Infinity, spring: Infinity };
  const inF = (gx, gz) => Math.abs((gx + 0.5) * COL) < half && Math.abs((gz + 0.5) * COL) < half;
  const kindOf = (t) => (t === TYPE_LAKE ? 'lake' : t === TYPE_RIVER ? 'river' : t === TYPE_SPRING ? 'spring' : null);
  const seen = new Uint8Array(n);
  let largest = 0;
  for (let gz = G0; gz < G0 + DIM; gz++) {
    for (let gx = G0; gx < G0 + DIM; gx++) {
      if (!inF(gx, gz)) continue;
      const k = kindOf(typeAt(gx, gz));
      if (!k) continue;
      cols[k]++;
      near[k] = Math.min(near[k], Math.hypot((gx + 0.5) * COL, (gz + 0.5) * COL));
      if (k !== 'lake' || seen[colAt(gx, gz)]) continue;
      // 4-connected lake component, counted inside the footprint
      let size = 0;
      const stack = [[gx, gz]];
      seen[colAt(gx, gz)] = 1;
      while (stack.length) {
        const [x, z] = stack.pop();
        size++;
        for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nx = x + dx, nz = z + dz;
          if (nx < G0 || nz < G0 || nx >= G0 + DIM || nz >= G0 + DIM || !inF(nx, nz)) continue;
          if (typeAt(nx, nz) !== TYPE_LAKE || seen[colAt(nx, nz)]) continue;
          seen[colAt(nx, nz)] = 1;
          stack.push([nx, nz]);
        }
      }
      largest = Math.max(largest, size);
    }
  }
  const m = (v) => (Number.isFinite(v) ? Math.round(v * 10) / 10 : null);
  return {
    half_m: half, lake_cols: cols.lake, largest_lake_cols: largest, nearest_lake_m: m(near.lake),
    river_cols: cols.river, nearest_river_m: m(near.river), spring_cols: cols.spring, nearest_spring_m: m(near.spring),
  };
})();

// ---- shot plan (rule geom_v1, Spec #517 A4.3): where the probe stands, from the plan arrays alone --------
// One stand per shot, chosen once from geometry; no pixel feedback anywhere. The engine-side probe
// computes the same rule from the engine's water queries and the DoD requires the two to agree.
const shot_plan = (() => {
  const half = HALF - 1; // 111 m
  const colX = (gx) => (gx + 0.5) * COL;
  const inF = (gx, gz) => Math.abs(colX(gx)) <= half && Math.abs(colX(gz)) <= half;
  const still = (gx, gz) => { const t = typeAt(gx, gz); return t === TYPE_LAKE || t === TYPE_SPRING; };
  const course = (gx, gz) => { const t = typeAt(gx, gz); return t === TYPE_RIVER || t === TYPE_FALL; };
  // still body L: the largest 4-connected component of still columns inside the footprint
  // (ties: the component met first in (gz, gx) order)
  const seen = new Uint8Array(n);
  let L = [];
  for (let gz = G0; gz < G0 + DIM; gz++) {
    for (let gx = G0; gx < G0 + DIM; gx++) {
      if (!inF(gx, gz) || !still(gx, gz) || seen[colAt(gx, gz)]) continue;
      const comp = [];
      const stack = [[gx, gz]];
      seen[colAt(gx, gz)] = 1;
      while (stack.length) {
        const [x, z] = stack.pop();
        comp.push([x, z]);
        for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nx = x + dx, nz = z + dz;
          if (nx < G0 || nz < G0 || nx >= G0 + DIM || nz >= G0 + DIM || !inF(nx, nz)) continue;
          if (!still(nx, nz) || seen[colAt(nx, nz)]) continue;
          seen[colAt(nx, nz)] = 1;
          stack.push([nx, nz]);
        }
      }
      if (comp.length > L.length) L = comp;
    }
  }
  const lx = L.map(([gx]) => colX(gx)), lz = L.map(([, gz]) => colX(gz));
  const centroid = [lx.reduce((a, b) => a + b, 0) / L.length, lz.reduce((a, b) => a + b, 0) / L.length];
  // shore: a RAISED VANTAGE over the largest still body (Spec #517 A4.3, Kel ruling 2026-11-08).
  // Candidates are integer-metre points with |x|,|z| <= 100 whose column is neither still water nor
  // river and whose nearest SHORELINE column centre (an L column with a 4-neighbour outside L) lies
  // SHORE_R_M = 8 m or less away (the bar requires the water within 8 m), and at least 2 m. Highest quantised ground first (ties: smaller x,
  // then smaller z); the first candidate with line of sight to the centroid of L is the stand, so there
  // is one stand and no retry. Line of sight: an eye 2.2 m above the stand's ground, a target 0.1 m
  // above the ground at the centroid, 50 samples between them, none with quantised ground above the
  // line minus 0.05 m. The view aims at the centroid of L.
  const SHORE_R_M = 8;
  const hm = (x, z) => Math.floor(WM.surfaceHeight(x / SF, z / SF, SEED) / 4) * 4 * SF;
  const inL = new Set(L.map(([gx, gz]) => gx * 4096 + gz));
  const shoreIdx = [];
  for (let i = 0; i < L.length; i++) {
    const [gx, gz] = L[i];
    if ([[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dz]) => !inL.has((gx + dx) * 4096 + gz + dz))) shoreIdx.push(i);
  }
  const cent = [lx.reduce((a, b) => a + b, 0) / L.length, lz.reduce((a, b) => a + b, 0) / L.length];
  const losClear = (x, z) => {
    const y0 = hm(x, z) + 2.2, y1 = hm(cent[0], cent[1]) + 0.1;
    for (let i = 1; i < 50; i++) {
      const t = i / 50;
      if (hm(x + (cent[0] - x) * t, z + (cent[1] - z) * t) > y0 + (y1 - y0) * t - 0.05) return false;
    }
    return true;
  };
  const cands = [];
  for (let x = -100; x <= 100; x++) {
    for (let z = -100; z <= 100; z++) {
      const cgx = Math.floor(x / COL), cgz = Math.floor(z / COL);
      if (still(cgx, cgz) || course(cgx, cgz)) continue;
      let nearest = Infinity;
      for (const i of shoreIdx) {
        const d2 = (lx[i] - x) ** 2 + (lz[i] - z) ** 2;
        if (d2 < nearest) nearest = d2;
      }
      const dist = Math.sqrt(nearest);
      if (dist < 2 || dist > SHORE_R_M) continue;
      cands.push({ stand: [x, z], height_m: hm(x, z), dist_m: dist });
    }
  }
  cands.sort((a, b) => b.height_m - a.height_m || a.stand[0] - b.stand[0] || a.stand[1] - b.stand[1]);
  const best = cands.find((c) => losClear(c.stand[0], c.stand[1]));
  best.aim = cent;
  best.candidates = cands.length;
  // sweep: the water column (still or river) nearest the spawn; the stand sits 12 m short of it on the
  // line from the spawn, stepped back toward the spawn in 0.5 m until the column under it is dry
  let tgt = null, td = Infinity;
  for (let gz = G0; gz < G0 + DIM; gz++) {
    for (let gx = G0; gx < G0 + DIM; gx++) {
      if (!inF(gx, gz) || !(still(gx, gz) || course(gx, gz))) continue;
      const d = Math.hypot(colX(gx), colX(gz));
      if (d < td) { td = d; tgt = [colX(gx), colX(gz)]; }
    }
  }
  let r = Math.max(0, td - 12);
  let stand = [tgt[0] * r / td, tgt[1] * r / td];
  while (r > 0 && (still(Math.floor(stand[0] / COL), Math.floor(stand[1] / COL)) || course(Math.floor(stand[0] / COL), Math.floor(stand[1] / COL)))) {
    r = Math.max(0, r - 0.5);
    stand = [tgt[0] * r / td, tgt[1] * r / td];
  }
  const rd = (v) => Math.round(v * 100) / 100;
  return {
    rule: 'geom_v1',
    still_body: { cols: L.length, centroid: centroid.map(rd) },
    shore: { rule: 'raised_vantage', radius_m: SHORE_R_M, stand: best.stand, aim: best.aim.map(rd), dist_m: rd(best.dist_m), height_m: rd(best.height_m), candidates: best.candidates },
    sweep: { stand: stand.map(rd), dist_to_water_m: rd(Math.hypot(tgt[0] - stand[0], tgt[1] - stand[1])), toward: tgt },
  };
})();

// ---- tiles --------------------------------------------------------------------
const style = TEX.STYLES.find((s) => s.id === 'boreal-baseline');
const tiles = TEX.genTextures(style);
const tileHash = (t) => createHash('sha256').update(Buffer.from(t.rgba.buffer, t.rgba.byteOffset, t.rgba.byteLength)).digest('hex').slice(0, 12);

// ---- query samples ----------------------------------------------------------------
const query_samples = LITE ? {} : (() => {
const wetCols_ = [], dryCols = [], nearCols = [];
for (let c = 0; c < n; c++) {
  const gx = G0 + (c % DIM), gz = G0 + Math.floor(c / DIM);
  if (plan.waterTw[c] !== -32768) wetCols_.push([gx, gz]);
  else dryCols.push([gx, gz]);
}
for (let i = 0; i < 1200; i++) {
  const [gx, gz] = pick(wetCols_);
  const ngx = gx + Math.floor(rnd() * 7) - 3, ngz = gz + Math.floor(rnd() * 7) - 3;
  nearCols.push([ngx, ngz]);
}
const fallCols = [];
for (let c = 0; c < n; c++) if (plan.waterType[c] === TYPE_FALL) fallCols.push([G0 + (c % DIM), G0 + Math.floor(c / DIM)]);
const outCols = [[G0 - 1, 0], [0, G0 - 1], [G0 + DIM, 0], [0, G0 + DIM], [G0 - 50, G0 - 50], [G0 + DIM + 9, 7]];
const sampleCols = [];
for (let i = 0; i < 1300; i++) sampleCols.push(pick(wetCols_));
for (let i = 0; i < 700; i++) sampleCols.push(pick(dryCols));
for (const c of nearCols) sampleCols.push(c);
for (const c of fallCols) for (let dz = -2; dz <= 2; dz++) for (let dx = -2; dx <= 2; dx++) sampleCols.push([c[0] + dx, c[1] + dz]);
for (const c of outCols) sampleCols.push(c);
const num = (v) => (v === HY.DRY ? -32768 : v);
const qs = {
  columns: sampleCols,
  waterLevelAt: sampleCols.map(([x, z]) => num(HY.waterLevelAt(x, z, SEED))),
  isFlooded: sampleCols.map(([x, z]) => (HY.isFlooded(x, z, SEED) ? 1 : 0)),
  courseLevelAt: sampleCols.map(([x, z]) => num(RV.courseLevelAt(x, z, SEED))),
  courseFallTopAt: sampleCols.map(([x, z]) => num(RV.courseFallTopAt(x, z, SEED))),
  isRiverColumn: sampleCols.map(([x, z]) => (RV.isRiverColumn(x, z, SEED) ? 1 : 0)),
  getStrahlerOrder: sampleCols.map(([x, z]) => RV.getStrahlerOrder(x, z, SEED)),
  getFlowDir: sampleCols.map(([x, z]) => {
    const f = RV.getFlowDir(x, z, SEED);
    return f ? [f.dx, f.dz] : null;
  }),
};
// surfaceHeight at lattice addresses of BOTH BCC cosets (A: 4g, B: 4g+2), many carved
const carvedCols = [];
for (let c = 0; c < n; c++) if (plan.carve[c] !== 0) carvedCols.push([G0 + (c % DIM), G0 + Math.floor(c / DIM)]);
const heightAddrs = [];
for (let i = 0; i < 14000; i++) {
  const [gx, gz] = pick(carvedCols);
  const off = i % 2 === 0 ? 0 : 2;
  heightAddrs.push([4 * gx + off, 4 * gz + off]);
}
for (let i = 0; i < 10000; i++) {
  const gx = G0 - 4 + Math.floor(rnd() * (DIM + 8)), gz = G0 - 4 + Math.floor(rnd() * (DIM + 8));
  const off = i % 2 === 0 ? 0 : 2;
  heightAddrs.push([4 * gx + off, 4 * gz + off]);
}
qs.surfaceHeight = {
  addrs: heightAddrs,
  values: heightAddrs.map(([cx, cz]) => WM.surfaceHeight(cx, cz, SEED)),
};


return qs;
})();

const head = execFileSync('git', ['-C', stalagDir, 'rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim();
const out = {
  generated_epoch: Date.now() / 1000,
  generated_by: 'tools/baseline/js_world_oracle.mjs',
  node_version: process.version,
  stalag_head: head,
  subst: { mode: tree.mode, files_changed: tree.files_changed, math_overrides: tree.math_overrides },
  plan: { seed: SEED, dim: DIM, g0: G0, hash: planHashStr, type_counts: typeCounts },
  footprint,
  shot_plan,
  terrain_regions,
  water_regions,
  tiles: { grass_hash: tileHash(tiles.grassTop), dirt_hash: tileHash(tiles.dirtSide) },
  query_samples,
};
writeFileSync(join(outDir, 'oracle.json'), JSON.stringify(out) + '\n');
console.log(`js_world_oracle: plan ${planHashStr}, ${terrain_regions.length} terrain + ${water_regions.length} water regions -> ${join(outDir, 'oracle.json')}`);
