# Requirements: Compile-Time Reflection for House Rules

Status: input to Hemera's (work-in-progress) reflection API. Not a finished design.

SlopOS enforces its project rules with `#run` code that reflects over packages
(`../decisions/0007-house-rules-compile-time-checks.md`). This file lists what those checks
need from the API, with sketches of the first two checks. All API names below are guesses
meant to show the *shape* of what's needed.

## Requirements

| # | Need | Used by |
|---|---|---|
| R1 | Get a package's info from an import alias or name (`package_info(arch)`) | all checks |
| R2 | List a package's declarations: functions (with `FunctionInfo`), types, constants | arch interface |
| R3 | Compare two function signatures exactly: parameter names and types, defaults, return values, generic parameters. Types compared with alias/`distinct` semantics (`types_are_aliases` exists) | arch interface |
| R4 | List a package's imports, directly and transitively | tiers |
| R5 | Read the value of a package-level constant at compile time | tiers (tier declaration) |
| R6 | Report a compile error from `#run` with a source location, and keep going so all violations are reported, not just the first | all checks |
| R7 | Run a check after the whole program has been type checked (so every package is visible) | all checks |
| R8 | `offset_of` alongside `size_of`/`align_of`, for spec-conformance asserts on hardware structs | layout checks |
| R9 | (Later) Which functions a function calls, and which types its body uses | future rules below |

The build proposal (`build-programs.md`) reuses R1/R2/R5 to discover program packages, and
proposes that build code observe each target's type-checked program, which is where these
checks would hook in.

`base/compiler/function.hsc` (`FunctionInfo`, `FunctionParameter`) and
`base/compiler/types.hsc` (`TypeInfo*`) already have most of the shape needed for R2/R3.

## Sketch 1: Arch Interface

The interface is a package of bodiless declarations, the same form `base` uses for intrinsics:

```
package arch_interface

map_page : fn(
    space: ptr[mut AddressSpace],
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    protection: Protection,
) -> Result[void, MapError] : ---

enable_interrupts  : fn() : ---
disable_interrupts : fn() -> (were_enabled: bool) : ---
// ...
```

The kernel selects an implementation and checks it:

```
#if TARGET_ARCH == .x86_64 {
    import x86_64 as arch from "../arch"
}

#run check_implements(package_info(arch), package_info(arch_interface))   //HEMERA(guess): package_info
```

The check:

```
package checks

import compiler from "base"

check_implements :: fn(implementation, interface: compiler.PackageInfo) -> bool {  //HEMERA(guess): PackageInfo
    with {
        all_found : bool = true
    }
    for required in interface.functions {
        candidate : compiler.FunctionInfo? = find_function(implementation, required.name)
        if is_none(candidate) {                                     //HEMERA(guess): is_none usage
            compiler.report_error(required.location,                 //HEMERA(guess): R6
                "% does not implement %", implementation.name, required.name)
            all_found = false
            continue
        }
        if !signatures_match(candidate or_else required, required) {
            compiler.report_error(candidate.location,
                "%.% does not match the signature in %",
                implementation.name, required.name, interface.name)
            all_found = false
        }
    }
    return all_found
}
```

## Sketch 2: `std` Tiers

Each `std_proposal` package declares its tier as a constant, which a check can read (R5).
The `Tier` enum lives in a tiny freestanding package with no imports of its own:

```
package tiers

Tier :: enum {
    Freestanding,   // needs only base
    Allocating,     // needs an Allocator in context
    Os,             // needs system calls
}
```

```
package atomic

import tiers from "std"

PACKAGE_TIER :: tiers.Tier.Freestanding
```

The check walks the import graph (R4) and rejects any import of a higher tier:

```
check_tier :: fn(root: compiler.PackageInfo, allowed: tiers.Tier) -> bool {
    with {
        ok : bool = true
    }
    for imported in transitive_imports(root) {                      //HEMERA(guess): R4
        tier :: package_tier(imported)                              // reads PACKAGE_TIER (R5)
        if tier > allowed {                                         //HEMERA(guess): enum ordering
            compiler.report_error(import_location(root, imported),
                "% imports % (tier %), but only tier % is allowed",
                root.name, imported.name, tier, allowed)
            ok = false
        }
    }
    return ok
}

// In the kernel's build:
#run check_tier(package_info(kernel), .Allocating)
```

A package with no `PACKAGE_TIER` is an error too, so new packages can't skip it.

**Open:** packages *inside* `std_proposal` must also respect tiers (a freestanding package
mustn't import an allocating one). The same check, run over every `std_proposal` package with
its own declared tier, covers that.

## Future House Rules (needing R9)

Candidates, once function-level reflection exists:

- **No floating point in the kernel:** no `f16`/`f32`/`f64`/complex/quaternion types in
  kernel package function bodies (the kernel is built without SIMD state).
- **Interrupt handlers don't allocate:** nothing reachable from an interrupt handler calls an
  allocator.
- **Every hardware struct has a layout assert:** any `#packed` struct in an `arch`/driver
  package must have a matching `size_of` check.
- **No `rawptr` outside allow-listed packages:** keeps unchecked pointers in the few places
  that need them.
- **Errors are not ignored:** no `_` for a `Result` return value in kernel code.
