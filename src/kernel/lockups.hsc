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
 * interrupts off in a loop: it's sent an NMI (x86-64's, or AArch64's pseudo-NMI through the GIC's priorities, decisions/
 * 0185), which notes where it was, its registers, and its stack as its frame pointers chain it; and the kernel stops
 * with Lockup, the report logged as fatal, which the panic record keeps for the next boot.
 */

/** How long a CPU may go without ticking, while it isn't idle, before it's taken as stuck. */
LOCKUP_SECONDS : u64 : 5
/** How long the stuck CPU's NMI is waited for, in counter ticks per second's thousandths. */
NMI_WAIT_MILLISECONDS : u64 : 100
/** The tick test_lockup's CPU 1 stops at, spinning with interrupts off for good. */
TEST_LOCKUP_TICK : u64 : 50
/** The most registers a lockup's NMI keeps: AArch64's x0 to x30, sp, pc and pstate. */
LOCKUP_REGISTERS :: 34
/** The most return addresses a lockup's NMI keeps from the stuck CPU's stack. */
LOCKUP_FRAMES :: 16
/** How many registers a line of a lockup's report shows. */
REGISTERS_PER_LINE :: 4

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
            report_registers(stuck)
            report_stack(kernel, stuck)
        }
    }
    stop(.Lockup)
}

/**
 * Log a stuck CPU's registers, as its NMI kept them, REGISTERS_PER_LINE to a fatal line.
 *
 * @param stuck The stuck CPU, whose lockup_seen is set.
 */
report_registers :: fn(stuck: ptr[PerCpu]) {
    runtime.log_fatal("lockup: CPU %'s registers:", stuck.index)
    count :: cast[usize](stuck.lockup_register_count)
    registers :: stuck.lockup_registers
    for first in 0..<registers.count {
        if first % REGISTERS_PER_LINE != 0 || first >= count {
            continue
        }
        // As many of this line's as there are: up to REGISTERS_PER_LINE, each a name and a value
        left :: count - first
        names : string[REGISTERS_PER_LINE]
        values : u64[REGISTERS_PER_LINE]
        for j in cast[usize](0)..<REGISTERS_PER_LINE {
            at :: first + j
            if at < count && at < registers.count {
                names[j] = arch.nmi_register_name(at)
                values[j] = registers[at]
            }
        }
        if left >= 4 {
            write_log_line("fatal", null, "  % %{#018x}  % %{#018x}  % %{#018x}  % %{#018x}", names[0], values[0], names[1], values[1],
                names[2], values[2], names[3], values[3])
        }
        else if left == 3 {
            write_log_line("fatal", null, "  % %{#018x}  % %{#018x}  % %{#018x}", names[0], values[0], names[1], values[1], names[2],
                values[2])
        }
        else if left == 2 {
            write_log_line("fatal", null, "  % %{#018x}  % %{#018x}", names[0], values[0], names[1], values[1])
        }
        else {
            write_log_line("fatal", null, "  % %{#018x}", names[0], values[0])
        }
    }
}

/**
 * Log a stuck CPU's stack, the return addresses its NMI found, a fatal line each, as kernel+offset where they're the
 * kernel's.
 *
 * @param kernel The kernel, whose image base the addresses are made relative to.
 * @param stuck The stuck CPU, whose lockup_seen is set.
 */
report_stack :: fn(kernel: ptr[Kernel], stuck: ptr[PerCpu]) {
    runtime.log_fatal("lockup: CPU %'s stack:", stuck.index)
    base :: kernel.image_base
    for address, i in stuck.lockup_frames {
        if i >= cast[usize](stuck.lockup_frame_count) {
            break
        }
        if address >= base {
            write_log_line("fatal", null, "  at kernel+%{#x}", address - base)
        }
        else {
            write_log_line("fatal", null, "  at %{#018x}", address)
        }
    }
}

/**
 * Note where this CPU was when an NMI interrupted it, its registers and its stack, if it's the CPU a lockup's report
 * asked (kernel_entry.nmi).
 *
 * The stack is walked through frame pointers, each a saved frame pointer then a return address, only within this CPU's
 * kernel stack, each further up than the last, so a broken chain ends the walk rather than faulting. Takes no lock
 * and logs nothing: the CPU may hold any lock.
 *
 * @param kernel The kernel.
 * @param cpu The calling CPU.
 * @param pc The interrupted program counter.
 * @param frame_pointer The interrupted code's frame pointer.
 * @param registers The interrupted code's registers; the first LOCKUP_REGISTERS are kept.
 */
note_lockup :: fn(kernel: ptr[Kernel], cpu: ptr[mut PerCpu], pc: u64, frame_pointer: u64, registers: u64[]) {
    if intrinsics.atomic_load_u32_acquire(&kernel.lockup_target) != cpu.index + 1 {
        return void
    }
    cpu.lockup_pc = pc
    kept := cast[u32](0)
    for value, i in registers {
        if i >= cpu.lockup_registers.count {
            break
        }
        cpu.lockup_registers[i] = value
        kept += 1
    }
    cpu.lockup_register_count = kept
    low :: cast[u64](cpu.stacks.kernel.low)
    high :: cast[u64](cpu.stacks.kernel.high)
    frames := cast[u32](0)
    frame := frame_pointer
    for i in 0..<cpu.lockup_frames.count {
        if frame < low || frame > high - 16 || frame & 7 != 0 {
            break
        }
        record :: cast[ptr[u64[2]]](cast[rawptr](frame))
        return_address :: intrinsics.volatile_load_u64(&record^[1])
        if return_address == 0 {
            break
        }
        cpu.lockup_frames[i] = return_address
        frames += 1
        next :: intrinsics.volatile_load_u64(&record^[0])
        if next <= frame {
            break
        }
        frame = next
    }
    cpu.lockup_frame_count = frames
    intrinsics.atomic_store_u32_release(&cpu.lockup_seen, 1)
}
