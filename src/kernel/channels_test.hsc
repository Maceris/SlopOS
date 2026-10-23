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
ring_receive #no_context :: fn(memory: u64, side: u64, port: u64, packets: u64, once: ptr[mut u64]) -> u64 {
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
            taken :: call(.PortWait, port, packets, 4, slop_os.NO_DEADLINE).rdx
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
    space :: page^[CHANNEL_SLOT_SPACE]
    c0 :: page^[CHANNEL_SLOT_END]
    port :: call(.PortCreate).rdx
    made :: call(.ChannelCreate, 0)
    x :: made.rdx
    y :: made.r8
    page^[8] = made.rax
    page^[9] = call(.ChannelCreate, 1000).rax
    page^[10] = call(.ChannelMap, x, space, TEST_RING).rax
    page^[11] = call(.ChannelMap, x, space, TEST_RING + 0x10000).rax
    // Sending: x is mapped, c0 is the channel's own end, and y goes
    handles :: cast[ptr[mut u64]](base + CHANNEL_HANDLES_OFFSET)
    handles^ = x
    page^[12] = call(.ChannelSendHandles, c0, base + CHANNEL_HANDLES_OFFSET, 1, 3).rax
    handles^ = c0
    page^[13] = call(.ChannelSendHandles, c0, base + CHANNEL_HANDLES_OFFSET, 1, 3).rax
    handles^ = y
    page^[14] = call(.ChannelSendHandles, c0, base + CHANNEL_HANDLES_OFFSET, 1, 3).rax
    cast[ptr[mut u64]](base + CHANNEL_DATA_OFFSET)^ = CHANNEL_VALUE
    page^[15] = call(.ChannelWrite, c0, base + CHANNEL_DATA_OFFSET, 8, 3).rax
    readable :: cast[u64](cast[u32](slop_os.SIGNAL_READABLE))
    writable :: cast[u64](cast[u32](slop_os.SIGNAL_WRITABLE))
    peer_closed :: cast[u64](cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    once :: cast[u64](cast[u32](slop_os.BindMode.Once))
    page^[16] = call(.PortBind, port, x, readable | peer_closed, KEY_X, cast[u64](cast[u32](slop_os.BindMode.Persistent))).rax
    page^[17] = call(.PortBind, port, x, writable, KEY_ONCE, once).rax
    // Through the rings: x is side 0, so A writes ring 0 and reads ring 1
    page^[18] = ring_receive(TEST_RING, 1, port, base + CHANNEL_PACKETS_OFFSET, &page^[20])
    _ = ring_send(TEST_RING, 0, FIRST_FROM_A)
    // B rings Writable twice once it has the message: the Once binding sees it once
    seen := cast[u64](0)
    waited := call(.ChannelNotifyAndWait, x, readable, port, base + CHANNEL_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    loop {
        for i in 0..<4 {
            if cast[u64](i) < waited.rdx && packets^[i * 4] == KEY_ONCE && packets^[i * 4 + 2] == writable {
                seen = 1
            }
        }
        if seen != 0 {
            break
        }
        waited = call(.PortWait, port, base + CHANNEL_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    }
    page^[19] = seen
    // B raises Writable again once it hears A took the packet, then says so: disarmed, the binding queues nothing
    if ring_send(TEST_RING, 0, TOOK_IT) {
        _ = call(.ChannelNotify, x, readable)
    }
    page^[28] = ring_receive(TEST_RING, 1, port, base + CHANNEL_PACKETS_OFFSET, &page^[20])
    started :: call(.ClockMonotonic).rdx
    again :: call(.PortWait, port, base + CHANNEL_PACKETS_OFFSET, 4, started + SHORT_WAIT_NANOSECONDS)
    for i in 0..<4 {
        if cast[u64](i) < again.rdx && packets^[i * 4] == KEY_ONCE {
            page^[20] += 1
        }
    }
    // Armed again, it sees the next one; then B closes y
    page^[21] = call(.PortBind, port, x, writable, KEY_ONCE, once).rax
    if ring_send(TEST_RING, 0, SECOND_FROM_A) {
        _ = call(.ChannelNotify, x, readable)
    }
    both := cast[u64](0)
    loop {
        last :: call(.PortWait, port, base + CHANNEL_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
        for i in 0..<4 {
            if cast[u64](i) < last.rdx {
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
    page^[23] = call(.ChannelWrite, x, base + CHANNEL_DATA_OFFSET, 8, slop_os.NO_BATCH).rax
    page^[24] = call(.ChannelRead, x, base + CHANNEL_DATA_OFFSET, 64).rax
    page^[25] = call(.HandleClose, x).rax
    // Closing x unmapped its rings, so another channel's go where they were; and again once unmapped
    other :: call(.ChannelCreate, 0).rdx
    page^[29] = call(.ChannelMap, other, space, TEST_RING).rax
    page^[30] = call(.ChannelUnmap, other).rax
    page^[31] = call(.ChannelMap, other, space, TEST_RING).rax
    page^[26] = call(.HandleClose, port).rax
    intrinsics.volatile_store_u64(&page^[27], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

user_channels_b #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    space :: page^[CHANNEL_SLOT_SPACE]
    c0 :: page^[CHANNEL_SLOT_END]
    port :: call(.PortCreate).rdx
    readable :: cast[u64](cast[u32](slop_os.SIGNAL_READABLE))
    writable :: cast[u64](cast[u32](slop_os.SIGNAL_WRITABLE))
    persistent :: cast[u64](cast[u32](slop_os.BindMode.Persistent))
    page^[8] = call(.PortBind, port, c0, readable, KEY_C0, persistent).rax
    // Through the kernel: Empty says it waits, so A's write rings the doorbell
    loop {
        read :: call(.ChannelRead, c0, base + CHANNEL_DATA_OFFSET, 64)
        if read.rax == 0 {
            page^[9] = read.rdx
            page^[10] = read.r8
            break
        }
        if read.rax != cast[u64](cast[u32](slop_os.ChannelError.Empty)) {
            page^[9] = 0xdead0000 | read.rax
            break
        }
        _ = call(.PortWait, port, base + CHANNEL_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    }
    page^[11] = cast[ptr[u64]](base + CHANNEL_DATA_OFFSET)^
    batch :: page^[10] >> 16
    taken :: call(.ChannelTakeHandles, c0, batch, base + CHANNEL_TAKEN_OFFSET, 4)
    page^[12] = taken.rdx
    page^[13] = call(.ChannelTakeHandles, c0, batch, base + CHANNEL_TAKEN_OFFSET, 4).rax
    y :: cast[u64](cast[ptr[u32]](base + CHANNEL_TAKEN_OFFSET)^)
    page^[14] = call(.ChannelMap, y, space, TEST_RING).rax
    page^[15] = call(.PortBind, port, y, readable, KEY_Y, persistent).rax
    // y is side 1: B writes ring 1 and reads ring 0
    if ring_send(TEST_RING, 1, FROM_B) {
        _ = call(.ChannelNotify, y, readable)
    }
    page^[16] = ring_receive(TEST_RING, 0, port, base + CHANNEL_PACKETS_OFFSET, &page^[30])
    _ = call(.ChannelNotify, y, writable)
    page^[20] = ring_receive(TEST_RING, 0, port, base + CHANNEL_PACKETS_OFFSET, &page^[30])
    _ = call(.ChannelNotify, y, writable)
    if ring_send(TEST_RING, 1, RAISED_AGAIN) {
        _ = call(.ChannelNotify, y, readable)
    }
    page^[17] = ring_receive(TEST_RING, 0, port, base + CHANNEL_PACKETS_OFFSET, &page^[30])
    _ = call(.ChannelNotify, y, writable)
    page^[18] = call(.HandleClose, y).rax
    intrinsics.volatile_store_u64(&page^[19], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

test_channels :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[ChannelsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_channels: no memory")
    entries :: u64.[cast[u64](user_channels_a), cast[u64](user_channels_b)]
    functions :: u64.[cast[u64](user_channels_a), cast[u64](user_channels_b), cast[u64](ring_send), cast[u64](ring_receive), cast[u64](call)]
    first := functions[0]
    last := functions[0]
    for function in functions {
        first = min_u64(first, function)
        last = max_u64(last, function)
    }
    code :: first & ~(frames.FRAME_SIZE - 1)
    code_end :: frames.round_up(last + 4 * frames.FRAME_SIZE, frames.FRAME_SIZE)
    for i in 0..<2 {
        process := cast[ptr[mut Process]](0)
        match create_process(kernel, 0) {
            case Ok(made) => process = made
            case Error(error) => {
                runtime.log_error("test_channels: no process: %", error)
                return void
            }
        }
        test.processes[i] = cast[u64](process)
        space := cast[ptr[mut AddressSpace]](0)
        match create_address_space(kernel, cast[u64](process)) {
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
    }
    // The channel between them: each end owned by its process
    pair := ChannelPair.{}
    match create_channel(kernel, test.processes[0], 0) {
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
        match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0) {
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
    if pools.channels.allocated != 0 || pools.channel_cores.allocated != 0 || pools.ports.allocated != 0
        || pools.bindings.allocated != 0 || pools.threads.allocated != 0 {
        runtime.log_error("test_channels: left after the processes were destroyed: % ends, % cores, % ports, % bindings, % threads",
            pools.channels.allocated, pools.channel_cores.allocated, pools.ports.allocated, pools.bindings.allocated, pools.threads.allocated)
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
