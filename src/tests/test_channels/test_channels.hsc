/*
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

NAME :: "test_channels"
CHANNEL_VALUE : u64 : 0x1122334455667788
FROM_B : u64 : 0xb0b
FIRST_FROM_A : u64 : 0xa0a
SECOND_FROM_A : u64 : 0xa0b
TOOK_IT : u64 : 0xa0c
RAISED_AGAIN : u64 : 0xb0c
KEY_C0 : u64 : 1
KEY_Y : u64 : 2
KEY_X : u64 : 5
KEY_ONCE : u64 : 8
SHORT_WAIT_NANOSECONDS : u64 : 20_000_000
B_RESULTS :: 13

// What B is given: its log, and its end of c0.
BGrants :: struct {
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    peer : slop_os.Channel?,
}

/*
 * Write one 8-byte message into the ring side writes, at memory: whether the reader waits, so the
 * writer rings the doorbell. The test's messages are few, so there's always room.
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

/*
 * The next 8-byte message in the ring side writes, at memory, waiting on port for it if there's none:
 * says it waits, looks once more, then waits. Packets for KEY_ONCE it takes meanwhile are counted at once.
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

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?) -> int {
    match peer {
        case Some(c0) => return run_b(c0)
        case None => {}
    }
    connection :: manager or_return 100
    executable :: program or_return 100
    return run_a(log, connection, executable)
}

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
    log_line.write(log, "%: handles moved, messages went through the kernel and the rings, doorbells and Once bindings woke the right waiters, and closing an end reached the other", NAME)
    return 0
}

// B, with its end of c0: what it finds goes back to A through it.
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
    match os.send(c0, reply_port, os.bytes_of(&results), view_of(&none[0], 0)) {
        case Some(error) => return 104
        case None => {}
    }
    return 0
}
