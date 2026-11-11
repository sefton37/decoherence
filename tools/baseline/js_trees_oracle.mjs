#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549: the S3 and S4 oracle ("the forest and the understory") for the engine's tree,
// wildflower and shrub placement and the grass thinning.
//
// Runs the frozen Stalag prototype (tag prototype-final) from $STALAG_DIR (default ~/dev/stalag),
// read-only, from a copy under the output directory, with the Spec #517 primitives substituted
// (tools/baseline/proto_subst.mjs; modes as js_flora_oracle.mjs). It writes oracle.json into the
// output directory: everything the engine must reproduce, hashed over raw little-endian dumps.
//
//   trees   14 float64 per instance (x, y, z, yaw, scale, height, wJit, hJit, leanX, leanZ,
//           valJit, hueJit, lidX, lidZ); the float32 chunk-local transform matrices; the float32
//           crown colours. The matrix composition below is the one three.js (MIT licence)
//           Object3D performs for rotation.set(leanX, yaw, leanZ) in Euler order XYZ with
//           scale (s*wJit, s*hJit, s*wJit): quaternion from Euler, then Matrix4.compose.
//           hsv2rgb is read out of the prototype's own index.html, not copied.
//   flowers 9 float64 per instance (x, y, z, yaw, scale, lidX, lidZ, tier 0 or 1, count in lid)
//   shrubs  7 float64 per instance (x, y, z, yaw, scale, lidX, lidZ)
//   meadow  the S2 placement with the grass thinning of index.html line 1414 applied
//
// Chunk order for the per-chunk hashes: chunks ascending by (cz, cx), the chunk of a lid centre.
//
// Environment: TREES_ORACLE_OUT (required), STALAG_DIR, WORLD_ORACLE_SUBST (default lowbias32)
// Option: --view-count '<json pose>' prints the pure-geometry frustum counts for the real-entry
// check instead of writing the oracle (see viewCount below).

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { installMath, prepareTree } from './proto_subst.mjs';

const E = process['env'];
const outDir = E.TREES_ORACLE_OUT;
if (!outDir) {
  console.error('js_trees_oracle: TREES_ORACLE_OUT is required');
  process.exit(2);
}
mkdirSync(outDir, { recursive: true });
const stalagDir = E.STALAG_DIR || join(homedir(), 'dev', 'stalag');
const SUBST_MODE = E.WORLD_ORACLE_SUBST || 'lowbias32';
const tree = prepareTree(stalagDir, outDir, SUBST_MODE);
installMath(SUBST_MODE);
const imp = (rel) => import(pathToFileURL(join(tree.dir, rel)).href);

const SEED = 7;
const EXTENT = 224;
const CHUNK_M = 28;
const RING = [-2, 2];

const WP = await imp('src/waterplan.js');
const plan = WP.computeWaterPlan(SEED); // the shared plan the placement queries read; solved with host math
const planHash = WP.planHash(plan);

const TP = await imp('src/tree-placement.js');
const FP = await imp('src/foliage-placement.js');
const FL = await imp('src/flower-placement.js');
const SH = await imp('src/shrub-placement.js');
const SK = await imp('skins/shrubs.js');
const TR = await imp('skins/trees.js');

const sha = (buf) => createHash('sha256').update(buf).digest('hex');
const f64 = (arr) => Buffer.from(new Float64Array(arr).buffer);
const f32 = (arr) => Buffer.from(new Float32Array(arr).buffer);

// hsv2rgb straight from the frozen index.html (the function body between its signature and the
// next top-level statement), so the colour maths is the prototype's text, not a transcription.
const html = readFileSync(join(stalagDir, 'index.html'), 'utf8');
const hsvStart = html.indexOf('function hsv2rgb(h, s, v) {');
const hsvEnd = html.indexOf('\n}\n', hsvStart) + 3;
if (hsvStart < 0 || hsvEnd < hsvStart) throw new Error('hsv2rgb not found in index.html');
const hsv2rgb = new Function(`${html.slice(hsvStart, hsvEnd)}\nreturn hsv2rgb;`)();

const chunkOf = (v) => Math.floor(v / CHUNK_M);

// ------------------------------------------------------------------ trees
const placement = TP.placeTrees({ seed: SEED, extent: EXTENT });
const TREE_IDS = TR.TREE_OPTIONS.map((o) => o.id);
const DEAD = new Set(['standing-snag', 'cut-stump']);

// three.js Object3D: rotation.set(x, y, z) (XYZ) -> Quaternion.setFromEuler -> Matrix4.compose
function treeMatrix(it, x0, z0) {
  const c1 = Math.cos(it.leanX / 2), c2 = Math.cos(it.yaw / 2), c3 = Math.cos(it.leanZ / 2);
  const s1 = Math.sin(it.leanX / 2), s2 = Math.sin(it.yaw / 2), s3 = Math.sin(it.leanZ / 2);
  const qx = s1 * c2 * c3 + c1 * s2 * s3;
  const qy = c1 * s2 * c3 - s1 * c2 * s3;
  const qz = c1 * c2 * s3 + s1 * s2 * c3;
  const qw = c1 * c2 * c3 - s1 * s2 * s3;
  const sx = it.scale * it.wJit, sy = it.scale * it.hJit, sz = it.scale * it.wJit;
  const x2 = qx + qx, y2 = qy + qy, z2 = qz + qz;
  const xx = qx * x2, xy = qx * y2, xz = qx * z2, yy = qy * y2, yz = qy * z2, zz = qz * z2;
  const wx = qw * x2, wy = qw * y2, wz = qw * z2;
  const te0 = (1 - (yy + zz)) * sx, te1 = (xy + wz) * sx, te2 = (xz - wy) * sx;
  const te4 = (xy - wz) * sy, te5 = (1 - (xx + zz)) * sy, te6 = (yz + wx) * sy;
  const te8 = (xz + wy) * sz, te9 = (yz - wx) * sz, te10 = (1 - (xx + yy)) * sz;
  return [te0, te4, te8, it.x - x0, te1, te5, te9, it.y, te2, te6, te10, it.z - z0];
}
function treeColor(it) {
  const [r, g, b] = hsv2rgb(128 + it.hueJit, 0.22, 1);
  return [r * it.valJit, g * it.valJit, b * it.valJit];
}
const dump14 = (list) => {
  const a = new Float64Array(list.length * 14);
  list.forEach((it, i) => a.set([it.x, it.y, it.z, it.yaw, it.scale, it.height, it.wJit, it.hJit, it.leanX, it.leanZ, it.valJit, it.hueJit, it.lidX ?? 0, it.lidZ ?? 0], i * 14));
  return Buffer.from(a.buffer);
};

// The prototype's tree instances carry no lid centre; it is the lid whose centre the instance
// sits within 0.15 m of (the placement jitter is +-0.15 m, lid centres are at least 0.5 m apart).
const SF = 0.125;
const lidSet = FP.listLids({ seed: SEED, extent: EXTENT });
const lidMap = new Map();
for (const l of lidSet) lidMap.set(`${l.cx},${l.cz}`, [(l.cx + 2) * SF, (l.cz + 2) * SF]);
const findLid = (it) => {
  // instance = lid centre + jitter in [-0.15, 0.15]; the lattice step of lid centres is >= 0.5 m
  const gx = Math.round(it.x / SF - 2), gz = Math.round(it.z / SF - 2);
  for (let dz = -2; dz <= 2; dz++) for (let dx = -2; dx <= 2; dx++) {
    const k = `${gx + dx},${gz + dz}`;
    const c = lidMap.get(k);
    if (c && Math.abs(it.x - c[0]) <= 0.15 + 1e-9 && Math.abs(it.z - c[1]) <= 0.15 + 1e-9) return c;
  }
  throw new Error('tree not on a lid');
};
for (const id of TREE_IDS) for (const it of placement[id]) { const c = findLid(it); it.lidX = c[0]; it.lidZ = c[1]; }

const treeForms = TREE_IDS.map((id) => ({ id, count: placement[id].length, hash: sha(dump14(placement[id])) }));
const treeTotal = treeForms.reduce((s, f) => s + f.count, 0);

// per-chunk grouping by lid centre, chunks ascending (cz, cx)
function groupByChunk(perForm) {
  const chunks = new Map();
  perForm.forEach((arr, fi) => {
    for (const it of arr) {
      const cz = chunkOf(it.lidZ), cx = chunkOf(it.lidX);
      const k = cz + ',' + cx;
      if (!chunks.has(k)) chunks.set(k, { cz, cx, forms: perForm.map(() => []) });
      chunks.get(k).forms[fi].push(it);
    }
  });
  return [...chunks.values()].sort((a, b) => a.cz - b.cz || a.cx - b.cx);
}
const treeLists = TREE_IDS.map((id) => placement[id]);
const treeChunks = groupByChunk(treeLists);
const treeChunkHash = createHash('sha256');
for (const c of treeChunks) for (const l of c.forms) treeChunkHash.update(dump14(l));
// per-form matrix and colour hashes, chunks ascending
const mxHash = [], colHash = [];
TREE_IDS.forEach((id, fi) => {
  const hm = createHash('sha256'), hc = createHash('sha256');
  for (const c of treeChunks) {
    const x0 = c.cx * CHUNK_M, z0 = c.cz * CHUNK_M;
    for (const it of c.forms[fi]) {
      hm.update(f32(treeMatrix(it, x0, z0)));
      if (!DEAD.has(id)) hc.update(f32(treeColor(it)));
    }
  }
  mxHash.push(hm.digest('hex'));
  colHash.push(hc.digest('hex'));
});
const treeRing = TREE_IDS.map(() => 0);
const ringChunks = new Set();
let treesRingTotal = 0;
for (const c of treeChunks) {
  if (c.cx < RING[0] || c.cx > RING[1] || c.cz < RING[0] || c.cz > RING[1]) continue;
  c.forms.forEach((l, fi) => { treeRing[fi] += l.length; treesRingTotal += l.length; });
  if (c.forms.some((l) => l.length)) ringChunks.add(c.cz + ',' + c.cx);
}
let nearestTree = Infinity;
for (const id of TREE_IDS) for (const it of placement[id]) nearestTree = Math.min(nearestTree, Math.hypot(it.x, it.z));

// ------------------------------------------------------------------ flowers, shrubs
const FLOWER_IDS = FL.PLACED_FLOWERS;
const flowers = FL.placeWildflowers({ seed: SEED, extent: EXTENT });
const SHRUB_IDS = SK.PLACED_SHRUBS.map((s) => s.id);
const treeFlat = [];
for (const k of Object.keys(placement)) for (const t of placement[k]) treeFlat.push(t);
const flowerKeys = new Set();
for (const id of FLOWER_IDS) for (const it of flowers[id]) flowerKeys.add(it.lidX + ',' + it.lidZ);
const shrubs = SH.placeShrubs({ seed: SEED, extent: EXTENT, treeInstances: treeFlat, flowerLidKeys: flowerKeys });
const shrubKeys = new Set();
for (const id of SHRUB_IDS) for (const it of shrubs[id]) shrubKeys.add(it.lidX + ',' + it.lidZ);

const dumpFlower = (id) => {
  const list = flowers[id];
  const per = new Map();
  for (const it of list) per.set(it.lidX + ',' + it.lidZ, (per.get(it.lidX + ',' + it.lidZ) || 0) + 1);
  const a = new Float64Array(list.length * 9);
  list.forEach((it, i) => a.set([it.x, it.y, it.z, it.yaw, it.scale, it.lidX, it.lidZ, it.tier === 'vivid' ? 1 : 0, per.get(it.lidX + ',' + it.lidZ)], i * 9));
  return Buffer.from(a.buffer);
};
const dumpShrub = (id) => {
  const list = shrubs[id];
  const a = new Float64Array(list.length * 7);
  list.forEach((it, i) => a.set([it.x, it.y, it.z, it.yaw, it.scale, it.lidX, it.lidZ], i * 7));
  return Buffer.from(a.buffer);
};
const inRing = (it) => { const cx = chunkOf(it.lidX), cz = chunkOf(it.lidZ); return cx >= RING[0] && cx <= RING[1] && cz >= RING[0] && cz <= RING[1]; };
const ringInfo = (ids, table) => {
  const per = ids.map((id) => table[id].filter(inRing).length);
  const chunks = new Set();
  let nearest = Infinity;
  ids.forEach((id) => table[id].filter(inRing).forEach((it) => { chunks.add(chunkOf(it.lidZ) + ',' + chunkOf(it.lidX)); nearest = Math.min(nearest, Math.hypot(it.x, it.z)); }));
  return { total: per.reduce((a, b) => a + b, 0), per_form: per, chunks_with: chunks.size, nearest };
};
const flowerRing = ringInfo(FLOWER_IDS, flowers);
const shrubRing = ringInfo(SHRUB_IDS, shrubs);
const flowerForms = FLOWER_IDS.map((id) => ({
  id, count: flowers[id].length, hash: sha(dumpFlower(id)),
  muted: flowers[id].filter((i) => i.tier === 'muted').length, vivid: flowers[id].filter((i) => i.tier === 'vivid').length,
}));
const shrubForms = SHRUB_IDS.map((id) => ({ id, count: shrubs[id].length, hash: sha(dumpShrub(id)) }));

// ------------------------------------------------------------------ meadow thinning (index.html 1414)
const meadow = FP.placeFoliage({ seed: SEED, extent: EXTENT });
const GRASS = new Set(['tuft-billboard-baseline', 'tuft-billboard-bladed', 'cover-billboard-creep']);
const thinned = {};
let rawTotal = 0, worldTotal = 0, ringTotal = 0;
const nonGrassRemoved = 0; // the rule only ever drops the three grass forms
const worldPer = {}, ringPer = {};
for (const id of FP.SELECTED_FORMS) {
  worldPer[id] = 0; ringPer[id] = 0;
  for (const it of meadow[id]) {
    rawTotal++;
    const key = it.lidX + ',' + it.lidZ;
    const drop = GRASS.has(id) && (flowerKeys.has(key) || shrubKeys.has(key));
    if (drop) continue;
    worldTotal++; worldPer[id]++;
    if (inRing(it)) { ringTotal++; ringPer[id]++; }
  }
}
let rawRing = 0;
for (const id of FP.SELECTED_FORMS) for (const it of meadow[id]) if (inRing(it)) rawRing++;
thinned.rule = 'grass_on_flower_or_shrub_lid';
thinned.grass_forms = [...GRASS].sort();
thinned.raw_total = rawTotal;
thinned.world_total = worldTotal;
thinned.ring_total = ringTotal;
thinned.removed_world = rawTotal - worldTotal;
thinned.removed_ring = rawRing - ringTotal;
thinned.non_grass_removed = nonGrassRemoved;
thinned.world_per_form = worldPer;
thinned.ring_per_form = ringPer;

// ------------------------------------------------------------------ --view-count '<pose json>'
// Pure-geometry counts of the real entry's frame, from the pose alone, over the spawn ring (the loaded
// chunks): a pinhole camera with vertical fov and aspect, the marker point root + 3 m (trees) or
// root + 0.5 m (flowers, shrubs), in front of the near plane (0.05 m) and inside both half-angles.
const vc = process.argv.indexOf('--view-count');
if (vc > 0) {
  const pose = JSON.parse(process.argv[vc + 1]);
  const [cx0, cy0, cz0] = pose.cam, [fx, fy, fz] = pose.fwd;
  const th = Math.tan((pose.fov_deg * Math.PI / 180) / 2);
  let rx = fy * 0 - fz * 1, ry = fz * 0 - fx * 0, rz = fx * 1 - fy * 0;
  const rl = Math.sqrt(rx * rx + ry * ry + rz * rz); rx /= rl; ry /= rl; rz /= rl;
  const ux = ry * fz - rz * fy, uy = rz * fx - rx * fz, uz = rx * fy - ry * fx;
  const count = (items, marker) => {
    let inF = 0, w30 = 0, nearest = Infinity;
    for (const it of items) {
      nearest = Math.min(nearest, Math.sqrt(it.x * it.x + it.z * it.z));
      const px = it.x - cx0, py = it.y + marker - cy0, pz = it.z - cz0;
      const z = px * fx + py * fy + pz * fz;
      if (z <= 0.05) continue;
      const x = px * rx + py * ry + pz * rz, y = px * ux + py * uy + pz * uz;
      if (Math.abs(x) > z * th * pose.aspect || Math.abs(y) > z * th) continue;
      inF++;
      if (Math.sqrt(px * px + py * py + pz * pz) <= 30) w30++;
    }
    return { in_frustum: inF, within_30m: w30, nearest_root_m: nearest };
  };
  const ringItems = (lists) => lists.flat().filter(inRing);
  const t = count(ringItems(TREE_IDS.map((id) => placement[id])), 3.0);
  const f = count(ringItems(FLOWER_IDS.map((id) => flowers[id])), 0.5);
  const s = count(ringItems(SHRUB_IDS.map((id) => shrubs[id])), 0.5);
  console.log(JSON.stringify({
    in_frustum: t.in_frustum, within_30m: t.within_30m, nearest_root_m: t.nearest_root_m,
    flowers_in_frustum: f.in_frustum, flowers_within_30m: f.within_30m, flowers_nearest_root_m: f.nearest_root_m,
    shrubs_in_frustum: s.in_frustum, shrubs_within_30m: s.within_30m, shrubs_nearest_root_m: s.nearest_root_m,
  }));
  process.exit(0);
}

const head = execFileSync('git', ['-C', stalagDir, 'rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim();
const ringObj = (info) => ({ total: info.total, per_form: info.per_form, chunks_with: info.chunks_with, nearest_root_m: info.nearest });

writeFileSync(join(outDir, 'oracle.json'), JSON.stringify({
  generated_epoch: Math.floor(Date.now() / 1000),
  stalag_head: head,
  oracle_subst: SUBST_MODE,
  plan_hash: planHash,
  placement: {
    forms: treeForms.map((f, i) => ({ ...f, mx_hash: mxHash[i], col_hash: colHash[i] })),
    total: treeTotal,
    nearest_root_m: nearestTree,
    chunks: { count: treeChunks.length, hash: treeChunkHash.digest('hex'), total: treeTotal },
    ring: {
      rule: 'lid_centre', coord_min: RING[0], coord_max: RING[1], chunks: 25,
      trees: treesRingTotal, chunks_with_trees: ringChunks.size, per_form: treeRing,
    },
  },
  flowers: { ids: FLOWER_IDS, forms: flowerForms, total: flowerForms.reduce((s, f) => s + f.count, 0), lid_keys: flowerKeys.size, ring: ringObj(flowerRing) },
  shrubs: { ids: SHRUB_IDS, forms: shrubForms, total: shrubForms.reduce((s, f) => s + f.count, 0), lid_keys: shrubKeys.size, ring: ringObj(shrubRing) },
  meadow_thinned: thinned,
}));
console.log(`js_trees_oracle: ${treeTotal} trees, ${flowerForms.reduce((s, f) => s + f.count, 0)} flowers, ${shrubForms.reduce((s, f) => s + f.count, 0)} shrubs, meadow ${rawTotal} -> ${worldTotal}, plan ${planHash} -> ${outDir}`);
