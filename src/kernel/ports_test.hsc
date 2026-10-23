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

// A system call by its number, in user mode.
call :: fn(number: slop_os.Syscall, a: u64 = 0, b: u64 = 0, c: u64 = 0, d: u64 = 0) -> x86_64.SystemCallResult #no_context {
    return x86_64.system_call(cast[u64](cast[u32](number)), a, b, c, d)
}

user_ports #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    packets :: cast[ptr[u64[16]]](base + PORT_PACKETS_OFFSET)
    port :: call(.PortCreate).rdx
    page^[PORT_SLOT_PORT] = port
    page^[8] = call(.PortBindWake, port, PORT_KEY).rax
    page^[9] = call(.PortBindWake, port, PORT_KEY).rax
    page^[10] = call(.PortWake, port, 99, 1).rax
    _ = call(.PortWake, port, PORT_KEY, 1)
    _ = call(.PortWake, port, PORT_KEY, 2)
    woken :: call(.PortWait, port, base + PORT_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    page^[11] = woken.rax
    page^[12] = woken.rdx
    page^[13] = packets^[0]
    page^[14] = packets^[1] & 0xffffffff
    page^[15] = packets^[2]
    // A timer
    set :: call(.ClockMonotonic).rdx
    _ = call(.PortSetTimer, port, TIMER_KEY, set + TIMER_NANOSECONDS)
    timed :: call(.PortWait, port, base + PORT_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    after_timer :: call(.ClockMonotonic).rdx
    page^[16] = timed.rdx
    page^[17] = packets^[1] & 0xffffffff
    page^[18] = if after_timer - set >= TIMER_NANOSECONDS { cast[u64](1) } else { cast[u64](0) }
    // A deadline, with nothing to take
    started :: call(.ClockMonotonic).rdx
    nothing :: call(.PortWait, port, base + PORT_PACKETS_OFFSET, 4, started + DEADLINE_NANOSECONDS)
    after_deadline :: call(.ClockMonotonic).rdx
    page^[19] = nothing.rdx
    page^[20] = if after_deadline - started >= DEADLINE_NANOSECONDS { cast[u64](1) } else { cast[u64](0) }
    // Memory it can't write
    page^[21] = call(.PortWait, port, 0x10, 4, slop_os.NO_DEADLINE).rax
    // B wakes it
    space :: page^[0]
    _ = call(.ThreadCreate, space, page^[PORT_SLOT_ENTRY], page^[PORT_SLOT_STACK], base)
    from_b :: call(.PortWait, port, base + PORT_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    page^[22] = if from_b.rdx == 1 { packets^[2] } else { cast[u64](0) }
    intrinsics.volatile_store_u64(&page^[PORT_SLOT_A_WOKEN], 1)
    page^[25] = call(.PortUnbind, port, PORT_KEY).rax
    page^[26] = call(.PortWake, port, PORT_KEY, 1).rax
    // Once B waits, and a while more, closing the port wakes it
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[PORT_SLOT_B_WAITING]) == 0
    while_b :: call(.ClockMonotonic).rdx
    _ = call(.PortWait, port, base + PORT_PACKETS_OFFSET, 4, while_b + DEADLINE_NANOSECONDS)
    page^[27] = call(.HandleClose, port).rax
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[23]) == 0
    intrinsics.volatile_store_u64(&page^[24], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

user_port_helper #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    port :: intrinsics.volatile_load_u64(&page^[PORT_SLOT_PORT])
    _ = call(.PortWake, port, PORT_KEY, 0x100)
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[PORT_SLOT_A_WOKEN]) == 0
    intrinsics.volatile_store_u64(&page^[PORT_SLOT_B_WAITING], 1)
    gone :: call(.PortWait, port, cast[u64](page) + PORT_B_PACKETS_OFFSET, 4, slop_os.NO_DEADLINE)
    intrinsics.volatile_store_u64(&page^[23], gone.rax)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

test_ports :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[PortsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_ports: no memory")
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("test_ports: no process: %", error)
            return void
        }
    }
    test.process = cast[u64](process)
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process)) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("test_ports: no address space: %", error)
            return void
        }
    }
    // Both functions, call, and the code between them
    first :: min_u64(min_u64(cast[u64](user_ports), cast[u64](user_port_helper)), cast[u64](call)) & ~(frames.FRAME_SIZE - 1)
    last :: frames.round_up(max_u64(max_u64(cast[u64](user_ports), cast[u64](user_port_helper)), cast[u64](call)) + 4 * frames.FRAME_SIZE,
        frames.FRAME_SIZE)
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
    slots^[PORT_SLOT_ENTRY] = TEST_CODE + (cast[u64](user_port_helper) - first)
    slots^[PORT_SLOT_STACK] = TEST_STACKS + 2 * frames.FRAME_SIZE - 8
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (cast[u64](user_ports) - first)),
        stack_pointer = cast[arch_interface.VirtualAddress](TEST_STACKS + frames.FRAME_SIZE - 8),
        argument = TEST_COUNTERS,
    }
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0) {
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
    if kernel.pools.ports.allocated != 0 || kernel.pools.bindings.allocated != 0 || kernel.pools.threads.allocated != 0 {
        runtime.log_error("test_ports: left after the process was destroyed: % ports, % bindings, % threads",
            kernel.pools.ports.allocated, kernel.pools.bindings.allocated, kernel.pools.threads.allocated)
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
