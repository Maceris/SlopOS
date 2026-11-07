package power

import os from "std"
import slop_os from "std/os"

/*
 * Asking for the system to shut down (decisions/0180): the supervisor serves it, to the terminal service, whose secure
 * attention key's screen asks it for the person at the console, and passes it on to the root task, which ends, and
 * with it everything. Only who holds a connection can ask.
 */

/**
 * The power protocol, for the channel between the supervisor and the terminal service: the terminal service sends the
 * requests, and the supervisor answers them.
 */
Power :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the supervisor, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "power", major_version = 1, lending = .Server}

/** What the terminal service asks the supervisor. */
Request :: union {
    /**
     * Shut the system down: the root task is told, and ends, ending everything. Answered with Done once the root task
     * is told, which may not be seen before the system's gone; Refused if it couldn't be told.
     */
    ShutDown,
}

/** What the supervisor answers. */
Response :: union {
    /** ShutDown's answer: the root task's been told. */
    Done,
    /** ShutDown's answer when the root task couldn't be told, as when its channel's gone. */
    Refused,
    /** The answer to a request the supervisor doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True: shutting down again is shutting down.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)
