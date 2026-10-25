package connector

import os from "std"
import slop_os from "std/os"

/*
 * A connector (decisions/0017, 0077): what a client holds in place of a connection to a service that may be restarted.
 * Dial gives a new connection to whichever process serves it now, which the client keeps until its other end goes,
 * then dials again. The supervisor serves every connector, one channel each, so which service a connector reaches is
 * which channel the client was given; dial checks the connection speaks the protocol the client expects.
 */

Connector :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "connector", major_version = 1, lending = .Server}

Request :: union {
    Dial,
}

Response :: union {
    // A connection, of the protocol the connector is for
    Dialed(slop_os.Channel),
    // Nothing serves it now, as while it's restarting: dial again later
    Unavailable,
    Unsupported,
}

// Dialing again gives another connection, which is as good.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Dial => true
    }
}

#insert os.protocol_code(Request, Response)

// How long dial waits between tries while what it reaches is unavailable, and how many it makes.
RETRY_NANOSECONDS : u64 : 100_000_000
TRIES :: 50

/*
 * A connection of protocol P through the connector at end, trying again while what it reaches is restarting; null if it
 * never answers with one, or with one that doesn't speak P.
 */
dial :: fn[P](end: slop_os.Channel, port: slop_os.Port) -> os.Channel[P]? {
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
                case _ => continue
            }
        }
        match os.message_of[Response](&into)^ {
            case Dialed(channel) => {
                if os.speaks[P](channel) {
                    return os.Channel[P].{end = channel}
                }
                _ = slop_os.handle_close(cast[slop_os.Handle](channel))
                return null
            }
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
