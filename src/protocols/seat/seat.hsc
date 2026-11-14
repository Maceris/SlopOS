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
 *
 * The reader can lend the seat (decisions/0192, 15c): while it's lent, keys and the pointer go to the borrower, the
 * client that said it borrows (Borrow), the compositor, instead; the pointer goes only to a borrower. The secure attention key
 * ends the lending, and goes to the reader as itself, the events waiting for the borrower dropped.
 */

/**
 * The seat protocol, for the channels between the input service and its clients, and its listener: the clients send
 * the requests, and the input service answers them.
 */
Seat :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the input service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "seat", major_version = 1, lending = .Server}

/** The most events one Input has: 32. */
MAX_EVENTS :: 32
/** The most bytes of text one Input has, for all its events together, unless its one event's text is more: 256. */
MAX_TEXT :: 256

/** What an event is, as Event's kind holds it. */
EventKind :: enum #backed_by(u8) {
    /**
     * A key pressed on an accepted keyboard: the event's code is the key's HID usage, its modifiers std/os/slop_os's
     * terminal's bits held then, and its text what the key types through the seat's keymap, empty with Ctrl, Alt or
     * Meta held or for a key that types nothing.
     */
    Key = 1,
    /** Ctrl+Alt+Delete, the secure attention key, on keyboard, given as itself whether it's accepted or not. */
    SecureAttention = 2,
    /**
     * Keyboard is new: nothing reads it until the event's waiting_code is typed on it, and Enter. Sent at its first
     * key press.
     */
    Waiting = 3,
    /** Keyboard's code was typed: its keys come as Key events from now on. */
    Accepted = 4,
    /** A relative pointer moved x across and y down, in the device's units; for the borrower only. */
    PointerMotion = 5,
    /**
     * An absolute pointer is at x across and y down, each from 0 to POSITION_MAX across the device's range; for the
     * borrower only.
     */
    PointerPosition = 6,
    /** A pointer's button, code from 0 (left), went down or came up as pressed says; for the borrower only. */
    Button = 7,
    /** A wheel turned y notches, positive away from the user; for the borrower only. */
    Wheel = 8,
}

/** The largest x and y a PointerPosition has: its device's range spread from 0 to this. */
POSITION_MAX : i32 : 65535

/** One event, plain data, as a Relative's elements are; kind_of tells its kind, and event_of makes one. */
Event :: struct {
    /** An EventKind's value; one this version doesn't know is null from kind_of. */
    kind : u8,
    /** Which of the input service's keyboards it's from, an index from 0. */
    keyboard : u8,
    /** For a Key, the modifier bits held, as std/os/slop_os's terminal names them; 0 otherwise. */
    modifiers : u8,
    /** For a Key, the key's HID usage (keyboard page); 0 otherwise. */
    code : u16,
    /** For a Waiting, the code to type on the keyboard, six decimal digits, 100000 to 999999; 0 otherwise. */
    waiting_code : u32,
    /** Where the event's text starts in its Events' text, in bytes. */
    text_start : u32,
    /** How many bytes of text the event has, as UTF-8; 0 for none. */
    text_bytes : u32,
    /** For a PointerMotion or PointerPosition, across; 0 otherwise. */
    x : i32,
    /** For a PointerMotion or PointerPosition, down; for a Wheel, how far it turned; 0 otherwise. */
    y : i32,
    /** For a Button, 1 if it went down, 0 if it came up; 0 otherwise. */
    pressed : u8,
}

/** Events, oldest first, and their text. */
Events :: struct {
    /** The events, 1 to MAX_EVENTS of them. */
    events : slop_os.Relative[Event],
    /** The events' text, each one's at its text_start, as UTF-8. */
    text : slop_os.Relative[u8],
}

/** What a client, the terminal service, asks the input service. */
Request :: union {
    /**
     * Ask for up to this many events, 0 taken as 1; held until there's at least one. Only one client reads: the first
     * to Read, while it's connected; another client's Read is never answered. A later Read replaces one held.
     * Answered with Input.
     */
    Read(u32),
    /**
     * Choose the keymap keys are typed through from now on, by its name, as UTF-8 (src/keymaps). Answered with
     * nothing; a name that isn't a layout's leaves the one there is.
     */
    SetLayout(slop_os.Relative[u8]),
    /**
     * Have the input service serve another client, on the end given, which moves to the service; it's closed if the
     * service already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Seat]),
    /**
     * From the reader: lend the seat to the borrower, or take it back. While it's lent, a borrower's Read is answered
     * with the seat's keys and pointer, and the reader's only with the secure attention key, which takes it back.
     * Answered with nothing.
     */
    Lend(bool),
    /**
     * Be the borrower: the client the seat's lent to, whose Reads are answered while it's lent, never the reader, which
     * ever client reads first. Sent by the compositor before it reads. Answered with nothing.
     */
    Borrow,
}

/** What the input service answers. */
Response :: union {
    /**
     * Read's answer: the events waiting, as many as it asked for, at most MAX_EVENTS, and as many as fit MAX_TEXT
     * bytes of text, at least one; those after wait for the next Read.
     */
    Input(Events),
    /** The answer to a request the service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Read, which asked again is another Read, taking other events; true for SetLayout, Connect and Lend.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => false
        case SetLayout(_) => true
        case Connect(_) => true
        case Lend(_) => true
        case Borrow => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make an event of a kind, from a keyboard, its other fields 0, for the input service to fill in.
 *
 * @param kind What the event is.
 * @param keyboard Which keyboard it's from, an index from 0.
 * @return The event, with kind's value, keyboard, and no code, modifiers, waiting code or text.
 */
event_of :: fn(kind: EventKind, keyboard: u8) -> Event {
    return Event.{kind = cast[u8](kind), keyboard = keyboard}
}

/**
 * Tell what an event is.
 *
 * @param event The event, as it came.
 * @return Its kind; null for a kind value this version doesn't have, as from a newer input service, which a client
 *     skips.
 */
kind_of :: fn(event: Event) -> EventKind? {
    return match event.kind {
        case 1 => EventKind.Key
        case 2 => EventKind.SecureAttention
        case 3 => EventKind.Waiting
        case 4 => EventKind.Accepted
        case 5 => EventKind.PointerMotion
        case 6 => EventKind.PointerPosition
        case 7 => EventKind.Button
        case 8 => EventKind.Wheel
        case _ => null
    }
}

/**
 * Make a new connection to the input service: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the input service takes the end when it next serves its listener, or closes it when it's full, which
 * the caller learns of as its end's peer gone.
 *
 * @param end The input service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
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
