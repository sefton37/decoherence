#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #545: bake the meadow's sprites and rock meshes from the frozen Stalag prototype's own
// generators (tag prototype-final: skins/foliage.js, and index.html rockGeometry / s2l for the rock
// colours). Reads (never writes) $STALAG_DIR (default ~/dev/stalag), runs them under the substituted
// math of tools/baseline/proto_subst.mjs (the same primitives the oracle uses, so a different JS
// engine cannot flip a pixel), and writes into the output directory:
//
//   one RGBA PNG per billboard form (six), straight from genBillboardSprite
//   .gdignore   empty marker: the directory is read raw (Image.load_from_file), never imported
//   rocks.json  {rocks: [{id, positions, normals, colors}]} -- four rock meshes, local metres,
//               linear colours, triangle soup (ROCK_M applied; the embed is game policy)
//
// The committed assets must equal a fresh bake (tests: DOD-14 of Spec #545).
//
// Usage: tools/bake_flora.mjs [outDir]    (default: game/world/assets/flora next to this repo)

import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync } from 'node:zlib';
import { installExpPow, installMath } from './baseline/proto_subst.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(process.argv[2] || join(here, '..', 'game', 'world', 'assets', 'flora'));
const stalagDir = process['env'].STALAG_DIR || join(homedir(), 'dev', 'stalag');

installMath('lowbias32');
installExpPow();
console.log('bake_flora: math=lowbias32 (hypot, log2, sin, cos, atan2, exp, pow substituted)');

const FOL = await import(pathToFileURL(join(stalagDir, 'skins/foliage.js')).href);
const TO = await import(pathToFileURL(join(stalagDir, 'src/to-cell.js')).href);
const { FOLIAGE_OPTIONS, genBillboardSprite, genCellPlant, FOLIAGE_PALETTE } = FOL;
const { VERTICES, SQUARE_FACES, HEX_FACES } = TO;

// ---- minimal PNG writer (RGBA8), as in tools/bake_skin.mjs ---------------------------------
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

// ---- rock colours: index.html s2l, hexRgb01, rockRampIdx, rockGeometry ------------------------
const s2l = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const hexRgb01 = (h) => { h = h.replace('#', ''); return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255]; };
const STONE_HEX = ['#2b3133', '#3c4446', '#525b5c', '#6b7476', '#8a9496'];
const ROCK_M = 0.80, ROCK_TO = 0.16;
const rockRampIdx = (ny, val) => { let i = ny > 0.45 ? 4 : ny < -0.45 ? 1 : 3; i += val; return Math.max(0, Math.min(4, i)); };
function rockMesh(option) {
  const plant = genCellPlant(option, option.seed);
  const stone = STONE_HEX.map(hexRgb01), green = FOLIAGE_PALETTE.ramp.map(hexRgb01);
  const sigB = hexRgb01(FOLIAGE_PALETTE.signalBright);
  const pos = [], nrm = [], col = [];
  for (const cell of plant.cells) {
    const [cxp, cyp, czp] = cell.pos, s = cell.scale;
    for (const face of [...SQUARE_FACES, ...HEX_FACES]) {
      const c = [0, 0, 0];
      for (const idx of face) { const v = VERTICES[idx]; c[0] += v[0]; c[1] += v[1]; c[2] += v[2]; }
      const l = Math.hypot(c[0], c[1], c[2]) || 1, n = [c[0] / l, c[1] / l, c[2] / l], top = n[1] > 0.45;
      const base = (cell.glow && top) ? sigB : (cell.lichen && top) ? green[3] : stone[rockRampIdx(n[1], cell.val)];
      const f = 1 + cell.hue * 0.006;
      const cr = s2l(Math.min(1, base[0] * f)), cg = s2l(Math.min(1, base[1] * f)), cb = s2l(Math.min(1, base[2] * (2 - f)));
      for (let k = 1; k < face.length - 1; k++) for (const vi of [face[0], face[k], face[k + 1]]) {
        const v = VERTICES[vi];
        pos.push(Math.fround((cxp + v[0] * s * ROCK_TO) * ROCK_M), Math.fround((cyp + v[1] * s * ROCK_TO) * ROCK_M), Math.fround((czp + v[2] * s * ROCK_TO) * ROCK_M));
        nrm.push(Math.fround(n[0]), Math.fround(n[1]), Math.fround(n[2]));
        col.push(Math.fround(cr), Math.fround(cg), Math.fround(cb));
      }
    }
  }
  return { id: option.id, positions: pos, normals: nrm, colors: col };
}

mkdirSync(outDir, { recursive: true });
const SELECTED = ['tuft-billboard-baseline', 'tuft-billboard-bladed', 'cover-billboard-creep', 'fern-billboard-frond', 'fern-billboard-mirror', 'shrub-billboard-lump'];
const ROCKS = ['rock-pebbles', 'rock-cobble', 'rock-boulder', 'rock-outcrop'];
const byId = new Map(FOLIAGE_OPTIONS.map((o) => [o.id, o]));
const written = [];
for (const id of SELECTED) {
  const opt = byId.get(id);
  const sp = genBillboardSprite(opt, opt.seed);
  writeFileSync(join(outDir, `${id}.png`), png(sp.width, sp.height, sp.rgba));
  written.push(`${id}.png(${sp.width}x${sp.height})`);
}
const rocks = ROCKS.map((id) => rockMesh(byId.get(id)));
writeFileSync(join(outDir, 'rocks.json'), JSON.stringify({ rocks }));
written.push(`rocks.json(${rocks.map((r) => r.positions.length / 9).join('/')} tris)`);
// The assets are read raw at runtime (Image.load_from_file); the marker keeps Godot from importing them,
// so the directory stays byte-equal to a fresh bake.
writeFileSync(join(outDir, '.gdignore'), '');
written.push('.gdignore');
console.log(`bake_flora: wrote ${written.join(', ')} -> ${outDir}`);
