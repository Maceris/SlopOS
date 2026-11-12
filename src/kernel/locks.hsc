package kernel

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import robustness from "../robustness"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/**
 * The kernel's lock order (decisions/0053, 0096, 0106), written once: a lock is taken only while every lock held is of
 * a lower rank, so no two CPUs can each wait for what the other holds. Locks of one rank are taken one at a time, or,
 * where two are needed, by address (lock_after). With robustness=on, lock_at checks the order and that interrupts are
 * off, as every lock here is taken with them off, and stops the kernel if either isn't so. The frame allocator's, the
 * slab caches' and the architectures' locks are leaves, taking nothing (a slab's, then the frame allocator's), and are
 * outside the table.
 *
 * A CPU waiting for a lock checks the others for lockups as it spins (lockups.hsc): with interrupts off, its own ticks
 * don't come, and a CPU stuck holding the lock would otherwise stop it too, with nothing left ticking to see either.
 */
LockRank :: enum #backed_by(u32) {
    /**
     * A device's lock, then the kernel's devices_lock and interrupts_lock, then the IOMMUs' (devices.hsc, iommus.hsc).
     */
    Device = 10,
    /** An intercept's lock, then a thread's control lock, then a port's (intercepts.hsc). */
    Intercept = 20,
    /** A channel core's lock, then a port's, then a run queue's (channels.hsc). */
    ChannelCore = 30,
    /** An IRQ's lock, then a port's (irqs.hsc). */
    Irq = 40,
    /** A memory's lock as a window's parent, taken before the window's own; then a space's (memory.hsc). */
    MemoryParent = 50,
    /** A memory's lock, which guards its lists of mappings and windows; then a space's (memory.hsc, paging.hsc). */
    Memory = 60,
    /** A thread's control lock, then a run queue's (control.hsc). */
    ThreadControl = 70,
    /** An address space's lock, which guards its page table and its mappings (spaces.hsc). */
    Space = 100,
    /** A memory's pages, under its space's lock (paging.hsc). */
    MemoryPages = 110,
    /** An address space's threads_lock, which guards the list of threads running in it (spaces.hsc). */
    SpaceThreads = 120,
    /** A process's handle table's lock (handles.hsc). */
    HandleTable = 130,
    /** The kernel's devices_lock, then a device's watchers, as a DMA fault is signalled (translation.hsc). */
    Devices = 140,
    /** A process's or a device's watchers, then the ports they signal. */
    Watchers = 145,
    /** A port's lock, taken after a space's: a user fault on paged memory signals its pager's port (paging.hsc). */
    Port = 148,
    /** The kernel's interrupts_lock, which guards the routes of device interrupts (interrupts.hsc). */
    Interrupts = 150,
    /** A wired interrupt controller's lock, which guards its lines (interrupts.hsc). */
    Wired = 160,
    /** The kernel's iommus_lock, which guards the list of IOMMUs registered (iommus.hsc, devices.hsc). */
    Iommus = 170,
    /** A registered IOMMU's lock, which guards its domains and tables (translation.hsc). */
    Iommu = 180,
    /** The kernel's cpu_budgets_lock, which guards the CPU budgets' tree and who runs on each (cpu_budgets.hsc). */
    CpuBudgets = 190,
    /** A run queue's lock, then a CpuTime's, whose time the scheduler checks as it picks (scheduler.hsc, pick). */
    RunQueue = 200,
    /** A CpuTime's lock, which guards what a budget has left and its refills (budgets.hsc). */
    CpuTime = 210,
    /** The kernel's threads_lock, which guards its list of every thread (control.hsc). */
    Threads = 220,
    /** The kernel's budgets_lock, then a memory budget's (its parent's, then its own, by address). */
    Budgets = 230,
    /** A memory budget's lock, which guards its charges (memory_budgets.hsc). */
    MemoryBudget = 240,
    /** A CPU's timer heap's lock (timers.hsc). */
    Timers = 250,
    /** The kernel's page_table_lock, which guards the kernel's own page table (address_space.hsc, window.hsc). */
    PageTable = 260,
    /** The kernel window's lock, which guards its free addresses (window.hsc). */
    Window = 270,
    /** The address-space tags' lock, which guards which tags are in use (spaces.hsc). */
    Tags = 280,
    /** A process's list of the objects it owns (objects.hsc). */
    ObjectList = 290,
    /** The kernel's console_lock, held while a line is written out (log.hsc). */
    Console = 300,
    /** A process's debug_lock, which guards its breakpoints and watchpoints (process_set_debug), taken returning to user. */
    ProcessDebug = 305,
    /** A CPU's trace ring's lock, taken in the scheduler's paths under any other (tracing.hsc). */
    Trace = 310,
    /** test_lockup_lock's lock, which CPU 1 holds as it stops and CPU 0 then waits for, at a tick (lockups.hsc). */
    LockupTest = 320,
}

/**
 * Take a spin lock of a rank, spinning until it's free.
 *
 * With robustness=on, once this CPU has its PerCpu, the lock is recorded in the CPU's held ranks, and the kernel stops
 * (lock_order_broken) if interrupts are on or the newest lock held isn't of a lower rank. Before the CPU has its
 * PerCpu, or while it's reporting a broken order, the lock is taken unchecked.
 *
 * @param spin_lock The lock, which stays held until unlock_at gives it back with the same rank.
 * @param rank The lock's rank in the kernel's order: above every rank this CPU holds.
 */
lock_at :: fn(spin_lock: ptr[mut concurrency.SpinLock], rank: LockRank) {
    #if robustness.ON {
        match held_ranks() {
            case Some(held) => {
                check_interrupts(rank)
                if !concurrency.lock_ranked(spin_lock, cast[u32](rank), held, watching()) {
                    lock_order_broken(rank, "taken after a higher rank")
                }
            }
            case None => concurrency.lock_waiting(spin_lock, watching())
        }
    }
    #else {
        concurrency.lock_waiting(spin_lock, watching())
    }
}

/**
 * Take a spin lock of a rank that may equal the newest rank held, for two locks of one kind taken by address.
 *
 * Checked as lock_at checks, except that a lock of the same rank as the newest held is in order when its address is
 * higher than that one's.
 *
 * @param spin_lock The lock, which stays held until unlock_at gives it back with the same rank.
 * @param rank The lock's rank: above every rank held, or equal to the newest's with spin_lock at a higher address.
 */
lock_after :: fn(spin_lock: ptr[mut concurrency.SpinLock], rank: LockRank) {
    #if robustness.ON {
        match held_ranks() {
            case Some(held) => {
                check_interrupts(rank)
                if !concurrency.lock_ranked_after(spin_lock, cast[u32](rank), held, watching()) {
                    lock_order_broken(rank, "taken after a higher rank, or one of its own at a higher address")
                }
            }
            case None => concurrency.lock_waiting(spin_lock, watching())
        }
    }
    #else {
        concurrency.lock_waiting(spin_lock, watching())
    }
}

/**
 * Give back a spin lock that lock_at or lock_after took.
 *
 * Locks needn't be given back in the order they were taken. With robustness=on, a lock the CPU's records don't show as
 * held stops the kernel (lock_order_broken).
 *
 * @param spin_lock The lock, held by this CPU.
 * @param rank The rank it was taken with.
 */
unlock_at :: fn(spin_lock: ptr[mut concurrency.SpinLock], rank: LockRank) {
    #if robustness.ON {
        match held_ranks() {
            case Some(held) => {
                if !concurrency.unlock_ranked(spin_lock, cast[u32](rank), held) {
                    lock_order_broken(rank, "given back, but not held")
                }
            }
            case None => concurrency.unlock(spin_lock)
        }
    }
    #else {
        concurrency.unlock(spin_lock)
    }
}

/** What a CPU does while it waits for a lock: check the others for lockups (check_lockups_while_locking). */
watching :: fn() -> concurrency.Waiting {
    return concurrency.Waiting.{call = check_lockups_while_locking, state = null}
}

/**
 * Find this CPU's record of the locks it holds, when lock checks apply.
 *
 * @return The calling CPU's PerCpu.held_ranks, good while it runs on this CPU; null before the CPU has its PerCpu
 *     (its carrier block's program_data is null), or while it's reporting a broken lock order, so the report's own
 *     locks aren't checked.
 */
held_ranks :: fn() -> ptr[mut concurrency.HeldRanks]? {
    if intrinsics.carrier().program_data == null {
        return null
    }
    cpu :: per_cpu()
    if cpu.reporting_locks {
        return null
    }
    return &cpu.held_ranks
}

/**
 * Stop the kernel if interrupts are on as a lock is taken: every kernel lock is taken with them off, so an interrupt
 * can't come in and wait for a lock its own CPU holds.
 *
 * @param rank The rank of the lock being taken, for the report.
 */
check_interrupts :: fn(rank: LockRank) {
    if arch.interrupts_enabled() {
        lock_order_broken(rank, "taken with interrupts on")
    }
}

/**
 * Report a broken lock order and stop the kernel.
 *
 * Logs the lock, every lock this CPU holds by rank and address, and a stack trace, then stops with AssertionFailed.
 * The CPU's reporting_locks is set first, so the locks the report itself takes aren't checked.
 *
 * @param rank The rank of the lock taken or given back out of order.
 * @param what What was wrong, as a phrase that follows "a <rank> lock", like "taken with interrupts on".
 */
lock_order_broken :: fn(rank: LockRank, what: string) #never_returns {
    cpu :: per_cpu()
    cpu.reporting_locks = true
    runtime.log_fatal("lock order: a % lock % on CPU % (decisions/0106)", rank, what, cpu.index)
    held :: &cpu.held_ranks
    for i in 0..<cast[usize](held.count) {
        if i < held.ranks.count && i < held.locks.count {
            runtime.log_fatal("lock order: holding a % lock at %{#x}", cast[LockRank](held.ranks[i]), held.locks[i])
        }
    }
    log_stack_trace(1)
    stop(.AssertionFailed)
}
