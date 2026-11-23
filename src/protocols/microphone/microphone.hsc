package microphone

import os from "std:os"
import slop_os from "std:os/slop_os"
import sound from "../sound"

/*
 * The microphone's control (decisions/0196, 17f): what the trusted path, the terminal service and the GUI's greeter,
 * asks of the audio service once the user has let a program record. Grant makes a sound connection that may record, for
 * the trusted path to give the program through its powerbox; no other sound connection can. Each grant has an id, by
 * which the trusted path takes it back (Revoke), the connection's server end closed (revocation by destruction,
 * decisions/0010), and hears when it's gone, whether taken back or let go (WaitReleased): the microphone is held while
 * a grant is, which the trusted path shows.
 *
 * Only the supervisor makes these connections (power's MicrophoneConnection), for the trusted path's own power
 * connections.
 */

/**
 * The microphone protocol, for the channels between the audio service and the trusted path, and its listener: the
 * trusted path sends the requests, and the service answers them.
 */
Microphone :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the audio service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "microphone", major_version = 1, lending = .Server}

/** The bytes of a connection's channel's ring: a grant's answer and a released one for each client the service has. */
RING_BYTES : u32 : 4096

/** A grant: its id, and the program's end of a sound connection that may record. */
Granted :: struct {
    /** The grant's id, never reused while the service runs: what Revoke and WaitReleased take. */
    id : u32,
    /** The sound connection's client end, which moves to the trusted path, for the program; it may record, not play. */
    end : os.Channel[sound.Sound],
}

/** Why a request was refused. */
Refused :: enum #backed_by(u8) {
    /** The service has no sound device, or the device has nothing to record from. */
    NoInput = 1,
    /** The service has no room for another connection, or no memory for its channel. */
    Full = 2,
    /** No grant has that id: it was never made, or it's gone already. */
    NoGrant = 3,
}

/** What the audio service is asked about the microphone. */
Request :: union {
    /** Make a grant: a sound connection that may record. Answered with Granted, or Refused. */
    Grant,
    /**
     * Take a grant back: its connection's server end closed, which the program sees as its peer gone, what it was
     * recording dropped. Answered with Revoked, or Refused(NoGrant); a WaitReleased for it is answered first.
     */
    Revoke(u32),
    /**
     * Hear when a grant's gone, taken back or its connection closed by the program. Answered with Released then, at
     * once if it's gone already; another WaitReleased for the same grant replaces the first, which is answered Released.
     */
    WaitReleased(u32),
    /**
     * Have the service serve another of the trusted path's connections, on the end given, which moves to the service.
     * Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Microphone]),
}

/** What the audio service answers. */
Response :: union {
    /** Grant's answer. */
    Granted(Granted),
    /** Revoke's answer: the grant's connection is closed. */
    Revoked,
    /** WaitReleased's answer: the grant, by its id, is gone. */
    Released(u32),
    /** Grant's, Revoke's or WaitReleased's answer when they're refused. */
    Refused(Refused),
    /** The answer to a request the service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Grant, which would make a second grant; true for the rest.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Grant => false
        case Revoke(_) => true
        case WaitReleased(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the audio service's microphone: a channel for the protocol, one end sent to it in a Connect.
 *
 * @param end The service's microphone listener, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection; null if it couldn't be made, both ends closed.
 */
connect :: fn(end : slop_os.Channel, port : slop_os.Port, budget : slop_os.MemoryBudget) -> os.Channel[Microphone]? {
    pair :: os.channel_for[Microphone](budget, RING_BYTES) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Microphone].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Microphone].{end = pair.b}
    }
}
