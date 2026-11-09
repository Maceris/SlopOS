package trace

import os from "std"
import slop_os from "std/os"

/*
 * Tracing the whole system (decisions/0185, 12g): the supervisor, which holds the kernel's trace right, serves it, on a
 * connection it makes only once an administrator's allowed it on the trusted path (power's TraceConnection), which the
 * terminal service passes on through the powerbox to the program that asked. The supervisor traces for as long as it's
 * asked, and answers with what each service did meanwhile: how often its threads were switched to and made ready.
 */

/** The trace protocol, for a connection the supervisor serves to whoever an administrator allowed to trace. */
Trace :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the supervisor, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "trace", major_version = 1, lending = .Server}

/** The longest a trace is asked for, in milliseconds: 10 s. */
MAX_MILLISECONDS :: 10_000
/** The most rows a Traced has: the busiest services first. */
MAX_ROWS :: 32
/** The most bytes of a row's name. */
NAME_BYTES :: 24

/** What's asked of the supervisor. */
Request :: union {
    /**
     * Trace the system for so many milliseconds, 1 to MAX_MILLISECONDS. Answered with Traced once it's done; or Busy
     * while another trace is under way.
     */
    Trace(u32),
}

/** What a service's threads did while it was traced. */
Row :: struct {
    /** The service's name, the first name_bytes of it; "others" for threads of no service the supervisor started. */
    name : u8[NAME_BYTES],
    /** How many bytes name has. */
    name_bytes : u8,
    /** How many times one of its threads was switched to. */
    switches : u32,
    /** How many times one of its threads was made ready. */
    wakes : u32,
}

/** What the supervisor answers. */
Response :: union {
    /** Trace's answer: each service's row, the busiest first, at most MAX_ROWS; and how many events there were. */
    Traced(Traced),
    /** Trace's answer while another trace is under way. */
    Busy,
    /** Trace's answer for a length that isn't 1 to MAX_MILLISECONDS, or a trace that couldn't be turned on. */
    Refused,
    /** The answer to a request the supervisor doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/** A trace's result. */
Traced :: struct {
    /** Each service's row, the busiest first. */
    rows : slop_os.Relative[Row],
    /** How many events the trace had in all, those of no service's thread in "others". */
    events : u64,
    /** How many events were lost, the kernel's ring full before they were read. */
    lost : u64,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True: tracing again only traces again.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)
