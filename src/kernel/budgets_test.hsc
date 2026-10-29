package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import frames from "frames"

/*
 * test_budgets: on 1 CPU, a thread in user mode with a CPU budget of 30 ms every 100 ms at priority 10, and one
 * in the background band, each running budget_counter, mapped into a user address space from the kernel image's
 * own frames, counting in a page of its own. The first gets its budget at its priority, then shares the
 * background round robin: about 65% of the time, and up to a tick more each period, since budgets are charged at
 * ticks (knowledge/design/scheduling.md §2). So more than half, and the other isn't starved: up to 90%.
 *
 * It stays in the kernel, since CPU budgets aren't objects a program can make yet; the other user-mode tests
 * are programs (src/tests, decisions/0069).
 */

BUDGETS_TEST_TICKS : u64 : 50
BUDGETS_TEST_THREADS :: 2
// Where the test maps things in its threads' address space
TEST_CODE : u64 : 0x400000
TEST_COUNTERS : u64 : 0x600000
TEST_STACKS : u64 : 0x800000

USER_CODE :: arch_interface.Mapping.{protection = .ReadExecute, cache = .WriteBack, user = true, global = false}
USER_DATA :: arch_interface.Mapping.{protection = .ReadWrite, cache = .WriteBack, user = true, global = false}

BudgetsTest :: struct {
    threads : u64[BUDGETS_TEST_THREADS],
    budget : CpuTime,
}

/*
 * Runs in user mode: counts in its argument's page for good. Without a context or a stack check, it
 * needs nothing but its own code and that page, so it runs from the kernel image's frames.
 */
budget_counter #calling_convention(.c) #no_context :: fn(counter: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(counter, intrinsics.volatile_load_u64(counter) + 1)
    }
}

// Two threads in one address space, started: the first bound to a budget.
test_budgets :: fn(kernel: ptr[mut Kernel]) {
    test :: allocate_object[BudgetsTest](&kernel.frames) or_else out_of_memory(&kernel.options, "test_budgets: no memory")
    process := cast[ptr[mut Process]](0)
    match create_process(kernel, 0, 0) {
        case Ok(made) => process = made
        case Error(error) => {
            runtime.log_error("test_budgets: no process: %", error)
            return void
        }
    }
    space := cast[ptr[mut AddressSpace]](0)
    match create_address_space(kernel, cast[u64](process), 0) {
        case Ok(made) => space = made
        case Error(error) => {
            runtime.log_error("test_budgets: no address space: %", error)
            return void
        }
    }
    // budget_counter's page and the next, from the image's frames
    code :: cast[u64](budget_counter)
    page :: code & ~(frames.FRAME_SIZE - 1)
    physical :: kernel.image_physical + (page - kernel.image_base)
    if !mapped_for_test(kernel, space, TEST_CODE, physical, 2 * frames.FRAME_SIZE, USER_CODE) {
        return void
    }
    // 30 ms every 100 ms, at priority 10
    test.budget = make_budget(kernel, 10, 100_000_000, 30_000_000)
    for i in 0..<BUDGETS_TEST_THREADS {
        counter :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_budgets: no memory")
        stack :: frames.allocate_zeroed(&kernel.frames, 0) or_else out_of_memory(&kernel.options, "test_budgets: no memory")
        counter_address :: TEST_COUNTERS + cast[u64](i) * frames.FRAME_SIZE
        stack_address :: TEST_STACKS + cast[u64](i) * 2 * frames.FRAME_SIZE
        if !mapped_for_test(kernel, space, counter_address, cast[u64](counter), frames.FRAME_SIZE, USER_DATA)
            || !mapped_for_test(kernel, space, stack_address, cast[u64](stack), frames.FRAME_SIZE, USER_DATA) {
            return void
        }
        // As after a call: the return address's slot below a 16-byte boundary
        start :: arch_interface.UserStart.{
            instruction_pointer = cast[arch_interface.VirtualAddress](TEST_CODE + (code - page)),
            stack_pointer = cast[arch_interface.VirtualAddress](stack_address + frames.FRAME_SIZE - 8),
            argument = counter_address,
        }
        budget :: if i == 0 { cast[u64](&test.budget) } else { cast[u64](0) }
        match create_thread(kernel, cast[u64](process), space, &start, arch_interface.VectorConfig.{extended = false}, budget, 0) {
            case Ok(made) => test.threads[i] = cast[u64](made)
            case Error(error) => {
                runtime.log_error("test_budgets: no thread: %", error)
                return void
            }
        }
    }
    for thread in test.threads {
        start_thread(kernel, cast[ptr[mut Thread]](thread))
    }
    kernel.stop_after_ticks = BUDGETS_TEST_TICKS
    intrinsics.atomic_store_u64_release(&kernel.budgets_test, cast[u64](test))
}

mapped_for_test :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> bool {
    match map_user(kernel, space, address, physical, size, mapping) {
        case Ok => return true
        case Error(error) => {
            runtime.log_error("test_budgets: couldn't map %: %", cast[rawptr](address), error)
            return false
        }
    }
}

// At the boot CPU's last tick while test_budgets runs: how the time was shared.
budgets_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    address :: intrinsics.atomic_load_u64_acquire(&kernel.budgets_test)
    if address == 0 || tick != kernel.stop_after_ticks {
        return void
    }
    test :: cast[ptr[BudgetsTest]](address)
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
