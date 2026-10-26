package container

import os from "std"
import slop_os from "std/os"
import slopfs from "../../slopfs"
import block from "../block"

/*
 * A container service's protocol (roadmap 8d, decisions/0089), which the storage manager and volume servers speak. On
 * the listener's connections, OpenVolume gives a connection of its own for one volume; on that, the volume server
 * describes its volume, allocates and gives back its extents, opens block connections that read and write only them,
 * and commits its tree: written through those connections, every write finished, then its record sent here, which
 * the container makes durable with a checkpoint. A volume server never reaches another volume's blocks or the
 * container's own, and the container service never reads a volume's tree.
 */

Container :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "container", major_version = 1, lending = .Server}

// An extent a volume gives back: its first 4 KiB block, its length, and the transaction it was written in.
Released :: struct {
    first : u64,
    blocks : u64,
    birth : u64,
}

// A volume as it was last committed, and the transaction its changes go into now.
Described :: struct {
    id : u64,
    record : slopfs.VolumeRecord,
    transaction : u64,
}

Request :: union {
    // The volume with a name, on a new connection of its own, for the requests below
    OpenVolume(slop_os.Relative[u8]),
    Describe,
    // An extent of so many 4 KiB blocks, for this volume
    Allocate(u64),
    Release(Released),
    // A block connection to the container's partition, its reads and writes allowed only in this volume's extents
    OpenBlocks,
    // The volume's record, its tree written through block connections whose writes have all finished, made durable
    Commit(slopfs.VolumeRecord),
    // Everything the volume changed since its last commit undone: its allocations free again, what it gave back its own
    Abandon,
    // Serve another client, on its end
    Connect(os.Channel[Container]),
}

Response :: union {
    OpenedVolume(os.Channel[Container]),
    Described(Described),
    Allocated(u64),
    Done,
    // The transaction committed, and the one changes go into next
    Committed(u64),
    Blocks(os.Channel[block.Block]),
    NoVolume,
    NoSpace,
    // The container couldn't commit: a write failed, or it doesn't hold together, and every later commit fails too
    Failed,
    // Only on a volume's connection
    NotAVolume,
    // An extent that isn't this volume's, given back, or a root that isn't in its extents, committed
    NotYours,
    Unsupported,
}

// Allocating, giving back and committing change something each time; the rest are as good done again.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case OpenVolume(_) => true
        case Describe => true
        case Allocate(_) => false
        case Release(_) => false
        case OpenBlocks => true
        case Commit(_) => false
        case Abandon => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the container service listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Container]? {
    pair :: os.channel_for[Container](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Container].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Container].{end = pair.b}
    }
}
