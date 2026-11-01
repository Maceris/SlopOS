/*
 * echo (decisions/0136): the console's first reader, until 10c's sessions start a session's own first program. It reads
 * the terminal's typed input, shows each key's text as it's typed, takes Backspace back a grapheme cluster, and answers
 * each line with "echo: " and the line, which it also logs; Ctrl-C drops the line. That's what the console service did
 * itself before the terminal service left line editing to programs. It reaches the terminal service through a
 * connector, dialed again if the service is started again. Asked to stop on its lifecycle channel (decisions/0139), it
 * ends with 0.
 */
package echo

import runtime from "base"
import os from "std"
import text_buffer from "std"
import unicode from "std"
import slop_os from "std/os"
import terminal from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import connector from "../../protocols/connector"

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

main :: fn(console: os.Channel[connector.Connector]) -> int {
    echo := Echo.{}
    if !dial(&echo, console.end) {
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
                // The terminal service was started again: dialed again, the line kept
                _ = slop_os.handle_close(cast[slop_os.Handle](echo.end))
                if !dial(&echo, console.end) {
                    return 3
                }
                continue
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

// A connection to the terminal through its connector, bound to a port, with a Read held: whether it worked.
dial :: fn(echo: ptr[mut Echo], dialing: slop_os.Channel) -> bool {
    dial_port :: os.port_for(slop_os.startup_block().budget, dialing) or_return false
    connection :: connector.dial[terminal.Terminal](dialing, dial_port) or_return false
    echo.end = connection.end
    echo.port = os.port_for(slop_os.startup_block().budget, connection.end) or_return false
    return terminal.read(echo.end, echo.port)
}

// One event: whether to go on, which a hang-up ends.
take :: fn(echo: ptr[mut Echo], event: terminal.Event, text: u8[]) -> bool {
    kind :: terminal.kind_of(event) or_return true
    match kind {
        case .HangUp => return false
        case .Interrupt => {
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
            shown : u8[1]
            shown[0] = byte
            show(echo, shown[0..<1])
        }
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
    _ = terminal.send(echo.end, echo.port, .Clear(terminal.Area.{columns = 0xffff, rows = 1}))
    if last <= line.count {
        show(echo, line[0..<last])
    }
    echo.count = last
}

show :: fn(echo: ptr[mut Echo], bytes: u8[]) {
    if bytes.count > 0 {
        _ = terminal.write(echo.end, echo.port, string_of(&bytes[0], bytes.count))
    }
}

finish_line :: fn(echo: ptr[mut Echo]) {
    _ = terminal.write(echo.end, echo.port, "\n")
    if echo.count == 0 || echo.count > echo.line.count {
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
