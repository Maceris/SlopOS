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

import compiler from "base"
import intrinsics from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
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

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/** A Probe channel the test holds both ends of, with a port for each. */
Probes :: struct {
    /** The end requests are sent on. */
    a : slop_os.Channel,
    /** The end requests are received on. */
    b : slop_os.Channel,
    /** A port b is bound to for Readable, waited on until a message arrives. */
    port : slop_os.Port,
    /** A port a is bound to, which a send waits on if the ring is full. */
    sender_port : slop_os.Port,
}

/** What a receive gave, by its variant alone, so it can be compared and reported by name. */
Arrived :: enum {
    /** A message, now in the Incoming it was received into. */
    Received,
    /** Nothing to receive. */
    Empty,
    /** A variant this side doesn't know. */
    Unsupported,
    /** A message that breaks the rules, refused. */
    Invalid,
    /** A channel of another protocol where a typed one goes. */
    WrongProtocol,
    /** The receive failed. */
    Failed,
}

/**
 * Make a Probe channel the test holds both ends of, with a port for each.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The channel's ends and their ports, which the test closes; Error(Failed), recorded, if any couldn't be made.
 */
probes :: fn(t: ptr[mut testing.T]) -> Result[Probes, testing.Stopped] {
    block :: slop_os.startup_block()
    pair :: testing.require_ok(t, os.channel_for[Probe](block.budget, 8192), "a Probe channel is made")?
    port :: testing.require_some(t, os.port_for(block.budget, pair.b), "a port for the receiving end")?
    sender_port :: testing.require_some(t, os.port_for(block.budget, pair.a), "a port for the sending end")?
    return .Ok(Probes.{a = pair.a, b = pair.b, port = port, sender_port = sender_port})
}

/**
 * Close a Probe channel's ends and their ports.
 *
 * @param probes What probes made, each handle closed.
 */
close_probes :: fn(probes: Probes) {
    _ = slop_os.handle_close(cast[slop_os.Handle](probes.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](probes.b))
    _ = slop_os.handle_close(cast[slop_os.Handle](probes.port))
    _ = slop_os.handle_close(cast[slop_os.Handle](probes.sender_port))
}

/**
 * Check that a message with a bool, an enum, a handle, a Relative of bytes and a typed channel goes through: the handle
 * and the channel arrive in place, and the bytes read back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channel, the memory or the other channel couldn't be made.
 */
a_whole_message_arrives_with_its_handles_and_data #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    probe :: probes(t)?
    into := os.Incoming.{}
    memory :: testing.require_ok(t, slop_os.memory_create(block.budget, 4096), "memory to send")?
    other :: testing.require_ok(t, os.channel_for[Probe](block.budget, 0), "a Probe channel to send an end of")?
    numbers :: u64.[3, 1, 4, 1, 5]
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Carry(Everything.{flag = true, shade = .Dark, count = 9, memory = memory, data = os.append(&out, numbers[0..<5]),
        peer = os.Channel[Probe].{end = other.a}})
    testing.expect(t, send_request(probe.a, probe.sender_port, &out) == null, "a whole message is sent")
    testing.expect_eq(t, arrival_code(receive_request(probe.b, probe.port, &into, true)), Arrived.Received, "a whole message is received")
    match os.message_of[Request](&into)^ {
        case Carry(carried) => {
            got :: os.items(&into, carried.data)
            sum := cast[u64](0)
            for value in got {
                sum += value
            }
            testing.expect_eq(t, sum, 14, "a Relative's u64s read back as they were sent: 3, 1, 4, 1 and 5")
            testing.expect(t, carried.flag && carried.shade == .Dark && carried.count == 9, "a message's plain fields arrive as they were sent")
            // The memory and the channel are handles of this process's again, and the channel speaks Probe
            size :: slop_os.memory_size(carried.memory)
            testing.expect_ok(t, size, "a handle sent arrives in place, as a handle of the receiver's")
            testing.expect(t, os.speaks[Probe](carried.peer.end), "a typed channel sent arrives in place, speaking its protocol")
        }
        case _ => testing.fail(t, "a Carry sent arrives as a Carry")
    }
    close_probes(probe)
    return .Ok
}

/**
 * Check that messages made by hand that break the rules are refused as Invalid: too short for a tag, an enum or a
 * bool that can't be, a handle index past the batch, and a Relative past the message's end, over its fixed part, or
 * misaligned.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channel couldn't be made.
 */
broken_messages_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    probe :: probes(t)?
    into := os.Incoming.{}
    a :: probe.a
    b :: probe.b
    testing.expect_eq(t, refused(a, probe.sender_port, b, probe.port, &into, 0, 0, 0), Arrived.Invalid, "a message too short for its tag is refused")
    testing.expect_eq(t, refused(a, probe.sender_port, b, probe.port, &into, offset_of_field(.Shade), 7, 1), Arrived.Invalid, "an enum that's no member is refused")
    testing.expect_eq(t, refused(a, probe.sender_port, b, probe.port, &into, offset_of_field(.Flag), 2, 1), Arrived.Invalid, "a bool that's neither 0 nor 1 is refused")
    testing.expect_eq(t, refused(a, probe.sender_port, b, probe.port, &into, offset_of_field(.Memory), 5, 4), Arrived.Invalid, "a handle index past the message's batch is refused")
    // A Relative past the end, over the fixed part, and misaligned
    testing.expect_eq(t, refused_relative(a, probe.sender_port, b, probe.port, &into, 4096, 1), Arrived.Invalid, "a Relative past the message's end is refused")
    testing.expect_eq(t, refused_relative(a, probe.sender_port, b, probe.port, &into, 8, 1), Arrived.Invalid, "a Relative over the message's fixed part is refused")
    testing.expect_eq(t, refused_relative(a, probe.sender_port, b, probe.port, &into, cast[u32](size_of(Request)) + 3, 1), Arrived.Invalid, "a Relative misaligned for its items is refused")
    close_probes(probe)
    return .Ok
}

/**
 * Check that a variant this side doesn't know arrives as Unsupported, for answer_unsupported to answer.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channel couldn't be made.
 */
an_unknown_variant_is_unsupported #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    probe :: probes(t)?
    into := os.Incoming.{}
    unknown : u64[4]
    unknown[0] = 7
    none : slop_os.Handle[1]
    _ = os.send(probe.a, probe.sender_port, view_of(cast[ptr[u8]](&unknown[0]), 32), view_of(&none[0], 0))
    testing.expect_eq(t, arrival_code(receive_request(probe.b, probe.port, &into, true)), Arrived.Unsupported, "a variant tag this side doesn't know is Unsupported")
    close_probes(probe)
    return .Ok
}

/**
 * Check that a channel of another protocol, where a Channel[Probe] goes, arrives as WrongProtocol.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channel or the stranger channel couldn't be made.
 */
a_channel_of_another_protocol_is_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    probe :: probes(t)?
    into := os.Incoming.{}
    stranger :: testing.require_ok(t, slop_os.channel_create(block.budget, 0, 12345), "a channel of another protocol")?
    wrong := os.Outgoing.{}
    carried :: os.begin[Request](&wrong)
    carried^ = .Carry(Everything.{flag = false, shade = .Light, peer = os.Channel[Probe].{end = stranger.a}})
    _ = send_request(probe.a, probe.sender_port, &wrong)
    testing.expect_eq(t, arrival_code(receive_request(probe.b, probe.port, &into, true)), Arrived.WrongProtocol, "a channel whose tag isn't Probe's can't arrive as a Channel[Probe]")
    close_probes(probe)
    return .Ok
}

/**
 * Check that a message shorter than the type, as an older sender's, reads its missing fields as zeros: Ping with
 * nothing after its tag reads as Ping(0).
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channel couldn't be made.
 */
a_short_message_reads_its_missing_fields_as_zeros #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    probe :: probes(t)?
    into := os.Incoming.{}
    short : u8[1]
    short[0] = 0
    none : slop_os.Handle[1]
    _ = os.send(probe.a, probe.sender_port, short, view_of(&none[0], 0))
    testing.expect_eq(t, arrival_code(receive_request(probe.b, probe.port, &into, true)), Arrived.Received, "a message shorter than its type is received")
    match os.message_of[Request](&into)^ {
        case Ping(value) => testing.expect_eq(t, value, 0, "a field past a short message's end reads as zero")
        case _ => testing.fail(t, "a message of only Ping's tag arrives as a Ping")
    }
    close_probes(probe)
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Give what a receive gave by its variant alone.
 *
 * @param arrival What the receive gave; a Failed's error is dropped.
 * @return Its variant, as an Arrived.
 */
arrival_code :: fn(arrival: os.Arrival) -> Arrived {
    return match arrival {
        case Received => Arrived.Received
        case Empty => Arrived.Empty
        case Unsupported => Arrived.Unsupported
        case Invalid => Arrived.Invalid
        case WrongProtocol => Arrived.WrongProtocol
        case Failed(error) => Arrived.Failed
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
    offset: usize, value: u64, size: usize) -> Arrived {
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
    into: ptr[mut os.Incoming], start: u32, count: u32) -> Arrived {
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
