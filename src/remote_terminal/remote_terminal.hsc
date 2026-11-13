/**
 * A terminal served over a byte stream to a terminal of the client's own (decisions/0191, 14d): the SSH service's
 * sessions'. The terminal protocol's requests become VT output (src/vt) at the size the client gave, with no screen
 * model: the client's terminal keeps what's shown, so nothing's ever drawn again. Text is made safe a cluster at a time
 * (safe_text), as the console's is, so a program can't write a sequence of its own.
 *
 * On lines, output goes where it ended, and the line being typed (InputLine) is drawn after it, on a row of its own if
 * the output's row has something on it; before more output it's taken away again, by moving back up the rows it took
 * and clearing below. Its rows are counted from its columns as written, wrapping at the client's width. On a whole
 * screen (Screen), the program's rows and columns are the client's, from 0.
 *
 * A plain terminal, for a command run without one (SSH's exec without a pty), is only its text: line breaks as LF,
 * tabs as tabs, and no styles, links, moves, clears or line being typed.
 */
package remote_terminal

import text_buffer from "std"
import unicode from "std"
import terminal from "std/os/slop_os"
import safe_text from "../safe_text"
import vt from "../vt"

/** The most bytes of the line being typed kept; the rest isn't shown. */
INPUT_BYTES :: 1024
/** Tabs stop at every eighth column. */
TAB_STOP : u16 : 8

/** A served terminal's state. */
RemoteTerminal :: struct {
    /** The client's size, at least 1 by 1. */
    columns : u16,
    rows : u16,
    /** Whether the program has the whole screen. */
    whole : bool,
    /** Whether it's plain: text only, its line breaks LF (make_plain). */
    plain : bool,
    /** On lines, the column the output's at, from 0. */
    column : u16,
    /** The line being typed, its first input_count bytes, and the cursor's byte in it. */
    input : u8[INPUT_BYTES],
    input_count : usize,
    input_cursor : usize,
    /** Whether the line's drawn, whether a line break was written before it, and the cursor's row below its first. */
    input_drawn : bool,
    input_break : bool,
    input_cursor_row : u16,
}

/** A terminal of a size: the client's, or 80 by 24 for 0. */
make :: fn(columns: u32, rows: u32) -> RemoteTerminal {
    made := RemoteTerminal.{}
    resize(&made, columns, rows)
    return made
}

/** A plain terminal, for a command's output to a client without a terminal: text only. */
make_plain :: fn() -> RemoteTerminal {
    made := make(80, 24)
    made.plain = true
    return made
}

/** Take a new size: the client's terminal was resized. */
resize :: fn(term: ptr[mut RemoteTerminal], columns: u32, rows: u32) {
    term.columns = if columns == 0 { cast[u16](80) } else if columns > 1000 { cast[u16](1000) } else { cast[u16](columns) }
    term.rows = if rows == 0 { cast[u16](24) } else if rows > 1000 { cast[u16](1000) } else { cast[u16](rows) }
    if term.column >= term.columns {
        term.column = 0
    }
}

/** What the terminal can show: Describe's answer. */
features :: fn(term: ptr[RemoteTerminal]) -> terminal.Features {
    return terminal.Features.{columns = term.columns, rows = term.rows, colors = .Rgb,
        attributes = terminal.BOLD | terminal.DIM | terminal.ITALIC | terminal.UNDERLINE | terminal.INVERSE | terminal.STRIKETHROUGH,
        links = true, unicode = 17 * 256}
}

/**
 * Write text, in its runs' styles, where the output is.
 *
 * @param term The terminal.
 * @param bytes The text.
 * @param runs Its runs: each its bytes' count and style, and its link's range in links; past the last, the last's.
 * @param links The links' targets.
 * @param out Where the VT bytes go.
 */
write :: fn(term: ptr[mut RemoteTerminal], bytes: u8[], runs: terminal.Run[], links: u8[], out: ptr[mut text_buffer.TextBuffer]) {
    hide_input(term, out)
    plain :: terminal.Style.{}
    current := plain
    linked := false
    run_index : usize = 0
    run_end : usize = if runs.count > 0 { cast[usize](runs[0].bytes) } else { bytes.count }
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        end :: unicode.grapheme_end(bytes, at)
        if end <= at || end > bytes.count {
            break
        }
        loop {
            if at < run_end || run_index + 1 >= runs.count {
                break
            }
            run_index += 1
            if run_index < runs.count {
                run_end += cast[usize](runs[run_index].bytes)
            }
        }
        if run_index < runs.count && !term.plain {
            run :: runs[run_index]
            if !same_style(run.style, current) {
                vt.append_style(out, run.style)
                current = run.style
            }
            wanted :: run.link_bytes > 0
            if wanted || linked {
                start :: cast[usize](run.link_start)
                stop :: start + cast[usize](run.link_bytes)
                if wanted && stop <= links.count && start <= stop {
                    vt.append_link(out, links[start..<stop])
                }
                else if linked {
                    vt.append_link(out, links[0..<0])
                }
                linked = wanted
            }
        }
        if safe_text.is_line_break(bytes, at, end) {
            if term.plain {
                text_buffer.append_byte(out, 0x0a)
            }
            else {
                vt.append_line_break(out)
            }
            term.column = 0
        }
        else if safe_text.is_tab(bytes, at, end) && term.plain {
            text_buffer.append_byte(out, 0x09)
        }
        else if safe_text.is_tab(bytes, at, end) {
            loop {
                text_buffer.append_byte(out, cast[u8](' '))
                advance(term, 1)
            }
            while term.column % TAB_STOP != 0
        }
        else {
            shown := safe_text.Shown.{}
            safe_text.show(bytes, at, end, &shown)
            if shown.count > 0 && shown.count <= shown.bytes.count {
                text_buffer.append(out, string_of(&shown.bytes[0], shown.count))
                advance(term, shown.columns)
            }
        }
        at = end
    }
    if linked {
        vt.append_link(out, links[0..<0])
    }
    if !same_style(current, plain) {
        vt.append_style(out, plain)
    }
    show_input(term, out)
}

/** Move the output's column on by what was written, wrapping at the client's width. */
advance :: fn(term: ptr[mut RemoteTerminal], columns: usize) {
    if term.whole {
        return void
    }
    next :: cast[usize](term.column) + columns
    term.column = cast[u16](next % cast[usize](term.columns))
}

/**
 * Move the cursor: anywhere on a whole screen; on lines, along the line being written, the row ignored.
 *
 * @param term The terminal.
 * @param position Where, from 0.
 * @param out Where the VT bytes go.
 */
move_cursor :: fn(term: ptr[mut RemoteTerminal], position: terminal.Position, out: ptr[mut text_buffer.TextBuffer]) {
    if term.plain {
        return void
    }
    column :: if position.column < term.columns { position.column } else { term.columns - 1 }
    if term.whole {
        row :: if position.row < term.rows { position.row } else { term.rows - 1 }
        vt.append_move(out, row, column)
        return void
    }
    hide_input(term, out)
    vt.append_column(out, column)
    term.column = column
    show_input(term, out)
}

/**
 * Clear an area: on a whole screen, its cells made blank; on lines, the line being written from the area's column, for
 * an area on the row being written, or nothing.
 */
clear :: fn(term: ptr[mut RemoteTerminal], area: terminal.Area, out: ptr[mut text_buffer.TextBuffer]) {
    if term.plain {
        return void
    }
    if !term.whole {
        hide_input(term, out)
        vt.append_column(out, if area.column < term.columns { area.column } else { term.columns - 1 })
        vt.append_clear_to_end(out)
        vt.append_column(out, term.column)
        show_input(term, out)
        return void
    }
    if area.column == 0 && area.row == 0 && area.columns >= term.columns && area.rows >= term.rows {
        vt.append_clear_screen(out)
        return void
    }
    last_row :: if cast[u32](area.row) + cast[u32](area.rows) < cast[u32](term.rows) { area.row + area.rows } else { term.rows }
    width :: if cast[u32](area.column) + cast[u32](area.columns) < cast[u32](term.columns) { area.columns }
        else if area.column < term.columns { term.columns - area.column } else { cast[u16](0) }
    for row in area.row..<last_row {
        vt.append_move(out, row, area.column)
        if area.column + width >= term.columns {
            vt.append_clear_to_end(out)
        }
        else {
            for i in cast[u16](0)..<width {
                text_buffer.append_byte(out, cast[u8](' '))
            }
        }
    }
}

/** Scroll an area's rows, on a whole screen; on lines, nothing. The margins are put back to the whole screen. */
scroll :: fn(term: ptr[mut RemoteTerminal], scrolled: terminal.ScrollArea, out: ptr[mut text_buffer.TextBuffer]) {
    if !term.whole || scrolled.area.rows == 0 || scrolled.area.row >= term.rows {
        return void
    }
    last :: if cast[u32](scrolled.area.row) + cast[u32](scrolled.area.rows) <= cast[u32](term.rows) { scrolled.area.row + scrolled.area.rows - 1 }
        else { term.rows - 1 }
    vt.append_scroll(out, scrolled.area.row, last, scrolled.lines)
    vt.append_margins(out, 0, term.rows - 1)
}

/** Take the whole screen for the program, blank, or go back to lines. */
use_screen :: fn(term: ptr[mut RemoteTerminal], whole: bool, out: ptr[mut text_buffer.TextBuffer]) {
    if whole == term.whole || term.plain {
        return void
    }
    if whole {
        hide_input(term, out)
        vt.append_alternate_screen(out, true)
        vt.append_clear_screen(out)
        term.whole = true
    }
    else {
        vt.append_alternate_screen(out, false)
        term.whole = false
        show_input(term, out)
    }
}

/** Set the line being typed, and where its cursor is; drawn at once on lines. */
set_input :: fn(term: ptr[mut RemoteTerminal], text: u8[], cursor: u32, out: ptr[mut text_buffer.TextBuffer]) {
    hide_input(term, out)
    term.input_count = if text.count < term.input.count { text.count } else { term.input.count }
    for byte, i in text {
        if i < term.input.count {
            term.input[i] = byte
        }
    }
    term.input_cursor = if cast[usize](cursor) < term.input_count { cast[usize](cursor) } else { term.input_count }
    show_input(term, out)
}

/** Take the line being typed away, from the screen and from the terminal. */
drop_input :: fn(term: ptr[mut RemoteTerminal], out: ptr[mut text_buffer.TextBuffer]) {
    hide_input(term, out)
    term.input_count = 0
    term.input_cursor = 0
}

/** Draw the line being typed after the output, if there's one and the program's on lines. */
show_input :: fn(term: ptr[mut RemoteTerminal], out: ptr[mut text_buffer.TextBuffer]) {
    if term.input_drawn || term.whole || term.plain || term.input_count == 0 || term.input_count > term.input.count {
        return void
    }
    term.input_break = term.column > 0
    if term.input_break {
        vt.append_line_break(out)
    }
    line :: if term.input_count <= term.input.count { term.input[0..<term.input_count] } else { term.input[0..<0] }
    column := cast[usize](0)
    row := cast[u16](0)
    cursor_column := cast[usize](0)
    cursor_row := cast[u16](0)
    at : usize = 0
    loop {
        if at == term.input_cursor {
            cursor_column = column
            cursor_row = row
        }
        if at >= line.count {
            break
        }
        end :: unicode.grapheme_end(line, at)
        if end <= at || end > line.count {
            break
        }
        shown := safe_text.Shown.{}
        safe_text.show(line, at, end, &shown)
        if shown.count > 0 && shown.count <= shown.bytes.count {
            if column + shown.columns > cast[usize](term.columns) {
                column = 0
                row += 1
            }
            text_buffer.append(out, string_of(&shown.bytes[0], shown.count))
            column += shown.columns
        }
        at = end
    }
    // The cursor put where the reader says: back up the rows after its, and to its column
    if row > cursor_row {
        text_buffer.append_byte(out, vt.ESCAPE)
        text_buffer.append(out, "[")
        text_buffer.append_unsigned(out, cast[u64](row - cursor_row))
        text_buffer.append(out, "A")
    }
    vt.append_column(out, cast[u16](if cursor_column < cast[usize](term.columns) { cursor_column } else { cast[usize](term.columns) - 1 }))
    term.input_cursor_row = cursor_row
    term.input_drawn = true
}

/** Take the drawn line being typed off the screen, putting the cursor back where the output ended. */
hide_input :: fn(term: ptr[mut RemoteTerminal], out: ptr[mut text_buffer.TextBuffer]) {
    if !term.input_drawn {
        return void
    }
    term.input_drawn = false
    text_buffer.append_byte(out, 0x0d)
    if term.input_cursor_row > 0 {
        text_buffer.append_byte(out, vt.ESCAPE)
        text_buffer.append(out, "[")
        text_buffer.append_unsigned(out, cast[u64](term.input_cursor_row))
        text_buffer.append(out, "A")
    }
    vt.append_clear_below(out)
    if term.input_break {
        text_buffer.append_byte(out, vt.ESCAPE)
        text_buffer.append(out, "[A")
    }
    vt.append_column(out, term.column)

}

/** Whether two styles are the same. */
same_style :: fn(a: terminal.Style, b: terminal.Style) -> bool {
    return a.attributes == b.attributes && same_color(a.foreground, b.foreground) && same_color(a.background, b.background)
}

/** Whether two colours are the same. */
same_color :: fn(a: terminal.Color, b: terminal.Color) -> bool {
    return a.kind == b.kind && a.index == b.index && a.red == b.red && a.green == b.green && a.blue == b.blue
}
