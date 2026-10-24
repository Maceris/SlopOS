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
CLOCK_TEST_NANOSECONDS : i64 : 10_000_000
CLOCK_TEST_SLACK : i64 : 1_000_000

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
