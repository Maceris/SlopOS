package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import frames from "frames"
import slop_os from "std/os"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Threads in user mode, before there are programs to load (M6) or system calls (M5): each runs
 * user_counter, mapped into a user address space from the kernel image's own frames, counting in a page
 * of its own, which the kernel reads through the direct map.
 *
 * test_threads: THREADS_TEST_THREADS threads on 2 CPUs. Halfway through, the counts are noted; at the
 * end every thread has to have counted more since, so each was preempted and run again, and its XSAVE
 * area still has the xmm0 it started with, a pattern of its own, which a mix-up of vector states would
 * have moved to another thread.
 *
 * test_budgets: on 1 CPU, a thread with a budget of 30 ms every 100 ms at priority 10, and one in the
 * background band. The first gets its budget at its priority, then shares the background round robin:
 * about 65% of the time, and up to a tick more each period, since budgets are charged at ticks
 * (knowledge/design/scheduling.md §2). So more than half, and the other isn't starved: up to 90%.
 */

THREADS_TEST_THREADS :: 4
THREADS_TEST_TICKS : u64 : 40
BUDGETS_TEST_TICKS : u64 : 50
// Where the test maps things in each thread's address space
TEST_CODE : u64 : 0x400000
TEST_COUNTERS : u64 : 0x600000
TEST_STACKS : u64 : 0x800000
// Where xmm0 is in the XSAVE area's legacy region, and the SSE bit of the header's XSTATE_BV
XMM0_OFFSET : u64 : 160
XSTATE_BV_OFFSET : u64 : 512

USER_CODE :: arch_interface.Mapping.{protection = .ReadExecute, cache = .WriteBack, user = true, global = false}
USER_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = true, global = false}

ThreadsTest :: struct {
    threads : u64[THREADS_TEST_THREADS],
    // Each one's counter, in the direct map
    counters : u64[THREADS_TEST_THREADS],
    // The counts halfway
    halfway : u64[THREADS_TEST_THREADS],
    count : usize,
    budget : CpuBudget,
}

/*
 * Runs in user mode: counts in its argument's page for good. Without a context or a stack check, it
 * needs nothing but its own code and that page, so it runs from the kernel image's frames.
 */
user_counter #calling_convention(.c) #no_context :: fn(counter: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(counter, intrinsics.volatile_load_u64(counter) + 1)
    }
}

test_threads :: fn(kernel: ptr[mut Kernel]) {
    test :: start_threads_test(kernel, THREADS_TEST_THREADS, false) or_return void
    kernel.stop_after_ticks = THREADS_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.threads_test, cast[u64](test))
}

test_budgets :: fn(kernel: ptr[mut Kernel]) {
    test :: start_threads_test(kernel, 2, true) or_return void
    kernel.stop_after_ticks = BUDGETS_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.threads_test, cast[u64](test))
}

/*
 * count threads in one address space, started: the first bound to a budget if budgeted. Each starts with
 * xmm0 holding its index plus one in every byte.
 */
start_threads_test :: fn(kernel: ptr[mut Kernel], count: usize, budgeted: bool) -> ptr[mut ThreadsTest]? {
    test :: allocate_object[ThreadsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "threads test: no memory")
    test.count = count
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("threads test: no process: %", error)
            return null
        }
    }
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), 0) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("threads test: no address space: %", error)
            return null
        }
    }
    // user_counter's page and the next, from the image's frames
    code :: cast[u64](user_counter)
    page :: code & ~(frames.FRAME_SIZE - 1)
    physical :: kernel.image_physical + (page - kernel.image_base)
    if !mapped_for_test(kernel, space, TEST_CODE, physical, 2 * frames.FRAME_SIZE, USER_CODE) {
        return null
    }
    if budgeted {
        // 30 ms every 100 ms, at priority 10
        test.budget = make_budget(kernel, 10, 100_000_000, 30_000_000)
    }
    for i in 0..<count {
        if i >= THREADS_TEST_THREADS {
            break
        }
        counter :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "threads test: no memory")
        stack :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "threads test: no memory")
        counter_address :: TEST_COUNTERS + cast[u64](i) * frames.FRAME_SIZE
        stack_address :: TEST_STACKS + cast[u64](i) * 2 * frames.FRAME_SIZE
        if !mapped_for_test(kernel, space, counter_address, cast[u64](counter), frames.FRAME_SIZE, USER_DATA)
            || !mapped_for_test(kernel, space, stack_address, cast[u64](stack), frames.FRAME_SIZE, USER_DATA) {
            return null
        }
        test.counters[i] = frames.virtual_of(&kernel.frames, counter)
        // As after a call: the return address's slot below a 16-byte boundary
        start :: arch_interface.UserStart.{
            instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (code - page)),
            stack_pointer = cast[arch_interface.VirtualAddress](stack_address + frames.FRAME_SIZE - 8),
            argument = counter_address,
        }
        budget :: if budgeted && i == 0 { cast[u64](&test.budget) } else { cast[u64](0) }
        thread := cast[ptr[mut Thread]](0)
        match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, budget, 0) {
            case Ok(made) => thread = made
            case Error(error) => {
                runtime.log_error("threads test: no thread: %", error)
                return null
            }
        }
        mark_vector_state(thread, cast[u8](i + 1))
        test.threads[i] = cast[u64](thread)
    }
    for i in 0..<count {
        if i < THREADS_TEST_THREADS {
            start_thread(kernel, cast[ptr[mut Thread]](test.threads[i]))
        }
    }
    return test
}

/*
 * The kernel's code, mapped at TEST_CODE in space for a test's code in user mode, which calls system calls
 * through the ABI package's stubs, wherever they are in it.
 */
map_test_code :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) -> bool {
    return mapped_for_test(kernel, space, TEST_CODE, kernel.image_physical + (kernel.code_base - kernel.image_base), kernel.code_size, USER_CODE)
}

// Where a function of the kernel's is, in the test's mapping of its code.
test_address :: fn(kernel: ptr[Kernel], function: u64) -> u64 {
    return TEST_CODE + (function - kernel.code_base)
}

// A call's result as a test records it: 0, or its error's tag.
tag_of :: fn[T, E](result: Result[T, E]) -> u64 #no_context {
    return match result {
        case Error(error) => cast[u64](cast[u32](error))
        case _ => 0
    }
}

// A handle of any kind as a test's page holds it, and back.
slot_of :: fn[H](handle: H) -> u64 #no_context {
    return cast[u64](cast[u32](cast[slop_os.Handle](handle)))
}

handle_at :: fn[H](word: u64) -> H #no_context {
    return cast[H](cast[slop_os.Handle](cast[u32](word)))
}

// count packets at address, for a port_wait.
packets_at :: fn(address: u64, count: usize) -> slop_os.Packet[] #no_context {
    return bit_cast[slop_os.Packet[]](usize.[count, cast[usize](address)])
}

// count bytes at address, as a slice for a call.
bytes_at :: fn(address: u64, count: usize) -> u8[] #no_context {
    return bit_cast[u8[]](usize.[count, cast[usize](address)])
}

// The monotonic clock, in user mode.
clock_now :: fn() -> u64 #no_context {
    return slop_os.clock_monotonic() or_else 0
}

// Where each test's page holds a handle to the budget its user code pays with.
TEST_SLOT_BUDGET :: 7
TEST_BUDGET_LIMIT : u64 : 16 << 20

/*
 * A budget for a test's process to pay with: a child of the root budget that the process owns, so it's
 * closed, and what it was charged goes back to the root, when the process is destroyed. Its handle goes
 * in page's TEST_SLOT_BUDGET.
 */
give_test_budget :: fn(kernel: ptr[mut Kernel], process: ptr[mut Process], page: u64) -> bool {
    match create_budget(kernel, cast[u64](process), kernel.root_budget, TEST_BUDGET_LIMIT) {
        case Ok(budget) => {
            match install_owning(kernel, process, cast[u64](budget)) {
                case Ok(handle) => {
                    cast[ptr[mut u64[64]]](page)^[TEST_SLOT_BUDGET] = cast[u64](cast[u32](handle))
                    return true
                }
                case Error(error) => runtime.log_error("no handle for a test's budget: %", error)
            }
        }
        case Error(error) => runtime.log_error("no budget for a test: %", error)
    }
    return false
}

mapped_for_test :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> bool {
    match map_user(kernel, space, address, physical, size, mapping) {
        case Ok => return true
        case Error(error) => {
            runtime.log_error("threads test: couldn't map %: %", cast[rawptr](address), error)
            return false
        }
    }
}

// xmm0 is byte in all 16 of its bytes, and the header says the SSE state is there.
mark_vector_state :: fn(thread: ptr[Thread], byte: u8) {
    area :: thread.vector + 64
    for i in 0..<16 {
        cast[ptr[mut u8]](area + XMM0_OFFSET + cast[u64](i))^ = byte
    }
    cast[ptr[mut u64]](area + XSTATE_BV_OFFSET)^ = 2
}

// Whether xmm0 in thread's saved state is still byte in every byte.
has_vector_mark :: fn(thread: ptr[Thread], byte: u8) -> bool {
    area :: thread.vector + 64
    for i in 0..<16 {
        if cast[ptr[u8]](area + XMM0_OFFSET + cast[u64](i))^ != byte {
            return false
        }
    }
    return true
}

// At each of the boot CPU's ticks while a threads test runs: halfway, the counts; at the end, the checks.
threads_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.threads_test)
    if address == 0 {
        return void
    }
    test :: cast[ptr[mut ThreadsTest]](address)
    count :: test.count
    runtime.assert(count <= THREADS_TEST_THREADS, "a threads test has up to THREADS_TEST_THREADS threads")
    if tick == kernel.stop_after_ticks / 2 {
        for i in 0..<count {
            test.halfway[i] = intrinsics.volatile_load_u64(cast[ptr[u64]](test.counters[i]))
        }
        return void
    }
    if tick != kernel.stop_after_ticks {
        return void
    }
    if kernel.options.test_budgets {
        check_budgets_test(kernel, test)
        return void
    }
    for i in 0..<count {
        thread :: cast[ptr[Thread]](test.threads[i])
        now :: intrinsics.volatile_load_u64(cast[ptr[u64]](test.counters[i]))
        if now <= test.halfway[i] || test.halfway[i] == 0 {
            runtime.log_error("test_threads: thread % counted % by halfway and % at the end", i, test.halfway[i], now)
            return void
        }
        if !has_vector_mark(thread, cast[u8](i + 1)) {
            runtime.log_error("test_threads: thread %'s xmm0 isn't its own", i)
            return void
        }
    }
    runtime.log_info("test_threads: % user threads on % CPUs, each preempted and run again, each with its own vector state",
        count, kernel.online_cpus)
}

check_budgets_test :: fn(kernel: ptr[Kernel], test: ptr[ThreadsTest]) {
    budgeted :: cast[ptr[Thread]](test.threads[0]).run_time
    background :: cast[ptr[Thread]](test.threads[1]).run_time
    total :: budgeted + background
    // Percent of the time each ran
    share :: if total > 0 { budgeted * 100 / total } else { cast[u64](0) }
    runtime.log_info("test_budgets: the budgeted thread ran % percent of the time", share)
    if share <= 50 || share > 90 {
        runtime.log_error("test_budgets: % percent is outside 50 to 90", share)
        return void
    }
    runtime.log_info("test_budgets: the budgeted thread got its budget at its priority, then shared the background")
}
