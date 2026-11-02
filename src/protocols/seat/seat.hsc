package seat

import os from "std"
import slop_os from "std/os"

/*
 * The input service's protocol (decisions/0136, 0138): the seat's keyboards as the trusted path sees them, for the
 * terminal service. Keys come typed through the seat's keymap, with their HID usage, modifiers and text; the secure
 * attention key comes as itself, from any keyboard, before anything else sees it; and a keyboard found after boot comes
 * only as Waiting, with the code to type on it, until that's typed, when it's Accepted and its keys come too. A Read is
 * held until there's an event. SetLayout chooses the keymap keys are typed through (decisions/0150), by its name, which
 * isn't answered; a name that isn't a layout's leaves the one there is. Connections arrive on the input service's
 * listener as Connects.
 */

Seat :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "seat", major_version = 1, lending = .Server}

// The most events, and bytes of their text, one Events has.
MAX_EVENTS :: 32
MAX_TEXT :: 256

EventKind :: enum #backed_by(u8) {
    // keyboard; code: the key's HID usage; modifiers (std/os/slop_os's terminal's); text: what it types, if anything
    Key = 1,
    // Ctrl+Alt+Delete, on keyboard
    SecureAttention = 2,
    // keyboard is new: nothing reads it until code is typed on it, and Enter
    Waiting = 3,
    // keyboard's code was typed: its keys come from now on
    Accepted = 4,
}

// Plain data, as a Relative's elements are: kind an EventKind's value (event_of, kind_of).
Event :: struct {
    kind : u8,
    keyboard : u8,
    modifiers : u8,
    code : u16,
    waiting_code : u32,
    text_start : u32,
    text_bytes : u32,
}

Events :: struct {
    events : slop_os.Relative[Event],
    text : slop_os.Relative[u8],
}

Request :: union {
    // Up to this many events; held until there's one
    Read(u32),
    // The keymap keys are typed through from now on, by its name (src/keymaps)
    SetLayout(slop_os.Relative[u8]),
    // Serve another client, on its end
    Connect(os.Channel[Seat]),
}

Response :: union {
    Input(Events),
    Unsupported,
}

// A Read asked again is another Read.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => false
        case SetLayout(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

event_of :: fn(kind: EventKind, keyboard: u8) -> Event {
    return Event.{kind = cast[u8](kind), keyboard = keyboard}
}

// What an event is, or null for a kind this version hasn't.
kind_of :: fn(event: Event) -> EventKind? {
    return match event.kind {
        case 1 => EventKind.Key
        case 2 => EventKind.SecureAttention
        case 3 => EventKind.Waiting
        case 4 => EventKind.Accepted
        case _ => null
    }
}

// A new connection to the input service listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Seat]? {
    pair :: os.channel_for[Seat](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Seat].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Seat].{end = pair.b}
    }
}
