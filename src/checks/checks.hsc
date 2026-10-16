/*
 * SlopOS's house rules (decisions/0007, 0029), run by the build package on every target once it's
 * checked: check_program, registered with compiler.add_check. Each rule reports every problem it
 * finds with compiler.report_error, at the most specific place, and returns false if it found any.
 *
 * A target's values have the target's types, not this package's, so they're compared by name
 * (reflection.enum_member_name), never cast (decisions/0029).
 */
package checks

import compiler from "base"
import reflection from "std"

check_program :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    tiers_hold := check_tiers(target, program)
    arch_holds := check_arch_interface(program)
    return tiers_hold && arch_holds
}

// std tiers

// What std tiers are, as numbers that grow with what a package needs (std's tiers.Tier).
FREESTANDING :: 0
ALLOCATING :: 1
OS :: 2
NO_TIER :: -1

/*
 * No package imports a package of a higher tier than its own (decisions/0007). A std package's tier is
 * its PACKAGE_TIER; base is below every tier, since a Freestanding package needs only base; any other
 * package has the target's: Allocating without an operating system, like the kernel, and Os otherwise.
 * Checking every import edge covers what's imported indirectly too.
 */
check_tiers :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    holds := true
    for &importer in program.packages {
        importer_tier :: tier_of(target, program, importer)
        if importer_tier == NO_TIER {
            compiler.report_error(importer.location, "% is in std but declares no PACKAGE_TIER", importer.name)
            holds = false
            continue
        }
        for &edge in importer.imports {
            imported :: package_at(program, edge.path) or_continue
            imported_tier :: tier_of(target, program, imported)
            // A missing tier is reported on that package's own turn
            if imported_tier > importer_tier {
                compiler.report_error(edge.location, "% (tier %) imports % (tier %)", importer.name,
                    tier_name(importer_tier), edge.alias, tier_name(imported_tier))
                holds = false
            }
        }
    }
    return holds
}

// A package's tier, or NO_TIER for a std package that declares none.
tier_of :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo], package: ptr[compiler.PackageInfo]) -> int {
    // base's packages are the compiler's, at paths like <base>/runtime
    if starts_with(package.path, "<base>/") {
        return FREESTANDING
    }
    if !is_std(program, package.path) {
        if target.target_options.os == .None {
            return ALLOCATING
        }
        return OS
    }
    constant :: compiler.find_constant(package, "PACKAGE_TIER") or_else compiler.ConstantInfo.{}
    name :: reflection.enum_member_name(constant.value) or_else ""
    if name == "Freestanding" {
        return FREESTANDING
    }
    if name == "Allocating" {
        return ALLOCATING
    }
    if name == "Os" {
        return OS
    }
    return NO_TIER
}

tier_name :: fn(tier: int) -> string {
    if tier == FREESTANDING {
        return "Freestanding"
    }
    if tier == ALLOCATING {
        return "Allocating"
    }
    return "Os"
}

// Whether the package at path is std's: something in the program imports it from "std".
is_std :: fn(program: ptr[compiler.ProgramInfo], path: string) -> bool {
    for &package in program.packages {
        for &edge in package.imports {
            if edge.path == path && (edge.from == "std" || starts_with(edge.from, "std/")) {
                return true
            }
        }
    }
    return false
}

// The arch interface

/*
 * A package imported as arch implements the program's arch_interface package (decisions/0007, 0032):
 * every function arch_interface declares, with a body, and the same signature. A type arch_interface
 * declares as an empty struct, like ArchCpu, is the architecture's own: the implementation declares a
 * type of the same name, and a signature using one matches a signature using the other.
 *
 * What an architecture doesn't implement yet, it lists in NOT_YET_IMPLEMENTED (decisions/0005). Those
 * may be missing; one that's there, or isn't in arch_interface at all, is an error, so the list stays true.
 */
check_arch_interface :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    interface :: package_named(program, "arch_interface") or_return true
    holds := true
    for &candidate in program.packages {
        if imported_as_arch(program, candidate.path) {
            holds = implements(candidate, interface) && holds
        }
    }
    return holds
}

// Whether anything in the program imports the package at path as arch.
imported_as_arch :: fn(program: ptr[compiler.ProgramInfo], path: string) -> bool {
    for &package in program.packages {
        for &edge in package.imports {
            if edge.alias == "arch" && edge.path == path {
                return true
            }
        }
    }
    return false
}

implements :: fn(implementation: ptr[compiler.PackageInfo], interface: ptr[compiler.PackageInfo]) -> bool {
    holds := true
    gaps :: compiler.find_constant(implementation, "NOT_YET_IMPLEMENTED") or_else compiler.ConstantInfo.{}
    for name in listed_names(gaps.value) {
        implemented :: declares_type(implementation, name) || (compiler.find_function(implementation, name) is_some)
        if implemented {
            compiler.report_error(gaps.location, "%.% is there now, so take it off NOT_YET_IMPLEMENTED", implementation.name, name)
            holds = false
        }
        else if !declares_type(interface, name) && (compiler.find_function(interface, name) is_none) {
            compiler.report_error(gaps.location, "% lists %, which arch_interface doesn't declare", implementation.name, name)
            holds = false
        }
    }
    for &declared in interface.types {
        if is_listed(gaps.value, declared.name) {
            continue
        }
        if is_architecture_type(declared.type) && !declares_type(implementation, declared.name) {
            compiler.report_error(declared.location, "% doesn't declare %, which arch_interface leaves to each architecture",
                implementation.name, declared.name)
            holds = false
        }
    }
    for &required in interface.functions {
        if required.has_body {
            continue
        }
        if is_listed(gaps.value, required.name) {
            continue
        }
        found := compiler.find_function(implementation, required.name) or_else compiler.FunctionInfo.{}
        if found.name == "" {
            compiler.report_error(required.location, "% doesn't implement %", implementation.name, required.name)
            holds = false
            continue
        }
        if !found.has_body {
            compiler.report_error(found.location, "%.% is a declaration, not an implementation", implementation.name,
                required.name)
            holds = false
            continue
        }
        if !signatures_match(found, required) {
            compiler.report_error(found.location, "%.% doesn't match the signature arch_interface declares",
                implementation.name, required.name)
            holds = false
        }
    }
    return holds
}

// The implementation by value: it came from find_function, so a pointer to it couldn't be passed on
signatures_match :: fn(implementation: compiler.FunctionInfo, interface: ptr[compiler.FunctionInfo]) -> bool {
    if implementation.parameters.count != interface.parameters.count
        || implementation.return_values.count != interface.return_values.count
        || implementation.never_returns != interface.never_returns {
        return false
    }
    for &parameter, index in implementation.parameters {
        other :: &interface.parameters[index]
        if parameter.name != other.name || !types_match(parameter.type, other.type)
            || parameter.is_escaping != other.is_escaping || parameter.is_varargs != other.is_varargs {
            return false
        }
    }
    for &result, index in implementation.return_values {
        if !types_match(result.type, interface.return_values[index].type) {
            return false
        }
    }
    return true
}

/*
 * The same type, or the same shape with an architecture's own type where arch_interface has its empty
 * struct of the same name: ptr[mut ArchCpu] in both, say.
 */
types_match :: fn(implementation: type, interface: type) -> bool {
    if implementation == interface {
        return true
    }
    ours :: type_info_of(implementation)
    theirs :: type_info_of(interface)
    if theirs.variant == .STRUCT && is_architecture_type(interface) && ours.variant == .STRUCT {
        return struct_name(ours) == struct_name(theirs)
    }
    if theirs.variant == .POINTER && ours.variant == .POINTER {
        our_pointer :: cast[ptr[compiler.TypeInfoPointer]](ours)
        their_pointer :: cast[ptr[compiler.TypeInfoPointer]](theirs)
        if our_pointer.is_mutable != their_pointer.is_mutable {
            return false
        }
        our_base :: our_pointer.base_type or_return false
        their_base :: their_pointer.base_type or_return false
        return types_match(described_type(our_base), described_type(their_base))
    }
    return false
}

// An empty struct, which arch_interface declares for each architecture to define.
is_architecture_type :: fn(declared: type) -> bool {
    info :: type_info_of(declared)
    return info.variant == .STRUCT && cast[ptr[compiler.TypeInfoStruct]](info).members.count == 0
}

struct_name :: fn(info: ptr[compiler.TypeInfo]) -> string {
    return cast[ptr[compiler.TypeInfoStruct]](info).name
}

// A type value from its descriptor: a type value is its descriptor's address (Hemera docs/types.md).
described_type :: fn(info: ptr[compiler.TypeInfo]) -> type {
    return bit_cast[type](info)
}

declares_type :: fn(package: ptr[compiler.PackageInfo], name: string) -> bool {
    for &declared in package.types {
        if declared.name == name {
            return true
        }
    }
    return false
}

/*
 * The names in a constant that's an array of strings, like NOT_YET_IMPLEMENTED, or none if it's
 * something else or there's no such constant.
 */
listed_names :: fn(names: any) -> string[] {
    none : string[]
    if names.data == null {
        return none
    }
    info :: type_info_of(names.type)
    if info.variant != .ARRAY {
        return none
    }
    array :: cast[ptr[compiler.TypeInfoArray]](info)
    if array.dimensions.count != 1 || array.dimensions[0].type != .STATIC || array.base_type.variant != .STRING {
        return none
    }
    return view_of(cast[ptr[string]](names.data), array.dimensions[0].count)
}

is_listed :: fn(names: any, name: string) -> bool {
    for listed in listed_names(names) {
        if listed == name {
            return true
        }
    }
    return false
}

// Finding packages

package_at :: fn(program: ptr[compiler.ProgramInfo], path: string) -> ptr[compiler.PackageInfo]? {
    for &package in program.packages {
        if package.path == path {
            return package
        }
    }
    return null
}

package_named :: fn(program: ptr[compiler.ProgramInfo], name: string) -> ptr[compiler.PackageInfo]? {
    for &package in program.packages {
        if package.name == name {
            return package
        }
    }
    return null
}

starts_with :: fn(text: string, prefix: string) -> bool {
    if text.count < prefix.count {
        return false
    }
    for index in 0..<prefix.count {
        if text[index] != prefix[index] {
            return false
        }
    }
    return true
}
