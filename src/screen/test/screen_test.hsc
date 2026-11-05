/**
 * The screen model's tests, a test program (tools/unit_tests.py, decisions/0175). Clusters go where the cursor is and
 * wrap at the edge, a wide one takes two columns, a mark joins the cluster before it, lines scroll at the bottom, areas
 * clear and scroll, a program's own screen leaves the lines as they were, and the status line is marked only when it
 * changes.
 */
package screen_test

import testing from "std"
import terminal from "std/os/slop_os"
import screen from ".."

/**
 * Find the cluster in a cell of a grid, as text.
 *
 * @param grid The grid, only read; the text returned is a view of its cell.
 * @param row The cell's row, from 0.
 * @param column The cell's column, from 0.
 * @return The cell's cluster, a view of the grid's bytes, good until the cell changes; empty for an empty cell or one
 *     past the grid.
 */
text_at :: fn(grid: ptr[mut screen.Grid], row: u16, column: u16) -> string {
    found :: screen.cell(grid, row, column) or_return ""
    if found.count == 0 || cast[usize](found.count) > found.bytes.count {
        return ""
    }
    return string_of(&found.bytes[0], cast[usize](found.count))
}

clusters_go_where_the_cursor_is #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shown := screen.Screen.{}
    plain :: terminal.Style.{}
    grid :: &shown.lines
    // Narrow, then wide, then a mark that joins the wide one
    screen.put(&shown, string_bytes("a"), 1, plain)
    screen.put(&shown, string_bytes("中"), 2, plain)
    screen.put(&shown, string_bytes("́"[0..<0]), 0, plain)
    testing.expect_eq(t, text_at(grid, 0, 0), "a", "the first cluster goes in the first cell")
    testing.expect_eq(t, text_at(grid, 0, 1), "中", "the wide one goes next, the mark joining it")
    testing.expect_eq(t, grid.column, 3, "one narrow cluster and one wide take three columns")
    second :: testing.require_some(t, screen.cell(grid, 0, 2), "the wide cluster's second column is in the grid")?
    testing.expect_eq(t, second.width, 0, "a wide cluster's second column is its continuation, of no width")
    testing.expect(t, grid.dirty[0], "the row written to is marked to be drawn")
    testing.expect(t, !grid.dirty[1], "a row not written to isn't")
    return .Ok
}

a_wide_cluster_that_does_not_fit_wraps_whole #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shown := screen.Screen.{}
    plain :: terminal.Style.{}
    grid :: &shown.lines
    screen.put(&shown, string_bytes("a"), 1, plain)
    grid.column = screen.COLUMNS - 1
    screen.put(&shown, string_bytes("中"), 2, plain)
    testing.expect_eq(t, grid.row, 1, "it doesn't fit the last column, so it goes on the next row")
    testing.expect_eq(t, grid.column, 2, "after the two columns it took there")
    testing.expect_eq(t, text_at(grid, 1, 0), "中", "whole, at the next row's start")
    return .Ok
}

a_line_break_at_the_bottom_scrolls_everything_up #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shown := screen.Screen.{}
    plain :: terminal.Style.{}
    grid :: &shown.lines
    grid.row = 1
    screen.put(&shown, string_bytes("中"), 2, plain)
    grid.row = screen.PROGRAM_ROWS - 1
    grid.column = 0
    screen.put(&shown, string_bytes("z"), 1, plain)
    screen.line_break(&shown)
    testing.expect_eq(t, grid.row, screen.PROGRAM_ROWS - 1, "the cursor stays on the bottom row")
    testing.expect_eq(t, grid.column, 0, "at its start")
    testing.expect_eq(t, text_at(grid, screen.PROGRAM_ROWS - 2, 0), "z", "the bottom row moved up one")
    testing.expect_eq(t, text_at(grid, 0, 0), "中", "the second row moved up to the first")
    testing.expect_eq(t, text_at(grid, screen.PROGRAM_ROWS - 1, 0), "", "the bottom row is a new, empty one")
    return .Ok
}

a_whole_screen_starts_blank_and_leaving_it_finds_the_lines_as_they_were #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shown := screen.Screen.{}
    plain :: terminal.Style.{}
    grid :: &shown.lines
    screen.put(&shown, string_bytes("a"), 1, plain)
    screen.put(&shown, string_bytes("中"), 2, plain)
    grid.row = screen.PROGRAM_ROWS - 2
    grid.column = 0
    screen.put(&shown, string_bytes("z"), 1, plain)
    screen.use_whole(&shown, true)
    testing.expect_eq(t, text_at(&shown.whole, 0, 1), "", "a program's own screen starts blank, not with the lines'")
    screen.put(&shown, string_bytes("w"), 1, plain)
    screen.move(&shown, 4, 2)
    screen.put(&shown, string_bytes("x"), 1, plain)
    testing.expect_eq(t, text_at(&shown.whole, 0, 0), "w", "writing goes to the whole screen, from its corner")
    testing.expect_eq(t, text_at(&shown.whole, 2, 4), "x", "move takes a column, then a row")
    screen.use_whole(&shown, false)
    testing.expect_eq(t, text_at(grid, screen.PROGRAM_ROWS - 2, 0), "z", "the lines weren't touched while it was in use")
    testing.expect_eq(t, text_at(grid, 0, 1), "中", "nor their first row")
    return .Ok
}

areas_scroll_and_clear #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shown := screen.Screen.{}
    plain :: terminal.Style.{}
    screen.use_whole(&shown, true)
    screen.put(&shown, string_bytes("w"), 1, plain)
    screen.move(&shown, 4, 2)
    screen.put(&shown, string_bytes("x"), 1, plain)
    // Scrolling an area down a row, then clearing part of one
    screen.scroll(&shown.whole, 0, 3, -1)
    testing.expect_eq(t, text_at(&shown.whole, 1, 0), "w", "scrolling rows 0 to 2 down moves row 0 to row 1")
    testing.expect_eq(t, text_at(&shown.whole, 0, 0), "", "and leaves row 0 empty")
    testing.expect_eq(t, text_at(&shown.whole, 2, 4), "", "row 2 moved down, out of the area, and row 1's empty cell took its place")
    screen.clear(&shown.whole, terminal.Area.{column = 0, row = 1, columns = 1, rows = 1})
    testing.expect_eq(t, text_at(&shown.whole, 1, 0), "", "clearing a cell empties it")
    return .Ok
}

the_status_line_is_marked_only_when_it_changes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    shown := screen.Screen.{}
    screen.set_status(&shown, "one")
    shown.status_dirty = false
    screen.set_status(&shown, "one")
    testing.expect(t, !shown.status_dirty, "setting the same text again changes nothing to draw")
    screen.set_status(&shown, "two")
    testing.expect(t, shown.status_dirty, "new text has to be drawn")
    testing.expect_eq(t, screen.status_text(&shown).count, 3, "the status is the new text, three bytes")
    return .Ok
}
