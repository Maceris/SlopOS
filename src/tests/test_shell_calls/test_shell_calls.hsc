/**
 * test_shell_calls (decisions/0170, 0172): a program the shell calls through its manifest, taking a connection to the
 * shell's terminal, values of several types, some optional, and a directory beneath the shell's home. It writes what it
 * was given on one line, and ends with 0, or, given the label "fail", with its count. In a pipeline: given an output, it
 * writes count rows, or with an input, each row it reads with its id times ten.
 */
package test_shell_calls

import os from "std"
import strings from "std"
import terminal from "std"
import text_buffer from "std"
import time from "std"
import dir from "std/os/slop_os"
import stream from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"

Speed :: enum {
    Slow,
    Fast,
}

Row :: struct {
    id : u64,
    name : string,
    kind : Speed,
}

main :: fn(session_terminal: os.Channel[protocol.Terminal], count: u64, label: string, loud: bool, speed: Speed?, wait: time.Duration?,
    tags: string[]?, place: os.Channel[dir.Dir]?, input: os.Stream[Row]?, output: os.Sink[Row]?) -> int {
    console := terminal.open(session_terminal) or_return 2
    match input {
        case Some(source) => match output {
            case Some(sink) => return write_rows(sink, input, count, label)
            case None => return 9
        }
        case None => {}
    }
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
    match output {
        case Some(sink) => return write_rows(sink, null, count, label)
        case None => {}
    }
    if label == "fail" {
        return cast[int](count)
    }
    return 0
}

/** Rows written: each one read, its id times ten, or count of them made, named after label. */
write_rows :: fn(sink: os.Sink[Row], input: os.Stream[Row]?, count: u64, label: string) -> int {
    writer := stream.writer_on(sink) or_return 4
    match input {
        case Some(source) => {
            reader := stream.reader_on(source) or_return 5
            loop {
                row := stream.next(&reader) or_break
                row.id *= 10
                if stream.write(&writer, row) is_some {
                    return 6
                }
            }
            stream.close_reader(&reader)
        }
        case None => {
            for i in cast[u64](0)..<count {
                name :: strings.format("%1%2", label, i + 1) or_return 7
                row :: Row.{id = i + 1, name = name, kind = if i % 2 == 0 { Speed.Slow } else { Speed.Fast }}
                if stream.write(&writer, row) is_some {
                    return 6
                }
            }
        }
    }
    if stream.finish(&writer, 0) is_some {
        return 8
    }
    if label == "fail" {
        return cast[int](count)
    }
    return 0
}
