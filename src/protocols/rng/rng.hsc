package rng

import os from "std"
import slop_os from "std/os"

/*
 * The device class of hardware random number generators (decisions/0074), which the entropy service reseeds from: a
 * driver offers its channel to the entropy service with entropy.AddSource, and answers Reads with the device's bytes.
 */

Rng :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "rng", major_version = 1, lending = .Server}

// The most bytes one Bytes has.
MAX_BYTES :: 256

Request :: union {
    // count bytes from the device, up to MAX_BYTES
    Read(u32),
}

Response :: union {
    // As many as the device gave, which may be fewer
    Bytes(slop_os.Relative[u8]),
    Unsupported,
}

// Reading again reads other bytes, which is as good.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => true
    }
}

#insert os.protocol_code(Request, Response)
