package block

import os from "std"
import slop_os from "std/os"

/*
 * The device class of disks (decisions/0076), which M8's storage stack is built on. A disk is BLOCK_BYTES blocks,
 * numbered from 0. Data moves through a buffer the driver makes for each connection, DMA memory a client reaches
 * through a window (GetBuffer), so the device reads and writes it with no copies; a Read or Write names blocks and
 * where in the buffer. A client may have several requests in flight, each with a tag of its own choosing, answered as
 * the device finishes them, in any order. Connections arrive on the driver's listener as Connects.
 */

/**
 * The block protocol, for the channels between a disk's driver, or a partition server narrowing one, and its
 * clients, and its listener: the clients send the requests, and the driver answers them.
 */
Block :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * client's budget is lent for each of its connections, which pays for the server's work on it.
 */
PROTOCOL :: slop_os.Protocol.{name = "block", major_version = 1, lending = .PerConnection}

/** The bytes of the blocks Read and Write count, and Info's block_count: 512. */
BLOCK_BYTES : u64 : 512

/** Which blocks, and where in the connection's buffer, with the client's tag for its answer. */
Transfer :: struct {
    /** The client's own value, any it likes, given back in the Finished that answers it, to tell answers apart. */
    tag : u64,
    /** The first block, from 0; with count, it has to lie within the disk, or it's OutOfRange. */
    first : u64,
    /** How many blocks, at least 1; 0 is OutOfRange. */
    count : u32,
    /**
     * Where the data is in the connection's buffer, in bytes from its start; the count of blocks' bytes from there
     * has to fit the buffer, or it's OutOfRange.
     */
    offset : u32,
}

/** How a request went. */
Status :: enum #backed_by(u32) {
    /** It's done: a Read's blocks are in the buffer, a Write's on the disk, a Flush's writes durable. */
    Done = 0,
    /** Past the disk's last block, or the buffer's end, a count of 0, or asked before the connection had a buffer. */
    OutOfRange = 1,
    /** A Write to a read-only disk. */
    ReadOnly = 2,
    /** The device said it failed; what a Write's blocks hold is unknown. */
    DeviceError = 3,
    /** Every slot for a request in flight is taken: send it again once one's answered. */
    Busy = 4,
}

/** A request answered: its tag, and how it went. */
Completion :: struct {
    /** The tag the request was sent with. */
    tag : u64,
    /** How it went. */
    status : Status,
}

/** What the disk is. */
Info :: struct {
    /** How many blocks it has, of BLOCK_BYTES; the last is block_count - 1. */
    block_count : u64,
    /** The size of its connection's buffer, in bytes, which a transfer's data has to fit. */
    buffer_bytes : u64,
    /** Whether it's read-only, so every Write is ReadOnly. */
    read_only : bool,
    /** Whether Flush does anything; without it, writes are durable when they're done. */
    flushes : bool,
}

/** What a client asks a disk's driver. */
Request :: union {
    /**
     * Read blocks into the connection's buffer. Answered with Finished, once the device has, or at once if not sent.
     */
    Read(Transfer),
    /**
     * Write blocks from the connection's buffer, which the client fills first and leaves alone until it's answered.
     * Answered with Finished, once the device has, or at once if not sent.
     */
    Write(Transfer),
    /**
     * Make everything written and done before it durable, with its tag. Answered with Finished: at once, Done, by a
     * disk that doesn't flush.
     */
    Flush(u64),
    /** Ask what the disk is. Answered with Described. */
    Describe,
    /**
     * Ask for a window onto the connection's buffer, read-write, made at the first ask. Answered with Buffer, or
     * Unsupported when it couldn't be made.
     */
    GetBuffer,
    /**
     * Have the driver serve another client, on the end given, which moves to the driver; it's closed if the driver
     * already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Block]),
}

/** What a disk's driver answers. */
Response :: union {
    /** Read's, Write's or Flush's answer: its tag and how it went, in the order the device finishes, not as asked. */
    Finished(Completion),
    /** Describe's answer: what the disk is. */
    Described(Info),
    /**
     * GetBuffer's answer: a window onto the connection's buffer, buffer_bytes of it, which moves to the client. The
     * buffer goes when the connection does.
     */
    Buffer(slop_os.Memory),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: a block written twice holds the same, and a flush again flushes nothing new.
 */
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

/**
 * Make a new connection to a disk's driver: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves its listener, or closes it when it's full, which the
 * caller learns of as its end's peer gone.
 *
 * @param end The driver's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
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
