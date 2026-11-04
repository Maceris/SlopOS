package kernel

import intrinsics from "base"
import runtime from "base"

/*
 * test_tickless (decisions/0128): with nothing to run, every CPU but the boot CPU idles without ticking. From the
 * boot CPU's TICKLESS_FROM'th tick to its TICKLESS_TICKS'th, the others' timer interrupts are counted, which should be
 * none, and said; then the kernel stops.
 */
/** The boot CPU's tick the count of the other CPUs' timer interrupts starts from, once they've gone idle. */
TICKLESS_FROM : u64 : 10
/** The boot CPU's tick the count ends at, said, and the kernel stops at. */
TICKLESS_TICKS : u64 : 60

/**
 * Start test_tickless: the kernel stops at the boot CPU's TICKLESS_TICKS'th tick.
 *
 * @param kernel The kernel, whose stop_after_ticks it sets; called on the boot CPU at boot.
 */
start_tickless_test :: fn(kernel: ptr[mut Kernel]) {
    kernel.stop_after_ticks = TICKLESS_TICKS
}

/**
 * Count the other CPUs' timer interrupts at the boot CPU's TICKLESS_FROM'th tick, and at its TICKLESS_TICKS'th log
 * how many they took since. Other ticks, and runs without test_tickless, do nothing.
 *
 * The counts are read atomically from each online CPU's PerCpu but the boot CPU's.
 *
 * @param kernel The kernel, whose tickless_baseline holds the count from TICKLESS_FROM.
 * @param tick The boot CPU's tick count, from 1.
 */
tickless_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    if !kernel.options.test_tickless || (tick != TICKLESS_FROM && tick != TICKLESS_TICKS) {
        return void
    }
    others := cast[u64](0)
    per_cpus :: kernel.per_cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    for index in 1..<online {
        if index < per_cpus.count && per_cpus[index] != 0 {
            others += intrinsics.atomic_load_u64(&cast[ptr[mut PerCpu]](per_cpus[index]).timer_interrupts)
        }
    }
    if tick == TICKLESS_FROM {
        kernel.tickless_baseline = others
        return void
    }
    taken :: others - kernel.tickless_baseline
    if taken == 0 {
        runtime.log_info("test_tickless: the other % CPUs took no timer interrupts over % ticks", online - 1, TICKLESS_TICKS - TICKLESS_FROM)
    }
    else {
        runtime.log_info("test_tickless: the other % CPUs took % timer interrupts over % ticks", online - 1, taken, TICKLESS_TICKS - TICKLESS_FROM)
    }
}
