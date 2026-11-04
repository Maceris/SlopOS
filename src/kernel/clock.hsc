package kernel

import runtime from "base"
import robustness from "../robustness"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * The kernel's clock (roadmap M3, docs/architecture/layers.md: L1 has a counter, L2 has time): every
 * CPU's context.clock. Monotonic time is nanoseconds since the timer started, from arch.counter()
 * and its frequency, the same on every CPU. Wall-clock time is a server's (decisions/0009), so the
 * kernel has none.
 */

#if robustness.ON {
    /**
     * Where monotonic time starts, in nanoseconds: 2^63 (about 292 years) with robustness=on (decisions/0096, 0105),
     * so code that narrows a time to 32 bits, or makes it signed, fails at once; now plus a timeout still never wraps.
     */
    MONOTONIC_START : u64 : 0x8000000000000000
}
#else {
    /** Where monotonic time starts, in nanoseconds: 0 without robustness=on. */
    MONOTONIC_START : u64 : 0
}

/**
 * Set up the kernel's clock, kernel.clock, which every CPU's context.clock points at.
 *
 * Its monotonic time stays at MONOTONIC_START until start_clock; it has no wall-clock time.
 *
 * @param kernel The kernel, which the clock keeps as its data for as long as it's used.
 */
init_clock :: fn(kernel #escaping : ptr[mut Kernel]) {
    kernel.clock = runtime.Clock.{data = cast[mut rawptr](kernel), monotonic = kernel_monotonic, wall = kernel_wall}
}

/**
 * Start monotonic time now: from here, it counts up from MONOTONIC_START at the counter's rate.
 *
 * Called on the boot CPU once the counter's frequency is known, before the other CPUs start, which read the two fields
 * it sets without a lock. Until then, monotonic time is MONOTONIC_START.
 *
 * @param kernel The kernel, whose counter_frequency is set; its clock_start and clock_frequency are written.
 */
start_clock :: fn(kernel: ptr[mut Kernel]) {
    kernel.clock_start = arch.counter()
    kernel.clock_frequency = kernel.counter_frequency
}

/**
 * Read the kernel's monotonic time: runtime.Clock's monotonic function for kernel.clock.
 *
 * The same on every CPU, as arch.counter() is. Seconds and the rest are converted apart, so the nanoseconds don't
 * overflow.
 *
 * @param data The Kernel, as init_clock set it.
 * @return Nanoseconds since start_clock, plus MONOTONIC_START; MONOTONIC_START before start_clock.
 */
kernel_monotonic :: fn(data: mut rawptr) -> runtime.MonotonicTime {
    kernel :: cast[ptr[Kernel]](data)
    frequency :: kernel.clock_frequency
    if frequency == 0 {
        return cast[runtime.MonotonicTime](MONOTONIC_START)
    }
    ticks :: arch.counter() - kernel.clock_start
    // Whole seconds and what's left, so the nanoseconds don't overflow
    seconds :: ticks / frequency
    left :: ticks % frequency
    return cast[runtime.MonotonicTime](MONOTONIC_START + seconds * runtime.NANOSECONDS_PER_SECOND
        + left * runtime.NANOSECONDS_PER_SECOND / frequency)
}

/**
 * Read the wall-clock time, which the kernel doesn't have: it's a server's (decisions/0009).
 *
 * @param data The Kernel, unused.
 * @return Never a time: the kernel has no wall clock.
 * @error Unavailable Always.
 */
kernel_wall :: fn(data: mut rawptr) -> Result[runtime.Instant, runtime.ClockError] {
    return .Error(.Unavailable)
}
