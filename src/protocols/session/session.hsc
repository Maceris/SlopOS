package session

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import terminal from "std/os/slop_os"
import prompt from "../prompt"

/*
 * What the trusted path asks of the session manager (decisions/0136, 0139, 0150). Start makes a session once someone's
 * logged in: whose it is, its home volume's root, and a terminal connection for its programs, which its first program
 * is started with; StartWithoutUser makes the one session of a boot with no accounts; each is answered with the
 * session's number. List, for a session by its number, is answered with its programs running, their memory, and
 * whether each answered a Ping on its lifecycle channel; End asks one, by the index List gave it, to stop, then ends it
 * after a grace period, and it isn't started again; EndSession does that for every program of a session, which ends it
 * (decisions/0151). Shown tells it which session the console shows, NO_SESSION for none, as on the login screen: the
 * others' installations are the idle ones it asks to stop under memory pressure (decisions/0153).
 */

/**
 * The session protocol, for the channels between the session manager and its clients, the trusted path's, and its
 * listener: the clients send the requests, and the session manager answers them.
 */
Session :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the session manager, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "session", major_version = 1, lending = .Server}

/** The most programs one Programs lists: 16. */
MAX_PROGRAMS :: 16
/** The most bytes of a program's name in a Program: 32. */
NAME_BYTES :: 32
/** Shown's number for no session shown, as on the login screen. */
NO_SESSION : u32 : 0xffffffff

/** A program of a session's, running, as List gives it: plain data, as a Relative's elements are. */
Program :: struct {
    /** Its index in the session manager's table of programs, for End. */
    index : u32,
    /** Its name, as UTF-8, in the first name_bytes bytes. */
    name : u8[NAME_BYTES],
    /** How many of name's bytes are the name, 0 to NAME_BYTES; name_of takes no more than NAME_BYTES. */
    name_bytes : u8,
    /** 1 if it answered the Ping List sent on its lifecycle channel in time, 0 if it didn't. */
    responding : u8,
    /** Its memory budget's bytes in use; 0 if the budget couldn't be read. */
    memory : u64,
    /** Its memory budget's limit, in bytes; 0 if the budget couldn't be read. */
    memory_limit : u64,
}

/**
 * A session to make: its user's name, its home volume's root, the terminal its programs write to, the keyboard layout
 * its user logged in with, which chooses its locale until its user's settings say one (decisions/0152), and the trusted
 * path's prompt connection for its powerbox (decisions/0156).
 */
SessionStart :: struct {
    /** The user's name, as UTF-8, at most 32 bytes, or the session is refused. */
    user : slop_os.Relative[u8],
    /** The keyboard layout's name, as UTF-8, as src/keymaps names it: "uk" suggests en-GB, anything else en-US. */
    layout : slop_os.Relative[u8],
    /** The root of the user's home volume, which moves to the session manager, for the session's programs. */
    home : os.Channel[dir.Dir],
    /** The terminal the session's programs write to, which moves to the session manager. */
    terminal : os.Channel[terminal.Terminal],
    /** The trusted path's prompt connection, which moves to the session manager, for the session's powerbox. */
    prompts : os.Channel[prompt.Prompt],
}

/** What the trusted path asks the session manager. */
Request :: union {
    /**
     * Make a session once someone's logged in, and start its first program. Its channels move to the session
     * manager, which closes them if it refuses. Answered with Started, or Refused when there's no room for another
     * session, the user's name is too long, or its first program didn't start.
     */
    Start(SessionStart),
    /**
     * Make the one session of a boot with no accounts, with the terminal its programs write to, which moves to the
     * session manager. Answered as Start is.
     */
    StartWithoutUser(os.Channel[terminal.Terminal]),
    /**
     * Ask for a session's running programs, by its number, each pinged on its lifecycle channel and given a short
     * while to answer. Answered with Programs, empty for a session that isn't there.
     */
    List(u32),
    /**
     * End a session, by its number: every program of it asked to stop, then killed if it hasn't after a grace period,
     * and the session with them (decisions/0151). Answered with Ended, once it's done, or at once for a session that
     * isn't there.
     */
    EndSession(u32),
    /**
     * End a program, by its index as List gave it: asked to stop on its lifecycle channel, then killed if it hasn't
     * ended after a grace period of 2 seconds; it isn't started again. Answered with Ended, once it has, or Refused
     * for an index past the table's.
     */
    End(u32),
    /**
     * Have the session manager serve another client, on the end given, which moves to it; it's closed if the session
     * manager already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Session]),
    /**
     * Say which session the console shows now, by its number, or NO_SESSION for none: the others' installations are
     * the idle ones asked to stop under memory pressure (decisions/0153). Answered with Noted.
     */
    Shown(u32),
}

/** What the session manager answers. */
Response :: union {
    /** Start's or StartWithoutUser's answer: the session's made, its first program started, by its number. */
    Started(u32),
    /** List's answer: the session's running programs, at most MAX_PROGRAMS. */
    Programs(slop_os.Relative[Program]),
    /** End's or EndSession's answer: it's ended, or was already. */
    Ended,
    /**
     * End's answer for an index past the session manager's table, or Start's and StartWithoutUser's when the session
     * couldn't be made.
     */
    Refused,
    /** Shown's answer. */
    Noted,
    /** The answer to a request the session manager doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Start and StartWithoutUser, which make another session; true for the rest: listing again changes
 *     nothing, and ending what's ended is answered Ended again.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Start(_) => false
        case StartWithoutUser(_) => false
        case List(_) => true
        case EndSession(_) => true
        case End(_) => true
        case Connect(_) => true
        case Shown(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the session manager: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the session manager takes the end when it next serves its listener, or closes it when it's full,
 * which the caller learns of as its end's peer gone.
 *
 * @param end The session manager's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Session]? {
    pair :: os.channel_for[Session](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Session].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Session].{end = pair.b}
    }
}

/**
 * Give a program's name as text.
 *
 * @param program The program, which the text views.
 * @return Its name's first name_bytes bytes, at most NAME_BYTES, as UTF-8 though not checked to be: a view into
 *     program's name, good while program is; "" for none.
 */
name_of :: fn(program: ptr[Program]) -> string {
    count :: if cast[usize](program.name_bytes) <= program.name.count { cast[usize](program.name_bytes) } else { program.name.count }
    return if count == 0 { "" } else { string_of(&program.name[0], count) }
}
