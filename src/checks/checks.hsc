/*
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
 * may be missing, or stubs in its not_yet_implemented.hsc, which the kernel's other code needs to compile
 * on an architecture that doesn't run it yet. One defined anywhere else, a stub that isn't listed, or a
 * name arch_interface doesn't declare is an error, so the list stays true.
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

/*
 * Each package imported under an alias starting iommu_, like iommu_vtd, implements the program's iommu_interface
 * package (decisions/0039, 0079), by the arch interface's rules: an IOMMU package is to iommu_interface what an
 * architecture package is to arch_interface.
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

/*
 * A package that generates protocol code (os.protocol_code, which declares validate_request) says what protocol it
 * is, a PROTOCOL constant, and which of its requests can be sent again after a reconnect, an is_idempotent function
 * (decisions/0040, 0071). What its messages hold, and its Response's Unsupported, the generator checks itself.
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

// Whether anything in the program imports the package at path as alias, or, with prefix, under an alias starting so.
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

// Whether a function's file is a not_yet_implemented.hsc, as the stubs of what isn't implemented yet are.
is_stub :: fn(path: string) -> bool {
    return ends_with(path, "not_yet_implemented.hsc")
}

// The implementation by value: it came from find_function, so a pointer to it couldn't be passed on
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

// The kernel's code (decisions/0029, 0100)

// Whether the target is the kernel: built for no operating system.
is_kernel :: fn(target: ptr[compiler.BuildOptions]) -> bool {
    return target.target_options.os == .None
}

// Whether a package is the project's own: not base's, and not std's.
is_own :: fn(program: ptr[compiler.ProgramInfo], package: ptr[compiler.PackageInfo]) -> bool {
    return !starts_with(package.path, "<base>/") && !is_std(program, package.path)
}

/*
 * No floating point in the kernel, which is built without SIMD or floating-point state: no float, complex or
 * quaternion type, or vector of them, in what a function of its takes, gives or uses.
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

unaliased :: fn(info: ptr[compiler.TypeInfo]) -> ptr[compiler.TypeInfo] {
    at := info
    loop {
        if at.variant != .ALIAS {
            return at
        }
        at = cast[ptr[compiler.TypeInfoAlias]](at).base_type
    }
}

/*
 * No kernel address reaches user space through a system call's result (decisions/0021): what a sys_ function of the
 * kernel's gives has no pointer in it, however deep.
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

// Whether a value of the type holds a pointer: itself, or a member's, element's or variant's, however deep.
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

/*
 * Interrupt handlers don't allocate: nothing the kernel's entry for an interrupt reaches, by calls it names, calls an
 * allocator. A call through a function value isn't followed.
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

// The allocators: base's, and the kernel's heap's and objects'.
ALLOCATORS :: string.["new", "new_aligned", "new_array", "new_array_aligned", "array_reserve", "allocate_block", "new_object"]

// Whether a function, or anything it calls by name, calls an allocator; each such call reported.
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

// Programs

// Folders whose packages that declare main are programs.
PROGRAM_FOLDERS :: string.["/src/apps/", "/src/services/", "/src/drivers/", "/src/tests/"]

// Whether a package is a program: one of the project's, in a program folder, that declares main.
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

/*
 * Programs don't share code by importing each other (decisions/0029, 0100): a program may import another to launch it,
 * for its entry's type and its constants, but calls nothing of it. What two programs share goes in a library package.
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

/*
 * rawptr only where it's needed (decisions/0029, 0100, 0102): in the packages RAW_POINTERS names, each one that works
 * with memory as bytes or as hardware sees it. Everywhere else, a pointer has a type: in what functions use, and in the
 * members of the structs and unions a package declares.
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

is_raw_pointer :: fn(checked: type) -> bool {
    info :: unaliased(type_info_of(checked))
    return info.variant == .POINTER && (cast[ptr[compiler.TypeInfoPointer]](info).base_type is_none)
}

// Whether a declared struct's members, or a union's variants, spell a rawptr (spells_raw_pointer).
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

/*
 * Whether a member's type is a rawptr, or has one in it as written: an array's elements, an optional's value, a pointer's
 * target, or a function type's parameters and results. Another named type, an alias or a struct or union, is its own
 * package's to answer for, so it isn't looked into.
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

/*
 * Hardware structs have their layouts checked (decisions/0029, 0100): a #packed struct in a hardware package is
 * hardware's, and its package asserts its size, an #assert with size_of(Name) in one of its files.
 */
HARDWARE_FOLDERS :: string.["/src/arch/", "/src/drivers/", "/src/iommu/", "/src/virtio", "/src/pci", "/src/gpt", "/src/fat", "/src/slopfs"]

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

// Whether text has a line with #assert and size_of(name) on it.
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

/*
 * The kernel's locks are ranked (decisions/0096, 0106): no kernel function takes or gives back a std spin lock itself
 * but the ranked ones of locks.hsc, which check the order with robustness=on. The frame allocator's, the slab's and the
 * architectures' leaves are other packages, outside this.
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

// The kernel's functions that take std's spin locks themselves: the ranked ones (kernel/locks.hsc).
LOCK_WRAPPERS :: string.["lock_at", "lock_after", "unlock_at"]

/*
 * Errors aren't ignored in the kernel (decisions/0029, 0100): no function of its discards a Result with _ =, unless
 * DISCARDED_RESULTS names it, as package.function, where losing the error is right.
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

is_result :: fn(checked: type) -> bool {
    info :: unaliased(type_info_of(checked))
    return info.variant == .UNION && starts_with(cast[ptr[compiler.TypeInfoUnion]](info).name, "Result")
}

// Allow-lists

/*
 * Packages whose code may use rawptr (decisions/0100, 0102, 0103), for one of these reasons, and a package joins only for
 * one:
 * - an instruction, or base's mem_copy and mem_zero, takes an address without a type (the architectures, the kernel,
 *   frames, elf_loader, pci, iommu_vtd, x86_64_test);
 * - base's own interfaces hide a type: the allocator's, the clock's and the context's data, the carrier's, the stack
 *   trace's addresses (the kernel, limine_boot);
 * - a device's callbacks take their context without a type, which Hemera's function values, capturing nothing, need
 *   (fat, gpt, slopfs, the servers and tests that give one, image_builder);
 * - structs are read at offsets in a buffer of bytes, from the address of its data, which base gives as a rawptr
 *   (events_service). A string's bytes are string_bytes(text), not its data.
 */
RAW_POINTERS :: string.[
    "arch_aarch64", "arch_x86_64", "container_service", "elf_loader", "events_service", "fat", "fat_server", "fat_test",
    "frames", "gpt", "gpt_test", "image_builder", "iommu_vtd", "kernel", "limine_boot", "partition_server", "pci",
    "slopfs", "slopfs_test", "volume_server", "x86_64_test",
]

// Functions of the kernel's, as package.function, that may discard a Result: losing its error is right there.
DISCARDED_RESULTS :: string.[
    // A block another one's tables already cover is mapped already
    "arch_aarch64.init_kernel_page_table",
    // Cleaning up after a failure, whose own error is the one given
    "kernel.sys_channel_create",
    // A test's unmap of a page it mapped
    "kernel.test_shootdown",
]

/*
 * Functions of the kernel's, as package.function, that an interrupt handler may reach though they allocate: what
 * they do without memory is right there.
 */
INTERRUPT_ALLOCATIONS :: string.[
    // A woken thread's wait, armed again as it's resumed, which without memory waits without its deadline
    "kernel.grow_heap",
]

is_listed_in :: fn(names: string[], name: string) -> bool {
    for listed in names {
        if listed == name {
            return true
        }
    }
    return false
}

// Whether names has package.function.
is_listed_function :: fn(names: string[], package: string, function: string) -> bool {
    for listed in names {
        if listed.count == package.count + 1 + function.count && package.count < listed.count && starts_with(listed, package)
            && listed[package.count] == '.' && ends_with(listed, function) {
            return true
        }
    }
    return false
}

// Text

contains :: fn(text: string, part: string) -> bool {
    return find(text, part, 0) != NOT_FOUND
}

NOT_FOUND : usize : 0xffffffffffffffff
NEWLINE :: "\n"

// Where part is in text, at or after from, or NOT_FOUND.
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

// Whether text has size_of(name), name whole, between from and to.
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

// A call's name without its generic arguments: new for new[u64].
generic_name :: fn(name: string) -> string {
    for character, index in name {
        if character == '[' {
            return string_of(cast[ptr[u8]](name.data), index)
        }
    }
    return name
}

// Whether a path has folder, written with /, in it, whichever separator the path uses.
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

// Whether part is in text at at.
matches_at :: fn(text: string, at: usize, part: string) -> bool {
    for character, index in part {
        if at + index >= text.count || text[at + index] != character {
            return false
        }
    }
    return true
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
