/**
 * SlopOS's house rules (decisions/0007, 0029, 0100), run by the build package on every target once it's
 * checked: check_program, registered with compiler.add_check. Each rule reports every problem it
 * finds with compiler.report_error, at the most specific place, and returns false if it found any.
 *
 * A target's values have the target's types, not this package's, so they're compared by name
 * (reflection.enum_member_name), never cast (decisions/0029).
 */
package checks

import compiler from "base"
import runtime from "base"
import os from "std"
import reflection from "std"

/**
 * Check a target's program against every house rule, the check the build registers with compiler.add_check.
 *
 * Every rule runs, whatever the others found, so all the problems are reported at once.
 *
 * @param target The target being built, whose options say whether it's the kernel.
 * @param program The target's program, as the compiler describes it once it's checked.
 * @return True if every rule holds; false if any reported a problem.
 */
check_program :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    tiers_hold := check_tiers(target, program)
    arch_holds := check_arch_interface(program)
    iommus_hold := check_iommu_interface(program)
    protocols_hold := check_protocols(program)
    floats_hold := check_kernel_floats(target, program)
    results_hold := check_syscall_results(target, program)
    interrupts_hold := check_interrupt_allocation(target, program)
    imports_hold := check_program_imports(program)
    raw_hold := check_raw_pointers(program)
    layouts_hold := check_hardware_layouts(program)
    discards_hold := check_kernel_discards(target, program)
    locks_hold := check_kernel_locks(target, program)
    return tiers_hold && arch_holds && iommus_hold && protocols_hold && floats_hold && results_hold && interrupts_hold
        && imports_hold && raw_hold && layouts_hold && discards_hold && locks_hold
}

// ---- std tiers

/** The Freestanding tier, as a number that grows with what a package needs (std's tiers.Tier): base alone. */
FREESTANDING :: 0
/** The Allocating tier: an allocator, but no operating system. */
ALLOCATING :: 1
/** The Os tier: an operating system. */
OS :: 2
/** No tier: a std package that declares no PACKAGE_TIER. */
NO_TIER :: -1

/**
 * Check that no package imports a package of a higher tier than its own (decisions/0007).
 *
 * A std package's tier is its PACKAGE_TIER; base is below every tier, since a Freestanding package needs only base;
 * any other package has the target's: Allocating without an operating system, like the kernel, and Os otherwise.
 * Checking every import edge covers what's imported indirectly too. A std package without a PACKAGE_TIER is reported.
 *
 * @param target The target being built, whose operating system gives the project's packages their tier.
 * @param program The program as the compiler describes it once checked; only read. Every package's import edges are
 *     checked, the imported package found by its path.
 * @return True if it holds; false if a problem was reported, at the import or the package.
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

/**
 * Give a package's std tier.
 *
 * @param target The target being built.
 * @param program The target's program, to tell std's packages.
 * @param package The package whose tier is given, one of program's.
 * @return FREESTANDING for base's; for std's, its PACKAGE_TIER's, NO_TIER if it declares none or another; for the
 *     project's, ALLOCATING for a target with no operating system, OS otherwise.
 */
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
    // A package without one has no constant to read, and is reported as NO_TIER
    constant :: compiler.find_constant(package, "PACKAGE_TIER") or_return NO_TIER
    if constant.value.data == null {
        return NO_TIER
    }
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

/**
 * Name a tier, for a problem's message.
 *
 * @param tier FREESTANDING, ALLOCATING or OS.
 * @return Its name as std's tiers.Tier has it; "Os" for any other number.
 */
tier_name :: fn(tier: int) -> string {
    if tier == FREESTANDING {
        return "Freestanding"
    }
    if tier == ALLOCATING {
        return "Allocating"
    }
    return "Os"
}

/**
 * Tell whether a package is std's: it's in a std folder, or something in the program imports it from "std".
 *
 * @param program The program as the compiler describes it once checked; only read, its packages' import edges looked
 *     through for one from "std".
 * @param path The package's path, as PackageInfo.path or an import edge has it; one with a std folder in it, "/std/" or
 *     "\std\", is std's whatever imports it.
 * @return True if it's std's.
 */
is_std :: fn(program: ptr[compiler.ProgramInfo], path: string) -> bool {
    // What the compiler loads itself, as std/schema into a build that makes or calls a typed library, has no edge
    // importing it: it's std's by where it is, Hemera's std folder
    if contains(path, "/std/") || contains(path, "\\std\\") {
        return true
    }
    for &package in program.packages {
        for &edge in package.imports {
            if edge.path == path && (edge.from == "std" || starts_with(edge.from, "std/")) {
                return true
            }
        }
    }
    return false
}

// ---- The arch interface

/**
 * Check that a package imported as arch implements the program's arch_interface package (decisions/0007, 0032):
 * every function arch_interface declares, with a body, and the same signature.
 *
 * A type arch_interface declares as an empty struct, like ArchCpu, is the architecture's own: the implementation
 * declares a type of the same name, and a signature using one matches a signature using the other.
 *
 * What an architecture doesn't implement yet, it lists in NOT_YET_IMPLEMENTED (decisions/0005). Those may be missing,
 * or stubs in its not_yet_implemented.hsc, which the kernel's other code needs to compile on an architecture that
 * doesn't run it yet. One defined anywhere else, a stub that isn't listed, or a name arch_interface doesn't declare is
 * an error, so the list stays true.
 *
 * @param program The target's program; one without arch_interface holds.
 * @return True if it holds; false if a problem was reported.
 */
check_arch_interface :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    interface :: package_named(program, "arch_interface") or_return true
    holds := true
    for &candidate in program.packages {
        if imported_as(program, candidate.path, "arch", false) {
            holds = implements(candidate, interface) && holds
        }
    }
    return holds
}

/**
 * Each package imported under an alias starting iommu_, like iommu_vtd, implements the program's iommu_interface
 * package (decisions/0039, 0079), by the arch interface's rules: an IOMMU package is to iommu_interface what an
 * architecture package is to arch_interface.
 *
 * @param program The target's program; one without iommu_interface holds.
 * @return True if it holds; false if a problem was reported.
 */
check_iommu_interface :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    interface :: package_named(program, "iommu_interface") or_return true
    holds := true
    for &candidate in program.packages {
        if candidate.path != interface.path && imported_as(program, candidate.path, "iommu_", true) {
            holds = implements(candidate, interface) && holds
        }
    }
    return holds
}

/**
 * Check that a package that generates protocol code (os.protocol_code, which declares validate_request) says what
 * protocol it is, a PROTOCOL constant, and which of its requests can be sent again after a reconnect, an
 * is_idempotent function (decisions/0040, 0071). What its messages hold, and its Response's Unsupported, the generator
 * checks itself.
 *
 * @param program The program as the compiler describes it once checked; only read. Each of its packages that declares
 *     validate_request is checked.
 * @return True if it holds; false if a problem was reported, at the package.
 */
check_protocols :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    holds := true
    for &candidate in program.packages {
        if compiler.find_function(candidate, "validate_request") is_none {
            continue
        }
        if compiler.find_constant(candidate, "PROTOCOL") is_none {
            compiler.report_error(candidate.location, "% is a protocol, so it declares PROTOCOL, a slop_os.Protocol (decisions/0040)", candidate.name)
            holds = false
        }
        if compiler.find_function(candidate, "is_idempotent") is_none {
            compiler.report_error(candidate.location, "% is a protocol, so it declares is_idempotent(request) (decisions/0040)", candidate.name)
            holds = false
        }
    }
    return holds
}

/**
 * Tell whether anything in the program imports a package under an alias.
 *
 * @param program The program as the compiler describes it once checked; only read, every package's import edges looked
 *     through.
 * @param path The imported package's path, compared whole with each import edge's.
 * @param alias The alias, or with prefix, what the alias starts with.
 * @param prefix Whether alias is a prefix, as "iommu_" is, rather than the whole alias.
 * @return True if some import of the package is under that alias.
 */
imported_as :: fn(program: ptr[compiler.ProgramInfo], path: string, alias: string, prefix: bool) -> bool {
    for &package in program.packages {
        for &edge in package.imports {
            if (edge.alias == alias || (prefix && starts_with(edge.alias, alias))) && edge.path == path {
                return true
            }
        }
    }
    return false
}

/**
 * Check that a package implements an interface package, by the arch interface's rules (check_arch_interface).
 *
 * @param implementation The implementing package, whose NOT_YET_IMPLEMENTED lists what it doesn't do yet.
 * @param interface The interface package: its functions without bodies, and its empty structs.
 * @return True if it implements it; false if a problem was reported, each where it's best fixed.
 */
implements :: fn(implementation: ptr[compiler.PackageInfo], interface: ptr[compiler.PackageInfo]) -> bool {
    holds := true
    gaps :: compiler.find_constant(implementation, "NOT_YET_IMPLEMENTED") or_else compiler.ConstantInfo.{}
    for name in listed_names(gaps.value) {
        function :: compiler.find_function(implementation, name) or_else compiler.FunctionInfo.{}
        implemented :: declares_type(implementation, name) || (function.name != "" && !is_stub(function.location.file_path))
        if implemented {
            compiler.report_error(gaps.location, "%.% is there now, so take it off NOT_YET_IMPLEMENTED", implementation.name, name)
            holds = false
        }
        else if !declares_type(interface, name) && (compiler.find_function(interface, name) is_none) {
            compiler.report_error(gaps.location, "% lists %, which % doesn't declare", implementation.name, name, interface.name)
            holds = false
        }
    }
    for &declared in interface.types {
        if is_listed(gaps.value, declared.name) {
            continue
        }
        if is_architecture_type(declared.type) && !declares_type(implementation, declared.name) {
            compiler.report_error(declared.location, "% doesn't declare %, which % leaves to each implementation",
                implementation.name, declared.name, interface.name)
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
        if found.name != "" && is_stub(found.location.file_path) {
            compiler.report_error(found.location, "%.% is a stub, so list it in NOT_YET_IMPLEMENTED", implementation.name,
                required.name)
            holds = false
            continue
        }
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
            compiler.report_error(found.location, "%.% doesn't match the signature % declares",
                implementation.name, required.name, interface.name)
            holds = false
        }
    }
    return holds
}

/**
 * Tell whether a function's file is a not_yet_implemented.hsc, as the stubs of what isn't implemented yet are.
 *
 * @param path The path of the file a function is declared in, as its location gives it; only its end is compared.
 * @return True if it ends with not_yet_implemented.hsc.
 */
is_stub :: fn(path: string) -> bool {
    return ends_with(path, "not_yet_implemented.hsc")
}

/**
 * Tell whether an implementation's signature matches an interface's: the same parameters, by name, type, escaping and
 * varargs, the same results' types, and the same never_returns, types matching as types_match says.
 *
 * @param implementation The implementing function, by value: it came from find_function, so a pointer to it couldn't
 *     be passed on.
 * @param interface The function the interface package declares without a body, which implementation has to match; only
 *     read.
 * @return True if they match.
 */
signatures_match :: fn(implementation: compiler.FunctionInfo, interface: ptr[compiler.FunctionInfo]) -> bool {
    // Copies of the views, which types_match can't change, so their counts stay compared
    parameters :: interface.parameters
    return_values :: interface.return_values
    if implementation.parameters.count != parameters.count
        || implementation.return_values.count != return_values.count
        || implementation.never_returns != interface.never_returns {
        return false
    }
    for &parameter, index in implementation.parameters {
        other :: &parameters[index]
        if parameter.name != other.name || !types_match(parameter.type, other.type)
            || parameter.is_escaping != other.is_escaping || parameter.is_varargs != other.is_varargs {
            return false
        }
    }
    for &result, index in implementation.return_values {
        if !types_match(result.type, return_values[index].type) {
            return false
        }
    }
    return true
}

/**
 * Tell whether an implementation's type matches an interface's: the same type, or the same shape with an
 * architecture's own type where the interface has its empty struct of the same name: ptr[mut ArchCpu] in both, say.
 *
 * @param implementation The type in the implementation's signature.
 * @param interface The type in the interface's.
 * @return True if they match; pointers match when they're both mutable or both not, and their targets match.
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

/**
 * Tell whether a type is an architecture's own: an empty struct, which arch_interface declares for each architecture
 * to define.
 *
 * @param declared A type an interface package declares, as its PackageInfo's types list it.
 * @return True for a struct without members.
 */
is_architecture_type :: fn(declared: type) -> bool {
    info :: type_info_of(declared)
    return info.variant == .STRUCT && cast[ptr[compiler.TypeInfoStruct]](info).members.count == 0
}

/**
 * Give a struct type's name.
 *
 * @param info The type's descriptor, which has to be a struct's.
 * @return Its name, as the compiler gives it.
 */
struct_name :: fn(info: ptr[compiler.TypeInfo]) -> string {
    return cast[ptr[compiler.TypeInfoStruct]](info).name
}

/**
 * Make a type value from its descriptor: a type value is its descriptor's address (Hemera docs/types.md).
 *
 * @param info Any type's descriptor, as type_info_of or a descriptor's member gives it; not checked, only
 *     reinterpreted.
 * @return The type value whose descriptor info is, for comparing with ==.
 */
described_type :: fn(info: ptr[compiler.TypeInfo]) -> type {
    return bit_cast[type](info)
}

/**
 * Tell whether a package declares a type of a name.
 *
 * @param package The package whose declared types are looked through; types it imports aren't.
 * @param name The name to find, compared whole with each declared type's own name, without a package prefix.
 * @return True if one of its types has it.
 */
declares_type :: fn(package: ptr[compiler.PackageInfo], name: string) -> bool {
    for &declared in package.types {
        if declared.name == name {
            return true
        }
    }
    return false
}

/**
 * Give the names in a constant that's an array of strings, like NOT_YET_IMPLEMENTED.
 *
 * @param names The constant's value, as compiler.ConstantInfo has it; one with no data is no constant.
 * @return The strings, a view into the constant's value; none if there's no constant, or it's anything but a static
 *     array of strings.
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

/**
 * Tell whether a constant that's an array of strings lists a name.
 *
 * @param names The constant's value, as listed_names takes it.
 * @param name The name looked for, compared whole and exactly.
 * @return True if it's one of the strings.
 */
is_listed :: fn(names: any, name: string) -> bool {
    for listed in listed_names(names) {
        if listed == name {
            return true
        }
    }
    return false
}

// ---- The kernel's code (decisions/0029, 0100)

/**
 * Tell whether the target is the kernel: built for no operating system.
 *
 * @param target The target being built.
 * @return True if its operating system is None.
 */
is_kernel :: fn(target: ptr[compiler.BuildOptions]) -> bool {
    return target.target_options.os == .None
}

/**
 * Tell whether a package is the project's own: not base's, and not std's.
 *
 * @param program The target's program, to tell std's packages.
 * @param package One of program's packages.
 * @return True if it's the project's.
 */
is_own :: fn(program: ptr[compiler.ProgramInfo], package: ptr[compiler.PackageInfo]) -> bool {
    return !starts_with(package.path, "<base>/") && !is_std(program, package.path)
}

/**
 * Check that there's no floating point in the kernel, which is built without SIMD or floating-point state: no float,
 * complex or quaternion type, or vector of them, in what a function of its own packages takes, gives or uses.
 *
 * @param target The target being built; anything but the kernel holds.
 * @param program The program as the compiler describes it once checked; only read. Its own packages' functions are
 *     checked, not base's or std's.
 * @return True if it holds; false if a problem was reported.
 */
check_kernel_floats :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if !is_kernel(target) {
        return true
    }
    holds := true
    for &package in program.packages {
        if !is_own(program, package) {
            continue
        }
        for &function in package.functions {
            for &parameter in function.parameters {
                if is_floating(parameter.type) {
                    compiler.report_error(function.location, "%.% takes floating point (%), which the kernel has none of",
                        package.name, function.name, parameter.name)
                    holds = false
                }
            }
            for &result in function.return_values {
                if is_floating(result.type) {
                    compiler.report_error(function.location, "%.% gives floating point, which the kernel has none of", package.name, function.name)
                    holds = false
                }
            }
            for &use in function.used_types {
                if is_floating(use.type) {
                    compiler.report_error(use.location, "floating point, which the kernel has none of")
                    holds = false
                }
            }
        }
    }
    return holds
}

/**
 * Tell whether a type is floating point: a float, complex or quaternion, or a vector of them, through aliases.
 *
 * @param checked A type a kernel function takes, gives or uses; its aliases are followed.
 * @return True if it is; false for a vector of bits.
 */
is_floating :: fn(checked: type) -> bool {
    info :: unaliased(type_info_of(checked))
    if info.variant == .FLOAT || info.variant == .COMPLEX || info.variant == .QUATERNION {
        return true
    }
    if info.variant == .VECTOR {
        vector :: cast[ptr[compiler.TypeInfoVector]](info)
        return !vector.is_bits && is_floating(described_type(vector.element_type))
    }
    return false
}

/**
 * Follow a type's aliases to the type they name.
 *
 * @param info Any type's descriptor; an alias's is followed through its base types, however many.
 * @return The first descriptor along the aliases that isn't an alias's; info itself if it isn't one.
 */
unaliased :: fn(info: ptr[compiler.TypeInfo]) -> ptr[compiler.TypeInfo] {
    at := info
    loop {
        if at.variant != .ALIAS {
            return at
        }
        at = cast[ptr[compiler.TypeInfoAlias]](at).base_type
    }
}

/**
 * Check that no kernel address reaches user space through a system call's result (decisions/0021): what a sys_
 * function of the kernel package gives has no pointer in it, however deep.
 *
 * @param target The target being built; anything but the kernel holds.
 * @param program The target's program; one without a kernel package holds.
 * @return True if it holds; false if a problem was reported, at the function.
 */
check_syscall_results :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if !is_kernel(target) {
        return true
    }
    kernel :: package_named(program, "kernel") or_return true
    holds := true
    for &function in kernel.functions {
        if !starts_with(function.name, "sys_") {
            continue
        }
        for &result in function.return_values {
            seen : uintptr[..]
            defer runtime.array_free(&seen)
            if has_pointer(type_info_of(result.type), &seen) {
                compiler.report_error(function.location, "%'s result has a pointer in it, which would give user space a kernel address",
                    function.name)
                holds = false
            }
        }
    }
    return holds
}

/**
 * Tell whether a value of a type holds a pointer: itself, or a member's, element's or variant's, however deep.
 *
 * @param info The descriptor of the type looked into: aliases, arrays, struct members and the types a variant holds are
 *     followed.
 * @param seen The types already looked at, which this adds to, so a type that holds itself ends; each is looked into
 *     once, and false the second time.
 * @return True if it holds a pointer.
 */
has_pointer :: fn(info: ptr[compiler.TypeInfo], seen: ptr[mut uintptr[..]]) -> bool {
    for each in seen^ {
        if each == cast[uintptr](info) {
            return false
        }
    }
    runtime.array_add(seen, cast[uintptr](info))
    if info.variant == .POINTER {
        return true
    }
    if info.variant == .ALIAS {
        return has_pointer(cast[ptr[compiler.TypeInfoAlias]](info).base_type, seen)
    }
    if info.variant == .ARRAY {
        return has_pointer(cast[ptr[compiler.TypeInfoArray]](info).base_type, seen)
    }
    if info.variant == .STRUCT {
        for &member in cast[ptr[compiler.TypeInfoStruct]](info).members {
            if has_pointer(member.member_type, seen) {
                return true
            }
        }
    }
    if info.variant == .UNION {
        for &variant in cast[ptr[compiler.TypeInfoUnion]](info).variants {
            for held in variant.types {
                if has_pointer(held, seen) {
                    return true
                }
            }
        }
    }
    return false
}

/**
 * Check that interrupt handlers don't allocate: nothing the kernel's entry for an interrupt (kernel_entry.interrupt)
 * reaches, by calls it names, calls an allocator, except what INTERRUPT_ALLOCATIONS lists. A call through a function
 * value isn't followed, nor one into std.
 *
 * @param target The target being built; anything but the kernel holds.
 * @param program The target's program; one without the interrupt entry holds.
 * @return True if it holds; false if a problem was reported, at each call to an allocator.
 */
check_interrupt_allocation :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if !is_kernel(target) {
        return true
    }
    entry :: package_named(program, "kernel_entry") or_return true
    handler :: compiler.find_function(entry, "interrupt") or_return true
    visited : compiler.FunctionCall[..]
    defer runtime.array_free(&visited)
    return !allocates(program, handler, entry.name, &visited)
}

/** The allocators, by the names they're called by: base's, and the kernel's heap's and objects'. */
ALLOCATORS :: string.["new", "new_aligned", "new_array", "new_array_aligned", "array_reserve", "allocate_block", "new_object"]

/**
 * Tell whether a function, or anything it calls by name in the project's packages or base's, calls an allocator,
 * reporting each such call.
 *
 * @param program The program as the compiler describes it once checked; only read, to find each called function's
 *     package by its path. Calls into packages other than the project's own and base's aren't followed.
 * @param function The function; one INTERRUPT_ALLOCATIONS lists is taken not to allocate.
 * @param package The function's package's name.
 * @param visited The calls already followed, which this adds to, so each is followed once.
 * @return True if an allocator is called.
 */
allocates :: fn(program: ptr[compiler.ProgramInfo], function: compiler.FunctionInfo, package: string,
    visited: ptr[mut compiler.FunctionCall[..]]) -> bool {
    if is_listed_function(INTERRUPT_ALLOCATIONS, package, function.name) {
        return false
    }
    found := false
    for &call in function.calls {
        if call.name == "" {
            continue
        }
        called_name :: generic_name(call.name)
        for name in ALLOCATORS {
            if called_name == name {
                compiler.report_error(call.location, "% allocates, and an interrupt handler reaches it", function.name)
                found = true
            }
        }
        already := false
        for &each in visited^ {
            already = already || (each.name == call.name && each.package_path == call.package_path)
        }
        if already {
            continue
        }
        runtime.array_add(visited, call^)
        called_package :: package_at(program, call.package_path) or_continue
        if !is_own(program, called_package) && !starts_with(called_package.path, "<base>/") {
            continue
        }
        called :: compiler.find_function(called_package, called_name) or_continue
        found = allocates(program, called, called_package.name, visited) || found
    }
    return found
}

// ---- Programs

/** The folders whose packages that declare main are programs, written with /. */
PROGRAM_FOLDERS :: string.["/src/apps/", "/src/services/", "/src/drivers/", "/src/tests/"]

/**
 * Tell whether a package is a program: one in a program folder that declares main.
 *
 * @param package One of the program's packages, by its path and its functions.
 * @return True if it's a program.
 */
is_program :: fn(package: ptr[compiler.PackageInfo]) -> bool {
    if compiler.find_function(package, "main") is_none {
        return false
    }
    for folder in PROGRAM_FOLDERS {
        if in_folder(package.path, folder) {
            return true
        }
    }
    return false
}

/**
 * Programs don't share code by importing each other (decisions/0029, 0100): a program may import another to launch it,
 * for its entry's type and its constants, but calls nothing of it. What two programs share goes in a library package.
 *
 * @param program The program as the compiler describes it once checked; only read. Every call one program package makes
 *     into another it imports is reported.
 * @return True if it holds; false if a problem was reported, at each call.
 */
check_program_imports :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    holds := true
    for &importer in program.packages {
        if !is_program(importer) {
            continue
        }
        for &edge in importer.imports {
            imported :: package_at(program, edge.path) or_continue
            if imported.path == importer.path || !is_program(imported) {
                continue
            }
            for &function in importer.functions {
                for &call in function.calls {
                    if call.package_path == imported.path {
                        compiler.report_error(call.location, "% calls %.%, but programs don't share code: move it to a library package",
                            importer.name, imported.name, call.name)
                        holds = false
                    }
                }
            }
        }
    }
    return holds
}

/**
 * rawptr only where it's needed (decisions/0029, 0100, 0102): in the packages RAW_POINTERS names, each one that works
 * with memory as bytes or as hardware sees it. Everywhere else, a pointer has a type: in what functions use, and in the
 * members of the structs and unions a package declares.
 *
 * @param program The target's program; only the project's own packages are checked.
 * @return True if it holds; false if a problem was reported, at each use or declaration.
 */
check_raw_pointers :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    holds := true
    for &package in program.packages {
        if !is_own(program, package) || is_listed_in(RAW_POINTERS, package.name) {
            continue
        }
        for &function in package.functions {
            for &use in function.used_types {
                if is_raw_pointer(use.type) {
                    compiler.report_error(use.location, "rawptr in %, which isn't in RAW_POINTERS (src/checks)", package.name)
                    holds = false
                }
            }
        }
        for &declared in package.types {
            if declares_raw_pointer(type_info_of(declared.type)) {
                compiler.report_error(declared.location, "% holds a rawptr, and %'s not in RAW_POINTERS (src/checks)",
                    declared.name, package.name)
                holds = false
            }
        }
    }
    return holds
}

/**
 * Tell whether a type is a rawptr: a pointer with no target type, through aliases.
 *
 * @param checked A type a function uses; its aliases are followed.
 * @return True if it is.
 */
is_raw_pointer :: fn(checked: type) -> bool {
    info :: unaliased(type_info_of(checked))
    return info.variant == .POINTER && (cast[ptr[compiler.TypeInfoPointer]](info).base_type is_none)
}

/**
 * Tell whether a declared struct's members, or a union's variants, spell a rawptr (spells_raw_pointer).
 *
 * @param info The declared type's descriptor; any other kind than a struct or a union spells none.
 * @return True if one does.
 */
declares_raw_pointer :: fn(info: ptr[compiler.TypeInfo]) -> bool {
    if info.variant == .STRUCT {
        for &member in cast[ptr[compiler.TypeInfoStruct]](info).members {
            if spells_raw_pointer(member.member_type) {
                return true
            }
        }
    }
    if info.variant == .UNION {
        for &variant in cast[ptr[compiler.TypeInfoUnion]](info).variants {
            for held in variant.types {
                if spells_raw_pointer(held) {
                    return true
                }
            }
        }
    }
    return false
}

/**
 * Whether a member's type is a rawptr, or has one in it as written: an array's elements, an optional's value, a
 * pointer's target, or a function type's parameters and results. Another named type, an alias or a struct or union, is
 * its own package's to answer for, so it isn't looked into.
 *
 * @param info The member's type's descriptor.
 * @return True if it spells a rawptr.
 */
spells_raw_pointer :: fn(info: ptr[compiler.TypeInfo]) -> bool {
    if info.variant == .POINTER {
        target :: cast[ptr[compiler.TypeInfoPointer]](info).base_type or_return true
        return spells_raw_pointer(target)
    }
    if info.variant == .ARRAY {
        return spells_raw_pointer(cast[ptr[compiler.TypeInfoArray]](info).base_type)
    }
    if info.variant == .UNION {
        optional :: cast[ptr[compiler.TypeInfoUnion]](info)
        if !starts_with(optional.name, "Optional[") {
            return false
        }
        for &variant in optional.variants {
            for held in variant.types {
                if spells_raw_pointer(held) {
                    return true
                }
            }
        }
    }
    if info.variant == .FUNCTION {
        function :: cast[ptr[compiler.TypeInfoFunction]](info)
        for &input in function.input {
            if spells_raw_pointer(input.type) {
                return true
            }
        }
        for &output in function.output {
            if spells_raw_pointer(output.type) {
                return true
            }
        }
    }
    return false
}

/**
 * The folders whose packages are hardware packages, written with /: a path that has one in it, anywhere, is in it, so
 * "/src/pci" holds "/src/pci_whatever" too.
 */
HARDWARE_FOLDERS :: string.["/src/arch/", "/src/drivers/", "/src/iommu/", "/src/virtio", "/src/pci", "/src/gpt", "/src/fat", "/src/slopfs"]

/**
 * Check that hardware structs have their layouts checked (decisions/0029, 0100): a #packed struct in a hardware
 * package is hardware's, and its package asserts its size, an #assert with size_of(Name) on a line of one of its
 * files.
 *
 * Its files are read whole; one that can't be read is passed over.
 *
 * @param program The program as the compiler describes it once checked; only read. The packages in a hardware folder
 *     have their #packed structs checked.
 * @return True if it holds; false if a problem was reported, at each struct.
 */
check_hardware_layouts :: fn(program: ptr[compiler.ProgramInfo]) -> bool {
    holds := true
    for &package in program.packages {
        hardware := false
        for folder in HARDWARE_FOLDERS {
            hardware = hardware || in_folder(package.path, folder)
        }
        if !hardware {
            continue
        }
        text : string[..]
        defer runtime.array_free(&text)
        for path in package.files {
            match os.read_entire_file(path) {
                case Ok(read) => runtime.array_add(&text, read)
                case Error(error) => {}
            }
        }
        for &declared in package.types {
            info :: type_info_of(declared.type)
            if info.variant != .STRUCT || !cast[ptr[compiler.TypeInfoStruct]](info).is_packed {
                continue
            }
            asserted := false
            for each in text {
                asserted = asserted || asserts_size(each, declared.name)
            }
            if !asserted {
                compiler.report_error(declared.location, "% is #packed, so it's hardware's: assert its size (#assert size_of(%) == ...)",
                    declared.name, declared.name)
                holds = false
            }
        }
    }
    return holds
}

/**
 * Tell whether text has a line with #assert and size_of(name) after it.
 *
 * @param text A file's text.
 * @param name The struct's name, matched whole within size_of's parentheses.
 * @return True if some line has both.
 */
asserts_size :: fn(text: string, name: string) -> bool {
    at := find(text, "#assert", 0)
    loop {
        if at == NOT_FOUND {
            return false
        }
        end := find(text, NEWLINE, at)
        if end == NOT_FOUND {
            end = text.count
        }
        if has_size_of(text, name, at, end) {
            return true
        }
        at = find(text, "#assert", end)
    }
}

/**
 * The kernel's locks are ranked (decisions/0096, 0106): no kernel function takes or gives back a std spin lock itself
 * but the ranked ones of locks.hsc, which check the order with robustness=on. The frame allocator's, the slab's and the
 * architectures' leaves are other packages, outside this.
 *
 * @param target The target being built; anything but the kernel holds.
 * @param program The target's program; one without a kernel package holds.
 * @return True if it holds; false if a problem was reported, at each call.
 */
check_kernel_locks :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if !is_kernel(target) {
        return true
    }
    kernel :: package_named(program, "kernel") or_return true
    holds := true
    for &function in kernel.functions {
        if is_listed_in(LOCK_WRAPPERS, function.name) {
            continue
        }
        for &call in function.calls {
            if (call.name == "lock" || call.name == "unlock") && (ends_with(call.package_path, "/concurrency")
                || ends_with(call.package_path, "\\concurrency")) {
                compiler.report_error(call.location, "% takes a spin lock unranked: use lock_at and unlock_at (locks.hsc)", function.name)
                holds = false
            }
        }
    }
    return holds
}

/** The kernel's functions that take std's spin locks themselves: the ranked ones (kernel/locks.hsc). */
LOCK_WRAPPERS :: string.["lock_at", "lock_after", "unlock_at"]

/**
 * Errors aren't ignored in the kernel (decisions/0029, 0100): no function of its discards a Result with _ =, unless
 * DISCARDED_RESULTS names it, as package.function, where losing the error is right.
 *
 * @param target The target being built; anything but the kernel holds.
 * @param program The target's program; only the project's own packages are checked.
 * @return True if it holds; false if a problem was reported, at each discard.
 */
check_kernel_discards :: fn(target: ptr[compiler.BuildOptions], program: ptr[compiler.ProgramInfo]) -> bool {
    if !is_kernel(target) {
        return true
    }
    holds := true
    for &package in program.packages {
        if !is_own(program, package) {
            continue
        }
        for &function in package.functions {
            for &discard in function.discards {
                if is_result(discard.type) && !is_listed_function(DISCARDED_RESULTS, package.name, function.name) {
                    compiler.report_error(discard.location, "%.% discards a Result: handle its error, or list it in DISCARDED_RESULTS (src/checks)",
                        package.name, function.name)
                    holds = false
                }
            }
        }
    }
    return holds
}

/**
 * Tell whether a type is a Result, by its name, through aliases.
 *
 * @param checked The type of a value a function discards; its aliases are followed.
 * @return True for a union whose name starts with Result.
 */
is_result :: fn(checked: type) -> bool {
    info :: unaliased(type_info_of(checked))
    return info.variant == .UNION && starts_with(cast[ptr[compiler.TypeInfoUnion]](info).name, "Result")
}

// ---- Allow-lists

/**
 * Packages whose code may use rawptr (decisions/0100, 0102, 0103), for one of these reasons, and a package joins only
 * for one: - an instruction, or base's mem_copy and mem_zero, takes an address without a type (the architectures, the
 * kernel, frames, elf_loader, pci, iommu_vtd, x86_64_test); - base's own interfaces hide a type: the allocator's, the
 * clock's and the context's data, the carrier's, the stack trace's addresses (the kernel, slopos_boot); - the
 * firmware's tables and protocols are reached through addresses without a type (bootloader); - a device's callbacks
 * take their context without a type, which Hemera's function values, capturing nothing, need (fat, gpt, slopfs, the
 * servers and tests that give one, image_builder); - structs are read at offsets in a buffer of bytes, from the address
 * of its data, which base gives as a rawptr (events_service); - a model-checked test's threads take their data as an
 * any, whose value is behind a rawptr (handle_entries_test, shootdowns_test). A string's bytes are string_bytes(text),
 * not its data.
 */
RAW_POINTERS :: string.[
    "arch_aarch64", "arch_x86_64", "container_service", "elf_loader", "events_service", "fat", "fat_server", "fat_test",
    "bootloader", "frames", "gpt", "gpt_test", "handle_entries_test", "image_builder", "iommu_vtd", "kernel",
    "partition_server", "pci", "shootdowns_test", "slopfs", "slopfs_test", "slopos_boot", "test_kit", "volume_server",
    "x86_64_test",
]

/** Functions of the kernel's, as package.function, that may discard a Result: losing its error is right there. */
DISCARDED_RESULTS :: string.[
    // A block another one's tables already cover is mapped already
    "arch_aarch64.init_kernel_page_table",
    // Cleaning up after a failure, whose own error is the one given
    "kernel.sys_channel_create",
]

/**
 * Functions of the kernel's, as package.function, that an interrupt handler may reach though they allocate: what
 * they do without memory is right there.
 */
INTERRUPT_ALLOCATIONS :: string.[
    // A woken thread's wait, armed again as it's resumed, which without memory waits without its deadline
    "kernel.grow_heap",
]

/**
 * Tell whether a list has a name.
 *
 * @param names The list, as RAW_POINTERS is.
 * @param name The name, compared whole.
 * @return True if it's listed.
 */
is_listed_in :: fn(names: string[], name: string) -> bool {
    for listed in names {
        if listed == name {
            return true
        }
    }
    return false
}

/**
 * Tell whether a list has a function, as package.function.
 *
 * @param names The list, as DISCARDED_RESULTS is.
 * @param package The function's package's name.
 * @param function The function's name as its FunctionInfo has it, without its package; compared exactly.
 * @return True if one of names is exactly package, a dot, and function.
 */
is_listed_function :: fn(names: string[], package: string, function: string) -> bool {
    for listed in names {
        if listed.count == package.count + 1 + function.count && package.count < listed.count && starts_with(listed, package)
            && listed[package.count] == '.' && ends_with(listed, function) {
            return true
        }
    }
    return false
}

// ---- Text

/**
 * Tell whether text has a part in it.
 *
 * @param text The text looked through, as a path.
 * @param part The part, matched byte for byte.
 * @return True if it's anywhere in text; an empty part is in any text.
 */
contains :: fn(text: string, part: string) -> bool {
    return find(text, part, 0) != NOT_FOUND
}

/** What find gives when the part isn't there: the largest usize. */
NOT_FOUND : usize : 0xffffffffffffffff
/** A line's end, as a hardware package's files are searched by line. */
NEWLINE :: "\n"

/**
 * Find a part in text, at or after an index.
 *
 * @param text The text looked through, as a file's.
 * @param part The part, matched byte for byte.
 * @param from Where to start looking, a byte index.
 * @return Where the first match starts, a byte index; NOT_FOUND if there's none, or part is longer than text.
 */
find :: fn(text: string, part: string, from: usize) -> usize {
    if part.count > text.count {
        return NOT_FOUND
    }
    for start in from..<text.count - part.count + 1 {
        matched := true
        for index in 0..<part.count {
            at :: start + index
            if at >= text.count || text[at] != part[index] {
                matched = false
                break
            }
        }
        if matched {
            return start
        }
    }
    return NOT_FOUND
}

/**
 * Tell whether text has size_of(name), name whole, between two indexes.
 *
 * @param text A file's text.
 * @param name The name in the parentheses.
 * @param from Where to start looking, a byte index.
 * @param to Where to stop: a match has to start before it, and its ) be before it.
 * @return True if there's one.
 */
has_size_of :: fn(text: string, name: string, from: usize, to: usize) -> bool {
    at := find(text, "size_of(", from)
    loop {
        if at == NOT_FOUND || at >= to {
            return false
        }
        start :: at + 8
        end :: start + name.count
        if end < to && end < text.count && text[end] == ')' && matches_at(text, start, name) {
            return true
        }
        at = find(text, "size_of(", start)
    }
}

/**
 * Give a call's name without its generic arguments: new for new[u64].
 *
 * @param name The call's name, as compiler.FunctionCall has it.
 * @return What's before its first [, a view into name; all of name without one.
 */
generic_name :: fn(name: string) -> string {
    for character, index in name {
        if character == '[' {
            return string_of(cast[ptr[u8]](name.data), index)
        }
    }
    return name
}

/**
 * Tell whether a path has a folder in it, whichever separator the path uses.
 *
 * @param path The path, with / or \ separators.
 * @param folder The folder, written with /, as "/src/drivers/"; each / matches a \ in path too.
 * @return True if it's anywhere in path.
 */
in_folder :: fn(path: string, folder: string) -> bool {
    if folder.count > path.count {
        return false
    }
    for start in 0..<path.count - folder.count + 1 {
        matched := true
        for character, index in folder {
            at :: start + index
            found :: if at < path.count { path[at] } else { cast[char](0) }
            if found != character && !(character == '/' && found == '\\') {
                matched = false
                break
            }
        }
        if matched {
            return true
        }
    }
    return false
}

/**
 * Tell whether a part is in text at an index.
 *
 * @param text The text looked in, as a path.
 * @param at The byte index the part has to start at.
 * @param part What has to be there, matched byte for byte; an empty part always is.
 * @return True if text's bytes from at are part's; false if they differ or text ends first.
 */
matches_at :: fn(text: string, at: usize, part: string) -> bool {
    for character, index in part {
        if at + index >= text.count || text[at + index] != character {
            return false
        }
    }
    return true
}

// ---- Finding packages

/**
 * Find a package of the program by its path.
 *
 * @param program The program as the compiler describes it once checked; only read, its packages looked through in
 *     order.
 * @param path The package's path, as an import edge has it.
 * @return The package, which the program holds; null if it has none at path.
 */
package_at :: fn(program: ptr[compiler.ProgramInfo], path: string) -> ptr[compiler.PackageInfo]? {
    for &package in program.packages {
        if package.path == path {
            return package
        }
    }
    return null
}

/**
 * Find a package of the program by its name.
 *
 * @param program The program as the compiler describes it once checked; only read, its packages looked through in
 *     order.
 * @param name The package's name, as its package line has it.
 * @return The first package of that name, which the program holds; null if it has none.
 */
package_named :: fn(program: ptr[compiler.ProgramInfo], name: string) -> ptr[compiler.PackageInfo]? {
    for &package in program.packages {
        if package.name == name {
            return package
        }
    }
    return null
}

/**
 * Tell whether text ends with a suffix.
 *
 * @param text The text looked at, as a path.
 * @param suffix The suffix, matched byte for byte.
 * @return True if it does; an empty suffix always does.
 */
ends_with :: fn(text: string, suffix: string) -> bool {
    if text.count < suffix.count {
        return false
    }
    start :: text.count - suffix.count
    for character, index in suffix {
        at :: start + index
        if at >= text.count || text[at] != character {
            return false
        }
    }
    return true
}

/**
 * Tell whether text starts with a prefix.
 *
 * @param text The text looked at, as a path or a name.
 * @param prefix The prefix, matched byte for byte.
 * @return True if it does; an empty prefix always does.
 */
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
