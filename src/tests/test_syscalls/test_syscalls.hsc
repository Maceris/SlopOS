/**
 * test_syscalls (decisions/0069, from the kernel's test of 0057): handles and the objects they reach.
 * - its address space's handle, a copy with fewer rights, and a copy asking for more (refused);
 * - closing a handle twice (the second time, it's no handle);
 * - a thread of its own, and a non-owning copy of its handle; a process, made and destroyed;
 * - once its thread has counted for a while, closing its owning handle destroys it, and the copy then
 *   reaches nothing (ObjectGone), and it counts no more;
 * - what the thread and the process charged their budget comes back.
 */
package test_syscalls

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** How far its thread counts before it's destroyed. */
COUNT_BEFORE_CLOSE : u64 : 100000
/** The test's name, which starts each line it logs. */
NAME :: "test_syscalls"

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/**
 * Count, for good, until the thread is destroyed.
 *
 * @param counter The count, which only this thread writes; it wraps after 2^64 counts.
 */
count_forever #calling_convention(.c) #no_context :: fn(counter: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(counter, intrinsics.volatile_load_u64(counter) + 1)
    }
}

/**
 * Check that the process's handle to its own address space is an AddressSpace's, with every right.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the handle couldn't be looked up.
 */
its_address_space_handle_has_every_right #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    info :: testing.require_ok(t, slop_os.handle_info(cast[slop_os.Handle](block.space)), "the startup block's address space handle is one the process holds")?
    testing.expect_eq(t, info.kind, slop_os.ObjectKind.AddressSpace, "the startup block's space handle reaches the process's address space")
    testing.expect_eq(t, info.rights, slop_os.RIGHTS_ALL, "the process's own address space handle is given with every right")
    return .Ok
}

/**
 * Check that a copy of a handle has only the rights asked for, that a copy of it can't ask for more, and that it closes
 * once, after which it's no handle.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the copy couldn't be made.
 */
a_copy_has_only_the_rights_asked_for_and_closes_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    space :: cast[slop_os.Handle](block.space)
    copied :: testing.require_ok(t, slop_os.handle_duplicate(space, slop_os.RIGHT_DUPLICATE), "a handle with RIGHT_DUPLICATE can be copied with fewer rights")?
    copied_info :: slop_os.handle_info(copied) or_else slop_os.HandleInfo.{}
    testing.expect_eq(t, copied_info.rights, slop_os.RIGHT_DUPLICATE, "a copy has just the rights it was asked for")
    more :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    widened :: slop_os.handle_duplicate(copied, more)
    testing.expect_error(t, widened, slop_os.HandleError.MissingRight, "a copy can't ask for a right its source doesn't have")
    closed :: slop_os.handle_close(copied)
    testing.expect_ok(t, closed, "the copy closes")
    closed_again :: slop_os.handle_close(copied)
    testing.expect_error(t, closed_again, slop_os.HandleError.InvalidHandle, "a closed handle is no handle, so closing it again is refused")
    return .Ok
}

/**
 * Check that a thread and a process of the program's own are made and destroyed by closing their owning handles; that
 * a non-owning copy of the thread's handle then reaches nothing, and the thread counts no more; and that what they
 * charged their budget comes back to nothing.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if the count's memory, the budget or the thread couldn't be made.
 */
closing_an_owning_handle_destroys_its_object #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    block :: slop_os.startup_block()
    counters, error :: runtime.new_array(u64, 1)
    if error != null || counters.count == 0 {
        testing.fail(t, "the thread's count is allocated")
        return .Error(.Failed)
    }
    counter :: &counters[0]
    // What it makes is charged to a budget of its own, which has to be back to nothing at the end
    budget :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a budget for the thread and the process")?
    thread :: testing.require_ok(t, test_kit.start_thread(budget, cast[u64](count_forever), cast[u64](counter)), "a thread of the program's own starts")?
    made :: cast[slop_os.Handle](thread)
    watch :: slop_os.handle_duplicate(made, slop_os.RIGHT_DUPLICATE)
    testing.expect_ok(t, watch, "the thread's handle is copied, the copy not owning it")
    child :: slop_os.process_create(budget)
    testing.expect_ok(t, child, "a process is made under the budget")
    child_closed :: slop_os.handle_close(cast[slop_os.Handle](child or_else test_kit.handle_at[slop_os.Process](0)))
    testing.expect_ok(t, child_closed, "the process's owning handle closes, destroying it")
    // Once it's counted a while, destroyed: the copy reaches nothing, and the count stands still
    loop {
        intrinsics.spin_hint()
    }
    while intrinsics.volatile_load_u64(counter) < COUNT_BEFORE_CLOSE
    thread_closed :: slop_os.handle_close(made)
    testing.expect_ok(t, thread_closed, "the thread's owning handle closes, destroying it")
    stale :: slop_os.handle_info(watch or_else slop_os.NO_HANDLE)
    testing.expect_error(t, stale, slop_os.HandleError.ObjectGone, "a non-owning copy reaches nothing once the owning handle has destroyed its thread")
    stopped :: intrinsics.volatile_load_u64(counter)
    test_kit.wait_nanoseconds(50_000_000)
    testing.expect_eq(t, intrinsics.volatile_load_u64(counter), stopped, "a destroyed thread is never run again, so its count stands still")
    _ = slop_os.handle_close(watch or_else slop_os.NO_HANDLE)
    // What the thread and the process charged comes back, after a grace period
    testing.expect(t, test_kit.wait_for_budget(budget, 0, 1_000_000_000), "the budget is back to nothing once the thread and the process are destroyed")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * Every test's entry has this type (system_config checks it), so the root task can launch any of them alike.
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
