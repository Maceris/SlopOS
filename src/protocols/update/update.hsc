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

/**
 * The update protocol, for the channel between the supervisor and the update service: the supervisor sends the
 * requests, and the update service answers them.
 */
Update :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the update service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "update", major_version = 1, lending = .Server}

/**
 * The bytes of a connection's rings, 4096, which a Substitute's policy needs more than the default's for; a channel
 * for the protocol is made with it.
 */
RING_BYTES : u32 : 4096

/** A boot's assessment: the generation it booted (0 for none, as from an ISO), and whether it's healthy. */
Booted :: struct {
    /** The generation's number, 0 for a boot of no generation, as from an ISO. */
    generation : u64,
    /** Whether every service the system needs came up, which makes a tentative generation permanent. */
    healthy : bool,
}

/** A substitution policy asked for, and the generation booted, which a generation with it is a copy of. */
SubstituteOf :: struct {
    /** The number of the generation booted, which the new generation copies. */
    generation : u64,
    /** The substitution policy, its entries each a library to replace and its substitute, by their hashes. */
    policy : bundle.Substitutions,
}

/** What the supervisor asks the update service. */
Request :: union {
    /**
     * Act on a boot's assessment: make a tentative generation that booted healthy permanent, or roll one that didn't
     * back; roll back newer tentative generations with no tries left; install a staged update; and collect what isn't
     * kept. Answered once it's done all that with Live, or Done, whatever failed along the way.
     */
    Booted(Booted),
    /**
     * Stage a generation with a substitution policy (decisions/0123, 0125), a copy of the generation booted, once each
     * entry passes the library check: tentative, and booted next. Answered with Staged, Done when the newest
     * generation has the policy already, or Refused.
     */
    Substitute(SubstituteOf),
}

/** A generation installed that changes only services, applied live (decisions/0126): its number and its store root. */
LiveOf :: struct {
    /** The number of the generation installed. */
    generation : u64,
    /** The hash of its bundle store root, which names the bundles its services run from. */
    store_root : bundle.Hash,
}

/** What the update service answers. */
Response :: union {
    /**
     * Booted's answer when it's acted on it with nothing for the supervisor to do, or Substitute's when the newest
     * generation has the policy already.
     */
    Done,
    /**
     * Booted's answer when the boot was healthy and a staged generation was installed whose kernel, boot set and
     * command line are the booted one's: for the supervisor to apply live, restarting the services whose bundles
     * changed, then telling Booted of it.
     */
    Live(LiveOf),
    /**
     * Substitute's answer: the generation staged with the policy, by its number, after the newest: tentative, with
     * generations.TRIES tries, the default for the next boot.
     */
    Staged(u64),
    /**
     * Substitute's answer for a policy whose entries don't all pass the check, or whose libraries can't be found, or
     * a generation that can't be staged; objects written before it are left for collection.
     */
    Refused,
    /**
     * The answer to a request the update service doesn't know, as from a newer supervisor; every protocol has it,
     * and ask gives it too when the connection's gone.
     */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: told again, the update service finds nothing more to do.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)

#assert cast[u32](size_of(Request)) <= slop_os.channel_max_payload(RING_BYTES)

/**
 * Send a request to the update service and wait for its answer.
 *
 * Responses that aren't one, unknown or invalid, are skipped while it waits.
 *
 * @param end The connection to the update service, kept by the caller.
 * @param port A port bound to end, waited on for the answer and while end's ring is full.
 * @param out The request, begun with os.begin; sent as it is.
 * @param into Where the answer is received, with any handles it brought, which are the caller's from then on.
 * @return The answer, copied out of into; Unsupported if the request couldn't be sent or the connection's gone.
 */
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
