package storage

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import block from "../block"
import partitions from "../partitions"

/*
 * The storage manager's protocol (roadmap 8a, decisions/0086): every partition of every disk it holds, by one index
 * from 0, and block connections narrowed to one, from that disk's partition server, or the files of a FAT partition
 * (an EFI system partition or a basic data one), as a dir connection to its root, from a FAT server for it.
 * Connections arrive on its listener as Connects. SlopOS's own volumes come with 8d.
 */

Storage :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "storage", major_version = 1, lending = .Server}

// A partition, and which disk it's on, from 0, and which of that disk's it is.
Partition :: struct {
    disk : u32,
    index : u32,
    info : partitions.PartitionInfo,
}

Request :: union {
    // The partition at an index, across every disk, from 0
    Describe(u32),
    // A new block connection narrowed to the partition at an index
    Open(u32),
    // The root of the FAT volume on the partition at an index
    OpenFiles(u32),
    // Serve another client, on its end
    Connect(os.Channel[Storage]),
}

Response :: union {
    Described(Partition),
    Opened(os.Channel[block.Block]),
    OpenedFiles(os.Channel[dir.Dir]),
    NoPartition,
    // The partition isn't one of a kind that holds files, or its FAT server couldn't be started
    NoFiles,
    Unsupported,
}

is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe(_) => true
        case Open(_) => true
        case OpenFiles(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the storage manager listening on end, or null (as entropy.connect).
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Storage]? {
    pair :: os.channel_for[Storage](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Storage].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Storage].{end = pair.b}
    }
}
