/*
 * The console service (decisions/0075), until M10's terminal service: given a serial line, it shows the lines its
 * clients send it there (the console_log protocol), each ended with a carriage return and a line feed, and echoes back
 * each line typed into it, which it also writes to the debug log. Without a serial line, it takes lines and shows
 * none.
 */
package console

import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import log_line from "../../log_line"
import console_log from "../../protocols/console_log"
import serial from "../../protocols/serial"
import service_kit from "../../service_kit"

// The serial line is bound to the port above the clients
SERIAL_KEY : u64 : 1000
LINE_BYTES :: 128
BANNER :: "SlopOS console"
CARRIAGE_RETURN : u8 : 13
LINE_FEED : u8 : 10

Console :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // The serial line, or NO_HANDLE without one
    line_end : slop_os.Channel,
    // The line being typed in
    typed : u8[LINE_BYTES],
    typed_count : usize,
}

main :: fn(log: slop_os.DebugLog?, serial_line: os.Channel[serial.Serial]?, clients: os.Listener[console_log.ConsoleLog]) -> int {
    block :: slop_os.startup_block()
    console := Console.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), line_end = cast[slop_os.Channel](slop_os.NO_HANDLE)}
    console.port = slop_os.port_create(block.budget) or_return 2
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, console.port, clients.end) {
        return 3
    }
    match serial_line {
        case Some(line) => {
            signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
            slop_os.port_bind(console.port, cast[slop_os.Handle](line.end), signals, SERIAL_KEY, .Persistent) or_return 4
            console.line_end = line.end
            // Firmware may have left a line unfinished on the same console
            show(&console, "")
            show(&console, BANNER)
            read_more(&console)
        }
        case None => {}
    }
    log_line.write(console.log, "console: serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(&console, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        take_typed(&console, &into)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(console.port, packets, slop_os.NO_DEADLINE)
    }
}

serve :: fn(console: ptr[mut Console], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match console_log.receive_request(end, console.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = console_log.answer_unsupported(end, console.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(connected, index)
                return void
            }
            case _ => continue
        }
        match os.message_of[console_log.Request](into)^ {
            case Line(text) => {
                bytes :: os.items(into, text)
                show(console, if bytes.count == 0 { "" } else { string_of(&bytes[0], bytes.count) })
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, console.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

// A line on the serial line, with its line break; its Written comes back later, and isn't waited for.
show :: fn(console: ptr[mut Console], text: string) {
    if cast[slop_os.Handle](console.line_end) == slop_os.NO_HANDLE {
        return void
    }
    out := os.Outgoing.{}
    request :: os.begin[serial.Request](&out)
    bytes : u8[serial.MAX_BYTES]
    // The text, as much as leaves room for the line break, then the line break
    taken :: if text.count < bytes.count - 2 { text.count } else { bytes.count - 2 }
    for character, i in text {
        if i < taken && i < bytes.count {
            bytes[i] = cast[u8](character)
        }
    }
    after :: taken + 1
    if taken < bytes.count && after < bytes.count {
        bytes[taken] = CARRIAGE_RETURN
        bytes[after] = LINE_FEED
    }
    request^ = .Write(os.append(&out, view_of(&bytes[0], taken + 2)))
    _ = serial.send_request(console.line_end, console.port, &out)
}

// Another Read, held by the driver until something's typed.
read_more :: fn(console: ptr[mut Console]) {
    out := os.Outgoing.{}
    request :: os.begin[serial.Request](&out)
    request^ = .Read(LINE_BYTES)
    _ = serial.send_request(console.line_end, console.port, &out)
}

// What's been typed: each line, once it ends, logged and echoed back.
take_typed :: fn(console: ptr[mut Console], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](console.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match serial.receive_response(console.line_end, console.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](console.line_end))
                console.line_end = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return void
            }
            case _ => continue
        }
        match os.message_of[serial.Response](into)^ {
            case Data(given) => {
                for byte in os.items(into, given) {
                    if byte == CARRIAGE_RETURN || byte == LINE_FEED {
                        finish_line(console)
                    }
                    else if console.typed_count < console.typed.count {
                        console.typed[console.typed_count] = byte
                        console.typed_count += 1
                    }
                }
                read_more(console)
            }
            case _ => {}
        }
    }
}

finish_line :: fn(console: ptr[mut Console]) {
    if console.typed_count == 0 {
        return void
    }
    line :: string_of(&console.typed[0], console.typed_count)
    log_line.write(console.log, "console: read %", line)
    storage : u8[LINE_BYTES + 8]
    echo := text_buffer.make(storage)
    text_buffer.append(&echo, "echo: ")
    text_buffer.append(&echo, line)
    show(console, text_buffer.as_string(&echo))
    console.typed_count = 0
}
