# 0189: Linear Algebra in Hemera

Status: accepted
Date: 2026-11-10

## Context

M15's canvas and compositor (`../design/display.md` §6), fonts, and graphics programs in Hemera need vectors,
matrices and float math. Hemera has complex numbers, quaternions and SIMD `vector[T, n]` built in, but no
three-element vector, no swizzles, no matrices (though `docs/operators.md` lists them) and no float functions beyond
`square_root`. The design is `../hemera-proposals/linear-algebra.md`.

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
