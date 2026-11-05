package kernel

import testing from "std"
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
 * Run test_clock on the calling CPU, reporting it to the kernel's log; never stops the kernel.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu, whose counter_frequency has to be set (the timer
 *     started).
 */
test_clock :: fn(kernel: ptr[Kernel]) {
    _ = run_tests("test_clock", testing.Test.[.{name = "ten_ms_by_the_counter_is_ten_ms_by_the_clock", run = ten_ms_by_the_counter_is_ten_ms_by_the_clock}])
}

/**
 * Check that 10 ms by the counter is 10 ms by the kernel's monotonic clock, spinning on this CPU for those 10 ms.
 *
 * @param t The test's state.
 * @return Ok once it's run.
 */
ten_ms_by_the_counter_is_ten_ms_by_the_clock #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    start :: time.monotonic()
    counter_start :: arch.counter()
    loop {
        arch.spin_hint()
    }
    while arch.counter() - counter_start < kernel.counter_frequency / 100
    elapsed :: cast[i64](time.monotonic()) - cast[i64](start)
    expect_within(t, elapsed, CLOCK_TEST_NANOSECONDS, CLOCK_TEST_NANOSECONDS + CLOCK_TEST_SLACK,
        "the clock counts the counter's ticks, so 10 ms by the counter is 10 ms by it, give or take reading the two apart")
    return .Ok
}
