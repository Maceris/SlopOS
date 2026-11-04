/**
 * test_budgets (decisions/0099, from the kernel's test of 0050): on 1 CPU, a pair of threads sharing a CPU budget of
 * 30 ms every 100 ms at priority 10, against a thread on a budget of 60 ms every 100 ms at priority 5, each counting
 * as fast as it can. The program launches two copies of itself for them, since a budget is a process's: P, whose two
 * threads are the pair, and Q, whose one is the rival; it gives each its budget, and a page they count in. Then it
 * sleeps, and reads the counts.
 *
 * The pair runs its 30 ms at priority 10, above the rival, then the rival its 60 ms, then all three share what's left,
 * round robin, until the pair's budget comes back at the next period: so the pair counts about a third of the counts,
 * between 20% and 55% allowing for ticks, since budgets are charged at ticks; and the two of it about alike, as one
 * that waited while their budget was spent is moved up when it comes back (scheduler.hsc, relevel), rather than
 * waiting behind the other.
 *
 * The counts stand for CPU time only if every counter counts at the same rate, so all three are threads started at
 * counter, running the same instructions at the same address, and each copy's own thread sleeps (decisions/0173):
 * under an emulator, how fast a loop runs depends on where it is, and a main thread calling counter could run a copy
 * of it inlined elsewhere.
 */
package test_budgets

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_budgets"
/** A millisecond, in nanoseconds, for budgets' periods and times. */
MILLISECOND : u64 : 1_000_000
/** How long the copies count before the test reads the counts, in nanoseconds: 1 s, ten of the budgets' periods. */
RUN_NANOSECONDS : u64 : 1_000_000_000
/** Each copy's memory budget, in bytes: 4 MiB. */
COPY_BUDGET : u64 : 4 << 20
/** The size of the page the copies count in, in bytes. */
PAGE : u64 : 4096
/** The slot, a u64 of the page by index, the pair's first thread counts in. */
SLOT_FIRST :: 0
/** The slot the pair's second thread counts in. */
SLOT_SECOND :: 1
/** The slot the rival counts in. */
SLOT_RIVAL :: 2
/** What P is told in its first message: start the pair's two threads. */
ROLE_PAIR : u64 : 1
/** What Q is told in its first message: start the rival's one thread. */
ROLE_RIVAL : u64 : 2

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
    /** The copy's end of a channel to the test, whose first message says its role. */
    peer : slop_os.Channel?,
    /** Not given: the copy's CPU budget is bound by its launch instead. */
    cpu_budget : slop_os.CpuBudget?,
}

/**
 * Count in a slot of the page, for good, as fast as the thread's budget lets it.
 *
 * @param slot The slot, a u64 in the shared page, which only this thread writes; it wraps after 2^64 counts.
 */
counter #calling_convention(.c) #no_context :: fn(slot: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(slot, intrinsics.volatile_load_u64(slot) + 1)
    }
}

/**
 * Check that a CPU budget's threads run its time at its priority, and share it alike; or, run as a copy, count.
 *
 * @param log The debug log, writable, where the test says what it found and which check failed.
 * @param platform Not used.
 * @param test_device For a copy, the page it counts in; not used by the test itself. A copy without it ends with 1.
 * @param firmware Not used.
 * @param manager The process manager, which launches the copies; without it the test ends with 101.
 * @param program The test's own module, which the copies are launched from; without it the test ends with 102.
 * @param peer Given only to a copy, by the test that launched it: the channel its role comes on. With it, this is a
 *     copy, which counts until it's killed.
 * @param cpu_budget The root CPU budget, split for the copies' budgets; without it the test ends with 100.
 * @return 0 if both checks passed; 1 if the pair's share of the counts was outside 20 to 55 percent; 2 if the first
 *     of the pair's share of theirs was outside 35 to 65 percent. 103 to 110 if setting up failed: 103 the manager's
 *     port, 104 the memory budget, 105 the pair's CPU budget, 106 the rival's, 107 the page, 108 launching P, 109
 *     launching Q, 110 the port it sleeps on. A copy ends only if it can't start counting: 2 if its port, 3 receiving
 *     its role, 4 mapping the page, 5 its threads' memory budget, 6 starting a thread, 7 the port it sleeps on failed.
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
    pair_budget :: slop_os.cpu_budget_create(root, memory, 10, 100 * MILLISECOND, 30 * MILLISECOND) or_return 105
    rival_budget :: slop_os.cpu_budget_create(root, memory, 5, 100 * MILLISECOND, 60 * MILLISECOND) or_return 106
    counts :: slop_os.memory_create(block.budget, PAGE) or_return 107
    counts_at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 107
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(counts, block.space, counts_at, 0, PAGE, read_write) or_return 107
    pair :: launch_copy(log, loader, manager_port, executable, counts, pair_budget, ROLE_PAIR) or_return 108
    rival :: launch_copy(log, loader, manager_port, executable, counts, rival_budget, ROLE_RIVAL) or_return 109
    // Asleep while they count, so this, on the root budget, takes none of the CPU
    sleeper :: slop_os.port_create(block.budget) or_return 110
    packets : slop_os.Packet[1]
    _ = slop_os.port_wait(sleeper, packets, (slop_os.clock_monotonic() or_else 0) + RUN_NANOSECONDS)
    first :: intrinsics.volatile_load_u64(cast[ptr[u64]](counts_at + SLOT_FIRST * 8))
    second :: intrinsics.volatile_load_u64(cast[ptr[u64]](counts_at + SLOT_SECOND * 8))
    other :: intrinsics.volatile_load_u64(cast[ptr[u64]](counts_at + SLOT_RIVAL * 8))
    _ = slop_os.process_kill(pair)
    _ = slop_os.process_kill(rival)
    budgeted :: first + second
    total :: budgeted + other
    share :: if total > 0 { budgeted * 100 / total } else { cast[u64](0) }
    split :: if budgeted > 0 { first * 100 / budgeted } else { cast[u64](0) }
    log_line.write(log, "%: the pair counted % percent of the counts, the first % percent of theirs", NAME, share, split)
    if share < 20 || share > 55 {
        log_line.write(log, "%: % percent is outside 20 to 55", NAME, share)
        return 1
    }
    if split < 35 || split > 65 {
        log_line.write(log, "%: the first's % percent of the pair's counts is outside 35 to 65", NAME, split)
        return 2
    }
    log_line.write(log, "%: the pair had its budget at its priority, and shared it alike, the rival the rest", NAME)
    return 0
}

/**
 * Launch a copy of the test on a CPU budget, given the page to count in, and tell it its role.
 *
 * @param log The test's debug log, duplicated for the copy.
 * @param manager The process manager connection the copy is launched through.
 * @param manager_port The test's port for the manager connection.
 * @param program The test's own module, which the copy runs.
 * @param counts The page the copies count in, duplicated for the copy, readable and writable.
 * @param budget The CPU budget the copy's threads run on, which stays the test's; the copy is given a handle that
 *     can only bind it.
 * @param role ROLE_PAIR or ROLE_RIVAL, sent on the copy's channel.
 * @return An owning handle to the copy's process, which the test kills; or null if any step failed, leaving behind
 *     whatever it had made.
 */
launch_copy :: fn(log: slop_os.DebugLog, manager: os.Channel[process_manager.ProcessManager], manager_port: slop_os.Port,
    program: slop_os.Memory, counts: slop_os.Memory, budget: slop_os.CpuBudget, role: u64) -> slop_os.Process? {
    block :: slop_os.startup_block()
    pair :: slop_os.channel_create(block.budget, 0, 0) or_return null
    log_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_DEBUG_LOG_WRITE) | cast[u32](slop_os.RIGHT_DUPLICATE) | cast[u32](slop_os.RIGHT_TRANSFER))
    log_copy :: cast[slop_os.DebugLog](slop_os.handle_duplicate(cast[slop_os.Handle](log), log_rights) or_return null)
    page_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_MEMORY_WRITE) | cast[u32](slop_os.RIGHT_TRANSFER))
    page :: cast[slop_os.Memory](slop_os.handle_duplicate(cast[slop_os.Handle](counts), page_rights) or_return null)
    // A handle that may only bind, which the launch closes; the budget stays this program's
    bind_rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND) | cast[u32](slop_os.RIGHT_TRANSFER))
    binding :: cast[slop_os.CpuBudget](slop_os.handle_duplicate(cast[slop_os.Handle](budget), bind_rights) or_return null)
    launched :: os.launch(manager, manager_port, "test_budgets copy", program, COPY_BUDGET, main,
        CopyGrants.{log = log_copy, test_device = page, peer = pair.b}, os.LaunchOptions.{cpu_budget = binding}) or_return null
    port :: os.port_for(block.budget, pair.a) or_return null
    told := role
    none : slop_os.Handle[1]
    if os.send(pair.a, port, os.bytes_of(&told), view_of(&none[0], 0)) is_some {
        return null
    }
    return launched.process
}

/**
 * Run as P or Q, as told in the first message on peer: start the pair's two threads, or the rival's one, counting in
 * the page given, then sleep until killed.
 *
 * @param peer The copy's end of the channel to the test.
 * @param counts The page to count in.
 * @return 2 if no port could be made for peer, 3 if the role couldn't be received, 4 if the page couldn't be mapped,
 *     5 if the threads' memory budget couldn't be made, 6 if a thread couldn't be started, 7 if the port to sleep on
 *     couldn't be made; it doesn't return otherwise.
 */
run_copy :: fn(peer: slop_os.Channel, counts: slop_os.Memory) -> int {
    block :: slop_os.startup_block()
    port :: os.port_for(block.budget, peer) or_return 2
    role : u64 = 0
    none : slop_os.Handle[1]
    _ = os.receive(peer, port, os.mut_bytes_of(&role), none) or_return 3
    at :: runtime.reserve_addresses(cast[usize](PAGE)) or_return 4
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(counts, block.space, at, 0, PAGE, read_write) or_return 4
    threads :: slop_os.memory_budget_create(block.budget, 1 << 20) or_return 5
    // Every counter a thread started at counter, not this one calling it, which could count with a copy inlined elsewhere
    if role == ROLE_PAIR {
        _ = test_kit.start_thread(threads, cast[u64](counter), at + SLOT_FIRST * 8) or_return 6
        _ = test_kit.start_thread(threads, cast[u64](counter), at + SLOT_SECOND * 8) or_return 6
    }
    else {
        _ = test_kit.start_thread(threads, cast[u64](counter), at + SLOT_RIVAL * 8) or_return 6
    }
    // Asleep for good, so it takes none of its budget
    asleep :: slop_os.port_create(block.budget) or_return 7
    packets : slop_os.Packet[1]
    loop {
        _ = slop_os.port_wait(asleep, packets, slop_os.NO_DEADLINE)
    }
}
