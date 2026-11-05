/**
 * test_affinity (decisions/0099): on 2 CPUs, a copy of the program spinning on a budget of one and a half CPUs at
 * priority 20, kept to CPU 0, where it never runs out of time; and another counting on a budget at priority 10, also
 * kept to CPU 0 (cpu_budget_set_cpus). The counter can't run there under the spinner, and CPU 1, idle, doesn't take
 * it, as it may not run there: so it hardly counts. Its budget moved to CPU 1, it counts. A budget's CPUs are refused
 * when there are none, or none online, or they aren't within its parent's or over its children's; and a child starts
 * with its parent's.
 */
package test_affinity

import compiler from "base"
import intrinsics from "base"
import runtime from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_affinity"
/** A millisecond, in nanoseconds, for budgets' periods and times. */
MILLISECOND : u64 : 1_000_000
/** How long the counter is watched counting, each time, in nanoseconds: 300 ms. */
RUN_NANOSECONDS : u64 : 300_000_000
/** How long the test waits before each watch, for the copies to settle where they're kept, in nanoseconds: 50 ms. */
SETTLE_NANOSECONDS : u64 : 50_000_000
/** Each copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 << 20
/** The size of the page the copies count in, in bytes. */
PAGE : u64 : 4096
/** The CPU set of CPU 0 alone, as cpu_budget_set_cpus takes it: a bit for each CPU. */
CPU_0 : u64 : 1
/** The CPU set of CPU 1 alone. */
CPU_1 : u64 : 2
/** The spinner's slot in the page, a u64 it counts in, by index. */
SLOT_SPINNER : u64 : 0
/** The counter's slot in the page, a u64 it counts in, by index. */
SLOT_COUNTER : u64 : 1

/** What a copy is launched with, as main takes it: the same entry, a copy's grants. */
CopyGrants :: struct {
    /** A copy of the test's debug log, writable. */
    log : slop_os.DebugLog,
    /** Not given. */
    platform : slop_os.Platform?,
    /** The page to count in, readable and writable; the copy's entry takes it in test_device's place. */
    test_device : slop_os.Memory?,
    /** Not given. */
    firmware : slop_os.Memory?,
    /** Not given. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** Not given. */
    program : slop_os.Memory?,
    /** The copy's end of a channel to the test, whose first message says which slot it counts in. */
    peer : slop_os.Channel?,
    /** Not given: the copy's CPU budget is bound by its launch instead. */
    cpu_budget : slop_os.CpuBudget?,
}

/**
 * Count in a slot of the page, for good, as fast as the CPU the copy runs on lets it.
 *
 * @param slot The slot, a u64 in the shared page, which only this thread writes; it wraps after 2^64 counts.
 */
counter #calling_convention(.c) #no_context :: fn(slot: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(slot, intrinsics.volatile_load_u64(slot) + 1)
    }
}

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log, which the counter's counts are logged to. */
    log : slop_os.DebugLog,
    /** The process manager, which launches the copies; none if main wasn't given it. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** The test's own module, which the copies are launched from; none if main wasn't given it. */
    program : slop_os.Memory?,
    /** The root CPU budget, split for the copies' budgets; none if main wasn't given it. */
    cpu_budget : slop_os.CpuBudget?,
}

/**
 * Check that a CPU budget's threads run only on its CPUs: a counter kept to CPU 0 under a spinner there hardly counts,
 * as CPU 1, idle, may not take it, and moved to CPU 1, it counts at least ten times as much. The counts are logged, as
 * "the counter counted % kept to CPU 0, % on CPU 1".
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the root budget, the process manager or its module, or the
 *     manager's port, the memory budget, a CPU budget, the page, a copy or the port it sleeps on couldn't be made.
 */
threads_run_only_on_their_budget_cpus #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    root :: testing.require_some(t, given.cpu_budget, "the root task grants the root CPU budget")?
    loader :: testing.require_some(t, given.manager, "the root task grants the process manager")?
    executable :: testing.require_some(t, given.program, "the root task grants the program's own module")?
    manager_port :: testing.require_some(t, os.port_for(block.budget, loader.end), "a port for the process manager's replies")?
    memory :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a memory budget for the CPU budgets")?
    spinning :: testing.require_ok(t, slop_os.cpu_budget_create(root, memory, 20, 10 * MILLISECOND, 15 * MILLISECOND), "the spinner's budget, one and a half CPUs at priority 20")?
    budget :: testing.require_ok(t, slop_os.cpu_budget_create(root, memory, 10, 10 * MILLISECOND, 4 * MILLISECOND), "the counter's budget, at priority 10")?
    testing.require_ok(t, slop_os.cpu_budget_set_cpus(spinning, CPU_0), "the spinner's budget is kept to CPU 0")?
    kept_to_0 :: slop_os.cpu_budget_set_cpus(budget, CPU_0)
    testing.expect_ok(t, kept_to_0, "a budget can be kept to an online CPU within its parent's")
    counts :: testing.require_ok(t, slop_os.memory_create(block.budget, PAGE), "the page the copies count in")?
    counts_at :: testing.require_some(t, runtime.reserve_addresses(cast[usize](PAGE)), "addresses to map the page at")?
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    testing.require_ok(t, slop_os.memory_map(counts, block.space, counts_at, 0, PAGE, read_write), "the page is mapped to read the counts")?
    spinner :: testing.require_some(t, launch_copy(given.log, loader, manager_port, executable, counts, spinning, SLOT_SPINNER), "the spinner's copy is launched on its budget")?
    copy :: testing.require_some(t, launch_copy(given.log, loader, manager_port, executable, counts, budget, SLOT_COUNTER), "the counter's copy is launched on its budget")?
    sleeper :: testing.require_ok(t, slop_os.port_create(block.budget), "a port to sleep on")?
    // Kept to CPU 0 under the spinner, then on CPU 1
    pause(sleeper, SETTLE_NANOSECONDS)
    kept :: counted(sleeper, counts_at)
    moved_to_1 :: slop_os.cpu_budget_set_cpus(budget, CPU_1)
    testing.expect_ok(t, moved_to_1, "a budget with threads running on it can be moved to another CPU")
    pause(sleeper, SETTLE_NANOSECONDS)
    moved :: counted(sleeper, counts_at)
    spun :: slot(counts_at, SLOT_SPINNER)
    _ = slop_os.process_kill(copy)
    _ = slop_os.process_kill(spinner)
    log_line.write(given.log, "%: the counter counted % kept to CPU 0, % on CPU 1", NAME, kept, moved)
    testing.expect(t, spun > 0, "the spinner ran on CPU 0, where its budget keeps it")
    testing.expect(t, moved > 0 && kept * 10 < moved, "kept to CPU 0 under the spinner, the counter hardly counts, as idle CPU 1 may not take it; moved there, it counts ten times as much")
    testing.expect_eq(t, (slop_os.cpu_budget_describe(budget) or_else slop_os.CpuBudgetInfo.{}).cpus, CPU_1, "a budget's CPUs are those it was last set to")
    // Their shares back to the root, for the tests after
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    _ = slop_os.handle_close(cast[slop_os.Handle](spinning))
    return .Ok
}

/**
 * Check which CPU sets cpu_budget_set_cpus refuses: none, or none online; a child's outside its parent's; and a
 * parent's not over its child's. And that a child starts with its parent's CPUs.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if main wasn't given the root budget, or the memory budget, the budget or its child
 *     couldn't be made, or the budget couldn't be kept to CPU 1.
 */
cpu_sets_empty_offline_or_outside_the_parent_are_refused #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    given :: test_kit.given(t, Given)?
    block :: slop_os.startup_block()
    root :: testing.require_some(t, given.cpu_budget, "the root task grants the root CPU budget")?
    memory :: testing.require_ok(t, slop_os.memory_budget_create(block.budget, 1 << 20), "a memory budget for the CPU budgets")?
    budget :: testing.require_ok(t, slop_os.cpu_budget_create(root, memory, 10, 10 * MILLISECOND, 4 * MILLISECOND), "a budget at priority 10")?
    testing.require_ok(t, slop_os.cpu_budget_set_cpus(budget, CPU_1), "the budget is kept to CPU 1")?
    // Refused: none, none online; a child starts with its parent's, and is within it, and its parent over it
    none :: slop_os.cpu_budget_set_cpus(budget, 0)
    testing.expect_error(t, none, slop_os.HandleError.InvalidArgument, "a budget has to have a CPU to run on")
    offline :: slop_os.cpu_budget_set_cpus(budget, cast[u64](1) << 40)
    testing.expect_error(t, offline, slop_os.HandleError.InvalidArgument, "a budget has to have an online CPU, and CPU 40 isn't one on 2 CPUs")
    child :: testing.require_ok(t, slop_os.cpu_budget_create(budget, memory, 5, 10 * MILLISECOND, MILLISECOND), "a child of the budget")?
    testing.expect_eq(t, (slop_os.cpu_budget_describe(child) or_else slop_os.CpuBudgetInfo.{}).cpus, CPU_1, "a child starts with its parent's CPUs")
    outside :: slop_os.cpu_budget_set_cpus(child, CPU_0)
    testing.expect_error(t, outside, slop_os.HandleError.BudgetExceeded, "a child's CPUs have to be within its parent's")
    under :: slop_os.cpu_budget_set_cpus(budget, CPU_0)
    testing.expect_error(t, under, slop_os.HandleError.BudgetExceeded, "a parent's CPUs have to stay over its children's")
    _ = slop_os.handle_close(cast[slop_os.Handle](child))
    _ = slop_os.handle_close(cast[slop_os.Handle](budget))
    return .Ok
}

/**
 * Run the tests, reporting to the debug log; or, run as a copy, count.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device For a copy, the page it counts in; not used by the test itself. A copy without it ends with 1.
 * @param firmware Not used.
 * @param manager The process manager, which launches the copies; without it the test fails.
 * @param program The test's own module, which the copies are launched from; without it the test fails.
 * @param peer Given only to a copy, by the test that launched it: the channel its slot comes on. With it, this is a
 *     copy, which counts until it's killed.
 * @param cpu_budget The root CPU budget, split for the copies' budgets; without it the tests fail.
 * @return How many tests failed: 0 when every one passed. A copy ends only if it can't start counting: with 1 if it
 *     wasn't given the page, otherwise what run_copy gives.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(end) => return run_copy(end, test_device or_return 1)
        case None => {}
    }
    given :: Given.{log = log, manager = manager, program = program, cpu_budget = cpu_budget}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}

/**
 * Watch how much the counter counts while the test sleeps RUN_NANOSECONDS.
 *
 * @param sleeper A port of the test's own, which nothing is bound to, slept on.
 * @param counts_at Where the test mapped the page the copies count in.
 * @return How much the counter's slot went up meanwhile.
 */
counted :: fn(sleeper: slop_os.Port, counts_at: u64) -> u64 {
    before :: slot(counts_at, SLOT_COUNTER)
    pause(sleeper, RUN_NANOSECONDS)
    return slot(counts_at, SLOT_COUNTER) - before
}

/**
 * Read a slot of the page the copies count in.
 *
 * @param counts_at Where the test mapped the page.
 * @param index Which slot, SLOT_SPINNER or SLOT_COUNTER.
 * @return What the slot holds now, read with a volatile load.
 */
slot :: fn(counts_at: u64, index: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](counts_at + index * 8))
}

/**
 * Sleep, on the test's own budget, taking none of the CPU, so it doesn't compete with the copies.
 *
 * @param sleeper A port nothing is bound to, so only the deadline wakes the wait.
 * @param nanoseconds How long to sleep, from now on the monotonic clock.
 */
pause :: fn(sleeper: slop_os.Port, nanoseconds: u64) {
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(sleeper, packets, (slop_os.clock_monotonic() or_else 0) + nanoseconds)
}

/**
 * Launch a copy of the test on a CPU budget, given the page to count in, and tell it its slot.
 *
 * @param log The test's debug log, duplicated for the copy.
 * @param manager The process manager connection the copy is launched through.
 * @param manager_port The test's port for the manager connection.
 * @param program The test's own module, which the copy runs.
 * @param counts The page the copies count in, duplicated for the copy, readable and writable.
 * @param budget The CPU budget the copy's threads run on, which stays the test's; the copy is given a handle that
 *     can only bind it.
 * @param which The copy's slot, SLOT_SPINNER or SLOT_COUNTER, sent on the copy's channel.
 * @return An owning handle to the copy's process, which the test kills; or null if any step failed, leaving behind
 *     whatever it had made.
 */
launch_copy :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager], manager_port: slop_os.Port,
    program: slop_os.Memory, counts: slop_os.Memory, budget: slop_os.CpuBudget, which: u64) -> slop_os.Process? {
    block :: slop_os.startup_block()
    pair :: slop_os.channel_create(block.budget, 0, 0) or_return null
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), log_rights) or_return null)
    page_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    page :: cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](counts), page_rights) or_return null)
    // A handle that may only bind, which the launch closes; the budget stays this program's
    bind_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND) | cast[u32](slop_os.RIGHT_TRANSFER))
    binding :: cast[slop_os.CpuBudget](slop_os.handle_duplicate(cast[slop_os.Handle](budget), bind_rights) or_return null)
    launched :: os.launch(manager, manager_port, "test_affinity copy", program, COPY_BUDGET, main,
        CopyGrants.{log = log_copy, test_device = page, peer = pair.b}, os.LaunchOptions.{cpu_budget = binding}) or_return null
    port :: os.port_for(block.budget, pair.a) or_return null
    told := which
    none : slop_os.Handle[1]
    if os.send(pair.a, port, os.bytes_of(&told), view_of(&none[0], 0)) is_some {
        return null
    }
    return launched.process
}

/**
 * Run as a copy: map the page, and count in the slot the first message on peer names, until killed.
 *
 * @param peer The copy's end of the channel to the test.
 * @param counts The page to count in.
 * @return 2 if no port could be made for peer, 3 if the slot couldn't be received, 4 if the page couldn't be mapped;
 *     it doesn't return otherwise.
 */
run_copy :: fn(peer: slop_os.Channel, counts: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    port :: os.port_for(block.budget, peer) or_return 2
    which : u64 = 0
    none : slop_os.Handle[1]
    _ = os.receive(peer, port, os.mut_bytes_of(&which), none) or_return 3
    at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 4
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(counts, block.space, at, 0, PAGE, read_write) or_return 4
    counter(cast[ptr[mut u64]](at + (which % 2) * 8))
}
