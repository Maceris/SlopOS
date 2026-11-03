package prompt

import os from "std"
import slop_os from "std/os"
import read_only_dir from "std/os/slop_os"

/**
 * What a session's powerbox asks the trusted path (decisions/0156): Ask, a request of one of the session's programs, for
 * the user to answer. The terminal service shows it on the status line until the secure attention key opens the chooser,
 * which lists the home given, read only; it's answered once the user has chosen (a path beneath the home, and whether
 * it's a new file to make) or refused. One Ask waits at a time. An Ask that may be kept offers "keep for next time",
 * and the Choice says whether the user ticked it (decisions/0158). An Ask for an account is answered on the trusted
 * path's own screen, which asks for the administrator's password and the new account's, with the account made.
 */
Prompt :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "prompt", major_version = 1, lending = .Server}

Kind :: enum #backed_by(u32) {
    File = 1,
    Directory = 2,
    /** Another account, which elevation makes */
    Account = 3,
}

Ask :: struct {
    // The program asking, by the name the session manager gave it, and why, in its words
    requester : slop_os.Relative[u8],
    purpose : slop_os.Relative[u8],
    // A file's suggested name, which the chooser's filter starts with
    suggested : slop_os.Relative[u8],
    kind : Kind,
    write : bool,
    // Whether the program asked to keep it
    keep : bool,
    home : os.Channel[read_only_dir.ReadOnlyDir],
}

/** What the user chose: a path beneath the home, whether it's a new file, and whether to keep it. */
Choice :: struct {
    path : slop_os.Relative[u8],
    new : bool,
    keep : bool,
}

Request :: union {
    Ask(Ask),
}

Response :: union {
    Chosen(Choice),
    /** An Ask for an account answered: the account made, by its name */
    AccountMade(slop_os.Relative[u8]),
    Refused,
    Unsupported,
}

is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Ask(_) => false
    }
}

#insert os.protocol_code(Request, Response)
