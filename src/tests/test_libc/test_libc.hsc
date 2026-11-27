/**
 * test_libc (decisions/0201, 20l): SlopOS's libc exercised from C. Its C, c/test_libc.c, built by a stock clang into
 * test_libc_c's library (tools/c_libraries.py), is run by the libc's start-up with its stdout the debug log, where
 * each check that fails is reported and then the tests' count, as test_kit's are. The root task gives it no working
 * directory, so its file test is skipped here; test_libc_files runs the same C beneath the shell's.
 */
package test_libc

import os from "std:os"
import slop_os from "std:os/slop_os"
import process_manager from "std:os/slop_os/process_manager"
import libc from "../../libc"

/** The test's C, test_libc_c's library, which tools/c_libraries.py builds from c/ beside this. */
TEST_C :: #library("test_libc_c")

/**
 * The test's C main (c/test_libc.c).
 *
 * @param argc How many arguments argv has: 1, the program's name.
 * @param argv The arguments, then NULL.
 * @return How many of its tests failed.
 */
c_main #foreign(TEST_C) #link_name("main") : fn(argc : i32, argv : ptr[mut cstring?]) -> i32 : ---

/**
 * Run the C tests through the libc, reporting to the debug log.
 *
 * @param log The debug log, writable, which the C's stdout and stderr write to a line at a time.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn(
    log : slop_os.DebugLog,
    platform : slop_os.Platform?,
    test_device : slop_os.Memory?,
    firmware : slop_os.Memory?,
    manager : os.Channel[process_manager.ProcessManager]?,
    program : slop_os.Memory?,
    peer : slop_os.Channel?,
    cpu_budget : slop_os.CpuBudget?
) -> int {
    return libc.run(libc.Start.{name = "test_libc", log = log}, c_main)
}
