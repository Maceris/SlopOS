package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import slop_os from "std/os"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import x86_64 from "base/intrinsics"
}

/*
 * test_channels: processes A and B, each in its own address space, start with the ends of one channel
 * between them, which the kernel made, and keep what each call gave in their pages:
 * - A makes a channel, maps one end, x, and sends the other, y, to B in a batch, with a message through
 *   the kernel naming it; sending x, which is mapped, or the first channel's own end, fails. B reads the
 *   message through the kernel and takes y;
 * - both map their ends and trade messages through the rings, with the wake protocol: a reader that
 *   finds nothing says it waits, looks again, and waits on its port; a writer that sees it waiting rings
 *   the doorbell. A answers with ChannelNotifyAndWait;
 * - a Once binding of A's sees B's Writable once: A takes the packet and tells B, which raises it again
 *   and says so; A sees no second packet, until it binds the key again;
 * - B closes y: A sees PeerClosed, and writing or reading x fails with it. Closing x unmaps its rings,
 *   and so does ChannelUnmap, so another channel's can be mapped there.
 * Then the kernel destroys both processes, and every channel, core, port and binding has to be back.
 */

CHANNELS_TEST_TICKS : u64 : 100
CHANNELS_TEST_DESTROY_TICK : u64 : 90
CHANNEL_SLOT_SPACE :: 0
CHANNEL_SLOT_END :: 1
// Where each process maps its end's rings
TEST_RING : u64 : 0xa00000
// In each page, after the results: what's sent and read, and packets
CHANNEL_DATA_OFFSET : u64 : 256
CHANNEL_HANDLES_OFFSET : u64 : 320
CHANNEL_PACKETS_OFFSET : u64 : 384
CHANNEL_TAKEN_OFFSET : u64 : 512
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

ChannelsTest :: struct {
    processes : u64[2],
    pages : u64[2],
}

/*
 * Write one 8-byte message into the ring side writes, at memory: whether the reader waits, so the
 * writer rings the doorbell. The tests' messages are few, so there's always room.
 */
ring_send #no_context :: fn(memory: u64, side: u64, value: u64) -> bool {
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
ring_receive #no_context :: fn(memory: u64, side: u64, port: slop_os.Port, packets: u64, once: ptr[mut u64]) -> u64 {
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
            taken :: cast[u64](slop_os.port_wait(port, packets_at(packets, 4), slop_os.NO_DEADLINE) or_else 0)
            for i in 0..<4 {
                if cast[u64](i) < taken && cast[ptr[u64]](packets + cast[u64](i) * 32)^ == KEY_ONCE {
                    once^ += 1
                }
            }
        }
    }
}

user_channels_a #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    packets :: cast[ptr[u64[16]]](base + CHANNEL_PACKETS_OFFSET)
    taken :: packets_at(base + CHANNEL_PACKETS_OFFSET, 4)
    space :: handle_at[slop_os.AddressSpace](page^[CHANNEL_SLOT_SPACE])
    c0 :: handle_at[slop_os.Channel](page^[CHANNEL_SLOT_END])
    budget :: handle_at[slop_os.MemoryBudget](page^[TEST_SLOT_BUDGET])
    port :: slop_os.port_create(budget) or_else handle_at[slop_os.Port](0)
    made :: slop_os.channel_create(budget, 0)
    pair :: made or_else slop_os.ChannelPair.{}
    x :: pair.a
    y :: pair.b
    page^[8] = tag_of(made)
    page^[9] = tag_of(slop_os.channel_create(budget, 1000))
    page^[10] = tag_of(slop_os.channel_map(x, space, TEST_RING))
    page^[11] = tag_of(slop_os.channel_map(x, space, TEST_RING + 0x10000))
    // Sending: x is mapped, c0 is the channel's own end, and y goes
    handles :: cast[ptr[mut slop_os.Handle[1]]](base + CHANNEL_HANDLES_OFFSET)
    handles^[0] = cast[slop_os.Handle](x)
    page^[12] = tag_of(slop_os.channel_send_handles(c0, handles^, 3))
    handles^[0] = cast[slop_os.Handle](c0)
    page^[13] = tag_of(slop_os.channel_send_handles(c0, handles^, 3))
    handles^[0] = cast[slop_os.Handle](y)
    page^[14] = tag_of(slop_os.channel_send_handles(c0, handles^, 3))
    cast[ptr[mut u64]](base + CHANNEL_DATA_OFFSET)^ = CHANNEL_VALUE
    page^[15] = tag_of(slop_os.channel_write(c0, bytes_at(base + CHANNEL_DATA_OFFSET, 8), 3))
    readable :: cast[u64](cast[u32](slop_os.SIGNAL_READABLE))
    writable :: cast[u64](cast[u32](slop_os.SIGNAL_WRITABLE))
    peer_closed :: cast[u64](cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    any_x :: cast[slop_os.Handle](x)
    page^[16] = tag_of(slop_os.port_bind(port, any_x, cast[slop_os.Signals](cast[u32](readable | peer_closed)), KEY_X, .Persistent))
    page^[17] = tag_of(slop_os.port_bind(port, any_x, slop_os.SIGNAL_WRITABLE, KEY_ONCE, .Once))
    // Through the rings: x is side 0, so A writes ring 0 and reads ring 1
    page^[18] = ring_receive(TEST_RING, 1, port, base + CHANNEL_PACKETS_OFFSET, &page^[20])
    _ = ring_send(TEST_RING, 0, FIRST_FROM_A)
    // B rings Writable twice once it has the message: the Once binding sees it once
    seen := cast[u64](0)
    waited := cast[u64](slop_os.channel_notify_and_wait(x, slop_os.SIGNAL_READABLE, port, taken, slop_os.NO_DEADLINE) or_else 0)
    loop {
        for i in 0..<4 {
            if cast[u64](i) < waited && packets^[i * 4] == KEY_ONCE && packets^[i * 4 + 2] == writable {
                seen = 1
            }
        }
        if seen != 0 {
            break
        }
        waited = cast[u64](slop_os.port_wait(port, taken, slop_os.NO_DEADLINE) or_else 0)
    }
    page^[19] = seen
    // B raises Writable again once it hears A took the packet, then says so: disarmed, the binding queues nothing
    if ring_send(TEST_RING, 0, TOOK_IT) {
        _ = slop_os.channel_notify(x, slop_os.SIGNAL_READABLE)
    }
    page^[28] = ring_receive(TEST_RING, 1, port, base + CHANNEL_PACKETS_OFFSET, &page^[20])
    started :: clock_now()
    again :: cast[u64](slop_os.port_wait(port, taken, started + SHORT_WAIT_NANOSECONDS) or_else 0)
    for i in 0..<4 {
        if cast[u64](i) < again && packets^[i * 4] == KEY_ONCE {
            page^[20] += 1
        }
    }
    // Armed again, it sees the next one; then B closes y
    page^[21] = tag_of(slop_os.port_bind(port, any_x, slop_os.SIGNAL_WRITABLE, KEY_ONCE, .Once))
    if ring_send(TEST_RING, 0, SECOND_FROM_A) {
        _ = slop_os.channel_notify(x, slop_os.SIGNAL_READABLE)
    }
    both := cast[u64](0)
    loop {
        last :: cast[u64](slop_os.port_wait(port, taken, slop_os.NO_DEADLINE) or_else 0)
        for i in 0..<4 {
            if cast[u64](i) < last {
                key :: packets^[i * 4]
                signals :: packets^[i * 4 + 2]
                if key == KEY_ONCE && signals == writable {
                    both |= 1
                }
                if key == KEY_X && signals & peer_closed != 0 {
                    both |= 2
                }
            }
        }
    }
    while both != 3
    page^[22] = both
    page^[23] = tag_of(slop_os.channel_write(x, bytes_at(base + CHANNEL_DATA_OFFSET, 8), slop_os.NO_BATCH))
    page^[24] = tag_of(slop_os.channel_read(x, bytes_at(base + CHANNEL_DATA_OFFSET, 64), cast[ptr[mut u32]](0)))
    page^[25] = tag_of(slop_os.handle_close(any_x))
    // Closing x unmapped its rings, so another channel's go where they were; and again once unmapped
    other_pair :: slop_os.channel_create(budget, 0) or_else slop_os.ChannelPair.{}
    other :: other_pair.a
    page^[29] = tag_of(slop_os.channel_map(other, space, TEST_RING))
    page^[30] = tag_of(slop_os.channel_unmap(other))
    page^[31] = tag_of(slop_os.channel_map(other, space, TEST_RING))
    page^[26] = tag_of(slop_os.handle_close(cast[slop_os.Handle](port)))
    intrinsics.volatile_store_u64(&page^[27], 1)
    slop_os.thread_exit()
}

user_channels_b #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    space :: handle_at[slop_os.AddressSpace](page^[CHANNEL_SLOT_SPACE])
    c0 :: handle_at[slop_os.Channel](page^[CHANNEL_SLOT_END])
    port :: slop_os.port_create(handle_at[slop_os.MemoryBudget](page^[TEST_SLOT_BUDGET])) or_else handle_at[slop_os.Port](0)
    taken :: packets_at(base + CHANNEL_PACKETS_OFFSET, 4)
    page^[8] = tag_of(slop_os.port_bind(port, cast[slop_os.Handle](c0), slop_os.SIGNAL_READABLE, KEY_C0, .Persistent))
    // Through the kernel: Empty says it waits, so A's write rings the doorbell
    loop {
        read :: slop_os.channel_read(c0, bytes_at(base + CHANNEL_DATA_OFFSET, 64), cast[ptr[mut u32]](0))
        match read {
            case Ok(info) => {
                page^[9] = cast[u64](info.size)
                page^[10] = cast[u64](info.flags_and_batch)
                break
            }
            case Error(error) => {
                if error != .Empty {
                    page^[9] = 0xdead0000 | cast[u64](cast[u32](error))
                    break
                }
            }
        }
        _ = slop_os.port_wait(port, taken, slop_os.NO_DEADLINE)
    }
    page^[11] = cast[ptr[u64]](base + CHANNEL_DATA_OFFSET)^
    batch :: cast[u32](page^[10] >> 16)
    into :: cast[ptr[mut slop_os.Handle[4]]](base + CHANNEL_TAKEN_OFFSET)
    page^[12] = cast[u64](slop_os.channel_take_handles(c0, batch, into^, cast[ptr[mut u32]](0)) or_else 0)
    page^[13] = tag_of(slop_os.channel_take_handles(c0, batch, into^, cast[ptr[mut u32]](0)))
    y :: cast[slop_os.Channel](into^[0])
    page^[14] = tag_of(slop_os.channel_map(y, space, TEST_RING))
    page^[15] = tag_of(slop_os.port_bind(port, cast[slop_os.Handle](y), slop_os.SIGNAL_READABLE, KEY_Y, .Persistent))
    // y is side 1: B writes ring 1 and reads ring 0
    if ring_send(TEST_RING, 1, FROM_B) {
        _ = slop_os.channel_notify(y, slop_os.SIGNAL_READABLE)
    }
    page^[16] = ring_receive(TEST_RING, 0, port, base + CHANNEL_PACKETS_OFFSET, &page^[30])
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    page^[20] = ring_receive(TEST_RING, 0, port, base + CHANNEL_PACKETS_OFFSET, &page^[30])
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    if ring_send(TEST_RING, 1, RAISED_AGAIN) {
        _ = slop_os.channel_notify(y, slop_os.SIGNAL_READABLE)
    }
    page^[17] = ring_receive(TEST_RING, 0, port, base + CHANNEL_PACKETS_OFFSET, &page^[30])
    _ = slop_os.channel_notify(y, slop_os.SIGNAL_WRITABLE)
    page^[18] = tag_of(slop_os.handle_close(cast[slop_os.Handle](y)))
    intrinsics.volatile_store_u64(&page^[19], 1)
    slop_os.thread_exit()
}

test_channels :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[ChannelsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_channels: no memory")
    entries :: u64.[cast[u64](user_channels_a), cast[u64](user_channels_b)]
    // The kernel's code, with the functions and the stubs they call
    code :: kernel.code_base
    code_end :: kernel.code_base + kernel.code_size
    for i in 0..<2 {
        process := cast[ptr[mut Process]](0)
        match create_process(kernel, 0, 0) {
            case Ok(made) => process = made
            case Error(error) => {
                runtime.log_error("test_channels: no process: %", error)
                return void
            }
        }
        test.processes[i] = cast[u64](process)
        space := cast[ptr[mut AddressSpace]](0)
        match create_address_space(kernel, cast[u64](process), 0) {
            case Ok(made) => space = made
            case Error(error) => {
                runtime.log_error("test_channels: no address space: %", error)
                return void
            }
        }
        page :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_channels: no memory")
        stack :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_channels: no memory")
        if !mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (code - kernel.image_base), code_end - code, USER_CODE)
            || !mapped_for_test(kernel, space, TEST_COUNTERS, cast[u64](page), frames.FRAME_SIZE, USER_DATA)
            || !mapped_for_test(kernel, space, TEST_STACKS, cast[u64](stack), frames.FRAME_SIZE, USER_DATA) {
            return void
        }
        test.pages[i] = frames.virtual_of(&kernel.frames, page)
        match install(kernel, &process.table, cast[u64](space), space.header.generation, .AddressSpace, slop_os.RIGHTS_ALL, false) {
            case Ok(handle) => cast[ptr[mut u64[64]]](test.pages[i])^[CHANNEL_SLOT_SPACE] = cast[u64](cast[u32](handle))
            case Error(error) => {
                runtime.log_error("test_channels: no handle: %", error)
                return void
            }
        }
        if !give_test_budget(kernel, process, test.pages[i]) {
            return void
        }
    }
    // The channel between them: each end owned by its process
    pair := ChannelPair.{}
    match create_channel(kernel, test.processes[0], 0, 0) {
        case Ok(made) => pair = made
        case Error(error) => {
            runtime.log_error("test_channels: no channel: %", error)
            return void
        }
    }
    disown(cast[u64](pair.b))
    if !adopted(test.processes[1], cast[u64](pair.b)) {
        return void
    }
    ends :: u64.[cast[u64](pair.a), cast[u64](pair.b)]
    for i in 0..<2 {
        process :: cast[ptr[mut Process]](test.processes[i])
        match install_owning(kernel, process, ends[i]) {
            case Ok(handle) => cast[ptr[mut u64[64]]](test.pages[i])^[CHANNEL_SLOT_END] = cast[u64](cast[u32](handle))
            case Error(error) => {
                runtime.log_error("test_channels: no handle: %", error)
                return void
            }
        }
        space :: cast[ptr[mut AddressSpace]](take_space_of(process))
        start :: arch_interface.UserStart.{
            instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (entries[i] - code)),
            stack_pointer = cast[arch_interface.VirtualAddress](TEST_STACKS + frames.FRAME_SIZE - 8),
            argument = TEST_COUNTERS,
        }
        match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0, 0) {
            case Ok(thread) => start_thread(kernel, thread)
            case Error(error) => {
                runtime.log_error("test_channels: no thread: %", error)
                return void
            }
        }
    }
    kernel.stop_after_ticks = CHANNELS_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.channels_test, cast[u64](test))
}

// The address space a test process owns, the one it made first.
take_space_of :: fn(process: ptr[mut Process]) -> u64 {
    with {
        object := process.owned.first
    }
    loop {
        if cast[ptr[ObjectHeader]](object).kind == .AddressSpace {
            return object
        }
        object = cast[ptr[ObjectHeader]](object).owned_next
    }
    while object != 0
    return 0
}

channels_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.channels_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut ChannelsTest]](address)
    if tick == CHANNELS_TEST_DESTROY_TICK {
        check_channel_results(test)
        for process in test.processes {
            _ = destroy_object(kernel, process)
        }
        return void
    }
    if tick != CHANNELS_TEST_TICKS {
        return void
    }
    pools :: &kernel.pools
    if pool_of(kernel, .Channel).allocated != 0 || pools.channel_cores.allocated != 0 || pool_of(kernel, .Port).allocated != 0
        || pools.bindings.allocated != 0 || pool_of(kernel, .Thread).allocated != 0 {
        runtime.log_error("test_channels: left after the processes were destroyed: % ends, % cores, % ports, % bindings, % threads",
            pool_of(kernel, .Channel).allocated, pools.channel_cores.allocated, pool_of(kernel, .Port).allocated, pools.bindings.allocated, pool_of(kernel, .Thread).allocated)
        return void
    }
    runtime.log_info("test_channels: destroying the processes freed their channels, ports and bindings")
}

// A ChannelError's tag, as a call gives it.
channel_tag :: fn(error: slop_os.ChannelError) -> u64 {
    return cast[u64](cast[u32](error))
}

check_channel_results :: fn(test: ptr[ChannelsTest]) {
    expected_a :: u64.[
        0, channel_tag(.InvalidSize), 0, channel_tag(.Mapped),
        channel_tag(.Mapped), channel_tag(.NotTransferable), 0, 0,
        0, 0,
        FROM_B, 1, 0, 0,
        3, channel_tag(.PeerClosed), channel_tag(.PeerClosed), 0, 0, 1,
        RAISED_AGAIN, 0, 0, 0,
    ]
    expected_b :: u64.[
        0, 8, cast[u64](slop_os.MESSAGE_HAS_HANDLES) | (3 << 16), CHANNEL_VALUE,
        1, channel_tag(.NoSuchBatch), 0, 0,
        FIRST_FROM_A, SECOND_FROM_A, 0, 1,
        TOOK_IT,
    ]
    a :: cast[ptr[u64[64]]](test.pages[0])
    b :: cast[ptr[u64[64]]](test.pages[1])
    for value, i in expected_a {
        if a^[8 + i] != value {
            runtime.log_error("test_channels: A's result % is %, not %", i, cast[rawptr](a^[8 + i]), cast[rawptr](value))
            return void
        }
    }
    for value, i in expected_b {
        if b^[8 + i] != value {
            runtime.log_error("test_channels: B's result % is %, not %", i, cast[rawptr](b^[8 + i]), cast[rawptr](value))
            return void
        }
    }
    runtime.log_info("test_channels: handles moved, messages went through the kernel and the rings, doorbells and Once bindings woke the right waiters, and closing an end reached the other")
}
