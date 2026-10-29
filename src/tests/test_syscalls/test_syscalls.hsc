/*
 * test_syscalls (decisions/0069, from the kernel's test of 0057): handles and the objects they reach.
 * - its address space's handle, a copy with fewer rights, and a copy asking for more (refused);
 * - closing a handle twice (the second time, it's no handle);
 * - a thread of its own, and a non-owning copy of its handle; a process, made and destroyed;
 * - once its thread has counted for a while, closing its owning handle destroys it, and the copy then
 *   reaches nothing (ObjectGone), and it counts no more;
 * - what the thread and the process charged their budget comes back.
 */
package test_syscalls

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

// How far its thread counts before it's destroyed.
COUNT_BEFORE_CLOSE : u64 : 100000
NAME :: "test_syscalls"

count_forever #calling_convention(.c) #no_context :: fn(counter: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(counter, intrinsics.volatile_load_u64(counter) + 1)
    }
}

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    counters, error :: runtime.new_array(u64, 1)
    if error != null || counters.count == 0 {
        return 100
    }
    counter :: &counters[0]
    // What it makes is charged to a budget of its own, which has to be back to nothing at the end
    budget :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    results : u64[16]
    space :: cast[slop_os.Handle](block.space)
    info :: slop_os.handle_info(space)
    results[0] = test_kit.tag_of(info)
    found :: info or_else slop_os.HandleInfo.{}
    results[1] = cast[u64](cast[u8](found.kind))
    results[2] = cast[u64](cast[u32](found.rights))
    copy :: slop_os.handle_duplicate(space, slop_os.RIGHT_DUPLICATE)
    results[3] = test_kit.tag_of(copy)
    copied :: copy or_else slop_os.NO_HANDLE
    copied_info :: slop_os.handle_info(copied) or_else slop_os.HandleInfo.{}
    results[4] = cast[u64](cast[u32](copied_info.rights))
    more :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    results[5] = test_kit.tag_of(slop_os.handle_duplicate(copied, more))
    results[6] = test_kit.tag_of(slop_os.handle_close(copied))
    results[7] = test_kit.tag_of(slop_os.handle_close(copied))
    // A thread of its own, a copy of its handle, and a process, made and closed
    thread :: test_kit.start_thread(budget, cast[u64](count_forever), cast[u64](counter))
    results[8] = test_kit.tag_of(thread)
    made :: cast[slop_os.Handle](thread or_else test_kit.handle_at[slop_os.Thread](0))
    watch :: slop_os.handle_duplicate(made, slop_os.RIGHT_DUPLICATE)
    results[9] = test_kit.tag_of(watch)
    child :: slop_os.process_create(budget)
    results[10] = test_kit.tag_of(child)
    results[11] = test_kit.tag_of(slop_os.handle_close(cast[slop_os.Handle](child or_else test_kit.handle_at[slop_os.Process](0))))
    // Once it's counted a while, destroyed: the copy reaches nothing, and the count stands still
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(counter) < COUNT_BEFORE_CLOSE
    results[12] = test_kit.tag_of(slop_os.handle_close(made))
    results[13] = test_kit.tag_of(slop_os.handle_info(watch or_else slop_os.NO_HANDLE))
    stopped :: intrinsics.volatile_load_u64(counter)
    test_kit.wait_nanoseconds(50_000_000)
    results[14] = if intrinsics.volatile_load_u64(counter) == stopped { cast[u64](1) } else { cast[u64](0) }
    _ = slop_os.handle_close(watch or_else slop_os.NO_HANDLE)
    // What the thread and the process charged comes back, after a grace period
    results[15] = if test_kit.wait_for_budget(budget, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    expected :: u64.[
        0, cast[u64](cast[u8](slop_os.ObjectKind.AddressSpace)), cast[u64](cast[u32](slop_os.RIGHTS_ALL)),
        0, cast[u64](cast[u32](slop_os.RIGHT_DUPLICATE)), test_kit.tag(slop_os.HandleError.MissingRight),
        0, test_kit.tag(slop_os.HandleError.InvalidHandle),
        0, 0, 0, 0,
        0, test_kit.tag(slop_os.HandleError.ObjectGone), 1, 1,
    ]
    failed :: test_kit.check(log, NAME, results, expected)
    if failed == 0 {
        log_line.write(log, "%: handles were looked up, copied, refused, closed and went stale; threads and processes made and destroyed", NAME)
    }
    return failed
}
