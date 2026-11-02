package session

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import terminal from "std/os/slop_os"

/*
 * What the trusted path asks of the session manager (decisions/0136, 0139, 0150). Start makes a session once someone's
 * logged in: whose it is, its home volume's root, and a terminal connection for its programs, which its first program
 * is started with; StartWithoutUser makes the one session of a boot with no accounts. List is answered with the
 * session's programs running, their memory, and whether each answered a Ping on its lifecycle channel; End asks one, by
 * the index List gave it, to stop, then ends it after a grace period, and it isn't started again.
 */

Session :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "session", major_version = 1, lending = .Server}

MAX_PROGRAMS :: 16
NAME_BYTES :: 32

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

// A session to make: its user's name, its home volume's root, and the terminal its programs write to.
SessionStart :: struct {
    user : slop_os.Relative[u8],
    home : os.Channel[dir.Dir],
    terminal : os.Channel[terminal.Terminal],
}

Request :: union {
    Start(SessionStart),
    // The session of a boot with no accounts, with the terminal its programs write to
    StartWithoutUser(os.Channel[terminal.Terminal]),
    List,
    // The program at this index stopped, or ended
    End(u32),
    // Serve another client, on its end
    Connect(os.Channel[Session]),
}

Response :: union {
    // The session's made, its first program started
    Started,
    Programs(slop_os.Relative[Program]),
    // It's ended, or was already
    Ended,
    // No program at that index that may be ended
    Refused,
    Unsupported,
}

// Listing again changes nothing; ending what's ended is answered Ended again.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Start(_) => false
        case StartWithoutUser(_) => false
        case List => true
        case End(_) => true
        case Connect(_) => true
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
