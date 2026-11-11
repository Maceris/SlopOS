# Proposal: Float Math and Linear Algebra

Status: **decided** 2026-11-10 (`../decisions/0189`), to be built. For M15's canvas and compositor
(`../design/display.md` §6), fonts, and graphics programs written in Hemera (a ray tracer, Vulkan programs through
`vendor/vulkan`). Once in Hemera, its docs are the reference and this proposal is removed.

## 1. What Hemera Has

- **Complex numbers and quaternions are built in** (`docs/types.md`, *Complex Numbers and Quaternions*): `c32` to
  `c128` and `q64` to `q256`, literals like `1 + 2i + 3j + 4k`, `+ - * /` (the Hamilton product), `conj`, `abs`,
  `real`, `imag`, `jmag`, `kmag`, and a quaternion's fields `x y z w`, settable, with `xyz` its vector part as an
  `f32[3]` or `f64[3]`.
- **`vector[T, n]`** (*Vectors*) is SIMD: power-of-two lane counts, aligned to its size, lane-wise operators and
  comparisons, `splat`, `select`, `rotate_lanes`, `reduce_*`, lanes read by a constant index.
- **Floats:** `intrinsics.square_root` and nothing else (no `floor`, `sin`, `exp`...); exact shortest printing
  (`base/runtime/format.hsc`), no parsing.
- **No matrices**, though `docs/operators.md` and `docs/faq.md` list matrices among the operators' types: the docs
  promise what §4 would make true (or the mention goes).
- **Missing for graphics:** a three-element vector (no `vector[f32, 3]`), swizzles, `dot`, `cross`, `normalize`,
  matrix products, rotations.

## 2. Float Math (`std`, no language change)

- **Compiler intrinsics** for the exact operations a CPU does in one instruction: `floor`, `ceil`, `trunc`,
  `round_even`, `fused_multiply_add`, `minimum` and `maximum` (with NaN defined), `copy_sign`, on floats and float
  vectors, and `square_root` on vectors too. `roundsd`/`vfmadd` where the target has SSE4.1 and FMA, `frint*`/`fmadd`
  on AArch64, bit arithmetic otherwise. Never LLVM's `llvm.sin`, `llvm.exp` and the like, which become libm calls.
- **`std/math`**, freestanding, generic over `f32` and `f64`: constants, classification, `frexp`/`ldexp`,
  `next_up`/`next_down`, `ulp`, remainders, `cbrt`, `hypot`, `exp`, `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p`,
  `pow`, `sin`, `cos`, `tan`, `sin_cos`, the inverses and `atan2`, the hyperbolics, `erf`, `erfc`, `erf_inverse`,
  `gamma`, `log_gamma`.
- **Algorithms** from musl and FreeBSD's msun (fdlibm), at most 1 ulp, cited with `//SPEC:`; written in Hemera, not
  linked (rule 6), so results are the same on every OS and architecture. CORE-MATH's correctly rounded versions can
  replace single functions later.
- **Float parsing**, correctly rounded: Eisel–Lemire, with an exact fallback on `format.hsc`'s wide integers.
- **Tests:** every `f32` input for the one-argument functions, against `f64` rounded; random and known-hard `f64`
  inputs, each function's ulp bound stated; parse and print round-tripping exactly.

## 3. Arithmetic and Swizzles on Fixed Arrays (language)

A fixed array of numbers is the vector type of graphics: any length (3 included), laid out as its elements with
their own alignment, so it matches C structs, vertex formats and Vulkan's structs. `vector[T, n]` stays the explicitly
SIMD type; the compiler can use vector instructions for array arithmetic where it pays.

```
position : f32[3] = f32.[1, 2, 3]
velocity := f32.[0.5, 0, -1]
next := position + velocity * 0.016     // element by element; a number goes with every element
colour : f32[4] = f32.[1, 0.5, 0, 1]
rgb := colour.rgb                        // an f32[3]
flipped := position.zyx
position.y = 10                          // one element, as position[1]
```

- **Operators:** `+ - * /` (and `%` on integers) element by element, on two arrays of the same type or an array and a
  number of its element type, which goes with every element; unary `-`. Any length, any number element type
  (integers, floats, complex numbers). `==` stays whole-array equality (*Equality*); lane-wise comparisons are what
  `vector` is for.
- **Swizzles** on arrays of 1 to 4 elements: `x y z w` and `r g b a`, one letter an element (settable), several a new
  array of those elements, in that order, letters repeatable (`v.xxy`), the two sets not mixed.
- **Assigning through a swizzle** with no repeated letter makes it the list of its elements in a multiple assignment
  (`docs/operators.md`), so `v.xy = ...` is `v.x, v.y = ...`: the right side is an array of that many elements
  (stored element by element), that many values (`v.xy = 1, 2`), a call giving that many results
  (`v.xy = returns_two_f32s()`), or one number for every element, as `a, b = c` already does. The right side is
  evaluated before anything is stored, so `v.xy = v.yx` swaps; compound assignments (`v.xy += 1, 2`) follow the same
  rules. A swizzle with a repeated letter is a value only.

```
v : f32[4]
v.xy = f32.[1, 2]
v.zw = 3, 4
v.xz = returns_two_f32s()
v.xy = v.yx                 // swaps them
```
- **Distinct aliases keep it:** `Point3 :: distinct alias f32[3]` and `Vector3 :: distinct alias f32[3]` take the
  operators among themselves, and mixing them needs a cast, so `Point3 - Point3` can't silently be a `Point3` but
  the library can say what it is.
- **Quaternions agree:** their `xyz` is already an `f32[3]`, so `q.xyz * 2` works with no special case.
- Element-wise integer division by an element of 0 panics, as a single division does.

## 4. Matrices (language)

```
Transform :: matrix[f32, 4, 4]                          // rows, columns
m := Transform.{
    1, 0, 0, tx,
    0, 1, 0, ty,                                        // written row by row, as on paper
    0, 0, 1, tz,
    0, 0, 0, 1,
}
moved := m * f32.[x, y, z, 1]                           // matrix times a column: an f32[4]
both := projection * view * m                           // matrix product
m[0, 3] = 5                                             // row, column
```

- `matrix[T, rows, columns]`, `T` a float or integer, 1 to 4 rows and columns. Stored **column-major**, as GLSL,
  SPIR-V, Vulkan and Odin store them, so a `matrix[f32, 4, 4]` is uploaded as it is; literals are still written row
  by row.
- **Operators:** `+ -` element by element; `*` the matrix product (`R×K` times `K×C`), a matrix times an array of its
  column count (a column vector), an array times a matrix (a row vector), or a number times every element.
- **Elements** by `m[row, column]` only, proven in bounds as any index; a column by itself can be added later.
- **Builtins:** `transpose(m)`, `identity[M]()`, and casts between a matrix and the `T[rows * columns]` of its
  storage. Determinants and inverses are library code (§5), being numerics rather than structure.
- std140's padding (a `mat3`'s columns 16 bytes apart) isn't the matrix's layout; the library converts.

## 5. `std/linear_algebra` (after §2–§4)

- On arrays: `dot`, `cross`, `length`, `length_squared`, `normalize`, `distance`, `lerp`, element-wise `minimum`,
  `maximum`, `clamp`, `absolute`, `reflect`, `refract`, `face_forward`.
- On quaternions: `from_axis_angle`, `rotate` (a vector), `slerp`, `to_matrix`, `from_matrix`, `from_euler`.
- On matrices: `determinant`, `inverse` (with its failure for a singular matrix), `outer_product`, and the
  transforms: `translation`, `scaling`, `rotation`, `look_at`, `perspective` and `orthographic` in Vulkan's
  convention (depth 0 to 1, y down), with OpenGL's as separate functions.
- Element-wise versions of `std/math`'s functions on arrays and vectors.

## 6. Decided (`../decisions/0189`)

- **Arrays are the vector type**, with operators at any length and swizzles on 1 to 4 elements (§3).
- **Matrices are built in** (§4), indexed by `m[row, column]` only.
- **Swizzles without a repeated letter are assignable** (§3), through multiple assignment; reopened if that proves
  hard in the compiler.

## 7. Order

1. The float intrinsics in the compiler (§2), then `std/math` and float parsing, with their tests.
2. Alongside 1, once decided: array arithmetic and swizzles (§3), compiler front end and `docs/types.md`.
3. Matrices (§4), and `docs/operators.md` made true.
4. `std/linear_algebra` (§5), needing all of the above.
