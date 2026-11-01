/*
 * The screen model's tests, as a hosted program (tools/unit_tests.py): main returns 0 if everything worked, or the
 * number of the first check that failed. Clusters go where the cursor is and wrap at the edge, a wide one takes two
 * columns, a mark joins the cluster before it, lines scroll at the bottom, areas clear and scroll, a program's own
 * screen leaves the lines as they were, and the status line is marked only when it changes.
 */
package screen_test

import terminal from "std/os/slop_os"
import screen from ".."

text_at :: fn(grid: ptr[mut screen.Grid], row: u16, column: u16) -> string {
    found :: screen.cell(grid, row, column) or_return ""
    if found.count == 0 || cast[usize](found.count) > found.bytes.count {
        return ""
    }
    return string_of(&found.bytes[0], cast[usize](found.count))
}

main :: fn() -> int {
    shown := screen.Screen.{}
    plain :: terminal.Style.{}
    grid :: &shown.lines

    // Narrow, then wide, then a mark that joins the wide one
    screen.put(&shown, string_bytes("a"), 1, plain)
    screen.put(&shown, string_bytes("中"), 2, plain)
    screen.put(&shown, string_bytes("́"[0..<0]), 0, plain)
    if text_at(grid, 0, 0) != "a" || text_at(grid, 0, 1) != "中" || grid.column != 3 {
        return 1
    }
    match screen.cell(grid, 0, 2) {
        case Some(second) => {
            if second.width != 0 {
                return 2
            }
        }
        case None => return 2
    }
    if !grid.dirty[0] || grid.dirty[1] {
        return 3
    }

    // A wide cluster that doesn't fit the last column wraps whole
    grid.column = screen.COLUMNS - 1
    screen.put(&shown, string_bytes("中"), 2, plain)
    if grid.row != 1 || grid.column != 2 || text_at(grid, 1, 0) != "中" {
        return 4
    }

    // At the bottom a line break scrolls everything up a row
    grid.row = screen.PROGRAM_ROWS - 1
    grid.column = 0
    screen.put(&shown, string_bytes("z"), 1, plain)
    screen.line_break(&shown)
    if grid.row != screen.PROGRAM_ROWS - 1 || grid.column != 0 || text_at(grid, screen.PROGRAM_ROWS - 2, 0) != "z"
        || text_at(grid, 0, 0) != "中" || text_at(grid, screen.PROGRAM_ROWS - 1, 0) != "" {
        return 5
    }

    // A whole screen of its own starts blank, and leaving it finds the lines as they were
    screen.use_whole(&shown, true)
    if text_at(&shown.whole, 0, 1) != "" {
        return 6
    }
    screen.put(&shown, string_bytes("w"), 1, plain)
    screen.move(&shown, 4, 2)
    screen.put(&shown, string_bytes("x"), 1, plain)
    if text_at(&shown.whole, 0, 0) != "w" || text_at(&shown.whole, 2, 4) != "x" {
        return 7
    }
    // Scrolling an area down a row, then clearing part of one
    screen.scroll(&shown.whole, 0, 3, -1)
    if text_at(&shown.whole, 1, 0) != "w" || text_at(&shown.whole, 0, 0) != "" || text_at(&shown.whole, 2, 4) != "" {
        return 8
    }
    screen.clear(&shown.whole, terminal.Area.{column = 0, row = 1, columns = 1, rows = 1})
    if text_at(&shown.whole, 1, 0) != "" {
        return 9
    }
    screen.use_whole(&shown, false)
    if text_at(grid, screen.PROGRAM_ROWS - 2, 0) != "z" {
        return 10
    }

    // The status line is marked only when it changes
    screen.set_status(&shown, "one")
    shown.status_dirty = false
    screen.set_status(&shown, "one")
    if shown.status_dirty {
        return 11
    }
    screen.set_status(&shown, "two")
    if !shown.status_dirty || screen.status_text(&shown).count != 3 {
        return 12
    }
    return 0
}
