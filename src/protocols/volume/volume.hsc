package volume

import os from "std"
import slop_os from "std/os"

/*
 * A volume server's own protocol (roadmap 8e), which only the storage manager that started it speaks: an encrypted
 * volume unlocked with a passphrase, which the volume server waits for before it serves anything, and a new key
 * generation started. The keys stay in the volume server (design/storage.md §2): the storage manager passes the
 * passphrase on and never sees them.
 */

Volume :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "volume", major_version = 1, lending = .Server}

Request :: union {
    // The volume's key unwrapped with this passphrase: the first time, to serve it; after that, to check it's the one
    Unlock(slop_os.Relative[u8]),
    // A new key generation, which seals what's written from now on (decisions/0042)
    Rotate,
}

Response :: union {
    Unlocked,
    // The passphrase doesn't unwrap the volume's key
    WrongKey,
    // The generation now sealing what's written
    Rotated(u32),
    // The volume isn't encrypted
    NotEncrypted,
    // What it needed couldn't be read, written or committed
    Failed,
    Unsupported,
}

// Unlocking again checks the passphrase again; rotating again starts another generation.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Unlock(_) => true
        case Rotate => false
    }
}

#insert os.protocol_code(Request, Response)
