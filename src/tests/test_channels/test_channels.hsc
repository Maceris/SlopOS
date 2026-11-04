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

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
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
/** How many results B keeps, and sends A. */
B_RESULTS :: 13

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

/**
 * Check channels between two processes: handles in batches, messages through the kernel and the rings, the wake
 * protocol, Once bindings, closing an end, and what's charged coming back; or, run as B, be the other end.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager The process manager, which launches B; without it the test ends with 100.
 * @param program The test's own module, which B is launched from; without it the test ends with 100.
 * @param peer Given only to B, by A: its end of c0. With it, this runs as B.
 * @param cpu_budget Not used.
 * @return What run_a gives for A, or run_b for B.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(c0) => return run_b(c0)
        case None => {}
    }
    connection :: manager or_return 100
    executable :: program or_return 100
    return run_a(log, connection, executable)
}

/**
 * Run as A: launch B, check what A sees, then what B found, then the stale end and bound-before-read checks.
 *
 * @param log The debug log, writable, duplicated for B.
 * @param manager The process manager connection B is launched through.
 * @param program The test's own module, which B runs.
 * @return 0 if every check passed. Otherwise the first that failed, A's checks first, by their result's index plus
 *     one: 1 making x and y; 2 a ring of 1000 bytes not refused with InvalidSize; 3 mapping x, or 4 mapping it again
 *     not refused with Mapped; 5 sending x while it's mapped not refused with Mapped, or 6 sending c0's own end not
 *     refused with NotTransferable; 7 sending y, or 8 the message naming its batch; 9 binding x for Readable and
 *     PeerClosed, or 10 for Writable, Once; 11 B's first message through the rings; 12 the Once binding not seeing
 *     Writable, or 13 seeing it a second time; 14 binding it again; 15 not seeing both Writable and PeerClosed once
 *     B closed y; 16 writing, or 17 reading, x not failing with PeerClosed; 18 closing x; 19 closing the port; 21 B's
 *     RAISED_AGAIN; 22 mapping another channel where x's rings were, 23 unmapping it, or 24 mapping it again. Then
 *     B's, 51 plus their index: 51 binding c0; 52 to 54 the message through the kernel, its size, flags and batch, or
 *     value; 55 taking its one handle, or 56 taking the batch twice not refused with NoSuchBatch; 57 mapping y, or 58
 *     binding it; 59, 60 and 63 A's messages through the rings; 61 closing y. 90 if B's budget, or A's objects',
 *     didn't come back to nothing; 120 to 128 from check_stale_end, 130 to 134 from check_bound_before_read. 101 to
 *     107 if setting up failed: 101 the memory budget or ring addresses, 102 the port, 103 c0, 104 the manager's
 *     port or the log's copy, 105 launching B, 106 c0's port, 107 receiving B's results.
 */
run_a :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager], program: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    space :: block.space
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    ring_at :: runtime.reserve_addresses(cast[usize](slop_os.channel_memory_size(slop_os.CHANNEL_DEFAULT_RING))) or_return 101
    port :: slop_os.port_create(budget) or_return 102
    // c0, and B, a copy of this program given its other end
    first :: slop_os.channel_create(budget, 0, 0) or_return 103
    c0 :: first.a
    manager_port :: os.port_for(block.budget, manager.end) or_return 104
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), log_rights) or_return 104)
    b :: os.launch(manager, manager_port, "test_channels B", program, 4 << 20, main, BGrants.{log = log_copy, peer = first.b})
        or_return 105
    results : u64[24]
    made :: slop_os.channel_create(budget, 0, 0)
    pair :: made or_else slop_os.ChannelPair.{}
    x :: pair.a
    y :: pair.b
    results[0] = test_kit.tag_of(made)
    results[1] = test_kit.tag_of(slop_os.channel_create(budget, 1000, 0))
    results[2] = test_kit.tag_of(slop_os.channel_map(x, space, ring_at))
    results[3] = test_kit.tag_of(slop_os.channel_map(x, space, ring_at + 0x10000))
    // Sending: x is mapped, c0 is the channel's own end, and y goes
    handles : slop_os.Handle[1]
    handles[0] = cast[slop_os.Handle](x)
    results[4] = test_kit.tag_of(slop_os.channel_send_handles(c0, handles, 3))
    handles[0] = cast[slop_os.Handle](c0)
    results[5] = test_kit.tag_of(slop_os.channel_send_handles(c0, handles, 3))
    handles[0] = cast[slop_os.Handle](y)
    results[6] = test_kit.tag_of(slop_os.channel_send_handles(c0, handles, 3))
    value := CHANNEL_VALUE
    results[7] = test_kit.tag_of(slop_os.channel_write(c0, os.bytes_of(&value), 3))
    writable :: cast[u64](cast[u32](slop_os.SIGNAL_WRITABLE))
    peer_closed :: cast[u64](cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    any_x :: cast[slop_os.Handle](x)
    readable_or_closed :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    results[8] = test_kit.tag_of(slop_os.port_bind(port, any_x, readable_or_closed, KEY_X, .Persistent))
    results[9] = test_kit.tag_of(slop_os.port_bind(port, any_x, slop_os.SIGNAL_WRITABLE, KEY_ONCE, .Once))
    // Through the rings: x is side 0, so A writes ring 0 and reads ring 1
    once := cast[u64](0)
    results[10] = ring_receive(ring_at, 1, port, &once)
    _ = ring_send(ring_at, 0, FIRST_FROM_A)
    // B rings Writable twice once it has the message: the Once binding sees it once
    seen := cast[u64](0)
    packets : slop_os.Packet[4]
    waited := cast[usize](slop_os.channel_notify_and_wait(x, slop_os.SIGNAL_READABLE, port, packets, slop_os.NO_DEADLINE) or_else 0)
    loop {
        for packet, i in packets {
            if i < waited && packet.key == KEY_ONCE && packet.data[0] == writable {
                seen = 1
            }
        }
        if seen != 0 {
            break
        }
        waited = cast[usize](slop_os.port_wait(port, packets, slop_os.NO_DEADLINE) or_else 0)
    }
    results[11] = seen
    // B raises Writable again once it hears A took the packet, then says so: disarmed, the binding queues nothing
    if ring_send(ring_at, 0, TOOK_IT) {
        _ = slop_os.channel_notify(x, slop_os.SIGNAL_READABLE)
    }
    results[20] = ring_receive(ring_at, 1, port, &once)
    started :: test_kit.clock_now()
    again :: cast[usize](slop_os.port_wait(port, packets, started + SHORT_WAIT_NANOSECONDS) or_else 0)
    for packet, i in packets {
        if i < again && packet.key == KEY_ONCE {
            once += 1
        }
    }
    results[12] = once
    // Armed again, it sees the next one; then B closes y
    results[13] = test_kit.tag_of(slop_os.port_bind(port, any_x, slop_os.SIGNAL_WRITABLE, KEY_ONCE, .Once))
    if ring_send(ring_at, 0, SECOND_FROM_A) {
        _ = slop_os.channel_notify(x, slop_os.SIGNAL_READABLE)
    }
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
    results[14] = both
    results[15] = test_kit.tag_of(slop_os.channel_write(x, os.bytes_of(&value), slop_os.NO_BATCH))
    buffer : u8[64]
    results[16] = test_kit.tag_of(slop_os.channel_read(x, buffer, cast[ptr[mut u32]](0)))
    results[17] = test_kit.tag_of(slop_os.handle_close(any_x))
    // Closing x unmapped its rings, so another channel's go where they were; and again once unmapped
    other_pair :: slop_os.channel_create(budget, 0, 0) or_else slop_os.ChannelPair.{}
    other :: other_pair.a
    results[21] = test_kit.tag_of(slop_os.channel_map(other, space, ring_at))
    results[22] = test_kit.tag_of(slop_os.channel_unmap(other))
    results[23] = test_kit.tag_of(slop_os.channel_map(other, space, ring_at))
    results[18] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](port)))
    results[19] = 1
    _ = slop_os.handle_close(cast[slop_os.Handle](other_pair.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](other_pair.b))
    // What B found, through c0
    b_results : u64[B_RESULTS]
    c0_port :: os.port_for(block.budget, c0) or_return 106
    none : slop_os.Handle[1]
    received :: os.receive(c0, c0_port, os.mut_bytes_of(&b_results), none) or_return 107
    _ = slop_os.handle_close(cast[slop_os.Handle](c0))
    _ = slop_os.handle_close(cast[slop_os.Handle](c0_port))
    expected_a :: u64.[
        0, test_kit.tag(slop_os.ChannelError.InvalidSize), 0, test_kit.tag(slop_os.ChannelError.Mapped),
        test_kit.tag(slop_os.ChannelError.Mapped), test_kit.tag(slop_os.ChannelError.NotTransferable), 0, 0,
        0, 0,
        FROM_B, 1, 0, 0,
        3, test_kit.tag(slop_os.ChannelError.PeerClosed), test_kit.tag(slop_os.ChannelError.PeerClosed), 0, 0, 1,
        RAISED_AGAIN, 0, 0, 0,
    ]
    expected_b :: u64.[
        0, 8, cast[u64](slop_os.MESSAGE_HAS_HANDLES) | (3 << 16), CHANNEL_VALUE,
        1, test_kit.tag(slop_os.ChannelError.NoSuchBatch), 0, 0,
        FIRST_FROM_A, SECOND_FROM_A, 0, 1,
        TOOK_IT,
    ]
    failed := test_kit.check(log, "test_channels A", results, expected_a)
    if failed == 0 {
        failed = test_kit.check(log, "test_channels B", b_results, expected_b)
        if failed != 0 {
            failed += 50
        }
    }
    if failed != 0 {
        return failed
    }
    // B ends, and what it and A's objects charged comes back
    if !test_kit.wait_for_budget(b.budget, 0, 2_000_000_000) || !test_kit.wait_for_budget(budget, 0, 1_000_000_000) {
        log_line.write(log, "%: budgets still charged: B's %, A's %", NAME, test_kit.used(b.budget), test_kit.used(budget))
        return 90
    }
    stale :: check_stale_end(log)
    if stale != 0 {
        return stale
    }
    bound :: check_bound_before_read(log)
    if bound != 0 {
        return bound
    }
    log_line.write(log, "%: handles moved, messages went through the kernel and the rings, doorbells and Once bindings woke the right waiters, and closing an end reached the other", NAME)
    return 0
}

/**
 * Check that an end bound for Readable while it's empty, and never read, is woken by its first message, as one a
 * service binds for a new client, in a place its pass has gone by, must be (decisions/0144).
 *
 * @param log The debug log, where a failure is said.
 * @return 0 if the port woke within a second; 134 if it didn't; 130 to 133 if setting up failed: 130 the channel, 131
 *     the port, 132 binding it, 133 writing the message.
 */
check_bound_before_read :: fn(log: slop_os.DebugLog) -> int {
    budget :: slop_os.startup_block().budget
    pair :: slop_os.channel_create(budget, 0, 0) or_return 130
    port :: slop_os.port_create(budget) or_return 131
    slop_os.port_bind(port, cast[slop_os.Handle](pair.b), slop_os.SIGNAL_READABLE, KEY_ONCE, .Persistent) or_return 132
    value := CHANNEL_VALUE
    slop_os.channel_write(pair.a, os.bytes_of(&value), slop_os.NO_BATCH) or_return 133
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
    if !woken {
        log_line.write(log, "%: the first message to an end bound before it was read woke nothing", NAME)
        return 134
    }
    return 0
}

/**
 * Check a batch holding a copy of an end, whose owning handle is closed while it's in flight and whose memory is let
 * go of after a grace period: taken, it gives NO_HANDLE in the copy's place, rather than the kernel touching the end's
 * core, which is gone.
 *
 * @param log The debug log, where a failure is said.
 * @return 0 if the copy came out as NO_HANDLE; 128 if it didn't; 120 to 127 if setting up failed: 120 and 121 the
 *     channels, 122 the copy, 123 sending it, 124 the port, 125 the message, 126 reading it, 127 taking the batch.
 */
check_stale_end :: fn(log: slop_os.DebugLog) -> int {
    budget :: slop_os.startup_block().budget
    carrier :: slop_os.channel_create(budget, 0, 0) or_return 120
    doomed :: slop_os.channel_create(budget, 0, 0) or_return 121
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_TRANSFER) | cast[u32](slop_os.RIGHT_CHANNEL_MAP))
    copy :: slop_os.handle_duplicate(cast[slop_os.Handle](doomed.a), rights) or_return 122
    handles : slop_os.Handle[1]
    handles[0] = copy
    slop_os.channel_send_handles(carrier.a, handles, 5) or_return 123
    // The end destroyed, its copy in flight stale, and a grace period passed, which releases its core
    _ = slop_os.handle_close(cast[slop_os.Handle](doomed.a))
    _ = slop_os.handle_close(cast[slop_os.Handle](doomed.b))
    waiter :: slop_os.port_create(budget) or_return 124
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(waiter, packets, test_kit.clock_now() + 5 * SHORT_WAIT_NANOSECONDS)
    value := CHANNEL_VALUE
    slop_os.channel_write(carrier.a, os.bytes_of(&value), 5) or_return 125
    data : u64[8]
    info :: slop_os.channel_read(carrier.b, os.mut_bytes_of(&data), cast[ptr[mut u32]](0)) or_return 126
    into : slop_os.Handle[1]
    taken :: slop_os.channel_take_handles(carrier.b, cast[u32](info.flags_and_batch >> 16), into, cast[ptr[mut u32]](0)) or_return 127
    if taken != 1 || into[0] != slop_os.NO_HANDLE {
        log_line.write(log, "%: a stale end's copy came out as %, of %", NAME, cast[u32](into[0]), taken)
        return 128
    }
    for each in slop_os.Handle.[cast[slop_os.Handle](carrier.a), cast[slop_os.Handle](carrier.b), cast[slop_os.Handle](waiter)] {
        _ = slop_os.handle_close(each)
    }
    return 0
}

/**
 * Run as B, with its end of c0: take y, trade messages with A through the rings, close y, and send A what it found.
 *
 * @param c0 B's end of c0, which A's message and y come on, and B's results go back on.
 * @return 0 once its results are sent; 101 if no addresses could be reserved for y's rings, 102 or 103 if a port
 *     couldn't be made, 104 if its results couldn't be sent. What B checks, A checks for it, so B's code isn't.
 */
run_b :: fn(c0: slop_os.Channel) -> int {
    block :: slop_os.startup_block()
    space :: block.space
    ring_at :: runtime.reserve_addresses(cast[usize](slop_os.channel_memory_size(slop_os.CHANNEL_DEFAULT_RING))) or_return 101
    port :: slop_os.port_create(block.budget) or_return 102
    results : u64[B_RESULTS]
    results[0] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](c0), slop_os.SIGNAL_READABLE, KEY_C0, .Persistent))
    // Through the kernel: Empty says it waits, so A's write rings the doorbell
    data : u64[8]
    loop {
        match slop_os.channel_read(c0, os.mut_bytes_of(&data), cast[ptr[mut u32]](0)) {
            case Ok(info) => {
                results[1] = cast[u64](info.size)
                results[2] = cast[u64](info.flags_and_batch)
                break
            }
            case Error(error) => {
                if error != .Empty {
                    results[1] = 0xdead0000 | test_kit.tag(error)
                    break
                }
            }
        }
        packets : slop_os.Packet[4]
        _ = slop_os.port_wait(port, packets, slop_os.NO_DEADLINE)
    }
    results[3] = data[0]
    batch :: cast[u32](results[2] >> 16)
    into : slop_os.Handle[4]
    results[4] = cast[u64](slop_os.channel_take_handles(c0, batch, into, cast[ptr[mut u32]](0)) or_else 0)
    results[5] = test_kit.tag_of(slop_os.channel_take_handles(c0, batch, into, cast[ptr[mut u32]](0)))
    y :: cast[slop_os.Channel](into[0])
    results[6] = test_kit.tag_of(slop_os.channel_map(y, space, ring_at))
    results[7] = test_kit.tag_of(slop_os.port_bind(port, cast[slop_os.Handle](y), slop_os.SIGNAL_READABLE, KEY_Y, .Persistent))
    // y is side 1: B writes ring 1 and reads ring 0
    once := cast[u64](0)
    if ring_send(ring_at, 1, FROM_B) {
        _ = slop_os.channel_notify(y, slop_os.SIGNAL_READABLE)
    }
    results[8] = ring_receive(ring_at, 0, port, &once)
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    results[12] = ring_receive(ring_at, 0, port, &once)
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    if ring_send(ring_at, 1, RAISED_AGAIN) {
        _ = slop_os.channel_notify(y, slop_os.SIGNAL_READABLE)
    }
    results[9] = ring_receive(ring_at, 0, port, &once)
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    results[10] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](y)))
    results[11] = 1
    // Back to A, through c0
    reply_port :: os.port_for(block.budget, c0) or_return 103
    none : slop_os.Handle[1]
    if os.send(c0, reply_port, os.bytes_of(&results), view_of(&none[0], 0)) is_some {
        return 104
    }
    return 0
}
