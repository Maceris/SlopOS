/**
 * The ABI description (roadmap 20a, decisions/0201, 0025): a hosted program that writes the ABI package's description,
 * Hemera's std:os/slop_os's as src/abi_describe works it out for this machine's architecture, or compares two, saying
 * each change and whether 0025 forbids it once ABI v1 is declared.
 *
 *     abi_description --write <file>
 *     abi_description --compare <old file> [<new file>] [--exact]
 *
 * Without a new file, --compare compares the old with this machine's description. The build (src/build, targets=tools)
 * writes each architecture's beside the tools, abi_description.<arch>.txt for x86_64, aarch64 and riscv64, as the
 * package differs by architecture; tools/unit_tests.py compares each with docs/specs/abi_description.<arch>.txt,
 * exactly, and with v1's, docs/specs/abi_v1.<arch>.txt, by 0025's rules.
 *
 * Compared, a call, a constant or a type that's gone, a call whose name or signature changed, an enum member whose
 * value changed, or a type whose layout changed is forbidden. Allowed are a call appended, a new constant, type or enum
 * member, ABI_VERSION (VERSION_CONSTANT) larger, and a growable struct (GROWABLE: a size-prefixed struct its readers
 * take as long as its size says) growing: past its old fields, or its last field, an array, longer; never one used as
 * an array's element or a field of another struct, whose growing would move what's after it. With --exact, any
 * difference fails, so every change to the ABI is one the descriptions are written again for. Exits 0 if what's
 * compared passes, 1 if not, 2 for a file it can't read or write, 3 for wrong arguments.
 */
package abi_description

import runtime from "base:runtime"
import io from "std:io"
import os from "std:os"
import strings from "std:strings"
import text_buffer from "std:text_buffer"
import abi_describe from "../../abi_describe"

/**
 * The structs that may grow after v1, as 0025 allows a size-prefixed struct to: each says in a field how much of it
 * its writer wrote (StartupBlock's size, ThreadDebug's size), and its reader takes the rest as zeros; StopInfo and
 * CpuBudgetInfo, which the kernel writes, say how much the caller has room for, and how much it wrote.
 */
GROWABLE :: string.["StartupBlock", "ThreadDebug", "StopInfo", "CpuBudgetInfo"]

/** The line of ABI_VERSION, the ABI's version, which only grows, as a later version keeps the earlier's promises. */
VERSION_CONSTANT :: "const ABI_VERSION : u32 = "

/** The struct whose members are the system calls, which grows by a field for each call appended. */
CALL_TABLE :: "Syscalls"

/**
 * Write the description, or compare it with another, as the file's comment says.
 *
 * @return 0 if it passed, 1 if not, 2 for a file it couldn't read or write, 3 for wrong arguments.
 */
main :: fn() -> int {
    arguments :: os.arguments()
    if arguments.count >= 3 && arguments[1] == "--write" {
        if os.write_entire_file(arguments[2], abi_describe.DESCRIPTION) != null {
            runtime.log_error("abi_description: can't write %", arguments[2])
            return 2
        }
        return 0
    }
    if arguments.count >= 3 && arguments[1] == "--compare" {
        exact :: arguments[arguments.count - 1] == "--exact"
        given :: arguments.count - (if exact { 1 } else { 0 })
        old :: read(arguments[2]) or_return 2
        new := abi_describe.DESCRIPTION
        if given >= 4 {
            new = read(arguments[3]) or_return 2
        }
        return compare(old, new, exact)
    }
    runtime.log_error("usage: abi_description --write <file> | --compare <old file> [<new file>] [--exact]")
    return 3
}

/**
 * Read a description.
 *
 * @param path The file.
 * @return Its text; null, the failure logged, if it can't be read.
 */
read :: fn(path : string) -> string? {
    return match os.read_entire_file(path) {
        case Ok(text) => cast[string](text)
        case Error(error) => {
            runtime.log_error("abi_description: can't read %", path)
            null
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
 * Compare an old description with a new one, printing each change and whether 0025 forbids it.
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
                allowed :: grown(after_lines, each, replaced) || lengthened(after_lines, each, replaced) ||
                    raised(each, replaced)
                verdict :: if allowed { "allowed" } else { "forbidden" }
                io.println(line("changed, %1: %2\n    now: %3", verdict, each, replaced))
                failed = failed || !allowed
            }
        }
    }
    for each in after_lines {
        if !has_line(before_lines, each) && line_with_key(before_lines, key_of(each)) == "" {
            differences += 1
            allowed :: added_allowed(before_lines, after_lines, each)
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
 * Give the name of the type a type's line is about: what's between "type " and the first of " field ", " member ",
 * " variant ", " : " and " = ", as a union's name, like Result[HandleInfo, HandleError], has spaces of its own.
 *
 * @param text The line.
 * @return The type's name; empty for a line that isn't a type's.
 */
type_named :: fn(text : string) -> string {
    if !strings.starts_with(text, "type ") {
        return ""
    }
    end := text.count
    for mark in string.[" field ", " member ", " variant ", " : ", " = "] {
        at :: strings.find(text, mark, 5) or_else text.count
        if at < end {
            end = at
        }
    }
    return strings.slice(text, 5, end)
}

/**
 * Tell whether a struct may grow: the call table, or one of GROWABLE that the new description doesn't use as an
 * array's element or a field of another struct (embedded).
 *
 * @param after_lines The new description's lines.
 * @param name The struct's name.
 * @return True if it may grow.
 */
growable :: fn(after_lines : string[..], name : string) -> bool {
    if name == CALL_TABLE {
        return true
    }
    for each in GROWABLE {
        if each == name {
            return !embedded(after_lines, name)
        }
    }
    return false
}

/**
 * Tell whether a description uses a type inside another's layout: as a field's type, an array's element, or a union
 * variant's, where its growing would move what's after it. A pointer to it isn't.
 *
 * @param lines The description's lines.
 * @param name The type's name.
 * @return True if a field or a variant holds it.
 */
embedded :: fn(lines : string[..], name : string) -> bool {
    plain :: line(" : %", name)
    element :: line(" : %[", name)
    held :: line(" %@", name)
    for each in lines {
        if strings.contains(each, " field ") && (strings.ends_with(each, plain) || strings.contains(each, element)) {
            return true
        }
        if strings.contains(each, " variant ") && strings.contains(each, held) {
            return true
        }
    }
    return false
}

/**
 * Tell whether a changed line is a struct growing as 0025 allows: a growable struct's first line (growable), its size
 * larger, never smaller. Its old fields' own lines are compared as any others are.
 *
 * @param after_lines The new description's lines.
 * @param was The changed line, as it was.
 * @param now The line now.
 * @return True if the change is such a struct's size growing.
 */
grown :: fn(after_lines : string[..], was : string, now : string) -> bool {
    if !strings.contains(was, " : struct size ") || !strings.contains(now, " : struct size ") {
        return false
    }
    if number_after(now, " : struct size ") <= number_after(was, " : struct size ") {
        return false
    }
    return growable(after_lines, type_named(was))
}

/**
 * Tell whether a changed line is the ABI's version made larger (VERSION_CONSTANT), as a later version is.
 *
 * @param was The changed line, as it was.
 * @param now The line now.
 * @return True if both are ABI_VERSION's line and now's number is larger; false for a smaller or equal one, or any
 *     other line.
 */
raised :: fn(was : string, now : string) -> bool {
    if !strings.starts_with(was, VERSION_CONSTANT) || !strings.starts_with(now, VERSION_CONSTANT) {
        return false
    }
    return number_after(now, VERSION_CONSTANT) > number_after(was, VERSION_CONSTANT)
}

/**
 * Tell whether a changed line is a growable struct's last field, an array, made longer, as more slots: the same
 * offset and element type, a larger count, and no field after it in the new description.
 *
 * @param after_lines The new description's lines.
 * @param was The field's line, as it was.
 * @param now The line now.
 * @return True if the change is that.
 */
lengthened :: fn(after_lines : string[..], was : string, now : string) -> bool {
    name :: type_named(was)
    if !strings.contains(was, " field ") || !growable(after_lines, name) {
        return false
    }
    was_open :: find_last(was, "[") or_return false
    now_open :: find_last(now, "[") or_return false
    if strings.slice(was, 0, was_open) != strings.slice(now, 0, now_open) || !strings.ends_with(now, "]") {
        return false
    }
    if number_after(now, "[") <= number_after(was, "[") {
        return false
    }
    // The last field: none with a later index
    index :: number_after(was, " field ")
    prefix :: line("type % field ", name)
    for each in after_lines {
        if strings.starts_with(each, prefix) && number_after(each, " field ") > index {
            return false
        }
    }
    return true
}

/**
 * Read the decimal number right after the last place a mark is in a line, as a struct's size, a field's index or an
 * array's count.
 *
 * @param text The line.
 * @param mark What comes before the number.
 * @return The number; 0 if the mark isn't there or no digit follows it.
 */
number_after :: fn(text : string, mark : string) -> u64 {
    at :: (find_last(text, mark) or_return 0) + mark.count
    number := cast[u64](0)
    for i in at..<text.count {
        digit :: cast[u8](text[i])
        if digit < 48 || digit > 57 {
            break
        }
        number = number * 10 + cast[u64](digit - 48)
    }
    return number
}

/**
 * Tell whether an added line may be added after v1: a call (and the call table's field for it), a constant, a type,
 * an enum member, a field of a growable struct the old description had, or a variant of a new union; not a variant
 * of a union the old one had, nor a field of another struct it had.
 *
 * @param before_lines The old description's lines.
 * @param after_lines The new description's lines.
 * @param added The added line.
 * @return True if 0025 allows it.
 */
added_allowed :: fn(before_lines : string[..], after_lines : string[..], added : string) -> bool {
    if strings.starts_with(added, "syscall ") || strings.starts_with(added, "const ") {
        return true
    }
    if strings.contains(added, " member ") {
        return true
    }
    name :: type_named(added)
    // The call table's field of a call appended: the call's own line says whether its number was free
    if strings.contains(added, " field ") {
        if growable(after_lines, name) {
            return true
        }
        return line_with_key(before_lines, line("type %", name)) == ""
    }
    // A variant of a union the old description had, whose old readers don't know its tag
    if strings.contains(added, " variant ") {
        return line_with_key(before_lines, line("type %", name)) == ""
    }
    // A new type's own line
    return true
}

/**
 * Find the last place a part is in a text.
 *
 * @param text The text.
 * @param part What's looked for, not empty.
 * @return Where its last whole occurrence starts; null if there's none.
 */
find_last :: fn(text : string, part : string) -> usize? {
    found : usize? = null
    start := cast[usize](0)
    loop {
        at :: strings.find(text, part, start) or_return found
        found = at
        start = at + 1
    }
}
