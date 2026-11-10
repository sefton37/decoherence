#!/usr/bin/env node
// Spec #517 A2: the oracle's substituted primitives, and the machinery that injects them.
//
// The frozen Stalag prototype (~/dev/stalag, tag prototype-final) is the oracle for the
// engine. Three of its numeric primitives are replaced, in the engine and here, by
// first-principles definitions: the integer hash finalizer inside hash2, Math.hypot,
// Math.log2, Math.sin, Math.cos and Math.atan2. Everything else the oracle runs is the prototype's own code, byte for byte.
//
//   prepareTree(stalagDir, outDir, mode)  copies src/, skins/ and package.json of the
//        prototype into outDir/proto/ (the original is never written) and, unless mode is
//        "none", rewrites ONE function there: hash2 in src/worldgen.js.
//   installMath(mode)                     overrides Math.hypot / Math.log2 for this process.
//
// Modes: lowbias32 (default; hash, hypot, log2 and trig swapped), none (copy only; reproduces the
// prototype's own world), hypot_native, log2_native, trig_native (the hash and the other
// primitives swapped, the named one left to the host engine).
//
// The detLog2 / detHypot* definitions are plain IEEE double + - * / and sqrt, in the exact
// operation order of engine/stalag/src/stalag_det.h, so the two agree bit for bit.
//
// CLI:  proto_subst.mjs vectors <dir>   writes <dir>/vectors.bin for tests/verify_stalag_det.sh
//
// vectors.bin: u32 family count, then per family { char name[24]; u32 n; u32 arity;
// f64 inputs[n*arity]; f64 expected[n] }. The lowbias32 family carries uint32 values as doubles.

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MODES = ['lowbias32', 'none', 'hypot_native', 'log2_native', 'trig_native'];

// ---- trigonometry: clean-room sin, cos, atan2 (Spec #517 A4.2); same order as stalag_det.h ----
const TWO_OVER_PI = 0.6366197723675814;
const CW_A = 1.570796325802803;
const CW_B = 9.920935739593517e-10;
const CW_C = 5.721188726109832e-18;
const PIO2 = 1.5707963267948966;
const PI = 3.141592653589793;

function polySin(r) {
  const z = r * r;
  let ps = 1;
  for (let k = 10; k >= 1; k--) ps = 1 - (z / ((2 * k) * (2 * k + 1))) * ps;
  return r * ps;
}
function polyCos(r) {
  const z = r * r;
  let pc = 1;
  for (let k = 10; k >= 1; k--) pc = 1 - (z / ((2 * k - 1) * (2 * k))) * pc;
  return pc;
}
function reduce(x) {
  if (!(Math.abs(x) < 1e6)) return null;
  const n = Math.floor(x * TWO_OVER_PI + 0.5);
  const r = ((x - n * CW_A) - n * CW_B) - n * CW_C;
  const q = n - 4 * Math.floor(n / 4);
  return [r, q];
}
export function detSin(x) {
  const t = reduce(x);
  if (!t) return NaN;
  const [r, q] = t;
  if (q === 0) return polySin(r);
  if (q === 1) return polyCos(r);
  if (q === 2) return -polySin(r);
  return -polyCos(r);
}
export function detCos(x) {
  const t = reduce(x);
  if (!t) return NaN;
  const [r, q] = t;
  if (q === 0) return polyCos(r);
  if (q === 1) return -polySin(r);
  if (q === 2) return -polyCos(r);
  return polySin(r);
}
function atan01(t) {
  let u = t;
  for (let i = 0; i < 3; i++) u = u / (1 + Math.sqrt(1 + u * u));
  const z = u * u;
  let p = 0;
  for (let k = 10; k >= 0; k--) p = 1 / (2 * k + 1) - z * p;
  return 8 * (u * p);
}
const negative = (v) => v < 0 || Object.is(v, -0);
export function detAtan2(y, x) {
  if (!Number.isFinite(y) || !Number.isFinite(x)) return NaN;
  const ay = Math.abs(y), ax = Math.abs(x);
  let r;
  if (ay === 0) r = 0;
  else if (ax === 0) r = PIO2;
  else if (ax >= ay) r = atan01(ay / ax);
  else r = PIO2 - atan01(ax / ay);
  if (negative(x)) r = PI - r;
  return negative(y) ? -r : r;
}

// SPDX-License-Identifier: LicenseRef-PublicDomain
// lowbias32: Chris Wellons, "Prospecting for Hash Functions", https://nullprogram.com/blog/2018/07/31/ (public domain)
export function lowbias32(x) {
  x ^= x >>> 16;
  x = Math.imul(x, 0x7feb352d);
  x ^= x >>> 15;
  x = Math.imul(x, 0x846ca68b);
  x ^= x >>> 16;
  return x >>> 0;
}

export function detHypot2(a, b) {
  return Math.sqrt(a * a + b * b);
}

export function detHypot3(a, b, c) {
  return Math.sqrt((a * a + b * b) + c * c);
}

// ln m = 2 * atanh(s) = 2 * (s + s^3/3 + s^5/5 + ...), s = (m - 1) / (m + 1), after x = m * 2^e.
export function detLog2(x) {
  if (!(x > 0)) {
    if (x === 0) return -Infinity;
    return NaN;
  }
  if (x === Infinity) return x;
  let m = x;
  let e = 0;
  while (m >= 2) {
    m = m * 0.5;
    e = e + 1;
  }
  while (m < 1) {
    m = m * 2;
    e = e - 1;
  }
  if (m > 1.4142135623730951) {
    m = m * 0.5;
    e = e + 1;
  }
  const s = (m - 1) / (m + 1);
  const z = s * s;
  let p = 1 / 23;
  for (let k = 21; k >= 1; k -= 2) p = p * z + 1 / k;
  return e + ((2 * s) * p) * 1.4426950408889634;
}

// ---- exp and pow: clean-room twins of det_exp / det_pow (Spec #545 Phase A); same order as stalag_det.h ----
const LOG2E = 1.4426950408889634;
const LN2 = 0.6931471805599453;
const LN2_A = 0.6931471796706319;
const LN2_B = 8.893134232496047e-10;
const LN2_C = 6.390629507645039e-19;
export function detExp(x) {
  if (x !== x) return NaN;
  if (x > 709.782712893384) return Infinity;
  if (x < -745.2) return 0;
  const k = Math.floor(x * LOG2E + 0.5);
  const r = ((x - k * LN2_A) - k * LN2_B) - k * LN2_C;
  let p = 1;
  for (let n = 18; n >= 1; n--) p = 1 + (r / n) * p;
  let ki = k;
  while (ki > 0) { p = p * 2; ki--; }
  while (ki < 0) { p = p * 0.5; ki++; }
  return p;
}
export function detPow(x, y) {
  if (y === 0) return 1;
  if (x !== x || y !== y) return NaN;
  if (x === 0) return y > 0 ? 0 : Infinity;
  if (x < 0) return NaN;
  if (x === Infinity) return y > 0 ? x : 0;
  return detExp(y * (detLog2(x) * LN2));
}
// Opt-in (flora oracle only): the S1 plan hash must not move, so installMath never does this.
export function installExpPow() {
  Math.exp = detExp;
  Math.pow = detPow;
}

// What each mode swaps: [hash2 finalizer, Math.hypot, Math.log2]
const PLAN = {
  lowbias32: { hash: true, overrides: ['atan2', 'cos', 'hypot', 'log2', 'sin'] },
  none: { hash: false, overrides: [] },
  hypot_native: { hash: true, overrides: ['atan2', 'cos', 'log2', 'sin'] },
  log2_native: { hash: true, overrides: ['atan2', 'cos', 'hypot', 'sin'] },
  trig_native: { hash: true, overrides: ['hypot', 'log2'] },
};

export function modeInfo(mode) {
  const p = PLAN[mode];
  if (!p) throw new Error(`proto_subst: unknown mode '${mode}' (want ${MODES.join('|')})`);
  return { mode, files_changed: p.hash ? ['src/worldgen.js'] : [], math_overrides: p.overrides.slice() };
}

// The replacement keeps the input combine of the prototype's hash2 (seed ^ ix*A ^ iz*B,
// reduced to 32 bits) and the final divide by 2^32; only the finalizer in between is swapped.
const HASH2_BODY = [
  'function hash2(ix, iz, seed) {',
  '  let h = (seed | 0) ^ ((ix * 2654435761) | 0) ^ ((iz * 1234567891) | 0);',
  '  h ^= h >>> 16;',
  '  h = Math.imul(h, 0x7feb352d);',
  '  h ^= h >>> 15;',
  '  h = Math.imul(h, 0x846ca68b);',
  '  h ^= h >>> 16;',
  '  return (h >>> 0) / 4294967296;',
  '}',
].join('\n');

export function prepareTree(stalagDir, outDir, mode) {
  const info = modeInfo(mode);
  const dest = join(outDir, 'proto');
  rmSync(dest, { recursive: true, force: true });
  mkdirSync(dest, { recursive: true });
  for (const rel of ['src', 'skins']) cpSync(join(stalagDir, rel), join(dest, rel), { recursive: true });
  const pkg = join(stalagDir, 'package.json');
  if (existsSync(pkg)) cpSync(pkg, join(dest, 'package.json'));
  if (info.files_changed.length) {
    const f = join(dest, 'src', 'worldgen.js');
    const lines = readFileSync(f, 'utf8').split('\n');
    const a = lines.findIndex((l) => l === 'function hash2(ix, iz, seed) {');
    if (a < 0) throw new Error('proto_subst: hash2 anchor not found in src/worldgen.js');
    const b = lines.findIndex((l, i) => i > a && l === '}');
    if (b < 0) throw new Error('proto_subst: end of hash2 not found');
    lines.splice(a, b - a + 1, ...HASH2_BODY.split('\n'));
    writeFileSync(f, lines.join('\n'));
  }
  return { dir: dest, ...info };
}

export function installMath(mode) {
  const info = modeInfo(mode);
  if (info.math_overrides.includes('hypot')) {
    Math.hypot = (a, b, c) => (c === undefined ? detHypot2(a, b) : detHypot3(a, b, c));
  }
  if (info.math_overrides.includes('log2')) Math.log2 = detLog2;
  if (info.math_overrides.includes('sin')) Math.sin = detSin;
  if (info.math_overrides.includes('cos')) Math.cos = detCos;
  if (info.math_overrides.includes('atan2')) Math.atan2 = detAtan2;
  return info;
}

// ---------------------------------------------------------------- test vectors (CLI)
function fromBits(hi, lo) {
  const dv = new DataView(new ArrayBuffer(8));
  dv.setUint32(0, lo >>> 0, true);
  dv.setUint32(4, hi >>> 0, true);
  return dv.getFloat64(0, true);
}
// neighbour in the next/previous representable direction, by integer arithmetic on the bit pattern
function stepBits(x, d) {
  const dv = new DataView(new ArrayBuffer(8));
  dv.setFloat64(0, x, true);
  dv.setBigUint64(0, dv.getBigUint64(0, true) + BigInt(d), true);
  return dv.getFloat64(0, true);
}

function makeVectors() {
  let counter = 1;
  const rnd32 = () => lowbias32(counter++ * 2 + 1); // counter-based generator, deterministic
  const rnd = () => rnd32() / 4294967296;
  const wide = () => {
    // random sign-free finite double: any exponent, random mantissa
    const hi = (rnd32() & 0x7fffffff) >>> 0;
    const lo = rnd32();
    const x = fromBits(hi, lo);
    return Number.isFinite(x) ? x : 1.5;
  };
  const fams = [];
  const add = (name, arity, n, gen, fn) => {
    const inp = new Float64Array(n * arity);
    const exp = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const v = gen(i);
      for (let a = 0; a < arity; a++) inp[i * arity + a] = v[a];
      exp[i] = fn(...v);
    }
    fams.push({ name, n, arity, inp, exp });
  };
  const N = 800000;
  const signed = () => (rnd() - 0.5) * 2;
  add('hypot2', 2, N, () => [signed() * 300, signed() * 300], detHypot2);
  add('hypot3', 3, N, () => [signed() * 300, signed() * 300, signed() * 300], detHypot3);
  // near 1: the series argument s is tiny and the result is dominated by cancellation
  add('log2_near1', 1, N, () => [1 + (rnd() - 0.5) * 1e-3 * (1 + rnd32() % 7)], detLog2);
  add('log2_ratio', 1, N, () => [Math.max(Math.floor(rnd() * 2e6), 5200) / 5200], detLog2);
  add('log2_split', 1, N, () => {
    // around the m > sqrt(2) switch and around every power of two
    const e = (rnd32() % 60) - 30;
    const base = (rnd32() & 1) ? 1.4142135623730951 : 1;
    return [base * 2 ** e * (1 + (rnd() - 0.5) * 1e-9)];
  }, detLog2);
  add('log2_wide', 1, N, () => [wide()], detLog2);
  // exact powers of two and their neighbours, every exponent
  const pow2 = [];
  for (let e = -1074; e <= 1023; e++) {
    const x = e < -1022 ? 2 ** (e + 1000) * 2 ** -1000 : 2 ** e;
    pow2.push(x);
    pow2.push(stepBits(x, 1)); // next above
    if (x > 5e-324) pow2.push(stepBits(x, -1)); // next below
  }
  add('log2_pow2', 1, pow2.length, (i) => [pow2[i]], detLog2);
  // special values plus a block of random subnormals and negatives
  const special = [0, -0, Infinity, -Infinity, NaN, -1, -5e-324, 5e-324, 2.2250738585072014e-308, Number.MAX_VALUE, Number.MIN_VALUE, 1];
  while (special.length < 2000) {
    const r = rnd32() % 3;
    if (r === 0) special.push(fromBits(0, rnd32() | 1)); // subnormal
    else if (r === 1) special.push(-wide());
    else special.push(fromBits(rnd32() & 0x000fffff, rnd32())); // subnormal, high bits set
  }
  add('log2_special', 1, special.length, (i) => [special[i]], detLog2);
  add('lowbias32', 1, N, () => [rnd32()], (x) => lowbias32(x));
  // trigonometry: reduction needs |x| < 1e6; atan2 takes every quadrant and both axes
  const NT = 300000;
  add('sin', 1, NT, () => [signed() * 1000], detSin);
  add('cos', 1, NT, () => [signed() * 1000], detCos);
  add('atan2', 2, NT, () => [signed() * 300, signed() * 300], detAtan2);
  const grid = [0, -0, 1, -1, 0.5, 1e-300, 3.141592653589793, 1.5707963267948966, 2 * Math.PI, 4.1887902047863905, 1e5, 999999, 1e6, NaN, Infinity, -Infinity, 5e-324];
  const tspecial = [];
  for (const kind of [0, 1, 2]) for (const a of grid) for (const b of kind === 2 ? grid : [0]) tspecial.push([kind, a, b]);
  add('trig_special', 3, tspecial.length, (i) => tspecial[i],
    (kind, a, b) => (kind === 0 ? detSin(a) : kind === 1 ? detCos(a) : detAtan2(a, b)));
  // exp and pow (Spec #545): small, the windfield decay range, the full range, special values
  add('exp_small', 1, 200000, () => [signed() * 2], detExp);
  add('exp_decay', 1, 200000, () => [-rnd() * 40], detExp);
  add('exp_wide', 1, 200000, () => [(rnd() - 0.5) * 1500], detExp);
  const expSpecial = [0, -0, NaN, Infinity, -Infinity, 709.782712893384, 709.79, -745.2, -745, -744.4, -708.4, -709, 1e-300, -1e-300, 1, -1, 0.5, 5e-324];
  while (expSpecial.length < 100000) expSpecial.push((rnd() - 0.5) * 1480);
  add('exp_special', 1, expSpecial.length, (i) => [expSpecial[i]], detExp);
  add('pow_boundary', 2, 200000, () => [Math.max(rnd(), 1e-9) * (1 + rnd() * 0.5), 0.143], detPow);
  add('pow_general', 2, 200000, () => [rnd() * 1000 + 1e-6, signed() * 3], detPow);
  const powSpecial = [[0, 0.143], [0, 0], [0, -1], [1, 0.143], [1, 7], [2, 0], [NaN, 1], [3, NaN], [-2, 0.5], [Infinity, 2], [Infinity, -2], [5e-324, 0.143], [1e300, 0.143], [0.5, 1000], [2, 1000]];
  while (powSpecial.length < 100000) powSpecial.push([rnd() * 3, signed() * 4]);
  add('pow_special', 2, powSpecial.length, (i) => powSpecial[i], detPow);
  return fams;
}

function writeVectors(dir) {
  mkdirSync(dir, { recursive: true });
  const fams = makeVectors();
  const parts = [];
  const hdr = Buffer.alloc(4);
  hdr.writeUInt32LE(fams.length, 0);
  parts.push(hdr);
  for (const f of fams) {
    const h = Buffer.alloc(32);
    h.write(f.name, 0, 'latin1');
    h.writeUInt32LE(f.n, 24);
    h.writeUInt32LE(f.arity, 28);
    parts.push(h, Buffer.from(f.inp.buffer), Buffer.from(f.exp.buffer));
  }
  writeFileSync(join(dir, 'vectors.bin'), Buffer.concat(parts));
  const total = fams.reduce((s, f) => s + f.n, 0);
  console.log(`proto_subst: ${fams.length} families, ${total} vectors -> ${join(dir, 'vectors.bin')}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, dir] = process.argv.slice(2);
  if (cmd === 'vectors' && dir) writeVectors(dir);
  else {
    console.error('usage: proto_subst.mjs vectors <dir>');
    process.exit(2);
  }
}
