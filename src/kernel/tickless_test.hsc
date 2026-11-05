package kernel

import intrinsics from "base"
import testing from "std"

/*
 * test_tickless (decisions/0128): with nothing to run, every CPU but the boot CPU idles without ticking. From the
 * boot CPU's TICKLESS_FROM'th tick to its TICKLESS_TICKS'th, the others' timer interrupts are counted, which should be
 * none; at the TICKLESS_TICKS'th the test is run on that count, from the timer interrupt, and the kernel stops.
 */
/** The boot CPU's tick the count of the other CPUs' timer interrupts starts from, once they've gone idle. */
TICKLESS_FROM : u64 : 10
/** The boot CPU's tick the count ends at, the test is run at, and the kernel stops at. */
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
 * Count the other CPUs' timer interrupts at the boot CPU's TICKLESS_FROM'th tick, and at its TICKLESS_TICKS'th run
 * test_tickless on how many they took since, reporting it to the kernel's log. Other ticks, and runs without
 * test_tickless, do nothing.
 *
 * @param kernel The kernel, whose tickless_baseline holds the count from TICKLESS_FROM.
 * @param tick The boot CPU's tick count, from 1.
 */
tickless_test_tick :: fn(kernel: ptr[mut Kernel], tick: u64) {
    if !kernel.options.test_tickless || (tick != TICKLESS_FROM && tick != TICKLESS_TICKS) {
        return void
    }
    if tick == TICKLESS_FROM {
        kernel.tickless_baseline = other_timer_interrupts(kernel)
        return void
    }
    _ = run_tests("test_tickless", testing.Test.[.{name = "idle_cpus_other_than_the_boot_cpu_take_no_timer_interrupts",
        run = idle_cpus_other_than_the_boot_cpu_take_no_timer_interrupts}])
}

/**
 * Check that the CPUs other than the boot CPU, idle with nothing to run, took no timer interrupts from the boot CPU's
 * TICKLESS_FROM'th tick to now, its TICKLESS_TICKS'th; run from the boot CPU's timer interrupt.
 *
 * @param t The test's state.
 * @return Ok once it's run.
 */
idle_cpus_other_than_the_boot_cpu_take_no_timer_interrupts #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    online :: intrinsics.atomic_load_u32_acquire(&kernel.online_cpus)
    testing.expect_ne(t, online, 1, "the test is booted with more than one CPU, so there are others to idle")
    taken :: other_timer_interrupts(kernel) - kernel.tickless_baseline
    testing.expect_eq(t, taken, 0, "an idle CPU with nothing to run sets no timer deadline, so it takes no timer interrupts")
    return .Ok
}

/**
 * Count the timer interrupts the online CPUs but the boot CPU have taken, ticks or not.
 *
 * @param kernel The kernel, whose per_cpus are read, each count atomically.
 * @return The sum over each online CPU's PerCpu but the boot CPU's; 0 with one CPU online.
 */
other_timer_interrupts :: fn(kernel: ptr[Kernel]) -> u64 {
    others := cast[u64](0)
    per_cpus :: kernel.per_cpus
    online :: cast[usize](intrinsics.atomic_load_u32_acquire(&kernel.online_cpus))
    for index in 1..<online {
        if index < per_cpus.count && per_cpus[index] != 0 {
            others += intrinsics.atomic_load_u64(&cast[ptr[mut PerCpu]](per_cpus[index]).timer_interrupts)
        }
    }
    return others
}
