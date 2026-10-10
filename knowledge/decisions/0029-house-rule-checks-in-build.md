# 0029: House-Rule Checks Run on Every Target, Registered by the Build

Status: proposed
Date: 2026-10-09
Related: `0007` (checks, not conventions), `0028` (build package),
`../hemera-proposals/reflection-checks.md`

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
  to the build package's types. The tier check compares enum member names
  (`../hemera-proposals/reflection-checks.md`, N2).
- **Checks report every problem** with `compiler.report_error` at the most specific location
  available (an import, a function, a constant) and return `false`; they never stop at the first.
- **The tier rule is checked per import edge** across the whole program: no package imports a
  higher tier than its own, and packages outside `std` take the target's tier. That implies the
  transitive rule without walking import chains.
- **The arch-interface rule is generic:** any package imported as `arch` must implement the
  program's `arch_interface` package.

## Alternatives considered
- **`#run` calls in the checked packages:** values have the right types, but each package must
  remember to call its checks, which is exactly the kind of convention `0007` set out to replace.
- **Both, per rule:** two mechanisms to explain, for a type problem a small `std` helper solves.

## Consequences
- Adding a rule means adding a function to the checks package and calling it from
  `check_program`.
- The tier check relies on `type_info_of` returning a pointer and on `std`'s
  `reflection.enum_member_name` (N1, N2). Both are declared; the helper's body is still to
  write in Hemera's `std/reflection` (`0030`).
- Checks only run once the compiler executes registered checks; until then they document intent,
  as `0007` says.
