/*
 * test_memory (decisions/0069, from the kernel's test of 0054): memory budgets and memory objects, used by
 * the program's first thread, A, and a writer, B:
 * - A splits a child budget off its test budget, which can't pay for memory bigger than its limit, nor make
 *   memory of a size that isn't whole pages;
 * - A makes memory with the child, and maps it read/write; mapping it over itself, past its end, or
 *   writable and executable is refused;
 * - A touches each page, which reads as zeros, then holds what A wrote; mapped again read-only elsewhere,
 *   the same frames show what A wrote;
 * - B writes to the read-only mapping, and is stopped: its handle reaches nothing;
 * - A unmaps the second mapping (and can't again), then closes the child budget: the parent takes over
 *   what the child paid for and gets back the rest of its limit, and the memory is still there;
 * - once the memory is closed, the test budget is back to nothing.
 */
package test_memory

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_memory"
PAGE : u64 : 4096
MEMORY_SIZE : u64 : 32768
MEMORY_PAGES :: 8
TEST_LIMIT : u64 : 1 << 20
CHILD_LIMIT : u64 : 65536
// How long A gives B to be stopped.
STOP_NANOSECONDS : u64 : 20_000_000
// What A and B share, by its slots, and where B writes.
SHARED_B_STARTED :: 0
SHARED_B_AFTER :: 1
SHARED_TARGET :: 2

// B: writes where it may only read, which stops it.
writer #calling_convention(.c) #no_context :: fn(shared: ptr[mut u64[4]]) #never_returns {
    intrinsics.volatile_store_u64(&shared^[SHARED_B_STARTED], 1)
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](intrinsics.volatile_load_u64(&shared^[SHARED_TARGET])), 7)
    intrinsics.volatile_store_u64(&shared^[SHARED_B_AFTER], 1)
    slop_os.thread_exit()
}

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?) -> int {
    block :: slop_os.startup_block()
    space :: block.space
    pages, error :: runtime.new_array(u64[4], 1)
    if error != null || pages.count == 0 {
        return 100
    }
    shared :: &pages[0]
    at :: runtime.reserve_addresses(cast[usize](MEMORY_SIZE)) or_return 101
    again :: runtime.reserve_addresses(cast[usize](MEMORY_SIZE)) or_return 101
    intrinsics.volatile_store_u64(&shared^[SHARED_TARGET], again)
    budget :: slop_os.memory_budget_create(block.budget, TEST_LIMIT) or_return 102
    read :: slop_os.PROTECTION_READ
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    write_execute :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_WRITE) | cast[u32](slop_os.PROTECTION_EXECUTE))
    results : u64[20]
    given :: slop_os.memory_budget_info(budget)
    results[0] = test_kit.tag_of(given)
    given_info :: given or_else slop_os.BudgetInfo.{}
    results[1] = given_info.limit
    // A child budget, too small for some memory, and memory of no whole number of pages
    made_child :: slop_os.memory_budget_create(budget, CHILD_LIMIT)
    results[2] = test_kit.tag_of(made_child)
    child :: made_child or_else test_kit.handle_at[slop_os.MemoryBudget](0)
    fresh :: slop_os.memory_budget_info(child) or_else slop_os.BudgetInfo.{}
    results[3] = fresh.limit
    results[4] = fresh.used
    results[5] = test_kit.tag_of(slop_os.memory_create(child, 2 * CHILD_LIMIT))
    results[6] = test_kit.tag_of(slop_os.memory_create(child, 1000))
    made :: slop_os.memory_create(child, MEMORY_SIZE)
    results[7] = test_kit.tag_of(made)
    memory :: made or_else test_kit.handle_at[slop_os.Memory](0)
    // Mapped, then over itself, past its end, and writable and executable
    results[8] = test_kit.tag_of(slop_os.memory_map(memory, space, at, 0, MEMORY_SIZE, read_write))
    results[9] = test_kit.tag_of(slop_os.memory_map(memory, space, at + PAGE, 0, PAGE, read))
    results[10] = test_kit.tag_of(slop_os.memory_map(memory, space, again, PAGE, MEMORY_SIZE, read))
    results[11] = test_kit.tag_of(slop_os.memory_map(memory, space, again, 0, PAGE, write_execute))
    // Each page, untouched, reads as zeros, then holds what's written
    zeros := cast[u64](0)
    for i in 0..<MEMORY_PAGES {
        page :: at + cast[u64](i) * PAGE
        if intrinsics.volatile_load_u64(cast[ptr[u64]](page + 8)) == 0 {
            zeros += 1
        }
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](page), 1000 + cast[u64](i))
    }
    results[12] = zeros
    // The second page again, read-only, shows the same frame
    results[13] = test_kit.tag_of(slop_os.memory_map(memory, space, again, PAGE, PAGE, read))
    results[14] = intrinsics.volatile_load_u64(cast[ptr[u64]](again))
    // B writes to it, and is stopped
    started_writer :: test_kit.start_thread(budget, cast[u64](writer), cast[u64](shared))
    results[15] = test_kit.tag_of(started_writer)
    _ = test_kit.wait_for(&shared^[SHARED_B_STARTED], 1_000_000_000)
    test_kit.wait_nanoseconds(STOP_NANOSECONDS)
    results[16] = intrinsics.volatile_load_u64(&shared^[SHARED_B_AFTER])
    results[17] = test_kit.tag_of(slop_os.handle_info(cast[slop_os.Handle](started_writer or_else test_kit.handle_at[slop_os.Thread](0))))
    results[18] = test_kit.tag_of(slop_os.memory_unmap(space, again))
    results[19] = test_kit.tag_of(slop_os.memory_unmap(space, again))
    // Closing the child: the parent pays for the memory, and gets back the rest of the limit
    child_used :: test_kit.used(child)
    with_child :: test_kit.used(budget)
    closed_child :: test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](child)))
    after :: test_kit.used(budget)
    still_there :: intrinsics.volatile_load_u64(cast[ptr[u64]](at + 3 * PAGE))
    closed_memory :: test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](memory)))
    expected :: u64.[
        0, TEST_LIMIT,
        0, CHILD_LIMIT, 0,
        test_kit.tag(slop_os.MemoryError.BudgetExceeded), test_kit.tag(slop_os.MemoryError.InvalidSize), 0,
        0, test_kit.tag(slop_os.MemoryError.BadAddress), test_kit.tag(slop_os.MemoryError.InvalidSize),
        test_kit.tag(slop_os.MemoryError.BadProtection),
        MEMORY_PAGES, 0, 1001,
        0, 0, test_kit.tag(slop_os.HandleError.ObjectGone), 0, test_kit.tag(slop_os.MemoryError.NotMapped),
    ]
    failed := test_kit.check(log, NAME, results, expected)
    if failed != 0 {
        return failed
    }
    /*
     * The child paid for the memory, at least all of it; closing it gave the parent back the limit less that,
     * and the child's own slot too if its grace period is over already
     */
    if child_used < MEMORY_SIZE || child_used > CHILD_LIMIT || closed_child != 0 || with_child - after < CHILD_LIMIT - child_used
        || after < child_used
        || still_there != 1003 || closed_memory != 0 {
        log_line.write(log, "%: the child had % charged; closing it took the parent from % to %; the memory read % after", NAME,
            child_used, with_child, after, still_there)
        return 30
    }
    if !test_kit.wait_for_budget(budget, 0, 1_000_000_000) {
        log_line.write(log, "%: its budget still has % bytes charged", NAME, test_kit.used(budget))
        return 31
    }
    log_line.write(log, "%: budgets split and closed, memory filled as it was touched and shared between mappings, and a write it didn't allow stopped the thread", NAME)
    return 0
}
