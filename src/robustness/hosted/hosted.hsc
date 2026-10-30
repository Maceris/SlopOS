/*
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

Request :: struct {
    counting : bool,
    // The allocation, or the pass through the failure points, that fails, from 1; 0 for none
    allocation : u64,
    point : u64,
}

// SLOPOS_FAIL, read.
request :: fn() -> Request {
    text :: os.get_environment("SLOPOS_FAIL") or_else ""
    asked :: request_of(text)
    if text.count > 0 {
        runtime.free_array(string_bytes(text))
    }
    return asked
}

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

/*
 * body's code, with its allocations through a FailingAllocator that fails what SLOPOS_FAIL asks: then
 * "faults: allocations <n>, live <blocks>", the blocks allocated and not freed by the time it returned.
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

// What a frame allocator's failure points should do (its faults.spec), from SLOPOS_FAIL.
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

// "faults: points <n>": the passes through a frame allocator's failure points, when they were counted.
report_points :: fn(faults: ptr[robustness.Faults]) {
    if faults.spec.mode != .Off {
        runtime.log_info("faults: points %", faults.all)
    }
}
