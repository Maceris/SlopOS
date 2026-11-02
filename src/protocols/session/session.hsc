package session

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import terminal from "std/os/slop_os"

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

Session :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "session", major_version = 1, lending = .Server}

MAX_PROGRAMS :: 16
NAME_BYTES :: 32
NO_SESSION : u32 : 0xffffffff

// Plain data, as a Relative's elements are: responding is 1 or 0.
Program :: struct {
    index : u32,
    name : u8[NAME_BYTES],
    name_bytes : u8,
    responding : u8,
    // Its memory budget's bytes in use, and its limit
    memory : u64,
    memory_limit : u64,
}

/*
 * A session to make: its user's name, its home volume's root, the terminal its programs write to, and the keyboard
 * layout its user logged in with, which chooses its locale until its user's settings say one (decisions/0152).
 */
SessionStart :: struct {
    user : slop_os.Relative[u8],
    layout : slop_os.Relative[u8],
    home : os.Channel[dir.Dir],
    terminal : os.Channel[terminal.Terminal],
}

Request :: union {
    Start(SessionStart),
    // The session of a boot with no accounts, with the terminal its programs write to
    StartWithoutUser(os.Channel[terminal.Terminal]),
    // A session's programs, by its number
    List(u32),
    // Every program of a session, by its number, asked to stop, then ended; and the session with them
    EndSession(u32),
    // The program at this index stopped, or ended
    End(u32),
    // Serve another client, on its end
    Connect(os.Channel[Session]),
    // The session the console shows now, by its number, or NO_SESSION
    Shown(u32),
}

Response :: union {
    // The session's made, its first program started: its number
    Started(u32),
    Programs(slop_os.Relative[Program]),
    // It's ended, or was already
    Ended,
    // No program at that index that may be ended, or no room for another session
    Refused,
    // Shown's answer
    Noted,
    Unsupported,
}

// Listing again changes nothing; ending what's ended is answered Ended again.
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

// A new connection to the session manager listening on end, or null (as entropy.connect).
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

// A program's name, as text.
name_of :: fn(program: ptr[Program]) -> string {
    count :: if cast[usize](program.name_bytes) <= program.name.count { cast[usize](program.name_bytes) } else { program.name.count }
    return if count == 0 { "" } else { string_of(&program.name[0], count) }
}
