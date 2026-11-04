package rng

import os from "std"
import slop_os from "std/os"

/*
 * The device class of hardware random number generators (decisions/0074), which the entropy service reseeds from: a
 * driver offers its channel to the entropy service with entropy.AddSource, and answers Reads with the device's bytes.
 */

/**
 * The rng protocol, for the channel between the entropy service and a hardware RNG's driver: the entropy service
 * sends the requests, and the driver answers them.
 */
Rng :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the driver, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "rng", major_version = 1, lending = .Server}

/** The most bytes one Bytes has, and so the most one Read is answered with: 256. */
MAX_BYTES :: 256

/** What the entropy service asks a hardware RNG's driver. */
Request :: union {
    /**
     * Ask for the given count of bytes from the device; a count over MAX_BYTES is taken as MAX_BYTES. Answered with
     * Bytes.
     */
    Read(u32),
}

/** What a hardware RNG's driver answers. */
Response :: union {
    /**
     * The answer to Read: as many bytes as the device gave, at most what was asked and MAX_BYTES, and fewer, even
     * none, when the device doesn't fill its buffer in time.
     */
    Bytes(slop_os.Relative[u8]),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for Read: reading again reads other bytes, which are as good.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => true
    }
}

#insert os.protocol_code(Request, Response)
