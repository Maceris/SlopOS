package shell

import runtime from "base"
import language from "../../shell_language"
import os from "std"
import schema from "std"
import text_buffer from "std"
import terminal from "std"
import unicode from "std"
import slop_os from "std/os"
import terminal as protocol from "std/os/slop_os"

/*
 * Reading values (decisions/0179, 11e3): view, a file as a value, and page, a value a screen at a time. A typed
 * file's value is read by its schema, found by its hash among the types of the manifests of the programs the shell
 * can run, as any file a program writes is of a type its manifest has; a file of bytes is its text, or, when it isn't
 * text, its bytes in hexadecimal. The pager shows a value as the shell writes it, on a screen of its own, one screen of
 * lines at a time, the line under it saying where it is and which keys move it.
 */

/** The most bytes of a file view reads: 1 MiB. What's past them is said to be there, but not read. */
MAX_VIEW_BYTES : u64 : 1024 * 1024
/** The most bytes of a file that isn't text view shows, in hexadecimal: 64 KiB. */
MAX_HEX_BYTES :: 64 * 1024
/** How many bytes a line of hexadecimal shows. */
HEX_LINE_BYTES : usize : 16
/** The most bytes of a value page shows, as the shell writes it: 4 MiB. What's past them is cut. */
MAX_PAGED_BYTES :: 4 * 1024 * 1024
/** The size a terminal that can't be asked is taken to be. */
DEFAULT_FEATURES :: protocol.Features.{columns = 80, rows = 24}

/** The key pages up, by its USB HID usage (page 7), beside those std/terminal names. */
USAGE_PAGE_UP : u16 : 0x4b
/** The key that pages down. */
USAGE_PAGE_DOWN : u16 : 0x4e

/**
 * View a file as a value: view path. A typed file's value, read by its type's schema; a text file's text; another
 * file's bytes in hexadecimal.
 *
 * It fails for no path, or more than one, a path that can't be opened or read, or a typed file whose type no
 * program's manifest has.
 *
 * @param shell The shell: the path is beneath its directory, and its programs' manifests are where a type's found.
 * @param tree The Call node, its one argument the path, a word or an expression giving a path or text.
 * @return The value: the typed file's; Text for the others, without a text file's last line break, and with a line
 *     saying how many bytes weren't read past MAX_VIEW_BYTES (or MAX_HEX_BYTES, in hexadecimal).
 */
view_file :: fn(shell: ptr[mut Shell], tree: ptr[Node]) -> Result[Value, EvalError] {
    if tree.children.count != 1 {
        return error_at(tree.at, "view takes a file's path: view notes.txt")
    }
    argument :: tree.children[0]
    path := ""
    if argument.kind == .Word {
        path = argument.text
    }
    else {
        got :: evaluate(shell, argument)?
        match got {
            case Path(text) => path = text
            case Text(text) => path = text
            case _ => return error_at(argument.at, message("view takes a path, not %", type_name(got)))
        }
    }
    handle :: match opened_beneath_home(shell, path, .ReadOnlyFile) {
        case Ok(made) => made
        case Error(problem) => {
            if problem == file_problem(.NotFound) {
                match meant_path(shell, path) {
                    case Some(meant) => return error_at(argument.at, message("%1: %2; did you mean %3?", path, problem, meant))
                    case None => {}
                }
            }
            return error_at(argument.at, message("%: %", path, problem))
        }
    }
    file, opened :: os.file_on(cast[slop_os.Channel](handle), false)
    if opened is_some {
        return error_at(argument.at, message("%: it couldn't be read", path))
    }
    defer os.close(file)
    size, hash, described :: os.file_info(file)
    if described is_some {
        return error_at(argument.at, message("%: it couldn't be read", path))
    }
    most :: if size < MAX_VIEW_BYTES { size } else { MAX_VIEW_BYTES }
    bytes, made :: runtime.new_array(u8, cast[usize](most))
    if made != null {
        return error_at(argument.at, message("%: there's no memory to read it", path))
    }
    defer runtime.free_array(bytes)
    filled := cast[usize](0)
    loop {
        if filled >= bytes.count {
            break
        }
        count :: match os.read(file, bytes[filled..<bytes.count]) {
            case Ok(read) => read
            case Error(_) => return error_at(argument.at, message("%: it couldn't be read", path))
        }
        if count == 0 {
            break
        }
        filled += count
    }
    if filled > bytes.count {
        return error_at(argument.at, message("%: it couldn't be read", path))
    }
    held :: bytes[0..<filled]
    if !os.all_zero(hash) {
        return match typed_value(shell, hash, held) {
            case Some(value) => .Ok(value)
            case None => error_at(argument.at, message("%: it's a typed file, and no program here has its type", path))
        }
    }
    unread :: size - cast[u64](filled)
    if is_text(held) {
        return .Ok(.Text(file_text(held, unread)))
    }
    return .Ok(.Text(hex_of(held, size)))
}

/**
 * Read a typed file's value, by the type whose schema hash it has, found among the manifests of the programs the
 * shell can run: the first type with that hash, in the order the programs are listed.
 *
 * @param shell The shell, whose programs connection finds each program and its manifest.
 * @param hash The file's schema hash.
 * @param bytes The value, as std/schema's write_value writes one; only read.
 * @return The value, as the shell reads a program's records (decode); null if no manifest has the type.
 */
typed_value :: fn(shell: ptr[mut Shell], hash: u8[32], bytes: u8[]) -> Value? {
    for name in program_names(shell) {
        found :: find_program(shell, name) or_continue
        _ = slop_os.handle_close(cast[slop_os.Handle](found.executable))
        read := read_manifest(found)
        _ = slop_os.handle_close(cast[slop_os.Handle](found.manifest))
        manifest := read or_continue
        defer schema.free(&manifest)
        for i in 0..<manifest.types.count {
            if same_hash(schema.hash_rooted(&manifest, i), hash) {
                return language.decode(&manifest, i, bytes, 0, 0)
            }
        }
    }
    return null
}

/**
 * Tell whether bytes are text: UTF-8, without a 0 byte.
 *
 * @param bytes The bytes; a code point cut off at their end is taken as text, as the file may go on past them.
 * @return True if they're text.
 */
is_text :: fn(bytes: u8[]) -> bool {
    at := cast[usize](0)
    loop {
        if at >= bytes.count {
            return true
        }
        if bytes[at] == 0 {
            return false
        }
        point, length :: unicode.decode(bytes, at)
        if length == 0 {
            return false
        }
        // A replacement character that wasn't written as one: bytes that aren't UTF-8, unless they're cut off at the end
        if point == 0xfffd && !(bytes.count - at >= 3 && bytes[at] == 0xef && bytes[at + 1] == 0xbf && bytes[at + 2] == 0xbd) {
            return at + 4 > bytes.count && bytes[at] >= 0xc0
        }
        at += length
    }
}

/**
 * Make text of a file's bytes: its text, without its last line break, and a line saying what wasn't read.
 *
 * @param bytes The bytes read, text (is_text).
 * @param unread How many of the file's bytes there are past them; 0 for none, when nothing's said.
 * @return The text, on the heap, never freed.
 */
file_text :: fn(bytes: u8[], unread: u64) -> string {
    end := bytes.count
    if end > 0 && bytes[end - 1] == cast[u8]('\n') {
        end -= 1
    }
    joined : u8[..]
    for byte, i in bytes {
        if i < end {
            runtime.array_add(&joined, byte)
        }
    }
    if unread > 0 {
        for byte in string_bytes(message("\n(% more bytes, not read)", unread)) {
            runtime.array_add(&joined, byte)
        }
    }
    if joined.count == 0 {
        return ""
    }
    return string_of(&joined[0], joined.count)
}

/**
 * Write bytes in hexadecimal, HEX_LINE_BYTES to a line: where the line starts, its bytes, and those that are printable
 * ASCII as themselves, the others as dots, as hexdump -C does; at most MAX_HEX_BYTES.
 *
 * @param bytes The bytes read.
 * @param size The file's size in bytes, for the line saying what isn't shown.
 * @return The text, on the heap, never freed.
 */
hex_of :: fn(bytes: u8[], size: u64) -> string {
    shown :: if bytes.count < MAX_HEX_BYTES { bytes.count } else { MAX_HEX_BYTES }
    out : u8[..]
    start := cast[usize](0)
    loop {
        if start >= shown {
            break
        }
        if start > 0 {
            runtime.array_add(&out, cast[u8]('\n'))
        }
        for shift in 0..<8 {
            runtime.array_add(&out, hex_digit((start >> (cast[usize](7 - shift) * 4)) & 15))
        }
        runtime.array_add(&out, cast[u8](' '))
        for i in 0..<HEX_LINE_BYTES {
            runtime.array_add(&out, cast[u8](' '))
            if start + i < shown && start + i < bytes.count {
                byte :: bytes[start + i]
                runtime.array_add(&out, hex_digit(cast[usize](byte >> 4)))
                runtime.array_add(&out, hex_digit(cast[usize](byte & 15)))
            }
            else {
                runtime.array_add(&out, cast[u8](' '))
                runtime.array_add(&out, cast[u8](' '))
            }
        }
        runtime.array_add(&out, cast[u8](' '))
        runtime.array_add(&out, cast[u8](' '))
        runtime.array_add(&out, cast[u8]('|'))
        for i in 0..<HEX_LINE_BYTES {
            if start + i < shown && start + i < bytes.count {
                byte :: bytes[start + i]
                runtime.array_add(&out, if byte >= 0x20 && byte < 0x7f { byte } else { cast[u8]('.') })
            }
        }
        runtime.array_add(&out, cast[u8]('|'))
        start += HEX_LINE_BYTES
    }
    if size > cast[u64](shown) {
        for byte in string_bytes(message("\n(% more bytes, not shown)", size - cast[u64](shown))) {
            runtime.array_add(&out, byte)
        }
    }
    if out.count == 0 {
        return ""
    }
    return string_of(&out[0], out.count)
}

/**
 * Give a hexadecimal digit.
 *
 * @param value 0 to 15; anything larger gives a letter past f.
 * @return Its digit, 0 to 9 then a to f, as ASCII.
 */
hex_digit :: fn(value: usize) -> u8 {
    if value < 10 {
        return cast[u8]('0') + cast[u8](value)
    }
    return cast[u8]('a') + cast[u8](value - 10)
}

// ---- The pager

/** What the pager shows: the lines, and where it is in them. */
Pager :: struct {
    /** The value's lines, as the shell writes it, views of its text. */
    lines : string[..],
    /** The first line shown, from 0. */
    top : usize,
    /** The terminal's size. */
    features : protocol.Features,
}

/**
 * Show a value a screen at a time: what comes before page in a pipeline, as the shell writes it. A value that fits on
 * the screen is written as any other is; a longer one is shown on a screen of the pager's own, a screen less a line of
 * it at a time, with a line under it saying which lines are shown and which keys move it: Space, Page Down or f a
 * screen on, b or Page Up a screen back, Enter, Down or j a line on, Up or k a line back, g or Home the start, G or End
 * the end, and q, Escape or Ctrl-C back to the shell.
 *
 * It fails for arguments given to it.
 *
 * @param shell The shell, whose terminal it's shown on and read from; programs that end meanwhile are noticed as they
 *     are while it reads a line.
 * @param stage The stage's Call node.
 * @param given What came before it, of any kind.
 * @return Null, so nothing's shown again after.
 */
page :: fn(shell: ptr[mut Shell], stage: ptr[Node], given: Value) -> Result[Value, EvalError] {
    if stage.children.count > 0 {
        return error_at(stage.at, "page takes nothing: what comes before it is what it shows")
    }
    storage, made :: runtime.new_array(u8, MAX_PAGED_BYTES)
    if made != null {
        return error_at(stage.at, "there's no memory to show it in")
    }
    defer runtime.free_array(storage)
    out := text_buffer.make(storage)
    language.render(&out, given)
    // The same bytes, seen as storage's, the heap's, so the lines can be views of them
    used :: text_buffer.as_string(&out).count
    if used == 0 || used > storage.count {
        return .Ok(.Null)
    }
    text :: string_of(&storage[0], used)
    pager := Pager.{features = describe(shell)}
    defer runtime.array_free(&pager.lines)
    split_lines(&pager.lines, text)
    if pager.lines.count < cast[usize](pager.features.rows) {
        say(shell, text)
        return .Ok(.Null)
    }
    send(shell, .Screen(true))
    send(shell, .ShowCursor(false))
    defer {
        send(shell, .Screen(false))
        send(shell, .ShowCursor(true))
    }
    loop {
        draw(shell, &pager)
        match terminal.next_event(&shell.console) {
            case Event(event, typed) => {
                match protocol.kind_of(event) {
                    case Some(kind) => {
                        if kind == .Interrupt {
                            return .Ok(.Null)
                        }
                        if kind == .Resize {
                            pager.features.columns = event.columns
                            pager.features.rows = event.rows
                        }
                        if kind == .Key && !moved(&pager, event.code, typed) {
                            return .Ok(.Null)
                        }
                    }
                    case None => {}
                }
            }
            case Other(packet) => take_while_reading(shell, packet)
            case _ => return .Ok(.Null)
        }
    }
}

/**
 * Move the pager for a key.
 *
 * @param pager The pager, whose top is moved, kept from 0 to the last screen's.
 * @param code The key's USB HID usage; 0 where only its text is known.
 * @param typed The text it typed, if any.
 * @return False for a key that ends the pager; true otherwise, also for a key it doesn't know.
 */
moved :: fn(pager: ptr[mut Pager], code: u16, typed: u8[]) -> bool {
    key :: if typed.count == 1 { typed[0] } else { cast[u8](0) }
    screen :: screen_lines(pager)
    last :: if pager.lines.count > screen { pager.lines.count - screen } else { 0 }
    if key == cast[u8]('q') || code == terminal.USAGE_ESCAPE {
        return false
    }
    if key == cast[u8](' ') || key == cast[u8]('f') || code == USAGE_PAGE_DOWN {
        pager.top += screen
    }
    else if key == cast[u8]('b') || code == USAGE_PAGE_UP {
        pager.top = if pager.top > screen { pager.top - screen } else { 0 }
    }
    else if key == cast[u8]('j') || code == terminal.USAGE_DOWN || code == terminal.USAGE_ENTER {
        pager.top += 1
    }
    else if key == cast[u8]('k') || code == terminal.USAGE_UP {
        pager.top = if pager.top > 0 { pager.top - 1 } else { 0 }
    }
    else if key == cast[u8]('g') || code == terminal.USAGE_HOME {
        pager.top = 0
    }
    else if key == cast[u8]('G') || code == terminal.USAGE_END {
        pager.top = last
    }
    if pager.top > last {
        pager.top = last
    }
    return true
}

/**
 * Tell how many of the value's lines a screen shows: its rows, less the pager's own line, and at least 1.
 *
 * @param pager The pager.
 * @return How many lines.
 */
screen_lines :: fn(pager: ptr[Pager]) -> usize {
    rows :: cast[usize](pager.features.rows)
    return if rows > 2 { rows - 1 } else { 1 }
}

/**
 * Draw the pager's screen: its lines from top, each cut to the screen's width, then its own line, inverse.
 *
 * @param shell The shell, whose terminal it's drawn on; failures are ignored, as say ignores them.
 * @param pager The pager.
 */
draw :: fn(shell: ptr[mut Shell], pager: ptr[Pager]) {
    screen :: screen_lines(pager)
    columns :: cast[usize](pager.features.columns)
    for row in 0..<screen {
        send(shell, .MoveCursor(protocol.Position.{column = 0, row = cast[u16](row)}))
        send(shell, .Clear(protocol.Area.{column = 0, row = cast[u16](row), columns = pager.features.columns, rows = 1}))
        at :: pager.top + row
        if at < pager.lines.count {
            _ = terminal.write(&shell.console, cut_to(pager.lines[at], columns))
        }
    }
    shown_to :: if pager.top + screen < pager.lines.count { pager.top + screen } else { pager.lines.count }
    status :: message("lines %1-%2 of %3: Space and b page, Up and Down scroll, q quits", pager.top + 1, shown_to,
        pager.lines.count)
    row :: cast[u16](screen)
    send(shell, .MoveCursor(protocol.Position.{column = 0, row = row}))
    send(shell, .Clear(protocol.Area.{column = 0, row = row, columns = pager.features.columns, rows = 1}))
    _ = terminal.write(&shell.console, cut_to(status, columns), protocol.Style.{attributes = protocol.INVERSE})
}

/**
 * Cut text to at most a number of columns, at a grapheme cluster's start.
 *
 * @param text The text, a line.
 * @param columns The most columns it may take (unicode.grapheme_width).
 * @return A view of its start: all of it if it fits.
 */
cut_to :: fn(text: string, columns: usize) -> string {
    bytes :: string_bytes(text)
    taken := cast[usize](0)
    end := cast[usize](0)
    loop {
        if end >= bytes.count {
            return text
        }
        next :: unicode.grapheme_end(bytes, end)
        if next <= end || next > bytes.count {
            return text
        }
        wide :: unicode.grapheme_width(bytes[end..<next])
        if taken + wide > columns {
            break
        }
        taken += wide
        end = next
    }
    if end == 0 {
        return ""
    }
    return string_of(&bytes[0], end)
}

/**
 * Split text into its lines, views of it, without their line breaks.
 *
 * @param into Where the lines go, in order; text without a line break is one line, and so is empty text.
 * @param text The text, kept by the views.
 */
split_lines :: fn(into: ptr[mut string[..]], text #escaping : string) {
    bytes :: string_bytes(text)
    start := cast[usize](0)
    for byte, i in bytes {
        if byte == cast[u8]('\n') {
            runtime.array_add(into, if i > start { string_of(&bytes[start], i - start) } else { "" })
            start = i + 1
        }
    }
    runtime.array_add(into, if start < bytes.count { string_of(&bytes[start], bytes.count - start) } else { "" })
}

/**
 * Find how wide a value may be written, as a table: the terminal's width now, asked only for a list, which may be one.
 *
 * @param shell The shell, whose terminal is asked.
 * @param value The value to be written.
 * @return The terminal's columns for a list; 0, no limit, for anything else.
 */
table_columns :: fn(shell: ptr[mut Shell], value: Value) -> usize {
    return match value {
        case List(_) => cast[usize](describe(shell).columns)
        case _ => 0
    }
}

/**
 * Ask the terminal what it can show, and its size, keeping what input comes meanwhile for the shell to read after.
 *
 * @param shell The shell, whose terminal is asked; a Read held is answered in turn, and its events kept.
 * @return What it answered; DEFAULT_FEATURES if it couldn't be asked or didn't answer, or said it has no rows.
 */
describe :: fn(shell: ptr[mut Shell]) -> protocol.Features {
    console :: &shell.console
    if !protocol.send(console.end, console.port, .Describe) {
        return DEFAULT_FEATURES
    }
    loop {
        into := os.Incoming.{}
        match protocol.receive_response(console.end, console.port, &into, false) {
            case Received => {}
            case Empty => {
                // As next_event waits: what comes under the shell's other keys is kept for it
                packets : slop_os.Packet[terminal.OTHERS]
                taken :: cast[usize](slop_os.port_wait(console.port, packets, slop_os.NO_DEADLINE) or_else 0)
                terminal.keep_others(console, packets, taken)
                continue
            }
            case _ => return DEFAULT_FEATURES
        }
        match os.message_of[protocol.Response](&into)^ {
            case Described(features) => return if features.rows == 0 || features.columns == 0 { DEFAULT_FEATURES } else { features }
            case Input(_) => terminal.take_input(console, &into)
            case _ => return DEFAULT_FEATURES
        }
    }
}

/**
 * Send the terminal a request it doesn't answer, ignoring a failure, as say does.
 *
 * @param shell The shell, whose terminal it's sent to.
 * @param request The request.
 */
send :: fn(shell: ptr[mut Shell], request: protocol.Request) {
    _ = protocol.send(shell.console.end, shell.console.port, request)
}
