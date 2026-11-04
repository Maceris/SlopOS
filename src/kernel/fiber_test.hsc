package kernel

import intrinsics from "base"
import runtime from "base"
import boot_info from "../boot_info"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/**
 * The state test_fibers and test_segments share with their fibers, through each fiber's context's user_data.
 *
 * test_fibers: two fibers on the boot CPU, taking turns, to check that a fiber suspends and resumes
 * with its frames, locals and return values intact (Hemera's docs/calling_convention.md, Suspending
 * and Resuming a Fiber). Each suspends at the bottom of a chain of calls, and again from a frame the
 * resume loop has already re-entered.
 *
 * Each fiber's block is a frame of its own, and its root context points at the test's state through
 * user_data.
 */
FiberTest :: struct {
    /** The letters the fibers wrote, in order, as mark writes them; count of them are written. */
    marks : u8[16],
    /** How many of marks are written, at most marks' count. */
    count : usize,
    /** The fiber's stack trace at the bottom of its calls, before it suspends: return addresses, innermost first. */
    before : rawptr[80],
    /** How many of before are captured. */
    before_count : usize,
    /** The same fiber's stack trace at the same place, once resumed, which should match before. */
    after : rawptr[80],
    /** How many of after are captured. */
    after_count : usize,
    /** The suspended fiber's stack trace, taken from outside it, which should end with before's frames. */
    outside : rawptr[80],
    /** How many of outside are captured. */
    outside_count : usize,
}

/**
 * What test_fibers' fibers write, in the order taking turns gives: a lower-case letter at each suspension, and an
 * upper-case one when a fiber's calls returned the right sum.
 */
EXPECTED_MARKS :: "ababAB"

/**
 * Run test_fibers on the calling CPU, the boot CPU, logging whether it passed.
 *
 * Interrupts are masked while the fibers run, since a resumed fiber's frames sit above the stack pointer; they're left
 * as they were found. The test's state and the fibers' frames are never freed.
 *
 * @param kernel The kernel, whose frame allocator gives the test's state and the fibers' blocks; kept by the fibers.
 */
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
    // Masked as they were found after (boot runs with them masked; unmasking them left it running unmasked, decisions/0106)
    unmasked :: arch.interrupts_enabled()
    arch.mask_interrupts()
    defer if unmasked {
        arch.unmask_interrupts()
    }
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
                // Suspended at the bottom of its calls, where its own trace was taken
                if i == 0 {
                    test.outside_count = intrinsics.capture_fiber_stack_trace(fiber, test.outside)
                }
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
    // descend(1) to (3), fiber_a, fiber_run and fiber_entry, which ends the chain
    if !traces_agree(test, 6) {
        return void
    }
    runtime.log_info("test_fibers: stack traces follow suspended and resumed fibers")
}

/**
 * Make a fiber in a frame of its own, not yet started, running a function with a copy of the caller's context whose
 * user_data points at the test.
 *
 * @param kernel The kernel, whose frame allocator gives the fiber's frame.
 * @param test The test's state, which the fiber reads through its context; it has to outlive the fiber.
 * @param function What the fiber runs, with an empty any as its data.
 * @return The fiber, in the direct map, its frame never freed; null if there was no frame, which is logged.
 */
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
    // No data: an empty any
    nothing : any
    fiber.data = nothing
    fiber.context = context
    fiber.context.user_data = cast[rawptr](test)
    fiber.state = .NotStarted
    fiber.next = null
    return fiber
}

/**
 * Run test_fibers' first fiber: descend three calls, then mark 'A' if the sum came back right, 'x' if not.
 *
 * @param data Unused; empty.
 */
fiber_a : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut FiberTest]](context.user_data)
    // 31 + (21 + (11 + 1))
    mark(test, if descend(test, 'a', 3) == 64 { 'A' } else { 'x' })
}

/**
 * Run test_fibers' second fiber: descend two calls, then mark 'B' if the sum came back right, 'y' if not.
 *
 * @param data Unused; empty.
 */
fiber_b : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut FiberTest]](context.user_data)
    // 21 + (11 + 1)
    mark(test, if descend(test, 'b', 2) == 33 { 'B' } else { 'y' })
}

/**
 * Go down a chain of calls, suspending at the bottom, and again at depth 2 on the way back up: each
 * frame's local and the value returned to it have to survive both.
 *
 * At the bottom it marks the letter; for 'a' it also captures the stack trace before suspending and after resuming.
 * At depth 2 it marks the letter again before suspending.
 *
 * @param test The test's state, marked and traced into.
 * @param letter The fiber's letter, 'a' or 'b'.
 * @param depth How many more calls to go down; 0 is the bottom.
 * @return The sum over the frames of depth * 10 + 1, and 1 for the bottom: 64 from depth 3, 33 from depth 2.
 */
descend :: fn(test: ptr[mut FiberTest], letter: char, depth: u64) -> u64 {
    here :: depth * 10 + 1
    if depth == 0 {
        mark(test, letter)
        if letter == 'a' {
            test.before_count = intrinsics.capture_stack_trace(test.before)
            pause()
            // Through the frames the resume loop re-entered, the same trace
            test.after_count = intrinsics.capture_stack_trace(test.after)
        }
        else {
            pause()
        }
        return 1
    }
    below :: descend(test, letter, depth - 1)
    if depth == 2 {
        mark(test, letter)
        pause()
    }
    return here + below
}

/**
 * Suspend the calling fiber, back to the code that started or resumed it, which resumes it later.
 *
 * Does nothing outside a fiber.
 */
pause :: fn() {
    fiber :: intrinsics.carrier().current_fiber or_return void
    intrinsics.fiber_suspend(fiber)
}

/**
 * Write a letter in the test's marks, unless they're full.
 *
 * @param test The test's state, whose marks gets letter at count, which goes up by one; a letter past the 16th is
 *     dropped.
 * @param letter The letter, ASCII.
 */
mark :: fn(test: ptr[mut FiberTest], letter: char) {
    if test.count < test.marks.count {
        test.marks[test.count] = cast[u8](letter)
        test.count += 1
    }
}

/** How many stack segments test_segments puts in the carrier's cache, a frame each. */
SEGMENT_COUNT :: 4
/** What climb returns from depth 64: 64 + 63 + ... + 1. */
DEEP_SUM : u64 : 2080

/**
 * Run test_segments, in a kernel built with morestack (the build package's stack_check setting): a fiber
 * whose calls go far past its first segment, onto segments from the carrier's cache, suspending at
 * the bottom; resumed, it returns up through them, and they all go back to the carrier.
 *
 * Runs on the calling CPU, the boot CPU, logging whether it passed. Interrupts are masked while the fiber runs, and
 * left as they were found. The segments stay in the carrier's cache; the test's state and the fiber's frame are never
 * freed.
 *
 * @param kernel The kernel, whose frame allocator gives the test's state, the segments and the fiber's block.
 */
test_segments :: fn(kernel #escaping : ptr[mut Kernel]) {
    test : ptr[mut FiberTest]
    match allocate_object[FiberTest](&kernel.frames) {
        case Ok(made) => test = made
        case Error(error) => {
            runtime.log_error("test_segments: no memory for the test's state")
            return void
        }
    }
    // Segments for the carrier's cache, a frame each
    carrier :: intrinsics.carrier()
    for i in 0..<cast[usize](SEGMENT_COUNT) {
        address : boot_info.PhysicalAddress
        match frames.allocate_zeroed(&kernel.frames, 0) {
            case Ok(allocated) => address = allocated
            case Error(error) => {
                runtime.log_error("test_segments: no memory for a segment")
                return void
            }
        }
        segment :: cast[ptr[mut runtime.StackSegment]](frames.virtual_of(&kernel.frames, address))
        segment.size = cast[u32](frames.FRAME_SIZE)
        segment.next_free = carrier.segment_cache
        carrier.segment_cache = segment
        carrier.segment_cache_count += 1
    }
    fiber :: make_fiber(kernel, test, fiber_deep) or_return void
    // Masked as they were found after (boot runs with them masked; unmasking them left it running unmasked, decisions/0106)
    unmasked :: arch.interrupts_enabled()
    arch.mask_interrupts()
    defer if unmasked {
        arch.unmask_interrupts()
    }
    exit := intrinsics.fiber_start(fiber)
    if exit == .Yielded {
        test.outside_count = intrinsics.capture_fiber_stack_trace(fiber, test.outside)
        exit = intrinsics.fiber_resume(fiber)
    }
    // All of them back: in the cache, or kept as the spare
    returned :: carrier.segment_cache_count + (if carrier.spare_segment is_some { cast[u32](1) } else { cast[u32](0) })
    if exit != .Finished || string_of(&test.marks[0], test.count) != "dD" || returned != SEGMENT_COUNT {
        runtime.log_error("test_segments: the fiber wrote %, and % of % segments came back", string_of(&test.marks[0], test.count),
            returned, SEGMENT_COUNT)
        return void
    }
    runtime.log_info("test_segments: a fiber grew past its first segment and back, and every segment came back")
    // climb(1) to (64), fiber_deep, fiber_run and fiber_entry: none of morestack's frames, nor .grow's
    if test.before_count != 67 {
        runtime.log_error("test_segments: the trace from the bottom has % frames, not 67", test.before_count)
        return void
    }
    if traces_agree(test, 67) {
        runtime.log_info("test_segments: stack traces leave out morestack, across segments")
    }
}

/**
 * Run test_segments' fiber: climb 64 calls deep, then mark 'D' if the sum came back right, 'x' if not.
 *
 * @param data Unused; empty.
 */
fiber_deep : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut FiberTest]](context.user_data)
    mark(test, if climb(test, 64) == DEEP_SUM { 'D' } else { 'x' })
}

/**
 * Go down a chain of calls, each with 128 bytes of locals of its own, suspending at the bottom.
 *
 * At the bottom it marks 'd', and captures the stack trace before suspending and after resuming.
 *
 * @param test The test's state, marked and traced into.
 * @param depth How many more calls to go down; 0 is the bottom.
 * @return The sum of the depths from depth down to 1: DEEP_SUM from 64.
 */
climb :: fn(test: ptr[mut FiberTest], depth: u64) -> u64 {
    padding : u64[16]
    padding[depth % 16] = depth
    if depth == 0 {
        mark(test, 'd')
        test.before_count = intrinsics.capture_stack_trace(test.before)
        pause()
        test.after_count = intrinsics.capture_stack_trace(test.after)
        return 0
    }
    return climb(test, depth - 1) + first_nonzero(padding)
}

/**
 * Find the first value that isn't zero; reading them keeps climb's locals in its frame.
 *
 * @param values The 16 words of padding of a climb frame, of which the one at its depth mod 16 is set to its depth.
 * @return The first that isn't zero, or 0 if they all are.
 */
first_nonzero :: fn(values: u64[]) -> u64 {
    for value in values {
        if value != 0 {
            return value
        }
    }
    return 0
}

/**
 * Tell whether a fiber test's traces agree: the one before suspending has at least least frames, the one after
 * resuming is the same, and the suspended fiber's own, taken from outside, ends with it.
 *
 * @param test The test's state, with its three traces captured.
 * @param least The fewest frames the trace before suspending may have.
 * @return True if they agree; false if not, with an error logged saying how.
 */
traces_agree :: fn(test: ptr[FiberTest], least: usize) -> bool {
    before :: test.before
    after :: test.after
    outside :: test.outside
    count :: test.before_count
    if count < least || count > before.count || test.after_count != count || test.outside_count < count
        || test.outside_count > outside.count {
        runtime.log_error("test_fibers: traces of %, % and % frames", count, test.after_count, test.outside_count)
        return false
    }
    shift :: test.outside_count - count
    for i in 0..<count {
        at :: shift + i
        if at >= outside.count || before[i] != after[i] || before[i] != outside[at] {
            runtime.log_error("test_fibers: the traces differ at frame %", i)
            return false
        }
    }
    return true
}
