package block

import os from "std"
import slop_os from "std/os"

/*
 * The device class of disks (decisions/0076), which M8's storage stack is built on. A disk is BLOCK_BYTES blocks,
 * numbered from 0. Data moves through a buffer the driver makes for each connection, DMA memory a client reaches through
 * a window (GetBuffer), so the device reads and writes it with no copies; a Read or Write names blocks and where in the
 * buffer. A client may have several requests in flight, each with a tag of its own choosing, answered as the device
 * finishes them, in any order. Connections arrive on the driver's listener as Connects.
 */

Block :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "block", major_version = 1, lending = .PerConnection}

// The blocks Read and Write count, in bytes.
BLOCK_BYTES : u64 : 512

// Which blocks, and where in the connection's buffer, with the client's tag for its answer.
Transfer :: struct {
    tag : u64,
    first : u64,
    count : u32,
    // In bytes, from the buffer's start
    offset : u32,
}

Status :: enum #backed_by(u32) {
    Done = 0,
    // Past the disk's last block, or the buffer's end
    OutOfRange = 1,
    ReadOnly = 2,
    // The device said it failed
    DeviceError = 3,
    // Every slot for a request in flight is taken: send it again once one's answered
    Busy = 4,
}

Completion :: struct {
    tag : u64,
    status : Status,
}

// What the disk is.
Info :: struct {
    block_count : u64,
    // Its connection's buffer, in bytes
    buffer_bytes : u64,
    read_only : bool,
    // Whether Flush does anything; without it, writes are durable when they're done
    flushes : bool,
}

Request :: union {
    // Blocks into the buffer
    Read(Transfer),
    // Blocks from the buffer
    Write(Transfer),
    // Everything written and done before it, durable; its tag
    Flush(u64),
    Describe,
    // A window onto the connection's buffer, read-write
    GetBuffer,
    // Serve another client, on its end
    Connect(os.Channel[Block]),
}

Response :: union {
    Finished(Completion),
    Described(Info),
    Buffer(slop_os.Memory),
    Unsupported,
}

// A block written twice holds the same; a flush again flushes nothing new.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Read(_) => true
        case Write(_) => true
        case Flush(_) => true
        case Describe => true
        case GetBuffer => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the driver listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Block]? {
    pair :: os.channel_for[Block](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Block].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Block].{end = pair.b}
    }
}
