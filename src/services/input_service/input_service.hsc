/**
 * The input service (decisions/0136, 0138, design/console-and-sessions.md §3): it owns the seat's keyboards, up to
 * four, reached through connectors and dialed again when they go, and gives the terminal service what they type,
 * through the US layout, as the seat protocol. It sees every key first: Ctrl+Alt+Delete, the secure attention key,
 * goes to the trusted path as itself from any keyboard, and is never a key.
 *
 * The terminal service, the reader, can lend the seat to another client that reads, the compositor (decisions/0192,
 * 15c): while it's lent, keys and pointers go to the borrower. The secure attention key, or a new keyboard's first key,
 * takes the seat back, what was waiting for the borrower dropped, so the trusted path always has it for those.
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

/** The most keyboards the seat has: one for each of the keyboard0 to keyboard3 grants. */
MAX_KEYBOARDS :: 4
/** The port key keyboard i's channel is bound at, plus i: above the clients' keys. */
KEYBOARD_KEY : u64 : 1000
/** No channel: a keyboard's connector or end when it has none. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

/** The HID usage of C. */
USAGE_C : u16 : 0x06
/** The HID usage of Enter, which checks a new keyboard's code. */
USAGE_ENTER : u16 : 0x28
/** The HID usage of Backspace, which takes back a digit of a new keyboard's code. */
USAGE_BACKSPACE : u16 : 0x2a
/** The HID usage of Delete, which with Ctrl and Alt is the secure attention key. */
USAGE_DELETE : u16 : 0x4c
/** The HID usage of the left Ctrl. */
USAGE_LEFT_CONTROL : u16 : 0xe0
/** The HID usage of the left Shift. */
USAGE_LEFT_SHIFT : u16 : 0xe1
/** The HID usage of the left Alt. */
USAGE_LEFT_ALT : u16 : 0xe2
/** The HID usage of the left Meta (the Windows or Command key). */
USAGE_LEFT_META : u16 : 0xe3
/** The HID usage of the right Ctrl. */
USAGE_RIGHT_CONTROL : u16 : 0xe4
/** The HID usage of the right Shift. */
USAGE_RIGHT_SHIFT : u16 : 0xe5
/** The HID usage of the right Alt. */
USAGE_RIGHT_ALT : u16 : 0xe6
/** The HID usage of the right Meta. */
USAGE_RIGHT_META : u16 : 0xe7

/** One of the seat's keyboards: how it's reached, what's held down on it, and whether it's trusted. */
Keyboard :: struct {
    /** The connector it's dialed through, the grant's, kept to dial it again; NONE without a keyboard. */
    connector : slop_os.Channel,
    /** The input protocol channel dialed through connector, the service's own; NONE while it's not connected. */
    end : slop_os.Channel,
    /** The modifiers held down on it, as terminal.SHIFT, CONTROL, ALT and META's bits; cleared when it's dialed. */
    modifiers : u8,
    /**
     * Whether what it types reaches the terminal service: true for the machine's own, and for a new one once its code
     * is typed.
     */
    accepted : bool,
    /** A new keyboard's six-digit code, 100000 to 999999; 0 until its first key, and once it's accepted. */
    code : u32,
    /** Its absolute axes, as Describe answered when it was dialed; all 0 until then, or without them. */
    axes : input.Axes,
    /** The digits of the code typed on it so far, as a number; 0 again after each Enter. */
    typed : u32,
}

/** The most events kept for the reader. */
QUEUED_EVENTS :: 256
/** The most bytes of text the events kept for the reader hold, in all. */
QUEUED_TEXT :: 2048

/**
 * The input service's state.
 *
 * Events wait for the reader, more than one Input holds, so a burst of typing waits rather than being dropped.
 */
Service :: struct {
    /** The port every keyboard and client is bound to, waited on for all of them. */
    port : slop_os.Port,
    /** The layout keys are typed through: US until a client's SetLayout names another. */
    keymap : keymaps.Keymap,
    /** The keyboards, by grant: keyboards[i] from keyboard{i}. */
    keyboards : Keyboard[MAX_KEYBOARDS],
    /** The events waiting for the reader, the first count of them, oldest first. */
    events : seat.Event[QUEUED_EVENTS],
    /** How many of events are waiting, at most QUEUED_EVENTS; an event past them is dropped. */
    count : usize,
    /** The waiting events' text, which their text_start and text_bytes are ranges of. */
    text : u8[QUEUED_TEXT],
    /** How many of text's bytes are in use. */
    text_count : usize,
    /**
     * The client that reads, the first to send a Read, by its index among the clients; null until one has, and after
     * it goes.
     */
    reader : usize?,
    /** How many events the reader's Read held asks for, at least 1; 0 when it holds none. */
    held : u32,
    /** Whether the reader has lent the seat. */
    lent : bool,
    /** The client that borrows the seat while it's lent, the one that sent Borrow, by its index; null for none. */
    borrower : usize?,
    /** How many events the borrower's Read held asks for, at least 1; 0 when it holds none. */
    borrower_held : u32,
}

/**
 * Serve the seat's keyboards: give what they type to the reader, through the keyboard layout, as the seat protocol.
 *
 * It runs until the system ends. Ctrl+Alt+Delete on any keyboard is the secure attention key, given as itself and
 * never as a key. A keyboard that's new, found after it started, has to have the code it makes, shown on the status
 * line, typed on it, and Enter, before anything it types reaches anyone.
 *
 * @param log The kernel's debug log. The service writes its lines through base's logger instead, so it's taken but
 *     not used.
 * @param keyboard0 The connector to the first keyboard's driver, dialed for the input protocol, and dialed again when
 *     the driver restarts. Without it, the seat has no first keyboard.
 * @param keyboard1 The connector to the second keyboard's driver, as keyboard0's.
 * @param keyboard2 The connector to the third keyboard's driver, as keyboard0's.
 * @param keyboard3 The connector to the fourth keyboard's driver, as keyboard0's.
 * @param clients Where connections from the seat's clients, the terminal service, arrive; more come through Connect.
 * @param command_line The kernel's command line, read for test_new_keyboards, which treats every keyboard as new.
 *     Without it, the keyboards given are the machine's own, and accepted.
 * @return 2 if its port couldn't be made; 3 if the clients' listener couldn't be bound to it. It doesn't return
 *     otherwise.
 */
main :: fn(log: slop_os.DebugLog?, keyboard0: os.Channel[connector.Connector]?, keyboard1: os.Channel[connector.Connector]?,
    keyboard2: os.Channel[connector.Connector]?, keyboard3: os.Channel[connector.Connector]?, clients: os.Listener[seat.Seat],
    command_line: slop_os.Memory?) -> int {
    startup :: slop_os.startup_block()
    service := runtime.new(Service)
    service.keymap = keymaps.US
    service.port = slop_os.port_create(startup.budget) or_return 2
    _ = service_kit.watch_stop(service.port)
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
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(service.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Take a keyboard grant as one of the seat's keyboards, accepted unless every keyboard is new, and dial it.
 *
 * @param service The service, whose keyboards[index] is set: its connector kept and, if dialing works, its end bound
 *     to the service's port.
 * @param index The keyboard's index, below MAX_KEYBOARDS; past it, nothing's done.
 * @param found The keyboard's connector, which the keyboard keeps; null for no keyboard at index.
 * @param all_new Whether test_new_keyboards treats every keyboard as new, so it has to have its code typed.
 */
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

/**
 * Dial a keyboard through its connector for the input protocol, bind it to the port, and hold a Read on it.
 *
 * Its modifiers are cleared, since what was held down isn't known. On any failure the keyboard's left without an end,
 * not dialed again until it's given another chance (only take_keys dials again).
 *
 * @param service The service: the keyboard's new end is bound to its port, at KEYBOARD_KEY plus index, and kept in
 *     keyboards[index].
 * @param index The keyboard's index; one past MAX_KEYBOARDS, or without a connector, isn't dialed.
 */
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
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Describe
    _ = input.send_request(keyboard.end, service.port, &out)
    read_keys(service, keyboard)
}

/**
 * Hold a Read on a keyboard, for as many events as the input protocol gives at once; a failure to send is noticed when
 * its answer's taken.
 *
 * @param service The service, whose port the answer comes to.
 * @param keyboard The keyboard, connected.
 */
read_keys :: fn(service: ptr[Service], keyboard: ptr[Keyboard]) {
    out := os.Outgoing.{}
    request :: os.begin[input.Request](&out)
    request^ = .Read(input.MAX_EVENTS)
    _ = input.send_request(keyboard.end, service.port, &out)
}

/**
 * Answer a client's requests, until it has none waiting.
 *
 * A Read is held for the reader, which is the first client to send one; another client's Read is never answered.
 * SetLayout changes the layout to the one it names, if there's one by that name. Connect adds a client. A client
 * whose channel fails is dropped, and if it was the reader, the next client to Read is.
 *
 * @param service The service: its reader and held Read are set or cleared, and SetLayout changes its keymap.
 * @param connected The clients bound to the service's port; Connect adds to them, and a client whose channel fails is
 *     dropped from them, its end closed.
 * @param index The client's index among them; past them, or a client that's gone, nothing's done.
 * @param into Where each request is received, reused.
 */
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
            case _ => {
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
                if (service.borrower or_else connected.ends.count) == index {
                    service.borrower = null
                    service.borrower_held = 0
                }
                return void
            }
        }
        match os.message_of[seat.Request](into)^ {
            case Read(most) => {
                owned :: match service.reader {
                    case Some(reader) => reader == index
                    case None => true
                }
                if (service.borrower or_else connected.ends.count) == index {
                    service.borrower_held = if most == 0 { cast[u32](1) } else { most }
                }
                else if owned {
                    service.reader = index
                    service.held = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case Borrow => {
                // The borrower's never the reader
                if (service.reader or_else connected.ends.count) != index {
                    service.borrower = index
                    runtime.log_info("the compositor borrows the seat")
                }
            }
            case Lend(lending) => {
                if (service.reader or_else connected.ends.count) == index && service.lent != lending {
                    service.lent = lending
                    runtime.log_info(if lending { "lent the seat" } else { "took the seat back" })
                    // What was waiting was for whoever had the seat
                    service.count = 0
                    service.text_count = 0
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

/**
 * Take what a keyboard pressed, until there's nothing more, and hold another Read for each answer.
 *
 * A keyboard whose channel fails, as when its driver restarts, is closed and dialed again; it's the same keyboard,
 * accepted or not as it was.
 *
 * @param service The service, whose queue takes the events made; a failed keyboard's end is closed and dialed again.
 * @param index The keyboard's index; past MAX_KEYBOARDS, or a keyboard not connected, nothing's done.
 * @param into Where each answer is received, reused.
 */
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
            case _ => {
                _ = slop_os.handle_close(cast[slop_os.Handle](keyboard.end))
                keyboard.end = NONE
                runtime.log_info("keyboard % went; dialing again", index)
                dial(service, index)
                if cast[slop_os.Handle](keyboard.end) == slop_os.NO_HANDLE {
                    return void
                }
                continue
            }
        }
        match os.message_of[input.Response](into)^ {
            case Events(given) => {
                for event in os.items(into, given) {
                    kind :: input.kind_of(event) or_else input.EventKind.Key
                    if kind == .Key {
                        press(service, index, event.code, input.is_pressed(event))
                    }
                    else {
                        point(service, index, kind, event)
                    }
                }
                read_keys(service, keyboard)
            }
            case Described(axes) => keyboard.axes = axes
            case _ => {}
        }
    }
}

/**
 * Handle a key on a keyboard, down or up: modifiers remembered, the secure attention key given as itself, and the
 * rest typed, or, on a keyboard not accepted, taken as its code.
 *
 * With Ctrl, Alt or Meta held a key types no text; it's known by its usage and modifiers.
 *
 * @param service The service, whose queue the event goes in.
 * @param index The keyboard's index, below MAX_KEYBOARDS; the seat event says it as which.
 * @param usage The key's HID usage.
 * @param pressed True when it goes down, false when it comes up; only a modifier coming up does anything.
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

/**
 * Queue a pointer's event for the borrower, from an accepted device while the seat's lent to one; dropped otherwise.
 *
 * @param service The service, whose queue it goes in.
 * @param index The device's index, below MAX_KEYBOARDS.
 * @param kind The input protocol's kind: Motion, Position, Button or Wheel; a Key isn't one.
 * @param event The device's event: a Position's x and y spread from its axes' range to 0 to seat.POSITION_MAX.
 */
point :: fn(service: ptr[mut Service], index: usize, kind: input.EventKind, event: input.Event) {
    keyboard :: &service.keyboards[index % MAX_KEYBOARDS]
    if !keyboard.accepted || !service.lent || (service.borrower is_none) {
        return void
    }
    which :: cast[u8](index)
    made := match kind {
        case .Motion => seat.event_of(.PointerMotion, which)
        case .Position => seat.event_of(.PointerPosition, which)
        case .Button => seat.event_of(.Button, which)
        case .Wheel => seat.event_of(.Wheel, which)
        case .Key => return void
    }
    made.x = event.x
    made.y = event.y
    if kind == .Position {
        made.x = spread(event.x, keyboard.axes.x_min, keyboard.axes.x_max)
        made.y = spread(event.y, keyboard.axes.y_min, keyboard.axes.y_max)
    }
    if kind == .Button {
        made.code = event.code
        made.pressed = if input.is_pressed(event) { cast[u8](1) } else { cast[u8](0) }
        made.modifiers = keyboard.modifiers
    }
    add(service, made, "")
}

/** An absolute axis's value spread from its range to 0 to seat.POSITION_MAX; taken as that range itself without one. */
spread :: fn(value: i32, low: i32, high: i32) -> i32 {
    if high <= low {
        return if value < 0 { 0 } else if value > seat.POSITION_MAX { seat.POSITION_MAX } else { value }
    }
    clamped :: if value < low { low } else if value > high { high } else { value }
    return cast[i32]((cast[i64](clamped) - cast[i64](low)) * cast[i64](seat.POSITION_MAX) / (cast[i64](high) - cast[i64](low)))
}

/**
 * Find the modifier a key is.
 *
 * @param usage The key's HID usage.
 * @return terminal.SHIFT, CONTROL, ALT or META for either side's key; 0 for a key that isn't a modifier.
 */
modifier_of :: fn(usage: u16) -> u8 {
    return if usage == USAGE_LEFT_SHIFT || usage == USAGE_RIGHT_SHIFT { terminal.SHIFT }
        else if usage == USAGE_LEFT_CONTROL || usage == USAGE_RIGHT_CONTROL { terminal.CONTROL }
        else if usage == USAGE_LEFT_ALT || usage == USAGE_RIGHT_ALT { terminal.ALT }
        else if usage == USAGE_LEFT_META || usage == USAGE_RIGHT_META { terminal.META } else { cast[u8](0) }
}

/**
 * Handle a key on a keyboard that's new: its first makes its code, a random six-digit number given to the reader as a
 * Waiting event for the terminal service to show; digits build what's typed of it, Backspace takes one back, and
 * Enter checks it, accepting the keyboard, and giving an Accepted event, if it's the code. Nothing else it types goes
 * anywhere.
 *
 * A wrong code typed only starts the typing again; the code stays the same.
 *
 * @param service The service: the keyboard's code, what's typed of it and whether it's accepted change, the layout
 *     reads the digits, and the Waiting and Accepted events go in its queue.
 * @param index The keyboard's index, below MAX_KEYBOARDS; larger ones wrap around it.
 * @param usage The key's HID usage, read as a digit through the layout.
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

/**
 * Queue an event for the reader, with its text.
 *
 * @param service The service, whose queue the event and its text are added to; if either's full, nothing changes.
 * @param made The event; its text_start and text_bytes are set here.
 * @param text Its text, copied. The event is dropped if it or its text has no room in the queue.
 */
add :: fn(service: ptr[mut Service], made: seat.Event, text: string) {
    // The secure attention key and a new keyboard's code are the trusted path's: the seat comes back for them
    if service.lent && (made.kind == cast[u8](seat.EventKind.SecureAttention) || made.kind == cast[u8](seat.EventKind.Waiting)) {
        service.lent = false
        service.count = 0
        service.text_count = 0
        runtime.log_info("the seat's back with the reader")
    }
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
 * Give the events waiting to the reader, once it holds a Read: as many as it asked for, at most an Input's, and as
 * many as their text fits one; those after wait for its next Read.
 *
 * If the answer can't be sent, the events stay queued and the Read stays held.
 *
 * @param service The service, whose queue loses the events given.
 * @param connected The clients, to find the reader's channel.
 */
deliver :: fn(service: ptr[mut Service], connected: ptr[service_kit.Clients]) {
    borrowing :: service.lent && (service.borrower is_some)
    held :: if borrowing { service.borrower_held } else { service.held }
    if service.count == 0 || held == 0 {
        return void
    }
    reader :: (if borrowing { service.borrower } else { service.reader }) or_return void
    if reader >= connected.ends.count {
        return void
    }
    end :: connected.ends[reader]
    count := if service.count < cast[usize](held) { service.count } else { cast[usize](held) }
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
    if borrowing {
        service.borrower_held = 0
    }
    else {
        service.held = 0
    }
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

/**
 * Find where the text of the queued events after the first count starts.
 *
 * @param service The service, whose queue is read and not changed.
 * @param count How many of the queued events are before.
 * @return The offset in the queue's text: text_count, all of it, if there are none after.
 */
text_before :: fn(service: ptr[Service], count: usize) -> usize {
    if count < service.count && count < service.events.count {
        return cast[usize](service.events[count].text_start)
    }
    return service.text_count
}

