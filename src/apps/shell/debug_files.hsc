package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import slop_os from "std/os"
import programs from "../../protocols/programs"

/*
 * Programs' debug files (decisions/0185, 12e): the program linked with its DWARF, after "HDBG", then the debug table,
 * which names each local's type as a schema (Hemera's docs/compilation.md, Debug Info). The shell asks the session
 * manager for one by the program's name, and gives it to the symbols program, which reads its DWARF; the table it
 * reads itself, for the schemas a value is shown through, which the shell already reads for manifests.
 */

/** A program's debug file, mapped in the shell, and its table read. */
DebugFile :: struct {
    /** The file, a copy the shell holds; closed by free_debug_file. */
    memory : slop_os.Memory,
    /** How many bytes are the file's. */
    size : u64,
    /** Where it's mapped in the shell. */
    address : u64,
    /** How many bytes are mapped: whole pages. */
    mapped : u64,
    /** Its table's schemas, each a view of the mapped file. */
    schemas : u8[..][],
    /** Its table's locals. */
    locals : DebugLocal[..],
    /** Its table's named types: the runtime's, which memory is laid out by, like "runtime.CarrierBlock". */
    named : DebugNamed[..],
}

/** A type the debug table names, for laying out the runtime's memory. */
DebugNamed :: struct {
    /** Its name, as package.name, a view of the mapped file. */
    name : string,
    /** Its schema, as a place among the table's schemas. */
    schema : usize,
}

/** A local the debug table names. */
DebugLocal :: struct {
    /** Its function's symbol, a view of the mapped file. */
    function : string,
    /** Its name, a view of the mapped file. */
    name : string,
    /** The line it's declared on. */
    line : u64,
    /** Its type's schema, as a place among the table's schemas. */
    schema : usize,
}

/**
 * Ask the session manager for a program's debug file, without mapping it.
 *
 * @param shell The shell, whose programs connection is asked, waiting for its answer.
 * @param name The program's name, 1 to programs.MAX_NAME bytes.
 * @return The file, a handle the caller owns and closes; null without a programs connection, or for a program
 *     without one.
 */
debug_memory :: fn(shell: ptr[mut Shell], name: string) -> slop_os.Memory? {
    found :: debug_file_of(shell, name) or_return null
    return found.record
}

/**
 * Ask the session manager for a program's debug file.
 *
 * @return The file and its size, the handle the caller's; null without one.
 */
debug_file_of :: fn(shell: ptr[mut Shell], name: string) -> programs.ProgramDocumentation? {
    connection :: shell.programs or_return null
    if name.count == 0 || name.count > programs.MAX_NAME {
        return null
    }
    out := os.Outgoing.{}
    request :: os.begin[programs.Request](&out)
    request^ = .Debug(os.append(&out, string_bytes(name)))
    if programs.send_request(connection.end, shell.programs_port, &out) is_some {
        return null
    }
    into := os.Incoming.{}
    if !received(programs.receive_response(connection.end, shell.programs_port, &into, true)) {
        return null
    }
    return match os.message_of[programs.Response](&into)^ {
        case DebugFile(file) => file
        case _ => null
    }
}

/**
 * The symbols program's queries for the lines of frames, a "line" each: the first frame's program counter, and each
 * other's return address less one, which is in its call.
 *
 * @param offsets The frames, as offsets in the image, innermost first.
 * @return The queries, on the heap, never freed.
 */
line_queries :: fn(offsets: u64[]) -> string {
    text : u8[..]
    for offset, i in offsets {
        line :: message("line %{#x}\n", if i > 0 && offset > 0 { offset - 1 } else { offset })
        for byte in string_bytes(line) {
            runtime.array_add(&text, byte)
        }
    }
    if text.count == 0 {
        return ""
    }
    return string_of(&text[0], text.count)
}

/**
 * Find a program's debug file, asking the session manager's Programs connection, and read its table.
 *
 * @param shell The shell, whose programs connection is asked, waiting for its answer.
 * @param name The program's name, 1 to programs.MAX_NAME bytes.
 * @return The file, mapped, which free_debug_file lets go of; null without a programs connection, for a program
 *     without one, as a system built without debug files has, or a file that doesn't map.
 */
find_debug_file :: fn(shell: ptr[mut Shell], name: string) -> DebugFile? {
    found :: debug_file_of(shell, name) or_return null
    mapped :: (found.size + 4095) & ~cast[u64](4095)
    address :: runtime.reserve_addresses(cast[usize](mapped)) or_else 0
    if found.size == 0 || address == 0
        || (slop_os.memory_map(found.record, slop_os.startup_block().space, address, 0, mapped, slop_os.PROTECTION_READ) is_error) {
        _ = slop_os.handle_close(cast[slop_os.Handle](found.record))
        return null
    }
    file := DebugFile.{memory = found.record, size = found.size, address = address, mapped = mapped}
    read_debug_table(&file)
    return file
}

/**
 * Let go of a debug file: its table, its mapping and its handle.
 *
 * @param file The file, which can't be used after.
 */
free_debug_file :: fn(file: ptr[mut DebugFile]) {
    runtime.array_free(&file.schemas)
    runtime.array_free(&file.locals)
    runtime.array_free(&file.named)
    _ = slop_os.memory_unmap(slop_os.startup_block().space, file.address)
    _ = slop_os.handle_close(cast[slop_os.Handle](file.memory))
}

/**
 * The bytes of a mapped debug file.
 *
 * @param file The file.
 * @return Its bytes, a view of its mapping.
 */
debug_bytes :: fn(file: ptr[DebugFile]) -> u8[] {
    return view_of(cast[ptr[u8]](file.address), cast[usize](file.size))
}

/**
 * Read a debug file's table into its schemas and locals; a table that doesn't read leaves what was read of it.
 *
 * @param file The file, mapped.
 */
read_debug_table :: fn(file: ptr[mut DebugFile]) {
    bytes :: debug_bytes(file)
    elf_size :: number_at(bytes, 8, 8)
    at := 16 + elf_size
    if !text_is(bytes, at, "HDBT") || number_at(bytes, at + 4, 2) != 1 {
        return void
    }
    at += 6
    schema_count :: table_number(bytes, &at, 4)
    for i in cast[u64](0)..<schema_count {
        size :: table_number(bytes, &at, 4)
        if at + size > cast[u64](bytes.count) || at >= cast[u64](bytes.count) {
            return void
        }
        runtime.array_add(&file.schemas, view_of(&bytes[cast[usize](at)], cast[usize](size)))
        at += size
    }
    function_count :: table_number(bytes, &at, 4)
    for i in cast[u64](0)..<function_count {
        function :: table_name(bytes, &at) or_return void
        local_count :: table_number(bytes, &at, 4)
        for j in cast[u64](0)..<local_count {
            name :: table_name(bytes, &at) or_return void
            line :: table_number(bytes, &at, 4)
            _ = table_number(bytes, &at, 4)
            place :: table_number(bytes, &at, 4)
            runtime.array_add(&file.locals, DebugLocal.{function = function, name = name, line = line, schema = cast[usize](place)})
        }
    }
    named_count :: table_number(bytes, &at, 4)
    for i in cast[u64](0)..<named_count {
        name :: table_name(bytes, &at) or_return void
        place :: table_number(bytes, &at, 4)
        runtime.array_add(&file.named, DebugNamed.{name = name, schema = cast[usize](place)})
    }
}

/**
 * Find a named type's member's offset, by the type's schema in a debug file's table.
 *
 * @param file The file.
 * @param type The type's name, like "runtime.CarrierBlock".
 * @param member The member's name.
 * @return Its offset in bytes; null if the file hasn't the type, or the type hasn't the member.
 */
member_offset :: fn(file: ptr[DebugFile], type: string, member: string) -> u64? {
    for named in file.named {
        if named.name != type || named.schema >= file.schemas.count {
            continue
        }
        types := schema.parse(file.schemas[named.schema]) or_return null
        defer schema.free(&types)
        if types.types.count == 0 {
            return null
        }
        for each in types.types[0].members {
            if each.name == member {
                return each.offset
            }
        }
        return null
    }
    return null
}

/**
 * Take a little-endian number from the table, moving past it.
 *
 * @param bytes The file.
 * @param at Where it is, moved past it.
 * @param count How many bytes.
 * @return Its value; 0 past the end.
 */
table_number :: fn(bytes: u8[], at: ptr[mut u64], count: u64) -> u64 {
    value :: number_at(bytes, at^, count)
    at^ += count
    return value
}

/**
 * Take a name from the table: its length, a u32, then its bytes.
 *
 * @param bytes The file, which the name is a view of.
 * @param at Where it is, moved past it.
 * @return The name; null if it runs past the end.
 */
table_name :: fn(bytes: u8[], at: ptr[mut u64]) -> string? {
    count :: table_number(bytes, at, 4)
    start :: at^
    if start + count > cast[u64](bytes.count) || start >= cast[u64](bytes.count) {
        return null
    }
    at^ += count
    if count == 0 {
        return ""
    }
    return string_of(&bytes[cast[usize](start)], cast[usize](count))
}

/**
 * Whether bytes hold some text at a place.
 *
 * @param bytes The bytes.
 * @param at Where.
 * @param text The text.
 * @return True if all of it's there.
 */
text_is :: fn(bytes: u8[], at: u64, text: string) -> bool {
    wanted :: string_bytes(text)
    for byte, i in wanted {
        index :: at + cast[u64](i)
        if index >= cast[u64](bytes.count) || bytes[cast[usize](index)] != byte {
            return false
        }
    }
    return true
}

/**
 * Find a local's schema in a debug file's table, by its function's symbol, its name and its line.
 *
 * @param file The file.
 * @param function The function's symbol, as the symbols program says it.
 * @param name The local's name.
 * @param line The line it's declared on.
 * @return Its schema's bytes; null if the table hasn't it.
 */
local_schema :: fn(file: ptr[DebugFile], function: string, name: string, line: u64) -> u8[]? {
    for local in file.locals {
        if local.function == function && local.name == name && local.line == line && local.schema < file.schemas.count {
            return file.schemas[local.schema]
        }
    }
    return null
}

/** How deep a value's pointers are followed when it's shown: a struct's members, a view's elements and so on. */
SHOW_DEPTH :: 4
/** The most elements of an array shown; the rest are said as "...". */
SHOW_ELEMENTS : u64 : 8
/** The most bytes of a string shown; the rest are said as "...". */
SHOW_TEXT : u64 : 64

/** Where a value shown comes from: its bytes, read already, and the process its pointers point into. */
Showing :: struct #scoped {
    /** The process, whose memory pointers are read from. */
    process : slop_os.Process,
    /** Its address space. */
    space : slop_os.AddressSpace,
    /** The schema the value's type is in. */
    types : ptr[schema.Schema],
    /** What's shown, added to. */
    into : ptr[mut u8[..]],
}

/**
 * Show a value as Hemera would write it: a struct with its members, a union's variant with what it holds, an
 * optional as None or Some, a string in quotes, an array or view with its first elements, an enum by its member, and
 * a number, a bool or a pointer as itself.
 *
 * @param showing Where it comes from, and where it's shown.
 * @param place Its type's place in the schema.
 * @param value Its bytes, in its own layout, as they are in the process.
 * @param depth How many more levels of members and elements are shown.
 */
show_value :: fn(showing: ptr[mut Showing], place: usize, value: u8[], depth: int) {
    if place >= showing.types.types.count {
        add_shown(showing, "<?>")
        return void
    }
    type :: &showing.types.types[place]
    if type.size > cast[u64](value.count) {
        add_shown(showing, "<?>")
        return void
    }
    kind :: type.kind
    if kind == .Alias {
        show_value(showing, type.base, value, depth)
    }
    else if kind == .Integer {
        bits :: number_at(value, 0, if type.size <= 8 { type.size } else { 8 })
        if type.is_signed && type.size < 8 && type.size > 0 && bits >> (type.size * 8 - 1) & 1 != 0 {
            add_shown(showing, message("%", cast[i64](bits | (~cast[u64](0) << (type.size * 8)))))
        }
        else if type.is_signed && type.size >= 8 {
            add_shown(showing, message("%", cast[i64](bits)))
        }
        else {
            add_shown(showing, message("%", bits))
        }
    }
    else if kind == .Boolean {
        add_shown(showing, if number_at(value, 0, 1) != 0 { "true" } else { "false" })
    }
    else if kind == .Float && type.size == 8 {
        add_shown(showing, message("%", bit_cast[f64](number_at(value, 0, 8))))
    }
    else if kind == .Float && type.size == 4 {
        add_shown(showing, message("%", bit_cast[f32](cast[u32](number_at(value, 0, 4)))))
    }
    else if kind == .Char {
        add_shown(showing, message("U+%{x}", number_at(value, 0, 4)))
    }
    else if kind == .String {
        if type.is_raw {
            show_text(showing, number_at(value, 0, 8), SHOW_TEXT, true)
        }
        else {
            show_text(showing, number_at(value, 8, 8), number_at(value, 0, 8), false)
        }
    }
    else if kind == .Enum {
        raw :: number_at(value, 0, if type.size <= 8 { type.size } else { 8 })
        for constant in type.constants {
            if constant.value == raw {
                add_shown(showing, message(".%", constant.name))
                return void
            }
        }
        add_shown(showing, message("%(%)", type.name, raw))
    }
    else if kind == .Pointer || kind == .Function || kind == .Type {
        address :: number_at(value, 0, 8)
        add_shown(showing, if address == 0 { "null" } else { message("%{#x}", address) })
    }
    else if kind == .Struct {
        show_struct(showing, type, value, depth)
    }
    else if kind == .Union {
        show_union(showing, type, value, depth)
    }
    else if kind == .Array {
        show_array(showing, type, 0, value, depth)
    }
    else {
        add_shown(showing, "<value>")
    }
}

/**
 * Show a struct: its name and each member, "Name{a = 1, b = 2}"; a #union struct's members aren't, as which it holds
 * isn't known.
 */
show_struct :: fn(showing: ptr[mut Showing], type: ptr[schema.Type], value: u8[], depth: int) {
    add_shown(showing, type.name)
    if type.is_union || depth <= 0 {
        add_shown(showing, "{...}")
        return void
    }
    add_shown(showing, "{")
    for member, i in type.members {
        if i > 0 {
            add_shown(showing, ", ")
        }
        add_shown(showing, message("% = ", member.name))
        show_at(showing, member.type, value, member.offset, depth - 1)
    }
    add_shown(showing, "}")
}

/**
 * Show a union: an optional as None or Some(value), anything else as its variant, with what it holds,
 * "Variant(a, b)".
 */
show_union :: fn(showing: ptr[mut Showing], type: ptr[schema.Type], value: u8[], depth: int) {
    if type.null_is_none {
        // Just the pointer, null for None
        if number_at(value, 0, 8) == 0 {
            add_shown(showing, "None")
            return void
        }
        add_shown(showing, "Some(")
        for variant in type.variants {
            if variant.held.count == 1 {
                show_at(showing, variant.held[0].type, value, variant.held[0].offset, depth - 1)
            }
        }
        add_shown(showing, ")")
        return void
    }
    tag_size :: if type.tag < showing.types.types.count { showing.types.types[type.tag].size } else { 0 }
    index :: number_at(value, 0, if tag_size <= 8 { tag_size } else { 8 })
    if index >= cast[u64](type.variants.count) {
        add_shown(showing, message("%(tag %)", type.name, index))
        return void
    }
    variant :: type.variants[cast[usize](index)]
    add_shown(showing, variant.name)
    if variant.held.count == 0 {
        return void
    }
    add_shown(showing, "(")
    for held, i in variant.held {
        if i > 0 {
            add_shown(showing, ", ")
        }
        show_at(showing, held.type, value, held.offset, depth - 1)
    }
    add_shown(showing, ")")
}

/**
 * Show an array from one of its dimensions: its elements, the first SHOW_ELEMENTS of them, "[1, 2, 3]", each the
 * next dimension's array or, for the last, the array's element type.
 *
 * @param dimension Which dimension the value is, from 0, the outermost.
 */
show_array :: fn(showing: ptr[mut Showing], type: ptr[schema.Type], dimension: usize, value: u8[], depth: int) {
    if dimension >= type.dimensions.count {
        add_shown(showing, "<?>")
        return void
    }
    each :: type.dimensions[dimension]
    element_size :: dimension_element_size(showing, type, dimension + 1)
    count := each.count
    // A view's and a dynamic array's elements are where its data points
    elements := value
    from := cast[u64](0)
    if each.kind != .Static {
        count = number_at(value, 0, 8)
        from = number_at(value, 8, 8)
    }
    if depth <= 0 {
        add_shown(showing, message("[% elements]", count))
        return void
    }
    shown :: if count < SHOW_ELEMENTS { count } else { SHOW_ELEMENTS }
    read : u8[..]
    defer runtime.array_free(&read)
    if each.kind != .Static {
        if shown > 0 && !read_remote(showing, from, shown * element_size, &read) {
            add_shown(showing, message("[% elements at %{#x}, not readable]", count, from))
            return void
        }
        elements = read[0..<read.count]
    }
    add_shown(showing, "[")
    for i in cast[u64](0)..<shown {
        if i > 0 {
            add_shown(showing, ", ")
        }
        at :: i * element_size
        if at + element_size > cast[u64](elements.count) || at >= cast[u64](elements.count) {
            add_shown(showing, "<?>")
            break
        }
        element :: view_of(&elements[cast[usize](at)], cast[usize](element_size))
        if dimension + 1 < type.dimensions.count {
            show_array(showing, type, dimension + 1, element, depth - 1)
        }
        else {
            show_value(showing, type.base, element, depth - 1)
        }
    }
    if count > shown {
        add_shown(showing, ", ...")
    }
    add_shown(showing, "]")
}

/**
 * The size of an array's elements from a dimension on: a static dimension's count times its elements', a view's 16
 * bytes, a dynamic array's 40, and past the last, the element type's.
 */
dimension_element_size :: fn(showing: ptr[mut Showing], type: ptr[schema.Type], dimension: usize) -> u64 {
    if dimension >= type.dimensions.count {
        return if type.base < showing.types.types.count { showing.types.types[type.base].size } else { 0 }
    }
    each :: type.dimensions[dimension]
    if each.kind == .View {
        return 16
    }
    if each.kind == .Dynamic {
        return 40
    }
    return each.count * dimension_element_size(showing, type, dimension + 1)
}

/**
 * Show a part of a value: a member or what a variant holds, at its offset.
 */
show_at :: fn(showing: ptr[mut Showing], place: usize, value: u8[], offset: u64, depth: int) {
    if offset >= cast[u64](value.count) {
        add_shown(showing, "<?>")
        return void
    }
    show_value(showing, place, view_of(&value[cast[usize](offset)], cast[usize](cast[u64](value.count) - offset)), depth)
}

/**
 * Show text from the process, in quotes: count bytes, or for a cstring, up to its zero; the first SHOW_TEXT of them.
 *
 * @param address Where the text is; 0 is null.
 * @param count How many bytes it has, or for a cstring, the most read.
 * @param raw Whether it's a cstring.
 */
show_text :: fn(showing: ptr[mut Showing], address: u64, count: u64, raw: bool) {
    if address == 0 {
        add_shown(showing, if raw { "null" } else { "\"\"" })
        return void
    }
    shown :: if count < SHOW_TEXT { count } else { SHOW_TEXT }
    read : u8[..]
    defer runtime.array_free(&read)
    if shown > 0 && !read_remote(showing, address, shown, &read) {
        add_shown(showing, message("<text at %{#x}, not readable>", address))
        return void
    }
    runtime.array_add(showing.into, cast[u8](0x22))
    for byte in read {
        if raw && byte == 0 {
            break
        }
        runtime.array_add(showing.into, byte)
    }
    if !raw && count > shown {
        add_shown(showing, "...")
    }
    runtime.array_add(showing.into, cast[u8](0x22))
}

/**
 * Read bytes from the process, a page at a time, so a read across a page that isn't there fails alone.
 *
 * @param address Where they start.
 * @param count How many.
 * @param into Where they go, grown to count.
 * @return True if all of them were read.
 */
read_remote :: fn(showing: ptr[mut Showing], address: u64, count: u64, into: ptr[mut u8[..]]) -> bool {
    runtime.array_reset(into)
    if count == 0 {
        return true
    }
    buffer, failed :: runtime.new_array(u8, cast[usize](count))
    if failed != null {
        return false
    }
    defer runtime.free_array(buffer)
    if !(slop_os.process_read_memory(showing.process, showing.space, address, buffer) is_ok) {
        return false
    }
    for byte in buffer {
        runtime.array_add(into, byte)
    }
    return true
}

/** Add text to what's shown. */
add_shown :: fn(showing: ptr[mut Showing], text: string) {
    for byte in string_bytes(text) {
        runtime.array_add(showing.into, byte)
    }
}

/**
 * Read a little-endian number from bytes.
 *
 * @param bytes The bytes.
 * @param at Where it starts.
 * @param count How many bytes it has, 0 to 8.
 * @return Its value; bytes past the end are taken as 0.
 */
number_at :: fn(bytes: u8[], at: u64, count: u64) -> u64 {
    value : u64 = 0
    for i in cast[u64](0)..<count {
        index :: at + i
        if index < cast[u64](bytes.count) {
            value |= cast[u64](bytes[cast[usize](index)]) << (8 * i)
        }
    }
    return value
}
