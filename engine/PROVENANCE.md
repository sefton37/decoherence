# Provenance of numeric constants (Spec #517 A2)

Standing rule: every algorithm in the engine, the spike and the tools is written from first
principles or from a documented public-domain source. This file is the registry the
definition-of-done checks read. Every long numeric literal (hex of seven or more digits,
integers of ten or more digits, decimals with fifteen or more fraction digits) in the scoped
source set must appear below with where it is used, where it comes from, and its licence.
Adding such a literal without a row here fails DOD-30; a row naming a restrictive licence
fails DOD-31.

Where a row says "lineage from the implementer's recollection", the claim is the implementer's
and is for the auditor to re-check. In every such row the entry is a number only: no code was
taken from the named source.

| literal | where | source | licence |
| --- | --- | --- | --- |
| `0x7feb352d` | `lowbias32` in `stalag_det.h`, the two spike hashes, `proto_subst.mjs`, `stalag_water.gdshader` | Chris Wellons, "Prospecting for Hash Functions", nullprogram.com/blog/2018/07/31 (first multiplier of lowbias32) | public domain (dedication on the post, hash-prospector repository carries the Unlicense) |
| `0x846ca68b` | same five definitions | same post (second multiplier of lowbias32) | public domain, as above |
| `2654435761` | `hash2` input combine (engine, spike, oracle copy) | the prototype's `worldgen.js` hash2; equals 0x9E3779B1, the golden-ratio prime used in Knuth-style multiplicative hashing (lineage from the implementer's recollection) | a number; no code taken |
| `1234567891` | `hash2` input combine (engine, spike, oracle copy) | the prototype's `worldgen.js` hash2 (a decimal digit run) | a number; no code taken |
| `4294967296` | divisor 2^32 turning a 32-bit hash into [0, 1) | arithmetic: two to the power 32 | mathematical constant |
| `2147483648` | 2^31, sign boundary in the GDScript spike's 32-bit conversion | arithmetic: two to the power 31 | mathematical constant |
| `0x80000000` | 2^31, same use | arithmetic | mathematical constant |
| `0x7fffffff` | mask of the low 31 bits when building test vectors | arithmetic | mathematical constant |
| `0xffffffff` | 32-bit mask (spike GDScript, PNG CRC in `bake_skin.mjs`) | arithmetic | mathematical constant |
| `0x100000000` | 2^32 in the GDScript spike | arithmetic | mathematical constant |
| `0x000fffff` | mask of the high-word mantissa bits of an IEEE double, test-vector builder | the IEEE 754 binary64 layout (20 mantissa bits in the high word) | format constant |
| `0x811c9dc5` | FNV-1a offset basis in the plan hash (`stalag_plan.cpp`) | Fowler/Noll/Vo hash, 32-bit offset basis; the prototype's `planHash` in `waterplan.js` uses the same | public domain (the FNV authors' dedication) |
| `0x01000193` | FNV-1a prime in the plan hash (`stalag_plan.cpp`) | Fowler/Noll/Vo hash, 32-bit prime | public domain |
| `0xedb88320` | CRC-32 polynomial (reflected) of the PNG writer in `bake_skin.mjs` | the PNG specification's CRC definition (ISO/IEC 15948, W3C) | format constant of the published PNG standard |
| `0x27d4eb2d` | `cell_hash` in `stalag_core.cpp`, the spike mesher copies | the prototype's `worldmesh.js` cellHash; the number also appears in integer-hash literature (Thomas Wang's 32-bit mixes; lineage from the implementer's recollection) | a number; no code taken |
| `0x165667b1` | `cell_hash`, same sites | the prototype's `worldmesh.js` cellHash; equals xxHash32 PRIME32_5 (lineage from the implementer's recollection) | a number; no code taken |
| `0x9e3779b1` | `cell_hash`, same sites | the prototype's `worldmesh.js` cellHash; equals the golden-ratio prime above | a number; no code taken |
| `0x85ebca6b` | `cell_hash`, same sites | the prototype's `worldmesh.js` cellHash; equals the first multiplier of the MurmurHash3 32-bit finalizer (Austin Appleby; lineage from the implementer's recollection) | public domain (the MurmurHash3 author's dedication) |
| `0xc2b2ae35` | `cell_hash`, same sites | the prototype's `worldmesh.js` cellHash; equals the second multiplier of the MurmurHash3 32-bit finalizer | public domain, as above |
| `0x1f83d9ab` | terrain noise seed salt in `stalag_core.cpp` and the spike | the prototype's `worldmesh.js`; equals SHA-256 initial hash word 6 (FIPS 180-4; lineage from the implementer's recollection) | a number from a public standard; no code taken |
| `0x5be0cd19` | terrain noise seed salt in `stalag_core.cpp` and the spike | the prototype's `worldmesh.js`; equals SHA-256 initial hash word 7 (FIPS 180-4) | a number from a public standard; no code taken |
| `1.4426950408889634` | `det_log2` (`stalag_det.h`, `proto_subst.mjs`) | 1 / ln 2, the base-2 conversion factor, correctly rounded to a double | mathematical constant |
| `1.4142135623730951` | `det_log2` mantissa split point | the square root of 2, correctly rounded to a double | mathematical constant |
| `2.2250738585072014` | smallest normal double (2.2250738585072014e-308) in the test-vector builder | IEEE 754 binary64 | format constant |
| `0.6366197723675814` | `TWO_OVER_PI` in `det_sin`/`det_cos` (`stalag_det.h`, `proto_subst.mjs`) | derived (Spec #517 A4.2): 2 / pi, correctly rounded to a double | mathematical constant |
| `1.570796325802803` | first piece of pi/2 (`CW_A`), split so that n times the piece is exact for small integers n | derived (A4.2): pi/2 truncated on a 26-bit grid | mathematical constant |
| `9.920935739593517e-10` | second piece of pi/2 (`CW_B`) | derived (A4.2): the next 26-bit slice of pi/2 | mathematical constant |
| `5.721188726109832e-18` | third piece of pi/2 (`CW_C`) | derived (A4.2): the remainder of pi/2 | mathematical constant |
| `1.5707963267948966` | pi/2 as one double (`PIO2`) in `det_atan2` | pi / 2, correctly rounded to a double | mathematical constant |
| `3.141592653589793` | pi as one double (`PI`) in `det_atan2` | pi, correctly rounded to a double | mathematical constant |
| `4.1887902047863905` | 4 pi / 3 as a double, a probe input in the test-vector builder | 4 pi / 3, correctly rounded | mathematical constant |
| `0.6931471805599453` | `LN2` in `det_pow` (`stalag_det.h`, `proto_subst.mjs`) | derived (Spec #545 Phase A): ln 2, correctly rounded to a double (the natural log of two, computed with a decimal arithmetic library at 80 digits) | mathematical constant |
| `0.6931471796706319` | `LN2_A` in `det_exp` (`stalag_det.h`, `proto_subst.mjs`) | derived (Spec #545 Phase A): ln 2 clipped to a 30-bit grid, so that k times it is exact for \|k\| < 2^23; pieces A + B + C sum to ln 2 | mathematical constant |
| `8.893134232496047` | `LN2_B` in `det_exp` (e-10 scaled piece) | derived (Spec #545 Phase A): the next 30-bit slice of ln 2 after `LN2_A` | mathematical constant |
| `6.390629507645039` | `LN2_C` in `det_exp` (e-19 scaled piece) | derived (Spec #545 Phase A): the remainder of ln 2 after A and B, as a double | mathematical constant |
| `709.782712893384` | overflow threshold of `det_exp` | derived (Spec #545 Phase A): ln of the largest double, rounded down to 12 digits; above it the result is infinity | mathematical constant |
| `0x5f3759df` | seed salt of the meadow patch mask in `place_flora_region` (`stalag_flora.cpp`) | the prototype's `foliage-placement.js` (tag prototype-final) valueNoise salt; the number also appears in fast-inverse-square-root literature (lineage from the implementer's recollection); used here only as a seed salt, no code taken | a number; no code taken |
