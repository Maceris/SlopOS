/**
 * test_libraries (roadmap 9e1, decisions/0119, 0120): a program bound to a typed library before its main, greeting,
 * by the grant library:greeting.library: its exports called, a sum, text made with this program's context, and a
 * string from the library's own data. Given a library whose export's type changed in its place, the program never
 * starts: its runtime refuses the import and ends it with 1.
 */
package test_libraries

import compiler from "base"
import os from "std"
import testing from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import greeting from "../../libraries/greeting"
import test_kit from "../../test_kit"

/** The test's name, which starts each line it logs. */
NAME :: "test_libraries"

/** What main was given that the tests use. */
Given :: struct {
    /** The debug log. */
    log : slop_os.DebugLog,
}

/**
 * Check that the greeting library, bound by the runtime before main, gives what its exports should.
 *
 * @param t The test's state.
 * @return Ok once it's run.
 */
a_library_bound_before_main_gives_what_its_exports_should #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    testing.expect_eq(t, greeting.add(40, 2), 42, "add's sum is computed in the library and returned across the call")
    repeated :: greeting.repeat("ab", 3)
    testing.expect_eq(t, repeated, "ababab", "repeat makes its text with this program's context, which it's handed")
    testing.expect_eq(t, greeting.greeting(), "hello from a library", "greeting's string is in the library's own data, which was mapped with it")
    return .Ok
}

/**
 * Run the tests, reporting to the debug log.
 *
 * The library is bound by the runtime before main runs, from the grant library:greeting.library; given one whose
 * export's type changed, main never runs, and the program ends with 1.
 *
 * @param log The debug log, writable, where each test is reported.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    given :: Given.{log = log}
    return test_kit.run(log, NAME, #insert testing.tests_of(compiler.load_package(".")), given)
}
