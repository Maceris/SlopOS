/**
 * test_profile (decisions/0183, 12d): a program for the shell's profile, which spins in spin_here for a while, on a
 * thread of its own whose entry it is, so it's never inlined into a caller: a profile of it finds most of its samples
 * there. With fibers (decisions/0185, 12h), it spins in spin_on_fiber instead, on a fiber of a pool its thread
 * carries, so a profile finds those samples taken on that fiber.
 */
package test_profile

import fiber from "std"
import intrinsics from "base"
import runtime from "base"
import slop_os from "std/os"

/** How long spin_here spins. */
Spin :: struct {
    /** When it stops, in nanoseconds of the monotonic clock. */
    deadline : u64,
}

/**
 * Spin for a while in spin_here, on a thread of its own, or in spin_on_fiber, on a fiber that thread carries, and wait
 * for it.
 *
 * @param milliseconds How long, at least 1.
 * @param fibers 1 to spin on a fiber; null or 0 for on the thread.
 * @return 0 once it's spun; 2 if its thread couldn't be started.
 */
main :: fn(milliseconds: u64, fibers: u64?) -> int {
    spin :: runtime.new(Spin)
    spin.deadline = (slop_os.clock_monotonic() or_else 0) + (if milliseconds == 0 { cast[u64](1) } else { milliseconds }) * 1_000_000
    node := runtime.extension_node(cast[ptr[Spin]](spin))
    on_fibers :: (fibers or_else 0) != 0
    push_context with_spin (extensions = &node) {
        thread :: runtime.thread_create(if on_fibers { carry_fibers } else { spin_here })
        if !runtime.thread_start(thread) {
            return 2
        }
        runtime.thread_join(thread)
    }
    return 0
}

/**
 * Carry a pool of one fiber, spin_on_fiber, until it's done.
 *
 * @param data Nothing: the deadline is the context's extension, which the fiber's context copies.
 */
carry_fibers : runtime.ThreadFunction : fn(data #escaping : any) {
    pool :: fiber.create_fiber_pool()
    _, failed :: fiber.spawn(pool, spin_on_fiber)
    fiber.close_pool(pool)
    if failed == null {
        fiber.run_carrier(pool)
    }
    fiber.destroy_fiber_pool(pool)
}

/**
 * Spin until the deadline on a fiber, the time a profile finds on it.
 *
 * @param data Nothing: the deadline is the context's extension.
 */
spin_on_fiber : runtime.ThreadFunction : fn(data #escaping : any) {
    found :: runtime.get_extension(Spin) or_return void
    spin :: cast[ptr[Spin]](found)
    count : u64 = 0
    loop {
        for i in 0..<1_000_000 {
            count = intrinsics.volatile_load_u64(&count) + 1
        }
    }
    while (slop_os.clock_monotonic() or_else spin.deadline) < spin.deadline
}

/**
 * Spin until the deadline, the time the profile finds.
 *
 * @param data Nothing: the deadline is the context's extension.
 */
spin_here : runtime.ThreadFunction : fn(data #escaping : any) {
    found :: runtime.get_extension(Spin) or_return void
    spin :: cast[ptr[Spin]](found)
    count : u64 = 0
    loop {
        for i in 0..<1_000_000 {
            count = intrinsics.volatile_load_u64(&count) + 1
        }
    }
    while (slop_os.clock_monotonic() or_else spin.deadline) < spin.deadline
}
