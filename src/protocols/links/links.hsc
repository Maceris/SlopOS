package links

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import grant from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"

/*
 * Stored links between volumes (roadmap 8f, design/security.md §8): what a volume server asks the storage manager,
 * which gives each its own connection and so knows which volume asks. Issue has a grant claimed from another volume
 * issued to this one, as the link it's about to keep; Resolve opens what a link leads to, and a path beneath it, as the
 * request that reached the link asked. The storage manager asks the volume the link leads into (the volume protocol),
 * which checks what it issued and opens it; a link leads only into a volume being served, and never into its own.
 *
 * A volume server sends these and goes on serving, and the answers come in the order asked: so a volume server never
 * waits on the storage manager, which can wait on any of them.
 */

/**
 * The links protocol, for the channel between each volume server and the storage manager: the volume server sends
 * the requests, and the storage manager answers them, in the order they were sent.
 */
Links :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the storage manager, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "links", major_version = 1, lending = .Server}

/** What a path through a link is opened as: what the request that reached the link asked for. */
OpenKind :: enum #backed_by(u32) {
    /** A file, to read and write; refused when the link was issued only to read. */
    File = 1,
    /** A file, to read only. */
    ReadOnlyFile = 2,
    /** A directory, to read and change; refused when the link was issued only to read. */
    Directory = 3,
    /** A directory, to read only. */
    ReadOnlyDirectory = 4,
}

/** How a path through a link is opened: what as, a file's creation, and whether a directory is made. */
Opening :: struct {
    /** What it's opened as, which says which of the Opened responses answers it. */
    kind : OpenKind,
    /**
     * For a File, whether it has to exist, has to be new, or may be either, and whether it's emptied; ignored for the
     * other kinds, which open only what's there.
     */
    creation : files.Creation,
    /** For a Directory, whether it's made when it isn't there; ignored for the other kinds. */
    create : bool,
}

/** A link, by the volume it leads into and its number there, and the path to open beneath what it leads to. */
Resolving :: struct {
    /** The ID of the container the volume the link leads into is in, 16 bytes as the storage service names it. */
    container : u8[16],
    /** The ID, within its container, of the volume the link leads into. */
    volume : u64,
    /** The number the link was issued under in that volume, as Issued said. */
    number : u64,
    /**
     * The path beneath what the link leads to, as UTF-8, at most files.PATH_BYTES; empty for what it leads to
     * itself.
     */
    path : slop_os.Relative[u8],
    /** How it's opened. */
    opening : Opening,
}

/** What a volume server asks the storage manager. */
Request :: union {
    /**
     * Have a grant, claimed from another volume's server, issued to the asking volume, as the link it's about to keep.
     * The storage manager passes the claim's ticket to the server of the volume it's from, which records the issue
     * durably. Answered with Issued, or Failed.
     */
    Issue(grant.Claim),
    /**
     * Open what a link the asking volume holds leads to, and a path beneath it, by the volume it leads into. Answered
     * with the Opened response its opening's kind asks for, or Failed.
     */
    Resolve(Resolving),
}

/** What the storage manager answers. */
Response :: union {
    /** Issue's answer: the number the link is issued under, in the volume it leads into, for the link to keep. */
    Issued(u64),
    /** Resolve's answer for a File: a connection to it, which moves to the volume server to pass to its client. */
    OpenedFile(os.Channel[file.File]),
    /** Resolve's answer for a ReadOnlyFile: a connection to it, which moves to the volume server. */
    OpenedReadOnlyFile(os.Channel[read_only_file.ReadOnlyFile]),
    /** Resolve's answer for a Directory: a connection to it, which moves to the volume server. */
    OpenedDirectory(os.Channel[dir.Dir]),
    /** Resolve's answer for a ReadOnlyDirectory: a connection to it, which moves to the volume server. */
    OpenedReadOnlyDirectory(os.Channel[read_only_dir.ReadOnlyDir]),
    /**
     * Issue's or Resolve's answer when it couldn't be done: Unavailable when the volume it leads into isn't being
     * served writable and unlocked, or didn't answer; otherwise what that volume's server refused with, like Revoked
     * for a link not issued to the asking volume, or not any more, NotFound for a ticket it didn't give, or ReadOnly
     * for writing through a link issued only to read.
     */
    Failed(files.FileError),
    /**
     * The answer to a request the storage manager doesn't know, as from a newer volume server; every protocol has it.
     */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Issue, which issues a link each time; true for Resolve, which opens again, except a File that has
 *     to be new, which the first open made.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Issue(_) => false
        case Resolve(resolving) => resolving.opening.kind != .File || resolving.opening.creation != .New
    }
}

#insert os.protocol_code(Request, Response)
