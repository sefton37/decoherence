#!/usr/bin/env node
// Spec #517: bake the world's pixel-art skin from the frozen prototype's own generators.
//
// Reads (never writes) the prototype checkout at $STALAG_DIR (default ~/dev/stalag), runs
// genTextures(boreal-baseline) for the grass and dirt tiles, and rebuilds the two small
// water-texture generators of index.html (the 8-frame flipbook strip and the river noise
// tile; they live in the composition root) with the same smoothing and quantising but with
// lattice values drawn from the lowbias32 hash of tools/baseline/proto_subst.mjs, then
// writes PNGs into game/world/assets/. The shipped tiles are therefore byte-identical
// to a fresh generate, which tests/verify_stalag_world.sh proves against the oracle.
//
// Usage: tools/bake_skin.mjs [outDir]    (default: game/world/assets next to this repo)

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

// ---- minimal PNG writer (RGBA8) -------------------------------------------------
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

// ---- terrain tiles ----------------------------------------------------------------
const tiles = genTextures(STYLES.find((s) => s.id === 'boreal-baseline'));

// ---- water flipbook strip (index.html: _noiseTile16 / _wFlipStrip) --------------------
// Lattice value in [0, 1): the two lattice coordinates and the seed are mixed in turn.
function wHash2(x, y, s) {
  return lowbias32(lowbias32(lowbias32(x) ^ y) ^ s) / 4294967296;
}
function noiseTile16(seed) {
  const L = 4, lat = [];
  for (let y = 0; y < L; y++) for (let x = 0; x < L; x++) lat.push(wHash2(x, y, seed));
  const v = new Float32Array(16 * 16);
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) {
    const fx = (x / 16) * L, fy = (y / 16) * L;
    const x0 = Math.floor(fx), y0 = Math.floor(fy), tx = fx - x0, ty = fy - y0;
    const sm = (t) => t * t * (3 - 2 * t);
    const g = (xx, yy) => lat[(yy % L) * L + (xx % L)];
    const a = g(x0, y0) + (g(x0 + 1, y0) - g(x0, y0)) * sm(tx);
    const b = g(x0, y0 + 1) + (g(x0 + 1, y0 + 1) - g(x0, y0 + 1)) * sm(tx);
    v[y * 16 + x] = a + (b - a) * sm(ty);
  }
  return v;
}
const nA = noiseTile16(7), nB = noiseTile16(23);
const strip = new Float32Array(128 * 16);
for (let f = 0; f < 8; f++) for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) {
  const s = 0.5 * (nA[y * 16 + (x + 2 * f) % 16] + nB[((y + f) % 16) * 16 + (x + 16 - f) % 16]);
  strip[y * 128 + f * 16 + x] = s < 0.42 ? 0.62 : s < 0.66 ? 0.82 : 1.0;
}
const flipRgba = new Uint8Array(128 * 16 * 4);
for (let i = 0; i < 128 * 16; i++) {
  const g = Math.max(0, Math.min(255, Math.round(strip[i] * 255)));
  flipRgba.set([g, g, g, 255], i * 4);
}

// ---- river noise tile (index.html makeRiverNoiseTile) ---------------------------------
function riverNoiseRgba() {
  let draw = 0;
  const rng = () => lowbias32(lowbias32(4242) ^ draw++) / 4294967296;
  const g4 = Array.from({ length: 16 }, () => rng());
  const g8 = Array.from({ length: 64 }, () => rng());
  const fade = (t) => t * t * (3 - 2 * t);
  const bil = (g, n, x, y) => {
    const xi = Math.floor(x), yi = Math.floor(y), fx = fade(x - xi), fy = fade(y - yi);
    const v = (i, j) => g[((yi + j) % n) * n + ((xi + i) % n)];
    return (v(0, 0) * (1 - fx) + v(1, 0) * fx) * (1 - fy) + (v(0, 1) * (1 - fx) + v(1, 1) * fx) * fy;
  };
  const vals = [];
  let mn = 1e9, mx = -1e9;
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) {
    const v = bil(g4, 4, x / 4, y / 4) + 0.4 * bil(g8, 8, x / 2, y / 2);
    vals.push(v);
    mn = Math.min(mn, v);
    mx = Math.max(mx, v);
  }
  const rgba = new Uint8Array(16 * 16 * 4);
  vals.forEach((v, i) => {
    const b = Math.round(((v - mn) / (mx - mn)) * 255);
    rgba.set([b, b, b, 255], i * 4);
  });
  return rgba;
}

mkdirSync(outDir, { recursive: true });
const files = {
  'grass_top.png': png(tiles.grassTop.width, tiles.grassTop.height, tiles.grassTop.rgba),
  'dirt_side.png': png(tiles.dirtSide.width, tiles.dirtSide.height, tiles.dirtSide.rgba),
  'water_flip.png': png(128, 16, flipRgba),
  'river_noise.png': png(16, 16, riverNoiseRgba()),
};
for (const [name, buf] of Object.entries(files)) writeFileSync(join(outDir, name), buf);
console.log(`bake_skin: wrote ${Object.keys(files).join(', ')} -> ${outDir}`);
