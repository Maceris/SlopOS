/**
 * edit (decisions/0162, 0179): a small text editor on the terminal it's given, full screen, for one file: moving,
 * inserting, deleting, undo, finding and saving.
 */
package edit

import runtime from "base"
import memory from "std"
import os from "std"
import strings from "std"
import terminal from "std"
import unicode from "std"
import slop_os from "std/os"
import file from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"

/** The most bytes of a file edit opens: 4 MiB. */
MAX_FILE_BYTES : u64 : 4 * 1024 * 1024
/** How many bytes are read at a time. */
READ_BYTES :: 64 * 1024
/** How many spaces Tab inserts. */
TAB_SPACES :: 4
/** The most bytes a search's text has. */
MAX_QUERY :: 128

/** The USB HID usages (page 7) of the keys edit reads, beside those std/terminal names. */
USAGE_F : u16 : 0x09
/** Ctrl-Q quits. */
USAGE_Q : u16 : 0x14
/** Ctrl-S saves. */
USAGE_S : u16 : 0x16
/** Ctrl-Z undoes. */
USAGE_Z : u16 : 0x1d
/** Page Up. */
USAGE_PAGE_UP : u16 : 0x4b
/** Page Down. */
USAGE_PAGE_DOWN : u16 : 0x4e

/** What an editing session did. */
Edited :: struct {
    /** Whether it was saved at least once. */
    saved : bool,
    /** How many lines the text had when it ended. */
    lines : u64,
    /** How many bytes. */
    bytes : memory.ByteCount,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: file, or console. */
    parameter : os.ParameterName,
}

/** Why it couldn't edit. */
EditError :: union {
    /** The file isn't text: a typed file, or one with a 0 byte, or more than 4 MiB. */
    NotText(Problem),
    /** The file couldn't be read. */
    Unreadable(Problem),
    /** The terminal couldn't be opened. */
    NoTerminal(Problem),
}

/** A change, as undo takes it back: bytes inserted at a place, or removed from it. */
Change :: struct {
    /** Where, in bytes from the text's start. */
    at : usize,
    /** The bytes inserted or removed. */
    bytes : u8[..],
    /** Whether they were inserted; false, removed. */
    inserted : bool,
    /** Whether it was typing, which the next character typed after it joins. */
    typing : bool,
}

/** The editor's state. */
Editor :: struct {
    /** The terminal. */
    console : terminal.Terminal,
    /** The file, read and written. */
    file : os.File,
    /** The text. */
    text : u8[..],
    /** Where each line starts, in bytes; the first is 0. */
    starts : usize[..],
    /** The cursor, in bytes, at a grapheme cluster's start. */
    at : usize,
    /** The column up and down keep to, in the terminal's columns. */
    goal : usize,
    /** The first line shown. */
    top : usize,
    /** The first column shown. */
    left : usize,
    /** The terminal's size. */
    columns : usize,
    /** Its rows; one is the status line. */
    rows : usize,
    /** The changes undo takes back, the newest last. */
    changes : Change[..],
    /** Whether the text has changed since it was read or saved. */
    modified : bool,
    /** Whether it's been saved. */
    saved : bool,
    /** Whether Ctrl-Q was pressed with changes unsaved, so another quits. */
    quitting : bool,
    /** Whether the status line is asking what to find. */
    finding : bool,
    /** What's being typed to find. */
    query : u8[..],
    /** What was last found, which an empty find looks for again. */
    found : u8[..],
    /** What the status line says once, in place of where the cursor is; empty for nothing. */
    note : string,
}

/**
 * Edit a text file on the terminal, full screen.
 *
 * The keys: the arrows, Home, End, Page Up and Page Down move; what's typed is inserted, Enter a line break and Tab
 * four spaces; Backspace and Delete delete; Ctrl-Z undoes; Ctrl-F finds text, typed on the status line, Enter looking
 * from the cursor on (an empty one looks for the last again), Escape not; Ctrl-S saves; Ctrl-Q quits, twice with
 * changes unsaved, and so does Ctrl-C.
 *
 * @param console The terminal, read and drawn on for as long as it edits, on a screen of its own.
 * @param file The file, beneath the shell's directory: made if it isn't there, read, and written when it's saved.
 * @return Whether it was saved, and how many lines and bytes the text had at the end.
 * @error NotText The file isn't text: a typed file, one with a 0 byte, or more than 4 MiB.
 * @error Unreadable The file couldn't be read.
 * @error NoTerminal The terminal couldn't be used.
 */
main :: fn(console: os.Channel[protocol.Terminal], file: os.Channel[file.File]) -> Result[Edited, EditError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "file"}}
    editor := runtime.new(Editor)
    editor.console = terminal.open(console) or_return .Error(.NoTerminal(Problem.{parameter = os.ParameterName.{name = "console"}}))
    opened, error :: os.file_on(file.end, true)
    if error is_some {
        return .Error(.Unreadable(problem))
    }
    editor.file = opened
    defer os.close(editor.file)
    size, schema, described :: os.file_info(editor.file)
    if described is_some {
        return .Error(.Unreadable(problem))
    }
    if !os.all_zero(schema) || size > MAX_FILE_BYTES {
        return .Error(.NotText(problem))
    }
    if !read_all(editor) {
        return .Error(.Unreadable(problem))
    }
    for byte in editor.text {
        if byte == 0 {
            return .Error(.NotText(problem))
        }
    }
    find_starts(editor)
    size_from(editor, describe(editor))
    send(editor, .Screen(true))
    defer send(editor, .Screen(false))
    loop {
        draw(editor)
        match terminal.next_event(&editor.console) {
            case Event(event, typed) => {
                match protocol.kind_of(event) {
                    case Some(kind) => {
                        if kind == .Resize {
                            editor.columns = cast[usize](event.columns)
                            editor.rows = cast[usize](event.rows)
                        }
                        if kind == .Paste {
                            insert_typed(editor, typed, false)
                        }
                        if (kind == .Key && !key(editor, event, typed)) || (kind == .Interrupt && !quit(editor)) {
                            break
                        }
                    }
                    case None => {}
                }
            }
            case Other(_) => {}
            case _ => break
        }
    }
    return .Ok(Edited.{saved = editor.saved, lines = cast[u64](editor.starts.count), bytes = cast[memory.ByteCount](editor.text.count)})
}

// ---- Reading and saving

/**
 * Read the whole file into the editor's text.
 *
 * @param editor The editor, whose file is read from its start.
 * @return Whether it was read; false if a read failed or it's past MAX_FILE_BYTES.
 */
read_all :: fn(editor: ptr[mut Editor]) -> bool {
    chunk : u8[READ_BYTES]
    loop {
        count :: os.read(editor.file, chunk[0..<chunk.count]) or_return false
        if count == 0 {
            return true
        }
        for byte, i in chunk {
            if i < count {
                runtime.array_add(&editor.text, byte)
            }
        }
        if cast[u64](editor.text.count) > MAX_FILE_BYTES {
            return false
        }
    }
}

/**
 * Save the text: written over the file from its start, and the file cut to its length.
 *
 * @param editor The editor; its modified is cleared and saved set once it's written, and its note says what happened.
 */
save :: fn(editor: ptr[mut Editor]) {
    os.file_seek(editor.file, 0)
    written := true
    if editor.text.count > 0 {
        written = os.write(editor.file, string_of(&editor.text[0], editor.text.count)) is_none
    }
    if written && (os.file_set_size(editor.file, cast[u64](editor.text.count)) is_none) {
        editor.modified = false
        editor.saved = true
        editor.quitting = false
        editor.note = (strings.format("saved: % lines, % bytes", editor.starts.count, editor.text.count) or_else "")
        return void
    }
    editor.note = "it couldn't be saved"
}

// ---- Keys

/**
 * Do what a key does.
 *
 * @param editor The editor.
 * @param event The key's event: its code and modifiers.
 * @param typed The text it types, if any.
 * @return False once it's quit; true otherwise.
 */
key :: fn(editor: ptr[mut Editor], event: protocol.Event, typed: u8[]) -> bool {
    control :: (event.modifiers & protocol.CONTROL) != 0
    code :: event.code
    if editor.finding {
        find_key(editor, code, typed)
        return true
    }
    editor.note = ""
    if control && code == USAGE_Q {
        return quit(editor)
    }
    editor.quitting = false
    if control {
        if code == USAGE_S {
            save(editor)
        }
        else if code == USAGE_Z {
            undo(editor)
        }
        else if code == USAGE_F {
            editor.finding = true
            runtime.array_reset(&editor.query)
        }
        return true
    }
    if code == terminal.USAGE_LEFT {
        move_to(editor, previous(editor, editor.at), true)
    }
    else if code == terminal.USAGE_RIGHT {
        move_to(editor, next(editor, editor.at), true)
    }
    else if code == terminal.USAGE_UP {
        vertical(editor, -1)
    }
    else if code == terminal.USAGE_DOWN {
        vertical(editor, 1)
    }
    else if code == USAGE_PAGE_UP {
        vertical(editor, -cast[int](text_rows(editor)))
    }
    else if code == USAGE_PAGE_DOWN {
        vertical(editor, cast[int](text_rows(editor)))
    }
    else if code == terminal.USAGE_HOME {
        move_to(editor, line_start(editor, line_of(editor, editor.at)), true)
    }
    else if code == terminal.USAGE_END {
        move_to(editor, line_end(editor, line_of(editor, editor.at)), true)
    }
    else if code == terminal.USAGE_ENTER {
        insert(editor, editor.at, string_bytes("\n"), false)
    }
    else if code == terminal.USAGE_TAB {
        insert(editor, editor.at, string_bytes("    "), true)
    }
    else if code == terminal.USAGE_BACKSPACE {
        if editor.at > 0 {
            remove(editor, previous(editor, editor.at), editor.at)
        }
    }
    else if code == terminal.USAGE_DELETE {
        remove(editor, editor.at, next(editor, editor.at))
    }
    else if typed.count > 0 && (event.modifiers & (protocol.ALT | protocol.META)) == 0 {
        insert_typed(editor, typed, true)
    }
    return true
}

/**
 * Ask to quit: at once when nothing's unsaved; otherwise the first time it's said, and the second quits.
 *
 * @param editor The editor.
 * @return False to quit; true to keep editing.
 */
quit :: fn(editor: ptr[mut Editor]) -> bool {
    if !editor.modified || editor.quitting {
        return false
    }
    editor.quitting = true
    editor.note = "the changes aren't saved: Ctrl-Q again quits without them, Ctrl-S saves"
    return true
}

/**
 * Take a key while the status line asks what to find: text typed adds to it, Backspace takes from it, Enter finds it
 * from the cursor on, wrapping round to the start, and Escape stops asking.
 *
 * @param editor The editor, finding.
 * @param code The key's code.
 * @param typed The text it types, if any.
 */
find_key :: fn(editor: ptr[mut Editor], code: u16, typed: u8[]) {
    if code == terminal.USAGE_ESCAPE {
        editor.finding = false
        return void
    }
    if code == terminal.USAGE_BACKSPACE {
        if editor.query.count > 0 {
            runtime.array_remove(&editor.query, editor.query.count - 1)
        }
        return void
    }
    if code == terminal.USAGE_ENTER {
        editor.finding = false
        if editor.query.count > 0 {
            runtime.array_reset(&editor.found)
            for byte in editor.query {
                runtime.array_add(&editor.found, byte)
            }
        }
        find(editor)
        return void
    }
    for byte in typed {
        if editor.query.count < MAX_QUERY && byte >= 0x20 {
            runtime.array_add(&editor.query, byte)
        }
    }
}

/**
 * Find the text last asked for, from just past the cursor to the end and then from the start, and move the cursor to
 * it; the note says if it isn't there.
 *
 * @param editor The editor, whose found is looked for.
 */
find :: fn(editor: ptr[mut Editor]) {
    wanted :: editor.found[0..<editor.found.count]
    if wanted.count == 0 {
        return void
    }
    count :: editor.text.count
    for step in 0..<count {
        at :: (editor.at + 1 + step) % (if count > 0 { count } else { 1 })
        if matches_at(editor, at, wanted) {
            move_to(editor, at, true)
            return void
        }
    }
    editor.note = (strings.format("\"%\" isn't there", string_of(&wanted[0], wanted.count)) or_else "")
}

/**
 * Tell whether bytes are in the text at a place.
 *
 * @param editor The editor.
 * @param at The place.
 * @param wanted The bytes.
 * @return True if the text has them there.
 */
matches_at :: fn(editor: ptr[Editor], at: usize, wanted: u8[]) -> bool {
    if at + wanted.count > editor.text.count {
        return false
    }
    for byte, i in wanted {
        if at + i >= editor.text.count || editor.text[at + i] != byte {
            return false
        }
    }
    return true
}

// ---- Changing the text

/**
 * Insert what was typed or pasted at the cursor, carriage returns dropped and other control characters but line
 * feeds and tabs, which Tab's spaces stand for.
 *
 * @param editor The editor.
 * @param typed The text.
 * @param typing Whether it was typed, so it joins the change before it for undo.
 */
insert_typed :: fn(editor: ptr[mut Editor], typed: u8[], typing: bool) {
    kept : u8[..]
    defer runtime.array_free(&kept)
    for byte in typed {
        if byte == cast[u8]('\t') {
            for i in 0..<TAB_SPACES {
                runtime.array_add(&kept, cast[u8](' '))
            }
        }
        else if byte >= 0x20 || byte == cast[u8]('\n') {
            runtime.array_add(&kept, byte)
        }
    }
    if kept.count > 0 {
        insert(editor, editor.at, kept[0..<kept.count], typing)
    }
}

/**
 * Insert bytes into the text, and move the cursor past them; it's kept for undo.
 *
 * @param editor The editor.
 * @param at Where, at most the text's length.
 * @param bytes The bytes.
 * @param typing Whether it's typing, joined to a typing change just before it.
 */
insert :: fn(editor: ptr[mut Editor], at: usize, bytes: u8[], typing: bool) {
    splice_in(editor, at, bytes)
    last :: editor.changes.count
    joined := false
    if typing && last > 0 {
        before :: &editor.changes[last - 1]
        if before.inserted && before.typing && before.at + before.bytes.count == at {
            for byte in bytes {
                runtime.array_add(&before.bytes, byte)
            }
            joined = true
        }
    }
    if !joined {
        made := Change.{at = at, inserted = true, typing = typing}
        for byte in bytes {
            runtime.array_add(&made.bytes, byte)
        }
        runtime.array_add(&editor.changes, made)
    }
    changed(editor)
    move_to(editor, at + bytes.count, true)
}

/**
 * Remove bytes from the text, and put the cursor where they were; it's kept for undo.
 *
 * @param editor The editor.
 * @param from Where they start.
 * @param to Where they end, at most the text's length; nothing's removed if it isn't past from.
 */
remove :: fn(editor: ptr[mut Editor], from: usize, to: usize) {
    if to <= from || to > editor.text.count {
        return void
    }
    made := Change.{at = from, inserted = false}
    for byte, i in editor.text {
        if i >= from && i < to {
            runtime.array_add(&made.bytes, byte)
        }
    }
    splice_out(editor, from, to)
    runtime.array_add(&editor.changes, made)
    changed(editor)
    move_to(editor, from, true)
}

/**
 * Take back the newest change: what was inserted removed, what was removed put back, the cursor where it was.
 *
 * @param editor The editor; the note says when there's nothing to undo.
 */
undo :: fn(editor: ptr[mut Editor]) {
    if editor.changes.count == 0 {
        editor.note = "nothing to undo"
        return void
    }
    change := editor.changes[editor.changes.count - 1]
    runtime.array_remove(&editor.changes, editor.changes.count - 1)
    if change.inserted {
        splice_out(editor, change.at, change.at + change.bytes.count)
        move_to(editor, change.at, true)
    }
    else {
        splice_in(editor, change.at, change.bytes[0..<change.bytes.count])
        move_to(editor, change.at + change.bytes.count, true)
    }
    runtime.array_free(&change.bytes)
    changed(editor)
}

/**
 * Put bytes into the text at a place.
 *
 * @param editor The editor.
 * @param at Where; past the end, at the end.
 * @param bytes The bytes.
 */
splice_in :: fn(editor: ptr[mut Editor], at: usize, bytes: u8[]) {
    made : u8[..]
    place :: if at < editor.text.count { at } else { editor.text.count }
    for byte, i in editor.text {
        if i == place {
            for each in bytes {
                runtime.array_add(&made, each)
            }
        }
        runtime.array_add(&made, byte)
    }
    if place >= editor.text.count {
        for each in bytes {
            runtime.array_add(&made, each)
        }
    }
    runtime.array_free(&editor.text)
    editor.text = made
}

/**
 * Take bytes out of the text.
 *
 * @param editor The editor.
 * @param from Where they start.
 * @param to Where they end.
 */
splice_out :: fn(editor: ptr[mut Editor], from: usize, to: usize) {
    made : u8[..]
    for byte, i in editor.text {
        if i < from || i >= to {
            runtime.array_add(&made, byte)
        }
    }
    runtime.array_free(&editor.text)
    editor.text = made
}

/**
 * Note that the text changed: its lines found again, and it's modified.
 *
 * @param editor The editor.
 */
changed :: fn(editor: ptr[mut Editor]) {
    find_starts(editor)
    editor.modified = true
    editor.quitting = false
}

// ---- Lines and the cursor

/**
 * Find where each line starts.
 *
 * @param editor The editor, whose starts are made again from its text.
 */
find_starts :: fn(editor: ptr[mut Editor]) {
    runtime.array_reset(&editor.starts)
    runtime.array_add(&editor.starts, cast[usize](0))
    for byte, i in editor.text {
        if byte == cast[u8]('\n') {
            runtime.array_add(&editor.starts, i + 1)
        }
    }
}

/**
 * Find the line a place is on.
 *
 * @param editor The editor.
 * @param at The place.
 * @return The line, from 0.
 */
line_of :: fn(editor: ptr[Editor], at: usize) -> usize {
    found := cast[usize](0)
    for start, i in editor.starts {
        if start <= at {
            found = i
        }
    }
    return found
}

/**
 * Find where a line starts.
 *
 * @param editor The editor.
 * @param line The line; past the last, the text's end.
 * @return The place.
 */
line_start :: fn(editor: ptr[Editor], line: usize) -> usize {
    return if line < editor.starts.count { editor.starts[line] } else { editor.text.count }
}

/**
 * Find where a line ends, before its line break.
 *
 * @param editor The editor.
 * @param line The line.
 * @return The place.
 */
line_end :: fn(editor: ptr[Editor], line: usize) -> usize {
    next_start :: line + 1
    if next_start < editor.starts.count {
        return editor.starts[next_start] - 1
    }
    return editor.text.count
}

/**
 * Give a line's bytes, without its line break.
 *
 * @param editor The editor.
 * @param line The line.
 * @return A view of them.
 */
line_bytes :: fn(editor: ptr[Editor], line: usize) -> u8[] {
    start :: line_start(editor, line)
    end :: line_end(editor, line)
    if start > end || end > editor.text.count {
        return editor.text[0..<0]
    }
    return editor.text[start..<end]
}

/**
 * Find the place after the grapheme cluster at a place: past a line break, the next line's start.
 *
 * @param editor The editor.
 * @param at The place.
 * @return The place after; the text's end at the end.
 */
next :: fn(editor: ptr[Editor], at: usize) -> usize {
    if at >= editor.text.count {
        return editor.text.count
    }
    if editor.text[at] == cast[u8]('\n') {
        return at + 1
    }
    line :: line_of(editor, at)
    start :: line_start(editor, line)
    bytes :: line_bytes(editor, line)
    after :: start + unicode.grapheme_end(bytes, at - start)
    return if after > at { after } else { at + 1 }
}

/**
 * Find the place before the grapheme cluster that ends at a place: from a line's start, the line break before it.
 *
 * @param editor The editor.
 * @param at The place.
 * @return The place before; 0 at the start.
 */
previous :: fn(editor: ptr[Editor], at: usize) -> usize {
    if at == 0 {
        return 0
    }
    line :: line_of(editor, at)
    start :: line_start(editor, line)
    if at == start {
        return at - 1
    }
    bytes :: line_bytes(editor, line)
    before := start
    loop {
        after :: start + unicode.grapheme_end(bytes, before - start)
        if after >= at || after <= before {
            return before
        }
        before = after
    }
}

/**
 * Measure how many columns of a line come before a place on it.
 *
 * @param editor The editor.
 * @param at The place.
 * @return The columns (unicode.text_width).
 */
column_of :: fn(editor: ptr[Editor], at: usize) -> usize {
    line :: line_of(editor, at)
    start :: line_start(editor, line)
    if at < start || at > editor.text.count {
        return 0
    }
    return unicode.text_width(editor.text[start..<at])
}

/**
 * Move the cursor.
 *
 * @param editor The editor.
 * @param at Where, at most the text's length.
 * @param keep_column Whether the column it's in becomes the one up and down keep to.
 */
move_to :: fn(editor: ptr[mut Editor], at: usize, keep_column: bool) {
    editor.at = if at < editor.text.count { at } else { editor.text.count }
    if keep_column {
        editor.goal = column_of(editor, editor.at)
    }
}

/**
 * Move the cursor up or down lines, to the column it keeps to or the line's end before it.
 *
 * @param editor The editor.
 * @param lines How many: up when negative.
 */
vertical :: fn(editor: ptr[mut Editor], lines: int) {
    line :: cast[int](line_of(editor, editor.at))
    last :: cast[int](editor.starts.count) - 1
    wanted := line + lines
    if wanted < 0 {
        wanted = 0
    }
    if wanted > last {
        wanted = last
    }
    target :: cast[usize](wanted)
    start :: line_start(editor, target)
    bytes :: line_bytes(editor, target)
    place := cast[usize](0)
    width := cast[usize](0)
    loop {
        if place >= bytes.count {
            break
        }
        after :: unicode.grapheme_end(bytes, place)
        if after <= place || after > bytes.count {
            break
        }
        wide :: unicode.grapheme_width(bytes[place..<after])
        if width + wide > editor.goal {
            break
        }
        width += wide
        place = after
    }
    move_to(editor, start + place, false)
}

// ---- Drawing

/**
 * Tell how many rows show text: all but the status line, at least 1.
 *
 * @param editor The editor.
 * @return The rows.
 */
text_rows :: fn(editor: ptr[Editor]) -> usize {
    return if editor.rows > 2 { editor.rows - 1 } else { 1 }
}

/**
 * Draw the screen: the lines from top, scrolled so the cursor's in sight, each from left, then the status line, then
 * the cursor.
 *
 * @param editor The editor; its top and left move to keep the cursor in sight.
 */
draw :: fn(editor: ptr[mut Editor]) {
    rows :: text_rows(editor)
    line :: line_of(editor, editor.at)
    if line < editor.top {
        editor.top = line
    }
    if line >= editor.top + rows {
        editor.top = line + 1 - rows
    }
    column :: column_of(editor, editor.at)
    if column < editor.left {
        editor.left = column
    }
    if column >= editor.left + editor.columns {
        editor.left = column + 1 - editor.columns
    }
    send(editor, .ShowCursor(false))
    for row in 0..<rows {
        send(editor, .MoveCursor(protocol.Position.{column = 0, row = cast[u16](row)}))
        send(editor, .Clear(protocol.Area.{column = 0, row = cast[u16](row), columns = cast[u16](editor.columns), rows = 1}))
        shown :: editor.top + row
        if shown < editor.starts.count {
            part :: visible(line_bytes(editor, shown), editor.left, editor.columns)
            if part.count > 0 {
                _ = terminal.write(&editor.console, string_of(&part[0], part.count))
            }
        }
    }
    status :: status_text(editor)
    send(editor, .MoveCursor(protocol.Position.{column = 0, row = cast[u16](rows)}))
    send(editor, .Clear(protocol.Area.{column = 0, row = cast[u16](rows), columns = cast[u16](editor.columns), rows = 1}))
    cut :: visible(string_bytes(status), 0, editor.columns)
    if cut.count > 0 {
        _ = terminal.write(&editor.console, string_of(&cut[0], cut.count), protocol.Style.{attributes = protocol.INVERSE})
    }
    if editor.finding {
        send(editor, .MoveCursor(protocol.Position.{column = cast[u16](unicode.text_width(string_bytes(status))), row = cast[u16](rows)}))
    }
    else {
        send(editor, .MoveCursor(protocol.Position.{column = cast[u16](column - editor.left), row = cast[u16](line - editor.top)}))
    }
    send(editor, .ShowCursor(true))
}

/**
 * Say what the status line shows: what's being found, a note, or where the cursor is and the keys.
 *
 * @param editor The editor.
 * @return The text, on the heap, never freed.
 */
status_text :: fn(editor: ptr[Editor]) -> string {
    if editor.finding {
        query :: if editor.query.count > 0 { string_of(&editor.query[0], editor.query.count) } else { "" }
        return (strings.format("find: %", query) or_else "")
    }
    if editor.note.count > 0 {
        return editor.note
    }
    line :: line_of(editor, editor.at)
    return (strings.format("line %1 of %2, column %3%4  ^S saves  ^Q quits  ^F finds  ^Z undoes", line + 1, editor.starts.count,
        column_of(editor, editor.at) + 1, if editor.modified { ", changed" } else { "" }) or_else "")
}

/**
 * Give the part of a line the screen shows: from a column, as many columns as fit.
 *
 * @param bytes The line.
 * @param left The first column shown.
 * @param columns How many columns.
 * @return A view of the bytes shown: whole grapheme clusters only.
 */
visible :: fn(bytes: u8[], left: usize, columns: usize) -> u8[] {
    place := cast[usize](0)
    width := cast[usize](0)
    start := bytes.count
    end := bytes.count
    loop {
        if place >= bytes.count {
            break
        }
        after :: unicode.grapheme_end(bytes, place)
        if after <= place || after > bytes.count {
            break
        }
        wide :: unicode.grapheme_width(bytes[place..<after])
        if width >= left && start == bytes.count {
            start = place
        }
        if width + wide > left + columns {
            end = place
            break
        }
        width += wide
        place = after
    }
    if start >= end || end > bytes.count {
        return bytes[0..<0]
    }
    return bytes[start..<end]
}

/**
 * Ask the terminal its size, keeping the input that comes meanwhile for next_event.
 *
 * @param editor The editor, whose terminal is asked.
 * @return What it answered; 80 columns and 24 rows if it didn't.
 */
describe :: fn(editor: ptr[mut Editor]) -> protocol.Features {
    fallback :: protocol.Features.{columns = 80, rows = 24}
    console :: &editor.console
    if !protocol.send(console.end, console.port, .Describe) {
        return fallback
    }
    loop {
        into := os.Incoming.{}
        match protocol.receive_response(console.end, console.port, &into, false) {
            case Received => {}
            case Empty => {
                packets : slop_os.Packet[terminal.OTHERS]
                taken :: cast[usize](slop_os.port_wait(console.port, packets, slop_os.NO_DEADLINE) or_else 0)
                terminal.keep_others(console, packets, taken)
                continue
            }
            case _ => return fallback
        }
        match os.message_of[protocol.Response](&into)^ {
            case Described(features) => return features
            case Input(_) => terminal.take_input(console, &into)
            case _ => return fallback
        }
    }
}

/**
 * Take the terminal's size, at least 10 columns and 3 rows.
 *
 * @param editor The editor.
 * @param features What the terminal said.
 */
size_from :: fn(editor: ptr[mut Editor], features: protocol.Features) {
    editor.columns = if features.columns >= 10 { cast[usize](features.columns) } else { 80 }
    editor.rows = if features.rows >= 3 { cast[usize](features.rows) } else { 24 }
}

/**
 * Send the terminal a request it doesn't answer, ignoring a failure: a terminal that's gone ends the next wait for a key.
 *
 * @param editor The editor.
 * @param request The request.
 */
send :: fn(editor: ptr[mut Editor], request: protocol.Request) {
    _ = protocol.send(editor.console.end, editor.console.port, request)
}
