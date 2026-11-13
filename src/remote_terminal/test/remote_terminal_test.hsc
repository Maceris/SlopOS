/*
 * remote_terminal's tests, a test program (tools/unit_tests.py): text written as VT bytes, made safe, line breaks as CR
 * LF; the line being typed drawn after the output and taken away before more; a whole screen's moves and clears at the
 * client's size. In what's expected, ~ stands for ESC, ^ for CR and | for LF.
 */
package remote_terminal_test

import testing from "std"
import text_buffer from "std"
import terminal from "std/os/slop_os"
import remote_terminal from ".."

/** Whether what's in a buffer is the text expected, ~ ESC, ^ CR and | LF in it; if not, notes what it is. */
is :: fn(t: ptr[mut testing.T], out: ptr[text_buffer.TextBuffer], expected: string) -> bool {
    got :: string_bytes(text_buffer.as_string(out))
    wanted :: string_bytes(expected)
    same := got.count == wanted.count
    for byte, i in wanted {
        real :: if byte == 0x7e { cast[u8](0x1b) } else if byte == 0x5e { cast[u8](0x0d) } else if byte == 0x7c { cast[u8](0x0a) } else { byte }
        if i < got.count && got[i] != real {
            same = false
        }
    }
    if !same {
        shown : u8[256]
        for byte, i in got {
            if i < shown.count {
                shown[i] = if byte == 0x1b { cast[u8](0x7e) } else if byte == 0x0d { cast[u8](0x5e) } else if byte == 0x0a { cast[u8](0x7c) } else { byte }
            }
        }
        if got.count > 0 && got.count <= shown.count {
            testing.note(t, string_of(&shown[0], got.count))
        }
    }
    return same
}

writes_text_safely #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    term := remote_terminal.make(80, 24)
    storage : u8[256]
    out := text_buffer.make(storage)
    text : u8[9]
    for byte, i in string_bytes("hi|ab~[J") {
        if i < text.count {
            text[i] = if byte == 0x7c { cast[u8](0x0a) } else if byte == 0x7e { cast[u8](0x1b) } else { byte }
        }
    }
    remote_terminal.write(&term, text[0..<8], terminal.Run.[], u8.[], &out)
    got :: string_bytes(text_buffer.as_string(&out))
    testing.expect(t, got.count > 3 && got[0] == 0x68 && got[2] == 0x0d && got[3] == 0x0a, "the text, its line break as CR LF")
    for byte in got {
        if byte == 0x1b {
            testing.fail(t, "a program's ESC reaches the client")
            break
        }
    }
    testing.expect(t, term.column >= 4, "the output's column after ab and the ESC shown")
    return .Ok
}

draws_the_line_being_typed_after_the_output #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    term := remote_terminal.make(80, 24)
    storage : u8[256]
    out := text_buffer.make(storage)
    remote_terminal.set_input(&term, string_bytes("> ls"), 4, &out)
    testing.expect(t, is(t, &out, "> ls~[5G"), "at the start of an empty row, the cursor after it")
    second : u8[256]
    out = text_buffer.make(second)
    remote_terminal.write(&term, string_bytes("out"), terminal.Run.[], u8.[], &out)
    testing.expect(t, is(t, &out, "^~[J~[1Gout^|> ls~[5G"), "taken away, the output written, and drawn again on the next row")
    third : u8[256]
    out = text_buffer.make(third)
    remote_terminal.drop_input(&term, &out)
    testing.expect(t, is(t, &out, "^~[J~[A~[4G"), "taken away, the cursor back after the output")
    return .Ok
}

draws_a_whole_screen #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    term := remote_terminal.make(100, 30)
    testing.expect_eq(t, remote_terminal.features(&term).columns, cast[u16](100), "the client's width")
    storage : u8[256]
    out := text_buffer.make(storage)
    remote_terminal.use_screen(&term, true, &out)
    second : u8[256]
    out = text_buffer.make(second)
    remote_terminal.move_cursor(&term, terminal.Position.{column = 5, row = 2}, &out)
    testing.expect(t, is(t, &out, "~[3;6H"), "a move anywhere")
    third : u8[256]
    out = text_buffer.make(third)
    remote_terminal.clear(&term, terminal.Area.{column = 98, row = 29, columns = 10, rows = 10}, &out)
    testing.expect(t, is(t, &out, "~[30;99H~[K"), "a clear past the edge cut at it")
    return .Ok
}
