#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549: bake the forest and the understory from the frozen Stalag prototype's own generators
// (tag prototype-final: skins/trees.js, skins/canopy.js, skins/leaf-sprite.js, skins/shrubs.js,
// skins/wildflowers.js, skins/foliage.js, src/to-cell.js, and the mesh builders of index.html:
// treeCellMesh, leafCutoutCrown, trunkGeometry, TREE_CANOPY_PARAMS). Reads (never writes)
// $STALAG_DIR (default ~/dev/stalag), runs them under the substituted math of
// tools/baseline/proto_subst.mjs (the same primitives the oracle uses), and writes into the output
// directory two subdirectories:
//
//   trees/       manifest.json, trees.bin, leaf_cool.png, leaf_warm.png, .gdignore
//   understory/  manifest.json, understory.bin, one PNG per sprite (2 T1 shrubs, 14 flower
//                species-tiers), one PNG per voxel-shrub cutout texture, .gdignore
//
// Mesh arrays are little-endian float32, vertex after vertex (the layouts are in the manifests):
//   trunk   9 floats  position(3) normal(3) colour(3, linear)
//   crown  16 floats  position(3) normal(3) colour(3) uv(2) heightFrac(1) exposure(1) cluster xz(2) cellY(1)
//   shadow  3 floats  position(3): the crown's six square faces per leaf cell, a shadow-only proxy
//
// ONE DECLARED DEVIATION from the prototype: the protruding-tuft hash. leafCutoutCrown picks which
// cells grow a tuft with an inline spatial hash whose primes are unattributed in the frozen source.
// Spec #517 A2 rewrites unknown-origin hash one-liners, so the tuft hash here is a composition of
// lowbias32 (the same one the flora shader uses for its lattice hash) with the prototype's 0.42
// threshold and the same inputs. Tuft density is the prototype's; which cells get one differs.
//
// The committed assets must equal a fresh bake (DOD-11 of Spec #549).
//
// Usage: tools/bake_trees.mjs [outDir]    (default: game/world/assets next to this repo)

import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync } from 'node:zlib';
import { installExpPow, installMath, lowbias32 } from './baseline/proto_subst.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(process.argv[2] || join(here, '..', 'game', 'world', 'assets'));
const stalagDir = process['env'].STALAG_DIR || join(homedir(), 'dev', 'stalag');
const WORLD_SEED = 7; // the engine world seed (the prototype ran 42): the shrub generators derive from it

installMath('lowbias32');
installExpPow();
console.log('bake_trees: math=lowbias32 (hypot, log2, sin, cos, atan2, exp, pow substituted)');

const imp = (rel) => import(pathToFileURL(join(stalagDir, rel)).href);
const TR = await imp('skins/trees.js');
const CA = await imp('skins/canopy.js');
const LS = await imp('skins/leaf-sprite.js');
const TO = await imp('src/to-cell.js');
const SHR = await imp('skins/shrubs.js');
const WF = await imp('skins/wildflowers.js');
const FOL = await imp('skins/foliage.js');
const { TREE_OPTIONS, genTrunkCells, TREE_PALETTE } = TR;
const { genCanopyCells, genTrunkCells2, CANOPY_GREENS, visibleCellFaces } = CA;
const { genLeafSprite } = LS;
const { VERTICES, SQUARE_FACES, HEX_FACES } = TO;
const { PLACED_SHRUBS, rotateHueRGBA, CUTOUT_TEX_OPTS } = SHR;
const genShrubGallery = SHR.default;
const { WILDFLOWER_OPTIONS, genWildflowerSprite } = WF;
const { genBillboardSprite } = FOL;

// ---- minimal PNG writer (RGBA8), as in tools/bake_flora.mjs ---------------------------------
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
  ihdr[8] = 8;
  ihdr[9] = 6;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ]);
}
const sha16 = (rgba) => createHash('sha256').update(Buffer.from(rgba.buffer, rgba.byteOffset, rgba.byteLength)).digest('hex').slice(0, 16);

// ---- colour helpers: index.html s2l, hexRgb01, rockRampIdx, barkIdx, hsv-free ------------------
const s2l = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const hexRgb01 = (h) => { h = h.replace('#', ''); return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255]; };
const rockRampIdx = (ny, val) => { let i = ny > 0.45 ? 4 : ny < -0.45 ? 1 : 3; i += val; return Math.max(0, Math.min(4, i)); };
const barkIdx = rockRampIdx; // index.html barkIdx has the identical body
const BARK = TREE_PALETTE.bark.map(hexRgb01), BARK_PALE = TREE_PALETTE.barkPale.map(hexRgb01);
const TREE_STONE = TREE_PALETTE.stone.map(hexRgb01), CUT = hexRgb01(TREE_PALETTE.bark[4]);
const TREE_FACES = [...SQUARE_FACES, ...HEX_FACES]; // index-aligned with NEIGHBOR_OFFSETS (square 0-5, hex 6-13)

// ---- index.html TREE_CANOPY_PARAMS (hueDeg is game policy: game/world/tree_assets.gd) -----------
const TREE_CANOPY_PARAMS = {
  'frost-sapling':    { shape: 'cone',  thickMul: 0.50, leafR: 0.11, fullness: 0.80, valBand: 1.02 },
  'scrub-birch':      { shape: 'clump', thickMul: 0.40, leafR: 0.10, fullness: 0.75, valBand: 1.00 },
  'young-spire':      { shape: 'cone',  thickMul: 0.90, leafR: 0.17, fullness: 0.88, valBand: 0.95 },
  'boreal-fir':       { shape: 'cone',  thickMul: 1.00, leafR: 0.22, fullness: 0.92, valBand: 0.90 },
  'broadleaf-lump':   { shape: 'blob',  thickMul: 1.20, leafR: 0.24, fullness: 0.95, valBand: 0.85 },
  'tall-pine':        { shape: 'cone',  thickMul: 1.10, leafR: 0.22, fullness: 0.87, valBand: 0.88 },
  'northwatch-larch': { shape: 'cone',  thickMul: 0.90, leafR: 0.19, fullness: 0.72, valBand: 1.10 },
  'twin-trunk':       { shape: 'clump', thickMul: 1.00, leafR: 0.21, fullness: 0.90, valBand: 0.93 },
  'elder-pine':       { shape: 'cone',  thickMul: 1.40, leafR: 0.28, fullness: 1.00, valBand: 0.75 },
  'sensor-pine':      { shape: 'cone',  thickMul: 1.00, leafR: 0.22, fullness: 0.90, valBand: 0.90 },
};

// ---- index.html treeCellMesh: visible faces of a cell list, ramp colour, flat normal -------------
function treeCellMesh(cells, ramp) {
  const out = [];
  const vis = visibleCellFaces(cells);
  for (let ci = 0; ci < cells.length; ci++) {
    const cell = cells[ci];
    const [cxp, cyp, czp] = cell.pos, s = cell.scale * 0.5;
    for (const fi of vis[ci]) {
      const face = TREE_FACES[fi];
      const cc = [0, 0, 0];
      for (const idx of face) { const v = VERTICES[idx]; cc[0] += v[0]; cc[1] += v[1]; cc[2] += v[2]; }
      const l = Math.hypot(cc[0], cc[1], cc[2]) || 1, n = [cc[0] / l, cc[1] / l, cc[2] / l];
      const base = n[1] > 0.45 ? ramp[4] : ramp[rockRampIdx(n[1], cell.val)];
      const f = 1 + cell.hue * 0.006;
      const cr = s2l(Math.min(1, base[0] * f)), cg = s2l(Math.min(1, base[1] * f)), cb = s2l(Math.min(1, base[2] * (2 - f)));
      for (let k = 1; k < face.length - 1; k++) for (const vi of [face[0], face[k], face[k + 1]]) {
        const v = VERTICES[vi];
        out.push(cxp + v[0] * s, cyp + v[1] * s, czp + v[2] * s, n[0], n[1], n[2], cr, cg, cb);
      }
    }
  }
  return out;
}

// ---- index.html trunkGeometry: the dead forms' cell column (every face, bark / pale / stone ramp)
function trunkGeometry(option, nominalH) {
  const trunk = genTrunkCells(option, option.seed, nominalH);
  const ramp = option.form === 'snag' ? TREE_STONE : option.pale ? BARK_PALE : BARK;
  const out = [];
  for (const cell of trunk.cells) {
    const [cxp, cyp, czp] = cell.pos, s = cell.scale * 0.5;
    for (const face of [...SQUARE_FACES, ...HEX_FACES]) {
      const c = [0, 0, 0];
      for (const idx of face) { const v = VERTICES[idx]; c[0] += v[0]; c[1] += v[1]; c[2] += v[2]; }
      const l = Math.hypot(c[0], c[1], c[2]) || 1, n = [c[0] / l, c[1] / l, c[2] / l];
      const base = cell.cut ? CUT : ramp[barkIdx(n[1], cell.val)];
      const f = 1 + cell.hue * 0.006;
      const cr = s2l(Math.min(1, base[0] * f)), cg = s2l(Math.min(1, base[1] * f)), cb = s2l(Math.min(1, base[2] * (2 - f)));
      for (let kk = 1; kk < face.length - 1; kk++) for (const vi of [face[0], face[kk], face[kk + 1]]) {
        const v = VERTICES[vi];
        out.push(cxp + v[0] * s, cyp + v[1] * s, czp + v[2] * s, n[0], n[1], n[2], cr, cg, cb);
      }
    }
  }
  return { verts: out, cells: trunk.cells.length };
}

// ---- index.html leafCutoutCrown: every face of every leaf cell (uncut, so leaves stack through the
// alpha gaps) plus protruding tufts. The tuft hash is the declared deviation (header).
const TOP_LEFT_LIGHT = (() => { const v = [-0.45, 0.80, 0.25]; const l = Math.hypot(v[0], v[1], v[2]); return [v[0] / l, v[1] / l, v[2] / l]; })();
const faceN = (face) => { const c = [0, 0, 0]; for (const i of face) { const v = VERTICES[i]; c[0] += v[0]; c[1] += v[1]; c[2] += v[2]; } const l = Math.hypot(c[0], c[1], c[2]) || 1; return [c[0] / l, c[1] / l, c[2] / l]; };
const tuftHash = (a, b, c) => lowbias32(lowbias32(lowbias32(a) ^ b) ^ c) / 4294967296;
function leafCutoutCrown(cells, leafR, seed, valBand = 1) {
  const out = []; // 16 floats per vertex: pos(3) nrm(3) col(3) uv(2) hf exp clu(2) cly
  let minY = Infinity, maxY = -Infinity;
  for (const cell of cells) { const y = cell.pos[1]; if (y < minY) minY = y; if (y > maxY) maxY = y; }
  const ySpan = (maxY - minY) || 1;
  const vis = visibleCellFaces(cells); // exposure metric only; never used to cull emitted faces
  const cellHF = new Array(cells.length), cellExp = new Array(cells.length);
  for (let ci = 0; ci < cells.length; ci++) {
    const cell = cells[ci];
    const [cxp, cyp, czp] = cell.pos, s = cell.scale * 0.5;
    const heightFrac = (cyp - minY) / ySpan;
    const exposure = vis[ci].length / 14;
    cellHF[ci] = heightFrac; cellExp[ci] = exposure;
    for (const face of TREE_FACES) {
      const n = faceN(face), fv = face.map((i) => VERTICES[i]);
      const lightTerm = Math.max(0, n[0] * TOP_LEFT_LIGHT[0] + n[1] * TOP_LEFT_LIGHT[1] + n[2] * TOP_LEFT_LIGHT[2]);
      let f = 0.55 + 0.30 * heightFrac + 0.20 * lightTerm;
      f = Math.max(0.3, Math.min(1.15, f));
      f *= valBand;
      f *= (0.85 + 0.15 * exposure);
      f *= 1 + cell.hue * 0.01;
      f = Math.max(0.25, Math.min(1.3, f));
      let u = [fv[1][0] - fv[0][0], fv[1][1] - fv[0][1], fv[1][2] - fv[0][2]];
      const ul = Math.hypot(u[0], u[1], u[2]) || 1; u = [u[0] / ul, u[1] / ul, u[2] / ul];
      const w = [n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]];
      const cen = [0, 0, 0]; for (const v of fv) { cen[0] += v[0]; cen[1] += v[1]; cen[2] += v[2]; } cen[0] /= fv.length; cen[1] /= fv.length; cen[2] /= fv.length;
      const puv = fv.map((v) => { const d = [v[0] - cen[0], v[1] - cen[1], v[2] - cen[2]]; return [d[0] * u[0] + d[1] * u[1] + d[2] * u[2], d[0] * w[0] + d[1] * w[1] + d[2] * w[2]]; });
      let mnx = 1e9, mny = 1e9, mxx = -1e9, mxy = -1e9; for (const p of puv) { mnx = Math.min(mnx, p[0]); mny = Math.min(mny, p[1]); mxx = Math.max(mxx, p[0]); mxy = Math.max(mxy, p[1]); }
      const sx = (mxx - mnx) || 1, sy = (mxy - mny) || 1;
      for (let k = 1; k < face.length - 1; k++) for (const vi of [0, k, k + 1]) {
        const v = VERTICES[face[vi]];
        out.push(cxp + v[0] * s, cyp + v[1] * s, czp + v[2] * s, n[0], n[1], n[2], f, f, f,
          (puv[vi][0] - mnx) / sx, (puv[vi][1] - mny) / sy, heightFrac, exposure, cxp, czp, cyp);
      }
    }
  }
  const UVq = [[0, 0], [1, 0], [1, 1], [0, 1]];
  const quad = (cx, cy, cz, ax, ay, az, bx, by, bz, hfV, expV, cluX, cluZ, cluY) => {
    const P = [[-ax - bx, -ay - by, -az - bz], [ax - bx, ay - by, az - bz], [ax + bx, ay + by, az + bz], [-ax + bx, -ay + by, -az + bz]];
    let nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx; const nl = Math.hypot(nx, ny, nz) || 1; nx /= nl; ny /= nl; nz /= nl;
    for (const t of [[0, 1, 2], [0, 2, 3]]) for (const k of t) {
      out.push(cx + P[k][0], cy + P[k][1], cz + P[k][2], nx, ny, nz, 1, 1, 1, UVq[k][0], UVq[k][1], hfV, expV, cluX, cluZ, cluY);
    }
  };
  let tufts = 0;
  for (let ci = 0; ci < cells.length; ci++) {
    const cell = cells[ci];
    const [cxp, cyp, czp] = cell.pos;
    if (tuftHash(Math.round(cxp / leafR), Math.round(cyp / leafR), Math.round(czp / leafR)) > 0.42) continue;
    tufts++; const sz = leafR * 1.6;
    quad(cxp, cyp, czp, sz, 0, 0, 0, sz, tuftHash(cxp | 0, 7 + seed, czp | 0) * 0.4 * sz, cellHF[ci], cellExp[ci], cxp, czp, cyp);
    quad(cxp, cyp, czp, 0, 0, sz, 0, sz, (tuftHash(cxp | 0, 9 + seed, czp | 0) - 0.5) * 0.6 * sz, cellHF[ci], cellExp[ci], cxp, czp, cyp);
  }
  return { verts: out, tufts, cells: cells.length };
}

// ---- the shadow proxy: six square faces per leaf cell, position only --------------------------
function shadowProxy(cells) {
  const out = [];
  for (const cell of cells) {
    const [cxp, cyp, czp] = cell.pos, s = cell.scale * 0.5;
    for (const face of SQUARE_FACES) {
      for (let k = 1; k < face.length - 1; k++) for (const vi of [face[0], face[k], face[k + 1]]) {
        const v = VERTICES[vi];
        out.push(cxp + v[0] * s, cyp + v[1] * s, czp + v[2] * s);
      }
    }
  }
  return out;
}

// ---- binary assembly -----------------------------------------------------------------------
const parts = [];
let offset = 0;
function addArray(floats) {
  const f32 = new Float32Array(floats);
  const buf = Buffer.from(f32.buffer, f32.byteOffset, f32.byteLength);
  const at = offset;
  parts.push(buf);
  offset += buf.length;
  return { offset: at, bytes: buf.length, buf };
}
const bakeDir = (sub) => { const d = join(outDir, sub); mkdirSync(d, { recursive: true }); return d; };

// ================================================================== trees
const treesDir = bakeDir('trees');
const leafCool = genLeafSprite(20260630, { size: 48, leaves: 22, colors: CANOPY_GREENS });
const leafWarm = genLeafSprite(20260702, { size: 48, leaves: 22 });
writeFileSync(join(treesDir, 'leaf_cool.png'), png(leafCool.width, leafCool.height, leafCool.rgba));
writeFileSync(join(treesDir, 'leaf_warm.png'), png(leafWarm.width, leafWarm.height, leafWarm.rgba));

const treeForms = [];
const tot = { trunk_tris: 0, crown_tris: 0, tufts: 0, leaf_cells: 0, shadow_tris: 0 };
for (const option of TREE_OPTIONS) {
  const nominalH = (option.heightRange[0] + option.heightRange[1]) / 2;
  const P = TREE_CANOPY_PARAMS[option.id];
  const form = { id: option.id, nominal_height_m: nominalH, trunk: null, crown: null, shadow: null };
  const bufs = [];
  if (P) {
    const o = { ...option, canopyShape: P.shape };
    const tr = genTrunkCells2(o, option.seed, nominalH, P.thickMul);
    const trunkVerts = treeCellMesh(tr.cells, BARK);
    const leaf = genCanopyCells(o, option.seed, { leafR: P.leafR, fullness: P.fullness, height: nominalH, trunkTopY: tr.height, branchPoints: tr.branchPoints });
    const crown = leafCutoutCrown(leaf, P.leafR, option.seed, P.valBand);
    const proxy = shadowProxy(leaf);
    const a = addArray(trunkVerts), b = addArray(crown.verts), c = addArray(proxy);
    form.trunk = { offset: a.offset, bytes: a.bytes, floats_per_vertex: 9, verts: trunkVerts.length / 9, cells: tr.cells.length, tris: trunkVerts.length / 27 };
    form.crown = { offset: b.offset, bytes: b.bytes, floats_per_vertex: 16, verts: crown.verts.length / 16, cells: leaf.length, tufts: crown.tufts, tris: crown.verts.length / 48, leaf_tex: P.shape === 'cone' ? 'cool' : 'warm' };
    form.shadow = { offset: c.offset, bytes: c.bytes, floats_per_vertex: 3, verts: proxy.length / 3, tris: proxy.length / 9 };
    bufs.push(a.buf, b.buf, c.buf);
    tot.crown_tris += form.crown.tris; tot.tufts += crown.tufts; tot.leaf_cells += leaf.length; tot.shadow_tris += form.shadow.tris;
  } else {
    const t = trunkGeometry(option, nominalH);
    const a = addArray(t.verts);
    form.trunk = { offset: a.offset, bytes: a.bytes, floats_per_vertex: 9, verts: t.verts.length / 9, cells: t.cells, tris: t.verts.length / 27 };
    bufs.push(a.buf);
  }
  tot.trunk_tris += form.trunk.tris;
  form.array_hash = createHash('sha256').update(Buffer.concat(bufs)).digest('hex');
  treeForms.push(form);
}
writeFileSync(join(treesDir, 'trees.bin'), Buffer.concat(parts));
const treeBytes = offset;
writeFileSync(join(treesDir, 'manifest.json'), JSON.stringify({
  version: 1, source: 'prototype-final', tuft_hash: 'lowbias32', world_seed: WORLD_SEED,
  layouts: { trunk: 'position3 normal3 colour3', crown: 'position3 normal3 colour3 uv2 heightFrac exposure clusterXZ2 cellY', shadow: 'position3' },
  leaf_tex: [
    { id: 'leaf_cool', w: leafCool.width, h: leafCool.height, rgba_sha16: sha16(leafCool.rgba) },
    { id: 'leaf_warm', w: leafWarm.width, h: leafWarm.height, rgba_sha16: sha16(leafWarm.rgba) },
  ],
  forms: treeForms, totals: { ...tot, bytes: treeBytes },
}));
writeFileSync(join(treesDir, '.gdignore'), '');
console.log(`bake_trees: trees ${treeForms.length} forms, ${treeBytes} bytes, trunk ${tot.trunk_tris} crown ${tot.crown_tris} tufts ${tot.tufts} leaf cells ${tot.leaf_cells} shadow ${tot.shadow_tris}`);

// ================================================================== understory
parts.length = 0;
offset = 0;
const uDir = bakeDir('understory');
const gallery = genShrubGallery(WORLD_SEED).filter((o) => PLACED_SHRUBS.some((p) => p.id === o.id));
const galleryById = new Map(gallery.map((o) => [o.id, o]));
const sprites = [];
const putSprite = (id, file, sp) => {
  writeFileSync(join(uDir, file), png(sp.width, sp.height, sp.rgba));
  sprites.push({ id, file, w: sp.width, h: sp.height, rgba_sha16: sha16(sp.rgba) });
};
const shrubForms = [];
const shrubTex = [];
const ut = { leaf_cells: 0, tufts: 0, voxel_tris: 0 };
for (const placed of PLACED_SHRUBS) {
  const option = galleryById.get(placed.id);
  if (option.form === 'sprite') {
    const sp = genBillboardSprite({ id: option.billboardId, form: 'shrub' }, option.seed);
    putSprite(option.id, `${option.id}.png`, sp);
    shrubForms.push({ id: option.id, kind: 'sprite', height_m: option.heightM, sprite: option.id });
  } else {
    const cut = genLeafSprite(option.seed, CUTOUT_TEX_OPTS);
    const rgba = option.colorMechanism === 'huejitter' ? rotateHueRGBA(cut.rgba, option.hueShiftDeg || 0, 1) : cut.rgba;
    writeFileSync(join(uDir, `${option.id}.png`), png(cut.width, cut.height, rgba));
    shrubTex.push({ id: option.id, file: `${option.id}.png`, w: cut.width, h: cut.height, rgba_sha16: sha16(rgba) });
    const crown = leafCutoutCrown(option.cells, option.leafR, option.seed);
    const a = addArray(crown.verts);
    const tris = crown.verts.length / 48;
    shrubForms.push({
      id: option.id, kind: 'voxel', cutout: option.id, cells: option.cells.length, tufts: crown.tufts, tris,
      crown: { offset: a.offset, bytes: a.bytes, floats_per_vertex: 16, verts: crown.verts.length / 16 },
      array_hash: createHash('sha256').update(a.buf).digest('hex'),
    });
    ut.leaf_cells += option.cells.length; ut.tufts += crown.tufts; ut.voxel_tris += tris;
  }
}
const FLOWER_BY_ID = new Map(WILDFLOWER_OPTIONS.map((o) => [o.id, o]));
const FLOWER_IDS = ['flower-spike-lupine', 'flower-dot-forgetmenot', 'flower-cushion-campion', 'flower-sensor-bloom', 'flower-spike-fireweed', 'flower-cup-poppy', 'flower-ray-arnica'];
for (const id of FLOWER_IDS) {
  const opt = FLOWER_BY_ID.get(id);
  for (const tier of ['muted', 'vivid']) putSprite(`${id}/${tier}`, `${id}-${tier}.png`, genWildflowerSprite(opt, opt.seed, tier));
}
writeFileSync(join(uDir, 'understory.bin'), Buffer.concat(parts));
const uBytes = offset;
writeFileSync(join(uDir, 'manifest.json'), JSON.stringify({
  version: 1, source: 'prototype-final', tuft_hash: 'lowbias32', world_seed: WORLD_SEED,
  layouts: { crown: 'position3 normal3 colour3 uv2 heightFrac exposure clusterXZ2 cellY' },
  shrubs: shrubForms, shrub_tex: shrubTex, sprites, totals: { ...ut, bytes: uBytes },
}));
writeFileSync(join(uDir, '.gdignore'), '');
console.log(`bake_trees: understory ${shrubForms.length} shrubs, ${sprites.length} sprites, ${shrubTex.length} cutouts, ${uBytes} bytes, cells ${ut.leaf_cells} tufts ${ut.tufts} tris ${ut.voxel_tris}`);
console.log(`bake_trees: combined mesh bytes ${treeBytes + uBytes}`);
