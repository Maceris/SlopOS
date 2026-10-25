package entropy

import os from "std"
import slop_os from "std/os"
import rng from "../rng"

/*
 * The entropy service's protocol (decisions/0058, 0067, 0071, 0074): random bytes for the services that need more than
 * their own seed. Connections arrive on its listener as Connects, and hardware RNGs' drivers offer themselves with
 * AddSource.
 */

Entropy :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "entropy", major_version = 1, lending = .Server}

// The most bytes one Filled has.
MAX_BYTES :: 256

Request :: union {
    // count random bytes, up to MAX_BYTES
    Fill(u32),
    // Serve another client, on its end
    Connect(os.Channel[Entropy]),
    // Reseed from a hardware RNG, through its driver; answered with nothing
    AddSource(os.Channel[rng.Rng]),
}

Response :: union {
    Filled(slop_os.Relative[u8]),
    Unsupported,
}

// Asking again gives other bytes, which is as good.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Fill(_) => true
        case Connect(_) => true
        case AddSource(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/*
 * A new connection to the service listening on end: a channel for Entropy, one end sent in a Connect, the other given
 * back, or null.
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
