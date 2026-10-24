package kernel

import runtime from "base"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * The kernel's clock (roadmap M3, docs/architecture/layers.md: L1 has a counter, L2 has time): every
 * CPU's context.clock. Monotonic time is nanoseconds since the timer started, from arch.counter()
 * and its frequency, the same on every CPU. Wall-clock time is a server's (decisions/0009), so the
 * kernel has none.
 */

// What context.clock points at, in Kernel: its data is the Kernel.
init_clock :: fn(kernel #escaping : ptr[mut Kernel]) {
    kernel.clock = runtime.Clock.{data = cast[mut rawptr](kernel), monotonic = kernel_monotonic, wall = kernel_wall}
}

/*
 * Once the counter's frequency is known: time starts now. Until then, monotonic time is 0. Called on
 * the boot CPU before the other CPUs start.
 */
start_clock :: fn(kernel: ptr[mut Kernel]) {
    kernel.clock_start = arch.counter()
    kernel.clock_frequency = kernel.counter_frequency
}

kernel_monotonic :: fn(data: mut rawptr) -> runtime.MonotonicTime {
    kernel :: cast[ptr[Kernel]](data)
    frequency :: kernel.clock_frequency
    if frequency == 0 {
        return 0
    }
    ticks :: arch.counter() - kernel.clock_start
    // Whole seconds and what's left, so the nanoseconds don't overflow
    seconds :: ticks / frequency
    left :: ticks % frequency
    return cast[runtime.MonotonicTime](seconds * runtime.NANOSECONDS_PER_SECOND + left * runtime.NANOSECONDS_PER_SECOND / frequency)
}

kernel_wall :: fn(data: mut rawptr) -> Result[runtime.Instant, runtime.ClockError] {
    return .Error(.Unavailable)
}
