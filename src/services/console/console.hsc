/*
 * The console service (decisions/0075, 0077), until M10's terminal service: it shows the lines its clients send it
 * (the console_log protocol) on a serial line, each ended with a carriage return and a line feed, and echoes back
 * each line typed into it, on the serial line or on a keyboard, which it also writes to the debug log. It reaches both
 * through connectors: when a driver is restarted and its connection goes, it dials again, and on a new serial line
 * shows its banner again. A keyboard's keys are typed through a US layout. Without a serial line, it takes lines and
 * shows none.
 */
package console

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import connector from "../../protocols/connector"
import console_log from "../../protocols/console_log"
import input from "../../protocols/input"
import serial from "../../protocols/serial"
import service_kit from "../../service_kit"

// The serial line and the keyboard are bound to the port above the clients
SERIAL_KEY : u64 : 1000
KEYBOARD_KEY : u64 : 1001
LINE_BYTES :: 128
BANNER :: "SlopOS console"
CARRIAGE_RETURN : u8 : 13
LINE_FEED : u8 : 10
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

// USB HID usages a US layout types: the letters, digits, and the rest of the main block
USAGE_A : u16 : 0x04
USAGE_Z : u16 : 0x1d
USAGE_1 : u16 : 0x1e
USAGE_0 : u16 : 0x27
USAGE_ENTER : u16 : 0x28
USAGE_BACKSPACE : u16 : 0x2a
USAGE_SPACE : u16 : 0x2c
USAGE_LEFT_SHIFT : u16 : 0xe1
USAGE_RIGHT_SHIFT : u16 : 0xe5
// From 0x2d (minus) to 0x38 (slash), unshifted then shifted; 0x32, the non-US hash key, types what an ISO layout's does
PUNCTUATION :: "-=[]\\#;'`,./"
PUNCTUATION_SHIFTED :: "_+{}|~:\"~<>?"
DIGITS_SHIFTED :: "!@#$%^&*()"

Console :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // The connectors to the serial line and the keyboard, and the connections they gave, NONE without
    serial_connector : slop_os.Channel,
    keyboard_connector : slop_os.Channel,
    line_end : slop_os.Channel,
    keyboard_end : slop_os.Channel,
    shifted : bool,
    // The line being typed in
    typed : u8[LINE_BYTES],
    typed_count : usize,
}

main :: fn(log: slop_os.DebugLog?, serial_line: os.Channel[connector.Connector]?, keyboard: os.Channel[connector.Connector]?,
    clients: os.Listener[console_log.ConsoleLog]) -> int {
    startup :: slop_os.startup_block()
    console := Console.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), serial_connector = NONE, keyboard_connector = NONE,
        line_end = NONE, keyboard_end = NONE}
    console.port = slop_os.port_create(startup.budget) or_return 2
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, console.port, clients.end) {
        return 3
    }
    match serial_line {
        case Some(found) => console.serial_connector = found.end
        case None => {}
    }
    match keyboard {
        case Some(found) => console.keyboard_connector = found.end
        case None => {}
    }
    dial_keyboard(&console)
    dial_serial(&console)
    runtime.log_info("serving")
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
        take_keys(&console, &into)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(console.port, packets, slop_os.NO_DEADLINE)
    }
}

// A serial line through its connector, if there's one: bound to the port, with the banner shown and a Read held.
dial_serial :: fn(console: ptr[mut Console]) {
    if cast[slop_os.Handle](console.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, console.serial_connector) or_return void
    line :: connector.dial[serial.Serial](console.serial_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(console.port, cast[slop_os.Handle](line.end), signals, SERIAL_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](line.end))
            return void
        }
    }
    console.line_end = line.end
    // Firmware may have left a line unfinished on the same console
    show(console, "")
    show(console, BANNER)
    read_more(console)
}

// A keyboard through its connector, if there's one: bound to the port, with a Read held.
dial_keyboard :: fn(console: ptr[mut Console]) {
    if cast[slop_os.Handle](console.keyboard_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, console.keyboard_connector) or_return void
    keys :: connector.dial[input.Input](console.keyboard_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(console.port, cast[slop_os.Handle](keys.end), signals, KEYBOARD_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](keys.end))
            return void
        }
    }
    console.keyboard_end = keys.end
    read_keys(console)
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

read_keys :: fn(console: ptr[mut Console]) {
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Read(input.MAX_EVENTS)
    _ = input.send_request(console.keyboard_end, console.port, &out)
}

// What's been typed on the serial line: each line, once it ends, logged and echoed back. A line that's gone, dialed again.
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
                console.line_end = NONE
                runtime.log_info("its serial line went; dialing again")
                dial_serial(console)
                // Read the new one until it's empty, since only a read that finds nothing has its next answer wake the port
                if cast[slop_os.Handle](console.line_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
            case _ => continue
        }
        match os.message_of[serial.Response](into)^ {
            case Data(given) => {
                for byte in os.items(into, given) {
                    type_byte(console, byte)
                }
                read_more(console)
            }
            case _ => {}
        }
    }
}

// What the keyboard's pressed, typed as a US layout types it. A keyboard that's gone, dialed again.
take_keys :: fn(console: ptr[mut Console], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](console.keyboard_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match input.receive_response(console.keyboard_end, console.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](console.keyboard_end))
                console.keyboard_end = NONE
                runtime.log_info("its keyboard went; dialing again")
                dial_keyboard(console)
                // As a serial line dialed again
                if cast[slop_os.Handle](console.keyboard_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
            case _ => continue
        }
        match os.message_of[input.Response](into)^ {
            case Events(given) => {
                for event in os.items(into, given) {
                    if input.kind_of(event) == .Key {
                        press(console, event.code, input.is_pressed(event))
                    }
                }
                read_keys(console)
            }
            case _ => {}
        }
    }
}

// A key, down or up: shift remembered, and a key that types something typed.
press :: fn(console: ptr[mut Console], usage: u16, pressed: bool) {
    if usage == USAGE_LEFT_SHIFT || usage == USAGE_RIGHT_SHIFT {
        console.shifted = pressed
        return void
    }
    if !pressed {
        return void
    }
    if usage == USAGE_ENTER {
        type_byte(console, LINE_FEED)
        return void
    }
    if usage == USAGE_BACKSPACE {
        console.typed_count = if console.typed_count > 0 { console.typed_count - 1 } else { cast[usize](0) }
        return void
    }
    character :: character_of(usage, console.shifted)
    if character != 0 {
        type_byte(console, character)
    }
}

// What a key types on a US layout, or 0.
character_of :: fn(usage: u16, shifted: bool) -> u8 {
    if usage >= USAGE_A && usage <= USAGE_Z {
        return (if shifted { cast[u8]('A') } else { cast[u8]('a') }) + cast[u8](usage - USAGE_A)
    }
    if usage >= USAGE_1 && usage <= USAGE_0 {
        index :: cast[usize](usage - USAGE_1)
        if shifted {
            return if index < DIGITS_SHIFTED.count { cast[u8](DIGITS_SHIFTED[index]) } else { cast[u8](0) }
        }
        return if usage == USAGE_0 { cast[u8]('0') } else { cast[u8]('1') + cast[u8](index) }
    }
    if usage == USAGE_SPACE {
        return cast[u8](' ')
    }
    index :: cast[usize](usage) - 0x2d
    if usage >= 0x2d && index < PUNCTUATION.count {
        return cast[u8](if shifted { PUNCTUATION_SHIFTED[index] } else { PUNCTUATION[index] })
    }
    return 0
}

// One byte typed: a line break ends the line, anything else adds to it.
type_byte :: fn(console: ptr[mut Console], byte: u8) {
    if byte == CARRIAGE_RETURN || byte == LINE_FEED {
        finish_line(console)
    }
    else if console.typed_count < console.typed.count {
        console.typed[console.typed_count] = byte
        console.typed_count += 1
    }
}

finish_line :: fn(console: ptr[mut Console]) {
    if console.typed_count == 0 {
        return void
    }
    line :: string_of(&console.typed[0], console.typed_count)
    runtime.log_info("read %", line)
    storage : u8[LINE_BYTES + 8]
    echo := text_buffer.make(storage)
    text_buffer.append(&echo, "echo: ")
    text_buffer.append(&echo, line)
    show(console, text_buffer.as_string(&echo))
    console.typed_count = 0
}
