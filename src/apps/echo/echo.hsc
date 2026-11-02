/*
 * echo (decisions/0136, 0150): a session's first program until the shell, which the session manager starts with the
 * session's terminal connection, and its home volume's root once someone's logged in; it says how many entries the home
 * directory has, then how numbers and dates look in its session's locale (decisions/0152). It reads
 * the terminal's typed input, keeps the line being typed as the terminal's input line, below what anything writes
 * (decisions/0147), takes Backspace back a grapheme cluster, and answers each line with the line itself and "echo: "
 * and the line, which it also logs; Ctrl-C drops the line, shown with ^C after it. That's what the console service did
 * itself before the terminal service left line editing to programs. Its session ends with its terminal connection,
 * and so does it. Asked to stop on its lifecycle channel (decisions/0139), it ends with 0.
 */
package echo

import runtime from "base"
import os from "std"
import text_buffer from "std"
import unicode from "std"
import locale from "std"
import time from "std"
import slop_os from "std/os"
import terminal from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import dir from "std/os/slop_os"

LINE_BYTES :: 256
// The port key a stop's asked for on, above the terminal's binding
STOP_KEY : u64 : 1
USAGE_ENTER : u16 : 0x28
USAGE_BACKSPACE : u16 : 0x2a

Echo :: struct {
    end : slop_os.Channel,
    port : slop_os.Port,
    line : u8[LINE_BYTES],
    count : usize,
}

main :: fn(log: slop_os.DebugLog?, session_terminal: os.Channel[terminal.Terminal], home: os.Channel[dir.Dir]?) -> int {
    echo := Echo.{end = session_terminal.end}
    echo.port = os.port_for(slop_os.startup_block().budget, echo.end) or_return 2
    match home {
        case Some(root) => greet(&echo, root)
        case None => {}
    }
    show_locale(&echo)
    if !terminal.read(echo.end, echo.port) {
        return 2
    }
    _ = lifecycle.on_stop(echo.port, STOP_KEY)
    into := os.Incoming.{}
    loop {
        match terminal.receive_response(echo.end, echo.port, &into, false) {
            case Received => {}
            case Empty => {
                if lifecycle.stop_requested() {
                    runtime.log_info("stopping, as asked")
                    return 0
                }
                packets : slop_os.Packet[4]
                _ = slop_os.port_wait(echo.port, packets, slop_os.NO_DEADLINE)
                continue
            }
            case Failed(error) => {
                runtime.log_info("its terminal went")
                return 3
            }
            case _ => continue
        }
        match os.message_of[terminal.Response](&into)^ {
            case Input(given) => {
                text :: os.items(&into, given.text)
                for event in os.items(&into, given.events) {
                    if !take(&echo, event, text) {
                        return 0
                    }
                }
                _ = terminal.read(echo.end, echo.port)
            }
            case _ => {}
        }
    }
}

// A number and a date as the session's locale writes them, the last day of 2026 for the date.
show_locale :: fn(echo: ptr[mut Echo]) {
    storage : u8[96]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "Numbers here look like ")
    locale.append_fixed(&line, 123456789, 2)
    text_buffer.append(&line, ", and dates like ")
    locale.append_date(&line, time.DateTime.{year = 2026, month = 12, day = 31})
    text_buffer.append(&line, ".")
    _ = terminal.write_line(echo.end, echo.port, text_buffer.as_string(&line))
    current :: locale.current()
    runtime.log_info("its locale is %", if current.name.count > 0 { current.name } else { "neutral" })
}

// How many entries the home directory has, said on the terminal and in the log.
greet :: fn(echo: ptr[mut Echo], root: os.Channel[dir.Dir]) {
    directory, error :: os.directory_on(root.end)
    if error != null {
        return void
    }
    defer os.close_directory(directory)
    count := cast[usize](0)
    match os.list_directory_in(directory, "") {
        case Ok(listing) => {
            count = listing.count
            os.free_directory_listing(listing)
        }
        case Error(failure) => return void
    }
    storage : u8[64]
    line := text_buffer.make(storage)
    text_buffer.append(&line, "Your home directory has ")
    text_buffer.append_unsigned(&line, cast[u64](count))
    text_buffer.append(&line, if count == 1 { " entry." } else { " entries." })
    _ = terminal.write_line(echo.end, echo.port, text_buffer.as_string(&line))
    runtime.log_info("home has % %", count, if count == 1 { "entry" } else { "entries" })
}

// One event: whether to go on, which a hang-up ends.
take :: fn(echo: ptr[mut Echo], event: terminal.Event, text: u8[]) -> bool {
    kind :: terminal.kind_of(event) or_return true
    match kind {
        case .HangUp => return false
        case .Interrupt => {
            _ = terminal.input_line(echo.end, echo.port, echo.line[0..<0], 0)
            if echo.count <= echo.line.count {
                show(echo, echo.line[0..<echo.count])
            }
            _ = terminal.write_line(echo.end, echo.port, "^C")
            echo.count = 0
        }
        case .Key => {
            if event.code == USAGE_ENTER {
                finish_line(echo)
            }
            else if event.code == USAGE_BACKSPACE {
                erase(echo)
            }
            else {
                add(echo, text_of(event, text))
            }
        }
        case .Paste => add(echo, text_of(event, text))
        case _ => {}
    }
    return true
}

text_of :: fn(event: terminal.Event, text: u8[]) -> u8[] {
    start :: cast[usize](event.text_start)
    end :: start + cast[usize](event.text_bytes)
    return if start <= end && end <= text.count { text[start..<end] } else { text[0..<0] }
}

// Typed text, added to the line and shown; a line break in it, from a paste, ends the line.
add :: fn(echo: ptr[mut Echo], typed: u8[]) {
    for byte in typed {
        if byte == 0x0a || byte == 0x0d {
            finish_line(echo)
        }
        else if echo.count < echo.line.count {
            echo.line[echo.count] = byte
            echo.count += 1
        }
    }
    show_line(echo)
}

// The line being typed, as the terminal's input line, the cursor at its end.
show_line :: fn(echo: ptr[mut Echo]) {
    if echo.count <= echo.line.count {
        _ = terminal.input_line(echo.end, echo.port, echo.line[0..<echo.count], echo.count)
    }
}

// The last grapheme cluster taken off the line, and the line drawn again.
erase :: fn(echo: ptr[mut Echo]) {
    if echo.count == 0 || echo.count > echo.line.count {
        return void
    }
    line :: echo.line[0..<echo.count]
    last : usize = 0
    at : usize = 0
    loop {
        end :: unicode.grapheme_end(line, at)
        if end <= at {
            break
        }
        last = at
        at = end
    }
    while at < echo.count
    echo.count = last
    show_line(echo)
}

show :: fn(echo: ptr[mut Echo], bytes: u8[]) {
    if bytes.count > 0 {
        _ = terminal.write(echo.end, echo.port, string_of(&bytes[0], bytes.count))
    }
}

// The line done: taken off the input line, and written above it, as typed, then answered.
finish_line :: fn(echo: ptr[mut Echo]) {
    _ = terminal.input_line(echo.end, echo.port, echo.line[0..<0], 0)
    if echo.count <= echo.line.count {
        show(echo, echo.line[0..<echo.count])
    }
    _ = terminal.write(echo.end, echo.port, "\n")
    if echo.count == 0 || echo.count > echo.line.count {
        echo.count = 0
        return void
    }
    line :: string_of(&echo.line[0], echo.count)
    runtime.log_info("read %", line)
    storage : u8[LINE_BYTES + 8]
    answer := text_buffer.make(storage)
    text_buffer.append(&answer, "echo: ")
    text_buffer.append(&answer, line)
    _ = terminal.write_line(echo.end, echo.port, text_buffer.as_string(&answer))
    echo.count = 0
}
