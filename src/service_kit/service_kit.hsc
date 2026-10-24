/*
 * What the first services share (decisions/0067, 0071): a set of clients, each an end bound to the service's port
 * under its index, and grants' labels as text.
 */
package service_kit

import slop_os from "std/os"

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
