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
 * test_ports: two threads in user mode, A and B, use a port, keeping what each call gave in their page:
 * - A binds a wake key, twice (KeyInUse the second time), wakes a key with no binding (NoSuchKey), wakes
 *   its key twice and takes one packet with both bits;
 * - a timer 20 ms off blocks A until it fires; a wait with nothing to take and a 15 ms deadline gives
 *   nothing, no sooner; packets for memory A can't write are refused (BadBuffer);
 * - B, started by A, wakes it through the port, likely from another CPU, and waits for A to have the
 *   packet, since any waiter on the port may take it; A unbinds the key, after which waking it fails;
 * - B waits on the port, and A closes it: B wakes with ObjectGone.
 * Then the kernel destroys the process, and every port and binding has to be back in its pool.
 */

PORTS_TEST_TICKS : u64 : 80
PORTS_TEST_DESTROY_TICK : u64 : 70
PORT_SLOT_PORT :: 1
PORT_SLOT_B_WAITING :: 2
PORT_SLOT_ENTRY :: 3
PORT_SLOT_STACK :: 4
// A has B's packet, so B can wait without taking it itself, which any waiter on the port may
PORT_SLOT_A_WOKEN :: 5
// A's packets, then B's, after the results
PORT_PACKETS_OFFSET : u64 : 256
PORT_B_PACKETS_OFFSET : u64 : 384
PORT_KEY : u64 : 7
TIMER_KEY : u64 : 9
TIMER_NANOSECONDS : u64 : 20_000_000
DEADLINE_NANOSECONDS : u64 : 15_000_000

PortsTest :: struct {
    process : u64,
    page : u64,
}


user_ports #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    packets :: cast[ptr[u64[16]]](base + PORT_PACKETS_OFFSET)
    taken :: packets_at(base + PORT_PACKETS_OFFSET, 4)
    budget :: handle_at[slop_os.MemoryBudget](page^[TEST_SLOT_BUDGET])
    port :: slop_os.port_create(budget) or_else handle_at[slop_os.Port](0)
    page^[PORT_SLOT_PORT] = slot_of(port)
    page^[8] = tag_of(slop_os.port_bind_wake(port, PORT_KEY))
    page^[9] = tag_of(slop_os.port_bind_wake(port, PORT_KEY))
    page^[10] = tag_of(slop_os.port_wake(port, 99, 1))
    _ = slop_os.port_wake(port, PORT_KEY, 1)
    _ = slop_os.port_wake(port, PORT_KEY, 2)
    woken :: slop_os.port_wait(port, taken, slop_os.NO_DEADLINE)
    page^[11] = tag_of(woken)
    page^[12] = cast[u64](woken or_else 0)
    page^[13] = packets^[0]
    page^[14] = packets^[1] & 0xffffffff
    page^[15] = packets^[2]
    // A timer
    set :: clock_now()
    _ = slop_os.port_set_timer(port, TIMER_KEY, set + TIMER_NANOSECONDS)
    timed :: slop_os.port_wait(port, taken, slop_os.NO_DEADLINE)
    after_timer :: clock_now()
    page^[16] = cast[u64](timed or_else 0)
    page^[17] = packets^[1] & 0xffffffff
    page^[18] = if after_timer - set >= TIMER_NANOSECONDS { cast[u64](1) } else { cast[u64](0) }
    // A deadline, with nothing to take
    started :: clock_now()
    nothing :: slop_os.port_wait(port, taken, started + DEADLINE_NANOSECONDS)
    after_deadline :: clock_now()
    page^[19] = cast[u64](nothing or_else 0)
    page^[20] = if after_deadline - started >= DEADLINE_NANOSECONDS { cast[u64](1) } else { cast[u64](0) }
    // Memory it can't write
    page^[21] = tag_of(slop_os.port_wait(port, packets_at(0x10, 4), slop_os.NO_DEADLINE))
    // B wakes it
    space :: handle_at[slop_os.AddressSpace](page^[0])
    _ = slop_os.thread_create(budget, space, page^[PORT_SLOT_ENTRY], page^[PORT_SLOT_STACK], base)
    from_b :: slop_os.port_wait(port, taken, slop_os.NO_DEADLINE)
    page^[22] = if (from_b or_else 0) == 1 { packets^[2] } else { cast[u64](0) }
    intrinsics.volatile_store_u64(&page^[PORT_SLOT_A_WOKEN], 1)
    page^[25] = tag_of(slop_os.port_unbind(port, PORT_KEY))
    page^[26] = tag_of(slop_os.port_wake(port, PORT_KEY, 1))
    // Once B waits, and a while more, closing the port wakes it
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[PORT_SLOT_B_WAITING]) == 0
    while_b :: clock_now()
    _ = slop_os.port_wait(port, taken, while_b + DEADLINE_NANOSECONDS)
    page^[27] = tag_of(slop_os.handle_close(cast[slop_os.Handle](port)))
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[23]) == 0
    intrinsics.volatile_store_u64(&page^[24], 1)
    slop_os.thread_exit()
}

user_port_helper #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    port :: handle_at[slop_os.Port](intrinsics.volatile_load_u64(&page^[PORT_SLOT_PORT]))
    _ = slop_os.port_wake(port, PORT_KEY, 0x100)
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[PORT_SLOT_A_WOKEN]) == 0
    intrinsics.volatile_store_u64(&page^[PORT_SLOT_B_WAITING], 1)
    gone :: slop_os.port_wait(port, packets_at(cast[u64](page) + PORT_B_PACKETS_OFFSET, 4), slop_os.NO_DEADLINE)
    intrinsics.volatile_store_u64(&page^[23], tag_of(gone))
    slop_os.thread_exit()
}

test_ports :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[PortsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_ports: no memory")
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("test_ports: no process: %", error)
            return void
        }
    }
    test.process = cast[u64](process)
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), 0) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("test_ports: no address space: %", error)
            return void
        }
    }
    // The kernel's code, with the functions and the stubs they call
    first :: kernel.code_base
    last :: kernel.code_base + kernel.code_size
    if !mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (first - kernel.image_base), last - first, USER_CODE) {
        return void
    }
    page :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_ports: no memory")
    stacks :: frames.allocate_zeroed(&kernel.frames, 1) or_else out_of_memory(&kernel.options, "test_ports: no memory")
    if !mapped_for_test(kernel, space, TEST_COUNTERS, cast[u64](page), frames.FRAME_SIZE, USER_DATA)
        || !mapped_for_test(kernel, space, TEST_STACKS, cast[u64](stacks), 2 * frames.FRAME_SIZE, USER_DATA) {
        return void
    }
    test.page = frames.virtual_of(&kernel.frames, page)
    slots :: cast[ptr[mut u64[64]]](test.page)
    match install(kernel, &process.table, cast[u64](space), space.header.generation, .AddressSpace, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[0] = cast[u64](cast[u32](handle))
        case Error(error) => {
            runtime.log_error("test_ports: no handle: %", error)
            return void
        }
    }
    if !give_test_budget(kernel, process, test.page) {
        return void
    }
    slots^[PORT_SLOT_ENTRY] = TEST_CODE + (cast[u64](user_port_helper) - first)
    slots^[PORT_SLOT_STACK] = TEST_STACKS + 2 * frames.FRAME_SIZE - 8
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (cast[u64](user_ports) - first)),
        stack_pointer = cast[arch_interface.VirtualAddress](TEST_STACKS + frames.FRAME_SIZE - 8),
        argument = TEST_COUNTERS,
    }
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0, 0) {
        case Ok(thread) => start_thread(kernel, thread)
        case Error(error) => {
            runtime.log_error("test_ports: no thread: %", error)
            return void
        }
    }
    kernel.stop_after_ticks = PORTS_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.ports_test, cast[u64](test))
}

ports_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.ports_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut PortsTest]](address)
    if tick == PORTS_TEST_DESTROY_TICK {
        check_port_results(test)
        _ = destroy_object(kernel, test.process)
        return void
    }
    if tick != PORTS_TEST_TICKS {
        return void
    }
    if pool_of(kernel, .Port).allocated != 0 || kernel.pools.bindings.allocated != 0 || pool_of(kernel, .Thread).allocated != 0 {
        runtime.log_error("test_ports: left after the process was destroyed: % ports, % bindings, % threads",
            pool_of(kernel, .Port).allocated, kernel.pools.bindings.allocated, pool_of(kernel, .Thread).allocated)
        return void
    }
    runtime.log_info("test_ports: destroying the process freed its ports and their bindings")
}

check_port_results :: fn(test: ptr[PortsTest]) {
    slots :: cast[ptr[u64[64]]](test.page)
    expected :: u64.[
        0, cast[u64](cast[u32](slop_os.PortError.KeyInUse)), cast[u64](cast[u32](slop_os.PortError.NoSuchKey)),
        0, 1, PORT_KEY, cast[u64](cast[u32](slop_os.PacketKind.User)), 3,
        1, cast[u64](cast[u32](slop_os.PacketKind.Timer)), 1,
        0, 1,
        cast[u64](cast[u32](slop_os.PortError.BadBuffer)),
        0x100,
        cast[u64](cast[u32](slop_os.PortError.ObjectGone)), 1,
        0, cast[u64](cast[u32](slop_os.PortError.NoSuchKey)), 0,
    ]
    for value, i in expected {
        if slots^[8 + i] != value {
            runtime.log_error("test_ports: result % is %, not %", i, slots^[8 + i], value)
            return void
        }
    }
    runtime.log_info("test_ports: wakes, timers, deadlines and other threads woke waiters; closing the port woke the last")
}
