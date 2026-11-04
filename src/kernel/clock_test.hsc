package kernel

import runtime from "base"
import time from "std"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * test_clock: 10 ms by the counter has to be 10 ms by context.clock, the kernel's monotonic clock,
 * within what reading the two apart takes.
 */
/** How long the test waits by the counter, in nanoseconds: 10 ms, a hundredth of the counter's frequency. */
CLOCK_TEST_NANOSECONDS : i64 : 10_000_000
/**
 * How much longer than CLOCK_TEST_NANOSECONDS the clock may say passed, in nanoseconds: what reading the clock and
 * the counter apart can take. Less than CLOCK_TEST_NANOSECONDS is never allowed.
 */
CLOCK_TEST_SLACK : i64 : 1_000_000

/**
 * Check that 10 ms by the counter is 10 ms by the kernel's monotonic clock, spinning on this CPU for those 10 ms.
 *
 * Logs whether it was, with the time the clock measured when it wasn't; never stops the kernel.
 *
 * @param kernel The kernel, whose counter_frequency must be set (the timer started).
 */
test_clock :: fn(kernel: ptr[Kernel]) {
    start :: time.monotonic()
    counter_start :: arch.counter()
    loop {
        arch.spin_hint()
    }
    while arch.counter() - counter_start < kernel.counter_frequency / 100
    elapsed :: cast[i64](time.monotonic()) - cast[i64](start)
    if elapsed < CLOCK_TEST_NANOSECONDS || elapsed > CLOCK_TEST_NANOSECONDS + CLOCK_TEST_SLACK {
        runtime.log_error("test_clock: 10 ms by the counter was % ns by the clock", elapsed)
        return void
    }
    runtime.log_info("test_clock: 10 ms by the counter is 10 ms by the clock")
}
