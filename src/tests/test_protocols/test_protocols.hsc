/**
 * test_protocols (decisions/0071): the code os.protocol_code generates, for a protocol of the test's own, Probe,
 * over a channel the test holds both ends of:
 * - a message with a bool, an enum, a handle, a Relative of bytes and a typed channel goes through: the handle and
 *   the channel arrive in place, and the bytes read back;
 * - messages made by hand that break the rules are refused, and their handles closed: too short for a tag, an
 *   enum or a bool that can't be, a handle index past the batch, a Relative past the message's end, over its
 *   fixed part, or misaligned;
 * - a variant this side doesn't know is Unsupported, which answer_unsupported answers;
 * - a channel of another protocol where a Channel[Probe] goes is WrongProtocol;
 * - a message shorter than the type, as an older sender's, reads its missing fields as zeros.
 */
package test_protocols

import intrinsics from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_protocols"

/** The test's own protocol, for the channel it holds both ends of. */
Probe :: struct {}

/** What Probe says of itself: its name, which its channels' tag is made from, and its major version. */
PROTOCOL :: slop_os.Protocol.{name = "probe", major_version = 1, lending = .Server}

/** An enum a message carries, whose 0 isn't a member, so a message with 0 or 7 in its place is refused. */
Shade :: enum #backed_by(u8) {
    /** A light shade; what hand-made messages use. */
    Light = 1,
    /** A dark shade; what the whole message carries. */
    Dark = 2,
}

/** A message's payload with one of every kind of field the generated code checks. */
Everything :: struct {
    /** A bool, which a message refuses as anything but 0 or 1. */
    flag : bool,
    /** An enum, which a message refuses as a value that's no member. */
    shade : Shade,
    /** A plain number, which any value is good for. */
    count : u32,
    /** A handle, as its index in the message's batch, which the receiver gets as a handle of its own. */
    memory : slop_os.Memory,
    /** u64s after the message's fixed part, by offset and count, which have to be within the message and aligned. */
    data : slop_os.Relative[u64],
    /** A typed channel end, which has to speak Probe. */
    peer : os.Channel[Probe],
}

/** What's sent over a Probe channel. */
Request :: union {
    /** A number, which a short message of only the tag reads as 0. */
    Ping(u32),
    /** One of everything. */
    Carry(Everything),
}

/** What's answered over a Probe channel. */
Response :: union {
    /** A ping's number, answered. */
    Pong(u32),
    /** The answer to a request of a variant the receiver doesn't know. */
    Unsupported,
}

/**
 * Tell whether a request can be sent again, unanswered, with the same effect, as the generated code asks.
 *
 * @param request The request, as received or about to be sent; only its variant is read.
 * @return True for a Ping, answered the same again; false for a Carry, which moves handles, which only happens once.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Ping(_) => true
        case Carry(_) => false
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Check the code os.protocol_code generates: a whole message through, broken ones refused, an unknown variant, a
 * channel of another protocol, and a short message.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return 0 if every check passed. Otherwise the first that failed, by its result's index plus one: 1 sending the
 *     whole message, or 2 receiving it; 3 its bytes, 4 its plain fields, 5 its memory or 6 its channel not arriving
 *     as they were sent; a message refused as Invalid 7 with no tag, 8 with an enum, 9 a bool, that can't be, 10 a
 *     handle index past the batch, 11 a Relative past the message's end, 12 over its fixed part, or 13 misaligned,
 *     not refused; 14 an unknown variant not Unsupported; 15 a channel of another protocol not WrongProtocol; 16 a
 *     short Ping not read as Ping(0). 100 to 104 if setting up failed: 100 the channel, 101 its ports, 102 the
 *     memory, 103 the other channel, 104 the stranger channel.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    pair :: os.channel_for[Probe](block.budget, 8192) or_return 100
    port :: os.port_for(block.budget, pair.b) or_return 101
    sender_port :: os.port_for(block.budget, pair.a) or_return 101
    results : u64[16]
    into := os.Incoming.{}

    // A whole message, through
    memory :: slop_os.memory_create(block.budget, 4096) or_return 102
    other :: os.channel_for[Probe](block.budget, 0) or_return 103
    numbers :: u64.[3, 1, 4, 1, 5]
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Carry(Everything.{flag = true, shade = .Dark, count = 9, memory = memory, data = os.append(&out, numbers[0..<5]),
        peer = os.Channel[Probe].{end = other.a}})
    results[0] = if send_request(pair.a, sender_port, &out) == null { cast[u64](0) } else { cast[u64](1) }
    results[1] = arrival_code(receive_request(pair.b, port, &into, true))
    match os.message_of[Request](&into)^ {
        case Carry(carried) => {
            got :: os.items(&into, carried.data)
            sum := cast[u64](0)
            for value in got {
                sum += value
            }
            results[2] = sum
            results[3] = if carried.flag && carried.shade == .Dark && carried.count == 9 { cast[u64](1) } else { cast[u64](0) }
            // The memory and the channel are handles of this process's again, and the channel speaks Probe
            results[4] = cast[u64](test_kit.tag_of(slop_os.memory_size(carried.memory)))
            results[5] = if os.speaks[Probe](carried.peer.end) { cast[u64](1) } else { cast[u64](0) }
        }
        case _ => {}
    }

    // Broken messages, each refused
    results[6] = refused(pair.a, sender_port, pair.b, port, &into, 0, 0, 0)
    results[7] = refused(pair.a, sender_port, pair.b, port, &into, offset_of_field(.Shade), 7, 1)
    results[8] = refused(pair.a, sender_port, pair.b, port, &into, offset_of_field(.Flag), 2, 1)
    results[9] = refused(pair.a, sender_port, pair.b, port, &into, offset_of_field(.Memory), 5, 4)
    // A Relative past the end, over the fixed part, and misaligned
    results[10] = refused_relative(pair.a, sender_port, pair.b, port, &into, 4096, 1)
    results[11] = refused_relative(pair.a, sender_port, pair.b, port, &into, 8, 1)
    results[12] = refused_relative(pair.a, sender_port, pair.b, port, &into, cast[u32](size_of(Request)) + 3, 1)

    // A variant this side doesn't know
    unknown : u64[4]
    unknown[0] = 7
    none : slop_os.Handle[1]
    _ = os.send(pair.a, sender_port, view_of(cast[ptr[u8]](&unknown[0]), 32), view_of(&none[0], 0))
    results[13] = arrival_code(receive_request(pair.b, port, &into, true))

    // A channel of another protocol where a Channel[Probe] goes
    stranger :: slop_os.channel_create(block.budget, 0, 12345) or_return 104
    wrong := os.Outgoing.{}
    carried :: os.begin[Request](&wrong)
    carried^ = .Carry(Everything.{flag = false, shade = .Light, peer = os.Channel[Probe].{end = stranger.a}})
    _ = send_request(pair.a, sender_port, &wrong)
    results[14] = arrival_code(receive_request(pair.b, port, &into, true))

    // A short message, as an older sender's: Ping with nothing after its tag reads as Ping(0)
    short : u8[1]
    short[0] = 0
    _ = os.send(pair.a, sender_port, short, view_of(&none[0], 0))
    results[15] = arrival_code(receive_request(pair.b, port, &into, true))
    match os.message_of[Request](&into)^ {
        case Ping(value) => {
            if value != 0 {
                results[15] = 99
            }
        }
        case _ => results[15] = 98
    }
    // RECEIVED 0, UNSUPPORTED 2, INVALID 3, WRONG_PROTOCOL 4
    expected :: u64.[0, 0, 14, 1, 0, 1, 3, 3, 3, 3, 3, 3, 3, 2, 4, 0]
    failed :: test_kit.check(log, NAME, results, expected)
    if failed == 0 {
        log_line.write(log, "%: messages went through with their handles and data, and broken, unknown and mistyped ones were refused", NAME)
    }
    return failed
}

/**
 * Give what a receive gave as a number, for a result.
 *
 * @param arrival What the receive gave.
 * @return 0 Received, 1 Empty, 2 Unsupported, 3 Invalid, 4 WrongProtocol, 5 Failed.
 */
arrival_code :: fn(arrival: os.Arrival) -> u64 {
    return match arrival {
        case Received => cast[u64](0)
        case Empty => cast[u64](1)
        case Unsupported => cast[u64](2)
        case Invalid => cast[u64](3)
        case WrongProtocol => cast[u64](4)
        case Failed(error) => cast[u64](5)
    }
}

/** A field of Everything a hand-made message sets. */
Field :: enum {
    /** Everything's flag. */
    Flag,
    /** Everything's shade. */
    Shade,
    /** Everything's memory. */
    Memory,
    /** Everything's data. */
    Data,
}

/**
 * Tell where a field of Carry's Everything is in a message.
 *
 * @param field Any of the four fields; any value but Flag, Shade and Memory is taken as Data.
 * @return Its offset in the message, in bytes from its start, the tag's byte.
 */
offset_of_field :: fn(field: Field) -> usize {
    payload :: payload_offset()
    if field == .Flag {
        return payload + offset_of(Everything, flag)
    }
    if field == .Shade {
        return payload + offset_of(Everything, shade)
    }
    if field == .Memory {
        return payload + offset_of(Everything, memory)
    }
    return payload + offset_of(Everything, data)
}

/**
 * Tell where Carry's Everything starts in a message.
 *
 * @return Its offset in bytes: after the tag's one byte, aligned for Everything.
 */
payload_offset :: fn() -> usize {
    alignment :: align_of(Everything)
    return (1 + alignment - 1) & ~(alignment - 1)
}

/**
 * Send a Carry made by hand, with a field broken, and no handles, and receive it.
 *
 * The rest of the message is a valid Carry: a Light shade, and the handles' indices all ones, no handle.
 *
 * @param end The Probe channel's end the message is sent on, kept open; it's sent with no handles.
 * @param sender_port A port end is bound to, which the send waits on if the ring is full.
 * @param reader The peer of end, kept open, read once, waiting for the message; what's received is left in into.
 * @param port A port reader is bound to for Readable, waited on until the message arrives.
 * @param into Where the message is received, zeroed first; a refused message leaves no handles there.
 * @param offset Where in the message the broken bytes go.
 * @param value What they're set to, little-endian.
 * @param size How many bytes are set, at most 8; 0 sends a message of no bytes at all, not even a tag.
 * @return What receiving it gave, as arrival_code gives it.
 */
refused :: fn(end: slop_os.Channel, sender_port: slop_os.Port, reader: slop_os.Channel, port: slop_os.Port, into: ptr[mut os.Incoming],
    offset: usize, value: u64, size: usize) -> u64 {
    message : u64[64]
    bytes :: view_of(cast[ptr[mut u8]](&message[0]), size_of(Request))
    none : slop_os.Handle[1]
    if size == 0 {
        // Nothing at all, not even a tag
        empty : u8[1]
        _ = os.send(end, sender_port, view_of(&empty[0], 0), view_of(&none[0], 0))
        return arrival_code(receive_request(reader, port, into, true))
    }
    put(bytes, 0, 1)
    // A valid Carry otherwise: a Light shade, no handles
    shade_at :: offset_of_field(.Shade)
    put(bytes, shade_at, 1)
    memory_at :: offset_of_field(.Memory)
    peer_at :: payload_offset() + offset_of(Everything, peer)
    for i in cast[usize](0)..<4 {
        put(bytes, memory_at + i, 0xff)
        put(bytes, peer_at + i, 0xff)
    }
    for i in 0..<size {
        put(bytes, offset + i, cast[u8](value >> cast[u64](8 * i)))
    }
    _ = os.send(end, sender_port, bytes, view_of(&none[0], 0))
    return arrival_code(receive_request(reader, port, into, true))
}

/**
 * Send a Carry made by hand whose data is count u64s at start, with 64 bytes of room after its fixed part, and
 * receive it.
 *
 * @param end The Probe channel's end the message is sent on, kept open; it's sent with no handles.
 * @param sender_port A port end is bound to, which the send waits on if the ring is full.
 * @param reader The peer of end, kept open, read once, waiting for the message; what's received is left in into.
 * @param port A port reader is bound to for Readable, waited on until the message arrives.
 * @param into Where the message is received, zeroed first; a refused message leaves no handles there.
 * @param start The data's offset, in bytes from the message's start.
 * @param count How many u64s the data has.
 * @return What receiving it gave, as arrival_code gives it.
 */
refused_relative :: fn(end: slop_os.Channel, sender_port: slop_os.Port, reader: slop_os.Channel, port: slop_os.Port,
    into: ptr[mut os.Incoming], start: u32, count: u32) -> u64 {
    data_at :: offset_of_field(.Data)
    message : u64[64]
    bytes :: view_of(cast[ptr[mut u8]](&message[0]), size_of(Request) + 64)
    put(bytes, 0, 1)
    shade_at :: offset_of_field(.Shade)
    put(bytes, shade_at, 1)
    memory_at :: offset_of_field(.Memory)
    peer_at :: payload_offset() + offset_of(Everything, peer)
    for i in cast[usize](0)..<4 {
        put(bytes, memory_at + i, 0xff)
        put(bytes, peer_at + i, 0xff)
        put(bytes, data_at + i, cast[u8](start >> cast[u32](8 * i)))
        put(bytes, data_at + 4 + i, cast[u8](count >> cast[u32](8 * i)))
    }
    none : slop_os.Handle[1]
    _ = os.send(end, sender_port, bytes, view_of(&none[0], 0))
    return arrival_code(receive_request(reader, port, into, true))
}

/**
 * Set a byte of a message, if there's room.
 *
 * @param bytes The message being built, changed in place; only bytes inside it are set.
 * @param at The byte's index; one past the end is ignored.
 * @param value What it's set to.
 */
put :: fn(bytes: mut u8[], at: usize, value: u8) {
    if at < bytes.count {
        bytes[at] = value
    }
}
