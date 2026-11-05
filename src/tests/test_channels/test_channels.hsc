/**
 * test_channels (decisions/0069, from the kernel's test of 0053): processes A, the program, and B, a copy of
 * it A launches, start with the ends of one channel, c0, between them, and:
 * - A makes a channel, maps one end, x, and sends the other, y, to B in a batch, with a message through
 *   the kernel naming it; sending x, which is mapped, or c0's own end, fails. B reads the message through the
 *   kernel and takes y;
 * - both map their ends and trade messages through the rings, with the wake protocol: a reader that
 *   finds nothing says it waits, looks again, and waits on its port; a writer that sees it waiting rings
 *   the doorbell. A answers with ChannelNotifyAndWait;
 * - a Once binding of A's sees B's Writable once: A takes the packet and tells B, which raises it again
 *   and says so; A sees no second packet, until it binds the key again;
 * - B closes y: A sees PeerClosed, and writing or reading x fails with it. Closing x unmaps its rings,
 *   and so does ChannelUnmap, so another channel's can be mapped there;
 * - B sends A what it found through c0, and ends; what A made, and B, charged their budgets comes back.
 */
package test_channels

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_channels"
/** The value of the message A sends B through the kernel, and of the other messages written through it. */
CHANNEL_VALUE : u64 : 0x1122334455667788
/** B's first message to A through the rings. */
FROM_B : u64 : 0xb0b
/** A's first message to B through the rings. */
FIRST_FROM_A : u64 : 0xa0a
/** A's message to B through the rings once its Once binding is armed again. */
SECOND_FROM_A : u64 : 0xa0b
/** A's message to B through the rings saying it took the Once binding's packet. */
TOOK_IT : u64 : 0xa0c
/** B's message to A through the rings saying it raised Writable again. */
RAISED_AGAIN : u64 : 0xb0c
/** The key B's binding of c0 queues packets under. */
KEY_C0 : u64 : 1
/** The key B's binding of y queues packets under. */
KEY_Y : u64 : 2
/** The key A's persistent binding of x, for Readable and PeerClosed, queues packets under. */
KEY_X : u64 : 5
/** The key A's Once bindings queue packets under, and the bound-before-read check's binding. */
KEY_ONCE : u64 : 8
/** How long A waits to see that no packet comes, in nanoseconds: 20 ms; the other checks wait multiples of it. */
SHORT_WAIT_NANOSECONDS : u64 : 20_000_000
/** How many results B keeps, and sends A, each a slot below. */
B_RESULTS :: 13
/** B's result slot for binding c0 to its port, as test_kit.tag_of gives it: 0 if it bound. */
B_BOUND_C0 :: 0
/** B's result slot for the size of A's message through the kernel, in bytes; or 0xdead0000 plus the read's error tag. */
B_SIZE :: 1
/** B's result slot for that message's flags and batch, as channel_read gives them. */
B_FLAGS_AND_BATCH :: 2
/** B's result slot for that message's value. */
B_VALUE :: 3
/** B's result slot for how many handles B took from the message's batch. */
B_TAKEN :: 4
/** B's result slot for taking the batch again, as test_kit.tag_of gives it. */
B_TAKEN_AGAIN :: 5
/** B's result slot for mapping y, as test_kit.tag_of gives it. */
B_MAPPED_Y :: 6
/** B's result slot for binding y to its port, as test_kit.tag_of gives it. */
B_BOUND_Y :: 7
/** B's result slot for A's first message through the rings. */
B_FIRST :: 8
/** B's result slot for A's message once its Once binding is armed again. */
B_SECOND :: 9
/** B's result slot for closing y, as test_kit.tag_of gives it. */
B_CLOSED_Y :: 10
/** B's result slot set to 1 once B has done everything before sending its results. */
B_FINISHED :: 11
/** B's result slot for A's message saying it took the Once binding's packet. */
B_TOOK_IT :: 12

/** What B is given, as main takes it: its log, and its end of c0. */
BGrants :: struct {
    /** A copy of A's debug log, writable. */
    log : slop_os.DebugLog,
    /** Not given. */
    platform : slop_os.Platform?,
    /** Not given. */
    test_device : slop_os.Memory?,
    /** Not given. */
    firmware : slop_os.Memory?,
    /** Not given. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Not given. */
    program : slop_os.Memory?,
    /** B's end of c0, which makes main run as B. */
    peer : slop_os.Channel?,
    /** Not given. */
    cpu_budget : slop_os.CpuBudget?,
}

/**
 * Write one 8-byte message into a ring of a mapped channel, as the wake protocol has it. The test's messages are
 * few, so there's always room, and that isn't checked.
 *
 * @param memory Where the writing end's rings are mapped.
 * @param side Which ring is written, 0 or 1: the one the end writes, its own side.
 * @param value The message's 8 bytes, any value; written after its 8-byte length word, then published by moving the
 *     tail on by 16.
 * @return Whether the reader says it waits, so the writer has to ring the doorbell (channel_notify with Readable).
 */
ring_send :: fn(memory: u64, side: u64, value: u64) -> bool {
    indices :: memory + side * 128
    ring :: memory + cast[u64](slop_os.CHANNEL_RINGS_OFFSET) + side * cast[u64](slop_os.CHANNEL_DEFAULT_RING)
    mask :: cast[u64](slop_os.CHANNEL_DEFAULT_RING) - 1
    tail :: intrinsics.atomic_load_u32(cast[ptr[u32]](indices))
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](ring + (cast[u64](tail) & mask)), 8)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](ring + ((cast[u64](tail) + 8) & mask)), value)
    intrinsics.atomic_store_u32_release(cast[ptr[mut u32]](indices), tail + 16)
    intrinsics.fence_sequentially_consistent()
    return intrinsics.atomic_load_u32(cast[ptr[u32]](indices + 68)) != 0
}

/**
 * Read the next 8-byte message from a ring of a mapped channel, waiting for it if there's none, as the wake
 * protocol has it: say it waits, look once more, then wait on the port.
 *
 * @param memory Where the reading end's rings are mapped.
 * @param side Which ring is read, 0 or 1: the other end's side.
 * @param port A port the reading end is bound to for Readable, so the writer's doorbell wakes it.
 * @param once Counts each KEY_ONCE packet taken from port while waiting, so a Once binding's packet isn't lost.
 * @return The message's 8 bytes, any value; the length word before it isn't checked. Doesn't return until one comes.
 */
ring_receive :: fn(memory: u64, side: u64, port: slop_os.Port, once: ptr[mut u64]) -> u64 {
    indices :: memory + side * 128
    ring :: memory + cast[u64](slop_os.CHANNEL_RINGS_OFFSET) + side * cast[u64](slop_os.CHANNEL_DEFAULT_RING)
    mask :: cast[u64](slop_os.CHANNEL_DEFAULT_RING) - 1
    head_at :: cast[ptr[mut u32]](indices + 64)
    waiting_at :: cast[ptr[mut u32]](indices + 68)
    loop {
        head :: intrinsics.atomic_load_u32(head_at)
        tail :: intrinsics.atomic_load_u32_acquire(cast[ptr[u32]](indices))
        if tail != head {
            intrinsics.atomic_store_u32(waiting_at, 0)
            value :: intrinsics.volatile_load_u64(cast[ptr[u64]](ring + ((cast[u64](head) + 8) & mask)))
            intrinsics.atomic_store_u32_release(head_at, head + 16)
            return value
        }
        intrinsics.atomic_store_u32(waiting_at, 1)
        intrinsics.fence_sequentially_consistent()
        if intrinsics.atomic_load_u32_acquire(cast[ptr[u32]](indices)) == head {
            packets : slop_os.Packet[4]
            taken :: cast[usize](slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0)
            for packet, i in packets {
                if i < taken && packet.key == KEY_ONCE {
                    once^ += 1
                }
            }
        }
    }
}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, duplicated for B. */
    log : slop_os.DebugLog,
    /** The process manager, which launches B; none if main wasn't given it. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which B is launched from; none if main wasn't given it. */
    program : slop_os.Memory?,
}

/**
 * Run the tests as A, reporting to the debug log; or, run as B, be the other end.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches B; without it the test that needs it fails.
 * @param program The test's own module, which B is launched from; without it the test that needs it fails.
 * @param peer Given only to B, by A: its end of c0. With it, this runs as B.
 * @param cpu_budget Not used.
 * @return How many tests failed, 0 when every one passed; as B, what run_b gives.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(c0) => return run_b(c0)
        case None => {}
    }
    given :: Given.{log = log, manager = manager, program = program}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Check channels between two processes, as A, with B a copy it launches: handles in batches, messages through the
 * kernel and the rings, the wake protocol, Once bindings, closing an end, unmapping rings, then what B found, and what
 * B and A's objects charged their budgets coming back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the process manager or its module, or the memory budget, the
 *     ring addresses, the port, c0, x and y, the manager's port, the log's copy, B, or c0's port couldn't be made, or
 *     B's results couldn't be received.
 */
handles_and_messages_pass_between_processes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    space :: block.space
    manager :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    program :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for A's objects")?
    ring_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](slop_os.channel_memory_size(slop_os.CHANNEL_DEFAULT_RING))), "addresses for x's rings")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port for x")?
    // c0, and B, a copy of this program given its other end
    first :: testing.require_ok(t, slop_os.channel_create(budget, 0, 0), "c0, the channel between A and B")?
    c0 :: first.a
    manager_port :: testing.require_some(t, os.port_for(block.budget, manager.end), "a port for the process manager's replies")?
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](given.log), log_rights), "the debug log can be copied for B")?
    launch :: os.launch(manager, manager_port, "test_channels B", program, 4 << 20, main, BGrants.{log = cast[slop_os.DebugLog](log_copy), peer = first.b})
    b :: testing.require_ok(t, launch, "the process manager launches B with its end of c0")?
    pair :: testing.require_ok(t, slop_os.channel_create(budget, 0, 0), "x and y, a channel's ends, are made")?
    x :: pair.a
    y :: pair.b
    small_ring :: slop_os.channel_create(budget, 1000, 0)
    testing.expect_error(t, small_ring, slop_os.ChannelError.InvalidSize, "a channel's ring is a power of two of bytes, which 1000 isn't")
    mapped :: slop_os.channel_map(x, space, ring_at)
    testing.expect_ok(t, mapped, "an end's rings map")
    mapped_again :: slop_os.channel_map(x, space, ring_at + 0x10000)
    testing.expect_error(t, mapped_again, slop_os.ChannelError.Mapped, "an end's rings are mapped once")
    // Sending: x is mapped, c0 is the channel's own end, and y goes
    handles : slop_os.Handle[1]
    handles[0] = cast[slop_os.Handle](x)
    sent_mapped :: slop_os.channel_send_handles(c0, handles, 3)
    testing.expect_error(t, sent_mapped, slop_os.ChannelError.Mapped, "an end whose rings are mapped can't be sent")
    handles[0] = cast[slop_os.Handle](c0)
    sent_itself :: slop_os.channel_send_handles(c0, handles, 3)
    testing.expect_error(t, sent_itself, slop_os.ChannelError.NotTransferable, "an end can't be sent through its own channel")
    handles[0] = cast[slop_os.Handle](y)
    sent_y :: slop_os.channel_send_handles(c0, handles, 3)
    testing.expect_ok(t, sent_y, "an end is sent to B in a batch")
    value := CHANNEL_VALUE
    named :: slop_os.channel_write(c0, os.bytes_of(&value), 3)
    testing.expect_ok(t, named, "a message through the kernel names the batch")
    writable :: cast[u64](cast[u32](slop_os.SIGNAL_WRITABLE))
    peer_closed :: cast[u64](cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    any_x :: cast[slop_os.Handle](x)
    readable_or_closed :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    bound :: slop_os.port_bind(port, any_x, readable_or_closed, KEY_X, .Persistent)
    testing.expect_ok(t, bound, "x binds to a port for Readable and PeerClosed")
    bound_once :: slop_os.port_bind(port, any_x, slop_os.SIGNAL_WRITABLE, KEY_ONCE, .Once)
    testing.expect_ok(t, bound_once, "x binds to a port for Writable, once")
    // Through the rings: x is side 0, so A writes ring 0 and reads ring 1
    once := cast[u64](0)
    testing.expect_eq(t, ring_receive(ring_at, 1, port, &once), FROM_B, "B's message through the rings reaches A, its doorbell waking A")
    _ = ring_send(ring_at, 0, FIRST_FROM_A)
    // B rings Writable twice once it has the message: the Once binding sees it once
    seen := false
    packets : slop_os.Packet[4]
    waited := cast[usize](slop_os.channel_notify_and_wait(x, slop_os.SIGNAL_READABLE, port, packets, slop_os.NO_DEADLINE) or_else 0)
    loop {
        for packet, i in packets {
            if i < waited && packet.key == KEY_ONCE && packet.data[0] == writable {
                seen = true
            }
        }
        if seen {
            break
        }
        waited = cast[usize](slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0)
    }
    testing.expect(t, seen, "a Once binding sees the signal it's bound for")
    // B raises Writable again once it hears A took the packet, then says so: disarmed, the binding queues nothing
    if ring_send(ring_at, 0, TOOK_IT) {
        _ = slop_os.channel_notify(x, slop_os.SIGNAL_READABLE)
    }
    testing.expect_eq(t, ring_receive(ring_at, 1, port, &once), RAISED_AGAIN, "B says it raised Writable again")
    started :: test_kit.clock_now()
    again :: cast[usize](slop_os.port_wait(port, packets, started + SHORT_WAIT_NANOSECONDS) or_else 0)
    for packet, i in packets {
        if i < again && packet.key == KEY_ONCE {
            once += 1
        }
    }
    testing.expect_eq(t, once, 0, "a Once binding, once it has fired, queues nothing more until it's bound again")
    // Armed again, it sees the next one; then B closes y
    rebound :: slop_os.port_bind(port, any_x, slop_os.SIGNAL_WRITABLE, KEY_ONCE, .Once)
    testing.expect_ok(t, rebound, "a fired Once binding binds again")
    if ring_send(ring_at, 0, SECOND_FROM_A) {
        _ = slop_os.channel_notify(x, slop_os.SIGNAL_READABLE)
    }
    // Until both are seen: a Once binding bound again sees Writable, and the persistent one B's close of y
    both := cast[u64](0)
    loop {
        last :: cast[usize](slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0)
        for packet, i in packets {
            if i < last {
                if packet.key == KEY_ONCE && packet.data[0] == writable {
                    both |= 1
                }
                if packet.key == KEY_X && packet.data[0] & peer_closed != 0 {
                    both |= 2
                }
            }
        }
    }
    while both != 3
    written :: slop_os.channel_write(x, os.bytes_of(&value), slop_os.NO_BATCH)
    testing.expect_error(t, written, slop_os.ChannelError.PeerClosed, "writing an end whose peer is closed fails with PeerClosed")
    buffer : u8[64]
    read :: slop_os.channel_read(x, buffer, cast[ptr[mut u32]](0))
    testing.expect_error(t, read, slop_os.ChannelError.PeerClosed, "reading an empty end whose peer is closed fails with PeerClosed")
    closed_x :: slop_os.handle_close(any_x)
    testing.expect_ok(t, closed_x, "x closes")
    // Closing x unmapped its rings, so another channel's go where they were; and again once unmapped
    other_pair :: slop_os.channel_create(budget, 0, 0) or_else slop_os.ChannelPair.{}
    other :: other_pair.a
    in_place :: slop_os.channel_map(other, space, ring_at)
    testing.expect_ok(t, in_place, "closing an end unmaps its rings, so another channel's map where they were")
    unmapped :: slop_os.channel_unmap(other)
    testing.expect_ok(t, unmapped, "an end's rings unmap")
    in_place_again :: slop_os.channel_map(other, space, ring_at)
    testing.expect_ok(t, in_place_again, "unmapped rings leave their place free to map again")
    port_closed :: slop_os.handle_close(cast[slop_os.Handle](port))
    testing.expect_ok(t, port_closed, "the port closes")
    _ = slop_os.handle_close(cast[slop_os.Handle](other_pair.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](other_pair.b))
    // What B found, through c0
    b_results : u64[B_RESULTS]
    c0_port :: testing.require_some(t, os.port_for(block.budget, c0), "a port for c0")?
    none : slop_os.Handle[1]
    testing.require_ok(t, os.receive(c0, c0_port, os.mut_bytes_of(&b_results), none), "B sends what it found through c0")?
    _ = slop_os.handle_close(cast[slop_os.Handle](c0))
    _ = slop_os.handle_close(cast[slop_os.Handle](c0_port))
    testing.expect_eq(t, b_results[B_BOUND_C0], 0, "B binds its end of c0 to a port")
    testing.expect_eq(t, b_results[B_SIZE], 8, "A's message through the kernel reaches B with its 8 bytes")
    testing.expect_eq(t, b_results[B_FLAGS_AND_BATCH], cast[u64](slop_os.MESSAGE_HAS_HANDLES) | (3 << 16), "A's message through the kernel says it has handles, in batch 3")
    testing.expect_eq(t, b_results[B_VALUE], CHANNEL_VALUE, "A's message through the kernel reads back as it was written")
    testing.expect_eq(t, b_results[B_TAKEN], 1, "B takes the batch's one handle, y")
    testing.expect_eq(t, b_results[B_TAKEN_AGAIN], test_kit.tag(slop_os.ChannelError.NoSuchBatch), "a batch is taken once, so taking it again is refused with NoSuchBatch")
    testing.expect_eq(t, b_results[B_MAPPED_Y], 0, "B maps y, the end it was sent")
    testing.expect_eq(t, b_results[B_BOUND_Y], 0, "B binds y to its port")
    testing.expect_eq(t, b_results[B_FIRST], FIRST_FROM_A, "A's first message through the rings reaches B")
    testing.expect_eq(t, b_results[B_SECOND], SECOND_FROM_A, "A's message once its Once binding is armed again reaches B")
    testing.expect_eq(t, b_results[B_CLOSED_Y], 0, "B closes y")
    testing.expect_eq(t, b_results[B_FINISHED], 1, "B got to the end of what it does")
    testing.expect_eq(t, b_results[B_TOOK_IT], TOOK_IT, "A's message saying it took the Once binding's packet reaches B")
    // B ends, and what it and A's objects charged comes back
    _ = test_kit.wait_for_budget(b.budget, 0, 2_000_000_000)
    testing.expect_eq(t, test_kit.used(b.budget), 0, "B's budget is back to nothing once it has ended")
    _ = test_kit.wait_for_budget(budget, 0, 1_000_000_000)
    testing.expect_eq(t, test_kit.used(budget), 0, "A's budget is back to nothing once its objects are closed")
    return .Ok
}

/**
 * Check that an end bound for Readable while it's empty, and never read, is woken by its first message, as one a
 * service binds for a new client, in a place its pass has gone by, must be (decisions/0144).
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channel or the port couldn't be made, bound or written.
 */
an_end_bound_before_it_is_read_is_woken #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    budget :: slop_os.startup_block().budget
    pair :: testing.require_ok(t, slop_os.channel_create(budget, 0, 0), "a channel")?
    port :: testing.require_ok(t, slop_os.port_create(budget), "a port")?
    bound :: slop_os.port_bind(port, cast[slop_os.Handle](pair.b), slop_os.SIGNAL_READABLE, KEY_ONCE, .Persistent)
    testing.require_ok(t, bound, "an empty end binds for Readable")?
    value := CHANNEL_VALUE
    written :: slop_os.channel_write(pair.a, os.bytes_of(&value), slop_os.NO_BATCH)
    testing.require_ok(t, written, "a message is written to the other end")?
    packets : slop_os.Packet[2]
    taken :: slop_os.port_wait(port, packets, test_kit.clock_now() + 50 * SHORT_WAIT_NANOSECONDS) or_else 0
    woken := false
    for packet, i in packets {
        if i < cast[usize](taken) && packet.key == KEY_ONCE && packet.data[0] & cast[u64](cast[u32](slop_os.SIGNAL_READABLE)) != 0 {
            woken = true
        }
    }
    for each in slop_os.Handle.[cast[slop_os.Handle](pair.a), cast[slop_os.Handle](pair.b), cast[slop_os.Handle](port)] {
        _ = slop_os.handle_close(each)
    }
    testing.expect(t, woken, "the first message to an end bound before it was ever read wakes its port within a second")
    return .Ok
}

/**
 * Check a batch holding a copy of an end, whose owning handle is closed while it's in flight and whose memory is let
 * go of after a grace period: taken, it gives NO_HANDLE in the copy's place, rather than the kernel touching the end's
 * core, which is gone.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the channels, the copy, the port or the message couldn't be made, sent, read or
 *     taken.
 */
a_stale_end_in_flight_arrives_as_no_handle #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    budget :: slop_os.startup_block().budget
    carrier :: testing.require_ok(t, slop_os.channel_create(budget, 0, 0), "a channel to carry the copy")?
    doomed :: testing.require_ok(t, slop_os.channel_create(budget, 0, 0), "a channel whose end is copied, then destroyed")?
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_TRANSFER) | cast[u32](slop_os.RIGHT_CHANNEL_MAP))
    copy :: testing.require_ok(t, slop_os.handle_duplicate(cast[slop_os.Handle](doomed.a), rights), "a copy of the doomed end")?
    handles : slop_os.Handle[1]
    handles[0] = copy
    sent :: slop_os.channel_send_handles(carrier.a, handles, 5)
    testing.require_ok(t, sent, "the copy is sent in a batch")?
    // The end destroyed, its copy in flight stale, and a grace period passed, which releases its core
    _ = slop_os.handle_close(cast[slop_os.Handle](doomed.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](doomed.b))
    waiter :: testing.require_ok(t, slop_os.port_create(budget), "a port to wait out the grace period on")?
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, test_kit.clock_now() + 5 * SHORT_WAIT_NANOSECONDS)
    value := CHANNEL_VALUE
    written :: slop_os.channel_write(carrier.a, os.bytes_of(&value), 5)
    testing.require_ok(t, written, "a message naming the batch is written")?
    data : u64[8]
    info :: testing.require_ok(t, slop_os.channel_read(carrier.b, os.mut_bytes_of(&data), cast[ptr[mut u32]](0)), "the message is read")?
    into : slop_os.Handle[1]
    taken :: testing.require_ok(t, slop_os.channel_take_handles(carrier.b, cast[u32](info.flags_and_batch >> 16), into, cast[ptr[mut u32]](0)), "the batch is taken")?
    testing.expect_eq(t, taken, 1, "the batch holds the one copy")
    testing.expect_eq(t, into[0], slop_os.NO_HANDLE, "a copy of an end destroyed while in flight comes out as NO_HANDLE")
    for each in slop_os.Handle.[cast[slop_os.Handle](carrier.a), cast[slop_os.Handle](carrier.b), cast[slop_os.Handle](waiter)] {
        _ = slop_os.handle_close(each)
    }
    return .Ok
}

/**
 * Run as B, with its end of c0: take y, trade messages with A through the rings, close y, and send A what it found.
 *
 * @param c0 B's end of c0, which A's message and y come on, and B's results go back on.
 * @return 0 once its results are sent; 101 if no addresses could be reserved for y's rings, 102 or 103 if a port
 *     couldn't be made, 104 if its results couldn't be sent. What B finds, A checks for it.
 */
run_b :: fn(c0: slop_os.Channel) -> int {
    block :: slop_os.startup_block()
    space :: block.space
    ring_at :: runtime.reserve_addresses(cast[usize](slop_os.channel_memory_size(slop_os.CHANNEL_DEFAULT_RING))) or_return 101
    port :: slop_os.port_create(block.budget) or_return 102
    results : u64[B_RESULTS]
    results[B_BOUND_C0] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](c0), slop_os.SIGNAL_READABLE, KEY_C0, .Persistent))
    // Through the kernel: Empty says it waits, so A's write rings the doorbell
    data : u64[8]
    loop {
        match slop_os.channel_read(c0, os.mut_bytes_of(&data), cast[ptr[mut u32]](0)) {
            case Ok(info) => {
                results[B_SIZE] = cast[u64](info.size)
                results[B_FLAGS_AND_BATCH] = cast[u64](info.flags_and_batch)
                break
            }
            case Error(error) => {
                if error != .Empty {
                    results[B_SIZE] = 0xdead0000 | test_kit.tag(error)
                    break
                }
            }
        }
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
    results[B_VALUE] = data[0]
    batch :: cast[u32](results[B_FLAGS_AND_BATCH] >> 16)
    into : slop_os.Handle[4]
    results[B_TAKEN] = cast[u64](slop_os.channel_take_handles(c0, batch, into, cast[ptr[mut u32]](0)) or_else 0)
    results[B_TAKEN_AGAIN] = test_kit.tag_of(slop_os.channel_take_handles(c0, batch, into, cast[ptr[mut u32]](0)))
    y :: cast[slop_os.Channel](into[0])
    results[B_MAPPED_Y] = test_kit.tag_of(slop_os.channel_map(y, space, ring_at))
    results[B_BOUND_Y] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](y), slop_os.SIGNAL_READABLE, KEY_Y, .Persistent))
    // y is side 1: B writes ring 1 and reads ring 0
    once := cast[u64](0)
    if ring_send(ring_at, 1, FROM_B) {
        _ = slop_os.channel_notify(y, slop_os.SIGNAL_READABLE)
    }
    results[B_FIRST] = ring_receive(ring_at, 0, port, &once)
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    results[B_TOOK_IT] = ring_receive(ring_at, 0, port, &once)
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    if ring_send(ring_at, 1, RAISED_AGAIN) {
        _ = slop_os.channel_notify(y, slop_os.SIGNAL_READABLE)
    }
    results[B_SECOND] = ring_receive(ring_at, 0, port, &once)
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    results[B_CLOSED_Y] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](y)))
    results[B_FINISHED] = 1
    // Back to A, through c0
    reply_port :: os.port_for(block.budget, c0) or_return 103
    none : slop_os.Handle[1]
    if os.send(c0, reply_port, os.bytes_of(&results), view_of(&none[0], 0)) is_some {
        return 104
    }
    return 0
}
