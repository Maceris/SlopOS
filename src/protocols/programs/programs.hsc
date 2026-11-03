package programs

import os from "std"
import slop_os from "std/os"

/*
 * What a session's shell asks the session manager for (decisions/0170): a program of the bundle store's boot root, by
 * name, its executable, which the shell launches itself, and its manifest, the schema of its entry's type, which says
 * what it takes. Nothing else of the store's: the shell can't put, pin, root or collect.
 */

Programs :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "programs", major_version = 1, lending = .Server}

// The longest name Find takes.
MAX_NAME :: 64

// A program found: its executable and its manifest as read-only memory, and how many of the manifest's bytes are its.
Program :: struct {
    executable : slop_os.Memory,
    manifest : slop_os.Memory,
    manifest_size : u64,
}

Request :: union {
    Find(slop_os.Relative[u8]),
}

Response :: union {
    Found(Program),
    // No program by that name
    Missing,
    Unsupported,
}

// Finding again changes nothing.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)
