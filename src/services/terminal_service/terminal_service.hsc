/*
 * The terminal service (decisions/0136, design/console-and-sessions.md §2), which replaced the console service of
 * decisions/0075 and 0077. It serves the console's terminal over the terminal protocol: what its clients write is shown
 * on the first serial line through the VT adapter, a grapheme cluster at a time, made safe (safe_text) so text can't
 * become a control sequence; and what's typed, on the serial line or the first keyboard, becomes typed input for the
 * client that reads it first. A keyboard's keys are typed through a US layout until the input service owns keyboards
 * (10a2). Both are reached through connectors, dialed again when they go, with the banner shown on each new serial line.
 * Without a serial line it takes output and shows none.
 */
package terminal_service

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import text_buffer from "std"
import unicode from "std"
import terminal from "std/os/slop_os"
import connector from "../../protocols/connector"
import input from "../../protocols/input"
import serial from "../../protocols/serial"
import service_kit from "../../libraries/service_kit"
import safe_text from "../../safe_text"
import vt from "../../vt"

// The serial line and the keyboard are bound to the port above the clients
SERIAL_KEY : u64 : 1000
KEYBOARD_KEY : u64 : 1001
BANNER :: "SlopOS console"
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

// The console's size, until the serial line can say its own
COLUMNS : u16 : 80
ROWS : u16 : 24
TAB_STOP : u16 : 8

// Output waiting for the serial line, and how many Writes may be in flight on it, which its ring holds
OUTPUT_BYTES :: 16384
MAX_IN_FLIGHT : u32 : 2

// USB HID usages a US layout types: the letters, digits, and the rest of the main block
USAGE_A : u16 : 0x04
USAGE_C : u16 : 0x06
USAGE_Z : u16 : 0x1d
USAGE_1 : u16 : 0x1e
USAGE_0 : u16 : 0x27
USAGE_ENTER : u16 : 0x28
USAGE_TAB : u16 : 0x2b
USAGE_SPACE : u16 : 0x2c
USAGE_LEFT_CONTROL : u16 : 0xe0
USAGE_LEFT_SHIFT : u16 : 0xe1
USAGE_LEFT_ALT : u16 : 0xe2
USAGE_RIGHT_CONTROL : u16 : 0xe4
USAGE_RIGHT_SHIFT : u16 : 0xe5
USAGE_RIGHT_ALT : u16 : 0xe6
// From 0x2d (minus) to 0x38 (slash), unshifted then shifted; 0x32, the non-US hash key, types what an ISO layout's does
PUNCTUATION :: "-=[]\\#;'`,./"
PUNCTUATION_SHIFTED :: "_+{}|~:\"~<>?"
DIGITS_SHIFTED :: "!@#$%^&*()"

Service :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // The connectors to the serial line and the keyboard, and the connections they gave, NONE without
    serial_connector : slop_os.Channel,
    keyboard_connector : slop_os.Channel,
    line_end : slop_os.Channel,
    keyboard_end : slop_os.Channel,
    // What's waiting to be sent on the serial line: a ring, from output_start
    output : u8[OUTPUT_BYTES],
    output_start : usize,
    output_count : usize,
    in_flight : u32,
    // Where the cursor is on the line being written, and whether a program has the screen to itself
    column : u16,
    whole_screen : bool,
    // Input waiting for the owner: the client that read first, and how many events its Read held asks for
    decoder : vt.Decoder,
    decoded : vt.Decoded,
    owner : usize?,
    held : u32,
    // The keyboard's modifiers held down
    modifiers : u8,
}

main :: fn(log: slop_os.DebugLog?, serial_line: os.Channel[connector.Connector]?, keyboard: os.Channel[connector.Connector]?,
    clients: os.Listener[terminal.Terminal]) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    service.serial_connector = NONE
    service.keyboard_connector = NONE
    service.line_end = NONE
    service.keyboard_end = NONE
    service.port = slop_os.port_create(startup.budget) or_return 2
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, service.port, clients.end) {
        return 3
    }
    match serial_line {
        case Some(found) => service.serial_connector = found.end
        case None => {}
    }
    match keyboard {
        case Some(found) => service.keyboard_connector = found.end
        case None => {}
    }
    dial_keyboard(service)
    dial_serial(service)
    runtime.log_info("serving")
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(service, &connected, i, &into)
            i += 1
        }
        while i < connected.count
        take_serial(service, &into)
        take_keys(service, &into)
        deliver(service, &connected)
        pump(service)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

// A serial line through its connector, if there's one: bound to the port, with the banner shown and a Read held.
dial_serial :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.serial_connector) or_return void
    line :: connector.dial[serial.Serial](service.serial_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](line.end), signals, SERIAL_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](line.end))
            return void
        }
    }
    service.line_end = line.end
    service.in_flight = 0
    // Firmware may have left a line unfinished on the same console
    storage : u8[64]
    shown := text_buffer.make(storage)
    vt.append_line_break(&shown)
    text_buffer.append(&shown, BANNER)
    vt.append_line_break(&shown)
    emit(service, string_bytes(text_buffer.as_string(&shown)))
    service.column = 0
    read_more(service)
    pump(service)
}

// A keyboard through its connector, if there's one: bound to the port, with a Read held.
dial_keyboard :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.keyboard_connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, service.keyboard_connector) or_return void
    keys :: connector.dial[input.Input](service.keyboard_connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](keys.end), signals, KEYBOARD_KEY, .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](keys.end))
            return void
        }
    }
    service.keyboard_end = keys.end
    service.modifiers = 0
    read_keys(service)
}

serve :: fn(service: ptr[mut Service], connected: ptr[mut service_kit.Clients], index: usize, into: ptr[mut os.Incoming]) {
    if index >= connected.ends.count {
        return void
    }
    end :: connected.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match terminal.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = terminal.answer_unsupported(end, service.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(connected, index)
                match service.owner {
                    case Some(owner) => {
                        if owner == index {
                            service.owner = null
                            service.held = 0
                        }
                    }
                    case None => {}
                }
                return void
            }
            case _ => continue
        }
        match os.message_of[terminal.Request](into)^ {
            case Write(text) => write(service, into, text)
            case MoveCursor(position) => move_cursor(service, position)
            case ShowCursor(shown) => {
                storage : u8[16]
                out := text_buffer.make(storage)
                vt.append_cursor_shown(&out, shown)
                emit(service, string_bytes(text_buffer.as_string(&out)))
            }
            case Clear(area) => clear(service, area)
            case Scroll(scrolled) => scroll(service, scrolled)
            case Screen(whole) => use_screen(service, whole)
            case Bell => {
                storage : u8[4]
                out := text_buffer.make(storage)
                vt.append_bell(&out)
                emit(service, string_bytes(text_buffer.as_string(&out)))
            }
            case Describe => {
                out := os.Outgoing.{}
                response :: os.begin[terminal.Response](&out)
                response^ = .Described(terminal.Features.{columns = COLUMNS, rows = ROWS, colors = .Rgb,
                    attributes = terminal.BOLD | terminal.DIM | terminal.ITALIC | terminal.UNDERLINE | terminal.INVERSE | terminal.STRIKETHROUGH,
                    links = true, unicode = 17 * 256})
                _ = terminal.send_response(end, service.port, &out)
            }
            case Read(most) => {
                // The first client to read owns the input, until it goes (sessions decide this in 10c)
                owned :: match service.owner {
                    case Some(owner) => owner == index
                    case None => true
                }
                if owned {
                    service.owner = index
                    service.held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(connected, service.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

// Whether two styles are the same.
same_style :: fn(a: terminal.Style, b: terminal.Style) -> bool {
    return a.attributes == b.attributes && same_color(a.foreground, b.foreground) && same_color(a.background, b.background)
}

same_color :: fn(a: terminal.Color, b: terminal.Color) -> bool {
    return a.kind == b.kind && a.index == b.index && a.red == b.red && a.green == b.green && a.blue == b.blue
}

/*
 * A Write: its text a grapheme cluster at a time, each in its run's style, made safe; line breaks as CR LF, tabs as
 * spaces to the next stop. The style and any link are ended with it, so another client's text starts plain.
 */
write :: fn(service: ptr[mut Service], into: ptr[os.Incoming], text: terminal.Text) {
    bytes :: os.items(into, text.text)
    runs :: os.items(into, text.runs)
    links :: os.items(into, text.links)
    plain :: terminal.Style.{}
    current := plain
    linked := false
    run_index : usize = 0
    run_end : usize = if runs.count > 0 { cast[usize](runs[0].bytes) } else { bytes.count }
    at : usize = 0
    loop {
        if at >= bytes.count {
            break
        }
        end :: unicode.grapheme_end(bytes, at)
        if end <= at || end > bytes.count {
            break
        }
        // The run this cluster starts in; past the last, the last's style
        loop {
            if at < run_end || run_index + 1 >= runs.count {
                break
            }
            run_index += 1
            if run_index < runs.count {
                run_end += cast[usize](runs[run_index].bytes)
            }
        }
        storage : u8[160]
        out := text_buffer.make(storage)
        if run_index < runs.count {
            run :: runs[run_index]
            if !same_style(run.style, current) {
                vt.append_style(&out, run.style)
                current = run.style
            }
            // A link starts or stops with its run
            wanted :: run.link_bytes > 0
            if wanted || linked {
                start :: cast[usize](run.link_start)
                stop :: start + cast[usize](run.link_bytes)
                if wanted && stop <= links.count && start <= stop {
                    vt.append_link(&out, links[start..<stop])
                }
                else if linked {
                    vt.append_link(&out, links[0..<0])
                }
                linked = wanted
            }
        }
        if safe_text.is_line_break(bytes, at, end) {
            vt.append_line_break(&out)
            service.column = 0
        }
        else if safe_text.is_tab(bytes, at, end) {
            loop {
                text_buffer.append_byte(&out, cast[u8](' '))
                service.column += 1
            }
            while service.column % TAB_STOP != 0 && service.column < COLUMNS
        }
        else {
            shown := safe_text.Shown.{}
            safe_text.show(bytes, at, end, &shown)
            if shown.count <= shown.bytes.count {
                text_buffer.append(&out, string_of(&shown.bytes[0], shown.count))
            }
            // Where the cursor goes, as the console wraps
            columns :: cast[u16](shown.columns)
            service.column = if service.column + columns > COLUMNS { columns } else { service.column + columns }
        }
        emit(service, string_bytes(text_buffer.as_string(&out)))
        at = end
    }
    storage : u8[32]
    out := text_buffer.make(storage)
    if linked {
        vt.append_link(&out, links[0..<0])
    }
    if !same_style(current, plain) {
        vt.append_style(&out, plain)
    }
    emit(service, string_bytes(text_buffer.as_string(&out)))
}

// The cursor: anywhere on a whole screen; on lines, only along the line being written.
move_cursor :: fn(service: ptr[mut Service], position: terminal.Position) {
    storage : u8[32]
    out := text_buffer.make(storage)
    column :: if position.column < COLUMNS { position.column } else { COLUMNS - 1 }
    if service.whole_screen {
        vt.append_move(&out, if position.row < ROWS { position.row } else { ROWS - 1 }, column)
    }
    else {
        vt.append_column(&out, column)
    }
    service.column = column
    emit(service, string_bytes(text_buffer.as_string(&out)))
}

/*
 * An area made blank: on a whole screen, each of its rows; on lines, the line being written, with the cursor at its
 * start, which is how a program redraws a line it's editing.
 */
clear :: fn(service: ptr[mut Service], area: terminal.Area) {
    storage : u8[128]
    out := text_buffer.make(storage)
    if !service.whole_screen {
        text_buffer.append_byte(&out, 0x0d)
        vt.append_clear_to_end(&out)
        service.column = 0
        emit(service, string_bytes(text_buffer.as_string(&out)))
        return void
    }
    if area.column >= COLUMNS || area.row >= ROWS {
        return void
    }
    columns :: if area.columns > COLUMNS - area.column { COLUMNS - area.column } else { area.columns }
    rows :: if area.rows > ROWS - area.row { ROWS - area.row } else { area.rows }
    for row in area.row..<area.row + rows {
        text_buffer.clear(&out)
        vt.append_move(&out, row, area.column)
        if area.column + columns >= COLUMNS {
            vt.append_clear_to_end(&out)
        }
        else {
            for i in 0..<columns {
                text_buffer.append_byte(&out, cast[u8](' '))
            }
        }
        emit(service, string_bytes(text_buffer.as_string(&out)))
    }
}

// An area scrolled, on a whole screen, where it's as wide as the screen, which is what a VT can scroll.
scroll :: fn(service: ptr[mut Service], scrolled: terminal.ScrollArea) {
    area :: scrolled.area
    if !service.whole_screen || area.column != 0 || area.columns < COLUMNS || area.row >= ROWS || area.rows == 0 {
        return void
    }
    last :: if area.rows > ROWS - area.row { ROWS - 1 } else { area.row + area.rows - 1 }
    storage : u8[48]
    out := text_buffer.make(storage)
    vt.append_scroll(&out, area.row, last, scrolled.lines)
    emit(service, string_bytes(text_buffer.as_string(&out)))
}

// A screen of the program's own, or back to the lines it left.
use_screen :: fn(service: ptr[mut Service], whole: bool) {
    if whole == service.whole_screen {
        return void
    }
    storage : u8[32]
    out := text_buffer.make(storage)
    vt.append_alternate_screen(&out, whole)
    service.whole_screen = whole
    service.column = 0
    emit(service, string_bytes(text_buffer.as_string(&out)))
}

// bytes, queued for the serial line; what doesn't fit the queue is dropped. Without a serial line nothing is kept.
emit :: fn(service: ptr[mut Service], bytes: u8[]) {
    if cast[slop_os.Handle](service.serial_connector) == slop_os.NO_HANDLE {
        return void
    }
    for byte in bytes {
        if service.output_count >= service.output.count {
            return void
        }
        at :: (service.output_start + service.output_count) % service.output.count
        if at < service.output.count {
            service.output[at] = byte
        }
        service.output_count += 1
    }
}

// Writes on the serial line from the queue, while it has room for them.
pump :: fn(service: ptr[mut Service]) {
    if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        if service.output_count == 0 || service.in_flight >= MAX_IN_FLIGHT {
            break
        }
        chunk : u8[serial.MAX_BYTES]
        taken :: if service.output_count < chunk.count { service.output_count } else { chunk.count }
        for i in 0..<taken {
            at :: (service.output_start + i) % service.output.count
            if at < service.output.count && i < chunk.count {
                chunk[i] = service.output[at]
            }
        }
        out := os.Outgoing.{}
        request :: os.begin[serial.Request](&out)
        request^ = .Write(os.append(&out, chunk[0..<taken]))
        if serial.send_request(service.line_end, service.port, &out) != null {
            break
        }
        service.in_flight += 1
        service.output_start = (service.output_start + taken) % service.output.count
        service.output_count -= taken
    }
}

// Another Read, held by the driver until something's typed.
read_more :: fn(service: ptr[mut Service]) {
    out := os.Outgoing.{}
    request :: os.begin[serial.Request](&out)
    request^ = .Read(serial.MAX_BYTES)
    _ = serial.send_request(service.line_end, service.port, &out)
}

read_keys :: fn(service: ptr[mut Service]) {
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Read(input.MAX_EVENTS)
    _ = input.send_request(service.keyboard_end, service.port, &out)
}

// What the serial line answered: Writes taken, and bytes typed, decoded. A line that's gone, dialed again.
take_serial :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match serial.receive_response(service.line_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](service.line_end))
                service.line_end = NONE
                runtime.log_info("its serial line went; dialing again")
                dial_serial(service)
                // Read the new one until it's empty, since only a read that finds nothing has its next answer wake the port
                if cast[slop_os.Handle](service.line_end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
            case _ => continue
        }
        match os.message_of[serial.Response](into)^ {
            case Written(_) => {
                service.in_flight = if service.in_flight > 0 { service.in_flight - 1 } else { cast[u32](0) }
                pump(service)
            }
            case Data(given) => {
                vt.feed(&service.decoder, os.items(into, given), &service.decoded)
                vt.finish(&service.decoder, &service.decoded)
                read_more(service)
            }
            case _ => {}
        }
    }
}

// What the keyboard's pressed, as keys a US layout types. A keyboard that's gone, dialed again.
take_keys :: fn(service: ptr[mut Service], into: ptr[mut os.Incoming]) {
    if cast[slop_os.Handle](service.keyboard_end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match input.receive_response(service.keyboard_end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](service.keyboard_end))
                service.keyboard_end = NONE
                runtime.log_info("its keyboard went; dialing again")
                dial_keyboard(service)
                // As a serial line dialed again
                if cast[slop_os.Handle](service.keyboard_end) == slop_os.NO_HANDLE {
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
                        press(service, event.code, input.is_pressed(event))
                    }
                }
                read_keys(service)
            }
            case _ => {}
        }
    }
}

// A key, down or up: modifiers remembered, and a key pressed given as an event, with what it types.
press :: fn(service: ptr[mut Service], usage: u16, pressed: bool) {
    bit :: if usage == USAGE_LEFT_SHIFT || usage == USAGE_RIGHT_SHIFT { terminal.SHIFT }
        else if usage == USAGE_LEFT_CONTROL || usage == USAGE_RIGHT_CONTROL { terminal.CONTROL }
        else if usage == USAGE_LEFT_ALT || usage == USAGE_RIGHT_ALT { terminal.ALT } else { cast[u8](0) }
    if bit != 0 {
        service.modifiers = if pressed { service.modifiers | bit } else { service.modifiers & ~bit }
        return void
    }
    if !pressed {
        return void
    }
    if usage == USAGE_C && service.modifiers & terminal.CONTROL != 0 {
        vt.event(&service.decoded, terminal.event_of(.Interrupt))
        return void
    }
    character :: if service.modifiers & (terminal.CONTROL | terminal.ALT) != 0 { cast[u8](0) }
        else { character_of(usage, service.modifiers & terminal.SHIFT != 0) }
    typed : u8[1]
    typed[0] = character
    vt.key(&service.decoded, usage, service.modifiers, if character != 0 { typed[0..<1] } else { typed[0..<0] })
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
    if usage == USAGE_ENTER {
        return 0x0a
    }
    if usage == USAGE_TAB {
        return 0x09
    }
    index :: cast[usize](usage) - 0x2d
    if usage >= 0x2d && index < PUNCTUATION.count {
        return cast[u8](if shifted { PUNCTUATION_SHIFTED[index] } else { PUNCTUATION[index] })
    }
    return 0
}

// The input waiting, to the owner, once it holds a Read.
deliver :: fn(service: ptr[mut Service], connected: ptr[service_kit.Clients]) {
    if service.decoded.count == 0 || service.held == 0 {
        return void
    }
    owner :: service.owner or_return void
    if owner >= connected.ends.count {
        return void
    }
    end :: connected.ends[owner]
    count :: if service.decoded.count < cast[usize](service.held) { service.decoded.count } else { cast[usize](service.held) }
    if count > service.decoded.events.count || service.decoded.text_count > service.decoded.text.count {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[terminal.Response](&out)
    response^ = .Input(terminal.Events.{events = os.append(&out, service.decoded.events[0..<count]),
        text = os.append(&out, service.decoded.text[0..<service.decoded.text_count])})
    if terminal.send_response(end, service.port, &out) != null {
        return void
    }
    service.held = 0
    // Events past the Read's most are dropped with their text, which the next events' ranges would no longer match
    vt.reset(&service.decoder, &service.decoded)
}
