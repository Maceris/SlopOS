package kernel

import runtime from "base"
import testing from "std"
import text_buffer from "std"

/*
 * How the kernel runs its own tests (decisions/0175): each command-line flag that asks for one, like test_heap, runs
 * its #test functions as a table of its own through run_tests, at its point in boot, or from the interrupt that
 * finishes it. Each line of the report goes to the kernel's log at the info level after the flag's name, as
 * "[info] test_heap: test heap_blocks_keep_their_contents ... ok", and a run ends with the summary,
 * "test_heap: 1 tests: 1 passed, 0 failed"; tools/boot.py fails a boot with a test's FAILED line in it.
 *
 * Nothing here allocates, so a test can be run from an interrupt handler: T, the report's lines and the reporter are
 * all on the calling CPU's stack, a few KiB of its kernel stack.
 */

/** Where run_tests' report goes: the kernel's log, each line after the name of the flag that ran the tests. */
KernelReporting :: struct #scoped {
    /** The flag's name, like "test_heap", which starts each line. */
    flag : string,
}

/**
 * Write a line of a test report to the kernel's log at the info level, after the flag's name, as a Reporter's write.
 *
 * @param target The KernelReporting, which lasts while run_tests does.
 * @param text The line, ending with its newline, which the log adds again, so it's taken off.
 */
write_kernel_log :: fn(target: rawptr, text: string) {
    reporting :: cast[ptr[KernelReporting]](target)
    line :: if text.count > 0 && text[text.count - 1] == '\n' { text[0..<text.count - 1] } else { text }
    runtime.log_info("%: %", reporting.flag, line)
}

/**
 * Run a flag's tests, in order, reporting each to the kernel's log after the flag's name.
 *
 * Needs a context whose logger is the kernel's, as boot and every interrupt entry have; allocates nothing.
 *
 * @param flag The command-line flag that asked for the tests, like "test_heap", which starts each line.
 * @param tests The tests, as a table literal naming each #test function; empty runs none, and reports "0 tests".
 * @return How many failed: 0 when every one passed. Callers needn't act on it, as the report says it.
 */
run_tests :: fn(flag: string, tests: testing.Test[]) -> usize {
    reporting := KernelReporting.{flag = flag}
    reporter :: testing.Reporter.{target = cast[rawptr](&reporting), write = write_kernel_log}
    return testing.run(tests, reporter)
}

/**
 * Check that a number is within a range, reporting it and the range if it isn't: an assertion std/testing lacks.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param actual What the code under test gave.
 * @param low The least it may be.
 * @param high The most it may be; below low, nothing passes.
 * @param message Why it should be within them, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return True if low <= actual <= high; false, the failure recorded as "expected % to %, got %", if not.
 */
expect_within :: fn(t: ptr[mut testing.T], actual: i64, low: i64, high: i64, message: string, location := #caller_location) -> bool {
    if actual >= low && actual <= high {
        return true
    }
    storage : u8[testing.TEXT_BYTES]
    detail := text_buffer.make(storage)
    text_buffer.append_format(&detail, "expected % to %, got %", low, high, actual)
    testing.record(t, message, text_buffer.as_string(&detail), location)
    return false
}

/**
 * Require a number to be within a range, as expect_within checks, ending the test with ? if it isn't.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param actual What the code under test gave.
 * @param low The least it may be.
 * @param high The most it may be.
 * @param message Why it should be within them, for whoever reads a failure.
 * @param location Where the check is; the caller's own.
 * @return Ok if low <= actual <= high; Error(Failed), the failure recorded, if not.
 */
require_within :: fn(t: ptr[mut testing.T], actual: i64, low: i64, high: i64, message: string, location := #caller_location) -> testing.Outcome {
    return testing.outcome_of(expect_within(t, actual, low, high, message, location))
}
