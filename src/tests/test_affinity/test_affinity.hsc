/**
 * test_affinity (decisions/0099): on 2 CPUs, a copy of the program spinning on a budget of one and a half CPUs at
 * priority 20, kept to CPU 0, where it never runs out of time; and another counting on a budget at priority 10, also
 * kept to CPU 0 (cpu_budget_set_cpus). The counter can't run there under the spinner, and CPU 1, idle, doesn't take
 * it, as it may not run there: so it hardly counts. Its budget moved to CPU 1, it counts. A budget's CPUs are refused
 * when there are none, or none online, or they aren't within its parent's or over its children's; and a child starts
 * with its parent's.
 */
package test_affinity

import intrinsics from "base"
import runtime from "base"
import os from "std"
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

/**
 * Check that a CPU budget's threads run only on its CPUs, and which CPU sets cpu_budget_set_cpus refuses; or, run as
 * a copy, count.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param platform Not used.
 * @param test_device For a copy, the page it counts in; not used by the test itself. A copy without it ends with 1.
 * @param firmware Not used.
 * @param manager The process manager, which launches the copies; without it the test ends with 101.
 * @param program The test's own module, which the copies are launched from; without it the test ends with 102.
 * @param peer Given only to a copy, by the test that launched it: the channel its slot comes on. With it, this is a
 *     copy, which counts until it's killed.
 * @param cpu_budget The root CPU budget, split for the copies' budgets; without it the test ends with 100.
 * @return 0 if every check passed. Otherwise the first that failed: 1 if keeping the counter's budget to CPU 0, or
 *     2 moving it to CPU 1, failed; 3 if the counter didn't count at least ten times as much on CPU 1 as kept to CPU
 *     0 under the spinner, or the spinner didn't spin; 4 if the budget's CPUs aren't then CPU 1's; 5 if no CPUs, or 6
 *     only CPUs that aren't online, weren't refused with InvalidArgument; 7 if a child budget didn't start with its
 *     parent's CPUs; 8 if a child's CPUs outside its parent's, or 9 a parent's CPUs not over its child's, weren't
 *     refused with BudgetExceeded. 103 to 109 if setting up failed: 103 the manager's port, 104 the memory budget,
 *     105 the CPU budgets, 106 the page, 107 launching a copy, 108 the port it sleeps on, 109 the child budget. A
 *     copy ends only if it can't start counting: 2 if its port, 3 receiving its slot, 4 mapping the page failed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    match peer {
        case Some(end) => return run_copy(end, test_device or_return 1)
        case None => {}
    }
    block :: slop_os.startup_block()
    root :: cpu_budget or_return 100
    loader :: manager or_return 101
    executable :: program or_return 102
    manager_port :: os.port_for(block.budget, loader.end) or_return 103
    memory :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 104
    spinning :: slop_os.cpu_budget_create(root, memory, 20, 10 * MILLISECOND, 15 * MILLISECOND) or_return 105
    budget :: slop_os.cpu_budget_create(root, memory, 10, 10 * MILLISECOND, 4 * MILLISECOND) or_return 105
    slop_os.cpu_budget_set_cpus(spinning, CPU_0) or_return 105
    results : u64[9]
    results[0] = test_kit.tag_of(slop_os.cpu_budget_set_cpus(budget, CPU_0))
    counts :: slop_os.memory_create(block.budget, PAGE) or_return 106
    counts_at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 106
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(counts, block.space, counts_at, 0, PAGE, read_write) or_return 106
    spinner :: launch_copy(log, loader, manager_port, executable, counts, spinning, SLOT_SPINNER) or_return 107
    copy :: launch_copy(log, loader, manager_port, executable, counts, budget, SLOT_COUNTER) or_return 107
    sleeper :: slop_os.port_create(block.budget) or_return 108

    // Kept to CPU 0 under the spinner, then on CPU 1
    pause(sleeper, SETTLE_NANOSECONDS)
    kept :: counted(sleeper, counts_at)
    results[1] = test_kit.tag_of(slop_os.cpu_budget_set_cpus(budget, CPU_1))
    pause(sleeper, SETTLE_NANOSECONDS)
    moved :: counted(sleeper, counts_at)
    spun :: slot(counts_at, SLOT_SPINNER)
    _ = slop_os.process_kill(copy)
    _ = slop_os.process_kill(spinner)
    results[2] = if spun > 0 && moved > 0 && kept * 10 < moved { cast[u64](1) } else { cast[u64](0) }
    results[3] = (slop_os.cpu_budget_describe(budget) or_else slop_os.CpuBudgetInfo.{}).cpus

    // Refused: none, none online; a child starts with its parent's, and is within it, and its parent over it
    results[4] = test_kit.tag_of(slop_os.cpu_budget_set_cpus(budget, 0))
    results[5] = test_kit.tag_of(slop_os.cpu_budget_set_cpus(budget, cast[u64](1) << 40))
    child :: slop_os.cpu_budget_create(budget, memory, 5, 10 * MILLISECOND, MILLISECOND) or_return 109
    results[6] = (slop_os.cpu_budget_describe(child) or_else slop_os.CpuBudgetInfo.{}).cpus
    results[7] = test_kit.tag_of(slop_os.cpu_budget_set_cpus(child, CPU_0))
    results[8] = test_kit.tag_of(slop_os.cpu_budget_set_cpus(budget, CPU_0))
    log_line.write(log, "%: the counter counted % kept to CPU 0, % on CPU 1", NAME, kept, moved)
    expected :: u64.[0, 0, 1, CPU_1, test_kit.tag(slop_os.HandleError.InvalidArgument), test_kit.tag(slop_os.HandleError.InvalidArgument),
        CPU_1, test_kit.tag(slop_os.HandleError.BudgetExceeded), test_kit.tag(slop_os.HandleError.BudgetExceeded)]
    failed := test_kit.check(log, NAME, results, expected)
    if failed != 0 {
        return failed
    }
    log_line.write(log, "%: its budget's threads ran only on its CPUs, and CPUs outside its parent's or under its children's were refused", NAME)
    return 0
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
