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

/*
 * The kernel's lock order (decisions/0053, 0096, 0106), written once: a lock is taken only while every lock held is of
 * a lower rank, so no two CPUs can each wait for what the other holds. Locks of one rank are taken one at a time, or,
 * where two are needed, by address (lock_after). With robustness=on, lock_at checks the order and that interrupts are
 * off, as every lock here is taken with them off, and stops the kernel if either isn't so. The frame allocator's, the
 * slab caches' and the architectures' locks are leaves, taking nothing (a slab's, then the frame allocator's), and are
 * outside the table.
 */
LockRank :: enum #backed_by(u32) {
    // A device's, then the kernel's devices_lock and interrupts_lock, then the IOMMUs' (devices.hsc, iommus.hsc)
    Device = 10,
    // An intercept's, then a thread's control lock, then a port's (intercepts.hsc)
    Intercept = 20,
    // A channel core's, then a port's, then a run queue's (channels.hsc)
    ChannelCore = 30,
    // An IRQ's, then a port's (irqs.hsc)
    Irq = 40,
    // A memory's (its windows' parent first), then a space's (memory.hsc)
    MemoryParent = 50,
    Memory = 60,
    // A thread's control lock, then a run queue's (control.hsc)
    ThreadControl = 70,
    Space = 100,
    // A memory's pages, under its space's (paging.hsc)
    MemoryPages = 110,
    SpaceThreads = 120,
    HandleTable = 130,
    // The kernel's devices_lock, then a device's watchers, as a DMA fault is signalled (translation.hsc)
    Devices = 140,
    // A process's or a device's watchers, then the ports they signal
    Watchers = 145,
    // After a space's: a user fault on paged memory signals its pager's port (paging.hsc), with the space held
    Port = 148,
    Interrupts = 150,
    Wired = 160,
    Iommus = 170,
    Iommu = 180,
    CpuBudgets = 190,
    // A run queue's, then a CpuTime's, whose time the scheduler checks as it picks (scheduler.hsc, pick)
    RunQueue = 200,
    CpuTime = 210,
    Threads = 220,
    // The kernel's budgets_lock, then a memory budget's (its parent's, then its own, by address)
    Budgets = 230,
    MemoryBudget = 240,
    Timers = 250,
    PageTable = 260,
    Window = 270,
    Tags = 280,
    ObjectList = 290,
    Console = 300,
}

// Take spin_lock, of rank: checked, with robustness=on, against what this CPU holds.
lock_at :: fn(spin_lock: ptr[mut concurrency.SpinLock], rank: LockRank) {
    #if robustness.ON {
        match held_ranks() {
            case Some(held) => {
                check_interrupts(rank)
                if !concurrency.lock_ranked(spin_lock, cast[u32](rank), held) {
                    lock_order_broken(rank, "taken after a higher rank")
                }
            }
            case None => concurrency.lock(spin_lock)
        }
    }
    #else {
        concurrency.lock(spin_lock)
    }
}

// Take spin_lock, of rank, which may be the rank of the last lock taken, if it's at a higher address.
lock_after :: fn(spin_lock: ptr[mut concurrency.SpinLock], rank: LockRank) {
    #if robustness.ON {
        match held_ranks() {
            case Some(held) => {
                check_interrupts(rank)
                if !concurrency.lock_ranked_after(spin_lock, cast[u32](rank), held) {
                    lock_order_broken(rank, "taken after a higher rank, or one of its own at a higher address")
                }
            }
            case None => concurrency.lock(spin_lock)
        }
    }
    #else {
        concurrency.lock(spin_lock)
    }
}

// Give back spin_lock, of rank, which lock_at or lock_after took.
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

// This CPU's held ranks, once it has its state and isn't already reporting a broken order.
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

check_interrupts :: fn(rank: LockRank) {
    if arch.interrupts_enabled() {
        lock_order_broken(rank, "taken with interrupts on")
    }
}

// A broken lock order, said with where from, and the kernel stopped: the checks stop for the report's own locks.
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
