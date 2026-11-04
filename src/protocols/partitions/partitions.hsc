package partitions

import os from "std"
import slop_os from "std/os"
import block from "../block"

/*
 * A partition server's protocol (roadmap 8a, decisions/0086), which the storage manager speaks: the partitions its
 * disk's GPT describes, by index, and block connections each narrowed to one of them. Connections arrive on its
 * listener as Connects.
 */

/**
 * The partitions protocol, for the channels between a partition server and its clients, and its listener: the
 * clients send the requests, and the partition server answers them.
 */
Partitions :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the partition server, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "partitions", major_version = 1, lending = .Server}

/**
 * The most bytes of a partition's GPT name, as UTF-8: 108, enough for the GPT's 36 UTF-16 code units, each at most 3
 * bytes.
 */
NAME_BYTES :: 108

/** One partition, as the disk's GPT describes it. */
PartitionInfo :: struct {
    /** Its first block on the disk, in block.BLOCK_BYTES blocks. */
    first : u64,
    /** How many blocks it has, of block.BLOCK_BYTES. */
    count : u64,
    /** Its GPT partition type GUID, as the GPT stores it, mixed-endian. */
    type_guid : u8[16],
    /** Its GPT unique partition GUID, as the GPT stores it, mixed-endian. */
    unique_guid : u8[16],
    /** Its GPT name, as UTF-8, in the first name_length bytes; the rest are zeros. */
    name : u8[NAME_BYTES],
    /** How many of name's bytes are the name, 0 to NAME_BYTES; name_of takes no more than NAME_BYTES. */
    name_length : u32,
}

/** What a client asks a partition server. */
Request :: union {
    /** Ask for the partition at an index, from 0, in the GPT's order. Answered with Described, or NoPartition. */
    Describe(u32),
    /**
     * Ask for a new block connection to the partition at an index, from 0, narrowed to its blocks: block 0 is its
     * first, and none past its count can be reached. Answered with Opened, or NoPartition when there's no partition
     * there or the connection couldn't be made.
     */
    Open(u32),
    /**
     * Have the server serve another client, on the end given, which moves to the server; it's closed if the server
     * already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Partitions]),
}

/** What a partition server answers. */
Response :: union {
    /** Describe's answer: the partition. */
    Described(PartitionInfo),
    /** Open's answer: the client's end of the new block connection, which moves to the client. */
    Opened(os.Channel[block.Block]),
    /** Describe's or Open's answer when there's no partition at that index, or Open's when it couldn't be opened. */
    NoPartition,
    /** The answer to a request the server doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: describing again changes nothing, and opening again gives another connection,
 *     which is as good.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe(_) => true
        case Open(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Give a partition's name as text.
 *
 * @param info The partition, which the text views.
 * @return Its name's first name_length bytes, at most NAME_BYTES, as UTF-8 though not checked to be: a view into
 *     info's name, good while info is.
 */
name_of :: fn(info: ptr[PartitionInfo]) -> string {
    return string_of(&info.name[0], cast[usize](if info.name_length > NAME_BYTES { cast[u32](NAME_BYTES) } else { info.name_length }))
}
