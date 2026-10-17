package kernel

import intrinsics from "base"
import runtime from "base"
import boot_info from "../boot_info"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * test_fibers: two fibers on the boot CPU, taking turns, to check that a fiber suspends and resumes
 * with its frames, locals and return values intact (Hemera's docs/calling_convention.md, Suspending
 * and Resuming a Fiber). Each suspends at the bottom of a chain of calls, and again from a frame the
 * resume loop has already re-entered.
 *
 * Each fiber's block is a frame of its own, and its root context points at the test's state through
 * user_data.
 */
FiberTest :: struct {
    marks : u8[16],
    count : usize,
}

// What the fibers write, in the order taking turns gives.
EXPECTED_MARKS :: "ababAB"

test_fibers :: fn(kernel #escaping : ptr[mut Kernel]) {
    test : ptr[mut FiberTest]
    match allocate_object[FiberTest](&kernel.frames) {
        case Ok(made) => test = made
        case Error(error) => {
            runtime.log_error("test_fibers: no memory for the test's state")
            return void
        }
    }
    first :: make_fiber(kernel, test, fiber_a) or_return void
    second :: make_fiber(kernel, test, fiber_b) or_return void
    // Round and round: start each, then resume each until both have finished
    // While a fiber resumes, its stack holds frames above the stack pointer, which an interrupt would overwrite
    arch.mask_interrupts()
    defer arch.unmask_interrupts()
    started : bool[2]
    finished : bool[2]
    for turn in 0..<cast[usize](8) {
        for i in 0..<cast[usize](2) {
            if finished[i] {
                continue
            }
            fiber :: if i == 0 { first } else { second }
            exit := runtime.FiberExit.Yielded
            if started[i] {
                exit = intrinsics.fiber_resume(fiber)
            }
            else {
                started[i] = true
                exit = intrinsics.fiber_start(fiber)
            }
            if exit == .Finished {
                finished[i] = true
            }
        }
    }
    if !finished[0] || !finished[1] || string_of(&test.marks[0], test.count) != EXPECTED_MARKS {
        runtime.log_error("test_fibers: the fibers wrote %, not %", string_of(&test.marks[0], test.count), EXPECTED_MARKS)
        return void
    }
    runtime.log_info("test_fibers: two fibers took turns")
}

// A fiber in a frame of its own, running function with a copy of this context pointing at test.
make_fiber :: fn(kernel: ptr[mut Kernel], test #escaping : ptr[mut FiberTest], function: runtime.ThreadFunction) -> ptr[mut runtime.Fiber]? {
    runtime.assert(cast[u64](runtime.FIBER_BLOCK_SIZE) <= frames.FRAME_SIZE, "a fiber's block fits in a frame")
    address : boot_info.PhysicalAddress
    match frames.allocate_zeroed(&kernel.frames, 0) {
        case Ok(allocated) => address = allocated
        case Error(error) => {
            runtime.log_error("test_fibers: no memory for a fiber")
            return null
        }
    }
    fiber :: cast[ptr[mut runtime.Fiber]](frames.virtual_of(&kernel.frames, address))
    fiber.function = function
    fiber.data = null
    fiber.context = context
    fiber.context.user_data = cast[rawptr](test)
    fiber.state = .NotStarted
    fiber.next = null
    return fiber
}

fiber_a : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut FiberTest]](context.user_data)
    // 31 + (21 + (11 + 1))
    mark(test, if descend(test, 'a', 3) == 64 { 'A' } else { 'x' })
}

fiber_b : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut FiberTest]](context.user_data)
    // 21 + (11 + 1)
    mark(test, if descend(test, 'b', 2) == 33 { 'B' } else { 'y' })
}

/*
 * Down a chain of calls, suspending at the bottom, and again at depth 2 on the way back up: each
 * frame's local and the value returned to it have to survive both.
 */
descend :: fn(test: ptr[mut FiberTest], letter: char, depth: u64) -> u64 {
    here :: depth * 10 + 1
    if depth == 0 {
        mark(test, letter)
        pause()
        return 1
    }
    below :: descend(test, letter, depth - 1)
    if depth == 2 {
        mark(test, letter)
        pause()
    }
    return here + below
}

// Back to the scheduler, which resumes this fiber later.
pause :: fn() {
    fiber :: intrinsics.carrier().current_fiber or_return void
    intrinsics.fiber_suspend(fiber)
}

mark :: fn(test: ptr[mut FiberTest], letter: char) {
    if test.count < test.marks.count {
        test.marks[test.count] = cast[u8](letter)
        test.count += 1
    }
}
