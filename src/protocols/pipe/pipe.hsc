package pipe

import os from "std"
import slop_os from "std/os"

/*
 * A byte stream between a program and what serves it (decisions/0191): the SSH service and the SFTP program a session
 * runs for its sftp subsystem. The program reads with Read, which is held until bytes come or the stream's ended, and
 * writes with Write, which isn't answered. Its bytes are anything: unlike the terminal protocol's text, nothing's made
 * safe, as a pipe is never shown.
 */

/**
 * The pipe protocol, for the channel between a program, which sends the requests, and what serves its stream, which
 * answers them.
 */
Pipe :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "pipe", major_version = 1, lending = .Server}

/** The ring every pipe is made with, 16 KiB, several messages of CHUNK_BYTES. */
RING_BYTES : u32 : 16384
/** The most bytes one Write, or one Data, carries: 3 KiB, so it fits a message, which is at most 4 KiB. */
CHUNK_BYTES :: 3072

/** What a program asks of its pipe. */
Request :: union {
    /** Bytes, at most this many and at most CHUNK_BYTES. Held until some come, then answered with Data, or Ended. */
    Read(u32),
    /** Bytes to send, at most CHUNK_BYTES. Not answered. */
    Write(slop_os.Relative[u8]),
}

/** What the pipe answers. */
Response :: union {
    /** Read's answer: the bytes that came, at least one. */
    Data(slop_os.Relative[u8]),
    /** Read's answer once the other end has finished, and every Read's after. */
    Ended,
    /** The answer to a request the server doesn't know; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for both: what was read or written would be again.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => false
        case Write(_) => false
    }
}

#insert os.protocol_code(Request, Response)
