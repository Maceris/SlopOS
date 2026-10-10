# 0007: House Rules Are Enforced by Compile-Time Reflection

Status: accepted
Date: 2026-10-01

## Context
Several project rules need enforcement the language doesn't provide directly: every
`arch/*` package must implement the same interface (Hemera has no `implements`), the kernel
must only use `std` packages that work without an OS, and more will follow. Hemera's
direction, like Jai's, is to enforce "house rules" with compile-time execution that
reflects over the program, rather than adding a language feature per rule. Package
reflection is planned (at compile time, and likely at runtime via exported type
information), and the API for it is a work in progress.

## Decision
- Project standards are checked by `#run` code that reflects over packages and reports
  compile errors. They are not left as conventions in comments.
- **Arch interface:** an `arch_interface` package declares the required functions (bodiless
  `---` declarations, as `base` does for intrinsics). A check verifies that the selected
  `arch/*` package defines every one with an identical signature.
- **`std` tiers:** each `std` package declares its tier as a compile-time constant.
  A check verifies that nothing imports a package from a higher tier than it allows (e.g.
  the kernel only uses freestanding and allocating packages).
- Checks live together in one package (location decided with the package structure) and
  run as part of the build.
- Until the reflection API exists, checks are written against the API we expect, marked
  `//HEMERA(guess)`. Our needs are listed in `../hemera-proposals/reflection-checks.md` as
  input to that API's design.

## Alternatives considered
- **Language feature (`implements`, package signatures):** compile-time safe, but one feature
  per rule doesn't scale to house rules generally.
- **Struct of function pointers:** works today, but adds runtime indirection on kernel hot paths.
- **Comments and code review only:** no enforcement.

## Consequences
- New project rules should be written as checks where possible, not just documented.
- SlopOS becomes a heavy user of the reflection API, which is useful pressure on its design.
- Checks can't run until compile-time execution works; until then they document intent.
