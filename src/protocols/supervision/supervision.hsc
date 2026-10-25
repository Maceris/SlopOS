package supervision

import os from "std"
import slop_os from "std/os"

/*
 * The supervisor's reports to the root task (decisions/0067, 0071, 0074), one way: as each service or driver starts,
 * ends, or doesn't start, and once it has started all it will. The root task answers none of them.
 */

Supervision :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "supervision", major_version = 1, lending = .Server}

// A service, and for an end, the code its SIGNAL_TERMINATED gave (slop_os.EXIT_KILLED if it was killed); for a
// failure, its os.LaunchError, plus one.
Report :: struct {
    name : u8[slop_os.GRANT_LABEL_SIZE],
    code : u64,
}

Request :: union {
    Started(Report),
    Ended(Report),
    Failed(Report),
    // Everything it starts at boot has started or failed: how many started
    AllStarted(u32),
}

Response :: union {
    Unsupported,
}

// A report says what happened, so again is the same.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Started(_) => true
        case Ended(_) => true
        case Failed(_) => true
        case AllStarted(_) => true
    }
}

#insert os.protocol_code(Request, Response)
