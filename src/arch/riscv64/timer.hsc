package arch_riscv64

import riscv64 from "base:intrinsics/riscv64"

/*
 * The timer (decisions/0199, R4): Sstc's stimecmp, the supervisor's own compare, which raises the timer interrupt once
 * the time CSR reaches it, at the device tree's timebase-frequency.
 *
 * SPEC: The RISC-V Instruction Set Manual, Volume II: Privileged Architecture, the Sstc extension (stimecmp).
 */

/** stimecmp's value for no deadline: the time CSR never reaches it. */
NO_DEADLINE : u64 : 0xffffffffffffffff

/**
 * Start the calling hart's timer (arch_interface.init_timer): its compare at NO_DEADLINE, its interrupt enabled in sie
 * already by init_cpu.
 *
 * @param hint The counter's frequency in Hz if L2 knows it, which wins; null to take the device tree's.
 * @return The time CSR's frequency in Hz: the hint, or the device tree's timebase-frequency, 0 if neither says.
 */
init_timer :: fn(hint : u64?) -> u64 {
    riscv64.csrw(.STIMECMP, NO_DEADLINE)
    return hint or_else current_system().timebase
}

/**
 * Raise a timer interrupt on the calling hart once the time CSR reaches a value (arch_interface.set_deadline).
 *
 * @param value The time to fire at; one already past fires at once.
 */
set_deadline :: fn(value : u64) {
    cpu :: current_cpu()
    cpu.deadline = value
    write_compare(cpu)
}

/** Cancel the calling hart's deadline (arch_interface.cancel_deadline): only the test device's is left in stimecmp. */
cancel_deadline :: fn() {
    cpu :: current_cpu()
    cpu.deadline = NO_DEADLINE
    write_compare(cpu)
}

/** How often the test device's line is pended while it's on, in Hz. */
TEST_DEVICE_HZ : u64 : 100

/**
 * Set stimecmp to the earlier of the hart's two deadlines, the kernel's and the test device's.
 *
 * @param cpu The calling hart's.
 */
write_compare :: fn(cpu : ptr[ArchCpu]) {
    riscv64.csrw(.STIMECMP, if cpu.deadline < cpu.test_deadline { cpu.deadline } else { cpu.test_deadline })
}

/**
 * Take a timer interrupt (interrupt_source): pend the test device's line if its deadline came, and say whether the
 * kernel's did. A deadline that came is moved on, the test device's by a period while it's on and this is the hart that
 * started it, the kernel's to NO_DEADLINE, and stimecmp is set to the earlier of what's left.
 *
 * @param cpu The calling hart's.
 * @param system The shared state, with the test device's.
 * @return True if the kernel's deadline came; false if only the test device's did.
 */
take_timer :: fn(cpu : ptr[mut ArchCpu], system : ptr[ArchSystem]) -> bool {
    now :: riscv64.csrr(.TIME)
    if cpu.test_deadline <= now {
        cpu.test_deadline = NO_DEADLINE
        if system.test_interrupts && system.test_hart == cpu.hart_id {
            arm_test_line(cpu, system, now)
        }
    }
    came :: cpu.deadline <= now
    if came {
        cpu.deadline = NO_DEADLINE
    }
    write_compare(cpu)
    return came
}

/**
 * Pend the test device's line now, and set the hart's test_deadline a period on, for TEST_DEVICE_HZ a second; with no
 * timebase known, it stays as it was, so the line is pended only now.
 *
 * @param cpu The calling hart's, the one the test device was started on.
 * @param system The shared state, with the timebase.
 * @param now The time CSR's value now.
 */
arm_test_line :: fn(cpu : ptr[mut ArchCpu], system : ptr[ArchSystem], now : u64) {
    pend_test_line(system)
    period :: system.timebase / TEST_DEVICE_HZ
    if period != 0 {
        cpu.test_deadline = now + period
    }
}

/**
 * Wait for an interrupt with interrupts enabled (arch_interface.idle).
 *
 * The interrupt enters kernel_entry.interrupt from Idle on the kernel stack's top: an interrupt in supervisor mode is
 * moved there by the trap entry's sret (entries.hsc), so the frames of this wait are left behind. This never returns.
 */
idle :: fn() #never_returns {
    _ = riscv64.csrrs(.SSTATUS, riscv64.SSTATUS_SIE)
    loop {
        riscv64.wfi()
    }
}
