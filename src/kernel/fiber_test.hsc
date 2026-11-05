package kernel

import intrinsics from "base"
import runtime from "base"
import frames from "frames"
import testing from "std"

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
 * Run test_fibers on the calling CPU, the boot CPU, reporting it to the kernel's log.
 *
 * @param kernel Not used: the tests find the kernel through per_cpu.
 */
test_fibers :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_fibers", testing.Test.[
        .{name = "two_fibers_take_turns", run = two_fibers_take_turns},
        .{name = "stack_traces_follow_suspended_and_resumed_fibers", run = stack_traces_follow_suspended_and_resumed_fibers}])
}

/**
 * Check that two fibers taking turns on this CPU each suspend and resume with their frames, locals and return values
 * intact: what they mark comes in the order taking turns gives, with the sums their calls return right.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if there was no memory for the fibers.
 */
two_fibers_take_turns #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    test :: run_fibers(t)?
    testing.expect_eq(t, string_of(&test.marks[0], test.count), EXPECTED_MARKS,
        "each fiber marks at each suspension and, its calls' sums right, once it ends, the two taking turns")
    return .Ok
}

/**
 * Check that stack traces follow fibers: the trace a fiber takes before it suspends is the one it takes once resumed,
 * and the one taken of it from outside, while it's suspended, ends with it.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if there was no memory for the fibers.
 */
stack_traces_follow_suspended_and_resumed_fibers #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    test :: run_fibers(t)?
    // descend(1) to (3), fiber_a, fiber_run and fiber_entry, which ends the chain
    expect_traces_agree(t, test, 6)
    return .Ok
}

/**
 * Run test_fibers' two fibers on the calling CPU, the boot CPU, until both have finished, each taking turns.
 *
 * Interrupts are masked while the fibers run, since a resumed fiber's frames sit above the stack pointer; they're left
 * as they were found. The test's state and the fibers' frames are never freed.
 *
 * @param t The test's state, which a failure is recorded in.
 * @return The fibers' state, what they marked and traced, from the frame allocator; Error if there was no memory for
 *     it or a fiber, or the fibers didn't both finish within eight turns each.
 */
run_fibers :: fn(t: ptr[mut testing.T]) -> Result[ptr[mut FiberTest], testing.Stopped] {
    kernel :: per_cpu().kernel
    made :: allocate_object[FiberTest](&kernel.frames)
    test :: testing.require_ok(t, made, "a boot's free frames hold the test's state")?
    first :: make_fiber(t, kernel, test, fiber_a)?
    second :: make_fiber(t, kernel, test, fiber_b)?
    /*
     * Round and round: start each, then resume each until both have finished. While a fiber resumes, its stack holds
     * frames above the stack pointer, which an interrupt would overwrite, so interrupts are masked, and left as they
     * were found after (boot runs with them masked; unmasking them left it running unmasked, decisions/0106).
     */
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
    testing.require_eq(t, finished, bool.[true, true], "each fiber suspends three times at most, so both finish within eight turns")?
    return .Ok(test)
}

/**
 * Make a fiber in a frame of its own, not yet started, running a function with a copy of the caller's context whose
 * user_data points at the test.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param kernel The kernel, whose frame allocator gives the fiber's frame.
 * @param test The test's state, which the fiber reads through its context; it has to outlive the fiber.
 * @param function What the fiber runs, with an empty any as its data.
 * @return The fiber, in the direct map, its frame never freed; Error, recorded, if there was no frame.
 */
make_fiber :: fn(t: ptr[mut testing.T], kernel: ptr[mut Kernel], test #escaping : ptr[mut FiberTest], function: runtime.ThreadFunction)
    -> Result[ptr[mut runtime.Fiber], testing.Stopped] {
    runtime.assert(cast[u64](runtime.FIBER_BLOCK_SIZE) <= frames.FRAME_SIZE, "a fiber's block fits in a frame")
    allocated :: frames.allocate_zeroed(&kernel.frames, 0)
    address :: testing.require_ok(t, allocated, "a boot's free frames hold a fiber's block")?
    fiber :: cast[ptr[mut runtime.Fiber]](frames.virtual_of(&kernel.frames, address))
    fiber.function = function
    // No data: an empty any
    nothing : any
    fiber.data = nothing
    fiber.context = context
    fiber.context.user_data = cast[rawptr](test)
    fiber.state = .NotStarted
    fiber.next = null
    return .Ok(fiber)
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
 * Run test_segments, in a kernel built with morestack (the build package's stack_check setting), on the calling CPU,
 * the boot CPU, reporting it to the kernel's log.
 *
 * @param kernel Not used: the test finds the kernel through per_cpu.
 */
test_segments :: fn(kernel: ptr[mut Kernel]) {
    _ = run_tests("test_segments", testing.Test.[.{name = "a_fiber_grows_onto_segments_and_back", run = a_fiber_grows_onto_segments_and_back}])
}

/**
 * Check a fiber whose calls go far past its first segment, onto segments from the carrier's cache, suspending at the
 * bottom; resumed, it returns up through them, and they all go back to the carrier. Its stack traces leave out
 * morestack's frames, across segments.
 *
 * Interrupts are masked while the fiber runs, and left as they were found. The segments stay in the carrier's cache;
 * the test's state and the fiber's frame are never freed.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error if there was no memory for the test's state, a segment or the fiber.
 */
a_fiber_grows_onto_segments_and_back #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    kernel :: per_cpu().kernel
    made :: allocate_object[FiberTest](&kernel.frames)
    test :: testing.require_ok(t, made, "a boot's free frames hold the test's state")?
    // Segments for the carrier's cache, a frame each
    carrier :: intrinsics.carrier()
    for i in 0..<cast[usize](SEGMENT_COUNT) {
        allocated :: frames.allocate_zeroed(&kernel.frames, 0)
        address :: testing.require_ok(t, allocated, "a boot's free frames hold the segments")?
        segment :: cast[ptr[mut runtime.StackSegment]](frames.virtual_of(&kernel.frames, address))
        segment.size = cast[u32](frames.FRAME_SIZE)
        segment.next_free = carrier.segment_cache
        carrier.segment_cache = segment
        carrier.segment_cache_count += 1
    }
    fiber :: make_fiber(t, kernel, test, fiber_deep)?
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
    testing.expect_eq(t, exit, runtime.FiberExit.Finished, "the fiber suspends once, at the bottom, so it finishes once resumed")
    testing.expect_eq(t, string_of(&test.marks[0], test.count), "dD",
        "the fiber marks at the bottom, and again once its 64 calls' sum comes back right through the segments")
    // All of them back: in the cache, or kept as the spare
    returned :: carrier.segment_cache_count + (if carrier.spare_segment is_some { cast[u32](1) } else { cast[u32](0) })
    testing.expect_eq(t, returned, cast[u32](SEGMENT_COUNT), "every segment the fiber grew onto goes back to the carrier as it returns")
    // climb(1) to (64), fiber_deep, fiber_run and fiber_entry: none of morestack's frames, nor .grow's
    testing.expect_eq(t, test.before_count, 67, "the trace from the bottom has climb's 64 frames and the fiber's 3, leaving out morestack's")
    expect_traces_agree(t, test, 67)
    return .Ok
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
 * Check that a fiber test's traces agree: the one before suspending has at least least frames, the one after resuming
 * is the same, and the suspended fiber's own, taken from outside, ends with it.
 *
 * @param t The test's state, which each disagreement is recorded in.
 * @param test The fiber test's state, with its three traces captured.
 * @param least The fewest frames the trace before suspending may have.
 * @param location Where the test asked, which a failure is recorded at: the caller's own.
 */
expect_traces_agree :: fn(t: ptr[mut testing.T], test: ptr[FiberTest], least: usize, location := #caller_location) {
    before :: test.before
    after :: test.after
    outside :: test.outside
    count :: test.before_count
    testing.expect_within(t, cast[i64](count), cast[i64](least), cast[i64](before.count),
        "the trace before suspending has every frame of the fiber's calls, and they fit in it", location)
    testing.expect_eq(t, test.after_count, count, "the trace once resumed has as many frames as before, the resume loop having re-entered them", location)
    testing.expect_within(t, cast[i64](test.outside_count), cast[i64](count), cast[i64](outside.count),
        "the trace from outside has the suspended fiber's frames, and those of what suspended it", location)
    if count > before.count || test.outside_count < count || test.outside_count > outside.count {
        return void
    }
    shift :: test.outside_count - count
    differs : usize? = null
    for i in 0..<count {
        at :: shift + i
        if at >= outside.count || before[i] != after[i] || before[i] != outside[at] {
            differs = i
            break
        }
    }
    testing.expect_none(t, differs, "the three traces have the same return addresses, frame for frame, from the bottom", location)
}
