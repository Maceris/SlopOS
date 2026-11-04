package entropy

import os from "std"
import slop_os from "std/os"
import rng from "../rng"

/*
 * The entropy service's protocol (decisions/0058, 0067, 0071, 0074): random bytes for the services that need more than
 * their own seed. Connections arrive on its listener as Connects, and hardware RNGs' drivers offer themselves with
 * AddSource.
 */

/**
 * The entropy protocol, for the channels between the entropy service and its clients, and its listener: the clients
 * send the requests, and the service answers them.
 */
Entropy :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the entropy service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "entropy", major_version = 1, lending = .Server}

/** The most bytes one Filled has, and so the most one Fill is answered with: 256. */
MAX_BYTES :: 256

/** What a client, or a hardware RNG's driver, asks the entropy service. */
Request :: union {
    /**
     * Ask for the given count of random bytes; a count over MAX_BYTES is taken as MAX_BYTES. Answered at once with
     * Filled.
     */
    Fill(u32),
    /**
     * Have the service serve another client, on the end given, which moves to the service; it's closed if the
     * service already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Entropy]),
    /**
     * Have the service reseed from a hardware RNG, through its driver's end of an rng channel, which moves to the
     * service; past the service's limit of sources it's closed. Answered with nothing: the service reads the source
     * at once, and again as it hands out more bytes.
     */
    AddSource(os.Channel[rng.Rng]),
}

/** What the entropy service answers. */
Response :: union {
    /** The answer to Fill: the bytes asked for, or MAX_BYTES of them when more were, from the service's stream. */
    Filled(slop_os.Relative[u8]),
    /** The answer to a request the service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: a Fill asked again gives other bytes, which are as good.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Fill(_) => true
        case Connect(_) => true
        case AddSource(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the entropy service: a channel for the protocol, one end sent to the service in a Connect.
 *
 * It doesn't wait: the service takes the end when it next serves its listener, or closes it when it's full, which
 * the caller learns of as its end's peer gone.
 *
 * @param end The service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Entropy]? {
    pair :: os.channel_for[Entropy](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Entropy].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Entropy].{end = pair.b}
    }
}
