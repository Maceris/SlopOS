/*
 * test_threads (decisions/0069, from the kernel's test of 0036): THREADS threads of the program's own count,
 * more than the CPUs it's booted with, so each is preempted. Each keeps a vector, its own pattern plus its
 * count, which it checks against its count as it goes: a mix-up of threads' vector states would change it.
 * Halfway through, the counts are noted; at the end every thread has to have counted more since, so each was
 * run again, and none saw its vector go wrong. Then the threads are closed, and their budget is back to nothing.
 */
package test_threads

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_threads"
THREADS :: 4
// Each thread's slot: its index plus one, its count, and whether its vector went wrong.
SLOT_INDEX :: 0
SLOT_COUNT :: 1
SLOT_WRONG :: 2
RUN_NANOSECONDS : u64 : 100_000_000
Lanes :: vector[u64, 2]

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

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?) -> int {
    block :: slop_os.startup_block()
    slots, error :: runtime.new_array(u64[4], THREADS)
    if error != null {
        return 100
    }
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    threads : slop_os.Thread[THREADS]
    for &slot, i in slots {
        intrinsics.volatile_store_u64(&slot^[SLOT_INDEX], cast[u64](i) + 1)
        if i < threads.count {
            threads[i] = test_kit.start_thread(budget, cast[u64](counter), cast[u64](slot)) or_return 102
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
    failed := 0
    for slot, i in slots {
        now :: intrinsics.volatile_load_u64(&slot[SLOT_COUNT])
        before :: if i < halfway.count { halfway[i] } else { cast[u64](0) }
        if now <= before || before == 0 {
            log_line.write(log, "%: thread % counted % by halfway, then %", NAME, i, before, now)
            failed = cast[int](i) + 1
        }
        if intrinsics.volatile_load_u64(&slot[SLOT_WRONG]) != 0 {
            log_line.write(log, "%: thread %'s vector didn't keep its value", NAME, i)
            failed = cast[int](i) + 11
        }
    }
    for thread in threads {
        _ = slop_os.handle_close(cast[slop_os.Handle](thread))
    }
    if failed != 0 {
        return failed
    }
    if !test_kit.wait_for_budget(budget, 0, 1_000_000_000) {
        log_line.write(log, "%: its budget still has % bytes charged", NAME, test_kit.used(budget))
        return 20
    }
    log_line.write(log, "%: % threads of its own, each preempted and run again, each with its own vector state", NAME, THREADS)
    return 0
}
