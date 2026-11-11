#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
// Spec #549 -- the charter frequency ceiling, ported from the frozen Stalag prototype's guards
// (tag prototype-final: test/leaf-frequency-guard.mjs and test/shrub-frequency-guard.mjs) and
// hardened. Kel's charter: "the world breathes, slowly, sometimes erratically, NOT vibrating." The
// top instantaneous flutter rate of the SHIPPED Godot shaders (stalag_leaf.gdshader and
// stalag_shrub.gdshader) must stay at or under 0.35 Hz, and gusts may grow the amplitude only.
//
// The prototype's guard resolved a rate factor chain by its first token and trusted marker comments
// (a first-token resolver under-reported a 0.359 Hz term as 0.223, the Spec #363 lesson). This guard
// resolves the FULL expression: every sin() or cos() whose argument depends on u_time is parsed, the
// coefficient of u_time is computed as a bound over the whole product (identifiers resolve through the
// shader's own uniform defaults, constants and local assignments, worst case for mix), so it does not
// care what order the factors are written in, and a term with no marker comment is still found.
//
// Usage: leaf_guard.mjs [repoRoot]   prints {leaf_guard{...}, shrub_guard{...}} as one JSON line.
// Each guard carries four negative controls run on mutated copies of the shader text (the shipped
// file is never written): coef_bump (the 0.359 Hz case), extra_term (a new fast term),
// literal_drift (the crate literal moved), reordered_chain (an over-ceiling rate in a reordered chain).

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.argv[2] || join(here, '..', '..', '..'));
const CEILING = 0.35;
const CRATE_MAX_EXPECTED = 1.15; // the prototype's LEAF_CRATE_MAX: the top of the per-cell rate band
const TWO_PI = 2 * Math.PI;

// ---------------------------------------------------------------- tokenizer and parser
function tokenize(s) {
  const out = [];
  const re = /\s*(\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+|[A-Za-z_][A-Za-z0-9_]*|[-+*/(),])/gy;
  let m;
  while ((m = re.exec(s)) !== null) out.push(m[1]);
  return out;
}

// A value is {c, d}: an upper bound of the magnitude of the part that does not depend on u_time, and of
// its u_time coefficient. u_time is {c: 0, d: 1}; a product of two time-dependent factors is not linear
// and is reported (q) rather than guessed.
const num = (x) => ({ c: Math.abs(x), d: 0, q: false, u: false });
function parseExpr(tokens, env, depth = 0) {
  let i = 0;
  const peek = () => tokens[i];
  const take = () => tokens[i++];
  function lookup(name) {
    if (name === 'u_time') return { c: 0, d: 1, q: false, u: false };
    if (name === 'PI') return num(Math.PI);
    if (env.has(name)) {
      if (depth > 20) throw new Error(`recursion resolving ${name}`);
      const e = env.get(name);
      return typeof e === 'number' ? num(e) : parseExpr(tokenize(e), env, depth + 1);
    }
    // a name the shader does not define as a number (a vertex input, a varying, a hash): fine inside a
    // phase, a failure the moment it multiplies something that depends on u_time (checked in product())
    return { c: 1, d: 0, q: false, u: true };
  }
  function primary() {
    const t = take();
    if (t === undefined) throw new Error('unexpected end of expression');
    if (t === '(') { const v = sum(); if (take() !== ')') throw new Error('missing )'); return v; }
    if (t === '-') { const v = primary(); return v; }
    if (t === '+') return primary();
    if (/^[\d.]/.test(t)) return num(Number(t));
    if (peek() === '(') { // function call: bound by the worst case of its arguments
      take();
      const args = [];
      if (peek() !== ')') { args.push(sum()); while (peek() === ',') { take(); args.push(sum()); } }
      if (take() !== ')') throw new Error(`missing ) after ${t}(`);
      if (t === 'mix') return { c: Math.max(args[0].c, args[1].c), d: Math.max(args[0].d, args[1].d), q: args.some((a) => a.q), u: false };
      if (t === 'fract' || t === 'sin' || t === 'cos' || t === 'smoothstep' || t === 'clamp') return { c: 1, d: 0, q: false, u: false };
      if (t === 'min' || t === 'max') return { c: Math.max(args[0].c, args[1].c), d: Math.max(args[0].d, args[1].d), q: false, u: false };
      if (t === 'abs' || t === 'float') return args[0];
      if (t === 'pow') return { c: Math.pow(args[0].c, args[1].c), d: 0, q: args[0].d > 0, u: false };
      // any other function (a hash, dot, normalize): a phase value, but never of u_time itself
      if (args.some((a) => a.d > 0)) throw new Error(`u_time passes through ${t}()`);
      return { c: 1, d: 0, q: false, u: true };
    }
    return lookup(t);
  }
  function product() {
    let v = primary();
    while (peek() === '*' || peek() === '/') {
      const op = take();
      const w = primary();
      if (op === '*') {
        if ((v.d > 0 && w.u) || (w.d > 0 && v.u)) throw new Error('an unresolved factor multiplies u_time');
        const q = v.q || w.q || (v.d > 0 && w.d > 0);
        v = { c: v.c * w.c, d: v.d * w.c + v.c * w.d, q, u: v.u || w.u };
      } else { // division by a literal or a constant: the bound shrinks, never grows past it
        const den = w.c === 0 ? 1 : w.c;
        v = { c: v.c / den, d: v.d / den, q: v.q || w.q || w.d > 0, u: v.u || w.u };
      }
    }
    return v;
  }
  function sum() {
    let v = product();
    while (peek() === '+' || peek() === '-') {
      take();
      const w = product();
      v = { c: v.c + w.c, d: v.d + w.d, q: v.q || w.q, u: v.u || w.u };
    }
    return v;
  }
  const v = sum();
  if (i !== tokens.length) throw new Error(`trailing tokens: ${tokens.slice(i).join(' ')}`);
  return v;
}

// ---------------------------------------------------------------- shader text scan
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

// uniform defaults, constants and local float assignments, by name (the last wins; all are bounds)
function buildEnv(src) {
  const env = new Map();
  for (const m of src.matchAll(/\buniform\s+float\s+([A-Za-z_]\w*)\s*=\s*([-\d.eE+]+)\s*;/g)) env.set(m[1], Number(m[2]));
  for (const m of src.matchAll(/\bconst\s+float\s+([A-Za-z_]\w*)\s*=\s*([-\d.eE+]+)\s*;/g)) env.set(m[1], Number(m[2]));
  for (const m of src.matchAll(/\bfloat\s+([A-Za-z_]\w*)\s*=\s*([^;]+);/g)) {
    if (!env.has(m[1])) env.set(m[1], m[2].trim());
  }
  return env;
}

// every sin( ... ) and cos( ... ) call whose argument mentions u_time, with its balanced argument text
function periodicTerms(src) {
  const out = [];
  const re = /\b(sin|cos)\s*\(/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    let depth = 1;
    let j = re.lastIndex;
    while (j < src.length && depth > 0) {
      if (src[j] === '(') depth++;
      else if (src[j] === ')') depth--;
      j++;
    }
    const arg = src.slice(re.lastIndex, j - 1);
    if (/\bu_time\b/.test(arg)) out.push(arg.replace(/\s+/g, ' ').trim());
  }
  return out;
}

function analyse(srcRaw, expect) {
  const src = stripComments(srcRaw);
  const env = buildEnv(src);
  const terms = [];
  let ok = true;
  const problems = [];
  for (const arg of periodicTerms(src)) {
    let rate;
    try {
      const v = parseExpr(tokenize(arg), env);
      rate = v.d;
      if (v.q) { ok = false; problems.push(`non-linear u_time term: ${arg}`); }
    } catch (e) {
      ok = false;
      problems.push(`${e.message} in "${arg}"`);
      terms.push({ expr: arg, rate: null, hz: null });
      continue;
    }
    const hz = rate / TWO_PI;
    terms.push({ expr: arg, rate, hz });
    if (!(hz <= CEILING)) { ok = false; problems.push(`${hz.toFixed(4)} Hz over the ${CEILING} Hz ceiling in "${arg}"`); }
  }
  const crateMax = env.has(expect.crateConst) ? env.get(expect.crateConst) : null;
  // the literal band top, wherever the shader writes it (a constant, or a mix() argument)
  const literalSynced = expect.crateLiteralIn(src, env) === CRATE_MAX_EXPECTED;
  if (!literalSynced) { ok = false; problems.push(`crate literal is not ${CRATE_MAX_EXPECTED}`); }
  const top = terms.reduce((a, t) => (t.hz !== null && t.hz > a ? t.hz : a), 0);
  return { env, terms, ok, problems, crateMax, literalSynced, top };
}

// ---------------------------------------------------------------- the two guards
const LEAF = {
  file: 'engine/stalag/shaders/stalag_leaf.gdshader',
  crateConst: 'LEAF_CRATE_MAX',
  crateLiteralIn: (src) => { const m = src.match(/\bconst\s+float\s+LEAF_CRATE_MAX\s*=\s*([\d.]+)\s*;/); return m ? Number(m[1]) : null; },
};
const SHRUB = {
  file: 'engine/stalag/shaders/stalag_shrub.gdshader',
  crateConst: null,
  crateLiteralIn: (src) => { const m = src.match(/\bfloat\s+crate\s*=\s*mix\(\s*[\d.]+\s*,\s*([\d.]+)\s*,/); return m ? Number(m[1]) : null; },
};

function replaceOnce(src, a, b) {
  if (!src.includes(a)) throw new Error(`control target not found: ${a}`);
  return src.replace(a, b);
}

function controls(kind, src) {
  const out = [];
  const run = (name, mutate, expectProblem) => {
    const text = mutate(src);
    const r = analyse(text, kind === 'leaf' ? LEAF : SHRUB);
    out.push({ name, ok: r.ok === false && r.problems.some((p) => expectProblem.test(p)), caught: r.problems.slice(0, 2) });
  };
  if (kind === 'leaf') {
    // the 0.359 Hz case: 1.96 rad/s times the 1.15 band top, over the ceiling
    run('coef_bump', (s) => replaceOnce(s, 'uniform float u_leaf_w = 1.4;', 'uniform float u_leaf_w = 1.96;'), /Hz over/);
    run('extra_term', (s) => replaceOnce(s, 'float gust_floor =', 'float zz_extra = sin(u_time * 3.0 + lph);\n\tfloat gust_floor ='), /Hz over/);
    run('literal_drift', (s) => replaceOnce(s, 'const float LEAF_CRATE_MAX = 1.15;', 'const float LEAF_CRATE_MAX = 1.6;'), /crate literal|Hz over/);
    run('reordered_chain', (s) => replaceOnce(replaceOnce(s, 'uniform float u_leaf_w = 1.4;', 'uniform float u_leaf_w = 1.96;'),
      'sin(u_time * u_leaf_w * crate + lph)', 'sin(crate * u_leaf_w * u_time + lph)'), /Hz over/);
  } else {
    run('coef_bump', (s) => replaceOnce(s, 'sin(u_time * 0.943 * crate + cph)', 'sin(u_time * 1.96 * crate + cph)'), /Hz over/);
    run('extra_term', (s) => replaceOnce(s, 'float flutter = ', 'float zz_extra = sin(u_time * 3.0 + cph);\n\tfloat flutter = '), /Hz over/);
    run('literal_drift', (s) => replaceOnce(s, 'mix(0.85, 1.15, cseed)', 'mix(0.85, 1.6, cseed)'), /crate literal|Hz over/);
    run('reordered_chain', (s) => replaceOnce(s, 'sin(u_time * 0.943 * crate + cph)', 'sin(crate * 1.96 * u_time + cph)'), /Hz over/);
  }
  return out;
}

function guard(kind) {
  const spec = kind === 'leaf' ? LEAF : SHRUB;
  const src = readFileSync(join(root, spec.file), 'utf8');
  const r = analyse(src, spec);
  const rec = {
    shader: spec.file, ceiling_hz: CEILING, crate_max: spec.crateLiteralIn(stripComments(src)),
    crate_literal_synced: r.literalSynced, top_hz: r.top,
    terms: r.terms.map((t) => ({ expr: t.expr, rate: t.rate, hz: t.hz })), ok: r.ok, problems: r.problems,
    neg: controls(kind, src),
  };
  if (kind === 'leaf') {
    rec.u_leaf_w = r.env.get('u_leaf_w') ?? null;
  } else {
    // the two flutter rates as the shader writes them (the literal right after u_time)
    const lit = (name) => { const m = stripComments(src).match(new RegExp(`${name}\\s*=\\s*sin\\(\\s*u_time\\s*\\*\\s*([\\d.]+)`)); return m ? Number(m[1]) : null; };
    rec.a_rate = lit('float flutter_a');
    rec.b_rate = lit('float flutter_b');
  }
  return rec;
}

console.log(JSON.stringify({ leaf_guard: guard('leaf'), shrub_guard: guard('shrub') }));
