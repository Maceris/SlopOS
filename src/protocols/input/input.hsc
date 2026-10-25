package input

import os from "std"
import slop_os from "std/os"

/*
 * The device class of keyboards, mice and tablets (decisions/0077): events in SlopOS's own terms, a key by its USB HID
 * usage (page 7), a pointer's motion or position, a button, a wheel. A Read is held by the driver until at least one
 * event has arrived, as a serial line's is. M10's terminal service turns keys into text with a keymap; until then the
 * console does, for a US layout. Connections arrive on the driver's listener as Connects.
 */

Input :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "input", major_version = 1, lending = .Server}

// The most events one Events has.
MAX_EVENTS :: 32

EventKind :: enum #backed_by(u8) {
    // code: the key's USB HID usage; pressed
    Key = 1,
    // x and y: how far a pointer moved
    Motion = 2,
    // x and y: where a pointer is, from 0 to the device's largest
    Position = 3,
    // code: which button, from 0 (left); pressed
    Button = 4,
    // y: how far a wheel turned
    Wheel = 5,
}

// Plain data, as a Relative's elements are: kind an EventKind's value, and pressed 1 or 0 (kind_of, is_pressed)
Event :: struct {
    kind : u8,
    pressed : u8,
    code : u16,
    x : i32,
    y : i32,
}

// What an event is, or null for a kind this version hasn't.
kind_of :: fn(event: Event) -> EventKind? {
    return match event.kind {
        case 1 => EventKind.Key
        case 2 => EventKind.Motion
        case 3 => EventKind.Position
        case 4 => EventKind.Button
        case 5 => EventKind.Wheel
        case _ => null
    }
}

is_pressed :: fn(event: Event) -> bool {
    return event.pressed != 0
}

// An event of kind.
event_of :: fn(kind: EventKind, pressed: bool, code: u16, x: i32, y: i32) -> Event {
    return Event.{kind = cast[u8](kind), pressed = if pressed { cast[u8](1) } else { cast[u8](0) }, code = code, x = x, y = y}
}

Request :: union {
    // Up to most events, answered once there's at least one
    Read(u32),
    // Serve another client, on its end
    Connect(os.Channel[Input]),
}

Response :: union {
    Events(slop_os.Relative[Event]),
    Unsupported,
}

// A Read again would take other events.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => false
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the driver listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Input]? {
    pair :: os.channel_for[Input](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Input].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Input].{end = pair.b}
    }
}
