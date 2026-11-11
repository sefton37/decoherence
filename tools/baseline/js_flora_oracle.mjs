#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545: the S2 "meadow" oracle for the engine's wind field and foliage placement.
//
// Runs the frozen Stalag prototype (tag prototype-final) from $STALAG_DIR (default ~/dev/stalag),
// read-only, from a copy under the output directory, with the Spec #517 primitives substituted
// (tools/baseline/proto_subst.mjs) and, AFTER the water plan is solved, the clean-room exp and pow
// as well (Spec #545 Phase A; the plan itself is solved with the host math so plan hash 4448de3c
// cannot move). It then writes into the output directory everything the engine must reproduce:
//
//   oracle.json       {generated_epoch, stalag_head, oracle_subst, plan_hash, placement{...}, wind{...}}
//   samples.bin       wind sample inputs, 4 little-endian f64 (x, y, z, t) per sample
//   wind_NAME.bin     the raw f64 outputs of each wind part for those samples
//
// Environment: FLORA_ORACLE_OUT (required), STALAG_DIR, WORLD_ORACLE_SUBST (default lowbias32)

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { installExpPow, installMath, lowbias32, prepareTree } from './proto_subst.mjs';

const E = process['env'];
const outDir = E.FLORA_ORACLE_OUT;
if (!outDir) {
  console.error('js_flora_oracle: FLORA_ORACLE_OUT is required');
  process.exit(2);
}
mkdirSync(outDir, { recursive: true });
const stalagDir = E.STALAG_DIR || join(homedir(), 'dev', 'stalag');
const SUBST_MODE = E.WORLD_ORACLE_SUBST || 'lowbias32';
const tree = prepareTree(stalagDir, outDir, SUBST_MODE);
installMath(SUBST_MODE);
// Only so the oracle can call the three internal pieces the engine ports; behaviour unchanged.
appendFileSync(join(tree.dir, 'src', 'windfield.js'), '\nexport { horizontalCurl, gustGain, boundaryLayer };\n');
const imp = (rel) => import(pathToFileURL(join(tree.dir, rel)).href);

const SEED = 7;
const EXTENT = 224;
const CHUNK_M = 28;
const SF = 0.125;

const WP = await imp('src/waterplan.js');
const plan = WP.computeWaterPlan(SEED); // solved with the host exp/pow: the S1 plan must not move
const planHash = WP.planHash(plan);
installExpPow(); // from here on windfield.js sees the clean-room exp and pow

const WF = await imp('src/windfield.js');
const WM = await imp('src/worldmesh.js');
const FP = await imp('src/foliage-placement.js');

const sha = (buf) => createHash('sha256').update(buf).digest('hex');
const f64bytes = (arr) => Buffer.from(new Float64Array(arr).buffer);

// ------------------------------------------------------------------ placement
const placement = FP.placeFoliage({ seed: SEED, extent: EXTENT });
const lids = FP.listLids({ seed: SEED, extent: EXTENT });
const dumpInst = (list) => {
  const a = new Float64Array(list.length * 7);
  list.forEach((it, i) => a.set([it.x, it.y, it.z, it.yaw, it.scale, it.lidX, it.lidZ], i * 7));
  return Buffer.from(a.buffer);
};
const forms = FP.SELECTED_FORMS.map((id) => ({ id, count: placement[id].length, hash: sha(dumpInst(placement[id])) }));
const total = forms.reduce((s, f) => s + f.count, 0);

// per-chunk union: chunk of an instance = chunk of its lid centre; chunks ascending by (cz, cx),
// within a chunk form by form, instances in the prototype's own order
const chunkKey = (it) => [Math.floor(it.lidZ / CHUNK_M), Math.floor(it.lidX / CHUNK_M)];
const chunks = new Map();
FP.SELECTED_FORMS.forEach((id, fi) => {
  for (const it of placement[id]) {
    const [cz, cx] = chunkKey(it);
    const k = cz + ',' + cx;
    if (!chunks.has(k)) chunks.set(k, { cz, cx, forms: FP.SELECTED_FORMS.map(() => []) });
    chunks.get(k).forms[fi].push(it);
  }
});
const chunkList = [...chunks.values()].sort((a, b) => a.cz - b.cz || a.cx - b.cx);
const chunkHash = createHash('sha256');
for (const c of chunkList) for (const l of c.forms) chunkHash.update(dumpInst(l));

// Spec #549: the rendered meadow drops the grass forms on every lid that holds a wildflower or a shrub
// (index.html line 1414); the per-chunk counts after that thinning are what the view probe compares with.
const TP = await imp('src/tree-placement.js');
const FL = await imp('src/flower-placement.js');
const SHP = await imp('src/shrub-placement.js');
const SHK = await imp('skins/shrubs.js');
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
const thinnedCounts = {};
FP.SELECTED_FORMS.forEach((id) => {
  for (const it of placement[id]) {
    if (GRASS_IDS.has(id) && thinKeys.has(it.lidX + ',' + it.lidZ)) continue;
    const k = Math.floor(it.lidX / CHUNK_M) + ',' + Math.floor(it.lidZ / CHUNK_M);
    thinnedCounts[k] = (thinnedCounts[k] || 0) + 1;
  }
});

// the four prototype checks (test/foliage-placement.test.mjs), run at seed 7
const a2 = FP.placeFoliage({ seed: SEED, extent: EXTENT });
const pcheck = {};
pcheck.DETERMINISM = JSON.stringify(placement) === JSON.stringify(a2);
pcheck.ALL_FORMS_HAVE_INSTANCES = FP.SELECTED_FORMS.every((f) => (placement[f] || []).length > 0);
{
  const mm = (v) => Math.round(v * 1000);
  const lidSet = new Set(lids.map((l) => `${mm((l.cx + 2) * 0.125)},${mm((l.cz + 2) * 0.125)}`));
  let tot = 0, off = 0;
  for (const f of FP.SELECTED_FORMS) for (const ins of placement[f]) {
    tot++;
    const known = lidSet.has(`${mm(ins.lidX)},${mm(ins.lidZ)}`);
    const within = Math.abs(ins.x - ins.lidX) <= FP.LID_JITTER + 1e-9 && Math.abs(ins.z - ins.lidZ) <= FP.LID_JITTER + 1e-9;
    if (!(known && within && ins.y > 0)) off++;
  }
  pcheck.LID_ONLY = tot > 0 && off === 0;
}
{
  const EXCLUDED = ['cover-billboard-mat', 'shrub-billboard-star', 'rock-mossy', 'rock-sensor'];
  pcheck.EXCLUDED_FORMS_ZERO = EXCLUDED.every((f) => !(f in placement) || placement[f].length === 0) && EXCLUDED.every((f) => !FP.SELECTED_FORMS.includes(f));
}

// ------------------------------------------------------------------ wind samples
let counter = 0;
const rnd = () => lowbias32(545 + 2 * counter++) / 4294967296;
const groundY = (x, z) => WM.surfaceHeight(x / SF, z / SF, SEED) * SF;
const samples = [];
const push = (x, z, t, up) => samples.push([x, groundY(x, z) + up, z, t]);
for (let i = 0; i < 5200; i++) push((rnd() - 0.5) * 220, (rnd() - 0.5) * 220, rnd() * 2400, rnd() * 25 - 0.5);
for (let i = 0; i < 500; i++) { // inside real vortices
  const t = rnd() * 2400;
  const vs = WF.activeVorticles(t, SEED, 0, 0, 84).filter((v) => Math.abs(v.cx) < 110 && Math.abs(v.cz) < 110);
  if (!vs.length) continue;
  const v = vs[Math.floor(rnd() * vs.length)];
  push(v.cx + (rnd() - 0.5) * 12, v.cz + (rnd() - 0.5) * 12, t, rnd() * 3);
}
for (let i = 0; i < 4000 && samples.length < 7600; i++) { // on a passing front wall
  const t = rnd() * 2400, f = WF.currentFront(t, SEED);
  if (!f.active) continue;
  const u = (rnd() - 0.5) * 200, s = (rnd() - 0.5) * 40;
  const x = f.nx * (f.offset + s) - f.nz * u, z = f.nz * (f.offset + s) + f.nx * u;
  if (Math.abs(x) > 110 || Math.abs(z) > 110) continue;
  push(x, z, t, rnd() * 10);
}
for (let i = 0; i < 500; i++) { // deep night and early afternoon, across the day cycle
  const d = (i % 2 ? 0.5 : 0) + (rnd() - 0.5) * 0.2;
  const t = (d - 0.3) * 600 + 600 * Math.floor(rnd() * 4);
  push((rnd() - 0.5) * 220, (rnd() - 0.5) * 220, Math.max(0, t), rnd() * 6);
}
const sampBuf = new Float64Array(samples.flat());

const parts = { boundary: [], deflect: [], flow: [], front: [], gust: [], katabatic: [], prevail: [], thermal: [], vnoise3: [], vorticle: [], windat: [] };
const ex = { vortex: 0, front: 0, night: 0, day: 0, slope: 0 };
for (const [x, y, z, t] of samples) {
  parts.vnoise3.push(WF.vnoise3(x * 0.1, t * 0.05, z * 0.1, SEED));
  const th = WF.prevailHeading(t, SEED);
  parts.prevail.push(th);
  const fl = WF.horizontalCurl(x, z, t, SEED, th);
  parts.flow.push(fl[0], fl[1]);
  parts.gust.push(WF.gustGain(x, z, t, SEED, Math.cos(th), Math.sin(th)));
  parts.boundary.push(WF.boundaryLayer(y));
  const de = WF.obstacleDeflect(x, z, SEED, fl[0], fl[1]);
  parts.deflect.push(de[0], de[1]);
  if (de[0] !== fl[0] || de[1] !== fl[1]) ex.slope++;
  const th2 = WF.thermalUpdraft(x, z, t, SEED, y);
  parts.thermal.push(th2);
  if (th2 > 0) ex.day++;
  const ka = WF.katabaticDrain(x, z, t, SEED, y);
  parts.katabatic.push(...ka);
  if (ka[0] !== 0 || ka[2] !== 0) ex.night++;
  const vo = WF.vorticleField(x, z, t, SEED);
  parts.vorticle.push(...vo);
  if (vo[0] !== 0 || vo[1] !== 0 || vo[2] !== 0) ex.vortex++;
  const fg = WF.frontAt(x, z, t, SEED), cf = WF.currentFront(t, SEED);
  parts.front.push(fg.gain, fg.sbs, cf.active, cf.nx, cf.nz, cf.offset, cf.peak);
  if (fg.gain > 1) ex.front++;
  const w = WF.windAt(x, y, z, t, SEED);
  parts.windat.push(w.vec[0], w.vec[1], w.vec[2], w.strength);
}
writeFileSync(join(outDir, 'samples.bin'), Buffer.from(sampBuf.buffer));
for (const [name, arr] of Object.entries(parts)) writeFileSync(join(outDir, `wind_${name}.bin`), f64bytes(arr));

// ------------------------------------------------------------------ ported windfield invariants (skins/test-windfield.mjs)
const jc = {};
{
  const S = SEED, SF_ = 0.125;
  const r = WF.windAt(10, 2, 5, 100, S);
  jc.shape = r.vec.length === 3 && r.vec.every((v) => Number.isFinite(v)) && r.strength >= 0 && r.strength <= 1;
  const a = WF.windAt(10, 2, 5, 100, S), b = WF.windAt(10, 2, 5, 100, S);
  jc.deterministic = JSON.stringify(a) === JSON.stringify(b);
  jc.stable = JSON.stringify(WF.windAt(10, 2, 5, 100, S)) === JSON.stringify(a);
  jc.varies = JSON.stringify(WF.windAt(0, 5, 0, 0, S).vec) !== JSON.stringify(WF.windAt(100, 5, 80, 500, S).vec);
  jc.seed_differs = JSON.stringify(WF.windAt(10, 2, 5, 100, S + 1).vec) !== JSON.stringify(a.vec);
  const tTop = WM.surfaceHeight(0, 0, S) * SF_;
  const lo = WF.windAt(0, tTop + 0.5, 0, 20, S), hi = WF.windAt(0, tTop + 14, 0, 20, S);
  jc.bl_rises = hi.strength >= lo.strength;
  jc.live_aloft = hi.strength > 0;
  let maxVy = -Infinity, thermAt = null;
  for (let t = 0; t <= 600; t += 30) for (let gx = -30; gx <= 30; gx += 6) for (let gz = -30; gz <= 30; gz += 6) {
    const yg = WM.surfaceHeight(gx / SF_, gz / SF_, S) * SF_ + 1.0;
    const vy = WF.windAt(gx, yg, gz, t, S).vec[1];
    if (vy > maxVy) { maxVy = vy; thermAt = { gx, gz, t }; }
  }
  jc.thermal_vy_positive = maxVy > 0.05;
  jc.thermal_nonneg = WF.thermalUpdraft(0, 0, 120, S, 0.5) >= 0 && WF.thermalUpdraft(thermAt.gx, thermAt.gz, thermAt.t, S, 1.0) > 0;
  const KE = 1.0;
  const grad = (x, z) => {
    const hpx = WM.surfaceHeight((x + KE) / SF_, z / SF_, S) * SF_, hmx = WM.surfaceHeight((x - KE) / SF_, z / SF_, S) * SF_;
    const hpz = WM.surfaceHeight(x / SF_, (z + KE) / SF_, S) * SF_, hmz = WM.surfaceHeight(x / SF_, (z - KE) / SF_, S) * SF_;
    return [(hpx - hmx) / (2 * KE), (hpz - hmz) / (2 * KE)];
  };
  let down = false;
  for (let t = 250; t <= 600 && !down; t += 30) for (let gx = -30; gx <= 30 && !down; gx += 5) for (let gz = -30; gz <= 30 && !down; gz += 5) {
    const [dx, dz] = grad(gx, gz), slope = Math.hypot(dx, dz);
    if (slope < 0.05) continue;
    const [kx, , kz] = WF.katabaticDrain(gx, gz, t, S, 0.5), mag = Math.hypot(kx, kz);
    if (mag < 1e-4) continue;
    if ((kx * -dx + kz * -dz) / slope > 0) down = true;
  }
  jc.katabatic_downslope = down;
  let vort = null, vt = 120;
  for (; vt <= 600 && !vort; vt += 18) vort = WF.activeVorticles(vt, S, 0, 0, 84).find((v) => v.kind === 'vortex');
  vt -= 18;
  const px = vort ? vort.cx + 3 : 8, pz = vort ? vort.cz : 5;
  const vfa = WF.vorticleField(px, pz, vt, S);
  jc.vorticle_deterministic = !!vort && JSON.stringify(vfa) === JSON.stringify(WF.vorticleField(px, pz, vt, S)) && (vfa[0] !== 0 || vfa[1] !== 0 || vfa[2] !== 0) && JSON.stringify(WF.vorticleField(px, pz, vt, S + 1)) !== JSON.stringify(vfa);
  let curl = 0;
  if (vort) {
    const d = 3, sx = (p, q) => WF.vorticleField(vort.cx + p, vort.cz + q, vt, S);
    const e = sx(d, 0), w = sx(-d, 0), n = sx(0, d), s = sx(0, -d);
    curl = Math.abs((e[2] - w[2]) / (2 * d) - (n[0] - s[0]) / (2 * d));
  }
  jc.vorticle_curl = !!vort && curl > 0.05;
  let fgain = 1;
  for (let t = 0; t <= 600; t += 2) fgain = Math.max(fgain, WF.frontAt(3, 3, t, S).gain);
  jc.front_modulation = fgain > 1.3;
  let hiN = 0, totN = 0;
  for (let t = 0; t <= 2000; t += 0.5) { totN++; if (WF.frontAt(7, 2, t, S).sbs >= 4) hiN++; }
  jc.front_budget_sbs4_low = hiN / totN < 0.20;
  jc.glsl_mirror = typeof WF.WIND_GLSL === 'string' && /windSample/.test(WF.WIND_GLSL) && /WindS/.test(WF.WIND_GLSL) && /(curl|fbm)/.test(WF.WIND_GLSL);
  const src = readFileSync(join(tree.dir, 'src', 'windfield.js'), 'utf8');
  jc.no_platform_rng = !/Math\.random/.test(src);
}

const head = execFileSync('git', ['-C', stalagDir, 'rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim();
writeFileSync(join(outDir, 'oracle.json'), JSON.stringify({
  generated_epoch: Math.floor(Date.now() / 1000),
  stalag_head: head,
  oracle_subst: SUBST_MODE,
  plan_hash: planHash,
  placement: {
    forms, total, lids: lids.length, ported_checks: pcheck, thinned_counts: thinnedCounts,
    chunks: {
      count: chunkList.length, hash: chunkHash.digest('hex'), total,
      counts: Object.fromEntries(chunkList.map((c) => [c.cx + ',' + c.cz, c.forms.reduce((n, l) => n + l.length, 0)])),
      per_form: Object.fromEntries(chunkList.map((c) => [c.cx + ',' + c.cz, c.forms.map((l) => l.length)])),
    },
  },
  wind: { samples: samples.length, exercised: ex, js_checks: jc, parts: Object.fromEntries(Object.entries(parts).map(([k, v]) => [k, v.length / samples.length])) },
}));
console.log(`js_flora_oracle: ${total} instances, ${lids.length} lids, ${samples.length} wind samples, plan ${planHash} -> ${outDir}`);
