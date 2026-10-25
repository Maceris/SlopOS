package partitions

import os from "std"
import slop_os from "std/os"
import block from "../block"

/*
 * A partition server's protocol (roadmap 8a, decisions/0086), which the storage manager speaks: the partitions its
 * disk's GPT describes, by index, and block connections each narrowed to one of them. Connections arrive on its
 * listener as Connects.
 */

Partitions :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "partitions", major_version = 1, lending = .Server}

// A partition's GPT name, as UTF-8, at most
NAME_BYTES :: 108

// One partition: its blocks, from first, count of them, of block.BLOCK_BYTES; its GPT type and GUID, and its name.
PartitionInfo :: struct {
    first : u64,
    count : u64,
    type_guid : u8[16],
    unique_guid : u8[16],
    name : u8[NAME_BYTES],
    name_length : u32,
}

Request :: union {
    // The partition at an index, from 0
    Describe(u32),
    // A new block connection to the partition at an index, narrowed to its blocks: block 0 is its first
    Open(u32),
    // Serve another client, on its end
    Connect(os.Channel[Partitions]),
}

Response :: union {
    Described(PartitionInfo),
    Opened(os.Channel[block.Block]),
    // No partition at that index
    NoPartition,
    Unsupported,
}

// Opening again gives another connection, which is as good.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe(_) => true
        case Open(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

// A partition's name, as text.
name_of :: fn(info: ptr[PartitionInfo]) -> string {
    return string_of(&info.name[0], cast[usize](if info.name_length > NAME_BYTES { cast[u32](NAME_BYTES) } else { info.name_length }))
}
