/**
 * test_shell_calls (decisions/0170, 0172, 0174): a program the shell calls through its manifest, taking a connection to
 * the shell's terminal, values of several types, some optional, and a directory beneath the shell's home. It writes
 * what it was given on one line, and ends with 0, or, given the label "fail", with its count. In a pipeline: given an
 * output, it writes count rows, or with an input, each row it reads with its id times ten. Given a time to sleep, it
 * sleeps first, saying its progress, and ends early when it's asked to stop, unless it's stubborn.
 */
package test_shell_calls

import os from "std"
import strings from "std"
import terminal from "std"
import text_buffer from "std"
import time from "std"
import slop_os from "std/os"
import lifecycle from "std/os/slop_os"
import dir from "std/os/slop_os"
import stream from "std/os/slop_os"
import terminal as protocol from "std/os/slop_os"

/** A choice the shell passes by name. */
Speed :: enum {
    /** Slow; the odd rows' kind. */
    Slow,
    /** Fast; the even rows' kind. */
    Fast,
}

/** A row the program writes to its output, or reads from its input, in a pipeline. */
Row :: struct {
    /** The row's number, from 1 for a row made; times ten for a row read and written back. */
    id : u64,
    /** The row's name: the label then its id, for a row made. */
    name : string,
    /** Slow for a row of odd id, Fast for an even one, for a row made. */
    kind : Speed,
}

/**
 * Write what the shell gave on one line of the terminal, or, in a pipeline, write rows.
 *
 * @param session_terminal A connection to the shell's terminal, which the line is written on. Without it, as in the
 *     background, no line is written.
 * @param count A number, written on the line; with an output and no input, how many rows are made; with the label
 *     "fail", the exit code.
 * @param label A word, written on the line, and starting each row's name made; "fail" makes the program end with
 *     count instead of 0.
 * @param loud A flag, written on the line.
 * @param speed A choice, written on the line by name, or "none" without it.
 * @param wait A duration, written on the line in milliseconds, or "none" without it.
 * @param tags Words, written on the line joined by +, or "none" without them.
 * @param place A directory beneath the shell's home, written on the line only as whether it was given.
 * @param input Rows to read, in a pipeline, each written to output with its id times ten; given without an output,
 *     the program ends with 9. Without it, nothing is read.
 * @param output Where rows go, in a pipeline: those read from input, or, without one, count rows made after the line
 *     is written. Without it, no rows are written.
 * @param sleep How long to sleep before anything else, in ten steps, saying its progress after each. Asked to stop
 *     meanwhile, it ends at once. Without it, it doesn't sleep.
 * @param stubborn Whether to keep sleeping when it's asked to stop, so it has to be killed.
 * @return 0, or count with the label "fail", once the line or the rows are written. 2 if the terminal couldn't be
 *     opened; 3 if the line couldn't be made; 9 if there's an input but no output; 10 if it was asked to stop while it
 *     slept; otherwise what write_rows gives.
 */
main :: fn(session_terminal: os.Channel[protocol.Terminal]?, count: u64, label: string, loud: bool, speed: Speed?, wait: time.Duration?,
    tags: string[]?, place: os.Channel[dir.Dir]?, input: os.Stream[Row]?, output: os.Sink[Row]?, sleep: time.Duration?, stubborn: bool) -> int {
    match sleep {
        case Some(given) => {
            if !slept(given.seconds * 1000000000 + cast[i64](given.nanos), stubborn) {
                return 10
            }
        }
        case None => {}
    }
    console : terminal.Terminal? = null
    match session_terminal {
        case Some(given) => console = terminal.open(given) or_return 2
        case None => {}
    }
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
    match console {
        case Some(opened) => {
            shown := opened
            _ = terminal.write_line(&shown, line)
        }
        case None => {}
    }
    match output {
        case Some(sink) => return write_rows(sink, null, count, label)
        case None => {}
    }
    if label == "fail" {
        return cast[int](count)
    }
    return 0
}

/**
 * Sleep in ten steps, saying its progress on its lifecycle channel after each (lifecycle.report_progress).
 *
 * @param nanoseconds How long, in all; 0 or less doesn't sleep, but still says it's done.
 * @param stubborn Whether to sleep on when it's asked to stop; if not, a stop wakes it and ends the sleep.
 * @return True once it's slept; false if it was asked to stop first, and wasn't stubborn.
 */
slept :: fn(nanoseconds: i64, stubborn: bool) -> bool {
    port :: slop_os.port_create(slop_os.startup_block().budget) or_return true
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    if !stubborn {
        _ = lifecycle.on_stop(port, 1)
    }
    step :: if nanoseconds > 0 { cast[u64](nanoseconds) / 10 } else { cast[u64](0) }
    for i in cast[u64](0)..<10 {
        deadline :: (slop_os.clock_monotonic() or_else 0) + step
        loop {
            if !stubborn && lifecycle.stop_requested() {
                return false
            }
            if (slop_os.clock_monotonic() or_else 0) >= deadline {
                break
            }
            packets : slop_os.Packet[1]
            _ = slop_os.port_wait(port, packets, deadline)
        }
        _ = lifecycle.report_progress(i + 1, 10)
    }
    return true
}

/**
 * Write rows to an output: each one read from an input, its id times ten, or count of them made, named after label.
 *
 * @param sink The output, which the rows are written to and which is ended with status 0.
 * @param input The rows to read; null makes count rows instead.
 * @param count How many rows to make, without an input.
 * @param label What each made row's name starts with; "fail" makes the result count instead of 0.
 * @return 0, or count with the label "fail", once every row is written and the output ended. 4 if the output, or 5
 *     the input, couldn't be opened; 6 if a row couldn't be written; 7 if a row's name couldn't be made; 8 if the
 *     output couldn't be ended.
 */
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
