package programs

import os from "std"
import slop_os from "std/os"
import powerbox from "../powerbox"

/*
 * What a session's shell asks the session manager for (decisions/0170): a program of the bundle store's boot root, by
 * name, its executable, which the shell launches itself, and its manifest, the schema of its entry's type, which says
 * what it takes; the root's programs' names, and a program's documentation (decisions/0174), for help and completion.
 * Nothing else of the store's: the shell can't put, pin, root or collect.
 *
 * And its own session (decisions/0179, 11e4): the session's programs running, an installation of it ended, and the
 * session's user's own installations, which run beside the system's in each of the user's sessions: installed,
 * uninstalled (a snapshot of the home taken first, so its data can be recovered) and listed with the system's. What a
 * shell asks is only ever of its own session and user.
 *
 * Connect makes another connection to the same session that only finds programs (Find, List, Describe, and Connect
 * again), as a script's shell is given (decisions/0179, 11e6): a script runs programs, but doesn't see or change its
 * session's.
 */

/**
 * The programs protocol, for the channel between a session's shell and the session manager: the shell sends the
 * requests, and the session manager answers them.
 */
Programs :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the session manager, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "programs", major_version = 1, lending = .Server}

/** The longest name Find takes, in bytes: 64. A longer name, or an empty one, is answered Missing. */
MAX_NAME :: 64

/**
 * A program found: its executable, the bundle store's paged memory, and a copy of its manifest, and how many of the
 * manifest's bytes are its.
 */
Program :: struct {
    /** The program's executable, the ELF image the shell launches; the handle moves to the shell. */
    executable : slop_os.Memory,
    /**
     * The program's manifest, the schema of its entry's type, which says what it takes: a copy, whose owning handle
     * moves to the shell, which destroys it by closing it. The object is whole pages, of which only manifest_size
     * bytes are the manifest's.
     */
    manifest : slop_os.Memory,
    /** How many bytes from manifest's start are the manifest. */
    manifest_size : u64,
}

/** What a session's shell asks the session manager. */
Request :: union {
    /**
     * Ask for a program of the bundle store's boot root, by its name's bytes, 1 to MAX_NAME of them. Answered with
     * Found, or Missing.
     */
    Find(slop_os.Relative[u8]),
    /**
     * Ask for the name of the boot root's program at an index, from 0, in the root's order. Answered with Named, or End
     * past the last.
     */
    List(u32),
    /**
     * Ask for a program's documentation, by its name's bytes, 1 to MAX_NAME of them. Answered with Documented, or
     * Missing, as for Find, and for a program without documentation.
     */
    Describe(slop_os.Relative[u8]),
    /**
     * Ask for the session's programs running, each pinged on its lifecycle channel and given a short while to answer.
     * Answered with Running.
     */
    Running,
    /**
     * End an installation running in the session, by its name: asked to stop, killed after a grace period if it hasn't.
     * It starts again with the session's next start. Answered with Done, or Refused (NotInstalled).
     */
    EndInstallation(slop_os.Relative[u8]),
    /**
     * Add an installation to the user's list, and start it in each of the user's sessions. Answered with Done, or
     * Refused.
     */
    Install(Installing),
    /**
     * Remove an installation of the user's, by its name: a snapshot of the home taken, then it's stopped in each of the
     * user's sessions, taken off the list, its data directory deleted and its settings forgotten. Answered with Done,
     * or Refused.
     */
    Uninstall(slop_os.Relative[u8]),
    /**
     * Ask for an installation the session runs, by an index from 0: the system's, then the user's. Answered with
     * Listed, or End past the last.
     */
    Installation(u32),
    /**
     * Have the session manager serve another connection to this session, on the end given, which moves to it: one that
     * answers only Find, List, Describe and Connect, and Unsupported to the rest. It's closed if there's no room for
     * another. Answered with nothing.
     */
    Connect(os.Channel[Programs]),
    /**
     * Ask for a connection to the session's powerbox for a program the shell starts, by the program's name, which the
     * powerbox shows the user when it asks (decisions/0181, F4). Answered with PowerboxGiven, or Refused(Failed) for a
     * session without a powerbox. A finding connection may ask too: what the program's given, the user chooses.
     */
    Powerbox(slop_os.Relative[u8]),
    /**
     * Ask for a program's debug file (decisions/0185, 12e), by its name's bytes, 1 to MAX_NAME of them: the program
     * linked with its DWARF and its debug table, for the debugger and crash reports' lines. Answered with DebugFile, or
     * Missing, as for Find, and for a program whose bundle has none. A finding connection may ask too.
     */
    Debug(slop_os.Relative[u8]),
    /**
     * The session's powerbox's only, on the connection the session manager gave it (decisions/0185, 12f): attach a
     * debugger to a program the session runs, by name, the user having allowed it. Answered with Attached, or
     * Refused: NotRunning for no program of that name, NeedsAdministrator for one only another user's session runs
     * unless elevated, NotAllowed from any other connection. The port is closed when it's refused.
     */
    Attach(Attaching),
    /**
     * The session's powerbox's only: where a program runs, by name, so it knows whom to ask before Attach. Answered
     * with Located, or Refused(NotAllowed) from any other connection.
     */
    Locate(slop_os.Relative[u8]),
}

/** Where Locate finds a program. */
Location :: enum #backed_by(u8) {
    /** No session runs a program of that name. */
    Nowhere = 0,
    /** The asking session runs it. */
    Here = 1,
    /** Only another user's session runs it. */
    Elsewhere = 2,
}

/** A program to attach a debugger to, as the powerbox asks for it. */
Attaching :: struct {
    /** The program's name, as its session runs it, as UTF-8, up to MAX_NAME. */
    name : slop_os.Relative[u8],
    /** The debugger's port, which moves here, then to the intercept. */
    port : slop_os.Port,
    /** The key its stops come under. */
    key : u64,
    /** Whether the administrator allowed it, so another user's session's program may be attached. */
    elevated : bool,
}

/** A program's documentation, as the bundle store keeps it. */
ProgramDocumentation :: struct {
    /**
     * Its record, a copy whose owning handle moves to the shell, which destroys it by closing it: the schema hash of
     * the bundle package's Documentation, then the value. The object is whole pages.
     */
    record : slop_os.Memory,
    /** How many bytes from record's start are the record's. */
    size : u64,
}

/** The most bytes of an installation's name: 31, letters, digits and _, as the system's records take them. */
MAX_INSTALLATION_NAME :: 31

/** The most programs one Running lists: 16. */
MAX_RUNNING :: 16

/** A program of the session's, running, as Running gives it: plain data, as a Relative's elements are. */
RunningProgram :: struct {
    /** Its name, as UTF-8, in the first name_bytes bytes: "shell", "powerbox", or an installation's. */
    name : u8[32],
    /** How many of name's bytes are the name, 0 to 32. */
    name_bytes : u8,
    /** 1 if it answered a Ping on its lifecycle channel in time, 0 if it didn't. */
    responding : u8,
    /** 1 if it's an installation, which EndInstallation can end; 0 for the session's own programs. */
    installation : u8,
    /** Its memory budget's bytes in use; 0 if the budget couldn't be read. */
    memory : u64,
    /** Its memory budget's limit, in bytes; 0 if the budget couldn't be read. */
    memory_limit : u64,
    /** Its threads' CPU time, in nanoseconds (decisions/0185, 12h); 0 if it couldn't be read. */
    cpu_ns : u64,
    /** The time services ran on its CPU budget, lent it, in nanoseconds; 0 if it couldn't be read. */
    lent_ns : u64,
    /** The bytes charged to its memory budget by other processes' objects, as services' made for it. */
    charged : u64,
}

/** An installation to make: its name, and the program it runs, from the boot root. */
Installing :: struct {
    /** Its name, 1 to MAX_INSTALLATION_NAME letters, digits and _: its data directory's and its settings' too. */
    name : slop_os.Relative[u8],
    /** The program's name in the boot root, 1 to MAX_INSTALLATION_NAME bytes. */
    program : slop_os.Relative[u8],
}

/** An installation, as Installation lists it. */
Installed :: struct {
    /** Its name. */
    name : slop_os.Relative[u8],
    /** The program it runs. */
    program : slop_os.Relative[u8],
    /** Whether it's the user's own, which Uninstall removes; false for the system's, which every session runs. */
    users : bool,
    /** The index to ask Installation for next. */
    next : u32,
}

/** Why an installation couldn't be made, removed or ended. */
InstallProblem :: enum #backed_by(u8) {
    /** The session has no user, so no list of its own. */
    NoUser = 1,
    /** The name isn't 1 to MAX_INSTALLATION_NAME letters, digits and _. */
    BadName = 2,
    /** The boot root has no program of that name. */
    NoSuchProgram = 3,
    /** The program's bundle or manifest couldn't be read. */
    NotInstallable = 4,
    /** An installation of the system's or the user's has the name already. */
    NameTaken = 5,
    /** The user's list has no room for another. */
    Full = 6,
    /** No installation of the user's has the name; one that isn't running, for EndInstallation. */
    NotInstalled = 7,
    /** It's the system's installation, which a user can't remove. */
    Systems = 8,
    /** The config store or the home couldn't be reached, or refused. */
    Failed = 9,
    /** Attach: no program of that name is running. */
    NotRunning = 10,
    /** Attach: only another user's session runs it, which takes the administrator. */
    NeedsAdministrator = 11,
    /** Attach: asked on a connection that isn't the session's powerbox's. */
    NotAllowed = 12,
}

/** What the session manager answers. */
Response :: union {
    /** The answer to Find when the program is there: its executable and manifest, whose handles move to the shell. */
    Found(Program),
    /**
     * The answer to Find when it isn't: no program by that name in the boot root, a name empty or longer than
     * MAX_NAME, or its bundle unreadable or without both an executable and a manifest. The answer to Describe for the
     * same, or a program without documentation.
     */
    Missing,
    /** The answer to a request the session manager doesn't know, as from a newer shell; every protocol has it. */
    Unsupported,
    /** The answer to List: the name of the program at the index, its bytes, 1 to MAX_NAME of them. */
    Named(slop_os.Relative[u8]),
    /** The answer to List for an index past the root's last program. */
    End,
    /** The answer to Describe when the program has documentation: its record, whose handle moves to the shell. */
    Documented(ProgramDocumentation),
    /**
     * The answer to Debug when the program has a debug file: the file, whose handle moves to the shell, in record, and
     * its size.
     */
    DebugFile(ProgramDocumentation),
    /** The answer to Attach: the program, attached, every handle moving to the powerbox. */
    Attached(powerbox.Attached),
    /** The answer to Locate. */
    Located(Location),
    /** The answer to Running: the session's programs, at most MAX_RUNNING. */
    RunningPrograms(slop_os.Relative[RunningProgram]),
    /** The answer to EndInstallation, Install and Uninstall once it's done. */
    Done,
    /** The answer to EndInstallation, Install and Uninstall when it isn't done, and why. */
    Refused(InstallProblem),
    /** The answer to Installation: the installation at the index. */
    Listed(Installed),
    /**
     * The answer to Install for a program whose entry needs, without being optional, what an installation isn't given:
     * that parameter's name (decisions/0181, F3).
     */
    NeedsParameter(slop_os.Relative[u8]),
    /** The answer to Powerbox: the program's connection to the session's powerbox, which moves to the shell. */
    PowerboxGiven(os.Channel[powerbox.Powerbox]),
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Install and Uninstall, which change the user's list, and Powerbox, which makes a connection each
 *     time; true for the rest: finding, listing, describing, ending what's ended again change nothing more.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Install(_) => false
        case Uninstall(_) => false
        case Powerbox(_) => false
        case _ => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make another connection to a session's programs: a channel for the protocol, one end sent in a Connect, which the
 * session manager serves as one that only finds programs.
 *
 * @param end A programs connection, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection; null if it couldn't be made or sent, both its ends then closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Programs]? {
    pair :: os.channel_for[Programs](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Programs].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Programs].{end = pair.b}
    }
}
