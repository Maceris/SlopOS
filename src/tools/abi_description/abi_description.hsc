/**
 * The ABI description (roadmap 20a, decisions/0201, 0025): a hosted program that holds a description of the ABI
 * package, Hemera's std:os/slop_os, worked out when it's compiled, and writes it, or compares it with another, saying
 * each change and whether 0025 forbids it once ABI v1 is declared.
 *
 *     abi_description --write <file>
 *     abi_description --compare <file> [--exact]
 *
 * The description is a line for each thing that's frozen at v1 (knowledge/design/system-abi.md §1), sorted so two of
 * them compare line by line:
 * - syscall <number> <name> : <signature>, each member of Syscalls, a call's number its index;
 * - const <name> : <type> = <value>, each integer, bool or enum constant of the package's;
 * - for each struct, enum, union and alias the package declares, or that one of them reaches through a field, a
 *   variant or a signature: a line naming it, its size and alignment, then a line for each field (its offset and
 *   type), member (its value) or variant (its types' offsets).
 *
 * Compared, a call, a constant or a type that's gone, a call whose name or signature changed, an enum member whose value
 * changed, or a type whose layout changed is forbidden; a call appended, a new constant, type or enum member, and a
 * struct that grew past its old fields where its first field is size (a size-prefixed struct) are allowed. With
 * --exact, as before v1, any difference fails, so every change to the ABI is one the description is updated for.
 * Exits 0 if what's compared passes, 1 if not, 2 for a file it can't read or write.
 */
package abi_description

import compiler from "base:compiler"
import runtime from "base:runtime"
import io from "std:io"
import os from "std:os"
import slop_os from "std:os/slop_os"
import strings from "std:strings"
import text_buffer from "std:text_buffer"

/** The ABI package's description, worked out at compile time (describe). */
DESCRIPTION :: describe()

/**
 * Describe the ABI package, as the file's comment says.
 *
 * @return The description, its lines each ended by a line break.
 */
describe :: fn() -> string {
    package :: compiler.package_info("slop_os") or_else compiler.PackageInfo.{}
    lines : string[..]
    // The calls, in number order
    calls :: cast[ptr[compiler.TypeInfoStruct]](type_info_of(slop_os.Syscalls))
    for member, index in calls.members {
        add(&lines, line("syscall % % : %", index, member.name, name_of(member.member_type)))
    }
    // The constants
    for constant in package.constants {
        info :: type_info_of(constant.type)
        scalar :: info.variant == .INTEGER || info.variant == .BOOLEAN || info.variant == .ENUM
        if scalar {
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
    }
    // In the order the package declares things, which is the same each build; compare treats lines as a set
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
 * Format a line.
 *
 * @param format_string The text, with a % for each value.
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
 * @param info The type: a struct, enum, union or alias.
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

/**
 * Write the description, or compare it with another, as the file's comment says.
 *
 * @return 0 if it passed, 1 if not, 2 for a file it couldn't read or write, 3 for wrong arguments.
 */
main :: fn() -> int {
    arguments :: os.arguments()
    if arguments.count >= 3 && arguments[1] == "--write" {
        if os.write_entire_file(arguments[2], DESCRIPTION) != null {
            runtime.log_error("abi_description: can't write %", arguments[2])
            return 2
        }
        return 0
    }
    if arguments.count >= 3 && arguments[1] == "--compare" {
        exact :: arguments.count >= 4 && arguments[3] == "--exact"
        old :: match os.read_entire_file(arguments[2]) {
            case Ok(read) => cast[string](read)
            case Error(error) => {
                runtime.log_error("abi_description: can't read %", arguments[2])
                return 2
            }
        }
        return compare(old, DESCRIPTION, exact)
    }
    runtime.log_error("usage: abi_description --write <file> | --compare <file> [--exact]")
    return 3
}

/**
 * Compare an old description with the new one, printing each change and whether 0025 forbids it.
 *
 * Lines are compared as sets: one only in the old is gone or changed, one only in the new is added or changed. A
 * line's key is what names it (a call's number, a constant's name, a type's name and its field's index, member's name
 * or variant's index), so a key in both with different lines is a change.
 *
 * @param old The old description.
 * @param new The new one.
 * @param exact Whether any difference fails, as before v1.
 * @return 0 if it passes, 1 if not.
 */
compare :: fn(old #escaping : string, new #escaping : string, exact : bool) -> int {
    before_lines := lines_of(old)
    after_lines := lines_of(new)
    failed := false
    differences := 0
    for each in before_lines {
        if !has_line(after_lines, each) {
            differences += 1
            key :: key_of(each)
            replaced :: line_with_key(after_lines, key)
            if replaced == "" {
                io.println(line("gone, forbidden: %", each))
                failed = true
            }
            else {
                allowed :: grown(old, new, each, replaced)
                verdict :: if allowed { "allowed" } else { "forbidden" }
                io.println(line("changed, %: %\n    now: %", verdict, each, replaced))
                failed = failed || !allowed
            }
        }
    }
    for each in after_lines {
        if !has_line(before_lines, each) && line_with_key(before_lines, key_of(each)) == "" {
            differences += 1
            allowed :: added_allowed(before_lines, each)
            verdict :: if allowed { "allowed" } else { "forbidden" }
            io.println(line("added, %: %", verdict, each))
            failed = failed || !allowed
        }
    }
    if differences == 0 {
        io.println("the same")
    }
    return if failed || (exact && differences != 0) { 1 } else { 0 }
}

/**
 * Split a description into its lines.
 *
 * @param text The description.
 * @return Its lines, without their line breaks, a carriage return before one included, as a checkout on Windows may
 *     write them; empty ones left out.
 */
lines_of :: fn(text #escaping : string) -> string[..] {
    found : string[..]
    start := cast[usize](0)
    loop {
        if start >= text.count {
            break
        }
        end :: strings.find(text, "\n", start) or_else text.count
        piece :: strings.slice(text, start, end)
        kept :: if strings.ends_with(piece, "\r") { strings.slice(piece, 0, piece.count - 1) } else { piece }
        if kept != "" {
            runtime.array_add(&found, kept)
        }
        start = end + 1
    }
    return found
}

/**
 * Tell whether a description has a line.
 *
 * @param lines Its lines.
 * @param wanted The line.
 * @return True if it's one of them.
 */
has_line :: fn(lines : string[..], wanted : string) -> bool {
    for each in lines {
        if each == wanted {
            return true
        }
    }
    return false
}

/**
 * The part of a line that names what it describes: up to its " : " or " = " for a call, a constant and a type's
 * first line, up to a field's offset, a member's value or a variant's types for theirs.
 *
 * @param text The line.
 * @return Its key.
 */
key_of :: fn(text : string) -> string {
    for mark in string.[" offset ", " = ", " : ", ":"] {
        match strings.find(text, mark) {
            case Some(at) => return strings.slice(text, 0, at)
            case None => {}
        }
    }
    return text
}

/**
 * Find a line by its key.
 *
 * @param lines The lines.
 * @param key The key.
 * @return The line with that key, or empty if there's none.
 */
line_with_key :: fn(lines : string[..], key : string) -> string {
    for each in lines {
        if key_of(each) == key {
            return each
        }
    }
    return ""
}

/**
 * Tell whether a changed line is a struct growing as 0025 allows: a size-prefixed struct's first line, where it has a
 * size field in both descriptions (size_prefixed), or the call table's (Syscalls), which grows by the calls appended;
 * its size larger, never smaller. Its old fields' own lines are compared as any others are.
 *
 * @param old The old description.
 * @param new The new one.
 * @param was The changed line, as it was.
 * @param now The line now.
 * @return True if the change is such a struct's size growing.
 */
grown :: fn(old #escaping : string, new #escaping : string, was : string, now : string) -> bool {
    if !strings.contains(was, " : struct size ") || !strings.contains(now, " : struct size ") {
        return false
    }
    if size_of_line(now) <= size_of_line(was) {
        return false
    }
    name :: strings.slice(was, 5, strings.find(was, " : struct") or_else 5)
    if name == CALL_TABLE {
        return true
    }
    return size_prefixed(lines_of(old), name) && size_prefixed(lines_of(new), name)
}

/** The struct whose members are the system calls, which grows by a field for each call appended. */
CALL_TABLE :: "Syscalls"

/**
 * Read a struct's size from its first line, "type <name> : struct size <bytes> align <bytes>".
 *
 * @param text The line.
 * @return The size; 0 if the line has none that reads.
 */
size_of_line :: fn(text : string) -> u64 {
    at :: (strings.find(text, " : struct size ") or_return 0) + 15
    size := cast[u64](0)
    for i in at..<text.count {
        digit :: cast[u8](text[i])
        if digit < 48 || digit > 57 {
            break
        }
        size = size * 10 + cast[u64](digit - 48)
    }
    return size
}

/**
 * Tell whether a struct is size-prefixed: one of its fields is named size, which says how much of it a reader has, so
 * it may grow past the fields it had (0025), as the startup block does.
 *
 * @param lines A description's lines.
 * @param name The struct's name.
 * @return True if the description gives the struct a size field.
 */
size_prefixed :: fn(lines : string[..], name : string) -> bool {
    prefix :: line("type % field ", name)
    for each in lines {
        if strings.starts_with(each, prefix) && strings.contains(each, " size offset ") {
            return true
        }
    }
    return false
}

/**
 * Tell whether an added line may be added after v1: a call (and the call table's field for it), a constant, a type,
 * an enum member, a field of a size-prefixed struct that the old description had, or a variant of a new union; not a
 * variant of a union the old one had.
 *
 * @param before_lines The old description's lines.
 * @param added The added line.
 * @return True if 0025 allows it.
 */
added_allowed :: fn(before_lines : string[..], added : string) -> bool {
    if strings.starts_with(added, "syscall ") || strings.starts_with(added, "const ") {
        return true
    }
    if strings.contains(added, " member ") {
        return true
    }
    // The call table's field of a call appended: the call's own line says whether its number was free
    if strings.contains(added, " field ") {
        name :: strings.slice(added, 5, strings.find(added, " field ") or_else 5)
        if name == CALL_TABLE || size_prefixed(before_lines, name) {
            return true
        }
        return line_with_key(before_lines, line("type %", name)) == ""
    }
    // A variant of a union the old description had, whose old readers don't know its tag
    if strings.contains(added, " variant ") {
        name :: strings.slice(added, 5, strings.find(added, " variant ") or_else 5)
        return line_with_key(before_lines, line("type %", name)) == ""
    }
    // A new type's own line
    return true
}
