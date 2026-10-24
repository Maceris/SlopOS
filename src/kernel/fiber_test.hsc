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
    // Stack traces at the bottom, before suspending and once resumed, and the suspended fiber's from outside
    before : rawptr[80],
    before_count : usize,
    after : rawptr[80],
    after_count : usize,
    outside : rawptr[80],
    outside_count : usize,
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
    // No data: an empty any
    nothing : any
    fiber.data = nothing
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

/*
 * test_segments, in a kernel built with morestack (the build package's stack_check setting): a fiber
 * whose calls go far past its first segment, onto segments from the carrier's cache, suspending at
 * the bottom; resumed, it returns up through them, and they all go back to the carrier.
 */
SEGMENT_COUNT :: 4
// 64 + 63 + ... + 1
DEEP_SUM : u64 : 2080

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
    arch.mask_interrupts()
    defer arch.unmask_interrupts()
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

fiber_deep : runtime.ThreadFunction : fn(data #escaping : any) {
    test :: cast[ptr[mut FiberTest]](context.user_data)
    mark(test, if climb(test, 64) == DEEP_SUM { 'D' } else { 'x' })
}

// Down depth calls, each with 128 bytes of its own, suspending at the bottom: the sum of the depths.
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

// What's in values that isn't zero, which keeps them in the frame.
first_nonzero :: fn(values: u64[]) -> u64 {
    for value in values {
        if value != 0 {
            return value
        }
    }
    return 0
}

/*
 * Whether the traces agree: the one before suspending has at least least frames, the one after
 * resuming is the same, and the suspended fiber's own, taken from outside, ends with it.
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
