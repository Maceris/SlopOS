package volume

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import links from "../links"

/*
 * A volume server's own protocol (roadmap 8e), which only the storage manager that started it speaks: an encrypted
 * volume unlocked with a passphrase, which the volume server waits for before it serves anything, and a new key
 * generation started. The keys stay in the volume server (design/storage.md §2): the storage manager passes the
 * passphrase on and never sees them.
 *
 * Stored links (roadmap 8f): a grant this volume gave, claimed by another volume's server, issued to that volume, and
 * what a link issued from here leads to opened for the volume holding it, which the storage manager vouches for.
 */

Volume :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "volume", major_version = 1, lending = .Server}

// A grant's ticket, from its Claim, and the volume the link is for, by its container and ID.
IssueTo :: struct {
    ticket : u8[32],
    recipient_container : u8[16],
    recipient : u64,
}

// What a link issued under number leads to opened, for the volume holding it, and a path beneath it.
OpenIssued :: struct {
    number : u64,
    recipient_container : u8[16],
    recipient : u64,
    path : slop_os.Relative[u8],
    opening : links.Opening,
}

Request :: union {
    // The volume's key unwrapped with this passphrase: the first time, to serve it; after that, to check it's the one
    Unlock(slop_os.Relative[u8]),
    // A new key generation, which seals what's written from now on (decisions/0042)
    Rotate,
    // What's changed committed now, as before a snapshot of it is taken
    Commit,
    IssueTo(IssueTo),
    OpenIssued(OpenIssued),
}

Response :: union {
    Unlocked,
    // The passphrase doesn't unwrap the volume's key
    WrongKey,
    // The generation now sealing what's written
    Rotated(u32),
    Committed,
    // The volume isn't encrypted
    NotEncrypted,
    // What it needed couldn't be read, written or committed
    Failed,
    Unsupported,
    // The number a link is issued under, durable
    Issued(u64),
    OpenedFile(os.Channel[file.File]),
    OpenedReadOnlyFile(os.Channel[read_only_file.ReadOnlyFile]),
    OpenedDirectory(os.Channel[dir.Dir]),
    OpenedReadOnlyDirectory(os.Channel[read_only_dir.ReadOnlyDir]),
    // No such grant, a link revoked or never issued to that volume, or what it leads to can't be opened as asked
    Refused(files.FileError),
}

// Unlocking again checks the passphrase again; rotating again starts another generation.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Unlock(_) => true
        case Rotate => false
        case Commit => true
        case IssueTo(_) => false
        case OpenIssued(opening) => opening.opening.kind != .File || opening.opening.creation != .New
    }
}

#insert os.protocol_code(Request, Response)
