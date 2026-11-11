package powerbox

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import network from "std/os/slop_os"
import trace from "../trace"
import events from "../events"

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
 *
 * The protocol is for the channels between a session's powerbox and the session's programs, and the session manager:
 * they send the requests, and the powerbox answers them.
 */
Powerbox :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the powerbox, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "powerbox", major_version = 1, lending = .Server}

/** The most bytes of a request's purpose: 96. */
PURPOSE_BYTES :: 96
/** The most bytes of a suggested name, and of a program's name: 64. */
NAME_BYTES :: 64
/** The most bytes of a kept grant's key: 32, each a letter, a digit, - or _. */
KEY_BYTES :: 32

/** What a kept grant is opened again as. */
Kind :: enum #backed_by(u32) {
    /** A file. */
    File = 1,
    /** A directory. */
    Directory = 2,
}

/**
 * A file asked for: why, the name it suggests for a new one, which the chooser starts with, whether it would write, and
 * the key to keep it under if the user lets it, empty to not ask.
 */
FileRequest :: struct {
    /** Why the program asks, in its own words, as UTF-8, up to PURPOSE_BYTES, shown to the user. */
    purpose : slop_os.Relative[u8],
    /** The name it suggests for a new file, as UTF-8, up to NAME_BYTES, which the chooser starts with; may be empty. */
    suggested : slop_os.Relative[u8],
    /** Whether the program would write the file; without it, the file's given read only. */
    write : bool,
    /**
     * The key to keep the grant under if the user lets it, 1 to KEY_BYTES letters, digits, - and _; empty to not
     * ask. A key not of those is Refused.
     */
    keep : slop_os.Relative[u8],
}

/** A directory asked for: why, whether it would write in it, and the key to keep it under, empty to not ask. */
DirectoryRequest :: struct {
    /** Why the program asks, in its own words, as UTF-8, up to PURPOSE_BYTES, shown to the user. */
    purpose : slop_os.Relative[u8],
    /** Whether the program would write in the directory; without it, the directory's given read only. */
    write : bool,
    /**
     * The key to keep the grant under if the user lets it, 1 to KEY_BYTES letters, digits, - and _; empty to not
     * ask. A key not of those is Refused.
     */
    keep : slop_os.Relative[u8],
}

/** A kept grant asked for again: its key, and what it's opened as. */
Reopening :: struct {
    /** The key the program kept it under, 1 to KEY_BYTES letters, digits, - and _. */
    key : slop_os.Relative[u8],
    /** Whether it's opened as a file or a directory. */
    kind : Kind,
    /** Whether it's opened to write, which the kept grant has to allow. */
    write : bool,
}

/** Another account asked for, and why. */
AccountRequest :: struct {
    /** Why the program asks, in its own words, as UTF-8, up to PURPOSE_BYTES, shown to the administrator. */
    purpose : slop_os.Relative[u8],
}

/** The system shut down or restarted, asked for, and why. */
PowerRequest :: struct {
    /** Why the program asks, in its own words, as UTF-8, up to PURPOSE_BYTES, shown to the administrator. */
    purpose : slop_os.Relative[u8],
    /** Whether it's a restart; a shutdown if not. */
    restart : bool,
}

/** A network connection allowing more than the program's own (decisions/0188, 13c), as RequestNetwork asks for it. */
NetworkRequest :: struct {
    /** Why the program asks, in its own words, as UTF-8, up to PURPOSE_BYTES, shown to the user. */
    purpose : slop_os.Relative[u8],
    /** What it would connect to, as network's rules; at most network.MAX_RULES. */
    connect : slop_os.Relative[network.Rule],
    /** What it would listen on; at most network.MAX_RULES. */
    listen : slop_os.Relative[network.Rule],
}

/** A program to debug (decisions/0185, 12f), as RequestDebug asks for it. */
DebugRequest :: struct {
    /** The program's name, as the session runs it: an installation's, or "powerbox"; up to NAME_BYTES, as UTF-8. */
    name : slop_os.Relative[u8],
    /** Why the program asks, in its own words, as UTF-8, up to PURPOSE_BYTES, shown to the user. */
    purpose : slop_os.Relative[u8],
    /**
     * The debugger's port, which the program's stops are to come to, as Stop packets under key; it moves to the
     * powerbox, and on to the session manager, which attaches the intercept to it.
     */
    port : slop_os.Port,
    /** The key the stops come under. */
    key : u64,
}

/** A program attached to a debugger: what the debugger controls it with. Every handle moves to the debugger. */
Attached :: struct {
    /**
     * The program's process, with RIGHT_PROCESS_INSPECT and RIGHT_PROCESS_WRITE_STATE: its threads read, suspended,
     * resumed and set to debug, and its end watched.
     */
    process : slop_os.Process,
    /** The intercept of its faults, on the debugger's port; closing it lets the program run on unintercepted. */
    intercept : slop_os.Intercept,
    /** Its address space, rightless, as process_read_memory takes it. */
    space : slop_os.AddressSpace,
    /** Where its image is in its address space. */
    image : u64,
    /** The name of the program it runs, as Find takes it, for its files: an installation's program, not its name. */
    program : slop_os.Relative[u8],
}

/** A program of the session's, to serve on its end under its name. */
Served :: struct {
    /** The program's name, as the session manager gave it, as UTF-8; the powerbox keeps up to NAME_BYTES of it. */
    name : slop_os.Relative[u8],
    /** The powerbox's end of the program's connection, which moves to the powerbox. */
    end : os.Channel[Powerbox],
}

/** What a program, or the session manager, asks the powerbox. */
Request :: union {
    /**
     * Ask the user for a file, on the trusted path. Answered once the user has chosen, with GrantedFile, or
     * GrantedReadOnlyFile without write, or Refused; at once with Busy, or Refused when the powerbox has no home or
     * trusted path, or the key isn't one.
     */
    RequestFile(FileRequest),
    /** Ask the user for a directory, as RequestFile asks for a file; answered with GrantedDirectory or the rest. */
    RequestDirectory(DirectoryRequest),
    /**
     * Open a grant the program kept, again, without asking the user. Answered with the Granted response for its kind
     * and write, or Refused if it isn't kept, was revoked, or the key isn't one.
     */
    Reopen(Reopening),
    /**
     * Ask for another account to be made, which the administrator allows on the trusted path (decisions/0158).
     * Answered with AccountMade, or Refused; at once with Busy.
     */
    RequestAccount(AccountRequest),
    /**
     * Ask for the system to be shut down or restarted, which the administrator allows on the trusted path
     * (decisions/0182). Answered with Allowed, once it's under way, which may not be seen before the system's gone; or
     * Refused; at once with Busy.
     */
    RequestPower(PowerRequest),
    /**
     * Ask to debug a program of the session's, which the user allows on the trusted path, each time, or, for another
     * user's program, the administrator (decisions/0185, 12f). Answered with Attached, once it's allowed and attached;
     * or Refused, the port closed; at once with Busy.
     */
    RequestDebug(DebugRequest),
    /**
     * Ask to trace the whole system, which the administrator allows on the trusted path (decisions/0185, 12g), with why,
     * as UTF-8, up to PURPOSE_BYTES. Answered with TraceGranted, or Refused; at once with Busy.
     */
    RequestTrace(slop_os.Relative[u8]),
    /**
     * Ask to read the system's log, every service's records, which the administrator allows on the trusted path
     * (decisions/0185, 12g), with why. Answered with LogGranted, or Refused; at once with Busy.
     */
    RequestSystemLog(slop_os.Relative[u8]),
    /**
     * Ask for a network connection allowing what's asked (decisions/0188, 13c), which the user allows on the trusted
     * path, its rules described to them. Answered with NetworkGranted, or Refused; at once with Busy.
     */
    RequestNetwork(NetworkRequest),
    /**
     * The session manager's, on its own connection only: serve another program on its end, under its name. Answered
     * with Done, or Refused when there's no room or it isn't the session manager's, the end then closed.
     */
    Serve(Served),
}

/** What the powerbox answers. */
Response :: union {
    /** A file chosen, or reopened, to write: a connection to it, which moves to the program. */
    GrantedFile(os.Channel[file.File]),
    /** A file chosen, or reopened, to read only: a connection to it, which moves to the program. */
    GrantedReadOnlyFile(os.Channel[read_only_file.ReadOnlyFile]),
    /** A directory chosen, or reopened, to write in: a connection to it, which moves to the program. */
    GrantedDirectory(os.Channel[dir.Dir]),
    /** A directory chosen, or reopened, to read only: a connection to it, which moves to the program. */
    GrantedReadOnlyDirectory(os.Channel[read_only_dir.ReadOnlyDir]),
    /** The user refused, or what they chose couldn't be opened, or it couldn't be asked. */
    Refused,
    /** A request before, this program's or another's, is still waiting for the user; one waits at a time. */
    Busy,
    /** Serve's answer: the program is served. */
    Done,
    /** RequestAccount's answer: the account made, by its name, as UTF-8. */
    AccountMade(slop_os.Relative[u8]),
    /** RequestPower's answer: the administrator allowed it, and it's under way. */
    Allowed,
    /** RequestDebug's answer: the program, attached to the debugger's port. */
    Attached(Attached),
    /** RequestTrace's answer: a trace connection to the supervisor, which moves to the program. */
    TraceGranted(os.Channel[trace.Trace]),
    /** RequestSystemLog's answer: a connection to the events service, which moves to the program. */
    LogGranted(os.Channel[events.Events]),
    /** RequestNetwork's answer: a network connection allowing what was asked, which moves to the program. */
    NetworkGranted(os.Channel[network.Network]),
    /** The answer to a request the powerbox doesn't know, as from a newer program; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for Reopen, a kept grant opened again giving another connection to it; false for the rest, which would
 *     ask the user again, or serve a program twice.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case RequestFile(_) => false
        case RequestDirectory(_) => false
        // A kept grant opened again gives another connection to it
        case Reopen(_) => true
        case RequestAccount(_) => false
        case RequestPower(_) => false
        case RequestDebug(_) => false
        case RequestTrace(_) => false
        case RequestSystemLog(_) => false
        case RequestNetwork(_) => false
        case Serve(_) => false
    }
}

#insert os.protocol_code(Request, Response)
