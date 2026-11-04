package arch_aarch64

import aarch64 from "base/intrinsics"

/*
 * The generic timer (docs/specs/arch_interface.md, Timer): the virtual counter, and the virtual timer's
 * one-shot deadline against it, raising its PPI. The frequency is the counter's own (CNTFRQ_EL0), which the
 * firmware sets; a hint isn't needed.
 */
//SPEC: Arm ARM (DDI 0487) D12 (the generic timer): CNTFRQ_EL0, CNTVCT_EL0, CNTV_CVAL_EL0, CNTV_CTL_EL0

/** CNTV_CTL_EL0 with ENABLE (bit 0) set and IMASK (bit 1) clear: the timer on, its interrupt not masked. */
TIMER_ENABLE : u64 : 1

/**
 * Stop the calling CPU's virtual timer until the first deadline, and give the counter's frequency
 * (arch_interface.init_timer).
 *
 * @param hint Ignored: CNTFRQ_EL0, which the firmware sets, is the frequency.
 * @return The counter's frequency in Hz, from CNTFRQ_EL0.
 */
init_timer :: fn(hint: u64?) -> u64 {
    aarch64.write_system_register(.CNTV_CTL_EL0, 0)
    return aarch64.read_system_register(.CNTFRQ_EL0)
}

/**
 * Read the virtual counter, which the timer counts with (arch_interface.counter).
 *
 * The isb keeps it from being read early, ahead of the code before it.
 *
 * @return CNTVCT_EL0, in ticks of init_timer's frequency; it only grows.
 */
counter :: fn() -> u64 {
    aarch64.isb()
    return aarch64.read_system_register(.CNTVCT_EL0)
}

/**
 * Raise the calling CPU's timer interrupt once counter() reaches value (arch_interface.set_deadline), replacing
 * any deadline set before.
 *
 * @param value The deadline, in counter() ticks; one that has passed already raises the interrupt at once.
 */
set_deadline :: fn(value: u64) {
    aarch64.write_system_register(.CNTV_CVAL_EL0, value)
    aarch64.write_system_register(.CNTV_CTL_EL0, TIMER_ENABLE)
    aarch64.isb()
}

/** Cancel the calling CPU's deadline, disabling its virtual timer (arch_interface.cancel_deadline). */
cancel_deadline :: fn() {
    aarch64.write_system_register(.CNTV_CTL_EL0, 0)
    aarch64.isb()
}
