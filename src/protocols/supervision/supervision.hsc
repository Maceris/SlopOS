package supervision

import os from "std"
import slop_os from "std/os"
import events from "../events"

/*
 * The supervisor's reports to the root task (decisions/0067, 0071, 0074), one way: as each service or driver starts,
 * ends, or doesn't start, and once it has started all it will; and a connection to the events service, once it's up and
 * each time it's started again, for the services the root task starts again to log through (decisions/0140). The root
 * task answers none of them.
 */

/**
 * The supervision protocol, for the one channel between the supervisor and the root task: the supervisor sends the
 * requests, reports the root task logs and acts on, and none is answered.
 */
Supervision :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the root task, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "supervision", major_version = 1, lending = .Server}

/** What happened to one service or driver: which, and a code whose meaning is the report's. */
Report :: struct {
    /** The service's or driver's name, as its grant label: UTF-8, padded with zeros to GRANT_LABEL_SIZE bytes. */
    name : u8[slop_os.GRANT_LABEL_SIZE],
    /**
     * For Started, 0. For Ended, the exit code its SIGNAL_TERMINATED gave, slop_os.EXIT_KILLED if it was killed.
     * For Failed, its os.LaunchError's value plus one, so it's never 0.
     */
    code : u64,
}

/** What the supervisor tells the root task; none of them is answered. */
Request :: union {
    /** A service or driver started, at boot or again after it ended; its code is 0. */
    Started(Report),
    /** A service or driver ended, with its exit code. */
    Ended(Report),
    /** A service or driver couldn't be launched, with its os.LaunchError plus one. */
    Failed(Report),
    /** Everything the supervisor starts at boot has started or failed: how many started. */
    AllStarted(u32),
    /** The boot's assessment (decisions/0115), just before AllStarted: every service the system needs is up. */
    Healthy,
    /**
     * Or, in Healthy's place, how many of the services the system needs aren't up: the boot is degraded, and its
     * record says which and why.
     */
    Degraded(u32),
    /**
     * A connection to the events service, sent once it's up and each time it's started again, which moves to the
     * root task, for the services the root task starts again to log through (decisions/0140); it replaces, and
     * closes, the one before.
     */
    EventsService(os.Channel[events.Events]),
}

/** What the root task answers: nothing, but every protocol has a response. */
Response :: union {
    /** The answer to a request not known; every protocol has it, though the root task skips such a report unsaid. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: a report says what happened, so again is the same.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Started(_) => true
        case Ended(_) => true
        case Failed(_) => true
        case AllStarted(_) => true
        case Healthy => true
        case Degraded(_) => true
        case EventsService(_) => true
    }
}

#insert os.protocol_code(Request, Response)
