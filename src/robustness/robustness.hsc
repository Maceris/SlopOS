/**
 * Robustness testing's machinery (decisions/0096, roadmap R), compiled in only by the build setting robustness=on:
 * without it ON is false, and every #if ON below leaves its code out, so a release kernel can't be told to fail
 * anything, whatever its command line says.
 *
 * R1, fault injection: a failure point is a place the kernel can fail for want of a resource. Each pass through one
 * calls fails, which says whether this pass fails as if the resource had run out. fail=<point>:<n> on the kernel's
 * command line fails the nth pass through that point, fail=any:<n> the nth pass through any, and fail=count fails
 * nothing; either way the passes are counted, and the kernel reports them when it stops (report).
 */
package robustness

import compiler from "base"
import intrinsics from "base"
import runtime from "base"

/** Whether the build set robustness=on, compiling the machinery in; without it, nothing can be made to fail. */
ON :: #run compiler.target_setting("robustness", default = "off") == "on"

/** The failure points (decisions/0096, R1), each named on the command line as NAMES gives it. */
Point :: enum #backed_by(u8) {
    /** frames.allocate, allocate_below and take_frame: a block of frames, or a frame from a CPU's cache. */
    Frame = 0,
    /** An object from a slab cache, for the kernel's object pools and the heap's small sizes. */
    Slab = 1,
    /** A block from the kernel heap. */
    Heap = 2,
    /** A memory budget's charge_new or charge_more. */
    Budget = 3,
    /** A frame for a handle table's growth. */
    Handles = 4,
    /** A timer heap's growth. */
    Timers = 5,
    /** Device addresses from a DMA domain. */
    Iova = 6,
}

/** How many failure points there are, one for each of Point's members. */
POINT_COUNT :: 7
/** Each failure point's name on the command line, indexed by its Point's value. */
NAMES :: string.["frame", "slab", "heap", "budget", "handles", "timers", "iova"]

/** What fail= asks for. */
FailMode :: enum #backed_by(u8) {
    /** No fail= word: nothing counted or failed. */
    Off = 0,
    /** fail=count: every pass counted, none failed. */
    Count = 1,
    /** fail=<point>:<n>: the nth pass through one point fails. */
    Point = 2,
    /** fail=any:<n>: the nth pass through any point fails. */
    Any = 3,
}

/** A fail= word, parsed (fail_of). */
FailSpec :: struct {
    /** What's asked for; Off, the zero value, for nothing. */
    mode : FailMode,
    /** The point whose pass fails, for Point; ignored otherwise. */
    point : Point,
    /** The pass that fails, from 1, for Point and Any; ignored otherwise. */
    pass : u64,
}

/** The kernel's injection state: what fails, and the passes so far. */
Faults :: struct {
    /** What fail= asked for. */
    spec : FailSpec,
    /** The passes so far through each point, indexed by its Point's value. */
    passes : u64[POINT_COUNT],
    /** The passes so far through any point. */
    all : u64,
    /** Whether a pass has failed; at most one does. */
    failed : bool,
    /** The point of the pass that failed, once failed is set. */
    failed_point : Point,
    /** The number of the pass that failed at its point, from 1, once failed is set. */
    failed_pass : u64,
    /** Called when a pass fails, after saying so, by whoever made this: the kernel logs where it failed from. */
    on_fail : fn()?,
}

/**
 * Parse the fail= word's value, after "fail=".
 *
 * @param text The value: count, any:<n> or <point>:<n>, point one of NAMES and n a decimal number from 1, of at most
 *     19 digits.
 * @return What it asks for, or null if it isn't one of those, its point isn't a name NAMES has, or n isn't a number
 *     from 1.
 */
fail_of :: fn(text: string) -> FailSpec? {
    if text == "count" {
        return FailSpec.{mode = .Count}
    }
    for character, colon in text {
        if character == ':' {
            pass :: number_of(text[colon + 1..<text.count]) or_return null
            if pass == 0 {
                return null
            }
            name :: text[0..<colon]
            if name == "any" {
                return FailSpec.{mode = .Any, pass = pass}
            }
            for each, index in NAMES {
                if each == name {
                    return FailSpec.{mode = .Point, point = cast[Point](cast[u8](index)), pass = pass}
                }
            }
            return null
        }
    }
    return null
}

/**
 * Read a decimal number.
 *
 * @param text The number's digits, nothing else: no sign, space or other byte.
 * @return The number, or null if text is empty, has more than 19 digits, or has a byte that isn't a digit.
 */
number_of :: fn(text: string) -> u64? {
    if text.count == 0 || text.count > 19 {
        return null
    }
    value : u64 = 0
    for character in text {
        if character < '0' || character > '9' {
            return null
        }
        value = value * 10 + cast[u64](character) - cast[u64]('0')
    }
    return value
}

/**
 * Count a pass through a failure point, and tell whether it fails as if the resource had run out.
 *
 * Any CPU may pass at once, so the counts are atomic; with more than one CPU, which pass is the nth can vary between
 * runs. The pass that fails is recorded, logged as "faults: failing <point> pass <n>" for a run that hangs and never
 * reports, and on_fail is called, before this returns.
 *
 * @param faults The kernel's injection state; nothing is counted when its spec is Off.
 * @param point The point being passed through.
 * @return True if this is the pass fail= asked to fail, which the caller treats as the resource running out; false
 *     otherwise, and always false without robustness=on, which leaves the rest out.
 */
fails :: fn(faults: ptr[mut Faults], point: Point) -> bool {
    #if ON {
        if faults.spec.mode == .Off {
            return false
        }
        index :: cast[usize](point)
        if index >= faults.passes.count {
            return false
        }
        mine :: intrinsics.interlocked_exchange_add_u64_no_fence(&faults.passes[index], 1) + 1
        all :: intrinsics.interlocked_exchange_add_u64_no_fence(&faults.all, 1) + 1
        spec :: faults.spec
        if spec.mode == .Point && spec.point == point && mine == spec.pass || spec.mode == .Any && all == spec.pass {
            // One pass matches, so one CPU writes these; they're read when the kernel stops
            faults.failed_point = point
            faults.failed_pass = mine
            faults.failed = true
            // Said now too, for a run that hangs and never stops to report
            index_name :: if index < NAMES.count { NAMES[index] } else { "?" }
            runtime.log_info("faults: failing % pass %", index_name, mine)
            match faults.on_fail {
                case Some(call) => call()
                case None => {}
            }
            return true
        }
    }
    return false
}

/**
 * Log the passes, and the pass that failed, for boot_tests.py --robustness to read: "faults: passes ..." and
 * "faults: failed <point> pass <n>".
 *
 * @param faults The kernel's injection state; nothing is logged when its spec is Off, or without robustness=on.
 */
report :: fn(faults: ptr[Faults]) {
    #if ON {
        if faults.spec.mode == .Off {
            return void
        }
        passes :: faults.passes
        runtime.log_info("faults: passes frame %, slab %, heap %, budget %, handles %, timers %, iova %, all %", passes[0],
            passes[1], passes[2], passes[3], passes[4], passes[5], passes[6], faults.all)
        if faults.failed {
            index :: cast[usize](faults.failed_point)
            name :: if index < NAMES.count { NAMES[index] } else { "?" }
            runtime.log_info("faults: failed % pass %", name, faults.failed_pass)
        }
    }
}
