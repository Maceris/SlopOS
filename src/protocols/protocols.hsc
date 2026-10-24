/*
 * The first services' own protocols (decisions/0067, 0068), each a fixed-layout struct starting with its tag,
 * sent as its bytes with std/os's send and receive, until messages are generated from typed protocols. The
 * process manager's is std's (std/os/slop_os/process_manager), since std/os's launch speaks it. Each
 * protocol's type names it, for os.Channel[P] and os.Listener[P].
 */
package protocols

import os from "std"
import slop_os from "std/os"

// A connection, to whoever serves a Listener[P]: the message's one handle is the connection's end.
CONNECT : u32 : 2

ConnectRequest :: struct {
    tag : u32,
    reserved : u32,
}

// ---- The entropy service

Entropy :: struct {}

ENTROPY_FILL : u32 : 1
// The most bytes one EntropyReply has.
MAX_ENTROPY_BYTES :: 256

// ENTROPY_FILL: count random bytes, up to MAX_ENTROPY_BYTES.
EntropyRequest :: struct {
    tag : u32,
    count : u32,
}

EntropyReply :: struct {
    tag : u32,
    count : u32,
    bytes : u8[MAX_ENTROPY_BYTES],
}

// ---- The supervisor's reports, to the root task

Supervision :: struct {}

// A service started, with its first thread.
SUPERVISOR_STARTED : u32 : 1
// A service ended, with code as its SIGNAL_TERMINATED gave it (slop_os.EXIT_KILLED if it was killed).
SUPERVISOR_ENDED : u32 : 2
// A service didn't start: code is its os.LaunchError, plus one.
SUPERVISOR_FAILED : u32 : 3

SupervisorReport :: struct {
    tag : u32,
    reserved : u32,
    code : u64,
    name : u8[slop_os.GRANT_LABEL_SIZE],
}

// ---- Connecting, and serving several clients

/*
 * A new connection to whoever serves end's listener: a channel of ring_bytes, one end sent through end, the
 * other given back, or null.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget, ring_bytes: u32) -> slop_os.Channel? {
    pair :: slop_os.channel_create(budget, ring_bytes) or_return null
    request := ConnectRequest.{tag = CONNECT}
    ends :: slop_os.Handle.[cast[slop_os.Handle](pair.a)]
    match os.send(end, port, os.bytes_of(&request), ends) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return pair.b
    }
}

// The most clients one service serves.
MAX_CLIENTS :: 16

// A service's clients: an end each, bound to its port under its index, NO_HANDLE once it's closed.
Clients :: struct {
    ends : slop_os.Channel[MAX_CLIENTS],
    count : usize,
}

// One more client, bound to port: false if there's no room, or it can't be bound.
add_client :: fn(clients: ptr[mut Clients], port: slop_os.Port, end: slop_os.Channel) -> bool {
    index :: clients.count
    if index >= clients.ends.count {
        return false
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(port, cast[slop_os.Handle](end), signals, cast[u64](index), .Persistent) {
        case Ok => {}
        case Error(error) => return false
    }
    clients.ends[index] = end
    clients.count = index + 1
    return true
}

// A client that went away, closed.
drop_client :: fn(clients: ptr[mut Clients], index: usize) {
    if index < clients.ends.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](clients.ends[index]))
        clients.ends[index] = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
}

// A label's text, without its padding.
text_of_label :: fn(label: ptr[u8[slop_os.GRANT_LABEL_SIZE]]) -> string {
    count : usize = 0
    for byte in label^ {
        if byte == 0 {
            break
        }
        count += 1
    }
    return string_of(&label^[0], count)
}
