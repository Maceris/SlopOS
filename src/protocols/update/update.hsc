package update

import os from "std"
import slop_os from "std/os"
import bundle from "../../bundle"

/*
 * The update service's protocol (roadmap 9d3, decisions/0113, 0116): the supervisor tells it, once each boot is
 * assessed, which generation booted and whether it's healthy; it answers once it's acted on it, a tentative generation
 * made permanent or rolled back, a staged update installed, and what isn't kept collected. And the substitution policy
 * the config store asks for (decisions/0123, 0125): checked, and if it's not the newest generation's, the booted
 * generation staged again with it, booted next.
 */

Update :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "update", major_version = 1, lending = .Server}

// A connection's rings, which a Substitute's policy needs more than the default's for
RING_BYTES : u32 : 4096

// A boot's assessment: the generation it booted (0 for none, as from an ISO), and whether it's healthy.
Booted :: struct {
    generation : u64,
    healthy : bool,
}

// A substitution policy asked for, and the generation booted, which a generation with it is a copy of.
SubstituteOf :: struct {
    generation : u64,
    policy : bundle.Substitutions,
}

Request :: union {
    Booted(Booted),
    Substitute(SubstituteOf),
}

// A generation installed that changes only services, applied live (decisions/0126): its number and its store root.
LiveOf :: struct {
    generation : u64,
    store_root : bundle.Hash,
}

Response :: union {
    Done,
    // To Booted: a staged generation installed whose kernel, boot set and command line are the booted one's, for the
    // supervisor to apply live, restarting the services whose bundles changed, then telling Booted of it
    Live(LiveOf),
    // A generation staged with the policy, by its number: tentative, the default for the next boot
    Staged(u64),
    // A policy whose entries don't all pass the check, or a generation that can't be staged
    Refused,
    Unsupported,
}

// Told again, it finds nothing more to do.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

#assert cast[u32](size_of(Request)) <= slop_os.channel_max_payload(RING_BYTES)

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
