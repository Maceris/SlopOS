/**
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

/** The columns of the screen, the status line's included. */
COLUMNS :: 80
/** The rows of the screen: the status line, then the program's. */
ROWS :: 24
/** The rows programs have, below the status line. */
PROGRAM_ROWS :: ROWS - 1
/** The most bytes of one cell's cluster: what safe_text shows for a long one is U+FFFD, and a substitute is 12. */
CELL_BYTES :: 16

/**
 * One cell: its cluster's bytes and the columns they take.
 *
 * The second column of a wide cluster is a cell of width 0, and an empty cell shows a space.
 */
Cell :: struct {
    /** The cluster's UTF-8 bytes, the first count of them; what's past CELL_BYTES is dropped. */
    bytes : u8[CELL_BYTES],
    /** How many of bytes are the cluster's: 0 for an empty cell, at most CELL_BYTES. */
    count : u8,
    /** The columns the cluster takes: 1 or 2, or 0 for an empty cell or a wide cluster's second column. */
    width : u8,
    /** The colours and attributes the cell is drawn in. */
    style : terminal.Style,
}

/** The cells of one screen, the cursor in it, which rows changed, and how many times a line break's scrolled it. */
Grid :: struct {
    /** The cells, row by row, COLUMNS to a row, the program's row 0 first. */
    cells : Cell[COLUMNS * PROGRAM_ROWS],
    /** The cursor's column, from 0; COLUMNS once a row's last column is written, until the next cluster wraps. */
    column : u16,
    /** The cursor's row, from 0, below PROGRAM_ROWS. */
    row : u16,
    /** Which rows changed since they were last drawn; whoever draws a row clears its mark. */
    dirty : bool[PROGRAM_ROWS],
    /** How many times a line break at the bottom has scrolled it up a row, in all; only grows. */
    scrolls : u64,
}

/** What the console's terminal shows: the program's grids, the panel, and the status line. */
Screen :: struct {
    /** The lines programs write, which scroll up as they fill. */
    lines : Grid,
    /** A screen a program takes for its own, whose cursor it moves anywhere. */
    whole : Grid,
    /** Whether programs write to whole now, rather than lines. */
    using_whole : bool,
    /** The terminal service's own screen, the secure attention key's, shown over the program's while it's up. */
    panel : Grid,
    /** Whether the panel's up, shown over the program's grid. */
    showing_panel : bool,
    /** The status line's text, the first status_count bytes of it, as the terminal service set it. */
    status : u8[COLUMNS * 3],
    /** How many of status's bytes are the text, at most its count. */
    status_count : usize,
    /** The status line's cells, made from its text, inverse. */
    status_cells : Cell[COLUMNS],
    /** Whether the status line's text has changed: set by set_status, for its reader to clear. */
    status_dirty : bool,
    /** Whether the framebuffer has the status line as it is. */
    status_drawn : bool,
}

/**
 * Find the grid programs write to now: the whole screen they took, or the lines.
 *
 * @param screen The screen, only read: its whole grid while a program has taken it (using_whole), its lines otherwise.
 * @return The grid, in screen, good as long as it is.
 */
current :: fn(screen: ptr[mut Screen]) -> ptr[mut Grid] {
    return if screen.using_whole { &screen.whole } else { &screen.lines }
}

/**
 * Find the grid that's shown now: the panel while it's up, or the program's.
 *
 * @param screen The screen, only read: its panel while that's up (showing_panel), otherwise the grid current gives.
 * @return The grid, in screen, good as long as it is.
 */
shown :: fn(screen: ptr[mut Screen]) -> ptr[mut Grid] {
    return if screen.showing_panel { &screen.panel } else { current(screen) }
}

/**
 * Show the panel over the program's grid, blank, or put it away; either way every row of what's shown is drawn again.
 *
 * @param screen The screen: showing_panel is set, the panel made blank when it's shown, and every row of the grid then
 *     shown marked changed.
 * @param showing True to show the panel, made blank with its cursor at its start; false to show the program's grid.
 */
show_panel :: fn(screen: ptr[mut Screen], showing: bool) {
    if showing {
        reset(&screen.panel)
    }
    screen.showing_panel = showing
    mark_all(shown(screen))
}

/**
 * Write text into a grid at a place, each grapheme cluster a cell, as far as the row goes; the cursor doesn't move.
 *
 * @param grid The grid written to; the row is marked changed.
 * @param row The row, from 0; nothing's written on a row past the grid's.
 * @param column The column the text starts at, from 0; what's past the row's end is dropped.
 * @param text The text, the terminal service's own, so nothing in it needs making safe.
 * @param style The colours and attributes every cell is written in.
 */
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

/**
 * Find a cell of a grid.
 *
 * @param grid The grid, not changed here; the cell returned points into it.
 * @param row The cell's row, from 0.
 * @param column The cell's column, from 0.
 * @return The cell, in grid; null if the row or column is past the grid's.
 */
cell :: fn(grid: ptr[mut Grid], row: u16, column: u16) -> ptr[mut Cell]? {
    index :: cast[usize](row) * COLUMNS + cast[usize](column)
    if row >= PROGRAM_ROWS || column >= COLUMNS || index >= grid.cells.count {
        return null
    }
    return &grid.cells[index]
}

/**
 * Put a cluster in the cell at the cursor of the grid programs write to, which moves on by its columns, wrapping to
 * the next row first if it doesn't fit.
 *
 * @param screen The screen, whose current grid is written.
 * @param bytes The cluster, already made safe; only its first CELL_BYTES are kept.
 * @param columns The columns it takes, 2 for any more than 2; 0 for a cluster that takes none, which is added to the
 *     cell before the cursor instead, as a combining mark is.
 * @param style The colours and attributes it's drawn in.
 */
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

/**
 * Add bytes to the cluster in the cell just before the cursor, as a mark that came after it is.
 *
 * Nothing's added at a row's start, and bytes past the cell's CELL_BYTES are dropped.
 *
 * @param grid The grid; the cursor's row is marked changed.
 * @param bytes The bytes, already made safe, added after the cell's own in order; the cell's width doesn't change, and
 *     an empty slice adds nothing.
 */
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

/**
 * Set a cell to a cluster.
 *
 * @param target The cell, whose row the caller marks changed.
 * @param bytes The cluster's bytes, copied; only the first CELL_BYTES are kept.
 * @param width The columns it takes: 1 or 2, or 0 for a wide cluster's second column.
 * @param style The colours and attributes it's drawn in.
 */
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

/**
 * Move the cursor of the grid programs write to to the next row's start, scrolling the grid up a row at its bottom,
 * which counts in its scrolls.
 *
 * @param screen The screen, whose current grid's cursor moves.
 */
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

/**
 * Move rows of a grid up or down, the rows left behind blank; each row of the region is marked changed.
 *
 * @param grid The grid whose cells move; its cursor and its scrolls don't change.
 * @param first The region's first row, from 0; past the grid's last, nothing moves.
 * @param count How many rows the region has, cut at the grid's bottom; 0 moves nothing.
 * @param lines How many rows the region's moved up, or down when negative; 0 moves nothing, and as many as the region
 *     has or more leaves it blank. Rows moved out of the region are gone.
 */
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

/**
 * Make an area of a grid blank, as far as the grid goes; its rows are marked changed. The cursor doesn't move.
 *
 * @param grid The grid whose cells in the area are made empty: no bytes, width 0, the default style.
 * @param area The area, in the grid's rows and columns from 0; what's past the grid is left out.
 */
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

/**
 * Make the row the cursor is on blank from a column on, and move the cursor to that column.
 *
 * @param grid The grid: the cursor's row is the one made blank, and the cursor's column is set to column, even one past
 *     the last.
 * @param column The first column made blank, from 0.
 */
clear_line_from :: fn(grid: ptr[mut Grid], column: u16) {
    clear(grid, terminal.Area.{column = column, row = grid.row, columns = COLUMNS, rows = 1})
    grid.column = column
}

/**
 * Make the whole of a grid blank, every row marked changed, and move the cursor to its start.
 *
 * @param grid The grid: every cell made empty and every row marked changed, its cursor put at row 0, column 0; its
 *     scrolls are kept.
 */
reset :: fn(grid: ptr[mut Grid]) {
    clear(grid, terminal.Area.{columns = COLUMNS, rows = PROGRAM_ROWS})
    grid.column = 0
    grid.row = 0
}

/**
 * Give the program a screen of its own, or go back to the lines; every row of the grid now written to is drawn again.
 *
 * @param screen The screen: using_whole is set, its whole grid made blank when newly taken, and every row of the grid
 *     then written to marked changed. The lines are kept as they were while the whole screen's in use.
 * @param whole True for the program's own screen, made blank if it wasn't already in use; false for the lines, as they
 *     were left.
 */
use_whole :: fn(screen: ptr[mut Screen], whole: bool) {
    if whole && !screen.using_whole {
        reset(&screen.whole)
    }
    screen.using_whole = whole
    mark_all(current(screen))
}

/**
 * Move the cursor of the grid programs write to.
 *
 * @param screen The screen, whose current grid's cursor moves.
 * @param column The column, from 0; past the last, the last.
 * @param row The row, from 0; past the last, the last. Only on the program's own screen: on the lines, the cursor's
 *     row stays as it is.
 */
move :: fn(screen: ptr[mut Screen], column: u16, row: u16) {
    grid :: current(screen)
    grid.column = if column < COLUMNS { column } else { COLUMNS - 1 }
    if screen.using_whole {
        grid.row = if row < PROGRAM_ROWS { row } else { PROGRAM_ROWS - 1 }
    }
}

/**
 * Mark a row of a grid changed, to be drawn again.
 *
 * @param grid The grid whose dirty mark for the row is set; its cells don't change.
 * @param row The row, from 0; one past the grid's is ignored.
 */
mark :: fn(grid: ptr[mut Grid], row: u16) {
    index :: cast[usize](row)
    if index < grid.dirty.count {
        grid.dirty[index] = true
    }
}

/**
 * Mark every row of a grid changed, to be drawn again.
 *
 * @param grid The grid whose every row's dirty mark is set; whoever draws a row clears its mark.
 */
mark_all :: fn(grid: ptr[mut Grid]) {
    for i in 0..<grid.dirty.count {
        grid.dirty[i] = true
    }
}

/**
 * Set the status line's text, and, if it changed, its cells, marked changed (status_dirty) and not yet drawn on the
 * framebuffer (status_drawn).
 *
 * The cells are the text's clusters, inverse, the rest of the row blank and inverse too.
 *
 * @param screen The screen: status and status_count always take the text; status_cells, status_dirty and status_drawn
 *     change only when the text differs from what was there.
 * @param text The text, the terminal service's own, copied; only its first COLUMNS * 3 bytes are kept, and only the
 *     clusters that fit COLUMNS columns are shown.
 */
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

/**
 * Find the status line's text.
 *
 * @param screen The screen, only read; the text is empty if status_count is past status's count.
 * @return The text's bytes, a view of screen's, good until the status line's set again.
 */
status_text :: fn(screen: ptr[Screen]) -> u8[] {
    return if screen.status_count <= screen.status.count { screen.status[0..<screen.status_count] } else { screen.status[0..<0] }
}
