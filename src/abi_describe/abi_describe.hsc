/**
 * The ABI package's description (roadmap 20a, decisions/0201, 0025): Hemera's std:os/slop_os as a list of lines, worked
 * out when this package is compiled, for whatever architecture it's compiled for, as the package has parts that differ
 * by architecture (THREAD_REGISTERS, the register order). The ABI description tool (src/tools/abi_description) holds
 * its own machine's and compares descriptions; the build (src/build, targets=tools) compiles this package for each
 * architecture SlopOS runs on and writes each one's description beside the tools.
 *
 * The description is a line for each thing that's frozen at v1 (knowledge/design/system-abi.md §1):
 * - syscall <number> <name> : <signature>, each member of Syscalls, a call's number its index;
 * - const <name> : <type> = <value>, each constant of an integer, bool or enum type, or an alias of one (Rights,
 *   Signals, Protection, Handle);
 * - for each struct, enum, union and alias the package declares, or that one of them reaches through a field, a
 *   variant or a signature: a line naming it, its size and alignment, then a line for each field (its offset and
 *   type), member (its value) or variant (its types' offsets).
 *
 * Working it out also checks two rules of the ABI's, each a compile error where it's broken: no struct's fields leave
 * bytes between them or after the last that no field names (abi_describe:E0001), so every byte of a layout is one a
 * reader can tell is meant to be zero or what it is; and no error tag means two things (abi_describe:E0002): across
 * every system call's error enum, one value has one name, and one name one value.
 */
package abi_describe

import compiler from "base:compiler"
import runtime from "base:runtime"
import slop_os from "std:os/slop_os"
import strings from "std:strings"
import text_buffer from "std:text_buffer"

/** The ABI package's description, worked out at compile time (describe), for the architecture compiled for. */
DESCRIPTION :: describe()

/**
 * Describe the ABI package, as the file's comment says, reporting a compile error for a struct with a gap or error tags
 * that disagree.
 *
 * @param location Where a broken rule is reported when the type has no declaration of its own to report it at.
 * @return The description, its lines each ended by a line break, in the order the package declares things, which is
 *     the same each build.
 */
describe :: fn(location := #caller_location) -> string {
    package :: compiler.package_info("slop_os") or_else compiler.PackageInfo.{}
    lines : string[..]
    // The calls, in number order
    calls :: cast[ptr[compiler.TypeInfoStruct]](type_info_of(slop_os.Syscalls))
    for member, index in calls.members {
        add(&lines, line("syscall % % : %", index, member.name, name_of(member.member_type)))
    }
    // The constants of integer, bool and enum types, and of aliases of them
    for constant in package.constants {
        info :: type_info_of(constant.type)
        if is_scalar(info) {
            add(&lines, line("const % : % = %", constant.name, name_of(info), constant.value))
        }
    }
    // The types: the package's own, then what they reach, each once
    seen : ptr[compiler.TypeInfo][..]
    for declared in package.types {
        reach(&seen, type_info_of(declared.type))
    }
    reach(&seen, type_info_of(slop_os.Syscalls))
    for info in seen {
        define(&lines, info)
        check_gaps(info, where_declared(&package, info, location))
    }
    check_error_tags(calls, &package, location)
    text : u8[..]
    for each in lines {
        for byte in string_bytes(each) {
            runtime.array_add(&text, byte)
        }
        runtime.array_add(&text, cast[u8](10))
    }
    if text.count == 0 {
        return ""
    }
    return string_of(&text[0], text.count)
}

/**
 * Tell whether a constant's type is one the description has a line for: an integer, bool or enum, or an alias of one.
 *
 * @param info The constant's type.
 * @return True for such a type, through any aliases; false for anything else, a string or an array among them.
 */
is_scalar :: fn(info : ptr[compiler.TypeInfo]) -> bool {
    base :: slop_os.underlying(info)
    return base.variant == .INTEGER || base.variant == .BOOLEAN || base.variant == .ENUM
}

/**
 * Find where a type is declared, to report a broken rule at.
 *
 * @param package The ABI package, whose declarations are looked in.
 * @param info The type.
 * @param otherwise Where to report it when the package doesn't declare it.
 * @return Its declaration's location, or otherwise.
 */
where_declared :: fn(
    package : ptr[compiler.PackageInfo],
    info : ptr[compiler.TypeInfo],
    otherwise : runtime.SourceCodeLocation
) -> runtime.SourceCodeLocation {
    for declared in package.types {
        if type_info_of(declared.type) == info {
            return declared.location
        }
    }
    return otherwise
}

/**
 * Report a compile error for a struct whose fields leave bytes unnamed: between two of them, as alignment pads, or
 * after the last, up to its size (abi_describe:E0001). A union-like or packed struct, and anything but a struct, has
 * none to report.
 *
 * @param info The type.
 * @param location Where it's reported.
 */
check_gaps :: fn(info : ptr[compiler.TypeInfo], location : runtime.SourceCodeLocation) {
    if info.variant != .STRUCT {
        return void
    }
    layout :: cast[ptr[compiler.TypeInfoStruct]](info)
    if layout.is_union || layout.is_packed {
        return void
    }
    end := cast[usize](0)
    for member in layout.members {
        if member.offset > end {
            compiler.report(
                .Error,
                "abi_describe",
                "E0001",
                location,
                "%1 leaves bytes %2 to %3 unnamed, before %4: name them, as a reserved field documented as zeros",
                layout.name,
                end,
                member.offset - 1,
                member.name
            )
        }
        if member.offset + member.member_type.size > end {
            end = member.offset + member.member_type.size
        }
    }
    if info.size > end {
        compiler.report(
            .Error,
            "abi_describe",
            "E0001",
            location,
            "%1 leaves bytes %2 to %3 unnamed, after its last field: name them, as a reserved field of zeros",
            layout.name,
            end,
            info.size - 1
        )
    }
}

/**
 * Report a compile error for any error tag that means two things across the system calls' error enums
 * (abi_describe:E0002): a value two enums name differently, or a name two enums give different values, as the package
 * says tags shared between them mean the same.
 *
 * @param calls Syscalls' struct information, whose members' results name the error enums.
 * @param package The ABI package, for where an enum is declared.
 * @param location Where it's reported for an enum the package doesn't declare.
 */
check_error_tags :: fn(
    calls : ptr[compiler.TypeInfoStruct],
    package : ptr[compiler.PackageInfo],
    location : runtime.SourceCodeLocation
) {
    errors : ptr[compiler.TypeInfoEnum][..]
    for member in calls.members {
        function :: cast[ptr[compiler.TypeInfoFunction]](member.member_type)
        for output in function.output {
            base :: slop_os.underlying(output.type)
            if base.variant != .UNION {
                continue
            }
            for variant in cast[ptr[compiler.TypeInfoUnion]](base).variants {
                for each in variant.types {
                    error :: slop_os.underlying(each)
                    if variant.name == "Error" && error.variant == .ENUM && !has_enum(errors, error) {
                        runtime.array_add(&errors, cast[ptr[compiler.TypeInfoEnum]](error))
                    }
                }
            }
        }
    }
    for one, i in errors {
        for other, j in errors {
            if j > i {
                compare_tags(one, other, where_declared(package, cast[ptr[compiler.TypeInfo]](other), location))
            }
        }
    }
}

/**
 * Tell whether an enum is among those collected.
 *
 * @param errors The enums collected so far.
 * @param info The enum.
 * @return True if it's one of them.
 */
has_enum :: fn(errors : ptr[compiler.TypeInfoEnum][..], info : ptr[compiler.TypeInfo]) -> bool {
    for each in errors {
        if cast[ptr[compiler.TypeInfo]](each) == info {
            return true
        }
    }
    return false
}

/**
 * Report a compile error for each tag two error enums disagree on (abi_describe:E0002).
 *
 * @param one An enum.
 * @param other Another.
 * @param location Where it's reported: other's declaration.
 */
compare_tags :: fn(
    one : ptr[compiler.TypeInfoEnum],
    other : ptr[compiler.TypeInfoEnum],
    location : runtime.SourceCodeLocation
) {
    for name, i in one.members {
        for other_name, j in other.members {
            if i >= one.values.count || j >= other.values.count {
                continue
            }
            same_value :: one.values[i] == other.values[j]
            same_name :: name == other_name
            if same_value != same_name {
                compiler.report(
                    .Error,
                    "abi_describe",
                    "E0002",
                    location,
                    "%1.%2 is %3 but %4.%5 is %6: one error tag means one thing across the system calls' errors",
                    one.name,
                    name,
                    cast[u64](one.values[i]),
                    other.name,
                    other_name,
                    cast[u64](other.values[j])
                )
            }
        }
    }
}

/**
 * Format a line.
 *
 * @param format_string The text, with a % for each value (docs/format_strings.md).
 * @param values The values.
 * @return The line, from the context's allocator; empty if there was no memory for it.
 */
line :: fn(format_string : string, values : any...) -> string {
    storage : u8[4096]
    text := text_buffer.make(storage)
    text_buffer.append_format(&text, format_string, values)
    return match strings.clone(text_buffer.as_string(&text)) {
        case Ok(kept) => kept
        case Error(error) => ""
    }
}

/**
 * Add a line to the description.
 *
 * @param lines The lines so far.
 * @param text The line, without a line break.
 */
add :: fn(lines : ptr[mut string[..]], text #escaping : string) {
    runtime.array_add(lines, text)
}

/**
 * Name a type as a field's or a signature's type is written: a struct, enum, union or alias by its name; an integer
 * as u or i and its bits, with _be for big-endian; and the rest as Hemera writes them.
 *
 * @param info The type's description.
 * @return Its name, from the context's allocator.
 */
name_of :: fn(info : ptr[compiler.TypeInfo]) -> string {
    return match info.variant {
        case .ALIAS => cast[ptr[compiler.TypeInfoAlias]](info).name
        case .STRUCT => cast[ptr[compiler.TypeInfoStruct]](info).name
        case .ENUM => cast[ptr[compiler.TypeInfoEnum]](info).name
        case .UNION => union_name(cast[ptr[compiler.TypeInfoUnion]](info))
        case .INTEGER => integer_name(cast[ptr[compiler.TypeInfoInteger]](info))
        case .BOOLEAN => if info.size == 1 { "bool" } else { line("b%", info.size * 8) }
        case .CHAR => "char"
        case .FLOAT => line("f%", info.size * 8)
        case .STRING => if cast[ptr[compiler.TypeInfoString]](info).is_raw { "cstring" } else { "string" }
        case .POINTER => pointer_name(cast[ptr[compiler.TypeInfoPointer]](info))
        case .ARRAY => array_name(cast[ptr[compiler.TypeInfoArray]](info))
        case .FUNCTION => function_name(cast[ptr[compiler.TypeInfoFunction]](info))
        case .VECTOR => vector_name(cast[ptr[compiler.TypeInfoVector]](info))
        case .VOID => "void"
        case .ANY => "any"
        case .TYPE => "type"
        case _ => line("<% bytes>", info.size)
    }
}

/**
 * Name an integer type.
 *
 * @param info Its description.
 * @return u or i, its bits, and _be where it's big-endian.
 */
integer_name :: fn(info : ptr[compiler.TypeInfoInteger]) -> string {
    sign :: if info.is_signed { "i" } else { "u" }
    order :: if info.endianness == .BIG { "_be" } else { "" }
    return line("%1%2%3", sign, info.size * 8, order)
}

/**
 * Name a pointer type.
 *
 * @param info Its description.
 * @return rawptr, or ptr[T], ptr[mut T] or relptr[T].
 */
pointer_name :: fn(info : ptr[compiler.TypeInfoPointer]) -> string {
    base :: info.base_type or_return "rawptr"
    kind :: if info.is_relative { "relptr" } else { "ptr" }
    mutable :: if info.is_mutable { "mut " } else { "" }
    return line("%1[%2%3]", kind, mutable, name_of(base))
}

/**
 * Name an array type, each dimension outermost first: [n] for a static one, [] for a view, [..] for a dynamic one.
 *
 * @param info Its description.
 * @return The element type's name, then its dimensions.
 */
array_name :: fn(info : ptr[compiler.TypeInfoArray]) -> string {
    name := name_of(info.base_type)
    for dimension in info.dimensions {
        written :: match dimension.type {
            case .STATIC => line("[%]", dimension.count)
            case .DYNAMIC => "[..]"
            case _ => "[]"
        }
        name = line("%1%2", name, written)
    }
    return name
}

/**
 * Name a function type.
 *
 * @param info Its description.
 * @return fn(name : T, ...) -> R, as it's declared.
 */
function_name :: fn(info : ptr[compiler.TypeInfoFunction]) -> string {
    inputs := ""
    for input, i in info.input {
        separator :: if i == 0 { "" } else { ", " }
        inputs = line("%1%2%3 : %4", inputs, separator, input.name, name_of(input.type))
    }
    outputs := ""
    for output, i in info.output {
        separator :: if i == 0 { "" } else { ", " }
        outputs = line("%1%2%3", outputs, separator, name_of(output.type))
    }
    returned :: if outputs == "" { "" } else { line(" -> %", outputs) }
    ending :: if info.never_returns { " #never_returns" } else { "" }
    return line("fn(%1)%2%3", inputs, returned, ending)
}

/**
 * Name a vector type.
 *
 * @param info Its description.
 * @return vector[T, n].
 */
vector_name :: fn(info : ptr[compiler.TypeInfoVector]) -> string {
    return line("vector[%, %]", name_of(info.element_type), info.count)
}

/**
 * Name a union: by its name, or by its variants where it has none.
 *
 * @param info Its description.
 * @return Its name, or union(T | U | ...).
 */
union_name :: fn(info : ptr[compiler.TypeInfoUnion]) -> string {
    if info.name != "" {
        return info.name
    }
    variants := ""
    for variant, i in info.variants {
        separator :: if i == 0 { "" } else { " | " }
        variants = line("%1%2%3", variants, separator, variant.name)
    }
    return line("union(%)", variants)
}

/**
 * Collect a type and every named type it reaches, each once.
 *
 * @param seen The types collected so far.
 * @param info The type.
 */
reach :: fn(seen : ptr[mut ptr[compiler.TypeInfo][..]], info #escaping : ptr[compiler.TypeInfo]) {
    named :: info.variant == .STRUCT || info.variant == .ENUM || info.variant == .UNION || info.variant == .ALIAS
    if named {
        for each in seen^ {
            if each == info {
                return void
            }
        }
        runtime.array_add(seen, info)
    }
    match info.variant {
        case .ALIAS => reach(seen, cast[ptr[compiler.TypeInfoAlias]](info).base_type)
        case .STRUCT => {
            for member in cast[ptr[compiler.TypeInfoStruct]](info).members {
                reach(seen, member.member_type)
            }
        }
        case .UNION => {
            for variant in cast[ptr[compiler.TypeInfoUnion]](info).variants {
                for each in variant.types {
                    reach(seen, each)
                }
            }
        }
        case .ARRAY => reach(seen, cast[ptr[compiler.TypeInfoArray]](info).base_type)
        case .POINTER => {
            pointer :: cast[ptr[compiler.TypeInfoPointer]](info)
            match pointer.base_type {
                case Some(base) => reach(seen, base)
                case None => {}
            }
        }
        case .FUNCTION => {
            function :: cast[ptr[compiler.TypeInfoFunction]](info)
            for input in function.input {
                reach(seen, input.type)
            }
            for output in function.output {
                reach(seen, output.type)
            }
        }
        case _ => {}
    }
}

/**
 * Add a named type's lines: one naming it, then one for each field, member or variant, each starting with the type's
 * name so they sort together.
 *
 * @param lines The lines so far.
 * @param info The type: a struct, enum, union or alias; anything else adds nothing.
 */
define :: fn(lines : ptr[mut string[..]], info : ptr[compiler.TypeInfo]) {
    match info.variant {
        case .ALIAS => {
            alias :: cast[ptr[compiler.TypeInfoAlias]](info)
            own :: if alias.is_distinct { "distinct " } else { "" }
            add(lines, line("type %1 = %2%3", alias.name, own, name_of(alias.base_type)))
        }
        case .STRUCT => {
            layout :: cast[ptr[compiler.TypeInfoStruct]](info)
            packed :: if layout.is_packed { " packed" } else { "" }
            add(lines, line("type %1 : struct size %2 align %3%4", layout.name, info.size, layout.alignment, packed))
            for member, i in layout.members {
                bounded :: if member.has_at_most { line(" at_most %", member.at_most) } else { "" }
                add(lines, line(
                    "type %1 field %2{04} %3 offset %4 : %5%6", layout.name, i, member.name, member.offset,
                    name_of(member.member_type), bounded
                ))
            }
        }
        case .ENUM => {
            values :: cast[ptr[compiler.TypeInfoEnum]](info)
            add(lines, line("type % : enum %", values.name, name_of(values.backing_type)))
            for member, i in values.members {
                if i < values.values.count {
                    add(lines, line("type % member % = %", values.name, member, values.values[i]))
                }
            }
        }
        case .UNION => {
            variants :: cast[ptr[compiler.TypeInfoUnion]](info)
            tag :: match variants.tag_type {
                case Some(tagged) => name_of(tagged)
                case None => "none"
            }
            add(lines, line("type % : union size % tag %", union_name(variants), info.size, tag))
            for variant, i in variants.variants {
                parts := ""
                for each, j in variant.types {
                    if j < variant.offsets.count {
                        parts = line("% %@%", parts, name_of(each), variant.offsets[j])
                    }
                }
                add(lines, line("type % variant %{04} %:%", union_name(variants), i, variant.name, parts))
            }
        }
        case _ => {}
    }
}
