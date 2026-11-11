package net

import os from "std"
import slop_os from "std/os"

/*
 * The device class of network interfaces (decisions/0188, 13a): Ethernet frames between a NIC's driver and its client,
 * the network service. Frames move through slots in a buffer the driver makes for the connection, DMA memory the client
 * reaches through a window (GetBuffer), so the device reads and writes them with no copies: SLOTS receive slots, then
 * SLOTS send slots, SLOT_BYTES each, a frame from a slot's start.
 *
 * A receive slot is given to the driver with Receive, held until a frame arrives in it, and answered with Received; the
 * client gives it again once it's done with the frame. A send slot's frame goes with Send, answered with Sent once the
 * device has taken it, when the slot is the client's again. Answers come as the device finishes, in any order. A driver
 * serves one client at a time; a new connection's client takes over the slots the last left given.
 */

/**
 * The net protocol, for the channels between a NIC's driver and its client, and its listener: the client sends the
 * requests, and the driver answers them.
 */
Net :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * client's budget is lent for each of its connections, which pays for the driver's work on it.
 */
PROTOCOL :: slop_os.Protocol.{name = "net", major_version = 1, lending = .PerConnection}

/** How many receive slots a connection's buffer has, and how many send slots after them: 64 each. */
SLOTS : u32 : 64
/** The bytes of each slot, which holds one frame from its start: 2048. */
SLOT_BYTES : u32 : 2048
/** The bytes of a connection's buffer: 2 * SLOTS slots, 256 KiB. */
BUFFER_BYTES : u64 : 2 * cast[u64](SLOTS) * cast[u64](SLOT_BYTES)
/**
 * The bytes of a connection's ring, 16 KiB, which connect makes it with: every receive slot given and every send slot's
 * frame sent at once, and their answers, fit without waiting for room.
 */
RING_BYTES : u32 : 16384
/** The longest frame without its frame check sequence, for an MTU of 1500: 14 bytes of header and 1500 of payload. */
MAX_FRAME : u32 : 1514
/** The fewest bytes a frame sent has: 14, its header. Shorter ones are refused; the device pads short frames. */
MIN_FRAME : u32 : 14

/**
 * Info.offloads's bit for an interface that completes a sent frame's checksum, from Frame.checksum_start to the frame's
 * end, written at checksum_at bytes past checksum_start: a TCP or UDP checksum, which the client starts with the
 * pseudo-header's sum.
 */
OFFLOAD_SEND_CHECKSUM : u32 : 1
/** Info.offloads's bit for an interface that checks received frames' TCP and UDP checksums (CHECKSUM_VALID). */
OFFLOAD_RECEIVE_CHECKSUM : u32 : 2
/** Frame.flags's bit for a received frame whose TCP or UDP checksum was checked, and is right. */
CHECKSUM_VALID : u32 : 1

/** A frame in a slot. */
Frame :: struct {
    /**
     * The slot, by number: 0 to SLOTS - 1 for receive slots, SLOTS to 2 * SLOTS - 1 for send slots, at slot *
     * SLOT_BYTES in the buffer.
     */
    slot : u32,
    /** The frame's length in bytes, from the slot's start, its header included and its frame check sequence not. */
    length : u32,
    /** Received: CHECKSUM_VALID, or 0. Sent: 0. */
    flags : u32,
    /**
     * Sent, with OFFLOAD_SEND_CHECKSUM: where the checksummed part starts, in bytes from the frame's start; 0 for no checksum
     * to complete, as for a frame without TCP or UDP. Received: 0.
     */
    checksum_start : u16,
    /** Sent, with checksum_start: where the checksum goes, in bytes past checksum_start. Received: 0. */
    checksum_at : u16,
}

/** What the interface is. */
Info :: struct {
    /** Its MAC address, in the order it's sent. */
    mac : u8[6],
    /** The largest IP packet it carries, in bytes: 1500 unless the device says less; frames are 14 bytes more. */
    mtu : u16,
    /** Whether its link is up, as Describe found it. */
    link_up : bool,
    /** What it does for its client: OFFLOAD_ bits. */
    offloads : u32,
    /** How many receive slots, and how many send slots, the buffer has: SLOTS. */
    slots : u32,
    /** The bytes of each slot: SLOT_BYTES. */
    slot_bytes : u32,
}

/** Why a Receive or Send was refused. */
Refusal :: enum #backed_by(u32) {
    /** The slot isn't one of its kind: a Receive's not a receive slot, a Send's not a send slot. */
    WrongSlot = 0,
    /** A Send's length is under MIN_FRAME or over the slot, or its checksum's place isn't in the frame. */
    BadFrame = 1,
    /** The connection has no buffer yet: GetBuffer first. */
    NoBuffer = 2,
    /** A Send's slot already has a frame the device hasn't taken. */
    Busy = 3,
}

/** A refused request: its slot, and why. */
Refused :: struct {
    /** The slot it named. */
    slot : u32,
    /** Why. */
    reason : Refusal,
}

/** What a client asks a NIC's driver. */
Request :: union {
    /** Ask what the interface is. Answered with Described. */
    Describe,
    /**
     * Ask for a window onto the connection's buffer, read-write, made at the first ask and kept for the driver's life,
     * so a new connection's client sees the same slots. Answered with Buffer, or Unsupported when it couldn't be made.
     */
    GetBuffer,
    /**
     * Give a receive slot to the device, for a frame to arrive in. Answered with Received once one has, or with
     * Refused. A slot given already, as by the last connection, stays given, answered to this one.
     */
    Receive(u32),
    /**
     * Send the frame in a send slot, which the client leaves alone until it's answered. Answered with Sent once the
     * device has taken it, or with Refused.
     */
    Send(Frame),
    /** Wait for the link to be other than the given state: up for true. Answered with Link once it is, maybe at once. */
    WatchLink(bool),
    /**
     * Have the driver serve another client, on the end given, which moves to the driver; the client before, if any,
     * is closed. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Net]),
}

/** What a NIC's driver answers. */
Response :: union {
    /** Describe's answer: what the interface is. */
    Described(Info),
    /**
     * GetBuffer's answer: a window onto the connection's buffer, BUFFER_BYTES of it, which moves to the client.
     */
    Buffer(slop_os.Memory),
    /** Receive's answer: the frame that arrived in its slot. */
    Received(Frame),
    /** Send's answer, by its slot: the device has taken the frame, and the slot is the client's again. */
    Sent(u32),
    /** Receive's or Send's answer when it's refused. */
    Refused(Refused),
    /** WatchLink's answer: whether the link is up now. */
    Link(bool),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Send, whose frame would go twice; true for the rest.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case GetBuffer => true
        case Receive(_) => true
        case Send(_) => false
        case WatchLink(_) => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to a NIC's driver: a channel for the protocol, one end sent to it in a Connect, as
 * block.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves its listener. The channel's ring is RING_BYTES.
 *
 * @param end The driver's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Net]? {
    pair :: os.channel_for[Net](budget, RING_BYTES) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Net].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Net].{end = pair.b}
    }
}

/**
 * Ask a NIC's driver what the interface is, and wait for the answer.
 *
 * @param end A connection to the driver, the caller's, with no other answer due before this one's.
 * @param port A port bound to end, waited on.
 * @return What the interface is; null if the request couldn't be sent, the connection failed, or the answer was
 *     something else.
 */
describe :: fn(end: slop_os.Channel, port: slop_os.Port) -> Info? {
    into := os.Incoming.{}
    if !call(end, port, Request.Describe, &into) {
        return null
    }
    return match os.message_of[Response](&into)^ {
        case Described(info) => info
        case _ => null
    }
}

/**
 * Ask a NIC's driver for a window onto the connection's buffer, and wait for the answer.
 *
 * @param end A connection to the driver, the caller's, with no other answer due before this one's.
 * @param port A port bound to end, waited on.
 * @return The window, BUFFER_BYTES, the caller's to map and close; null if the request couldn't be sent, the
 *     connection failed, or the driver couldn't make it.
 */
get_buffer :: fn(end: slop_os.Channel, port: slop_os.Port) -> slop_os.Memory? {
    into := os.Incoming.{}
    if !call(end, port, Request.GetBuffer, &into) {
        return null
    }
    return match os.message_of[Response](&into)^ {
        case Buffer(memory) => memory
        case _ => null
    }
}

/**
 * Send a request that has no variable-size data, and wait for the next answer.
 *
 * @param end A connection to the driver, the caller's.
 * @param port A port bound to end, waited on.
 * @param request The request.
 * @param into Where the answer's received, for message_of.
 * @return True once an answer is in into; false if the request couldn't be sent, or receiving failed.
 */
call :: fn(end: slop_os.Channel, port: slop_os.Port, request: Request, into: ptr[mut os.Incoming]) -> bool {
    out := os.Outgoing.{}
    made :: os.begin[Request](&out)
    made^ = request
    if send_request(end, port, &out) is_some {
        return false
    }
    return match receive_response(end, port, into, true) {
        case Received => true
        case _ => false
    }
}
