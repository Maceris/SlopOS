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
 * both its program and the service, until its last records are read (decisions/0098).
 */

Events :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "events", major_version = 1, lending = .Server}

// A program's ring for its records (base's runtime.SlopOsEventsRing), and the doorbell base's logger rings.
Source :: struct {
    ring : slop_os.Memory,
    doorbell : slop_os.Channel,
}

QueryOf :: struct {
    // The source's name, as Open was given it
    source : slop_os.Relative[u8],
    // The number of the first record to give, among the source's this boot, from 0
    from : u64,
    // The lowest level given: a LogLevel
    level : u8,
    // Whether to wait for a record at or after from, if there isn't one yet, rather than answering End
    wait : bool,
}

Found :: struct {
    // Its number among the source's
    number : u64,
    // The monotonic clock's nanoseconds when it was written, and its level, a LogLevel
    time : u64,
    level : u8,
    // Whether it was read from where Store keeps records
    stored : bool,
    text : slop_os.Relative[u8],
}

Request :: union {
    // A ring for a program the caller starts, whose records are the source named this
    Open(slop_os.Relative[u8]),
    // Records kept in this directory from now on, those in memory with them
    Store(os.Channel[dir.Dir]),
    Query(QueryOf),
    // Serve another client, on its end
    Connect(os.Channel[Events]),
    /*
     * A ring whose program has ended, its owning handle given back by whoever launched it: its records read, every
     * ring's, then closed (decisions/0098)
     */
    Retire(slop_os.Memory),
}

Response :: union {
    Opened(Source),
    Done,
    Found(Found),
    // No record at or after the query's from, or no such source
    End,
    // Out of room for another source, or a name that's empty or too long
    Refused,
    Unsupported,
}

// Opening again opens another ring, and storing again changes nothing; a query only reads.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Open(_) => false
        case Store(_) => true
        case Query(_) => true
        case Connect(_) => true
        case Retire(_) => false
    }
}

#insert os.protocol_code(Request, Response)

// A request sent through end, and its answer, waited for on port; Unsupported if the connection's gone.
ask :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> Response {
    if send_request(end, port, out) is_some {
        return .Unsupported
    }
    loop {
        match receive_response(end, port, into, true) {
            case Received => break
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
    return os.message_of[Response](into)^
}

// A ring for a program named name, through end: what to give it as os.LaunchEvents, or null.
open :: fn(end: slop_os.Channel, port: slop_os.Port, name: string) -> os.LaunchEvents? {
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Open(os.append(&out, view_of(cast[ptr[u8]](name.data), name.count)))
    into := os.Incoming.{}
    return match ask(end, port, &out, &into) {
        case Opened(source) => os.LaunchEvents.{ring = source.ring, doorbell = source.doorbell}
        case _ => null
    }
}
