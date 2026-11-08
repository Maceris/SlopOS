package kernel

import intrinsics from "base"
import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Lockup detection (decisions/0183, 12a, design/lessons.md §6.2): each CPU's tick notes when it ticked, and checks
 * every other CPU did within LOCKUP_SECONDS, but those idle without ticking. One that didn't is stuck, as with
 * interrupts off in a loop: it's sent an NMI where the architecture has them (x86-64), which notes where it was, and
 * the kernel stops with Lockup, which the panic record keeps for the next boot.
 */

/** How long a CPU may go without ticking, while it isn't idle, before it's taken as stuck. */
LOCKUP_SECONDS : u64 : 5
/** How long the stuck CPU's NMI is waited for, in counter ticks per second's thousandths. */
NMI_WAIT_MILLISECONDS : u64 : 100
/** The tick test_lockup's CPU 1 stops at, spinning with interrupts off for good. */
TEST_LOCKUP_TICK : u64 : 50

/**
 * Note this CPU's tick, and check the others' (called at each tick, with interrupts off).
 *
 * @param kernel The kernel.
 * @param cpu The calling CPU.
 * @param now The counter now.
 */
check_lockups :: fn(kernel: ptr[mut Kernel], cpu: ptr[mut PerCpu], now: u64) {
    intrinsics.atomic_store_u64_release(&cpu.heartbeat, now)
    // test_lockup: the second CPU stops making progress, interrupts off
    if kernel.options.test_lockup && cpu.index == 1 && cpu.timer_ticks >= TEST_LOCKUP_TICK {
        runtime.log_info("test_lockup: CPU 1 spins with interrupts off")
        loop {
            arch.spin_hint()
        }
    }
    limit :: LOCKUP_SECONDS * kernel.counter_frequency
    per_cpus :: kernel.per_cpus
    for address, index in per_cpus {
        if index >= cast[usize](kernel.online_cpus) || cast[u32](index) == cpu.index || address == 0 {
            continue
        }
        other :: cast[ptr[mut PerCpu]](address)
        if intrinsics.atomic_load_u32_acquire(&other.tickless) != 0 {
            continue
        }
        beat :: intrinsics.atomic_load_u64_acquire(&other.heartbeat)
        if beat == 0 || beat > now || now - beat < limit {
            continue
        }
        // Only the first CPU to see it reports it
        _, claimed :: intrinsics.interlocked_compare_exchange_u32(&kernel.lockup, 1, 0)
        if !claimed {
            return void
        }
        report_lockup(kernel, other, now - beat)
    }
}

/**
 * Report a stuck CPU and stop the kernel with Lockup: where it was, if an NMI could ask it, logged.
 *
 * @param kernel The kernel.
 * @param stuck The stuck CPU.
 * @param since The counter ticks since it last ticked.
 */
report_lockup :: fn(kernel: ptr[mut Kernel], stuck: ptr[mut PerCpu], since: u64) #never_returns {
    seconds :: since / kernel.counter_frequency
    runtime.log_fatal("lockup: CPU % made no progress for % seconds", stuck.index, seconds)
    cpus :: kernel.cpus
    if cast[usize](stuck.index) < cpus.count && arch.send_nmi(cpus[stuck.index].hardware_id) {
        intrinsics.atomic_store_u32_release(&kernel.lockup_target, stuck.index + 1)
        deadline :: arch.counter() + NMI_WAIT_MILLISECONDS * kernel.counter_frequency / 1000
        loop {
            arch.spin_hint()
        }
        while intrinsics.atomic_load_u32_acquire(&stuck.lockup_seen) == 0 && arch.counter() < deadline
        if intrinsics.atomic_load_u32_acquire(&stuck.lockup_seen) != 0 {
            pc :: stuck.lockup_pc
            base :: kernel.image_base
            if pc >= base {
                runtime.log_fatal("lockup: CPU % was at kernel+%{#x}", stuck.index, pc - base)
            }
            else {
                runtime.log_fatal("lockup: CPU % was at %{#018x}", stuck.index, pc)
            }
        }
    }
    stop(.Lockup)
}

/**
 * Note where this CPU was when an NMI interrupted it, if it's the CPU a lockup's report asked (kernel_entry.nmi).
 *
 * Takes no lock and logs nothing: the CPU may hold any lock.
 *
 * @param kernel The kernel.
 * @param cpu The calling CPU.
 * @param pc The interrupted program counter.
 */
note_lockup :: fn(kernel: ptr[Kernel], cpu: ptr[mut PerCpu], pc: u64) {
    if intrinsics.atomic_load_u32_acquire(&kernel.lockup_target) != cpu.index + 1 {
        return void
    }
    cpu.lockup_pc = pc
    intrinsics.atomic_store_u32_release(&cpu.lockup_seen, 1)
}
