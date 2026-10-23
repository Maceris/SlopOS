package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import slop_os from "std/os"
import frames from "frames"

/*
 * test_control: a debugger D, a process in user mode, holds a handle to a target process T with every
 * process right, as T's creator would, and a handle to T's address space. T has two threads: T1 makes
 * system calls and faults, T2 counts. D keeps what each call gave in its page:
 * - T's subtree has two threads; D intercepts ClockMonotonic's entry and exit, and faults, and can't
 *   intercept T twice; it watches for T's end;
 * - D starts T1 by writing to T's memory; T1's first ClockMonotonic stops at its entry, where D sets the
 *   result registers and skips the call, so T1 gets D's value;
 * - the second runs (Continue at its entry), and stops at its exit, where D changes its result;
 * - T1 writes where nothing is mapped: D maps memory there in T's space and lets it retry, which works;
 * - D reads what T1 got from T's memory; suspends T2, whose count then stands still and whose registers
 *   it can read, and resumes it, when it counts again and they can't be read;
 * - D kills T, and its port tells it T ended.
 * Then the kernel destroys D, and every intercept and thread is gone.
 */

CONTROL_TEST_TICKS : u64 : 120
CONTROL_TEST_DESTROY_TICK : u64 : 110
// D's page's slots, then its results from 8.
CONTROL_SLOT_TARGET :: 0
CONTROL_SLOT_TARGET_SPACE :: 1
CONTROL_SLOT_T1 :: 2
CONTROL_SLOT_T2 :: 3
CONTROL_SLOT_SPACE :: 4
CONTROL_SLOT_ONE :: 5
CONTROL_SLOT_DONE :: 50
// T's page's slots.
TARGET_SLOT_GO :: 0
TARGET_SLOT_COUNTER :: 1
TARGET_SLOT_DONE :: 2
TARGET_RESULTS :: 8
// Where D keeps what calls write, in its page.
CONTROL_IDS_OFFSET : u64 : 1024
CONTROL_STOP_OFFSET : u64 : 1088
CONTROL_PACKETS_OFFSET : u64 : 1152
CONTROL_REGISTERS_OFFSET : u64 : 1280
CONTROL_READ_OFFSET : u64 : 1536
CONTROL_KEY : u64 : 21
WATCH_KEY : u64 : 22
SKIPPED_VALUE : u64 : 12345
CHANGED_VALUE : u64 : 777
FAULT_AT : u64 : 0x6000000
FAULT_VALUE : u64 : 4242
REGISTER_RAX :: 0
REGISTER_RDX :: 3
COUNTING_NANOSECONDS : u64 : 10_000_000
RESUME_NANOSECONDS : u64 : 200_000_000

ControlTest :: struct {
    debugger : u64,
    target : u64,
    page : u64,
}

user_target #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(&page^[TARGET_SLOT_GO]) == 0
    page^[TARGET_RESULTS] = call(.ClockMonotonic).rdx
    page^[TARGET_RESULTS + 1] = call(.ClockMonotonic).rdx
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](FAULT_AT), FAULT_VALUE)
    page^[TARGET_RESULTS + 2] = intrinsics.volatile_load_u64(cast[ptr[u64]](FAULT_AT))
    intrinsics.volatile_store_u64(&page^[TARGET_SLOT_DONE], 1)
    loop {
        intrinsics.spin_hint()
    }
}

user_counter_thread #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(&page^[TARGET_SLOT_COUNTER], intrinsics.volatile_load_u64(&page^[TARGET_SLOT_COUNTER]) + 1)
    }
}

// The next stop's StopInfo, at stop, once the intercept's packet says there is one.
next_stop :: fn(port: u64, intercept: u64, base: u64) #no_context {
    loop {
        if call(.InterceptNext, intercept, base + CONTROL_STOP_OFFSET).rax == 0 {
            break
        }
        _ = call(.PortWait, port, base + CONTROL_PACKETS_OFFSET, 1, slop_os.NO_DEADLINE)
    }
}

// A u64 of T's page, read through D's process handle.
read_target :: fn(page: ptr[mut u64[64]], slot: u64) -> u64 #no_context {
    base :: cast[u64](page)
    _ = call(.ProcessReadMemory, page^[CONTROL_SLOT_TARGET], page^[CONTROL_SLOT_TARGET_SPACE], TEST_COUNTERS + slot * 8,
        base + CONTROL_READ_OFFSET, 8)
    return intrinsics.volatile_load_u64(cast[ptr[u64]](base + CONTROL_READ_OFFSET))
}

wait_nanoseconds :: fn(nanoseconds: u64) #no_context {
    started :: call(.ClockMonotonic).rdx
    loop {
        intrinsics.spin_hint()
    }
    while call(.ClockMonotonic).rdx - started < nanoseconds
}

user_debugger #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    base :: cast[u64](page)
    target :: page^[CONTROL_SLOT_TARGET]
    target_space :: page^[CONTROL_SLOT_TARGET_SPACE]
    t1 :: page^[CONTROL_SLOT_T1]
    t2 :: page^[CONTROL_SLOT_T2]
    stop :: cast[ptr[slop_os.StopInfo]](base + CONTROL_STOP_OFFSET)
    registers :: cast[ptr[mut u64[18]]](base + CONTROL_REGISTERS_OFFSET)
    port :: call(.PortCreate, page^[TEST_SLOT_BUDGET]).rdx
    // T's threads, an intercept, a second refused, and a watch for its end
    page^[8] = call(.ProcessThreads, target, base + CONTROL_IDS_OFFSET, 4).rdx
    points :: cast[u64](slop_os.STOP_SYSCALL_ENTRY | slop_os.STOP_SYSCALL_EXIT | slop_os.STOP_FAULT)
    calls :: cast[u64](1) << cast[u64](cast[u32](slop_os.Syscall.ClockMonotonic))
    intercept :: call(.InterceptAttach, target, port, CONTROL_KEY, calls, points)
    page^[9] = intercept.rax
    page^[10] = call(.InterceptAttach, target, port, CONTROL_KEY + 100, calls, points).rax
    page^[11] = call(.PortBind, port, target, cast[u64](cast[u32](slop_os.SIGNAL_TERMINATED)), WATCH_KEY,
        cast[u64](cast[u32](slop_os.BindMode.Persistent))).rax
    // T1 goes, by a write to T's memory
    page^[CONTROL_SLOT_ONE] = 1
    page^[12] = call(.ProcessWriteMemory, target, target_space, TEST_COUNTERS + TARGET_SLOT_GO * 8, base + CONTROL_SLOT_ONE * 8, 8).rax
    // The first call, at its entry: answered, and skipped
    next_stop(port, intercept.rdx, base)
    page^[13] = if stop.thread == t1 { cast[u64](cast[u32](stop.point)) } else { cast[u64](0) }
    page^[14] = cast[u64](stop.number)
    page^[15] = call(.ThreadReadRegisters, target, t1, base + CONTROL_REGISTERS_OFFSET).rax
    page^[16] = registers^[REGISTER_RAX]
    registers^[REGISTER_RAX] = 0
    registers^[REGISTER_RDX] = SKIPPED_VALUE
    page^[17] = call(.ThreadWriteRegisters, target, t1, base + CONTROL_REGISTERS_OFFSET).rax
    page^[18] = call(.InterceptResume, intercept.rdx, t1, cast[u64](cast[u32](slop_os.InterceptAction.Skip))).rax
    // The second runs, and its result is changed at its exit
    next_stop(port, intercept.rdx, base)
    page^[19] = cast[u64](cast[u32](stop.point))
    _ = call(.InterceptResume, intercept.rdx, t1, cast[u64](cast[u32](slop_os.InterceptAction.Continue)))
    next_stop(port, intercept.rdx, base)
    page^[20] = cast[u64](cast[u32](stop.point))
    _ = call(.ThreadReadRegisters, target, t1, base + CONTROL_REGISTERS_OFFSET)
    registers^[REGISTER_RDX] = CHANGED_VALUE
    _ = call(.ThreadWriteRegisters, target, t1, base + CONTROL_REGISTERS_OFFSET)
    page^[21] = call(.InterceptResume, intercept.rdx, t1, cast[u64](cast[u32](slop_os.InterceptAction.Skip))).rax
    _ = call(.InterceptResume, intercept.rdx, t1, cast[u64](cast[u32](slop_os.InterceptAction.Continue)))
    // The fault: memory mapped where it wrote, and it tries again
    next_stop(port, intercept.rdx, base)
    page^[22] = cast[u64](cast[u32](stop.point))
    page^[23] = if stop.address == FAULT_AT { cast[u64](1) } else { cast[u64](0) }
    memory :: call(.MemoryCreate, page^[TEST_SLOT_BUDGET], frames.FRAME_SIZE).rdx
    read_write :: cast[u64](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    page^[24] = call(.MemoryMap, memory, target_space, FAULT_AT, 0, frames.FRAME_SIZE, read_write).rax
    _ = call(.InterceptResume, intercept.rdx, t1, cast[u64](cast[u32](slop_os.InterceptAction.Continue)))
    loop {
        intrinsics.spin_hint()
    }
    while read_target(page, TARGET_SLOT_DONE) == 0
    page^[25] = read_target(page, TARGET_RESULTS)
    page^[26] = read_target(page, TARGET_RESULTS + 1)
    page^[27] = read_target(page, TARGET_RESULTS + 2)
    // T2, suspended: its count stands still, and its registers can be read; resumed, it counts, and they can't
    page^[28] = call(.ThreadSuspend, target, t2).rax
    wait_nanoseconds(COUNTING_NANOSECONDS)
    before :: read_target(page, TARGET_SLOT_COUNTER)
    wait_nanoseconds(COUNTING_NANOSECONDS)
    page^[29] = if read_target(page, TARGET_SLOT_COUNTER) == before { cast[u64](1) } else { cast[u64](0) }
    page^[30] = call(.ThreadReadRegisters, target, t2, base + CONTROL_REGISTERS_OFFSET).rax
    page^[31] = call(.ThreadResume, target, t2).rax
    // Three threads busy on two CPUs, preempted at ticks: it runs again within a few
    resumed :: call(.ClockMonotonic).rdx
    loop {
        intrinsics.spin_hint()
    }
    while read_target(page, TARGET_SLOT_COUNTER) == before && call(.ClockMonotonic).rdx - resumed < RESUME_NANOSECONDS
    page^[32] = if read_target(page, TARGET_SLOT_COUNTER) > before { cast[u64](1) } else { cast[u64](0) }
    page^[33] = call(.ThreadReadRegisters, target, t2, base + CONTROL_REGISTERS_OFFSET).rax
    // T killed, and its end seen, once the stops' packet is out of the way
    loop {
        if call(.PortWait, port, base + CONTROL_PACKETS_OFFSET, 1, 0).rdx == 0 {
            break
        }
    }
    page^[34] = call(.ProcessKill, target).rax
    ended :: call(.PortWait, port, base + CONTROL_PACKETS_OFFSET, 1, slop_os.NO_DEADLINE)
    packet :: cast[ptr[u64[4]]](base + CONTROL_PACKETS_OFFSET)
    page^[35] = if ended.rdx == 1 && packet^[0] == WATCH_KEY && packet^[2] & cast[u64](cast[u32](slop_os.SIGNAL_TERMINATED)) != 0 { cast[u64](1) }
        else { cast[u64](0) }
    intrinsics.volatile_store_u64(&page^[CONTROL_SLOT_DONE], 1)
    _ = call(.ThreadExit)
    loop {
        intrinsics.spin_hint()
    }
}

// A process with an address space mapping the test's code and a page and stacks of its own: the page's direct-map address.
control_process :: fn(kernel: ptr[mut Kernel], first: u64, last: u64) -> (process #unrestricted : ptr[mut Process]?, space #unrestricted : ptr[mut AddressSpace]?, page: u64) {
    made := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, 0) {
        case Ok(process) => made = process
        case Error(error) => return null, null, 0
    }
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](made), 0) {
        case Ok(created) => space = created
        case Error(error) => return null, null, 0
    }
    page :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_control: no memory")
    stacks :: frames.allocate_zeroed(&kernel.frames, 1) or_else out_of_memory(&kernel.options, "test_control: no memory")
    if !mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (first - kernel.image_base), last - first, USER_CODE)
        || !mapped_for_test(kernel, space, TEST_COUNTERS, cast[u64](page), frames.FRAME_SIZE, USER_DATA)
        || !mapped_for_test(kernel, space, TEST_STACKS, cast[u64](stacks), 2 * frames.FRAME_SIZE, USER_DATA) {
        return null, null, 0
    }
    return made, space, frames.virtual_of(&kernel.frames, page)
}

/*
 * A thread of process in space, at function in the test's code, with stack the stack's top, given
 * TEST_COUNTERS, started: its ID, 0 if it couldn't be made.
 */
control_thread :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], space #escaping : ptr[mut AddressSpace], first: u64, function: u64,
    stack: u64) -> u64 {
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (function - first)),
        stack_pointer = cast[arch_interface.VirtualAddress](stack),
        argument = TEST_COUNTERS,
    }
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0, 0) {
        case Ok(thread) => {
            start_thread(kernel, thread)
            return thread.id
        }
        case Error(error) => return 0
    }
}

test_control :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[ControlTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_control: no memory")
    lowest := min_u64(min_u64(cast[u64](user_target), cast[u64](user_counter_thread)), min_u64(cast[u64](user_debugger), cast[u64](call)))
    lowest = min_u64(lowest, min_u64(min_u64(cast[u64](next_stop), cast[u64](read_target)), cast[u64](wait_nanoseconds)))
    highest := max_u64(max_u64(cast[u64](user_target), cast[u64](user_counter_thread)), max_u64(cast[u64](user_debugger), cast[u64](call)))
    highest = max_u64(highest, max_u64(max_u64(cast[u64](next_stop), cast[u64](read_target)), cast[u64](wait_nanoseconds)))
    first :: lowest & ~(frames.FRAME_SIZE - 1)
    last :: frames.round_up(highest + 4 * frames.FRAME_SIZE, frames.FRAME_SIZE)
    debugger, debugger_space, page :: control_process(kernel, first, last)
    target, target_space, target_page :: control_process(kernel, first, last)
    if debugger == null || target == null || debugger_space == null || target_space == null {
        runtime.log_error("test_control: no processes")
        return void
    }
    d :: debugger or_else cast[ptr[mut Process]](0)
    t :: target or_else cast[ptr[mut Process]](0)
    d_space :: debugger_space or_else cast[ptr[mut AddressSpace]](0)
    t_space :: target_space or_else cast[ptr[mut AddressSpace]](0)
    test.debugger = cast[u64](d)
    test.target = cast[u64](t)
    test.page = page
    if !give_test_budget(kernel, d, page) {
        return void
    }
    slots :: cast[ptr[mut u64[64]]](page)
    // D's handles to T and T's space, as T's creator would have them
    handed := true
    match install(kernel, &d.table, cast[u64](t), t.header.generation, .Process, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[CONTROL_SLOT_TARGET] = cast[u64](cast[u32](handle))
        case Error(error) => handed = false
    }
    match install(kernel, &d.table, cast[u64](t_space), t_space.header.generation, .AddressSpace, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[CONTROL_SLOT_TARGET_SPACE] = cast[u64](cast[u32](handle))
        case Error(error) => handed = false
    }
    if !handed {
        runtime.log_error("test_control: no handles for the debugger")
        return void
    }
    // T's threads first, so D knows them when it starts
    slots^[CONTROL_SLOT_T1] = control_thread(kernel, t, t_space, first, cast[u64](user_target), TEST_STACKS + frames.FRAME_SIZE - 8)
    slots^[CONTROL_SLOT_T2] = control_thread(kernel, t, t_space, first, cast[u64](user_counter_thread), TEST_STACKS + 2 * frames.FRAME_SIZE - 8)
    if slots^[CONTROL_SLOT_T1] == 0 || slots^[CONTROL_SLOT_T2] == 0
        || control_thread(kernel, d, d_space, first, cast[u64](user_debugger), TEST_STACKS + frames.FRAME_SIZE - 8) == 0 {
        runtime.log_error("test_control: no threads")
        return void
    }
    kernel.stop_after_ticks = CONTROL_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.control_test, cast[u64](test))
}

control_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.control_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut ControlTest]](address)
    if tick == CONTROL_TEST_DESTROY_TICK {
        check_control_results(test)
        _ = destroy_object(kernel, test.target)
        _ = destroy_object(kernel, test.debugger)
        return void
    }
    if tick != CONTROL_TEST_TICKS {
        return void
    }
    pools :: &kernel.pools
    if pools.intercepts.allocated != 0 || pools.threads.allocated != 0 || pools.processes.allocated != 0 {
        runtime.log_error("test_control: left after the processes were destroyed: % intercepts, % threads, % processes",
            pools.intercepts.allocated, pools.threads.allocated, pools.processes.allocated)
        return void
    }
    runtime.log_info("test_control: destroying the debugger freed its intercept, and the target's threads")
}

check_control_results :: fn(test: ptr[ControlTest]) {
    slots :: cast[ptr[u64[64]]](test.page)
    if slots^[CONTROL_SLOT_DONE] != 1 {
        runtime.log_error("test_control: the debugger didn't finish")
        return void
    }
    clock :: cast[u64](cast[u32](slop_os.Syscall.ClockMonotonic))
    entry :: cast[u64](cast[u32](slop_os.StopPoint.SyscallEntry))
    exit :: cast[u64](cast[u32](slop_os.StopPoint.SyscallExit))
    expected :: u64.[
        2, 0, control_tag(.AlreadyIntercepted), 0, 0,
        entry, clock, 0, clock, 0, 0,
        entry, exit, control_tag(.NotStopped),
        cast[u64](cast[u32](slop_os.StopPoint.Fault)), 1, 0,
        SKIPPED_VALUE, CHANGED_VALUE, FAULT_VALUE,
        0, 1, 0, 0, 1, control_tag(.NotStopped),
        0, 1,
    ]
    for value, i in expected {
        if slots^[8 + i] != value {
            runtime.log_error("test_control: result % is %, not %", i, slots^[8 + i], value)
            return void
        }
    }
    runtime.log_info("test_control: a debugger skipped and answered a call, changed a result, fixed a fault, read and wrote memory, suspended and resumed a thread, and killed the process it watched")
}

// A control error's tag, as a call gives it.
control_tag :: fn(error: slop_os.ControlError) -> u64 {
    return cast[u64](cast[u32](error))
}
