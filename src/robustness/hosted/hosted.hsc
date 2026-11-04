/**
 * Fault injection for the hosted unit tests (decisions/0096, R1; tools/unit_tests.py --robustness). SLOPOS_FAIL, in
 * the environment, says what to do:
 * - unset: nothing;
 * - count: count the allocations a test makes, and the passes through the frame allocator's failure points;
 * - alloc:<n>: fail the nth allocation through context.allocator (std's memory.FailingAllocator);
 * - point:<n>: fail the nth pass through the failure points of a frame allocator the test gives point_spec to, in a
 *   test built with robustness=on.
 * A test's main runs its checks through run, which says what was counted when they're done, and whether blocks were
 * left allocated, for unit_tests.py to compare with a run that failed nothing.
 */
package hosted_faults

import runtime from "base"
import memory from "std"
import os from "std"
import robustness from "../../robustness"

/** What SLOPOS_FAIL asks for; all zero when it's unset or not understood. */
Request :: struct {
    /** Whether to count allocations and passes through the failure points, failing none (count). */
    counting : bool,
    /** The allocation through context.allocator that fails, from 1; 0 for none (alloc:<n>). */
    allocation : u64,
    /** The pass through a frame allocator's failure points that fails, from 1; 0 for none (point:<n>). */
    point : u64,
}

/**
 * Read what SLOPOS_FAIL asks for, from the environment.
 *
 * @return What it asks for, as request_of reads it; nothing asked for when it's unset.
 */
request :: fn() -> Request {
    text :: os.get_environment("SLOPOS_FAIL") or_else ""
    asked :: request_of(text)
    if text.count > 0 {
        runtime.free_array(string_bytes(text))
    }
    return asked
}

/**
 * Read what a SLOPOS_FAIL value asks for.
 *
 * @param text The value: count, alloc:<n> or point:<n>, n a decimal number of at most 19 digits.
 * @return What it asks for; nothing asked for when it's empty or none of those, and none failed for an n that
 *     isn't a number or is 0.
 */
request_of :: fn(text: string) -> Request {
    if text == "count" {
        return Request.{counting = true}
    }
    alloc :: "alloc:"
    if text.count > alloc.count && text[0..<alloc.count] == alloc {
        return Request.{allocation = robustness.number_of(text[alloc.count..<text.count]) or_else 0}
    }
    point :: "point:"
    if text.count > point.count && text[0..<point.count] == point {
        return Request.{point = robustness.number_of(text[point.count..<text.count]) or_else 0}
    }
    return Request.{}
}

/**
 * Run a test's checks, with their allocations through a FailingAllocator that fails what SLOPOS_FAIL asks.
 *
 * When SLOPOS_FAIL asks for anything, it logs "faults: allocations <n>, live <blocks>" once body returns, the blocks
 * allocated and not freed by then, and where the allocation it failed was made, if it failed one. When it asks for
 * nothing, body runs as it is, with nothing logged.
 *
 * @param body The test's checks, which give its exit code.
 * @return body's code; or 1000 if the FailingAllocator couldn't be made, in which case body isn't run.
 */
run :: fn(body: (fn() -> int)) -> int {
    asked :: request()
    if !asked.counting && asked.allocation == 0 && asked.point == 0 {
        return body()
    }
    failing :: memory.make_failing(asked.allocation) or_return 1000
    defer memory.free_failing(failing)
    code := 0
    push_context failing_context (allocator = memory.failing_allocator(failing)) {
        code = body()
    }
    runtime.log_info("faults: allocations %, live %", failing.allocations, failing.live)
    if failing.failed {
        at :: failing.failed_at
        runtime.log_info("faults: failed the allocation at %:%, in %", at.file_path, at.line, at.function)
    }
    return code
}

/**
 * Tell a frame allocator's failure points what to do (its faults.spec), from SLOPOS_FAIL.
 *
 * @return Count for count; Any, failing the nth pass through any point, for point:<n>; Off, failing and counting
 *     nothing, otherwise, alloc:<n> included.
 */
point_spec :: fn() -> robustness.FailSpec {
    asked :: request()
    if asked.counting {
        return robustness.FailSpec.{mode = .Count}
    }
    if asked.point != 0 {
        return robustness.FailSpec.{mode = .Any, pass = asked.point}
    }
    return robustness.FailSpec.{}
}

/**
 * Log "faults: points <n>", the passes through a frame allocator's failure points, for unit_tests.py to read.
 *
 * @param faults The frame allocator's injection state; nothing is logged when its spec is Off.
 */
report_points :: fn(faults: ptr[robustness.Faults]) {
    if faults.spec.mode != .Off {
        runtime.log_info("faults: points %", faults.all)
    }
}
