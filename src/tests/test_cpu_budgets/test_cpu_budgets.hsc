/*
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

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_cpu_budgets"
MILLISECOND : u64 : 1_000_000

main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    block :: slop_os.startup_block()
    root :: cpu_budget or_return 100
    memory :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 101
    results : u64[17]
    whole :: slop_os.cpu_budget_describe(root) or_return 102
    results[0] = whole.priority
    results[1] = whole.share
    results[2] = whole.children_share
    // A child, and what's refused
    child :: slop_os.cpu_budget_create(root, memory, 100, 10 * MILLISECOND, 5 * MILLISECOND)
    results[3] = test_kit.tag_of(child)
    child_budget :: child or_else test_kit.handle_at[slop_os.CpuBudget](0)
    results[4] = (slop_os.cpu_budget_describe(root) or_return 103).children_share
    results[5] = test_kit.tag_of(slop_os.cpu_budget_create(root, memory, 100, 10 * MILLISECOND, (whole.share / 1_000_000 + 1) * 10 * MILLISECOND))
    results[6] = test_kit.tag_of(slop_os.cpu_budget_create(child_budget, memory, 200, 10 * MILLISECOND, MILLISECOND))
    results[7] = test_kit.tag_of(slop_os.cpu_budget_create(root, memory, 100, 0, MILLISECOND))
    // A grandchild, and the child set around it
    grandchild :: slop_os.cpu_budget_create(child_budget, memory, 50, 10 * MILLISECOND, 2 * MILLISECOND)
    results[8] = test_kit.tag_of(grandchild)
    results[9] = test_kit.tag_of(slop_os.cpu_budget_set(child_budget, 100, 10 * MILLISECOND, MILLISECOND))
    results[10] = test_kit.tag_of(slop_os.cpu_budget_set(child_budget, 100, 20 * MILLISECOND, 8 * MILLISECOND))
    results[11] = (slop_os.cpu_budget_describe(root) or_return 104).children_share
    results[12] = test_kit.tag_of(slop_os.cpu_budget_set(root, 255, 10 * MILLISECOND, 10 * MILLISECOND))
    // A process on the child, which then goes, and the grandchild after it
    process :: slop_os.process_create(memory) or_return 107
    results[13] = test_kit.tag_of(slop_os.process_set_cpu_budget(process, child_budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](child_budget))
    test_kit.wait_nanoseconds(20 * MILLISECOND)
    results[14] = (slop_os.cpu_budget_describe(root) or_return 105).children_share
    _ = slop_os.handle_close(cast[slop_os.Handle](grandchild or_else test_kit.handle_at[slop_os.CpuBudget](0)))
    _ = slop_os.handle_close(cast[slop_os.Handle](process))
    results[15] = (slop_os.cpu_budget_describe(root) or_return 106).children_share
    results[16] = if test_kit.wait_for_budget(memory, 0, 1_000_000_000) { cast[u64](1) } else { cast[u64](0) }
    expected :: u64.[
        255, whole.share, 0,
        0, 500_000, test_kit.tag(slop_os.HandleError.BudgetExceeded), test_kit.tag(slop_os.HandleError.BudgetExceeded),
        test_kit.tag(slop_os.HandleError.InvalidArgument),
        0, test_kit.tag(slop_os.HandleError.BudgetExceeded), 0, 400_000, test_kit.tag(slop_os.HandleError.MissingRight),
        0, 200_000, 0, 1,
    ]
    failed :: test_kit.check(log, NAME, results, expected)
    if failed == 0 {
        log_line.write(log, "%: budgets split off the root's share and refused past it, set, and destroyed, what ran on them going to their parent", NAME)
    }
    return failed
}
