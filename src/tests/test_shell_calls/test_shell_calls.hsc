/*
 * test_shell_calls (decisions/0170): a program the shell calls through its manifest, taking a connection to the shell's
 * terminal, values of several types, some optional, and a directory beneath the shell's home. It writes what it was
 * given on one line, and ends with 0, or, given the label "fail", with its count.
 */
package test_shell_calls

import os from "std"
import strings from "std"
import terminal from "std"
import text_buffer from "std"
import time from "std"
import dir from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"

Speed :: enum {
    Slow,
    Fast,
}

main :: fn(session_terminal: os.Channel[protocol.Terminal], count: u64, label: string, loud: bool, speed: Speed?, wait: time.Duration?,
    tags: string[]?, place: os.Channel[dir.Dir]?) -> int {
    console := terminal.open(session_terminal) or_return 2
    speed_text :: match speed {
        case Some(given) => strings.format("%", given) or_else "?"
        case None => "none"
    }
    wait_text :: match wait {
        case Some(given) => strings.format("%ms", given.seconds * 1000 + cast[i64](given.nanos / 1000000)) or_else "?"
        case None => "none"
    }
    tags_text := "none"
    match tags {
        case Some(given) => {
            storage : u8[256]
            out := text_buffer.make(storage)
            for tag, i in given {
                if i > 0 {
                    text_buffer.append(&out, "+")
                }
                text_buffer.append(&out, tag)
            }
            tags_text = strings.clone(text_buffer.as_string(&out)) or_else "?"
        }
        case None => {}
    }
    place_text :: match place {
        case Some(given) => "a directory"
        case None => "none"
    }
    line :: strings.format("called with %, %, loud %, speed %, wait %, tags %, place %", label, count, loud, speed_text, wait_text, tags_text,
        place_text) or_return 3
    _ = terminal.write_line(&console, line)
    if label == "fail" {
        return cast[int](count)
    }
    return 0
}
