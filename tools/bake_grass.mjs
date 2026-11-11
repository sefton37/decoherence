#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #551 phase 1 -- bake the meadow's anti-repetition art: 8 grass tile variants and
// 8 decals, as two 128 x 16 strips of 16 x 16 tiles.
//
// Source and licence: the frozen Stalag prototype (tag prototype-final, AGPL-3.0, same
// author) supplies the tile generator, skins/texgen.js, read from $STALAG_DIR (default
// ~/dev/stalag) and never written. The variants re-seed its boreal-baseline style (the
// style that drew the shipped grass_top.png), so variant 0 is byte-identical to the shipped
// tile. This file is a port of the design lab's grass tile generator (same author, same
// licence) with the corner-mask output dropped. The decals are drawn here in the same
// style and palette as the design lab's; the lab drew them with the prototype generator's
// own seeded random source, whose name is on this repo's banned list, so the decal scatter
// is drawn from a counter-based lowbias32 stream instead (tools/baseline/proto_subst.mjs,
// registered in engine/PROVENANCE.md). Positions inside each decal therefore differ from the lab's.
//
// Writes exactly two files into <outDir>: grass_variants.png, grass_decals.png.
// Usage: tools/bake_grass.mjs [outDir]    (default: game/world/assets next to this repo)

import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync } from 'node:zlib';
import { lowbias32 } from './baseline/proto_subst.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(process.argv[2] || join(here, '..', 'game', 'world', 'assets'));
const stalagDir = process['env'].STALAG_DIR || join(homedir(), 'dev', 'stalag');
const { STYLES, genTextures } = await import(pathToFileURL(join(stalagDir, 'skins/texgen.js')).href);

// ---- minimal PNG writer (RGBA8), the same one tools/bake_skin.mjs uses --------------------
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

const R = 16; // texels per tile edge
const N = 8; // tiles per strip
const strip = () => ({ w: N * R, h: R, rgba: new Uint8Array(N * R * R * 4) });
function blit(dst, i, tile) {
  for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
    const s = (y * R + x) * 4, d = (y * dst.w + i * R + x) * 4;
    for (let k = 0; k < 4; k++) dst.rgba[d + k] = tile[s + k];
  }
}

// ---- 1. variants: the same style, new seeds; the cyan glint kept but rare -----------------
const base = STYLES.find((s) => s.id === 'boreal-baseline');
const SEEDS = [101, 1103, 2207, 3301, 4409, 5503, 6607, 7703]; // index 0 is the style's own seed
const SIGNAL = [2, 0, 1, 0, 0, 1, 0, 0]; // glints per variant: half a glint per square on average
const variants = strip();
SEEDS.forEach((seed, i) => {
  const st = JSON.parse(JSON.stringify(base));
  st.seed = seed;
  if (i > 0) {
    st.grass.signal.count = SIGNAL[i];
    if (i % 3 === 1) st.grass.tuft.clusters = 4;
    if (i % 3 === 2) st.grass.tuft.clusters = 6;
    if (i === 4) st.grass.fieldDark = 0.28;
    if (i === 6) st.grass.fieldDark = 0.16;
  }
  blit(variants, i, genTextures(st).grassTop.rgba);
});

// ---- 2. decals (alpha 0 or 255 only) -------------------------------------------------------
const C = {
  clover: [62, 112, 70], cloverHi: [104, 150, 98], cloverDk: [29, 51, 39],
  yellow: [214, 190, 92], yellowDk: [150, 120, 52], white: [216, 222, 210], whiteDk: [140, 150, 140],
  violet: [146, 118, 170], violetDk: [92, 70, 112],
  dirt: [79, 60, 40], dirtHi: [106, 82, 55], dirtDk: [58, 42, 28], pebble: [125, 112, 100], pebbleHi: [150, 140, 126],
  straw: [150, 142, 92], strawDk: [112, 106, 66],
};
// A counter-based random stream: draw n of stream `seed` is lowbias32(lowbias32(seed) ^ n), in [0, 1).
function stream(seed) {
  const s = lowbias32(seed);
  let n = 0;
  return () => lowbias32(s ^ n++) / 4294967296;
}
function decal(fn, seed) {
  const t = new Uint8Array(R * R * 4);
  const rnd = stream(seed);
  const put = (x, y, c) => {
    if (x < 0 || y < 0 || x >= R || y >= R) return;
    const i = (y * R + x) * 4;
    t[i] = c[0]; t[i + 1] = c[1]; t[i + 2] = c[2]; t[i + 3] = 255;
  };
  fn(put, rnd);
  return t;
}
const leaf3 = (put, x, y) => {
  put(x, y, C.clover); put(x + 1, y, C.cloverHi); put(x, y + 1, C.clover); put(x - 1, y + 1, C.cloverHi);
  put(x + 1, y + 1, C.clover); put(x, y + 2, C.cloverDk);
};
const speck = (put, r, span, c, dk) => {
  const x = 1 + (r() * span | 0), y = 1 + (r() * 13 | 0);
  put(x, y + 1, dk); put(x, y, c); put(x + 1, y, c);
};
const DECALS = [
  (put, r) => { for (let k = 0; k < 8; k++) leaf3(put, 2 + (r() * 11 | 0), 2 + (r() * 11 | 0)); }, // clover
  (put, r) => { for (let k = 0; k < 9; k++) speck(put, r, 13, C.yellow, C.yellowDk); }, // yellow flower specks
  (put, r) => { for (let k = 0; k < 10; k++) speck(put, r, 13, C.white, C.whiteDk); }, // white flower specks
  (put, r) => { for (let k = 0; k < 8; k++) speck(put, r, 12, C.violet, C.violetDk); }, // violet flower specks
  (put, r) => { // bare dirt with pebbles
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      const d = Math.hypot((x - 8) / 5.2, (y - 8) / 4.2) + (r() - 0.5) * 0.45;
      if (d < 1) put(x, y, d > 0.8 ? C.dirtDk : (r() < 0.2 ? C.dirtHi : C.dirt));
    }
    put(6, 7, C.pebble); put(7, 7, C.pebbleHi); put(10, 9, C.pebble);
  },
  (put, r) => { // bare dirt
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      const d = Math.hypot((x - 6) / 3, (y - 10) / 2.3) + (r() - 0.5) * 0.5;
      if (d < 1) put(x, y, d > 0.75 ? C.dirtDk : C.dirt);
    }
  },
  (put, r) => { // pebbles
    for (let k = 0; k < 4; k++) {
      const x = 2 + (r() * 11 | 0), y = 2 + (r() * 11 | 0);
      put(x, y, C.pebbleHi); put(x + 1, y, C.pebble); put(x + 1, y + 1, C.dirtDk);
    }
  },
  (put, r) => { // straw
    for (let k = 0; k < 6; k++) {
      const x = 2 + (r() * 11 | 0), y = 2 + (r() * 11 | 0);
      put(x, y, C.straw); put(x + 1, y + 1, C.strawDk);
    }
  },
];
const decals = strip();
DECALS.forEach((fn, i) => blit(decals, i, decal(fn, 900 + i * 37)));

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'grass_variants.png'), png(variants.w, variants.h, variants.rgba));
writeFileSync(join(outDir, 'grass_decals.png'), png(decals.w, decals.h, decals.rgba));
console.log(`bake_grass: math=lowbias32 wrote grass_variants.png, grass_decals.png -> ${outDir}`);
