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

/**
 * The volume protocol, for the channel between the storage manager and each volume server it started: the storage
 * manager sends the requests, and the volume server answers them.
 */
Volume :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the volume server, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "volume", major_version = 1, lending = .Server}

/** A grant's ticket, from its Claim, and the volume the link is for, by its container and ID. */
IssueTo :: struct {
    /** The ticket from the grant's Claim, which this volume's server gave the grant's holder; taken only once. */
    ticket : u8[32],
    /** The ID of the container the volume the link is for is in, 16 bytes as the storage service names it. */
    recipient_container : u8[16],
    /** The ID, within its container, of the volume the link is for, which the storage manager vouches is asking. */
    recipient : u64,
}

/** What a link issued under number leads to opened, for the volume holding it, and a path beneath it. */
OpenIssued :: struct {
    /** The number the link was issued under, in this volume, as Issued said. */
    number : u64,
    /** The ID of the container of the volume holding the link, checked against the one it was issued to. */
    recipient_container : u8[16],
    /** The ID, within its container, of the volume holding the link, checked against the one it was issued to. */
    recipient : u64,
    /**
     * The path beneath what the link leads to, as UTF-8, at most files.PATH_BYTES, or InvalidPath; empty for what it
     * leads to itself.
     */
    path : slop_os.Relative[u8],
    /** How it's opened, as the request that reached the link asked. */
    opening : links.Opening,
}

/** What the storage manager asks a volume server. */
Request :: union {
    /**
     * Unwrap the volume's key with this passphrase, its bytes: the first time, to serve it, the volume server waiting
     * for it before it serves anything; after that, to check it's the one. A volume made with nothing in it yet has
     * its keys made and wrapped with it. Answered with Unlocked, or WrongKey; Failed if the keys couldn't be made or
     * checked; NotEncrypted, once it's serving, for a volume that isn't encrypted.
     */
    Unlock(slop_os.Relative[u8]),
    /**
     * Start a new key generation, which seals what's written from now on (decisions/0042), committing what's changed
     * first. Answered with Rotated, NotEncrypted, or Failed, which it is too before the volume's unlocked and for a
     * read-only volume.
     */
    Rotate,
    /**
     * Give the volume a new volume key, wrapped by this passphrase, its bytes, in place of every way it was wrapped
     * before, every generation's key wrapped again by it and a new generation started (decisions/0181's F5); what's
     * changed is committed first, and the new key is committed before it's answered. What was written before is sealed
     * again with the new generation in the background, and the generations before it deleted once nothing needs them.
     * Answered with Rotated and the new generation, NotEncrypted, or Failed, which it is too before the volume's
     * unlocked, for a read-only volume, and for a clone.
     */
    Rekey(slop_os.Relative[u8]),
    /**
     * Commit what's changed now, as before a snapshot of it is taken. Answered with Committed, nothing to commit or a
     * read-only volume included, or Failed, which it is too before the volume's unlocked.
     */
    Commit,
    /**
     * Issue a grant this volume gave, claimed by another volume's server, to that volume, durably before it's
     * answered. Answered with Issued, or Refused: NotFound for a ticket not given or already issued, ReadOnly for a
     * read-only volume, Unavailable before it's unlocked. Failed if the issue couldn't be committed.
     */
    IssueTo(IssueTo),
    /**
     * Open what a link issued from here leads to, and a path beneath it, for the volume holding it; what's opened is
     * linked, so nothing opened from it grants, links or follows links. Answered with the Opened response its
     * opening's kind asks for, or Refused.
     */
    OpenIssued(OpenIssued),
}

/** What a volume server answers. */
Response :: union {
    /** Unlock's answer when the passphrase unwraps the volume's key: the volume is served, or was already. */
    Unlocked,
    /** Unlock's answer when the passphrase doesn't unwrap the volume's key; another may be tried. */
    WrongKey,
    /** Rotate's answer: the generation now sealing what's written, numbered after the newest there was. */
    Rotated(u32),
    /** Commit's answer: what had changed is committed, or nothing had. */
    Committed,
    /** Unlock's or Rotate's answer when the volume isn't encrypted. */
    NotEncrypted,
    /**
     * The answer when what it needed couldn't be read, written or committed, or when what's asked can't be done
     * before the volume is unlocked or on a read-only volume.
     */
    Failed,
    /**
     * The answer to a request the volume server doesn't know, as from a newer storage manager; every protocol has it.
     */
    Unsupported,
    /** IssueTo's answer: the number the link is issued under, durable, for the holding volume to keep. */
    Issued(u64),
    /** OpenIssued's answer for a File: a connection to it, which moves to the storage manager to pass on. */
    OpenedFile(os.Channel[file.File]),
    /** OpenIssued's answer for a ReadOnlyFile: a connection to it, which moves to the storage manager. */
    OpenedReadOnlyFile(os.Channel[read_only_file.ReadOnlyFile]),
    /** OpenIssued's answer for a Directory: a connection to it, which moves to the storage manager. */
    OpenedDirectory(os.Channel[dir.Dir]),
    /** OpenIssued's answer for a ReadOnlyDirectory: a connection to it, which moves to the storage manager. */
    OpenedReadOnlyDirectory(os.Channel[read_only_dir.ReadOnlyDir]),
    /**
     * IssueTo's or OpenIssued's answer when it's refused: no such grant, a link revoked or never issued to that
     * volume (Revoked), writing through a link issued only to read (ReadOnly), or what it leads to can't be opened
     * as asked, with the error opening it gave.
     */
    Refused(files.FileError),
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for Unlock, which checks the passphrase again, Commit, and OpenIssued, except for a File that has to be
 *     new; false for Rotate, which starts another generation each time, and IssueTo, whose ticket is taken once.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Unlock(_) => true
        case Rotate => false
        case Rekey(_) => false
        case Commit => true
        case IssueTo(_) => false
        case OpenIssued(opening) => opening.opening.kind != .File || opening.opening.creation != .New
    }
}

#insert os.protocol_code(Request, Response)
