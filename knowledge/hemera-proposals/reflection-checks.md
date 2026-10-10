# Requirements: Compile-Time Reflection for House Rules

Status: **adopted** into `base/compiler` (2026-10-05, rest 2026-10-09). `base/compiler/package.hsc`
(`PackageInfo`, `ImportInfo`, `ConstantInfo`, `TypeDeclaration`, `ProgramInfo`,
`package_info`, `find_constant`, `find_function`, `find_packages`),
`base/compiler/function.hsc` (`FunctionInfo`, `FunctionCall`, `TypeUse`),
`base/compiler/types.hsc` (`TypeInfo*`), `offset_of`/`type_info_of` in `base/builtin`,
`enum_member_name`/`equal` in `std/reflection` and `add_check`/`report_error` in
`base/compiler/build.hsc` are the reference. This document keeps what SlopOS's checks need
(`../decisions/0007-house-rules-compile-time-checks.md`,
`../decisions/0029-house-rule-checks-in-build.md`) and sketches of the first two checks against
the real API. Everything here is declared; what still needs the compiler or a body is noted
per row.

## Requirements

| # | Need | State |
|---|---|---|
| R1 | Get a package's info from an import alias or name | **Done**: `package_info(import_name: string) -> PackageInfo?` |
| R2 | List a package's functions, types and constants | **Done**: `PackageInfo.functions`, `.types`, `.constants`; `find_function`, `find_constant` |
| R3 | Compare two function signatures exactly | **Done**, written by the check: `FunctionInfo` has parameter names, types, defaults, `is_escaping`, `is_varargs`, return values and generic bindings. Defaults compare with `reflection.equal` (N4) |
| R4 | A package's imports, directly and transitively | **Done**: `PackageInfo.imports` (`ImportInfo` with canonical `path` and `location`); transitive by walking `ProgramInfo.packages`. Checking every edge in the program makes transitive walks unnecessary for tiers |
| R5 | Read a package-level constant at compile time | **Done**: `ConstantInfo.value: any`. Values come typed by the program they were evaluated in (N2) |
| R6 | Report an error with a location and keep going | **Done**: `report_error(location, format, ...)`, `report_warning` |
| R7 | Run a check once the whole program is type checked | **Done**: `add_check(CheckFunction)` gets each target's `ProgramInfo` |
| R8 | `offset_of` and struct layout in type info, for spec-conformance asserts | **Declared**: `offset_of(T, member)` in `builtin`; `StructMember.offset`; `TypeInfoStruct.alignment` (the `#align(n)` value, else natural), `.is_packed`, `.is_union`. Not yet filled in by the compiler |
| R9 | (Later) Which functions a function calls, and which types its body uses | **Declared**: `FunctionInfo.calls` (`FunctionCall`: package path, name, type, location; calls through function values have only the type) and `FunctionInfo.used_types` (`TypeUse`: each type at its first use). Not yet filled in by the compiler |

New needs found while rewriting the sketches against the real API:

| # | Need | Why | State |
|---|---|---|---|
| N1 | `type_info_of` should return `ptr[TypeInfo]`, not `TypeInfo` by value | Everywhere else (`StructMember.member_type`, `TypeInfoPointer.base_type`...) type info is a `ptr[TypeInfo]` cast to the variant struct (`TypeInfoEnum`, `TypeInfoStruct`). A by-value `TypeInfo` is only `variant` and `size`, so the variant's fields are unreachable. Probably an oversight | **Declared**: `type_info_of : fn[T](T: type) -> ptr[TypeInfo]` |
| N2 | Read a target's constant from a check defined in the build package | A `CheckFunction` lives in the build program, but `ConstantInfo.value` in a target's `ProgramInfo` has the *target's* types, and "a type from one doesn't exist in the other" (`TargetSetting`'s comment). So the tier check can't cast `PACKAGE_TIER` to its own `tiers.Tier`. Suggested: a `std` helper `reflection.enum_member_name(value: any) -> string?` (needs N1), so checks compare by name. Alternative: a compiler function converting a value to the same declaration (same package path and name, same layout) in the calling program. Also worth stating: `type` values from one target compare correctly *with each other* inside a check (the arch-interface check relies on it) | **Declared**: `reflection.enum_member_name(value: any) -> string?`, body still a TODO. `ConstantInfo`'s comment now states the cross-program rule, including that `type` values from one program compare correctly |
| N3 | A location for a package itself | "`atomic` has no `PACKAGE_TIER`" has nowhere to point. `PackageInfo` could carry its package statement's `SourceCodeLocation` (from the first file). Until then, checks build one from `files[0]`, line 1 | **Declared**: `PackageInfo.location` |
| N4 | Compare two `any` values for equality | Default parameter values are `any?`; R3 needs to compare them. A `std` `reflection.equal(a, b: any) -> bool` (deep for structs and arrays) would do | **Declared**: `reflection.equal(a, b: any) -> bool`, body still a TODO |
| N5 | Whether a function has a body | The arch interface is bodiless `---` declarations; an implementation that's also `---` should be rejected. `FunctionInfo` could carry `has_body` (or `is_declaration`) | **Declared**: `FunctionInfo.has_body` |

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

The kernel selects an implementation by importing it as `arch`:

```
#if TARGET_ARCH == .x86_64 {
    import x86_64 as arch from "../arch"                        //HEMERA(guess): import inside #if
}
```

The check runs on every target as part of `check_program` (Sketch 2), with nothing to wire
in the kernel: any package imported as `arch` must implement the `arch_interface` package
of the same program. It only compares the target's values with each other (`type` against
`type`), never with the build package's own types (N2).

```
package checks

import compiler from "base"
import reflection from "std"
import tiers from "std"

check_arch_interface :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    ok := true
    interface := package_named(program, "arch_interface") or_return true     // target has no arch layer
    for &importer in program.packages {
        for &edge in importer.imports {
            if edge.alias != "arch" {
                continue
            }
            implementation := package_at(program, edge.path) or_continue
            ok = check_implements(implementation, interface) && ok
        }
    }
    return ok
}

check_implements :: fn(implementation, interface: ptr[compiler.PackageInfo]) -> bool {
    all_found := true
    for &required in interface.functions {
        candidate := compiler.find_function(implementation, required.name)
        if candidate is_none {
            compiler.report_error(required.location,
                "% does not implement %", implementation.name, required.name)
            all_found = false
            continue
        }
        found := candidate or_else required^
        if !found.has_body {
            compiler.report_error(found.location,
                "%.% is a declaration, not an implementation", implementation.name, required.name)
            all_found = false
            continue
        }
        if !signatures_match(&found, required) {
            compiler.report_error(found.location,
                "%.% does not match the signature in %",
                implementation.name, required.name, interface.name)
            all_found = false
        }
    }
    return all_found
}

signatures_match :: fn(a, b: ptr[compiler.FunctionInfo]) -> bool {
    if a.parameters.count != b.parameters.count || a.return_values.count != b.return_values.count {
        return false
    }
    for &parameter, index in a.parameters {
        other := &b.parameters[index]
        if parameter.name != other.name
            || parameter.type_ != other.type_                   //HEMERA(guess): == on type values is exact (distinct types differ)
            || parameter.is_escaping != other.is_escaping
            || parameter.is_varargs != other.is_varargs
            || !reflection.equal(parameter.default_value, other.default_value) {
            return false
        }
    }
    for &result, index in a.return_values {
        other := &b.return_values[index]
        if result.type_ != other.type_ || result.name != other.name {
            return false
        }
    }
    return true
}
```

## Sketch 2: `std` Tiers

Each Hemera `std` package declares its tier as a constant. The `Tier` enum lives in a tiny
freestanding package with no imports of its own:

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

The check is registered once in the build package (`compiler.add_check(checks.check_program)`)
and runs on every target. Rather than walking transitive imports, it checks every import edge
in the program: no package imports a higher tier than its own. A package outside `std` gets
the target's tier: `Allocating` for the kernel (`OS == .None`), `Os` otherwise.

```
// Registered once by the build package: compiler.add_check(checks.check_program)
check_program :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    ok := check_tiers(target, program)
    ok = check_arch_interface(program) && ok
    return ok
}

check_tiers :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    ok := true
    for &importer in program.packages {
        declared := package_tier(target, importer)
        if declared is_none {
            compiler.report_error(importer.location,
                "% is in std but declares no PACKAGE_TIER", importer.name)
            ok = false
            continue
        }
        importer_tier := declared or_else .Freestanding
        for &edge in importer.imports {
            imported := package_at(program, edge.path) or_continue
            imported_tier := package_tier(target, imported) or_continue  // a missing tier is reported on that package's own turn
            if cast[uint](imported_tier) > cast[uint](importer_tier) {    //HEMERA(guess): enum to backing integer cast
                compiler.report_error(edge.location,
                    "% (tier %) imports % (tier %)",
                    importer.name, importer_tier, imported.name, imported_tier)
                ok = false
            }
        }
    }
    return ok
}

// The tier of a std package by its PACKAGE_TIER, or the target's tier for anything else.
package_tier :: fn(target: ptr[compiler.BuildOptions], package_: ptr[compiler.PackageInfo]) -> tiers.Tier? {
    if !is_std_package(target, package_) {
        if target.target_options.os == .None {
            return tiers.Tier.Allocating
        }
        return tiers.Tier.Os
    }
    constant := compiler.find_constant(package_, "PACKAGE_TIER")?
    // The value has the target's tiers.Tier type, not ours (N2), so compare by member name.
    name := reflection.enum_member_name(constant.value)?
    return tier_from_name(name)
}
```

`package_at` and `package_named` find a package in `program.packages` by canonical path or
by name; `is_std_package` compares the path against the target's `std` location in
`target.package_paths`, which the build package always sets (`../decisions/0028-build-package.md`).

The same check covers packages *inside* `std`: a freestanding package importing an
allocating one is just another edge.

## Future House Rules

Once the compiler fills in R8 and R9:

- **Every hardware struct has a layout assert** (R8 plus a way to find `#assert`s, or a
  convention like a `LAYOUT_CHECKED` constant): any `#packed` struct in an `arch`/driver
  package must have a matching `size_of` check.
- **No floating point in the kernel** (R9): no `f16`/`f32`/`f64`/complex/quaternion types in
  kernel package function bodies (the kernel is built without SIMD state). Signatures alone
  can already be checked with `FunctionInfo`.
- **Interrupt handlers don't allocate** (R9): nothing reachable from an interrupt handler
  calls an allocator.
- **No `rawptr` outside allow-listed packages** (R9 for bodies; signatures and struct members
  work today).
- **Errors are not ignored** (R9): no `_` for a `Result` return value in kernel code.
- **Programs never import other programs:** works today, from `ProgramInfo` and the
  `PROGRAM_KIND` constant (`build-programs.md`).
