package input

import os from "std"
import slop_os from "std/os"

/*
 * The device class of keyboards, mice and tablets (decisions/0077): events in SlopOS's own terms, a key by its USB HID
 * usage (page 7), a pointer's motion or position, a button, a wheel. A Read is held by the driver until at least one
 * event has arrived, as a serial line's is. M10's terminal service turns keys into text with a keymap; until then the
 * console does, for a US layout. Connections arrive on the driver's listener as Connects.
 */

/**
 * The input protocol, for the channels between an input device's driver and its clients, and its listener: the
 * clients send the requests, and the driver answers them.
 */
Input :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the driver, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "input", major_version = 1, lending = .Server}

/** The most events one Events has: 32. */
MAX_EVENTS :: 32

/** What an event is, as Event's kind holds it. */
EventKind :: enum #backed_by(u8) {
    /**
     * A key: the event's code is its USB HID usage (page 7), and pressed whether it went down, or repeats held down,
     * or was let go.
     */
    Key = 1,
    /** A relative pointer's motion: x and y are how far it moved, in the device's units, either 0 for no motion. */
    Motion = 2,
    /** An absolute pointer, like a tablet's: x and y are where it is, from 0 to the device's largest. */
    Position = 3,
    /** A button: the event's code is which, from 0 (left), and pressed whether it went down or was let go. */
    Button = 4,
    /** A wheel: y is how far it turned, in notches, positive away from the user. */
    Wheel = 5,
}

/** One event, plain data, as a Relative's elements are; kind_of tells its kind, and is_pressed its pressed. */
Event :: struct {
    /** An EventKind's value; one this version doesn't know is null from kind_of. */
    kind : u8,
    /** For a Key or a Button, 1 if it's down, 0 if it was let go; 0 for the other kinds. */
    pressed : u8,
    /** For a Key, its USB HID usage; for a Button, which, from 0; 0 for the other kinds. */
    code : u16,
    /** For a Motion, how far it moved across; for a Position, where it is across; 0 otherwise. */
    x : i32,
    /** For a Motion, how far it moved down; for a Position, where it is down; for a Wheel, how far it turned. */
    y : i32,
}

/**
 * Tell what an event is.
 *
 * @param event The event, as it came.
 * @return Its kind; null for a kind value this version doesn't have, as from a newer driver, which a client skips.
 */
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

/**
 * Tell whether a Key's or a Button's event is it going down, or repeating held down, rather than being let go.
 *
 * @param event A Key's or a Button's event; another kind's pressed is 0.
 * @return True if its pressed is any value but 0; false for the kinds that aren't keys or buttons, whose pressed is 0.
 */
is_pressed :: fn(event: Event) -> bool {
    return event.pressed != 0
}

/**
 * Make an event, for a driver to send.
 *
 * @param kind What the event is.
 * @param pressed For a Key or a Button, whether it's down; false for the other kinds.
 * @param code For a Key, its USB HID usage; for a Button, which, from 0; 0 for the other kinds.
 * @param x What Event's x is for its kind, 0 when it has none.
 * @param y What Event's y is for its kind, 0 when it has none.
 * @return The event, its kind kind's value and its pressed 1 or 0.
 */
event_of :: fn(kind: EventKind, pressed: bool, code: u16, x: i32, y: i32) -> Event {
    return Event.{kind = cast[u8](kind), pressed = if pressed { cast[u8](1) } else { cast[u8](0) }, code = code, x = x, y = y}
}

/** What a client asks an input device's driver. */
Request :: union {
    /**
     * Ask for up to this many events, 0 taken as 1, of those the client hasn't had; held until there's at least one.
     * Every client gets every event, from when it connected. A later Read replaces one held. Answered with Events.
     */
    Read(u32),
    /**
     * Have the driver serve another client, on the end given, which moves to the driver; it's closed if the driver
     * already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Input]),
}

/** What an input device's driver answers. */
Response :: union {
    /**
     * Read's answer: the events, oldest first, at least one, at most the Read's count and MAX_EVENTS. A client that
     * fell far behind may have missed the oldest.
     */
    Events(slop_os.Relative[Event]),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Read, which again would take other events; true for Connect.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => false
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to an input device's driver: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves its listener, or closes it when it's full, which the
 * caller learns of as its end's peer gone.
 *
 * @param end The driver's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
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
