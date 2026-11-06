package shell

import runtime from "base"
import os from "std"
import terminal from "std"

/*
 * History (design/shell.md §6): the lines entered, kept in the shell's data directory, the user's own, so Up finds
 * them again in the next session. One line of the file a line of history, oldest first, at most terminal.MAX_HISTORY.
 */

/** The file history's kept in, in the shell's data directory. */
HISTORY_FILE :: "history"

/**
 * Read history from the shell's data directory into an editor, as its history so far.
 *
 * Nothing's read without a data directory or a history file; an empty line in the file is skipped, and only the last
 * terminal.MAX_HISTORY lines are kept.
 *
 * @param shell The shell, whose data directory is read.
 * @param editor The editor, whose history, empty to start with, gets each line, a copy with context.allocator, as the
 *     editor's own lines are.
 */
load_history :: fn(shell: ptr[mut Shell], editor: ptr[mut terminal.LineEditor]) {
    directory :: shell.data or_return void
    read :: match os.read_entire_file_in(directory, HISTORY_FILE) {
        case Ok(contents) => contents
        case Error(error) => return void
    }
    defer runtime.free_array(bit_cast[u8[]](read))
    bytes :: bit_cast[u8[]](read)
    start : usize = 0
    for i in 0..<bytes.count + 1 {
        if i < bytes.count && bytes[i] != 10 {
            continue
        }
        if i > start && i <= bytes.count {
            if editor.history.count >= terminal.MAX_HISTORY {
                runtime.free_array(bit_cast[u8[]](editor.history[0]))
                runtime.array_remove(&editor.history, 0)
            }
            line : u8[..]
            for byte in bytes[start..<i] {
                runtime.array_add(&line, byte)
            }
            runtime.array_add(&editor.history, terminal.copy_text(line))
            runtime.array_free(&line)
        }
        start = i + 1
    }
}

/**
 * Write an editor's history to the shell's data directory, replacing what the file held, one line a line.
 *
 * A failure isn't reported: the history's still the editor's, and the next line's write tries again.
 *
 * @param shell The shell, whose data directory is written; nothing's written without one.
 * @param editor The editor, whose history is written; it isn't changed.
 */
save_history :: fn(shell: ptr[mut Shell], editor: ptr[terminal.LineEditor]) {
    directory :: shell.data or_return void
    contents : u8[..]
    defer runtime.array_free(&contents)
    for line in editor.history {
        for byte in string_bytes(line) {
            runtime.array_add(&contents, byte)
        }
        runtime.array_add(&contents, cast[u8](10))
    }
    _ = os.write_entire_file_in(directory, HISTORY_FILE, if contents.count > 0 { string_of(&contents[0], contents.count) } else { "" })
}
