package session

import os from "std"
import slop_os from "std/os"

/*
 * What the trusted path asks of whoever runs the session's programs (decisions/0136, 0139): the supervisor until 10c's
 * session manager, for the console's programs. List is answered with each program running, its memory, and whether it
 * answered a Ping on its lifecycle channel; End asks one, by the index List gave it, to stop, then ends it after a
 * grace period, and it isn't started again.
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

Request :: union {
    List,
    // The program at this index stopped, or ended
    End(u32),
    // Serve another client, on its end
    Connect(os.Channel[Session]),
}

Response :: union {
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
        case List => true
        case End(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A program's name, as text.
name_of :: fn(program: ptr[Program]) -> string {
    count :: if cast[usize](program.name_bytes) <= program.name.count { cast[usize](program.name_bytes) } else { program.name.count }
    return if count == 0 { "" } else { string_of(&program.name[0], count) }
}
