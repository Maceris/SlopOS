/*
 * What the console's terminal shows (decisions/0136, 0138): a grid of cells, each a grapheme cluster already made safe
 * (safe_text) in a style, for the lines programs write and for a screen a program takes for its own, with the cursor in
 * each, and which rows changed since they were last drawn. The terminal service keeps one and draws it on its back
 * ends: the framebuffer from its cells, the serial line from the rows it redraws, after the secure attention key's
 * screen and when the status line changes. Row 0 is the status line, which only the terminal service writes; programs
 * see the rows below it, from 0.
 */
package screen

import terminal from "std/os/slop_os"
import unicode from "std"

COLUMNS :: 80
ROWS :: 24
// The rows programs have, below the status line
PROGRAM_ROWS :: ROWS - 1
// The most bytes of one cell's cluster: what safe_text shows for a long one is U+FFFD, and a substitute is 12
CELL_BYTES :: 16

/*
 * One cell: its cluster's bytes and the columns they take. The second column of a wide cluster is a cell of width 0, and
 * an empty cell shows a space.
 */
Cell :: struct {
    bytes : u8[CELL_BYTES],
    count : u8,
    width : u8,
    style : terminal.Style,
}

// The cells of one screen, the cursor in it, which rows changed, and how many times a line break's scrolled it.
Grid :: struct {
    cells : Cell[COLUMNS * PROGRAM_ROWS],
    column : u16,
    row : u16,
    dirty : bool[PROGRAM_ROWS],
    scrolls : u64,
}

Screen :: struct {
    lines : Grid,
    whole : Grid,
    using_whole : bool,
    // The terminal service's own screen, the secure attention key's, shown over the program's while it's up
    panel : Grid,
    showing_panel : bool,
    // The status line's text, its cells, and whether it changed
    status : u8[COLUMNS * 3],
    status_count : usize,
    status_cells : Cell[COLUMNS],
    status_dirty : bool,
    // Whether the framebuffer has the status line as it is
    status_drawn : bool,
}

// The grid programs write to now.
current :: fn(screen: ptr[mut Screen]) -> ptr[mut Grid] {
    return if screen.using_whole { &screen.whole } else { &screen.lines }
}

// The grid that's shown now: the panel while it's up, or the program's.
shown :: fn(screen: ptr[mut Screen]) -> ptr[mut Grid] {
    return if screen.showing_panel { &screen.panel } else { current(screen) }
}

// The panel, blank, shown or not; either way every row of what's shown is drawn again.
show_panel :: fn(screen: ptr[mut Screen], showing: bool) {
    if showing {
        reset(&screen.panel)
    }
    screen.showing_panel = showing
    mark_all(shown(screen))
}

// text, each grapheme cluster a cell, at row and column of grid, in style, as far as the row goes. text is the
// terminal service's own, so nothing in it needs making safe.
write_at :: fn(grid: ptr[mut Grid], row: u16, column: u16, text: string, style: terminal.Style) {
    bytes :: string_bytes(text)
    at : usize = 0
    place := column
    loop {
        end :: unicode.grapheme_end(bytes, at)
        if end <= at || end > bytes.count || place >= COLUMNS {
            break
        }
        width :: cast[u16](unicode.grapheme_width(bytes[at..<end]))
        target :: cell(grid, row, place) or_break
        set(target, bytes[at..<end], cast[u8](width), style)
        place += if width == 0 { cast[u16](1) } else { width }
        at = end
    }
    while at < bytes.count
    mark(grid, row)
}

cell :: fn(grid: ptr[mut Grid], row: u16, column: u16) -> ptr[mut Cell]? {
    index :: cast[usize](row) * COLUMNS + cast[usize](column)
    if row >= PROGRAM_ROWS || column >= COLUMNS || index >= grid.cells.count {
        return null
    }
    return &grid.cells[index]
}

// A cell's cluster at the cursor, which moves on by its columns, wrapping to the next row first if it doesn't fit.
put :: fn(screen: ptr[mut Screen], bytes: u8[], columns: usize, style: terminal.Style) {
    grid :: current(screen)
    width :: if columns > 2 { cast[u16](2) } else { cast[u16](columns) }
    if width == 0 {
        // Nothing that takes columns: kept with the cell before, if it has room
        attach(grid, bytes)
        return void
    }
    if grid.column + width > COLUMNS {
        line_break(screen)
    }
    target :: cell(grid, grid.row, grid.column) or_return void
    set(target, bytes, cast[u8](width), style)
    if width == 2 {
        match cell(grid, grid.row, grid.column + 1) {
            case Some(second) => set(second, bytes[0..<0], 0, style)
            case None => {}
        }
    }
    mark(grid, grid.row)
    grid.column += width
}

// bytes added to the cluster just before the cursor, as a mark is that came after it.
attach :: fn(grid: ptr[mut Grid], bytes: u8[]) {
    if grid.column == 0 {
        return void
    }
    before :: cell(grid, grid.row, grid.column - 1) or_return void
    for byte in bytes {
        if cast[usize](before.count) < before.bytes.count {
            before.bytes[before.count] = byte
            before.count += 1
        }
    }
    mark(grid, grid.row)
}

set :: fn(target: ptr[mut Cell], bytes: u8[], width: u8, style: terminal.Style) {
    taken :: if bytes.count < target.bytes.count { bytes.count } else { target.bytes.count }
    for i in 0..<taken {
        if i < target.bytes.count && i < bytes.count {
            target.bytes[i] = bytes[i]
        }
    }
    target.count = cast[u8](taken)
    target.width = width
    target.style = style
}

// The cursor to the next row's start, scrolling the grid up a row at its bottom.
line_break :: fn(screen: ptr[mut Screen]) {
    grid :: current(screen)
    grid.column = 0
    if grid.row + 1 < PROGRAM_ROWS {
        grid.row += 1
        return void
    }
    scroll(grid, 0, PROGRAM_ROWS, 1)
    grid.scrolls += 1
}

// Rows first to first + count of grid moved up by lines, or down when negative, the rows left behind blank.
scroll :: fn(grid: ptr[mut Grid], first: u16, count: u16, lines: i16) {
    if count == 0 || first >= PROGRAM_ROWS || lines == 0 {
        return void
    }
    last :: if count > PROGRAM_ROWS - first { cast[u16](PROGRAM_ROWS) } else { first + count }
    if lines > 0 {
        by :: cast[u16](lines)
        for row in first..<last {
            from :: row + by
            for column in 0..<cast[u16](COLUMNS) {
                target :: cell(grid, row, column) or_return void
                if from < last {
                    source :: cell(grid, from, column) or_return void
                    target^ = source^
                }
                else {
                    target^ = Cell.{}
                }
            }
            mark(grid, row)
        }
    }
    else {
        by :: cast[u16](-cast[i32](lines))
        for step in 0..<last - first {
            row :: last - 1 - step
            for column in 0..<cast[u16](COLUMNS) {
                target :: cell(grid, row, column) or_return void
                if row >= first + by {
                    source :: cell(grid, row - by, column) or_return void
                    target^ = source^
                }
                else {
                    target^ = Cell.{}
                }
            }
            mark(grid, row)
        }
    }
}

// An area of the grid made blank.
clear :: fn(grid: ptr[mut Grid], area: terminal.Area) {
    for row in area.row..<area.row + area.rows {
        if row >= PROGRAM_ROWS {
            break
        }
        for column in area.column..<area.column + area.columns {
            if column >= COLUMNS {
                break
            }
            target :: cell(grid, row, column) or_return void
            target^ = Cell.{}
        }
        mark(grid, row)
    }
}

// The row the cursor is on, blank from column on.
clear_line_from :: fn(grid: ptr[mut Grid], column: u16) {
    clear(grid, terminal.Area.{column = column, row = grid.row, columns = COLUMNS, rows = 1})
    grid.column = column
}

// The whole of a grid made blank, the cursor at its start.
reset :: fn(grid: ptr[mut Grid]) {
    clear(grid, terminal.Area.{columns = COLUMNS, rows = PROGRAM_ROWS})
    grid.column = 0
    grid.row = 0
}

// A screen of the program's own, blank, or back to the lines.
use_whole :: fn(screen: ptr[mut Screen], whole: bool) {
    if whole && !screen.using_whole {
        reset(&screen.whole)
    }
    screen.using_whole = whole
    mark_all(current(screen))
}

move :: fn(screen: ptr[mut Screen], column: u16, row: u16) {
    grid :: current(screen)
    grid.column = if column < COLUMNS { column } else { COLUMNS - 1 }
    if screen.using_whole {
        grid.row = if row < PROGRAM_ROWS { row } else { PROGRAM_ROWS - 1 }
    }
}

mark :: fn(grid: ptr[mut Grid], row: u16) {
    index :: cast[usize](row)
    if index < grid.dirty.count {
        grid.dirty[index] = true
    }
}

mark_all :: fn(grid: ptr[mut Grid]) {
    for i in 0..<grid.dirty.count {
        grid.dirty[i] = true
    }
}

// The status line's text, marked to be drawn if it changed.
set_status :: fn(screen: ptr[mut Screen], text: string) {
    bytes :: string_bytes(text)
    taken :: if bytes.count < screen.status.count { bytes.count } else { screen.status.count }
    same := taken == screen.status_count
    for i in 0..<taken {
        if i >= screen.status.count || i >= bytes.count {
            break
        }
        if same && i < screen.status_count && screen.status[i] != bytes[i] {
            same = false
        }
        screen.status[i] = bytes[i]
    }
    screen.status_count = taken
    screen.status_dirty = screen.status_dirty || !same
    if !same {
        // Its cells, inverse, the rest of the row blank and inverse too
        inverse :: terminal.Style.{attributes = terminal.INVERSE}
        for &each in screen.status_cells {
            each^ = Cell.{style = inverse}
        }
        line :: status_text(screen)
        at : usize = 0
        place : usize = 0
        loop {
            end :: unicode.grapheme_end(line, at)
            if end <= at || end > line.count || place >= screen.status_cells.count {
                break
            }
            width :: unicode.grapheme_width(line[at..<end])
            set(&screen.status_cells[place], line[at..<end], cast[u8](width), inverse)
            place += if width == 0 { cast[usize](1) } else { width }
            at = end
        }
        while at < line.count
        screen.status_drawn = false
    }
}

status_text :: fn(screen: ptr[Screen]) -> u8[] {
    return if screen.status_count <= screen.status.count { screen.status[0..<screen.status_count] } else { screen.status[0..<0] }
}
