package powerbox

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"

/**
 * What a session's programs ask of its powerbox (decisions/0018, 0156, design/console-and-sessions.md §5). Each program
 * has a connection of its own, which the session manager has the powerbox serve under the program's name (Serve, on its
 * own connection only), so the user's told which program asks. RequestFile and RequestDirectory say why, in the
 * program's words, and whether it would write; the user chooses on the trusted path, and the answer is a connection to
 * what they chose, read only unless writing was asked for, or Refused. A program has one request waiting at a time:
 * another is answered Busy.
 *
 * A request may ask to be kept under a key of the program's (decisions/0158): if the user ticks "keep for next time",
 * the powerbox keeps the grant as a stored link in the session's home, which Reopen with the key opens again, without
 * asking, until the user revokes it.
 *
 * Elevation (decisions/0158): RequestAccount asks for another account to be made, which the administrator allows on
 * the trusted path, with their password, then the new account's name and password, typed there and never seen by the
 * program; it's answered with the new account's name.
 */
Powerbox :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "powerbox", major_version = 1, lending = .Server}

// The most bytes of a purpose, a suggested name and a program's name, and of a kept grant's key
PURPOSE_BYTES :: 96
NAME_BYTES :: 64
KEY_BYTES :: 32

Kind :: enum #backed_by(u32) {
    File = 1,
    Directory = 2,
}

/**
 * A file asked for: why, the name it suggests for a new one, which the chooser starts with, whether it would write, and
 * the key to keep it under if the user lets it, empty to not ask.
 */
FileRequest :: struct {
    purpose : slop_os.Relative[u8],
    suggested : slop_os.Relative[u8],
    write : bool,
    keep : slop_os.Relative[u8],
}

/** A directory asked for: why, whether it would write in it, and the key to keep it under, empty to not ask. */
DirectoryRequest :: struct {
    purpose : slop_os.Relative[u8],
    write : bool,
    keep : slop_os.Relative[u8],
}

/** A kept grant asked for again: its key, and what it's opened as. */
Reopening :: struct {
    key : slop_os.Relative[u8],
    kind : Kind,
    write : bool,
}

/** Another account asked for, and why. */
AccountRequest :: struct {
    purpose : slop_os.Relative[u8],
}

/** A program of the session's, to serve on its end under its name. */
Served :: struct {
    name : slop_os.Relative[u8],
    end : os.Channel[Powerbox],
}

Request :: union {
    RequestFile(FileRequest),
    RequestDirectory(DirectoryRequest),
    Reopen(Reopening),
    RequestAccount(AccountRequest),
    /** The session manager's: another program to serve */
    Serve(Served),
}

Response :: union {
    GrantedFile(os.Channel[file.File]),
    GrantedReadOnlyFile(os.Channel[read_only_file.ReadOnlyFile]),
    GrantedDirectory(os.Channel[dir.Dir]),
    GrantedReadOnlyDirectory(os.Channel[read_only_dir.ReadOnlyDir]),
    /** The user refused, or what they chose couldn't be opened */
    Refused,
    /** This program's request before is still waiting */
    Busy,
    /** Serve's answer */
    Done,
    /** RequestAccount's: the account made, by its name */
    AccountMade(slop_os.Relative[u8]),
    Unsupported,
}

/** Asking again would ask the user again. */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case RequestFile(_) => false
        case RequestDirectory(_) => false
        // A kept grant opened again gives another connection to it
        case Reopen(_) => true
        case RequestAccount(_) => false
        case Serve(_) => false
    }
}

#insert os.protocol_code(Request, Response)
