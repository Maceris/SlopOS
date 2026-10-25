package serial

import os from "std"
import slop_os from "std/os"

/*
 * The device class of byte streams (decisions/0075): a serial line, or a console that's one, like virtio-console. A
 * Read is held by the driver until at least one byte has arrived, so a client waits on its port. Connections arrive on
 * the driver's listener as Connects.
 */

Serial :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "serial", major_version = 1, lending = .Server}

// The most bytes one Write or Data has, so a message fits the default 1 KiB ring.
MAX_BYTES :: 256

Request :: union {
    // Bytes to send, up to MAX_BYTES
    Write(slop_os.Relative[u8]),
    // Up to max bytes that have arrived, answered once there's at least one
    Read(u32),
    // What the line is
    Features,
    // Serve another client, on its end
    Connect(os.Channel[Serial]),
}

Response :: union {
    // How many of the bytes were taken
    Written(u32),
    Data(slop_os.Relative[u8]),
    // Its speed in bits a second, 0 for a line without one, like a virtual console
    Line(u32),
    Unsupported,
}

// Sending the same bytes again sends them twice.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Write(_) => false
        case Read(_) => false
        case Features => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the driver listening on end, or null (as entropy.connect).
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
