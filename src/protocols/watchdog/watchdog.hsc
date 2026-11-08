package watchdog

import os from "std"
import slop_os from "std/os"

/*
 * A hardware watchdog (decisions/0182, P5, design/lessons.md §6.2): its driver's one client, the supervisor, arms it
 * with a timeout and resets it while the services it supervises answer; a machine that stops being reset in time is
 * reset by the watchdog, and boot counting does the rest. A shutdown disarms it.
 */

/**
 * The watchdog protocol, for the channel between the supervisor and a hardware watchdog's driver: the supervisor
 * sends the requests, and the driver answers them.
 */
Watchdog :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the driver, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "watchdog", major_version = 1, lending = .Server}

/** What the supervisor asks a watchdog's driver. */
Request :: union {
    /**
     * Arm the watchdog to reset the machine once this many seconds pass without a Pet, 2 to the most the device takes
     * (the i6300esb's, 2046); one given past them is taken as the nearest. Answered with Armed, saying the seconds it
     * took.
     */
    Arm(u32),
    /** Start the watchdog's time again. Answered with Done; Refused while it isn't armed. */
    Pet,
    /** Stop the watchdog, so it resets nothing, as a shutdown does first. Answered with Done. */
    Disarm,
    /**
     * Have the driver serve another client, on the end given, which moves to it; it's closed if the driver already has
     * as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Watchdog]),
}

/** What a watchdog's driver answers. */
Response :: union {
    /** Arm's answer: the seconds it's armed for. */
    Armed(u32),
    /** Pet's and Disarm's answer. */
    Done,
    /** Pet's answer while the watchdog isn't armed. */
    Refused,
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for each: arming, resetting and stopping again change nothing more.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Arm(_) => true
        case Pet => true
        case Disarm => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the driver, through its listener: a channel made, one end sent in Connect.
 *
 * @param end The listener's other end, which Connect is sent on.
 * @param port A port the end is bound to, or may be.
 * @param budget The budget the new channel is charged to.
 * @return The caller's end of the new connection; null if the channel couldn't be made or Connect couldn't be sent.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Watchdog]? {
    pair :: os.channel_for[Watchdog](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Watchdog].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Watchdog].{end = pair.b}
    }
}
