package clock_setting

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * The clock service's protocol for setting the time (roadmap 9a, decisions/0093): it sets the real-time clock, and the
 * clock page every program reads the time from, to a UTC time. Only who holds a connection can set it: the supervisor,
 * for now. Connections arrive on its listener as Connects.
 *
 * Keep gives it a directory to keep the time in across boots (decisions/0188, 13e), which the clock starts no earlier
 * than.
 */

/**
 * The clock setting protocol, for the channels between the clock service and those allowed to set the time, and its
 * listener: the clients send the requests, and the clock service answers them.
 */
ClockSetting :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the clock service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "clock_setting", major_version = 1, lending = .Server}

/** What a client asks the clock service. */
Request :: union {
    /**
     * Set the time to this many nanoseconds since 1970-01-01T00:00:00Z, UTC; negative is before 1970. Answered with
     * Done, or Refused.
     */
    Set(i64),
    /**
     * Keep the time in this directory, which moves to the clock service: the time saved there is read, and the clock set
     * forward to it if it's later; the time's saved there now, every SAVE_MINUTES, after each Set, and as the service
     * stops. Answered with Done, or Refused if the directory can't be used; a Keep replaces the one before.
     */
    Keep(os.Channel[dir.Dir]),
    /**
     * Have the clock service serve another client, on the end given, which moves to it; it's closed if the service
     * already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[ClockSetting]),
}

/** What the clock service answers. */
Response :: union {
    /** Set's answer: the time is set, the real-time clock's and the clock page's; Keep's: the directory's kept in. */
    Done,
    /**
     * Set's answer when the real-time clock couldn't be set, or doesn't hold a time this far from 2000; nothing
     * changed.
     */
    Refused,
    /** The answer to a request the clock service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for Set, which sets the time to the same time again, which has moved on since, and Connect; false for Keep,
 *     whose directory moves.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Keep(_) => false
        case _ => true
    }
}

/** How often the time's saved, once a Keep's given a directory: every 5 minutes. */
SAVE_MINUTES :: 5

#insert os.protocol_code(Request, Response)

/**
 * Set the time through the clock service, and wait for its answer.
 *
 * A response that isn't the protocol, unknown or invalid, ends the wait as the connection's going does
 * (decisions/0177).
 *
 * @param end A connection to the clock service, kept by the caller.
 * @param port A port bound to end, waited on for the answer and while end's ring is full.
 * @param utc The time, in nanoseconds since 1970-01-01T00:00:00Z, UTC.
 * @return True if the clock service set it; false if it refused, or the request couldn't be sent, or the connection's
 *     gone.
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
            case _ => return false
        }
    }
    return match os.message_of[Response](&into)^ {
        case Done => true
        case _ => false
    }
}

/**
 * Give the clock service a directory to keep the time in, and wait for its answer.
 *
 * @param end A connection to the clock service, kept by the caller.
 * @param port A port bound to end, waited on for the answer and while end's ring is full.
 * @param directory The directory, which moves to the clock service even if the request isn't answered.
 * @return True if the clock service keeps the time there; false if it refused, or the request couldn't be sent, or the
 *     connection's gone.
 */
keep :: fn(end: slop_os.Channel, port: slop_os.Port, directory: os.Channel[dir.Dir]) -> bool {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Keep(directory)
    if send_request(end, port, &out) is_some {
        return false
    }
    into := os.Incoming.{}
    match receive_response(end, port, &into, true) {
        case Received => {}
        case _ => return false
    }
    return match os.message_of[Response](&into)^ {
        case Done => true
        case _ => false
    }
}
