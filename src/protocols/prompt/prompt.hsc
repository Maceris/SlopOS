package prompt

import os from "std"
import slop_os from "std/os"
import trace from "../trace"
import events from "../events"
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
 *
 * An account's public keys (decisions/0191, 14c): an Ask to add a key (its line as suggested) or remove one (its
 * fingerprint as suggested) is confirmed on the trusted path's own screen, which has the account service do it for the
 * session's user, answered Allowed once it's done; an Ask to list them is answered at once, with KeysListed.
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
    /** The system shut down, which elevation allows (decisions/0182). */
    ShutDown = 4,
    /** The system restarted, which elevation allows. */
    Restart = 5,
    /**
     * A program of the session's debugged, named by suggested (decisions/0185, 12f): the user allows it, with no
     * password, as it's their own program.
     */
    Debug = 6,
    /** A program of another user's session debugged, named by suggested, which elevation allows. */
    DebugOther = 7,
    /** The whole system traced (decisions/0185, 12g), which elevation allows: a trace connection to the supervisor. */
    Trace = 8,
    /** The system's log read (decisions/0185, 12g), which elevation allows: an events connection. */
    SystemLog = 9,
    /**
     * A network connection allowing more than the session's own (decisions/0188, 13c), what it allows described by
     * suggested: the user allows it, with no password, as it's their own program. Answered Allowed, or Refused.
     */
    Network = 10,
    /** A public key added to the session's user's account, which logs in over SSH: its line is suggested. */
    AddKey = 11,
    /** A public key removed from the session's user's account: its fingerprint is suggested. */
    RemoveKey = 12,
    /** The session's user's public keys listed, answered at once with KeysListed, without asking the user. */
    ListKeys = 13,
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
    /** Ask's answer for a shutdown or a restart: the administrator allowed it, and it's under way. */
    Allowed,
    /** Ask's answer when the user refused, or the account couldn't be made. */
    Refused,
    /** Ask's answer for a trace: the administrator allowed it, and this is a trace connection to the supervisor. */
    TraceGranted(os.Channel[trace.Trace]),
    /** Ask's answer for the system's log: the administrator allowed it, and this is an events connection. */
    LogGranted(os.Channel[events.Events]),
    /** Ask's answer for ListKeys: the session's user's keys, a line each, each ended by a line break. */
    KeysListed(slop_os.Relative[u8]),
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
