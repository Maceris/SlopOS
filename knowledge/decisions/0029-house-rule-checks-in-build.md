# 0029: House-Rule Checks Run on Every Target, Registered by the Build

Status: accepted (implemented 2026-10-16 in `src/checks`)
Date: 2026-10-09
Related: `0007` (checks, not conventions), `0028` (build package); Hemera's `base/compiler`

## Context
`0007` decided that house rules are `#run` code reflecting over packages, written against an
expected API until one existed. Hemera now has it: `compiler.add_check` registers a function
that runs on every target once it's type checked, receiving the target's `BuildOptions` and
its whole program (`ProgramInfo`: every package with its imports, functions, constants and
types), and `report_error` reports a problem at a location without stopping. Checks could
instead be `#run` calls placed in the checked code, as `0007`'s sketches assumed.

A catch: a check registered by the build package runs in the build program, and the build
package and each target are type checked separately, so a constant's value in a target (like
`PACKAGE_TIER`) has the *target's* `tiers.Tier` type, not the build's.

## Decision
- **Every house rule is a `CheckFunction`** in the checks package, called from one
  `check_program` that the build package registers once with `compiler.add_check`. Nothing in
  the checked code calls a check, so no package can skip one, and every target (kernel, user
  space, host tests) is checked.
- **Rules that depend on the target read it from `BuildOptions`**, for example the kernel's
  allowed `std` tier comes from `target_options.os == .None`.
- **Checks compare a target's values only with each other or by name**, never by casting them
  to the build package's types. The tier check compares enum member names (Hemera's
  `docs/compilation.md`, *Build Packages*: a target's values have its types, compared by name).
- **Checks report every problem** with `compiler.report_error` at the most specific location
  available (an import, a function, a constant) and return `false`; they never stop at the first.
- **The tier rule is checked per import edge** across the whole program: no package imports a
  higher tier than its own, and packages outside `std` take the target's tier. `base` counts as
  Freestanding, since a Freestanding package needs only `base`. A package is `std`'s when an
  import names it `from "std"` (or `"std/..."`). That implies the
  transitive rule without walking import chains.
- **The arch-interface rule is generic:** any package imported as `arch` must implement the
  program's `arch_interface` package: every bodiless function with the same signature (names,
  types, `#escaping`, varargs, results, never-returning), and a type of the same name for each
  empty struct `arch_interface` leaves to the architecture.
- **What an architecture doesn't implement yet, it lists** in a `NOT_YET_IMPLEMENTED` array of
  names (decided with the project author 2026-10-16, after `0005`'s listed gaps). Those may be
  missing; a listed name that's implemented, or that `arch_interface` doesn't declare, is an
  error, so the list can't go stale.

## Alternatives considered
- **`#run` calls in the checked packages:** values have the right types, but each package must
  remember to call its checks, which is exactly the kind of convention `0007` set out to replace.
- **Both, per rule:** two mechanisms to explain, for a type problem a small `std` helper solves.

## Consequences
- Adding a rule means adding a function to the checks package and calling it from
  `check_program`.
- The tier check relies on `type_info_of` returning a pointer and on `std`'s
  `reflection.enum_member_name` (N1, N2), both working since Phase 8, step 4a.
- Signatures are compared without parameters' default values, which reflection doesn't give yet.
- Rules waiting to be written, now that Hemera's reflection gives struct layouts (`offset_of`,
  `StructMember.offset`) and what a function's body calls and uses (`FunctionInfo.calls`,
  `used_types`), since 2026-10-16:
  - Every hardware struct has a layout assert: any `#packed` struct in an `arch` or driver
    package has a matching `size_of` check (or a convention like a `LAYOUT_CHECKED` constant).
  - No floating point in the kernel: no `f16`/`f32`/`f64`/complex/quaternion types in kernel
    function bodies, since the kernel is built without SIMD state.
  - Interrupt handlers don't allocate: nothing reachable from one calls an allocator.
  - No `rawptr` outside allow-listed packages.
  - Errors aren't ignored: no `_` for a `Result` in kernel code.
  - Programs never import other programs.
