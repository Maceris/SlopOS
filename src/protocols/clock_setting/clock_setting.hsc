package clock_setting

import os from "std"
import slop_os from "std/os"

/*
 * The clock service's protocol for setting the time (roadmap 9a, decisions/0093): it sets the real-time clock, and the
 * clock page every program reads the time from, to a UTC time. Only who holds a connection can set it: the supervisor,
 * for now. Connections arrive on its listener as Connects.
 */

ClockSetting :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "clock_setting", major_version = 1, lending = .Server}

Request :: union {
    // Set the time to this many nanoseconds since 1970-01-01T00:00:00Z
    Set(i64),
    // Serve another client, on its end
    Connect(os.Channel[ClockSetting]),
}

Response :: union {
    // The time is set, the real-time clock's and the clock page's
    Done,
    // The real-time clock couldn't be set, or doesn't hold a time this far from 2000; nothing changed
    Refused,
    Unsupported,
}

// Setting the time again sets it to the same time, which has moved on since.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

/*
 * The time set to utc, in nanoseconds since 1970-01-01T00:00:00Z, through end: whether the clock service set it. It
 * waits on port for the answer.
 */
set :: fn(end: slop_os.Channel, port: slop_os.Port, utc: i64) -> bool {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Set(utc)
    if send_request(end, port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    loop {
        match receive_response(end, port, &into, true) {
            case Received => break
            case Failed(error) => return false
            case _ => continue
        }
    }
    return match os.message_of[Response](&into)^ {
        case Done => true
        case _ => false
    }
}
