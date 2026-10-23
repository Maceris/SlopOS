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
 * test_syscalls: a thread in user mode makes system calls, and keeps what each gave in its page, which the
 * kernel checks at the end:
 * - what its address space's handle is, a copy with fewer rights, and a copy asking for more (refused);
 * - closing a handle twice (the second time, it's no handle);
 * - a thread of its own, and a non-owning copy of its handle; a process, made and destroyed;
 * - once its thread has counted for a while, closing its owning handle destroys it, and the copy then
 *   reaches nothing (ObjectGone); then it exits.
 * The destroyed thread has to have stopped counting. Then the kernel destroys the process, and once every
 * CPU has passed a quiescent point, every object it owned is back in its pool.
 *
 * Its user code is kernel code that needs nothing else, as threads_test.hsc's: real programs will call
 * through the ABI package's stubs (M5, the ABI package).
 */

SYSCALLS_TEST_TICKS : u64 : 60
// Where the kernel destroys the process, before the end, so reclamation has ticks to catch up.
SYSCALLS_TEST_DESTROY_TICK : u64 : 50
// The page's slots: what the kernel gives, then what the thread found.
SLOT_SPACE :: 0
SLOT_ENTRY :: 1
SLOT_STACK :: 2
SLOT_COUNTER :: 3
SLOT_RESULTS :: 8
SLOT_DONE :: 22
// How far the thread lets its own count before destroying it.
COUNT_BEFORE_CLOSE : u64 : 100000

SyscallsTest :: struct {
    process : u64,
    // The page, and the created thread's counter, in the direct map
    page : u64,
    counter : u64,
    // The counter, 5 ticks before the process is destroyed
    sampled : u64,
}

user_syscalls #calling_convention(.c) #no_context :: fn(page: ptr[mut u64[64]]) #never_returns {
    space :: page^[SLOT_SPACE]
    info :: x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleInfo)), space)
    page^[8] = info.rax
    page^[9] = info.rdx
    page^[10] = info.r8
    copy :: x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleDuplicate)), space, cast[u64](cast[u32](slop_os.RIGHT_DUPLICATE)))
    page^[11] = copy.rax
    page^[12] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleInfo)), copy.rdx).r8
    page^[13] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleDuplicate)), copy.rdx,
        cast[u64](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))).rax
    page^[14] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleClose)), copy.rdx).rax
    page^[15] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleClose)), copy.rdx).rax
    thread :: x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.ThreadCreate)), space, page^[SLOT_ENTRY], page^[SLOT_STACK],
        page^[SLOT_COUNTER])
    page^[16] = thread.rax
    watch :: x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleDuplicate)), thread.rdx, cast[u64](cast[u32](slop_os.RIGHT_DUPLICATE)))
    page^[17] = watch.rax
    child :: x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.ProcessCreate)))
    page^[18] = child.rax
    page^[19] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleClose)), child.rdx).rax
    counter :: cast[ptr[u64]](page^[SLOT_COUNTER])
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(counter) < COUNT_BEFORE_CLOSE
    page^[20] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleClose)), thread.rdx).rax
    page^[21] = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.HandleInfo)), watch.rdx).rax
    intrinsics.volatile_store_u64(&page^[SLOT_DONE], 1)
    _ = x86_64.system_call(cast[u64](cast[u32](slop_os.Syscall.ThreadExit)))
    loop {
        intrinsics.spin_hint()
    }
}

test_syscalls :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[SyscallsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_syscalls: no memory")
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("test_syscalls: no process: %", error)
            return void
        }
    }
    test.process = cast[u64](process)
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process)) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("test_syscalls: no address space: %", error)
            return void
        }
    }
    // Both functions, and the code between them
    first :: min_u64(cast[u64](user_syscalls), cast[u64](user_counter)) & ~(frames.FRAME_SIZE - 1)
    last :: frames.round_up(max_u64(cast[u64](user_syscalls), cast[u64](user_counter)) + 4 * frames.FRAME_SIZE, frames.FRAME_SIZE)
    if !mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (first - kernel.image_base), last - first, USER_CODE) {
        return void
    }
    page :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_syscalls: no memory")
    counter :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_syscalls: no memory")
    stacks :: frames.allocate_zeroed(&kernel.frames, 1) or_else out_of_memory(&kernel.options, "test_syscalls: no memory")
    if !mapped_for_test(kernel, space, TEST_COUNTERS, cast[u64](page), frames.FRAME_SIZE, USER_DATA)
        || !mapped_for_test(kernel, space, TEST_COUNTERS + frames.FRAME_SIZE, cast[u64](counter), frames.FRAME_SIZE, USER_DATA)
        || !mapped_for_test(kernel, space, TEST_STACKS, cast[u64](stacks), 2 * frames.FRAME_SIZE, USER_DATA) {
        return void
    }
    test.page = frames.virtual_of(&kernel.frames, page)
    test.counter = frames.virtual_of(&kernel.frames, counter)
    // A handle to the space in the process's table, as its creator would give it
    slots :: cast[ptr[mut u64[64]]](test.page)
    match install(kernel, &process.table, cast[u64](space), space.header.generation, .AddressSpace, slop_os.RIGHTS_ALL, false) {
        case Ok(handle) => slots^[SLOT_SPACE] = cast[u64](cast[u32](handle))
        case Error(error) => {
            runtime.log_error("test_syscalls: no handle: %", error)
            return void
        }
    }
    slots^[SLOT_ENTRY] = TEST_CODE + (cast[u64](user_counter) - first)
    slots^[SLOT_STACK] = TEST_STACKS + 2 * frames.FRAME_SIZE - 8
    slots^[SLOT_COUNTER] = TEST_COUNTERS + frames.FRAME_SIZE
    start :: arch_interface.UserStart.{
        instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (cast[u64](user_syscalls) - first)),
        stack_pointer = cast[arch_interface.VirtualAddress](TEST_STACKS + frames.FRAME_SIZE - 8),
        argument = TEST_COUNTERS,
    }
    match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, 0) {
        case Ok(thread) => start_thread(kernel, thread)
        case Error(error) => {
            runtime.log_error("test_syscalls: no thread: %", error)
            return void
        }
    }
    kernel.stop_after_ticks = SYSCALLS_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.syscalls_test, cast[u64](test))
}

// At each of the boot CPU's ticks while test_syscalls runs.
syscalls_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.syscalls_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut SyscallsTest]](address)
    if tick == SYSCALLS_TEST_DESTROY_TICK - 5 {
        test.sampled = intrinsics.volatile_load_u64(cast[ptr[u64]](test.counter))
        return void
    }
    if tick == SYSCALLS_TEST_DESTROY_TICK {
        check_syscall_results(kernel, test)
        _ = destroy_object(kernel, test.process)
        return void
    }
    if tick != SYSCALLS_TEST_TICKS {
        return void
    }
    // Everything the process owned, back in its pool
    if kernel.pools.processes.allocated != 0 || kernel.pools.threads.allocated != 0 || kernel.pools.spaces.allocated != 0 {
        runtime.log_error("test_syscalls: objects left after the process was destroyed: % processes, % threads, % address spaces",
            kernel.pools.processes.allocated, kernel.pools.threads.allocated, kernel.pools.spaces.allocated)
        return void
    }
    runtime.log_info("test_syscalls: destroying the process freed everything it owned, after a grace period")
}

check_syscall_results :: fn(kernel: ptr[Kernel], test: ptr[SyscallsTest]) {
    slots :: cast[ptr[u64[64]]](test.page)
    expected :: u64.[
        0, cast[u64](cast[u8](slop_os.ObjectKind.AddressSpace)), cast[u64](cast[u32](slop_os.RIGHTS_ALL)),
        0, cast[u64](cast[u32](slop_os.RIGHT_DUPLICATE)),
        cast[u64](cast[u32](slop_os.HandleError.MissingRight)),
        0, cast[u64](cast[u32](slop_os.HandleError.InvalidHandle)),
        0, 0, 0, 0,
        0, cast[u64](cast[u32](slop_os.HandleError.ObjectGone)),
        1,
    ]
    for value, i in expected {
        if slots^[SLOT_RESULTS + i] != value {
            runtime.log_error("test_syscalls: result % is %, not %", i, slots^[SLOT_RESULTS + i], value)
            return void
        }
    }
    now :: intrinsics.volatile_load_u64(cast[ptr[u64]](test.counter))
    if now < COUNT_BEFORE_CLOSE || now != test.sampled {
        runtime.log_error("test_syscalls: the destroyed thread counted % then %", test.sampled, now)
        return void
    }
    runtime.log_info("test_syscalls: handles were looked up, copied, refused, closed and went stale; threads and processes made and destroyed")
}

max_u64 :: fn(a, b: u64) -> u64 {
    return if a > b { a } else { b }
}
