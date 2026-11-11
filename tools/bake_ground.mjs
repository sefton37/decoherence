#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #551 phase 2 -- bake the ground-material art: an atlas of 9 materials by 8 tile variants and
// a matching atlas of per-material decals, each 128 x 144 (nine rows of 16 x 16 tiles, eight tiles
// per row). Rows: 0 grass, 1 dirt wall, 2 rock, 3 mossy rock, 4 gravel, 5 sand, 6 mud, 7 path, 8 podzol.
//
// Source and licence: the frozen Stalag prototype (tag prototype-final, AGPL-3.0, same author)
// supplies the tile generator, skins/texgen.js, read from $STALAG_DIR (default ~/dev/stalag) and
// never written. Row 0 is bake_grass.mjs's variant set and row 1 re-seeds the prototype's dirt-side
// generator (variant 0 is byte-identical to the shipped dirt_side.png). Rows 2 to 8 are drawn here
// with the rules texgen uses: 16 px, value-led five-step ramps, tileable value noise, stones and clods
// lit top-left with a bottom-right shadow, wrapped writes so every tile is seamless. This file is a
// port of the design lab's ground tile generator (same author, same licence) with the frost row and
// the enlargement sheets dropped. The lab drew with the prototype generator's own seeded random
// source and a murmur-style cell hash, both on this repo's banned list, so every random draw here is a
// counter-based lowbias32 stream (tools/baseline/proto_subst.mjs, registered in engine/PROVENANCE.md);
// the scatter inside rows 2 to 8 therefore differs from the lab's, in the same style and palette.
// Row 0 draws the grass variants exactly as bake_grass.mjs does, so it equals grass_variants.png.
//
// Writes exactly two files into <outDir>: atlas.png, decals.png.
// Usage: tools/bake_ground.mjs [outDir]    (default: game/world/assets/ground next to this repo)

import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync } from 'node:zlib';
import { lowbias32 } from './baseline/proto_subst.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(process.argv[2] || join(here, '..', 'game', 'world', 'assets', 'ground'));
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

const R = 16, NV = 8;
const MATS = ['grass', 'dirt', 'rock', 'mossrock', 'gravel', 'sand', 'mud', 'path', 'podzol'];
const NM = MATS.length;
const atlas = new Uint8Array(NV * R * NM * R * 4);
const datlas = new Uint8Array(NV * R * NM * R * 4);
function blitTile(dst, m, v, tile) {
  for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
    const s = (y * R + x) * 4, d = ((m * R + y) * NV * R + v * R + x) * 4;
    for (let k = 0; k < 4; k++) dst[d + k] = tile[s + k];
  }
}

// ---- random sources: counter-based lowbias32, no state beyond a counter -----------------------
// Draw n of stream `seed` is lowbias32(lowbias32(seed) ^ n), in [0, 1).
function stream(seed) {
  const s = lowbias32(seed);
  let n = 0;
  return () => lowbias32(s ^ n++) / 4294967296;
}
// A value in [0, 1) addressed by an integer point and a seed (replaces the lab's cell hash).
function hash2(x, y, seed) {
  return lowbias32(lowbias32(lowbias32(seed >>> 0) ^ (x >>> 0)) ^ (y >>> 0)) / 4294967296;
}
function tileNoise(cells, seed) {
  const g = new Float32Array(cells * cells), rnd = stream(seed);
  for (let i = 0; i < g.length; i++) g[i] = rnd();
  return (x, y) => {
    const fx = (x / R) * cells, fy = (y / R) * cells;
    const x0 = Math.floor(fx) % cells, y0 = Math.floor(fy) % cells, x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells;
    const tx = fx - Math.floor(fx), ty = fy - Math.floor(fy), sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
    const a = g[y0 * cells + x0] + (g[y0 * cells + x1] - g[y0 * cells + x0]) * sx;
    const b = g[y1 * cells + x0] + (g[y1 * cells + x1] - g[y1 * cells + x0]) * sx;
    return a + (b - a) * sy;
  };
}
const RGB = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
function canvas() {
  const t = new Uint8Array(R * R * 4);
  const put = (x, y, c, a = 255) => { const xi = ((x % R) + R) % R, yi = ((y % R) + R) % R, i = (yi * R + xi) * 4; t[i] = c[0]; t[i + 1] = c[1]; t[i + 2] = c[2]; t[i + 3] = a; };
  const get = (x, y) => { const xi = ((x % R) + R) % R, yi = ((y % R) + R) % R, i = (yi * R + xi) * 4; return [t[i], t[i + 1], t[i + 2]]; };
  return { t, put, get };
}
// field of ramp indices from noise: the texgen "calm field" (2-3 mid values, few extremes)
function field(c, ramp, seed, cells, cuts = [0.34, 0.62], lo = 1) {
  const n = tileNoise(cells, seed);
  for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
    const v = n(x, y);
    const idx = v > cuts[1] ? lo + 2 : v > cuts[0] ? lo + 1 : lo;
    c.put(x, y, RGB(ramp[idx]));
  }
}
// a stone/clod: lit top-left, shadow bottom-right (texgen's light rule)
function stone(c, x, y, w, h, body, hi, sh) {
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) c.put(x + i, y + j, body);
  c.put(x, y, hi); if (w > 2) c.put(x + 1, y, hi);
  for (let i = 1; i <= w; i++) c.put(x + i, y + h, sh);
  for (let j = 1; j < h; j++) c.put(x + w, y + j, sh);
}

// ---- palettes (value-led 5-step ramps, nudged toward the boreal-baseline teal like the grass) ----
const base = STYLES.find((s) => s.id === 'boreal-baseline');
const GRASS = base.grass.ramp;
const DIRT = base.dirt.ramp; // the shipped dirt_side ramp
const ROCK = ['#1c2120', '#2e3533', '#434b47', '#5c6560', '#7f8882'];
const MOSS = ['#1a2e22', '#28432f', '#37583d', '#4d7049'];
const GRAVEL = ['#2e2b27', '#45413a', '#5e5950', '#7b756a', '#a09888'];
const SAND = ['#4f4a3a', '#6a6350', '#7f7861', '#958d73', '#ada58a'];
const MUD = ['#17140f', '#231e17', '#302820', '#3f352a', '#544838'];
const PATH = ['#2c241a', '#433728', '#574833', '#6b5a41', '#857256'];
const PODZOL = ['#1c140f', '#2c1f16', '#3f2b1d', '#563a26', '#70503a'];
const GLINT = '#3fb0a4'; // the meadow's sensor-cyan, kept rare (lore)
const SKY = ['#56706f', '#7e9a9a']; // wet sheen: haze colour seen in mud

// ---- 0. grass row: the variant set of bake_grass.mjs, drawn the same way --------------------------
const GSEEDS = [101, 1103, 2207, 3301, 4409, 5503, 6607, 7703];
const GSIGNAL = [2, 0, 1, 0, 0, 1, 0, 0];
GSEEDS.forEach((seed, i) => {
  const st = JSON.parse(JSON.stringify(base));
  st.seed = seed;
  if (i > 0) {
    st.grass.signal.count = GSIGNAL[i];
    if (i % 3 === 1) st.grass.tuft.clusters = 4;
    if (i % 3 === 2) st.grass.tuft.clusters = 6;
    if (i === 4) st.grass.fieldDark = 0.28;
    if (i === 6) st.grass.fieldDark = 0.16;
  }
  blitTile(atlas, 0, i, genTextures(st).grassTop.rgba);
});
const C = {
  clover: [62, 112, 70], cloverHi: [104, 150, 98], cloverDk: [29, 51, 39],
  yellow: [214, 190, 92], yellowDk: [150, 120, 52], white: [216, 222, 210], whiteDk: [140, 150, 140],
  violet: [146, 118, 170], violetDk: [92, 70, 112],
  dirt: [79, 60, 40], dirtHi: [106, 82, 55], dirtDk: [58, 42, 28], pebble: [125, 112, 100], pebbleHi: [150, 140, 126],
  straw: [150, 142, 92], strawDk: [112, 106, 66],
};
function decal(fn, seed) {
  const t = new Uint8Array(R * R * 4); const rnd = stream(seed);
  const put = (x, y, c) => { if (x < 0 || y < 0 || x >= R || y >= R) return; const i = (y * R + x) * 4; t[i] = c[0]; t[i + 1] = c[1]; t[i + 2] = c[2]; t[i + 3] = 255; };
  fn(put, rnd); return t;
}
const leaf3 = (put, x, y) => {
  put(x, y, C.clover); put(x + 1, y, C.cloverHi); put(x, y + 1, C.clover); put(x - 1, y + 1, C.cloverHi);
  put(x + 1, y + 1, C.clover); put(x, y + 2, C.cloverDk);
};
const speck = (put, r, span, c, dk) => {
  const x = 1 + (r() * span | 0), y = 1 + (r() * 13 | 0);
  put(x, y + 1, dk); put(x, y, c); put(x + 1, y, c);
};
const GDECALS = [
  (put, r) => { for (let k = 0; k < 8; k++) leaf3(put, 2 + (r() * 11 | 0), 2 + (r() * 11 | 0)); },
  (put, r) => { for (let k = 0; k < 9; k++) speck(put, r, 13, C.yellow, C.yellowDk); },
  (put, r) => { for (let k = 0; k < 10; k++) speck(put, r, 13, C.white, C.whiteDk); },
  (put, r) => { for (let k = 0; k < 8; k++) speck(put, r, 12, C.violet, C.violetDk); },
  (put, r) => {
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      const d = Math.hypot((x - 8) / 5.2, (y - 8) / 4.2) + (r() - 0.5) * 0.45;
      if (d < 1) put(x, y, d > 0.8 ? C.dirtDk : (r() < 0.2 ? C.dirtHi : C.dirt));
    }
    put(6, 7, C.pebble); put(7, 7, C.pebbleHi); put(10, 9, C.pebble);
  },
  (put, r) => {
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      const d = Math.hypot((x - 6) / 3, (y - 10) / 2.3) + (r() - 0.5) * 0.5;
      if (d < 1) put(x, y, d > 0.75 ? C.dirtDk : C.dirt);
    }
  },
  (put, r) => {
    for (let k = 0; k < 4; k++) {
      const x = 2 + (r() * 11 | 0), y = 2 + (r() * 11 | 0);
      put(x, y, C.pebbleHi); put(x + 1, y, C.pebble); put(x + 1, y + 1, C.dirtDk);
    }
  },
  (put, r) => {
    for (let k = 0; k < 6; k++) {
      const x = 2 + (r() * 11 | 0), y = 2 + (r() * 11 | 0);
      put(x, y, C.straw); put(x + 1, y + 1, C.strawDk);
    }
  },
];
GDECALS.forEach((fn, i) => blitTile(datlas, 0, i, decal(fn, 900 + i * 37)));

// ---- 1. dirt wall: the prototype's genDirtSide re-seeded; variant 0 is the shipped seed 101 ----
const DSEEDS = [101, 1201, 2311, 3413, 4517, 5623, 6733, 7841];
DSEEDS.forEach((seed, i) => {
  const st = JSON.parse(JSON.stringify(base));
  st.seed = seed;
  if (i % 2 === 1) st.dirt.clod.clusters = 4;
  if (i % 3 === 2) st.dirt.pebble.count = 8;
  blitTile(atlas, 1, i, genTextures(st).dirtSide.rgba);
});

// ---- material generators: (seed, variant index) -> 16x16 RGBA ----
const GEN = {
  // Rock face (sides only; drawn upright, v increases downward = world down after the shader flip).
  // Horizontal bedding planes with a lit ledge on top and short vertical joints between them.
  rock(seed, v) {
    const c = canvas(), r = stream(seed);
    field(c, ROCK, seed + 1, 4, [0.4, 0.68], 1);
    const off = (r() * 5) | 0, gap = 5 + (v % 2);
    for (let y = off; y < R + gap; y += gap) {
      for (let x = 0; x < R; x++) {
        if (hash2(x, y, seed) < 0.12) continue;            // bedding planes break here and there
        const wob = hash2(x >> 2, y, seed + 3) < 0.3 ? 1 : 0;
        c.put(x, y + wob, RGB(ROCK[0]));
        c.put(x, y + wob + 1, RGB(ROCK[3 + (hash2(x, y, seed + 9) < 0.25 ? 1 : 0)]));
      }
      const joints = 1 + ((r() * 2) | 0);
      for (let k = 0; k < joints; k++) {
        const x = (r() * R) | 0;
        for (let j = 2; j < gap; j++) { c.put(x, y + j, RGB(ROCK[0])); c.put(x + 1, y + j, RGB(ROCK[2])); }
      }
    }
    if (v === 3) c.put((r() * R) | 0, (r() * R) | 0, RGB(GLINT));   // rare sensor speck (1 of 8)
    return c.t;
  },
  // Mossy rock: the rock above, with moss settled on the ledges and in the damp low patches.
  mossrock(seed, v) {
    const c = canvas(); c.t.set(GEN.rock(seed, v));
    const n = tileNoise(4, seed + 41), r = stream(seed + 5);
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      const [rr] = c.get(x, y);
      const ledge = rr === RGB(ROCK[3])[0] || rr === RGB(ROCK[4])[0];
      const cover = n(x, y) + (ledge ? 0.35 : 0) + (v % 3) * 0.06;
      if (cover > 0.78) c.put(x, y, RGB(MOSS[cover > 0.95 ? 3 : hash2(x, y, seed) < 0.5 ? 2 : 1]));
      else if (cover > 0.70 && hash2(x, y, seed + 2) < 0.5) c.put(x, y, RGB(MOSS[0]));
    }
    for (let k = 0; k < 3; k++) { const x = (r() * R) | 0, y = (r() * R) | 0; c.put(x, y, RGB(MOSS[3])); }
    return c.t;
  },
  // Gravel / scree: packed stones of mixed hue, each lit top-left, dark interstices.
  gravel(seed, v) {
    const c = canvas(), r = stream(seed);
    field(c, GRAVEL, seed + 1, 5, [0.45, 0.8], 0);
    const hues = [GRAVEL, ['#262422', '#3c3a37', '#55524d', '#716d66', '#938e85'], ['#2a2219', '#40352a', '#5a4b3a', '#78654e', '#9a8569']];
    const count = 22 + v * 2;
    for (let k = 0; k < count; k++) {
      const x = (r() * R) | 0, y = (r() * R) | 0, w = 1 + ((r() * 2.4) | 0), h = 1 + ((r() * 2) | 0);
      const p = hues[(r() * 3) | 0];
      stone(c, x, y, w, h, RGB(p[2 + (r() < 0.4 ? 1 : 0)]), RGB(p[4]), RGB(p[0]));
    }
    return c.t;
  },
  // Sand bank: fine grain dither between two mids, soft ripple lines (dark trough, lit crest).
  sand(seed, v) {
    const c = canvas(), r = stream(seed);
    const n = tileNoise(4, seed + 1);
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      const t = n(x, y) + (hash2(x, y, seed) - 0.5) * 0.35;
      c.put(x, y, RGB(SAND[t > 0.62 ? 3 : t > 0.3 ? 2 : 1]));
    }
    if (v % 4 !== 3) {   // ripples on most variants; one in four is flat
      const ph = r() * 6.28, per = 5 + (v % 2);
      for (let x = 0; x < R; x++) {
        const yy = Math.round(2 * Math.sin((x / R) * 6.283 + ph));
        for (let y0 = 0; y0 < R; y0 += per) {
          if (hash2(x, y0, seed + 7) < 0.15) continue;
          c.put(x, y0 + yy, RGB(SAND[1])); c.put(x, y0 + yy - 1, RGB(SAND[4]));
        }
      }
    }
    for (let k = 0; k < 6; k++) c.put((r() * R) | 0, (r() * R) | 0, RGB(SAND[0]));
    return c.t;
  },
  // Mud / clay at still water: dark wet field, sky-coloured sheen specks, drying cracks on some.
  mud(seed, v) {
    const c = canvas(), r = stream(seed);
    field(c, MUD, seed + 1, 4, [0.4, 0.72], 1);
    const n = tileNoise(3, seed + 11);
    for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) {
      if (n(x, y) > 0.7 && hash2(x, y, seed + 4) < 0.35) c.put(x, y, RGB(SKY[hash2(x, y, seed + 5) < 0.3 ? 1 : 0]));
    }
    if (v >= 4) {        // the drier half cracks into plates
      let x = (r() * R) | 0, y = (r() * R) | 0;
      for (let k = 0; k < 26 + v * 2; k++) {
        c.put(x, y, RGB(MUD[0])); c.put(x + 1, y + 1, RGB(MUD[4]));
        if (r() < 0.5) x += r() < 0.5 ? 1 : -1; else y += r() < 0.5 ? 1 : -1;
        if (k % 9 === 8) { x = (r() * R) | 0; y = (r() * R) | 0; }
      }
    }
    return c.t;
  },
  // Packed earth path: calm, compacted, lighter than the dirt wall; sparse pebbles and hairline cracks.
  path(seed, v) {
    const c = canvas(), r = stream(seed);
    field(c, PATH, seed + 1, 3, [0.3, 0.7], 1);
    for (let k = 0; k < 3 + (v % 3); k++) { const x = (r() * R) | 0, y = (r() * R) | 0; stone(c, x, y, 1, 1, RGB('#7d7064'), RGB('#8b7f70'), RGB(PATH[0])); }
    for (let k = 0; k < 2; k++) {
      let x = (r() * R) | 0, y = (r() * R) | 0;
      for (let s = 0; s < 4; s++) { c.put(x, y, RGB(PATH[0])); x += 1; if (r() < 0.5) y += r() < 0.5 ? 1 : -1; }
    }
    if (v === 2 || v === 5) for (let k = 0; k < 4; k++) c.put((r() * R) | 0, (r() * R) | 0, RGB(GRASS[2]));
    return c.t;
  },
  // Podzol / needle litter: rust-brown duff with fallen needles in all directions, bleached specks.
  podzol(seed, v) {
    const c = canvas(), r = stream(seed);
    field(c, PODZOL, seed + 1, 4, [0.38, 0.7], 0);
    const dirs = [[1, 0], [0, 1], [1, 1], [1, -1]];
    for (let k = 0; k < 26 + v * 2; k++) {
      const [dx, dy] = dirs[(r() * 4) | 0], x = (r() * R) | 0, y = (r() * R) | 0, len = 2 + ((r() * 2) | 0);
      const col = RGB(PODZOL[r() < 0.6 ? 3 : 4]);
      for (let s = 0; s < len; s++) c.put(x + dx * s, y + dy * s, col);
      c.put(x + dx * len, y + dy * len + 1, RGB(PODZOL[0]));
    }
    for (let k = 0; k < 3; k++) c.put((r() * R) | 0, (r() * R) | 0, RGB('#8a8478'));
    return c.t;
  },
};

const P = (h) => RGB(h);
const DECALS = {
  dirt: [
    (put, r) => { let x = 2, y = 3 + (r() * 4 | 0); for (let s = 0; s < 12; s++) { put(x, y, P('#2a1d12')); put(x, y - 1, P('#5b4630')); x++; if (r() < 0.35) y += r() < 0.5 ? 1 : -1; } },
    (put) => { for (let j = 0; j < 3; j++) for (let i = 0; i < 4; i++) put(6 + i, 6 + j, P('#7d7064')); put(6, 6, P('#a09584')); put(7, 6, P('#a09584')); for (let i = 1; i <= 4; i++) put(6 + i, 9, P(DIRT[0])); },
  ],
  rock: [
    (put, r) => { for (let k = 0; k < 7; k++) { const x = 3 + (r() * 9 | 0), y = 3 + (r() * 9 | 0); put(x, y, P('#8a9a7a')); put(x + 1, y, P('#6f7f62')); } },
    (put) => { for (let i = 0; i < 12; i++) { put(2 + i, 4 + (i >> 2), P('#b6bcb3')); put(2 + i, 5 + (i >> 2), P(ROCK[1])); } },
    (put) => { for (let j = 0; j < 10; j++) put(8 + (j % 3 === 0 ? 1 : 0), 3 + j, P(ROCK[0])); },
  ],
  mossrock: [
    (put, r) => { for (let k = 0; k < 14; k++) { const x = 4 + (r() * 7 | 0), y = 4 + (r() * 7 | 0); put(x, y, P(MOSS[2 + (k % 2)])); } },
    (put) => { [[7, 3], [6, 4], [8, 4], [7, 5], [5, 6], [9, 6], [7, 7], [7, 8], [7, 9]].forEach(([x, y]) => put(x, y, P('#4f8a52'))); put(7, 10, P(MOSS[0])); },
    (put, r) => { for (let k = 0; k < 7; k++) { const x = 3 + (r() * 9 | 0), y = 3 + (r() * 9 | 0); put(x, y, P('#8a9a7a')); } },
  ],
  gravel: [
    (put) => { for (let j = 0; j < 3; j++) for (let i = 0; i < 5; i++) put(5 + i, 6 + j, P('#6b665b')); put(5, 6, P('#a19a8b')); put(6, 6, P('#a19a8b')); for (let i = 1; i <= 5; i++) put(5 + i, 9, P(GRAVEL[0])); for (let j = 7; j <= 9; j++) put(10, j, P(GRAVEL[0])); },
    (put) => { for (let i = 0; i < 9; i++) { put(3 + i, 9 - (i >> 1), P('#6a5237')); put(4 + i, 10 - (i >> 1), P(DIRT[0])); } },
    (put) => { for (let j = 0; j < 2; j++) for (let i = 0; i < 4; i++) put(4 + i, 4 + j, P('#55606a')); put(4, 4, P('#7d8a94')); for (let i = 1; i <= 4; i++) put(4 + i, 6, P(GRAVEL[0])); },
  ],
  sand: [
    // freshwater mussel shell: pale valve with growth lines
    (put) => { [[6, 6], [7, 6], [8, 6], [5, 7], [6, 7], [7, 7], [8, 7], [9, 7], [5, 8], [6, 8], [7, 8], [8, 8], [9, 8], [6, 9], [7, 9], [8, 9]].forEach(([x, y]) => put(x, y, P('#d6cfbf'))); put(6, 8, P('#9e927c')); put(8, 8, P('#9e927c')); put(7, 9, P('#9e927c')); [[7, 10], [8, 10], [10, 8]].forEach(([x, y]) => put(x, y, P(SAND[0]))); },
    // small snail shell
    (put) => { [[7, 7], [8, 7], [6, 8], [9, 8], [7, 9], [8, 9]].forEach(([x, y]) => put(x, y, P('#c9b89a'))); put(7, 8, P('#7a6650')); put(8, 8, P('#e3d8c2')); put(9, 9, P(SAND[0])); },
    // driftwood twig
    (put) => { for (let i = 0; i < 10; i++) { put(3 + i, 6 + (i >> 2), P('#8f8a7c')); put(3 + i, 7 + (i >> 2), P('#5b5546')); } },
    // bird tracks
    (put) => { for (let k = 0; k < 3; k++) { const x = 3 + k * 4, y = 4 + k * 3; put(x, y, P(SAND[0])); put(x - 1, y - 1, P(SAND[0])); put(x + 1, y - 1, P(SAND[0])); put(x, y + 1, P(SAND[0])); } },
  ],
  mud: [
    // hoofprint pair
    (put) => { [[5, 6], [6, 6], [5, 7], [6, 7], [8, 6], [9, 6], [8, 7], [9, 7], [5, 8], [9, 8]].forEach(([x, y]) => put(x, y, P(MUD[0]))); put(5, 5, P(MUD[4])); put(9, 5, P(MUD[4])); },
    // puddle with sky
    (put, r) => { for (let y = 0; y < R; y++) for (let x = 0; x < R; x++) { const d = Math.hypot((x - 8) / 4.5, (y - 8) / 3) + (r() - 0.5) * 0.25; if (d < 1) put(x, y, d > 0.82 ? P(MUD[0]) : P(SKY[(x + y) % 5 === 0 ? 1 : 0])); } },
    // reed stubs
    (put, r) => { for (let k = 0; k < 5; k++) { const x = 3 + (r() * 10 | 0), y = 3 + (r() * 10 | 0); put(x, y, P('#6f7a4a')); put(x, y + 1, P('#3f4a2a')); } },
  ],
  path: [
    (put, r) => { for (let k = 0; k < 4; k++) { const x = 3 + (r() * 10 | 0), y = 3 + (r() * 10 | 0); put(x, y, P('#9a8f7f')); put(x + 1, y, P('#7d7064')); put(x + 1, y + 1, P(PATH[0])); } },
    (put) => { let y = 7; for (let x = 1; x < 15; x++) { put(x, y, P('#5b4630')); put(x, y + 1, P(PATH[0])); if (x % 4 === 0) y += 1; } },
    (put, r) => { for (let k = 0; k < 6; k++) { const x = 2 + (r() * 12 | 0), y = 2 + (r() * 11 | 0); put(x, y, P(GRASS[3])); put(x, y + 1, P(GRASS[2])); put(x - 1, y + 1, P(GRASS[1])); } },
    (put) => { [[5, 4], [6, 4], [5, 5], [6, 5], [5, 6], [6, 6], [5, 7], [6, 7], [9, 9], [10, 9], [9, 10], [10, 10], [9, 11], [10, 11], [9, 12], [10, 12]].forEach(([x, y]) => put(x, y, P(PATH[1]))); },
  ],
  podzol: [
    // spruce cone
    (put) => { for (let j = 0; j < 5; j++) { put(7, 5 + j, P('#7a4a26')); put(8, 5 + j, P(j % 2 ? '#5a3418' : '#8f5c30')); } put(7, 4, P('#3b2414')); put(9, 6, P(PODZOL[0])); put(9, 8, P(PODZOL[0])); },
    // twig
    (put) => { for (let i = 0; i < 11; i++) { put(2 + i, 10 - (i >> 1), P('#4a3a2a')); } put(6, 6, P('#4a3a2a')); put(7, 5, P('#4a3a2a')); },
    // muted mushroom cap seen from above
    (put) => { [[7, 6], [8, 6], [6, 7], [7, 7], [8, 7], [9, 7], [7, 8], [8, 8]].forEach(([x, y]) => put(x, y, P('#9a5a3a'))); put(7, 7, P('#c48a62')); put(9, 8, P(PODZOL[0])); put(8, 9, P(PODZOL[0])); },
    // birch leaf
    (put) => { [[6, 6], [7, 6], [6, 7], [7, 7], [8, 7], [7, 8], [8, 8]].forEach(([x, y]) => put(x, y, P('#b89a4a'))); put(9, 9, P('#7a6a30')); },
  ],
};

const SEED0 = { rock: 3101, mossrock: 3101, gravel: 4201, sand: 5303, mud: 6407, path: 7509, podzol: 8603 };
for (let m = 2; m < NM; m++) {
  const slug = MATS[m];
  for (let v = 0; v < NV; v++) blitTile(atlas, m, v, GEN[slug](SEED0[slug] + v * 1013, v));
}
for (let m = 1; m < NM; m++) {
  const list = DECALS[MATS[m]];
  list.forEach((fn, i) => blitTile(datlas, m, i, decal(fn, 1900 + m * 101 + i * 37)));
}

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'atlas.png'), png(NV * R, NM * R, atlas));
writeFileSync(join(outDir, 'decals.png'), png(NV * R, NM * R, datlas));
console.log(`bake_ground: math=lowbias32 wrote atlas.png, decals.png (${MATS.join(',')}) -> ${outDir}`);
