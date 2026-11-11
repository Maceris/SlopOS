# 0190: Pure f32, Fast and Vector Float Math

Status: accepted, chosen with the project's owner; to be built as Linear Algebra's L5, before M13's 13e
Date: 2026-11-11

## Context

0189's L1 built `std/math` from fdlibm's f64 functions, and an f32 function as the f64 one widened and rounded back:
within 1 ulp, but doing 53 bits' work for 24. Every function is scalar and branches on its argument's bits, so none
works on `vector[T, n]`, and a loop over them doesn't vectorize. A ray tracer's hot path is already SIMD (the
operators, `square_root`, `fused_multiply_add`, `minimum`, `maximum` and the roundings work lane by lane), but its
shading and sampling call `sin`, `cos`, `exp`, `log`, `pow`, `atan2` and `acos` per ray per bounce, and those would
be scalar and slow.

## Decision

- **Pure f32:** `std/math`'s f32 functions work in f32 alone, still within 1 ulp each (as musl's and CORE-MATH's f32
  functions are), with their own reductions and shorter polynomials. f64's stay fdlibm's.
- **Lane by lane:** the same functions, by the same names, take `vector[f32, n]` and `vector[f64, n]`: branch-free
  kernels (a reduction exact over the usual range, a polynomial with fused multiply-adds, special cases chosen with
  `select`), with any lane outside the fast range done again through the exact scalar path, so results are the same
  as the scalar functions' bound says.
- **Fast math:** `std/math/fast`, the same functions, for scalars and vectors of f32 and f64, documented as less
  precise: within about 3.5 ulp each, each function's bound stated, trading accuracy for fewer operations.
- **Measured:** `perf_tests` measures each tier, so speed is known, not guessed; the reference tests hold every
  function to its stated bound.

## Alternatives considered

- **Keeping f32 through f64:** accurate, but slower than it needs to be, and no help for vectors.
- **Only a fast tier for f32:** lost; f32 code that wants exact results shouldn't need f64 for them.
- **Linking SLEEF or a vendor library:** lost on rule 6 (written in Hemera, the same bits everywhere).

## Consequences

- `std/math` grows a second set of kernels, f32's, and vector forms of both; `std/math/fast` a third.
- Graphics code in Hemera can shade and sample in `vector[f32, 8]` without a scalar call per lane.
- Results stay the same on every target: the kernels are Hemera, and fused multiply-adds have their software path.
