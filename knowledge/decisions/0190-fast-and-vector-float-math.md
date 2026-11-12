# 0190: f32's Own, Fast and Vector Float Math

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

- **f32's own kernels:** `std/math`'s f32 functions take and give f32, still within 1 ulp each, with reductions and
  polynomials sized for 24 bits rather than fdlibm's 53. Inside, each works however reaches 1 ulp cheapest: mostly
  short f64 polynomials, as ARM's, musl's and CORE-MATH's f32 functions do, which cost about twice f32's instructions
  on a vector, less than carrying f32 pairs for the extra precision would. Asked and chosen 2026-11-11, after the
  owner first asked for pure f32: what made the old ones slow was fdlibm's 53-bit algorithms and their scalar
  branches, not f64 itself. f64's stay fdlibm's.
- **Lane by lane:** the same functions, by the same names, take `vector[f32, n]` and `vector[f64, n]`: branch-free
  kernels (a reduction exact over the usual range, a polynomial with fused multiply-adds, special cases chosen with
  `select`), with any lane outside the fast range done again through the exact scalar path, so results are the same
  as the scalar functions' bound says.
- **Fast math:** `std/math/fast`, the same functions, for scalars and vectors of f32 and f64, documented as less
  precise: within about 3.5 ulp each, each function's bound stated, trading accuracy for fewer operations; its f32
  functions are f32 throughout.
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

## As Built

Built 2026-11-11, in Hemera (`std/math`'s `lanes.hsc` and `lanes_64.hsc`, `std/math/fast`); `docs/types.md`, Floats
and Vectors, is the reference. Times are a value's, on the development machine built for x86-64-v3, from the
`float_math_speed` scenario; `test_perf` (`perf_tests.py`) reports sin, exp and log in each tier on SlopOS.
- **Compiler, on the way:** `#if` in a generic is worked out per instance (it had been shared by every instance);
  a generic binds `vector[T, n]`'s `T` and `n` from an argument; `cast` converts a vector lane by lane; and beside a
  vector, a value of its lanes' type goes in every lane, as a literal does. `math.float_kind(T)` lets each function
  choose its code by type.
- **f32's own kernels:** exp, exp2, exp_minus_one, log, log2, log10, log_one_plus, power, sin, cos, tan, asin, acos,
  atan, atan2, cube_root and hypotenuse, branch-free on f64 lanes with short polynomials, rare lanes redone by the f64
  function. Checked on every f32 (the `float_math_exhaustive` scenario, by hand), each within 0.51 ulp; power, atan2
  and hypotenuse within 0.51 on 2^28 pairs. On eight lanes 1.4 to 2.9 ns, against 4.7 to 5.4 through f64.
  **Deviation:** a scalar f32 runs the kernel on one lane, the same bits as eight, but no faster than through f64
  (3.9 to 8.9 ns); the gain is on vectors.
- **f64 on vectors:** every elementary function but the remainders, and erf and erfc, is fdlibm with every branch
  worked out in each lane and the lane's own chosen, so each lane gives the scalar function's bits exactly (a test
  holds a million random lanes to it); hyperbolics and erf build on the lane forms of exp, exp_minus_one, log and
  log_one_plus. **Found:** without AVX-512, x86-64 converts f64 to i64 a lane at a time, so the kernels convert
  through i32 lanes. Four lanes take from about one value's time (sin and cos, which work out both kernels) to half or
  less (log 2.8 ns against 4.6, power 11.5 against 30, cube_root, hypotenuse). gamma, log_gamma and erf_inverse work a
  lane at a time.
- **`std/math/fast`:** the same names. f32's kernels are f32 throughout, SLEEF's 3.5-ulp algorithms and coefficients
  (exp, exp2, log, log2, sin, cos, tan, asin, acos, atan, atan2, cube_root); checked on every f32, the worst are tan
  3.41, log2 3.13 and log 2.84 ulp, and on eight lanes they take 0.5 to 1.0 ns. f64's (exp, exp2, log, log2, sin, cos,
  asin, acos, atan, atan2) are SLEEF's shapes with series worked out for 53 bits (Taylor's, ln's in (m - 1)/(m + 1),
  and fdlibm's atan and asin on a reduced range), within 1.7 ulp of the exact references; on four lanes 1.5 to 2.5 ns.
  The rest are std/math's, each saying its bound. **Deviation:** a scalar f64 runs the kernel on one lane, which is no
  faster than std/math's (log slower, 6.0 against 4.6 ns); fast's gain in f64 is on vectors.
