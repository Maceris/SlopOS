/**
 * symbols (decisions/0183, 12a): names places in a program for crash reports, as the decoder process that parses a
 * program's symbols, holding nothing else (design/lessons.md §9.4): given the program's file and offsets in its image,
 * it finds the function each offset is in among the file's symbol table (.symtab), and sends one line per offset on its
 * reply channel, as the function's name and the offset into it, "main+0x1c", or "?" for an offset no function holds.
 * Given functions' names too, for a debugger's breakpoints (12b), it sends a line for each after them: the function's
 * offset in the image, as "0x1c40", or "?" for a name no function has.
 *
 * Given the program's debug file instead (decisions/0185, 12e: "HDBG", then the program linked with its DWARF, then the
 * debug table), it reads the ELF in it the same way, and answers queries from its DWARF after the names (dwarf.hsc):
 * "line <offset>" with "file:line", "where <file>:<line>" with the line's lowest offset, and "locals <offset>" with the
 * function there and its locals, each as describe_locals says them.
 */
package symbols

import runtime from "base"
import os from "std"
import text_buffer from "std"
import slop_os from "std/os"

/** The most offsets named at once; more are left out. */
MAX_OFFSETS :: 64
/** The largest program file read, in bytes: 64 MiB. */
MAX_FILE : u64 : 64 << 20
/** The most bytes of the reply, all its lines together; lines past it are left out. */
REPLY_BYTES :: 8192
/** An ELF section that holds a symbol table: SHT_SYMTAB. */
SECTION_SYMBOLS : u32 : 2
/** A symbol's type, in its info's low four bits, for a function: STT_FUNC. */
SYMBOL_FUNCTION : u8 : 2
/** How many bytes an ELF64 section header has. */
SECTION_HEADER_SIZE : u64 : 64
/** How many bytes an ELF64 symbol has. */
SYMBOL_SIZE : u64 : 24

/**
 * Name each offset in a program's image by the function it's in, and send the names on the reply channel.
 *
 * @param log The kernel's debug log; symbols logs through base's logger instead, so it's taken but not used.
 * @param program The program's file, which needs RIGHT_MEMORY_READ; only read.
 * @param reply Where the names go: one message of lines, one per offset in their order, each ending in a newline,
 *     cut at REPLY_BYTES.
 * @param offsets Offsets in the program's image, as a crash report's frames less its image's address; at most
 *     MAX_OFFSETS are named.
 * @param names Functions' names, as the symbol table has them ("program.main"), each ending in a newline, each
 *     answered with its offset after the offsets' lines; at most MAX_OFFSETS. None for none.
 * @param queries Queries of the debug file's DWARF, each ending in a newline, answered after the names' lines, in
 *     order: "line <offset>", "where <file>:<line>" and "locals <offset>", offsets in hex with 0x or in decimal; at most
 *     MAX_OFFSETS. Each is answered "?" without DWARF, as from a program's file. None for none.
 * @return 0 once the names are sent; 1 if the file couldn't be read, 2 if it isn't an ELF64 file with a symbol table,
 *     3 if the reply couldn't be sent.
 */
main :: fn(log: slop_os.DebugLog?, program: slop_os.Memory, reply: slop_os.Channel, offsets: u64[], names: string?, queries: string?) -> int {
    size :: slop_os.memory_size(program) or_return 1
    if size == 0 || size > MAX_FILE {
        return 1
    }
    file, failed :: runtime.new_array(u8, cast[usize](size))
    if failed != null {
        return 1
    }
    defer runtime.free_array(file)
    slop_os.memory_read(program, 0, file) or_return 1
    elf :: inner_elf(file)
    table :: symbol_table(elf) or_return 2
    storage : u8[REPLY_BYTES]
    text := text_buffer.make(storage)
    for offset, i in offsets {
        if i >= MAX_OFFSETS {
            break
        }
        name_at(elf, table, offset, &text)
        text_buffer.append(&text, "\n")
    }
    // Each name, up to its newline
    bytes :: string_bytes(names or_else "")
    start : usize = 0
    asked : usize = 0
    for i in cast[usize](0)..<bytes.count {
        if bytes[i] != 0x0a {
            continue
        }
        if i > start && start < bytes.count && asked < MAX_OFFSETS {
            match offset_of(elf, table, string_of(&bytes[start], i - start)) {
                case Some(offset) => text_buffer.append_format(&text, "%{#x}\n", offset)
                case None => text_buffer.append(&text, "?\n")
            }
            asked += 1
        }
        start = i + 1
    }
    answer_queries(elf, queries or_else "", &text)
    port :: os.port_for(slop_os.startup_block().budget, reply) or_return 3
    none : slop_os.Handle[1]
    match os.send(reply, port, string_bytes(text_buffer.as_string(&text)), view_of(&none[0], 0)) {
        case Some(error) => return 3
        case None => return 0
    }
}

/**
 * The ELF a file is: the file itself, or a debug file's program, after its header.
 *
 * @param file The whole file.
 * @return The ELF's bytes, a view of file; the file itself unless it starts "HDBG" and holds all of the ELF it says.
 */
inner_elf :: fn(file: u8[]) -> u8[] {
    if file.count < 16 || file[0] != 0x48 || file[1] != 0x44 || file[2] != 0x42 || file[3] != 0x47 {
        return file
    }
    size :: word(file, 8, 8)
    first : usize = 16
    if size == 0 || !fits(file, 16, size) || first >= file.count {
        return file
    }
    return view_of(&file[first], cast[usize](size))
}

/**
 * Answer each query, a line each, or the lines describe_locals gives.
 *
 * @param elf The ELF, whose DWARF answers.
 * @param queries The queries, each ending in a newline.
 * @param into Where the answers go.
 */
answer_queries :: fn(elf: u8[], queries: string, into: ptr[mut text_buffer.TextBuffer]) {
    found :: find_dwarf(elf)
    bytes :: string_bytes(queries)
    start : usize = 0
    asked : usize = 0
    for i in cast[usize](0)..<bytes.count {
        if bytes[i] != 0x0a {
            continue
        }
        if i > start && start < bytes.count && asked < MAX_OFFSETS {
            query :: string_of(&bytes[start], i - start)
            match found {
                case Some(dwarf) => answer_query(elf, dwarf, query, into)
                case None => text_buffer.append(into, "?\n")
            }
            asked += 1
        }
        start = i + 1
    }
}

/**
 * Answer one query.
 *
 * @param elf The ELF.
 * @param dwarf Its DWARF.
 * @param query "line <offset>", "where <file>:<line>" or "locals <offset>".
 * @param into Where the answer goes: "?" for a query not known.
 */
answer_query :: fn(elf: u8[], dwarf: Dwarf, query: string, into: ptr[mut text_buffer.TextBuffer]) {
    bytes :: string_bytes(query)
    space : usize = bytes.count
    for byte, i in bytes {
        if byte == 0x20 {
            space = i
            break
        }
    }
    if space == 0 || space + 1 >= bytes.count {
        text_buffer.append(into, "?\n")
        return void
    }
    command :: string_of(&bytes[0], space)
    argument :: string_of(&bytes[space + 1], bytes.count - space - 1)
    if command == "line" {
        describe_line(elf, dwarf, number_in(argument) or_else ~cast[u64](0), into)
    }
    else if command == "locals" {
        describe_locals(elf, dwarf, number_in(argument) or_else ~cast[u64](0), into)
    }
    else if command == "where" {
        // The file, then the line after the last colon
        given :: string_bytes(argument)
        colon : usize = given.count
        for byte, i in given {
            if byte == 0x3a {
                colon = i
            }
        }
        if colon == 0 || colon + 1 >= given.count {
            text_buffer.append(into, "?\n")
            return void
        }
        line :: number_in(string_of(&given[colon + 1], given.count - colon - 1)) or_else 0
        describe_address(elf, dwarf, string_of(&given[0], colon), line, into)
    }
    else {
        text_buffer.append(into, "?\n")
    }
}

/**
 * Read a number, in hex after 0x or in decimal.
 *
 * @param text The number's text.
 * @return Its value; null if it isn't one, or is empty.
 */
number_in :: fn(text: string) -> u64? {
    bytes :: string_bytes(text)
    hex :: bytes.count > 2 && bytes[0] == 0x30 && (bytes[1] == 0x78 || bytes[1] == 0x58)
    first : usize = if hex { 2 } else { 0 }
    if first >= bytes.count {
        return null
    }
    value : u64 = 0
    for i in first..<bytes.count {
        byte :: bytes[i]
        digit : u64 = 0
        if byte >= 0x30 && byte <= 0x39 {
            digit = cast[u64](byte - 0x30)
        }
        else if hex && byte >= 0x61 && byte <= 0x66 {
            digit = cast[u64](byte - 0x61 + 10)
        }
        else if hex && byte >= 0x41 && byte <= 0x46 {
            digit = cast[u64](byte - 0x41 + 10)
        }
        else {
            return null
        }
        value = value * (if hex { cast[u64](16) } else { cast[u64](10) }) + digit
    }
    return value
}

/** Where a file's symbol table and its names are, in bytes from the file's start. */
SymbolTable :: struct {
    /** Where the symbols start. */
    symbols : u64,
    /** How many there are. */
    count : u64,
    /** Where the names they point into start: the table's string table. */
    names : u64,
    /** How many bytes the names have. */
    names_size : u64,
}

/**
 * Find an ELF64 file's symbol table and its string table.
 *
 * @param file The whole file.
 * @return Where they are; null if it isn't a little-endian ELF64 file, it has no symbol table, or either runs past the
 *     file's end.
 */
symbol_table :: fn(file: u8[]) -> SymbolTable? {
    if file.count < 64 || file[0] != 0x7f || file[1] != 0x45 || file[2] != 0x4c || file[3] != 0x46 || file[4] != 2 || file[5] != 1 {
        return null
    }
    sections :: word(file, 0x28, 8)
    section_size :: word(file, 0x3a, 2)
    section_count :: word(file, 0x3c, 2)
    if section_size != SECTION_HEADER_SIZE || !fits(file, sections, section_count * SECTION_HEADER_SIZE) {
        return null
    }
    for i in cast[u64](0)..<section_count {
        header :: sections + i * SECTION_HEADER_SIZE
        if word(file, header + 4, 4) != cast[u64](SECTION_SYMBOLS) {
            continue
        }
        symbols :: word(file, header + 0x18, 8)
        size :: word(file, header + 0x20, 8)
        link :: word(file, header + 0x28, 4)
        if link >= section_count || !fits(file, symbols, size) {
            return null
        }
        names_header :: sections + link * SECTION_HEADER_SIZE
        names :: word(file, names_header + 0x18, 8)
        names_size :: word(file, names_header + 0x20, 8)
        if !fits(file, names, names_size) {
            return null
        }
        return SymbolTable.{symbols = symbols, count = size / SYMBOL_SIZE, names = names, names_size = names_size}
    }
    return null
}

/**
 * Write the function an offset is in, and how far into it, as "name+0x1c": the function symbol starting nearest at or
 * before it, within its size, or with a size of 0, nearest of all; "?" if there's none.
 *
 * @param file The whole file.
 * @param table Its symbol table.
 * @param offset The offset in the image, which an ELF's symbols' values are, its image based at 0.
 * @param into Where the text's added.
 */
name_at :: fn(file: u8[], table: SymbolTable, offset: u64, into: ptr[mut text_buffer.TextBuffer]) {
    best : u64 = 0
    best_start : u64 = 0
    found := false
    for i in cast[u64](0)..<table.count {
        symbol :: table.symbols + i * SYMBOL_SIZE
        info :: cast[u8](word(file, symbol + 4, 1))
        start :: word(file, symbol + 8, 8)
        size :: word(file, symbol + 16, 8)
        if info & 0xf != SYMBOL_FUNCTION || start > offset || (size != 0 && offset - start >= size) {
            continue
        }
        if !found || start > best_start {
            best = symbol
            best_start = start
            found = true
        }
    }
    if !found {
        text_buffer.append(into, "?")
        return void
    }
    name :: word(file, best, 4)
    text_buffer.append(into, name_in(file, table, name))
    text_buffer.append_format(into, "+%{#x}", offset - best_start)
}

/**
 * Find a function's offset in the image by its name.
 *
 * @param file The whole file.
 * @param table Its symbol table.
 * @param name The function's name, as the table has it, compared byte for byte.
 * @return The first function symbol of that name's value, its offset in the image; null if none has it.
 */
offset_of :: fn(file: u8[], table: SymbolTable, name: string) -> u64? {
    for i in cast[u64](0)..<table.count {
        symbol :: table.symbols + i * SYMBOL_SIZE
        if cast[u8](word(file, symbol + 4, 1)) & 0xf != SYMBOL_FUNCTION {
            continue
        }
        if name_in(file, table, word(file, symbol, 4)) == name {
            return word(file, symbol + 8, 8)
        }
    }
    return null
}

/**
 * Get a name from a symbol table's string table.
 *
 * @param file The whole file, which the name is a view of.
 * @param table The symbol table, whose string table's read.
 * @param at Where the name starts in the string table.
 * @return The name, up to its zero or the table's end; "?" if it starts past the end.
 */
name_in :: fn(file: u8[], table: SymbolTable, at: u64) -> string {
    if at >= table.names_size {
        return "?"
    }
    start :: table.names + at
    count := cast[u64](0)
    loop {
        index :: start + count
        if count >= table.names_size - at || index >= cast[u64](file.count) || file[cast[usize](index)] == 0 {
            break
        }
        count += 1
    }
    first :: cast[usize](start)
    if count == 0 || first >= file.count {
        return "?"
    }
    return string_of(&file[first], cast[usize](count))
}

/**
 * Tell whether a range is within a file.
 *
 * @param file The file.
 * @param at Where the range starts.
 * @param count How many bytes it has.
 * @return True if all of it is in the file.
 */
fits :: fn(file: u8[], at: u64, count: u64) -> bool {
    size :: cast[u64](file.count)
    return at <= size && count <= size - at
}

/**
 * Read a little-endian number.
 *
 * @param file The bytes.
 * @param at Where it starts.
 * @param count How many bytes it has, 1 to 8.
 * @return Its value; bytes past the end are taken as 0.
 */
word :: fn(file: u8[], at: u64, count: u64) -> u64 {
    value : u64 = 0
    for i in cast[u64](0)..<count {
        index :: at + i
        if index < cast[u64](file.count) {
            value |= cast[u64](file[cast[usize](index)]) << (8 * i)
        }
    }
    return value
}
