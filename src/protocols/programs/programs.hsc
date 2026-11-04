package programs

import os from "std"
import slop_os from "std/os"

/*
 * What a session's shell asks the session manager for (decisions/0170): a program of the bundle store's boot root, by
 * name, its executable, which the shell launches itself, and its manifest, the schema of its entry's type, which says
 * what it takes. Nothing else of the store's: the shell can't put, pin, root or collect.
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
 * A program found: its executable and its manifest, each a read-only memory object from the bundle store, and how
 * many of the manifest's bytes are its.
 */
Program :: struct {
    /** The program's executable, the ELF image the shell launches; the handle moves to the shell. */
    executable : slop_os.Memory,
    /**
     * The program's manifest, the schema of its entry's type, which says what it takes; the handle moves to the
     * shell. The object is whole pages, of which only manifest_size bytes are the manifest's.
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
}

/** What the session manager answers. */
Response :: union {
    /** The answer to Find when the program is there: its executable and manifest, whose handles move to the shell. */
    Found(Program),
    /**
     * The answer to Find when it isn't: no program by that name in the boot root, a name empty or longer than
     * MAX_NAME, or its bundle unreadable or without both an executable and a manifest.
     */
    Missing,
    /** The answer to a request the session manager doesn't know, as from a newer shell; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: finding again changes nothing.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)
