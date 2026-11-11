#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #551 phase 2 -- the ground fields: which material each 0.5 m column of the seed-7 world
// wears, baked once from a survey of the world and committed as two 448 x 448 images.
//
// Source and licence: the world is the frozen Stalag prototype's (tag prototype-final, AGPL-3.0, same
// author), reached only through the engine's own bound queries by engine/stalag/tests/ground_survey.gd.
// This file is a port of the design lab's field baker (same author, same licence; the lab wrote it in
// Python with numpy), reduced to what the game needs and with the placement rules turned into ONE
// ordered rule list per column that the shader and the flora filter both read (the ids it writes).
// The lab's two stand-in masks (noise "paths" and "podzol") are not ported: they belong to phase 3.
// The column jitter that ragged the lab's edges is a clean-room hash of the column (lowbias32,
// tools/baseline/proto_subst.mjs, registered in engine/PROVENANCE.md), not the lab's cell hash.
//
// Commands (all read the survey dir written by ground_survey.gd: height.f32, lake.i32, course.i32, meta.json):
//   bake  <surveyDir> <outDir>
//         writes exactly fields_top.png, fields_wall.png and fields_sha.json
//   check <surveyDir> <committedDir> <recordPath>
//         bakes fresh into a temp dir, compares with the committed images byte for byte, runs the
//         INDEPENDENT oracle (a second implementation: ring search instead of seed stamping, one
//         plain if-chain instead of the baker's classifier) and the rule-order invariants, and writes
//         the JSON record the wrapper tests/verify_ground_fields.sh hands to the stored checks.
//   oracle-flora <committedDir> <chunksJson>
//         the independent JS filter for the flora and understory exclusion (see runFloraOracle).
//
// fields_top.png   R = material id of the column's top (0 grass, 4 gravel, 5 sand, 6 mud; the ids are the
//                  atlas rows), G = 0, B = 0, A = 255
// fields_wall.png  R = distance to the nearest water column in 0.1 m (0 = wet, 255 = 25.5 m or more),
//                  G = riser below this column's top edge in 0.125 m (the largest drop to a 4-neighbour),
//                  B = 0, A = 255
// A column's neighbours outside the +-112 m grid do not exist (the edge clamps, nothing wraps).

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync, inflateSync } from 'node:zlib';
import { lowbias32 } from './baseline/proto_subst.mjs';

const N = 448; // columns per side
const HALF = 224; // columns from the origin to an edge
const COL = 0.5; // metres per column
const DRY = -32768; // the plan's "no water" level
const PLAN_HASH = '4448de3c';
const here = dirname(fileURLToPath(import.meta.url));
const rulesPath = join(here, '..', 'game', 'world', 'assets', 'ground', 'rules.json');
const RULES = JSON.parse(readFileSync(rulesPath, 'utf8'));
const ID = RULES.ids;
const T = RULES.top;

// ---- PNG: the writer of bake_skin.mjs, and a reader for our own filter-0 files -----------------
const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(w, h, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0; // filter: none
    Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ]);
}
function readPng(path) {
  const b = readFileSync(path);
  let o = 8;
  let w = 0, h = 0;
  const idat = [];
  while (o < b.length) {
    const len = b.readUInt32BE(o);
    const type = b.toString('ascii', o + 4, o + 8);
    const data = b.subarray(o + 8, o + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); if (data[8] !== 8 || data[9] !== 6) throw new Error('png: not RGBA8'); }
    if (type === 'IDAT') idat.push(data);
    o += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    if (raw[y * (w * 4 + 1)] !== 0) throw new Error('png: only filter 0 is read');
    out.set(raw.subarray(y * (w * 4 + 1) + 1, (y + 1) * (w * 4 + 1)), y * w * 4);
  }
  return { w, h, rgba: out };
}
const sha = (buf) => createHash('sha256').update(buf).digest('hex');

// ---- clean-room column jitter (lowbias32), shared by the baker and the oracle --------------------
const h01 = (a, b, salt) => lowbias32(lowbias32(lowbias32(salt >>> 0) ^ (a >>> 0)) ^ (b >>> 0)) / 4294967296;
function vnoise(px, pz, salt) {
  const ix = Math.floor(px), iz = Math.floor(pz);
  const fx = px - ix, fz = pz - iz;
  const sx = fx * fx * (3 - 2 * fx), sz = fz * fz * (3 - 2 * fz);
  const a = h01(ix, iz, salt), b = h01(ix + 1, iz, salt), c = h01(ix, iz + 1, salt), d = h01(ix + 1, iz + 1, salt);
  return (a + (b - a) * sx) * (1 - sz) + (c + (d - c) * sx) * sz;
}
// metres added to a column's distance and height tests: ragged edges that stay put (a function of the column)
function jitter(gx, gz) {
  const J = RULES.jitter;
  return (h01(gx, gz, J.salt_hash) - 0.5) * J.hash_amp_m + (vnoise(gx * COL / J.noise_scale_m, gz * COL / J.noise_scale_m, J.salt_noise) - 0.5) * J.noise_amp_m;
}
const jitterBound = RULES.jitter.hash_amp_m / 2 + RULES.jitter.noise_amp_m / 2;

// ---- the survey --------------------------------------------------------------------------------
function loadSurvey(dir) {
  const rd = (name) => readFileSync(join(dir, name));
  const f = rd('height.f32'), l = rd('lake.i32'), c = rd('course.i32');
  const meta = JSON.parse(rd('meta.json').toString('utf8'));
  const height = new Float64Array(N * N);
  const lake = new Int32Array(N * N);
  const course = new Int32Array(N * N);
  for (let i = 0; i < N * N; i++) {
    height[i] = f.readFloatLE(i * 4);
    lake[i] = l.readInt32LE(i * 4);
    course[i] = c.readInt32LE(i * 4);
  }
  const wet = new Uint8Array(N * N);
  const kind = new Uint8Array(N * N); // 0 none, 1 lake or spring, 2 river or fall
  const surf = new Float64Array(N * N); // the water's surface y at a wet column
  const level = new Int32Array(N * N); // its plan level (the tie-break key)
  for (let i = 0; i < N * N; i++) {
    if (course[i] !== DRY || lake[i] !== DRY) {
      wet[i] = 1;
      kind[i] = course[i] !== DRY ? 2 : 1;
      level[i] = course[i] !== DRY ? course[i] : lake[i];
      surf[i] = level[i] * 0.5 + 0.25; // 4 * level + 2 lattice units at the engine's scale
    }
  }
  return { meta, height, wet, kind, surf, level };
}

// distance in integer octile units: 1000 per column step, 1414 per diagonal step
const octile = (dx, dz) => {
  const ax = Math.abs(dx), az = Math.abs(dz);
  return ax > az ? 1000 * ax + 414 * az : 1000 * az + 414 * ax;
};
const WATER_R = 51; // columns: cost 51000 is 25.5 m, the field's range
const FOOT_R = 8;

// ---- the baker: seed stamping ----------------------------------------------------------------------
function nearestWaterStamp(S) {
  const best = new Int32Array(N * N).fill(0x7fffffff);
  const who = new Int32Array(N * N).fill(-1);
  const better = (cost, s, cur, curWho) => {
    if (cost !== cur) return cost < cur;
    if (curWho < 0) return true;
    if (S.kind[s] !== S.kind[curWho]) return S.kind[s] < S.kind[curWho];
    if (S.level[s] !== S.level[curWho]) return S.level[s] < S.level[curWho];
    return s < curWho;
  };
  for (let s = 0; s < N * N; s++) {
    if (!S.wet[s]) continue;
    const sx = s % N, sz = (s / N) | 0;
    for (let dz = -WATER_R; dz <= WATER_R; dz++) {
      const z = sz + dz;
      if (z < 0 || z >= N) continue;
      for (let dx = -WATER_R; dx <= WATER_R; dx++) {
        const x = sx + dx;
        if (x < 0 || x >= N) continue;
        const i = z * N + x;
        const cost = octile(dx, dz);
        if (better(cost, s, best[i], who[i])) { best[i] = cost; who[i] = s; }
      }
    }
  }
  return { best, who };
}
function nearestFootStamp(S, footMask) {
  const best = new Int32Array(N * N).fill(0x7fffffff);
  const who = new Int32Array(N * N).fill(-1);
  for (let s = 0; s < N * N; s++) {
    if (!footMask[s]) continue;
    const sx = s % N, sz = (s / N) | 0;
    for (let dz = -FOOT_R; dz <= FOOT_R; dz++) {
      const z = sz + dz;
      if (z < 0 || z >= N) continue;
      for (let dx = -FOOT_R; dx <= FOOT_R; dx++) {
        const x = sx + dx;
        if (x < 0 || x >= N) continue;
        const i = z * N + x;
        const cost = octile(dx, dz);
        // the tie-break: the nearest foot, then the highest, then the lowest index
        if (cost < best[i] || (cost === best[i] && (S.height[s] > S.height[who[i]] || (S.height[s] === S.height[who[i]] && s < who[i])))) {
          best[i] = cost; who[i] = s;
        }
      }
    }
  }
  return { best, who };
}
const FOUR = [[1, 0], [-1, 0], [0, 1], [0, -1]];
function riserFields(S) {
  const drop = new Float64Array(N * N); // largest fall to a 4-neighbour
  const rise = new Float64Array(N * N); // largest climb to a 4-neighbour
  for (let z = 0; z < N; z++) for (let x = 0; x < N; x++) {
    const i = z * N + x;
    for (const [dx, dz] of FOUR) {
      const xx = x + dx, zz = z + dz;
      if (xx < 0 || xx >= N || zz < 0 || zz >= N) continue;
      const hn = S.height[zz * N + xx];
      drop[i] = Math.max(drop[i], S.height[i] - hn);
      rise[i] = Math.max(rise[i], hn - S.height[i]);
    }
  }
  return { drop, rise };
}
const q10 = (cost) => Math.min(255, Math.round(cost * 0.005)); // octile cost -> 0.1 m units, clamped
const q8 = (m) => Math.min(255, Math.max(0, Math.round(m * 8))); // metres -> 0.125 m units, clamped

function bake(S) {
  const { best: wBest, who: wWho } = nearestWaterStamp(S);
  const { drop, rise } = riserFields(S);
  const foot = new Uint8Array(N * N);
  for (let i = 0; i < N * N; i++) foot[i] = rise[i] >= T.foot_rise_m ? 1 : 0;
  const { best: fBest, who: fWho } = nearestFootStamp(S, foot);
  const top = new Uint8Array(N * N * 4);
  const wall = new Uint8Array(N * N * 4);
  for (let z = 0; z < N; z++) for (let x = 0; x < N; x++) {
    const i = z * N + x;
    const gx = x - HALF, gz = z - HALF;
    const jit = jitter(gx, gz);
    let id = ID.grass;
    if (S.wet[i]) {
      id = S.kind[i] === 2 ? ID.gravel : ID.mud;
    } else {
      const haveW = wWho[i] >= 0;
      const wd = haveW ? wBest[i] * 0.0005 : 1e9;
      const nk = haveW ? S.kind[wWho[i]] : 0;
      const above = haveW ? S.height[i] - S.surf[wWho[i]] : 1e9;
      const haveF = fWho[i] >= 0 && S.height[i] <= S.height[fWho[i]] + T.scree_low_side_m;
      const fd = haveF ? fBest[i] * 0.0005 : 99;
      if (nk === 1 && wd + jit * T.mud.jitter < T.mud.within_m && above < T.mud.above_m) id = ID.mud;
      else if (nk === 2 && wd + jit * T.sand.jitter < T.sand.within_m && above < T.sand.above_m) id = ID.sand;
      else if (fd + jit * T.gravel.jitter < T.gravel.within_m) id = ID.gravel;
    }
    top[i * 4] = id; top[i * 4 + 3] = 255;
    wall[i * 4] = S.wet[i] ? 0 : (wWho[i] >= 0 ? q10(wBest[i]) : 255);
    wall[i * 4 + 1] = q8(drop[i]);
    wall[i * 4 + 3] = 255;
  }
  return { top, wall };
}

// ---- the oracle: per-column ring search and one plain if-chain ---------------------------------------
function oracle(S) {
  const top = new Uint8Array(N * N * 4);
  const wall = new Uint8Array(N * N * 4);
  const heightAt = (x, z) => S.height[z * N + x];
  for (let z = 0; z < N; z++) for (let x = 0; x < N; x++) {
    const i = z * N + x;
    // nearest water by growing rings (Chebyshev), stopping once no ring cell can still win
    let wCost = 0x7fffffff, wS = -1;
    for (let r = 0; r <= WATER_R; r++) {
      if (wS >= 0 && 1000 * r > wCost) break;
      for (let dz = -r; dz <= r; dz++) for (let dx = -r; dx <= r; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dz)) !== r) continue;
        const xx = x + dx, zz = z + dz;
        if (xx < 0 || xx >= N || zz < 0 || zz >= N) continue;
        const s = zz * N + xx;
        if (!S.wet[s]) continue;
        const c = octile(dx, dz);
        const win = c < wCost || (c === wCost && (S.kind[s] < S.kind[wS] || (S.kind[s] === S.kind[wS] && (S.level[s] < S.level[wS] || (S.level[s] === S.level[wS] && s < wS)))));
        if (win) { wCost = c; wS = s; }
      }
    }
    // nearest riser foot (a column with a 4-neighbour at least foot_rise_m higher)
    let fCost = 0x7fffffff, fS = -1;
    for (let dz = -FOOT_R; dz <= FOOT_R; dz++) for (let dx = -FOOT_R; dx <= FOOT_R; dx++) {
      const xx = x + dx, zz = z + dz;
      if (xx < 0 || xx >= N || zz < 0 || zz >= N) continue;
      let isFoot = false;
      for (const [ax, az] of FOUR) {
        const ux = xx + ax, uz = zz + az;
        if (ux >= 0 && ux < N && uz >= 0 && uz < N && heightAt(ux, uz) - heightAt(xx, zz) >= T.foot_rise_m) isFoot = true;
      }
      if (!isFoot) continue;
      const s = zz * N + xx;
      const c = octile(dx, dz);
      if (c < fCost || (c === fCost && (heightAt(xx, zz) > S.height[fS] || (heightAt(xx, zz) === S.height[fS] && s < fS)))) { fCost = c; fS = s; }
    }
    let id;
    const gx = x - HALF, gz = z - HALF;
    const jit = jitter(gx, gz);
    if (S.wet[i] === 1 && S.kind[i] === 2) id = ID.gravel;
    else if (S.wet[i] === 1) id = ID.mud;
    else {
      const wd = wS >= 0 ? wCost * 0.0005 : 1e9;
      const nk = wS >= 0 ? S.kind[wS] : 0;
      const above = wS >= 0 ? S.height[i] - S.surf[wS] : 1e9;
      const lowSide = fS >= 0 && S.height[i] <= S.height[fS] + T.scree_low_side_m;
      const fd = lowSide ? fCost * 0.0005 : 99;
      const mudOk = nk === 1 && wd + jit * T.mud.jitter < T.mud.within_m && above < T.mud.above_m;
      const sandOk = nk === 2 && wd + jit * T.sand.jitter < T.sand.within_m && above < T.sand.above_m;
      const gravelOk = fd + jit * T.gravel.jitter < T.gravel.within_m;
      id = mudOk ? ID.mud : sandOk ? ID.sand : gravelOk ? ID.gravel : ID.grass;
    }
    // the wall channels: distance to the nearest water and the largest fall to a 4-neighbour
    let dropM = 0;
    for (const [ax, az] of FOUR) {
      const ux = x + ax, uz = z + az;
      if (ux >= 0 && ux < N && uz >= 0 && uz < N) dropM = Math.max(dropM, heightAt(x, z) - heightAt(ux, uz));
    }
    top[i * 4] = id; top[i * 4 + 3] = 255;
    wall[i * 4] = S.wet[i] ? 0 : (wS >= 0 ? Math.min(255, Math.round(wCost * 0.005)) : 255);
    wall[i * 4 + 1] = Math.min(255, Math.max(0, Math.round(dropM * 8)));
    wall[i * 4 + 3] = 255;
  }
  return { top, wall };
}

// ---- invariants on the baked ids, from the survey alone ------------------------------------------------
function invariants(S, top) {
  const { best: wBest, who: wWho } = nearestWaterStamp(S);
  const { rise } = riserFields(S);
  const foot = new Uint8Array(N * N);
  for (let i = 0; i < N * N; i++) foot[i] = rise[i] >= T.foot_rise_m ? 1 : 0;
  const { best: fBest } = nearestFootStamp(S, foot);
  const counts = { grass: 0, gravel: 0, sand: 0, mud: 0 };
  const names = Object.fromEntries(Object.entries(ID).map(([k, v]) => [v, k]));
  const v = { mud_far_from_lake: 0, sand_far_from_river: 0, gravel_far_from_foot: 0, wet_not_bed_material: 0,
    unknown_id: 0, mud_rule_missed: 0, sand_rule_missed: 0 };
  for (let i = 0; i < N * N; i++) {
    const id = top[i * 4];
    const nm = names[id];
    if (nm in counts) counts[nm]++; else v.unknown_id++;
    const wd = wWho[i] >= 0 ? wBest[i] * 0.0005 : 1e9;
    const nk = wWho[i] >= 0 ? S.kind[wWho[i]] : 0;
    if (S.wet[i]) {
      if (id !== (S.kind[i] === 2 ? ID.gravel : ID.mud)) v.wet_not_bed_material++;
      continue;
    }
    if (id === ID.mud && !(nk === 1 && wd <= T.mud.within_m + jitterBound * T.mud.jitter)) v.mud_far_from_lake++;
    if (id === ID.sand && !(nk === 2 && wd <= T.sand.within_m + jitterBound * T.sand.jitter)) v.sand_far_from_river++;
    if (id === ID.gravel && !(fBest[i] * 0.0005 <= T.gravel.within_m + jitterBound * T.gravel.jitter)) v.gravel_far_from_foot++;
    // the rule order: a column that is certainly inside the mud band (jitter at its least favourable) is mud
    const above = wWho[i] >= 0 ? S.height[i] - S.surf[wWho[i]] : 1e9;
    if (nk === 1 && wd + jitterBound * T.mud.jitter < T.mud.within_m && above < T.mud.above_m && id !== ID.mud) v.mud_rule_missed++;
    if (nk === 2 && wd + jitterBound * T.sand.jitter < T.sand.within_m && above < T.sand.above_m && id !== ID.sand && id !== ID.mud) v.sand_rule_missed++;
  }
  return { counts, violations: v };
}

// ---- the flora oracle: the prototype's own placement, filtered by the committed ids -----------------------
// Runs the prototype (tag prototype-final, read-only, from a copy with the Spec #517 substituted
// primitives, exactly as tools/baseline/js_flora_oracle.mjs does), applies the prototype's own grass
// thinning, and drops every instance whose own column is a blocked material in fields_top.png. The
// engine's filter is C++ over the same ids; this function shares no code with it.
async function runFloraOracle(committedDir, chunksJson) {
  const { installExpPow, installMath, prepareTree } = await import('./baseline/proto_subst.mjs');
  const { homedir } = await import('node:os');
  const stalagDir = process['env'].STALAG_DIR || join(homedir(), 'dev', 'stalag');
  const work = mkdtempSync(join(tmpdir(), 'ground-flora-oracle-'));
  const tree = prepareTree(stalagDir, work, 'lowbias32');
  installMath('lowbias32');
  const imp = (rel) => import(pathToFileURL(join(tree.dir, rel)).href);
  const WP = await imp('src/waterplan.js');
  const planHash = WP.planHash(WP.computeWaterPlan(7));
  installExpPow();
  const FP = await imp('src/foliage-placement.js');
  const TP = await imp('src/tree-placement.js');
  const FL = await imp('src/flower-placement.js');
  const SHP = await imp('src/shrub-placement.js');
  const SHK = await imp('skins/shrubs.js');
  const SEED = 7, EXTENT = 224, CHUNK_M = 28;
  const meadow = FP.placeFoliage({ seed: SEED, extent: EXTENT });
  const treePl = TP.placeTrees({ seed: SEED, extent: EXTENT });
  const treeFlat = [];
  for (const k of Object.keys(treePl)) for (const t of treePl[k]) treeFlat.push(t);
  const flowerPl = FL.placeWildflowers({ seed: SEED, extent: EXTENT });
  const thinKeys = new Set();
  for (const id of FL.PLACED_FLOWERS) for (const it of flowerPl[id]) thinKeys.add(it.lidX + ',' + it.lidZ);
  const flowerKeys = new Set(thinKeys);
  const shrubPl = SHP.placeShrubs({ seed: SEED, extent: EXTENT, treeInstances: treeFlat, flowerLidKeys: flowerKeys });
  for (const o of SHK.PLACED_SHRUBS) for (const it of shrubPl[o.id]) thinKeys.add(it.lidX + ',' + it.lidZ);
  const GRASS_IDS = new Set(['tuft-billboard-baseline', 'tuft-billboard-bladed', 'cover-billboard-creep']);
  const fields = readPng(join(committedDir, 'fields_top.png'));
  const blocked = new Set(RULES.flora_blocked.map((n) => ID[n]));
  const isBlocked = (x, z) => {
    const gx = Math.floor(x / COL) + HALF, gz = Math.floor(z / COL) + HALF;
    if (gx < 0 || gx >= N || gz < 0 || gz >= N) return false;
    return blocked.has(fields.rgba[(gz * N + gx) * 4]);
  };
  const chunks = JSON.parse(readFileSync(chunksJson, 'utf8')).chunks; // [[cx, cz], ...]
  const want = new Set(chunks.map((c) => c[0] + ',' + c[1]));
  const inRing = (it) => want.has(Math.floor(it.lidX / CHUNK_M) + ',' + Math.floor(it.lidZ / CHUNK_M));
  const tally = (blockCheck) => {
    const o = { meadow: 0, flowers: 0, shrubs: 0, meadow_removed: 0, understory_removed: 0, meadow_all: 0, understory_all: 0,
      forms: { meadow: {}, flowers: {}, shrubs: {} } };
    const bump = (group, id) => { o.forms[group][id] = (o.forms[group][id] || 0) + 1; };
    FP.SELECTED_FORMS.forEach((id) => {
      for (const it of meadow[id]) {
        if (GRASS_IDS.has(id) && thinKeys.has(it.lidX + ',' + it.lidZ)) continue; // the prototype's thinning
        if (!inRing(it)) continue;
        o.meadow_all++;
        if (blockCheck && isBlocked(it.x, it.z)) o.meadow_removed++; else { o.meadow++; bump('meadow', id); }
      }
    });
    for (const id of FL.PLACED_FLOWERS) for (const it of flowerPl[id]) {
      if (!inRing(it)) continue;
      o.understory_all++;
      if (blockCheck && isBlocked(it.x, it.z)) o.understory_removed++; else { o.flowers++; bump('flowers', id); }
    }
    for (const sh of SHK.PLACED_SHRUBS) for (const it of shrubPl[sh.id]) {
      if (!inRing(it)) continue;
      o.understory_all++;
      if (blockCheck && isBlocked(it.x, it.z)) o.understory_removed++; else { o.shrubs++; bump('shrubs', sh.id); }
    }
    return o;
  };
  const filtered = tally(true), unfiltered = tally(false);
  return { plan_hash: planHash, chunks: chunks.length, unfiltered_total: unfiltered.meadow + unfiltered.flowers + unfiltered.shrubs,
    filtered_total: filtered.meadow + filtered.flowers + filtered.shrubs, meadow: filtered.meadow, flowers: filtered.flowers, shrubs: filtered.shrubs,
    removed_meadow: filtered.meadow_removed, removed_understory: filtered.understory_removed,
    meadow_unfiltered: unfiltered.meadow, understory_unfiltered: unfiltered.flowers + unfiltered.shrubs,
    per_form: filtered.forms, per_form_unfiltered: unfiltered.forms };
}

// ---- commands ------------------------------------------------------------------------------------------------
function writeFields(outDir, F) {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'fields_top.png'), png(N, N, F.top));
  writeFileSync(join(outDir, 'fields_wall.png'), png(N, N, F.wall));
  writeFileSync(join(outDir, 'fields_sha.json'), JSON.stringify({ top: sha(F.top), wall: sha(F.wall) }) + '\n');
}
const sameBytes = (a, b) => a.length === b.length && Buffer.compare(Buffer.from(a), Buffer.from(b)) === 0;

async function main() {
  const [cmd, a, b, c] = process.argv.slice(2);
  if (cmd === 'bake') {
    const S = loadSurvey(resolve(a));
    writeFields(resolve(b), bake(S));
    console.log(`bake_ground_fields: math=lowbias32 wrote fields_top.png, fields_wall.png, fields_sha.json -> ${resolve(b)}`);
  } else if (cmd === 'check') {
    const S = loadSurvey(resolve(a));
    const committed = resolve(b);
    const tmp = mkdtempSync(join(tmpdir(), 'ground-fields-'));
    const F = bake(S);
    writeFields(tmp, F);
    const eqFile = (name) => existsSync(join(committed, name)) && sameBytes(readFileSync(join(tmp, name)), readFileSync(join(committed, name)));
    const O = oracle(S);
    let oracleEq = false;
    try {
      const ct = readPng(join(committed, 'fields_top.png')), cw = readPng(join(committed, 'fields_wall.png'));
      oracleEq = sameBytes(O.top, ct.rgba) && sameBytes(O.wall, cw.rgba);
    } catch (e) { oracleEq = false; }
    const inv = invariants(S, F.top);
    const rec = {
      generated_epoch: Math.floor(Date.now() / 1000),
      phase: 2,
      plan_hash: S.meta.plan_hash,
      plan_hash_expected: PLAN_HASH,
      survey_columns: S.meta.columns,
      fresh_equals_committed: { top: eqFile('fields_top.png'), wall: eqFile('fields_wall.png'), sha: eqFile('fields_sha.json') },
      oracle_equals_committed: oracleEq,
      oracle_equals_fresh: sameBytes(O.top, F.top) && sameBytes(O.wall, F.wall),
      counts: inv.counts,
      violations: inv.violations,
      field_sha256: { top: sha(F.top), wall: sha(F.wall) },
    };
    writeFileSync(resolve(c), JSON.stringify(rec));
    console.log(`bake_ground_fields: check wrote ${resolve(c)}`);
  } else if (cmd === 'oracle-flora') {
    const r = await runFloraOracle(resolve(a), resolve(b));
    console.log(JSON.stringify(r));
  } else {
    console.error('usage: bake_ground_fields.mjs bake <survey> <out> | check <survey> <committed> <record> | oracle-flora <committed> <chunks.json>');
    process.exit(2);
  }
}
await main();
