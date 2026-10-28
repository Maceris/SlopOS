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

Links :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "links", major_version = 1, lending = .Server}

// What a path through a link is opened as: what the request that reached the link asked for.
OpenKind :: enum #backed_by(u32) {
    File = 1,
    ReadOnlyFile = 2,
    Directory = 3,
    ReadOnlyDirectory = 4,
}

// How it's opened: a file's creation, and whether a directory is made.
Opening :: struct {
    kind : OpenKind,
    creation : files.Creation,
    create : bool,
}

// A link, by the volume it leads into and its number there, and the path to open beneath what it leads to.
Resolving :: struct {
    container : u8[16],
    volume : u64,
    number : u64,
    path : slop_os.Relative[u8],
    opening : Opening,
}

Request :: union {
    Issue(grant.Claim),
    Resolve(Resolving),
}

Response :: union {
    // The number the link is issued under, in the volume it leads into
    Issued(u64),
    OpenedFile(os.Channel[file.File]),
    OpenedReadOnlyFile(os.Channel[read_only_file.ReadOnlyFile]),
    OpenedDirectory(os.Channel[dir.Dir]),
    OpenedReadOnlyDirectory(os.Channel[read_only_dir.ReadOnlyDir]),
    Failed(files.FileError),
    Unsupported,
}

// Issuing makes a link each time; opening again opens again.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Issue(_) => false
        case Resolve(resolving) => resolving.opening.kind != .File || resolving.opening.creation != .New
    }
}

#insert os.protocol_code(Request, Response)
