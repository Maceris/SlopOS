package bundle_store

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import bundle from "../../bundle"

/*
 * The bundle store's protocol (roadmap 9b, decisions/0094, design/software.md §2): objects by their BLAKE3-256 hashes.
 * Get gives an object as paged memory, read-only, which the store pages in as it's touched, one memory object per
 * object however many ask for it; Put takes one from memory given, kept only if its bytes have the hash given. Roots
 * keep objects, and what bundles and roots they are refer to, from Collect, which removes everything else: the boot
 * root, and pins by name. Connections arrive on its listener, and as Connects. The pages it has supplied are a cache
 * it gives back under pressure on its budget (decisions/0111): CacheLimit sets how much of them it keeps, and
 * Evictions says how many it's given back.
 */

BundleStore :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "bundle_store", major_version = 1, lending = .Server}

PutOf :: struct {
    hash : bundle.Hash,
    // Its bytes, the first size of data's
    size : u64,
    data : slop_os.Memory,
}

PinOf :: struct {
    // Letters, digits and underscores
    name : slop_os.Relative[u8],
    hash : bundle.Hash,
}

// An object: read-only paged memory, and how many of its bytes are the object's.
Object :: struct {
    memory : slop_os.Memory,
    size : u64,
}

Request :: union {
    Get(bundle.Hash),
    Put(PutOf),
    Pin(PinOf),
    Unpin(slop_os.Relative[u8]),
    // The boot root's hash, set; the root object itself put first
    SetRoot(bundle.Hash),
    Root,
    // Everything no root reaches removed
    Collect,
    Connect(os.Channel[BundleStore]),
    // The store's directory from now on, the same one served again, as when its volume server was started again
    UseDirectory(os.Channel[dir.Dir]),
    // The most bytes of objects' pages it keeps in memory from now on; 0 for as much as its budget's threshold allows
    CacheLimit(u64),
    // How many pages it's given back, as Collected
    Evictions,
}

Response :: union {
    Got(Object),
    Done,
    Rooted(bundle.Hash),
    // How many objects Collect removed
    Collected(u64),
    // No object, pin or root by that
    Missing,
    // Bytes that don't have the hash given, a name that isn't one, or the store couldn't write it
    Refused,
    Unsupported,
}

// Putting, pinning or collecting again changes nothing more.
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
