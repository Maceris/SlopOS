package prompt

import os from "std"
import slop_os from "std/os"
import read_only_dir from "std/os/slop_os"

/**
 * The prompt protocol, for the channel between a session's powerbox and the trusted path, the terminal service: the
 * powerbox sends the requests, and the terminal service answers them once the user has.
 *
 * What a session's powerbox asks the trusted path (decisions/0156) is Ask, a request of one of the session's
 * programs, for the user to answer. The terminal service shows it on the status line until the secure attention key
 * opens the chooser, which lists the home given, read only; it's answered once the user has chosen (a path beneath the
 * home, and whether it's a new file to make) or refused. One Ask waits at a time. An Ask that may be kept offers "keep
 * for next time", and the Choice says whether the user ticked it (decisions/0158). An Ask for an account is answered
 * on the trusted path's own screen, which asks for the administrator's password and the new account's, with the
 * account made.
 */
Prompt :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the terminal service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "prompt", major_version = 1, lending = .Server}

/** What a program asks the user for. */
Kind :: enum #backed_by(u32) {
    /** A file, chosen in the home, or named there to be made. */
    File = 1,
    /** A directory, chosen in the home. */
    Directory = 2,
    /** Another account, which elevation makes. */
    Account = 3,
}

/** A request of one of the session's programs, for the user to answer. */
Ask :: struct {
    /**
     * The program asking, by the name the session manager gave it, as UTF-8, shown to the user; the terminal service
     * keeps as much of it as its buffer holds.
     */
    requester : slop_os.Relative[u8],
    /** Why the program asks, in its own words, as UTF-8, shown to the user. */
    purpose : slop_os.Relative[u8],
    /** For a file, its suggested name, as UTF-8, which the chooser's filter starts with; may be empty. */
    suggested : slop_os.Relative[u8],
    /** What the program asks for. */
    kind : Kind,
    /** Whether the program would write what it's given, not only read it. */
    write : bool,
    /** Whether the program asked to keep what it's given, so the chooser offers "keep for next time". */
    keep : bool,
    /**
     * The session's home, narrowed and read-only, which the chooser lists; the handle moves to the terminal service,
     * which closes it once the Ask is answered.
     */
    home : os.Channel[read_only_dir.ReadOnlyDir],
}

/** What the user chose: a path beneath the home, whether it's a new file, and whether to keep it. */
Choice :: struct {
    /** The path chosen, beneath the home, as UTF-8; empty for the home itself. */
    path : slop_os.Relative[u8],
    /** Whether path names a new file, for the program to make, rather than one that's there. */
    new : bool,
    /** Whether the user ticked "keep for next time", which they can only when the Ask's keep was set. */
    keep : bool,
}

/** What a session's powerbox asks the trusted path. */
Request :: union {
    /**
     * Ask the user for a file, a directory, or a new account, for a program. Answered once the user has: with
     * Chosen, AccountMade for an account, or Refused. One waits at a time.
     */
    Ask(Ask),
}

/** What the trusted path answers. */
Response :: union {
    /** Ask's answer for a file or a directory: what the user chose. */
    Chosen(Choice),
    /** Ask's answer for an account: the account made, by its name, as UTF-8. */
    AccountMade(slop_os.Relative[u8]),
    /** Ask's answer when the user refused, or the account couldn't be made. */
    Refused,
    /** The answer to a request the trusted path doesn't know, as from a newer powerbox; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Ask, which asks the user again, and whose home was given away.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Ask(_) => false
    }
}

#insert os.protocol_code(Request, Response)
