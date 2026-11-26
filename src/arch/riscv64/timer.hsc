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
    riscv64.csrw(.STIMECMP, value)
}

/** Cancel the calling hart's deadline (arch_interface.cancel_deadline): its compare at NO_DEADLINE. */
cancel_deadline :: fn() {
    riscv64.csrw(.STIMECMP, NO_DEADLINE)
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
