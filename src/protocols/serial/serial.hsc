package serial

import os from "std"
import slop_os from "std/os"

/*
 * The device class of byte streams (decisions/0075): a serial line, or a console that's one, like virtio-console. A
 * Read is held by the driver until at least one byte has arrived, so a client waits on its port. Connections arrive on
 * the driver's listener as Connects.
 */

/**
 * The serial protocol, for the channels between a byte stream's driver and its clients, and its listener: the clients
 * send the requests, and the driver answers them.
 */
Serial :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the driver, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "serial", major_version = 1, lending = .Server}

/** The most bytes one Write or Data has, 256, so a message fits the default 1 KiB ring. */
MAX_BYTES :: 256

/** What a client asks a byte stream's driver. */
Request :: union {
    /** Send bytes, up to MAX_BYTES, waiting until the device has taken them. Answered with Written. */
    Write(slop_os.Relative[u8]),
    /**
     * Take up to the given count of bytes that have arrived, 0 taken as 1. Held by the driver until at least one
     * byte has, so it may be answered much later; one Read is held for a client at a time, a later one replacing it.
     * Answered with Data.
     */
    Read(u32),
    /** Ask what the line is. Answered with Line. */
    Features,
    /**
     * Have the driver serve another client, on the end given, which moves to the driver; it's closed if the driver
     * already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Serial]),
}

/** What a byte stream's driver answers. */
Response :: union {
    /**
     * Write's answer: how many of the bytes were taken, from the first; fewer than were given when the device
     * stopped taking them.
     */
    Written(u32),
    /**
     * Read's answer: the bytes that had arrived, oldest first, at least one, at most the Read's count and MAX_BYTES.
     */
    Data(slop_os.Relative[u8]),
    /** Features' answer: the line's speed in bits a second, 0 for a line without one, like a virtual console. */
    Line(u32),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Write, which sends the same bytes twice, and Read, which takes bytes another Read would have; true
 *     for Features and Connect.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Write(_) => false
        case Read(_) => false
        case Features => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to a byte stream's driver: a channel for the protocol, one end sent to the driver in a
 * Connect, as entropy.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves its listener, or closes it when it's full, which the
 * caller learns of as its end's peer gone.
 *
 * @param end The driver's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Serial]? {
    pair :: os.channel_for[Serial](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Serial].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Serial].{end = pair.b}
    }
}
