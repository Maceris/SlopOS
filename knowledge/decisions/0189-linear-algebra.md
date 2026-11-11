# 0189: Linear Algebra in Hemera

Status: accepted; built 2026-11-11, L1 to L4, between M13's 13c and 13e (`../roadmap.md`, Linear Algebra)
Date: 2026-11-10

## Context

M15's canvas and compositor (`../design/display.md` §6), fonts, and graphics programs in Hemera need vectors,
matrices and float math. Hemera has complex numbers, quaternions and SIMD `vector[T, n]` built in, but no
three-element vector, no swizzles, no matrices (though `docs/operators.md` lists them) and no float functions beyond
`square_root`. The design was `../hemera-proposals/linear-algebra.md`, removed once built (As Built).

## Decision

- **Fixed arrays are the vector type.** `+ - * /` (and `%` on integers) work element by element on fixed arrays of
  numbers of any length, with a number going with every element; `vector[T, n]` stays the explicitly SIMD type.
  Distinct aliases of arrays keep the operators among themselves.
- **Swizzles** on arrays of 1 to 4 elements: `x y z w` or `r g b a`, the two sets not mixed. A swizzle with no
  repeated letter can be assigned to, as the list of its elements in a multiple assignment (`docs/operators.md`):
  `v.xy = f32.[1, 2]` (an array of that many elements, element by element), `v.xy = 1, 2`, and
  `v.xy = returns_two_f32s()`, with the right side evaluated before any element is stored, so `v.xy = v.yx` swaps.
  One with a repeated letter (`v.xxy`) is a value only.
- **A built-in `matrix[T, rows, columns]`**, 1 to 4 each, stored column-major, written row by row in literals, with
  `*` the matrix product (and matrix times array, array times matrix, number times matrix), `+ -` element by
  element, `transpose` and `identity` builtins.
- **Matrix elements by `m[row, column]` only**; a column by itself can be added later if it's missed.
- **Order:** float intrinsics and `std/math` (with float parsing) first; array arithmetic and swizzles alongside;
  then matrices; then `std/linear_algebra`.

## Alternatives considered

- **A separate small-vector type:** lost, since vertex formats and C structs are already arrays, and quaternions'
  `xyz` is already an array.
- **Operators only on arrays of 1–4 elements:** lost; nothing about longer arrays makes element-wise arithmetic
  wrong, and swizzles alone are limited to four.
- **A library matrix struct:** lost; with no operator overloading every product would be a function call, and
  complex numbers and quaternions are built in already.
- **`m[column]` giving a column, as GLSL:** deferred, to keep one way to index.
- **Multi-letter swizzles as values only:** lost; assigning through them reuses multiple assignment, so it costs the
  compiler little. Reopened if it turns out to.

## Consequences

- The compiler gains element-wise array operators, swizzle fields and assignment through them, and a matrix type;
  `docs/types.md` and `docs/operators.md` describe them, and the latter's mention of matrices becomes true.
- `std` gains `math` and `linear_algebra`, freestanding, written in Hemera rather than linked (CLAUDE.md, rule 6).
- A struct, parameter or local can be `f32[3]` and do arithmetic, so graphics code reads like GLSL.

## As Built
Built 2026-11-11, L1 to L4, in Hemera; Hemera's docs are now the reference (`docs/types.md`, Floats, Arrays as Vectors
and Matrices; `docs/operators.md`), and the proposal is removed, as it said it would be.
- **L1, float intrinsics:** `floor`, `ceil`, `trunc`, `round_even`, `fused_multiply_add`, `minimum`, `maximum` (IEEE
  754-2019's: a NaN wins, -0 below +0), `copy_sign`, and `square_root` on vectors, typed from their first argument as
  the vector functions are. Beyond the plan, `leading_zeros`, `trailing_zeros` and `count_ones`, which the software
  fallbacks and parsing needed. Instructions where the target has them; on an x86 CPU without SSE4.1, rounding by adding
  and taking away 2^p; without FMA, `runtime.fused_multiply_add_f64` and `_f32`, from musl, lane by lane. **Found:**
  musl's `fma` gives +0 where a product underflows to -0 and z is +0; the port keeps the exact result's sign.
- **L1, `std/math`:** the f64 functions are fdlibm's, as FreeBSD's msun and musl carry them (musl's own `exp`, `log` and
  `pow` are ARM's table-driven ones; fdlibm's were taken instead, needing no tables), each with `//SPEC:`, its
  constants checked against fdlibm's hex for them. Names in Hemera's style: `exp_minus_one`, `log_one_plus`, `power`,
  `cube_root`, `hypotenuse`, `truncated_remainder` (fmod), `fraction_and_exponent` (frexp), `scale_by_power_of_two`.
  `erf_inverse` is Giles' guess refined by Halley's method on `erf` and `erfc`. **Deviation:** an f32 function works in
  f64 and rounds once, rather than ports of musl's f32 code: within 1 ulp and nearly always correctly rounded, at the
  cost of speed. So the plan's every-f32-input test would only test the rounding; random f32 inputs are checked
  against the f64 functions instead.
- **L1, accuracy, measured:** against 4,238 references worked out with Python's `decimal` and `fractions` (the
  scenario's `make_references.py`), every function is within 1 ulp but `atanh` (1.5), `erfc` far in its tail (2),
  `erf_inverse` (2) and `gamma` (6), and `log_gamma` within ulp(1) where it's below 1, near its zeros; each one's docs
  say so. Python's own `lgamma` turned out 8 to 74 ulp off near its zeros, where the references are right.
- **L1, parsing:** `math.parse[F](text)`, correctly rounded: Clinger's exact cases, Eisel-Lemire over 696 128-bit powers
  of ten (`std/math/_generator/make_powers_of_ten.py`), and Go's exact decimal shifting for what's left, 800 digits
  kept and the rest a sticky flag. 1,317 cases, halfway points between f64s and f32s written out exactly, and a hair
  either side, among them.
- **L2, arrays as vectors:** as decided. Element-wise code is unrolled up to 16 elements and a loop beyond. A swizzle
  assigned through is recorded by the checker (`CheckedBody::swizzle_targets`), and the generator stores each element
  where the swizzle's letters say, after everything on the right is worked out. `&v.xy` and a repeated letter are
  refused as a place.
- **L3, matrices:** a type of its own (`TypeInfoVariant::MATRIX`, `compiler.TypeInfoMatrix`, schema kind 19, after
  VOID so the kinds before keep their numbers), the same LLVM type as the array of its elements, so the casts either
  way change nothing. `m[row, column]` has each index proven in bounds by the bounds pass. **Deviation:** the identity
  is `identity(M)`, taking its type as `size_of(T)` and `max_value(T)` do, as no builtin takes `[...]` arguments; and
  `transpose(m)`. `std/testing` draws matrices, `std/schema` reads them.
- **Generic inference, found on the way:** a generic couldn't bind `T` and `n` from an argument for `T[n]`, which
  `std/linear_algebra` needs (in a type, `T[n]` parses as `T` given `n`), nor a matrix's rows and columns; both bind
  now. And a derived parameter was bound from an argument of its type, against its docs ("nothing binds it from
  arguments"), so `slerp(a, b, 0.5)` made T an f64; it's worked out only, now.
- **L4, `std/linear_algebra`:** on arrays of any length, `dot`, `cross`, `length`, `length_squared`, `normalize` (a zero
  array stays zero), `distance`, `lerp`, `minimum`, `maximum`, `clamp`, `absolute`, `reflect`, `refract`,
  `face_forward`, and `map` and `map_pairs` for std/math's functions element by element. Quaternions, the type
  worked out from the parts' (`quaternion_of`, `part_of`, derived parameters): `from_axis_angle`, `rotate`, `slerp`,
  `to_matrix`, `from_matrix` (Shepperd's), `from_euler` (roll about z, then pitch about x, then yaw about y, about the
  world's axes). Matrices: `determinant`, `inverse` (none for a singular one), `outer_product`, and `translation`,
  `scaling`, `rotation`, `look_at`, `perspective` and `orthographic` in Vulkan's conventions (depth 0 to 1, y down,
  looking down -z), `perspective_opengl` and `orthographic_opengl` beside them.
- **Not built:** std/math's functions on `vector[T, n]` lane by lane; `map` takes arrays only.
