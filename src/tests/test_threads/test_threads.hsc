/**
 * test_threads (decisions/0069, from the kernel's test of 0036): THREADS threads of the program's own count,
 * more than the CPUs it's booted with, so each is preempted. Each keeps a vector, its own pattern plus its
 * count, which it checks against its count as it goes: a mix-up of threads' vector states would change it.
 * Halfway through, the counts are noted; at the end every thread has to have counted more since, so each was
 * run again, and none saw its vector go wrong. Then the threads are closed, and their budget is back to nothing.
 */
package test_threads

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_threads"
/** How many threads count: more than the CPUs the test is booted with, so each is preempted. */
THREADS :: 4
/** The word of a thread's slot holding its index plus one, which its pattern is made from. */
SLOT_INDEX :: 0
/** The word of a thread's slot holding its count. */
SLOT_COUNT :: 1
/** The word of a thread's slot set to 1 once its vector went wrong. */
SLOT_WRONG :: 2
/** How long the threads count before the counts are noted, and again after, in nanoseconds: 100 ms. */
RUN_NANOSECONDS : u64 : 100_000_000
/** The vector a thread keeps its pattern plus its count in, in both lanes. */
Lanes :: vector[u64, 2]

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/**
 * Count, for good, keeping a vector of the thread's pattern plus its count, and checking it each time.
 *
 * @param slot The thread's slot: its index plus one is read from SLOT_INDEX; its count is written to SLOT_COUNT, and
 *     SLOT_WRONG set if the vector is ever not what it should be.
 */
counter #calling_convention(.c) #no_context :: fn(slot: ptr[mut u64[4]]) #never_returns {
    pattern :: intrinsics.volatile_load_u64(&slot^[SLOT_INDEX]) * 0x0101010101010101
    lanes := intrinsics.splat[Lanes](pattern)
    count := cast[u64](0)
    loop {
        lanes = lanes + 1
        count += 1
        intrinsics.volatile_store_u64(&slot^[SLOT_COUNT], count)
        if lanes[0] != pattern + count || lanes[1] != pattern + count {
            intrinsics.volatile_store_u64(&slot^[SLOT_WRONG], 1)
        }
    }
}

/**
 * Check that threads of the program's own are each preempted and run again, each with its own vector state, and that
 * their budget comes back to nothing once they're closed.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the slots, the budget or a thread couldn't be made.
 */
threads_are_preempted_and_keep_their_vectors #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    slots, error :: runtime.new_array(u64[4], THREADS)
    testing.require(t, error == null, "the threads' slots are allocated")?
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the threads")?
    threads : slop_os.Thread[THREADS]
    for &slot, i in slots {
        intrinsics.volatile_store_u64(&slot^[SLOT_INDEX], cast[u64](i) + 1)
        if i < threads.count {
            threads[i] = testing.require_ok(t, test_kit.start_thread(budget, cast[u64](counter), cast[u64](slot)), "each thread starts")?
        }
    }
    test_kit.wait_nanoseconds(RUN_NANOSECONDS)
    halfway : u64[THREADS]
    for slot, i in slots {
        if i < halfway.count {
            halfway[i] = intrinsics.volatile_load_u64(&slot[SLOT_COUNT])
        }
    }
    test_kit.wait_nanoseconds(RUN_NANOSECONDS)
    // Each thread's, so a failure says which
    counted_on : bool[THREADS]
    kept_vector : bool[THREADS]
    for slot, i in slots {
        if i < THREADS {
            now :: intrinsics.volatile_load_u64(&slot[SLOT_COUNT])
            counted_on[i] = halfway[i] != 0 && now > halfway[i]
            kept_vector[i] = intrinsics.volatile_load_u64(&slot[SLOT_WRONG]) == 0
        }
    }
    for thread in threads {
        _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    }
    every :: bool.[true, true, true, true]
    testing.expect_eq(t, counted_on, every, "each thread counted by halfway and again after, so each was preempted and run again")
    testing.expect_eq(t, kept_vector, every, "no thread's vector state was mixed up with another's")
    testing.expect(t, test_kit.wait_for_budget(budget, 0, 1_000_000_000), "the budget is back to nothing once the threads are closed")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
