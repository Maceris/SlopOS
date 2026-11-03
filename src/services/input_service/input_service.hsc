/**
 * The input service (decisions/0136, 0138, design/console-and-sessions.md §3): it owns the seat's keyboards, up to four,
 * reached through connectors and dialed again when they go, and gives the terminal service what they type, through the
 * US layout, as the seat protocol. It sees every key first: Ctrl+Alt+Delete, the secure attention key, goes to the
 * trusted path as itself from any keyboard, and is never a key.
 *
 * Keyboards there when it starts are the machine's own, and accepted. One found later, or every one with
 * test_new_keyboards on the kernel's command line, is new: its first key makes a random six-digit code, which the
 * terminal service shows on the status line, and nothing it types reaches anyone until that code is typed on it, and
 * Enter. A keyboard that's dialed again, after its driver's restart, is the same keyboard.
 */
package input_service

import runtime from "base"
import os from "std"
import random from "std"
import slop_os from "std/os"
import terminal from "std/os/slop_os"
import connector from "../../protocols/connector"
import input from "../../protocols/input"
import seat from "../../protocols/seat"
import keymaps from "../../keymaps"
import service_kit from "../../libraries/service_kit"

MAX_KEYBOARDS :: 4
// Each keyboard is bound to the port at this key and above, above the clients
KEYBOARD_KEY : u64 : 1000
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

USAGE_C : u16 : 0x06
USAGE_ENTER : u16 : 0x28
USAGE_BACKSPACE : u16 : 0x2a
USAGE_DELETE : u16 : 0x4c
USAGE_LEFT_CONTROL : u16 : 0xe0
USAGE_LEFT_SHIFT : u16 : 0xe1
USAGE_LEFT_ALT : u16 : 0xe2
USAGE_LEFT_META : u16 : 0xe3
USAGE_RIGHT_CONTROL : u16 : 0xe4
USAGE_RIGHT_SHIFT : u16 : 0xe5
USAGE_RIGHT_ALT : u16 : 0xe6
USAGE_RIGHT_META : u16 : 0xe7

Keyboard :: struct {
    connector : slop_os.Channel,
    end : slop_os.Channel,
    modifiers : u8,
    accepted : bool,
    // A new keyboard's code, 0 until its first key, and what's been typed of it
    code : u32,
    typed : u32,
}

// The most events kept for the reader, and their text's bytes.
QUEUED_EVENTS :: 256
QUEUED_TEXT :: 2048

Service :: struct {
    port : slop_os.Port,
    keymap : keymaps.Keymap,
    keyboards : Keyboard[MAX_KEYBOARDS],
    // Events waiting for the reader, more than one Input holds, so a burst of typing waits rather than being dropped:
    // the client that read first, and how many its Read held asks for
    events : seat.Event[QUEUED_EVENTS],
    count : usize,
    text : u8[QUEUED_TEXT],
    text_count : usize,
    reader : usize?,
    held : u32,
}

main :: fn(log: slop_os.DebugLog?, keyboard0: os.Channel[connector.Connector]?, keyboard1: os.Channel[connector.Connector]?,
    keyboard2: os.Channel[connector.Connector]?, keyboard3: os.Channel[connector.Connector]?, clients: os.Listener[seat.Seat],
    command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.keymap = keymaps.US
    service.port = slop_os.port_create(startup.budget) or_return 2
    connected := service_kit.Clients.{}
    if !service_kit.add_client(&connected, service.port, clients.end) {
        return 3
    }
    all_new := false
    match command_line {
        case Some(memory) => all_new = service_kit.has_word(service_kit.text_of(startup, memory) or_else "", "test_new_keyboards")
        case None => {}
    }
    adopt(service, 0, keyboard0, all_new)
    adopt(service, 1, keyboard1, all_new)
    adopt(service, 2, keyboard2, all_new)
    adopt(service, 3, keyboard3, all_new)
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
        for i in cast[usize](0)..<MAX_KEYBOARDS {
            take_keys(service, i, &into)
        }
        deliver(service, &connected)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/** The keyboard given as index, if there is one, accepted unless every keyboard is new, and dialed. */
adopt :: fn(service: ptr[mut Service], index: usize, found: os.Channel[connector.Connector]?, all_new: bool) {
    if index >= service.keyboards.count {
        return void
    }
    keyboard :: &service.keyboards[index]
    keyboard.connector = NONE
    keyboard.end = NONE
    channel :: found or_return void
    keyboard.connector = channel.end
    keyboard.accepted = !all_new
    dial(service, index)
}

/** Keyboard index through its connector: bound to the port, with a Read held. */
dial :: fn(service: ptr[mut Service], index: usize) {
    if index >= service.keyboards.count {
        return void
    }
    keyboard :: &service.keyboards[index]
    if cast[slop_os.Handle](keyboard.connector) == slop_os.NO_HANDLE {
        return void
    }
    port :: os.port_for(slop_os.startup_block().budget, keyboard.connector) or_return void
    keys :: connector.dial[input.Input](keyboard.connector, port) or_return void
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(service.port, cast[slop_os.Handle](keys.end), signals, KEYBOARD_KEY + cast[u64](index), .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](keys.end))
            return void
        }
    }
    keyboard.end = keys.end
    keyboard.modifiers = 0
    read_keys(service, keyboard)
}

read_keys :: fn(service: ptr[Service], keyboard: ptr[Keyboard]) {
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Read(input.MAX_EVENTS)
    _ = input.send_request(keyboard.end, service.port, &out)
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
        match seat.receive_request(end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = seat.answer_unsupported(end, service.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(connected, index)
                match service.reader {
                    case Some(reader) => {
                        if reader == index {
                            service.reader = null
                            service.held = 0
                        }
                    }
                    case None => {}
                }
                return void
            }
            case _ => continue
        }
        match os.message_of[seat.Request](into)^ {
            case Read(most) => {
                owned :: match service.reader {
                    case Some(reader) => reader == index
                    case None => true
                }
                if owned {
                    service.reader = index
                    service.held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case SetLayout(name) => {
                bytes :: os.items(into, name)
                if bytes.count > 0 {
                    match keymaps.find(string_of(&bytes[0], bytes.count)) {
                        case Some(layout) => {
                            service.keymap = layout
                            runtime.log_info("typing through the % layout", layout.name)
                        }
                        case None => {}
                    }
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

/** What keyboard index pressed, until there's nothing more. A keyboard that's gone, dialed again. */
take_keys :: fn(service: ptr[mut Service], index: usize, into: ptr[mut os.Incoming]) {
    if index >= service.keyboards.count {
        return void
    }
    keyboard :: &service.keyboards[index]
    if cast[slop_os.Handle](keyboard.end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match input.receive_response(keyboard.end, service.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](keyboard.end))
                keyboard.end = NONE
                runtime.log_info("keyboard % went; dialing again", index)
                dial(service, index)
                if cast[slop_os.Handle](keyboard.end) == slop_os.NO_HANDLE {
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
                        press(service, index, event.code, input.is_pressed(event))
                    }
                }
                read_keys(service, keyboard)
            }
            case _ => {}
        }
    }
}

/**
 * A key on keyboard index, down or up: modifiers remembered, the secure attention key given as itself, and the rest typed.
 */
press :: fn(service: ptr[mut Service], index: usize, usage: u16, pressed: bool) {
    keyboard :: &service.keyboards[index % MAX_KEYBOARDS]
    bit :: modifier_of(usage)
    if bit != 0 {
        keyboard.modifiers = if pressed { keyboard.modifiers | bit } else { keyboard.modifiers & ~bit }
        return void
    }
    if !pressed {
        return void
    }
    which :: cast[u8](index)
    if usage == USAGE_DELETE && keyboard.modifiers & (terminal.CONTROL | terminal.ALT) == terminal.CONTROL | terminal.ALT {
        add(service, seat.event_of(.SecureAttention, which), "")
        return void
    }
    if !keyboard.accepted {
        type_code(service, index, usage)
        return void
    }
    shifted :: keyboard.modifiers & terminal.SHIFT != 0
    // With Ctrl or Alt a key types nothing; it's known by its usage and modifiers
    text :: if keyboard.modifiers & (terminal.CONTROL | terminal.ALT | terminal.META) != 0 { "" } else { keymaps.typed(service.keymap, usage, shifted) }
    made := seat.event_of(.Key, which)
    made.code = usage
    made.modifiers = keyboard.modifiers
    add(service, made, text)
}

modifier_of :: fn(usage: u16) -> u8 {
    return if usage == USAGE_LEFT_SHIFT || usage == USAGE_RIGHT_SHIFT { terminal.SHIFT }
        else if usage == USAGE_LEFT_CONTROL || usage == USAGE_RIGHT_CONTROL { terminal.CONTROL }
        else if usage == USAGE_LEFT_ALT || usage == USAGE_RIGHT_ALT { terminal.ALT }
        else if usage == USAGE_LEFT_META || usage == USAGE_RIGHT_META { terminal.META } else { cast[u8](0) }
}

/**
 * A key on a keyboard that's new: its first makes its code, which the terminal service shows; digits build what's typed
 * of it, Backspace takes one back, and Enter checks it, accepting the keyboard if it's the code. Nothing else it types
 * goes anywhere.
 */
type_code :: fn(service: ptr[mut Service], index: usize, usage: u16) {
    keyboard :: &service.keyboards[index % MAX_KEYBOARDS]
    which :: cast[u8](index)
    if keyboard.code == 0 {
        keyboard.code = 100000 + cast[u32](random.next_u64() % 900000)
        keyboard.typed = 0
        waiting := seat.event_of(.Waiting, which)
        waiting.waiting_code = keyboard.code
        add(service, waiting, "")
        runtime.log_info("keyboard % is new: its code is on the console", index)
        return void
    }
    if usage == USAGE_BACKSPACE {
        keyboard.typed /= 10
        return void
    }
    if usage == USAGE_ENTER {
        if keyboard.typed == keyboard.code {
            keyboard.accepted = true
            keyboard.code = 0
            add(service, seat.event_of(.Accepted, which), "")
            runtime.log_info("keyboard % accepted", index)
        }
        keyboard.typed = 0
        return void
    }
    match keymaps.digit_of(service.keymap, usage) {
        case Some(digit) => {
            if keyboard.typed < 100000 {
                keyboard.typed = keyboard.typed * 10 + digit
            }
        }
        case None => {}
    }
}

/** An event for the reader, with its text; dropped if there's no room. */
add :: fn(service: ptr[mut Service], made: seat.Event, text: string) {
    bytes :: string_bytes(text)
    if service.count >= service.events.count || bytes.count > service.text.count - service.text_count {
        return void
    }
    event := made
    event.text_start = cast[u32](service.text_count)
    event.text_bytes = cast[u32](bytes.count)
    for byte in bytes {
        if service.text_count < service.text.count {
            service.text[service.text_count] = byte
            service.text_count += 1
        }
    }
    if service.count < service.events.count {
        service.events[service.count] = event
        service.count += 1
    }
}

/**
 * The events waiting, to the reader, once it holds a Read: as many as it asked for, at most an Input's, and as many as
 * their text fits one; those after wait for its next Read.
 */
deliver :: fn(service: ptr[mut Service], connected: ptr[service_kit.Clients]) {
    if service.count == 0 || service.held == 0 {
        return void
    }
    reader :: service.reader or_return void
    if reader >= connected.ends.count {
        return void
    }
    end :: connected.ends[reader]
    count := if service.count < cast[usize](service.held) { service.count } else { cast[usize](service.held) }
    if count > seat.MAX_EVENTS {
        count = seat.MAX_EVENTS
    }
    text_end := text_before(service, count)
    loop {
        if text_end <= seat.MAX_TEXT || count <= 1 {
            break
        }
        count -= 1
        text_end = text_before(service, count)
    }
    if count > service.events.count || text_end > service.text.count || text_end > service.text_count {
        return void
    }
    out := os.Outgoing.{}
    response :: os.begin[seat.Response](&out)
    response^ = .Input(seat.Events.{events = os.append(&out, service.events[0..<count]), text = os.append(&out, service.text[0..<text_end])})
    if seat.send_response(end, service.port, &out) != null {
        return void
    }
    service.held = 0
    // Those after moved to the front, their text with them
    left :: service.count - count
    for i in 0..<left {
        from :: i + count
        if from < service.events.count && i < service.events.count {
            moved := service.events[from]
            moved.text_start = if cast[usize](moved.text_start) >= text_end { moved.text_start - cast[u32](text_end) } else { 0 }
            service.events[i] = moved
        }
    }
    text_left :: service.text_count - text_end
    for i in 0..<text_left {
        from :: i + text_end
        if from < service.text.count && i < service.text.count {
            service.text[i] = service.text[from]
        }
    }
    service.count = left
    service.text_count = text_left
}

/** Where the text of the events after the first count starts: all of it, if there are none after. */
text_before :: fn(service: ptr[Service], count: usize) -> usize {
    if count < service.count && count < service.events.count {
        return cast[usize](service.events[count].text_start)
    }
    return service.text_count
}

