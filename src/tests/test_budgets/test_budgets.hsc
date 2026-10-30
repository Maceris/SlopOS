/*
 * test_budgets (decisions/0099, from the kernel's test of 0050): on 1 CPU, a pair of threads sharing a CPU budget of
 * 30 ms every 100 ms at priority 10, against a thread on a budget of 60 ms every 100 ms at priority 5, each counting as fast
 * as it can. The program launches two copies of itself for them, since a budget is a process's: P, whose two threads
 * are the pair, and Q, whose one is the rival; it gives each its budget, and a page they count in. Then it sleeps,
 * and reads the counts.
 *
 * The pair runs its 30 ms at priority 10, above the rival, then the rival its 60 ms, then all three share what's left,
 * round robin, until the pair's budget comes back at the next period: so the pair counts about a third of the counts,
 * between 20% and 55% allowing for ticks, since budgets are
 * charged at ticks; and the two of it about alike, as one that waited while their budget was spent is moved up when it
 * comes back (scheduler.hsc, relevel), rather than waiting behind the other.
 */
package test_budgets

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import test_kit from "../../test_kit"

NAME :: "test_budgets"
MILLISECOND : u64 : 1_000_000
RUN_NANOSECONDS : u64 : 1_000_000_000
COPY_BUDGET : u64 : 4 << 20
PAGE : u64 : 4096
// The counts' slots in the page: the pair's two, and the rival's
SLOT_FIRST :: 0
SLOT_SECOND :: 1
SLOT_RIVAL :: 2
// What each copy is told, in its first message
ROLE_PAIR : u64 : 1
ROLE_RIVAL : u64 : 2

CopyGrants :: struct {
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    firmware : slop_os.Memory?,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    peer : slop_os.Channel?,
    cpu_budget : slop_os.CpuBudget?,
}

// Counts in its slot of the page for good.
counter #calling_convention(.c) #no_context :: fn(slot: ptr[mut u64]) #never_returns {
    loop {
        intrinsics.volatile_store_u64(slot, intrinsics.volatile_load_u64(slot) + 1)
    }
}

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

// A copy launched on budget, given the page to count in and told its role: its process.
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

// P or Q, as told in its first message: the pair's two threads, or the rival's one, counting in the page given.
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
    if role == ROLE_PAIR {
        _ = test_kit.start_thread(threads, cast[u64](counter), at + SLOT_SECOND * 8) or_return 6
        counter(cast[ptr[mut u64]](at + SLOT_FIRST * 8))
    }
    counter(cast[ptr[mut u64]](at + SLOT_RIVAL * 8))
}
