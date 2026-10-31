package update

import os from "std"
import slop_os from "std/os"

/*
 * The update service's protocol (roadmap 9d3, decisions/0113, 0116): the supervisor tells it, once each boot is
 * assessed, which generation booted and whether it's healthy; it answers once it's acted on it, a tentative generation
 * made permanent or rolled back, a staged update installed, and what isn't kept collected.
 */

Update :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "update", major_version = 1, lending = .Server}

// A boot's assessment: the generation it booted (0 for none, as from an ISO), and whether it's healthy.
Booted :: struct {
    generation : u64,
    healthy : bool,
}

Request :: union {
    Booted(Booted),
}

Response :: union {
    Done,
    Unsupported,
}

// Told again, it finds nothing more to do.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

// A request through end, and its answer, waited for on port; Unsupported if the connection's gone.
ask :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> Response {
    if send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match receive_response(end, port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
    return os.message_of[Response](into)^
}
