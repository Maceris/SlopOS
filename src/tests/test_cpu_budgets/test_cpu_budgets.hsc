/**
 * test_cpu_budgets (roadmap 9a, decisions/0093): CPU budgets as objects, from the root budget the root task gives it.
 * - the root budget is every CPU's whole time at the top priority, with nothing split off it yet;
 * - a child splits its share off the root's; one past the root's share, one above its parent's priority and one with a
 *   period of 0 are refused;
 * - a grandchild splits off the child; the child can't then be set below its grandchild's share, and can be set to
 *   another period and time, its share changing in its parent's count;
 * - setting the root, which its handle hasn't the right to, is refused;
 * - a process made here runs on the child, and is put on the root, with the grandchild, once the child is destroyed;
 *   destroying the grandchild gives the root its whole time back;
 * - what the budgets charged their memory budget comes back.
 */
package test_cpu_budgets

import compiler from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_cpu_budgets"
/** A millisecond, in nanoseconds, for budgets' periods and times. */
MILLISECOND : u64 : 1_000_000

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
    /** The root CPU budget, which may be split but not set; none if main wasn't given it. */
    cpu_budget : slop_os.CpuBudget?,
}


/**
 * Check that the root budget is every CPU's whole time at the top priority, with nothing split off it yet.
 *
 * Shares are in millionths of a CPU: a time of 5 ms every 10 ms is 500,000.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the root budget, or it couldn't be described.
 */
the_root_budget_is_every_cpu_s_whole_time #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    root :: testing.require_some(t, given.cpu_budget, "the root task grants the root CPU budget")?
    whole :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    testing.expect_eq(t, whole.priority, 255, "the root budget has the top priority, which every other is under")
    // Its CPUs are any there may be, but its share counts those online, which the test isn't told
    testing.expect_eq(t, whole.share % 1_000_000, 0, "the root budget's share is the whole of each CPU it has")
    testing.expect_ge(t, whole.share, 1_000_000, "the root budget has at least the boot CPU's whole time")
    testing.expect_eq(t, whole.children_share, 0, "nothing has been split off the root budget before the test")
    return .Ok
}

/**
 * Check that budgets split off their parents' shares and are refused past them, above their parents' priorities, or
 * with no period; that a budget can't be set below what its children have, but can to another period and time, its
 * share changing in its parent's count; that the root can't be set; that what ran on a destroyed budget goes to its
 * parent, and the root has its whole time back once every budget split off it is gone; and that what the budgets
 * charged their memory budget comes back.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the root budget, or the memory budget, the child or the
 *     process couldn't be made, or the root couldn't be described.
 */
budgets_split_off_their_parents_and_give_back_on_going #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    root :: testing.require_some(t, given.cpu_budget, "the root task grants the root CPU budget")?
    memory :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a memory budget for the CPU budgets")?
    whole :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    // A child, and what's refused
    child_budget :: testing.require_ok(t, slop_os.cpu_budget_create(root, memory, 100, 10 * MILLISECOND, 5 * MILLISECOND), "a child of 5 ms every 10 ms fits in the root's share")?
    with_child :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    testing.expect_eq(t, with_child.children_share, 500_000, "the child's half a CPU is split off the root's share")
    too_much :: slop_os.cpu_budget_create(root, memory, 100, 10 * MILLISECOND, (whole.share / 1_000_000 + 1) * 10 * MILLISECOND)
    testing.expect_error(t, too_much, slop_os.HandleError.BudgetExceeded, "a child can't have more than its parent's whole share")
    too_high :: slop_os.cpu_budget_create(child_budget, memory, 200, 10 * MILLISECOND, MILLISECOND)
    testing.expect_error(t, too_high, slop_os.HandleError.BudgetExceeded, "a child's priority can't be above its parent's")
    no_period :: slop_os.cpu_budget_create(root, memory, 100, 0, MILLISECOND)
    testing.expect_error(t, no_period, slop_os.HandleError.InvalidArgument, "a budget's period has to be more than 0")
    // A grandchild, and the child set around it
    grandchild :: slop_os.cpu_budget_create(child_budget, memory, 50, 10 * MILLISECOND, 2 * MILLISECOND)
    testing.expect_ok(t, grandchild, "a grandchild of 2 ms every 10 ms fits in the child's share")
    below :: slop_os.cpu_budget_set(child_budget, 100, 10 * MILLISECOND, MILLISECOND)
    testing.expect_error(t, below, slop_os.HandleError.BudgetExceeded, "a budget can't be set below what its children have split off it")
    reset :: slop_os.cpu_budget_set(child_budget, 100, 20 * MILLISECOND, 8 * MILLISECOND)
    testing.expect_ok(t, reset, "a budget can be set to another period and time that still holds its children")
    with_reset :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    testing.expect_eq(t, with_reset.children_share, 400_000, "the child's new share, 8 ms every 20 ms, is what's split off the root")
    root_set :: slop_os.cpu_budget_set(root, 255, 10 * MILLISECOND, 10 * MILLISECOND)
    testing.expect_error(t, root_set, slop_os.HandleError.MissingRight, "the root budget's handle hasn't the right to set it")
    // A process on the child, which then goes, and the grandchild after it
    process :: testing.require_ok(t, slop_os.process_create(memory), "a process is made to run on the child")?
    put :: slop_os.process_set_cpu_budget(process, child_budget)
    testing.expect_ok(t, put, "a process can be put on a budget split off its parent's")
    _ = slop_os.handle_close(cast[slop_os.Handle](child_budget))
    test_kit.wait_nanoseconds(20 * MILLISECOND)
    without_child :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    testing.expect_eq(t, without_child.children_share, 200_000, "once the child is destroyed, its grandchild and process go to the root, with the grandchild's share")
    _ = slop_os.handle_close(cast[slop_os.Handle](grandchild or_else test_kit.handle_at[slop_os.CpuBudget](0)))
    _ = slop_os.handle_close(cast[slop_os.Handle](process))
    emptied :: testing.require_some(t, slop_os.cpu_budget_describe(root), "the root budget can be described")?
    testing.expect_eq(t, emptied.children_share, 0, "once the grandchild is destroyed too, the root has its whole time back")
    testing.expect(t, test_kit.wait_for_budget(memory, 0, 1_000_000_000), "what the budgets charged their memory budget is back to nothing once they're gone")
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
 * @param cpu_budget The root CPU budget, which may be split but not set; without it the tests fail.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log, cpu_budget = cpu_budget}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
