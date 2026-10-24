/*
 * The first services' messages (decisions/0067), until 6d generates them from typed protocols: each a
 * struct with a fixed layout starting with its tag, sent as its bytes, with its handles in the message's
 * batch in the order its comment gives. Every service here answers one request at a time, in order.
 */
package protocols

import slop_os from "std/os"

// ---- The process manager

// Load a program into a process the requester made, which stays the requester's and is paid for by it.
PM_LOAD : u32 : 1
// Serve another client: the request's one handle is a channel end to read requests from.
PM_CONNECT : u32 : 2

// The most grants a LoadRequest gives the new program.
MAX_LOAD_GRANTS :: 12
// The handles a LoadRequest comes with: the process, its space, its budget and the executable, then its grants.
LOAD_HANDLES :: 4
LOAD_HANDLES_AND_GRANTS :: LOAD_HANDLES + MAX_LOAD_GRANTS

/*
 * PM_LOAD, with handles: the process (RIGHT_PROCESS_THREADS, RIGHT_DUPLICATE and RIGHT_TRANSFER), its
 * address space (owning, which goes to the process), its memory budget (RIGHT_BUDGET_CHARGE, RIGHT_DUPLICATE
 * and RIGHT_TRANSFER), the executable (a memory object, RIGHT_MEMORY_READ), then grant_count grants, each
 * labeled by labels, in order, with RIGHT_TRANSFER. The manager keeps none of them.
 */
LoadRequest :: struct {
    tag : u32,
    grant_count : u32,
    // The program's name, for the manager's log
    name : u8[slop_os.GRANT_LABEL_SIZE],
    labels : u8[MAX_LOAD_GRANTS][slop_os.GRANT_LABEL_SIZE],
}

LoadStatus :: enum #backed_by(u32) {
    Loaded = 1,
    // Not a LoadRequest's handles, or too many grants
    BadRequest = 2,
    // The executable isn't one the loader takes
    NotAProgram = 3,
    // The budget couldn't pay, or there was no room
    NoMemory = 4,
    // The entropy service didn't answer
    NoRandom = 5,
    // A call failed building it
    Failed = 6,
}

// The answer to a LoadRequest: its status, and once it's loaded, its first thread's ID.
LoadReply :: struct {
    tag : u32,
    status : LoadStatus,
    thread : u64,
}

// PM_CONNECT, with the end to serve.
ConnectRequest :: struct {
    tag : u32,
    reserved : u32,
}

// ---- The entropy service

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

// ---- The supervisor, to the root task

// A service started, with its first thread.
SUPERVISOR_STARTED : u32 : 1
// A service ended, with code as its SIGNAL_TERMINATED gave it (slop_os.EXIT_KILLED if it was killed).
SUPERVISOR_ENDED : u32 : 2
// A service didn't start: code is its LoadStatus, or 0 if it never reached the manager.
SUPERVISOR_FAILED : u32 : 3

SupervisorReport :: struct {
    tag : u32,
    reserved : u32,
    code : u64,
    name : u8[slop_os.GRANT_LABEL_SIZE],
}

// ---- Sending and receiving

// What receive gives: the message's size, and how many handles came with it.
Received :: struct {
    size : u32,
    handle_count : u32,
}

// A message's bytes.
bytes_of :: fn[T](message: ptr[T]) -> u8[] {
    return view_of(cast[ptr[u8]](message), size_of(T))
}

mut_bytes_of :: fn[T](message: ptr[mut T]) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](message), size_of(T))
}

/*
 * bytes, with handles in a batch the other end has free, moved out of the caller's table. Waits on port,
 * which nothing else uses, while the ring is full.
 */
send :: fn(end: slop_os.Channel, port: slop_os.Port, bytes: u8[], handles: slop_os.Handle[]) -> slop_os.ChannelError? {
    batch := slop_os.NO_BATCH
    if handles.count != 0 {
        batch = 0
        loop {
            match slop_os.channel_send_handles(end, handles, batch) {
                case Ok => break
                case Error(error) => {
                    if error != .BatchInUse || batch + 1 >= slop_os.HANDLE_BATCHES {
                        return error
                    }
                    batch += 1
                }
            }
        }
    }
    loop {
        match slop_os.channel_write(end, bytes, batch) {
            case Ok => return null
            case Error(error) => {
                if error != .Full {
                    return error
                }
                packets : slop_os.Packet[4]
                _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
            }
        }
    }
}

/*
 * The next message, its bytes in buffer and its handles in handles, without waiting: Empty if there's
 * none yet, which leaves the end's next write raising SIGNAL_READABLE.
 */
try_receive :: fn(end: slop_os.Channel, buffer: mut u8[], handles: mut slop_os.Handle[]) -> Result[Received, slop_os.ChannelError] {
    info :: slop_os.channel_read(end, buffer, cast[ptr[mut u32]](0))?
    received := Received.{size = info.size}
    if info.flags_and_batch & cast[u32](slop_os.MESSAGE_HAS_HANDLES) != 0 {
        received.handle_count = slop_os.channel_take_handles(end, info.flags_and_batch >> 16, handles, cast[ptr[mut u32]](0))?
    }
    return .Ok(received)
}

/*
 * The next message, as try_receive, waiting on port for it: a port bound to the end for SIGNAL_READABLE and
 * SIGNAL_PEER_CLOSED, which nothing else uses.
 */
receive :: fn(end: slop_os.Channel, port: slop_os.Port, buffer: mut u8[], handles: mut slop_os.Handle[]) -> Result[Received, slop_os.ChannelError] {
    loop {
        match try_receive(end, buffer, handles) {
            case Ok(received) => return .Ok(received)
            case Error(error) => {
                if error != .Empty {
                    return .Error(error)
                }
                packets : slop_os.Packet[4]
                _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_return .Error(.ObjectGone)
            }
        }
    }
}

/*
 * A port for one end: SIGNAL_READABLE, SIGNAL_WRITABLE and SIGNAL_PEER_CLOSED wake it, for send and
 * receive to wait on.
 */
port_for :: fn(budget: slop_os.MemoryBudget, end: slop_os.Channel) -> slop_os.Port? {
    port :: slop_os.port_create(budget) or_return null
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_WRITABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    match slop_os.port_bind(port, cast[slop_os.Handle](end), signals, 0, .Persistent) {
        case Ok => return port
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](port))
            return null
        }
    }
}

// A request, then its reply, on an end and its port_for.
call :: fn(end: slop_os.Channel, port: slop_os.Port, request: u8[], handles: slop_os.Handle[], reply: mut u8[])
    -> Result[Received, slop_os.ChannelError] {
    match send(end, port, request, handles) {
        case Some(error) => return .Error(error)
        case None => {}
    }
    none : slop_os.Handle[1]
    return receive(end, port, reply, none)
}

// A label in a grant's form: its bytes, then zeros.
label_from :: fn(text: string) -> u8[slop_os.GRANT_LABEL_SIZE] {
    label : u8[slop_os.GRANT_LABEL_SIZE]
    for byte, i in text {
        if i < label.count {
            label[i] = cast[u8](byte)
        }
    }
    return label
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

// ---- Serving several clients

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

// Every channel the process was granted as "client:<name>", as a client.
add_granted_clients :: fn(clients: ptr[mut Clients], port: slop_os.Port, block: ptr[slop_os.StartupBlock]) {
    for &grant in slop_os.grants_of(block) {
        label :: slop_os.label_of(grant)
        if grant.kind == .Channel && label.count > 7 && string_of(cast[ptr[u8]](label.data), 7) == "client:" {
            _ = add_client(clients, port, cast[slop_os.Channel](grant.handle))
        }
    }
}

// A client that went away, closed.
drop_client :: fn(clients: ptr[mut Clients], index: usize) {
    if index < clients.ends.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](clients.ends[index]))
        clients.ends[index] = cast[slop_os.Channel](slop_os.NO_HANDLE)
    }
}
