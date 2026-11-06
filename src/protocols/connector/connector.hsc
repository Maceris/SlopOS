package connector

import os from "std"
import slop_os from "std/os"

/*
 * A connector (decisions/0017, 0077): what a client holds in place of a connection to a service that may be restarted.
 * Dial gives a new connection to whichever process serves it now, which the client keeps until its other end goes,
 * then dials again. The supervisor serves connectors to what it starts, and the root task to what it does
 * (decisions/0140), one channel each, so which service a connector reaches is which channel the client was given; dial
 * checks the connection speaks the protocol the client expects.
 */

/**
 * The connector protocol, for the channel between a client and the supervisor or root task serving it a connector:
 * the client sends the requests, and the supervisor or root task answers them.
 */
Connector :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the supervisor or root task, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "connector", major_version = 1, lending = .Server}

/** What a client asks of its connector. */
Request :: union {
    /** Ask for a new connection to whatever serves the connector now. Answered with Dialed, or Unavailable. */
    Dial,
}

/** What the supervisor or root task answers on a connector. */
Response :: union {
    /**
     * Dial's answer: the client's end of a new connection, of the protocol the connector is for, which moves to the
     * client; it's good until its other end goes, as when the service ends.
     */
    Dialed(slop_os.Channel),
    /** Dial's answer when nothing serves it now, as while it's restarting: dial again later. */
    Unavailable,
    /** The answer to a request the server doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for Dial: dialing again gives another connection, which is as good.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Dial => true
    }
}

#insert os.protocol_code(Request, Response)

/** How long dial waits between tries while what it reaches is unavailable, in nanoseconds: 100 ms. */
RETRY_NANOSECONDS : u64 : 100_000_000
/** How many tries dial makes before it gives up, so it waits at most about 5 seconds in all. */
TRIES :: 50

/**
 * Dial a connector for a connection of protocol P, trying again while what it reaches is restarting.
 *
 * It waits for each answer, and RETRY_NANOSECONDS between tries, at most TRIES of them.
 *
 * @tparam P The protocol the connection has to speak, checked by its tag (os.speaks).
 * @param end The connector, kept by the caller.
 * @param port A port bound to end, waited on for each answer and while end's ring is full.
 * @return The new connection, the caller's to keep and close; null if the Dial couldn't be sent, the connector's
 *     gone or answered Unsupported, it was Unavailable for every try, or the connection doesn't speak P, which is
 *     closed then.
 */
dial :: fn[P](end: slop_os.Channel, port: slop_os.Port) -> os.Channel[P]? {
    channel :: dial_raw(end, port) or_return null
    if os.speaks[P](channel) {
        return os.Channel[P].{end = channel}
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](channel))
    return null
}

/**
 * Dial a connector for a connection of whatever protocol it's for, trying again while what it reaches is restarting:
 * for one who passes it on, as a supervisor serving connectors of its own to what another serves does.
 *
 * It waits for each answer, and RETRY_NANOSECONDS between tries, on a port of its own made for each wait, at most
 * TRIES of them.
 *
 * @param end The connector, kept by the caller.
 * @param port A port bound to end, waited on for each answer and while end's ring is full.
 * @return The new connection, unchecked, the caller's to keep and close; null if the Dial couldn't be sent, the
 *     connector's gone or answered Unsupported, a port to wait on couldn't be made, or it was Unavailable for every
 *     try.
 */
dial_raw :: fn(end: slop_os.Channel, port: slop_os.Port) -> slop_os.Channel? {
    for try in 0..<TRIES {
        out := os.Outgoing.{}
        request :: os.begin[Request](&out)
        request^ = .Dial
        if send_request(end, port, &out) != null {
            return null
        }
        into := os.Incoming.{}
        loop {
            match receive_response(end, port, &into, true) {
                case Received => break
                case Failed(error) => return null
                case _ => return null
            }
        }
        match os.message_of[Response](&into)^ {
            case Dialed(channel) => return channel
            case Unavailable => {
                deadline :: (slop_os.clock_monotonic() or_else 0) + RETRY_NANOSECONDS
                packets : slop_os.Packet[1]
                waiter :: slop_os.port_create(slop_os.startup_block().budget) or_return null
                _ = slop_os.port_wait(waiter, packets, deadline)
                _ = slop_os.handle_close(cast[slop_os.Handle](waiter))
            }
            case Unsupported => return null
        }
    }
    return null
}
