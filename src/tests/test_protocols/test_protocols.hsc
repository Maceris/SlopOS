/*
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

NAME :: "test_protocols"

Probe :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "probe", major_version = 1, lending = .Server}

Shade :: enum #backed_by(u8) {
    Light = 1,
    Dark = 2,
}

Everything :: struct {
    flag : bool,
    shade : Shade,
    count : u32,
    memory : slop_os.Memory,
    data : slop_os.Relative[u64],
    peer : os.Channel[Probe],
}

Request :: union {
    Ping(u32),
    Carry(Everything),
}

Response :: union {
    Pong(u32),
    Unsupported,
}

// A ping is answered the same again; a carry moves handles, which only happens once.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Ping(_) => true
        case Carry(_) => false
    }
}

#insert os.protocol_code(Request, Response)

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

// What a receive gave, as a number.
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

Field :: enum {
    Flag,
    Shade,
    Memory,
    Data,
}

// Where a field of Carry's Everything is in a message.
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

// Where Carry's Everything starts: after the tag, aligned for it.
payload_offset :: fn() -> usize {
    alignment :: align_of(Everything)
    return (1 + alignment - 1) & ~(alignment - 1)
}

/*
 * A Carry made by hand, with size bytes at offset set to value (or no tag at all with size 0), and no handles:
 * what receiving it gave.
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

// A Carry made by hand whose data is count u64s at start, with room after its fixed part: what receiving it gave.
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

// value at bytes[at], if there's room.
put :: fn(bytes: mut u8[], at: usize, value: u8) {
    if at < bytes.count {
        bytes[at] = value
    }
}
