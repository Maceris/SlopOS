package arch_aarch64

import aarch64 from "base/intrinsics"

/*
 * The generic timer (docs/specs/arch_interface.md, Timer): the virtual counter, and the virtual timer's
 * one-shot deadline against it, raising its PPI. The frequency is the counter's own (CNTFRQ_EL0), which the
 * firmware sets; a hint isn't needed.
 */
//SPEC: Arm ARM (DDI 0487) D12 (the generic timer): CNTFRQ_EL0, CNTVCT_EL0, CNTV_CVAL_EL0, CNTV_CTL_EL0

// CNTV_CTL_EL0: the timer on, its interrupt not masked
TIMER_ENABLE : u64 : 1

// The counter's frequency, with the timer stopped until the first deadline.
init_timer :: fn(hint: u64?) -> u64 {
    aarch64.write_system_register(.CNTV_CTL_EL0, 0)
    return aarch64.read_system_register(.CNTFRQ_EL0)
}

// The virtual counter, which the timer counts with. The isb keeps it from being read early.
counter :: fn() -> u64 {
    aarch64.isb()
    return aarch64.read_system_register(.CNTVCT_EL0)
}

// Raise the timer's interrupt once counter() reaches value, which may have passed already.
set_deadline :: fn(value: u64) {
    aarch64.write_system_register(.CNTV_CVAL_EL0, value)
    aarch64.write_system_register(.CNTV_CTL_EL0, TIMER_ENABLE)
    aarch64.isb()
}

cancel_deadline :: fn() {
    aarch64.write_system_register(.CNTV_CTL_EL0, 0)
    aarch64.isb()
}
