package events

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"

/*
 * The events service's protocol (roadmap 9a, decisions/0093, design/observability.md §2). Who starts a program asks for
 * its ring with Open, and gives it to the program as its grants "events" (std's os.LaunchEvents): base's logger
 * writes the program's records there, and the service labels them with the name Open was given, so a program can't
 * claim another's. Records are kept in memory until Store gives a directory, then there. Query reads a source's
 * records, one at a time, rendered as text; one that waits is answered once there's a record to give. Connections
 * arrive on its listener, and as Connects. Open's answer holds the ring's owning handle, which the launcher keeps,
 * giving the program one that doesn't own it, and gives back with Retire once the program has ended: so a ring outlives
 * both its program and the service, until its last records are read (decisions/0098). A service started again is
 * given the rings of the programs still running with Adopt, and reads them from where the last one stopped.
 */

/**
 * The events protocol, for the channels between the events service and its clients, and its listener: the clients
 * send the requests, and the events service answers them.
 */
Events :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the events service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "events", major_version = 1, lending = .Server}

/** A program's ring for its records (base's runtime.SlopOsEventsRing), and the doorbell base's logger rings. */
Source :: struct {
    /**
     * The ring, shared memory its header written already: the owning handle, which the launcher keeps and gives back
     * with Retire, giving the program a duplicate that doesn't own it.
     */
    ring : slop_os.Memory,
    /** The program's end of the doorbell, which base's logger rings once it's written records; given to the program. */
    doorbell : slop_os.Channel,
}

/** What a Query asks for. */
QueryOf :: struct {
    /** The source's name, as Open was given it; a source of that name needn't exist yet. */
    source : slop_os.Relative[u8],
    /** The number of the first record to give, among the source's this boot, from 0. */
    from : u64,
    /** The lowest level given: a LogLevel's value. */
    level : u8,
    /** Whether to wait for a record at or after from, if there isn't one yet, rather than answering End. */
    wait : bool,
}

/** A ring to adopt: whose records it holds, and a handle to it. */
AdoptOf :: struct {
    /**
     * The source its records are, as Open was given it: 1 to the service's NAME_BYTES lowercase letters, digits and
     * underscores.
     */
    source : slop_os.Relative[u8],
    /** A handle to it that can read and write it but doesn't own it, which moves to the service, closed if refused. */
    ring : slop_os.Memory,
}

/** A record found by a Query. */
Found :: struct {
    /** Its number among the source's this boot, from 0; the next Query for more asks from one past it. */
    number : u64,
    /** The monotonic clock's nanoseconds when it was written. */
    time : u64,
    /** Its level, a LogLevel's value. */
    level : u8,
    /** Whether it was read from where Store keeps records, rather than memory. */
    stored : bool,
    /** The record, rendered as text, as UTF-8. */
    text : slop_os.Relative[u8],
}

/** What a client asks the events service. */
Request :: union {
    /**
     * Ask for a ring for a program the caller starts, whose records are the source named this, made a source if it
     * isn't one: 1 to the service's NAME_BYTES lowercase letters, digits and underscores. Answered with Opened, or
     * Refused.
     */
    Open(slop_os.Relative[u8]),
    /**
     * Have records kept in this directory from now on, those in memory with them; the end moves to the service.
     * Answered with Done.
     */
    Store(os.Channel[dir.Dir]),
    /**
     * Read the first record of a source at or after a number, at a level or above. Answered with Found, or End;
     * when it waits, answered once there's one, or End at once if it can't be held.
     */
    Query(QueryOf),
    /**
     * Have the events service serve another client, on the end given, which moves to it; it's closed if the service
     * already has as many clients as it takes. Answered with nothing.
     */
    Connect(os.Channel[Events]),
    /**
     * Give back a ring whose program has ended, by its owning handle, which moves to the service: its records read,
     * every ring's, then closed (decisions/0098). Answered with Done.
     */
    Retire(slop_os.Memory),
    /**
     * Have the service read a ring a service before this one opened, its program still running, from here on.
     * Answered with Done, or Refused.
     */
    Adopt(AdoptOf),
}

/** What the events service answers. */
Response :: union {
    /** Open's answer: the ring and the doorbell, which move to the client, to keep the ring and give the rest on. */
    Opened(Source),
    /** Store's, Retire's or Adopt's answer: it's done. */
    Done,
    /** Query's answer: the record. */
    Found(Found),
    /** Query's answer when there's no record at or after its from, or no such source, and it doesn't wait. */
    End,
    /**
     * Open's or Adopt's answer when there's no room for another source or ring, the name is empty, too long or not of
     * the letters it takes, or the ring couldn't be made or read.
     */
    Refused,
    /** The answer to a request the events service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Open, which opens another ring, and Retire and Adopt, whose handles were given; true for Store,
 *     which again changes nothing, Query, which only reads, and Connect.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Open(_) => false
        case Store(_) => true
        case Query(_) => true
        case Connect(_) => true
        case Retire(_) => false
        case Adopt(_) => false
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Send a request to the events service and wait for its answer.
 *
 * A response that isn't the protocol, unknown or invalid, ends the wait as the connection's going does
 * (decisions/0177).
 *
 * @param end A connection to the events service, kept by the caller.
 * @param port A port bound to end, waited on for the answer and while end's ring is full.
 * @param out The request, begun with os.begin; sent as it is, any handles in it moving to the service.
 * @param into Where the answer is received, with any handles it brought, which are the caller's from then on.
 * @return The answer, copied out of into; Unsupported if the request couldn't be sent, the connection's gone, or its
 *     answer isn't the protocol.
 */
ask :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> Response {
    if send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match receive_response(end, port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
    return os.message_of[Response](into)^
}

/**
 * Ask the events service for a ring for a program, and wait for it.
 *
 * @param end A connection to the events service, kept by the caller.
 * @param port A port bound to end, waited on for the answer.
 * @param name The source's name, which the program's records are labeled with: 1 to the service's NAME_BYTES
 *     lowercase letters, digits and underscores.
 * @return What to launch the program with as os.LaunchEvents: the ring's owning handle and the doorbell's end, the
 *     caller's; null if the service refused, or couldn't be asked.
 */
open :: fn(end: slop_os.Channel, port: slop_os.Port, name: string) -> os.LaunchEvents? {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Open(os.append(&out, string_bytes(name)))
    into := os.Incoming.{}
    return match ask(end, port, &out, &into) {
        case Opened(source) => os.LaunchEvents.{ring = source.ring, doorbell = source.doorbell}
        case _ => null
    }
}
