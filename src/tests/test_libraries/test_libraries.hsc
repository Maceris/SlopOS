/**
 * test_libraries (roadmap 9e1, decisions/0119, 0120): a program bound to a typed library before its main, greeting,
 * by the grant library:greeting.library: its exports called, a sum, text made with this program's context, and a
 * string from the library's own data. Given a library whose export's type changed in its place, the program never
 * starts: its runtime refuses the import and ends it with 1.
 */
package test_libraries

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import greeting from "../../libraries/greeting"

/** The test's name, which starts each line it logs. */
NAME :: "test_libraries"

/**
 * Check that the greeting library is bound before main, and its exports work.
 *
 * The library is bound by the runtime before main runs, from the grant library:greeting.library; given one whose
 * export's type changed, main never runs, and the program ends with 1.
 *
 * @param log The debug log, writable, where the test says what it found.
 * @param platform Not used.
 * @param test_device Not used.
 * @param firmware Not used.
 * @param manager Not used.
 * @param program Not used.
 * @param peer Not used.
 * @param cpu_budget Not used.
 * @return 0 if every export gave what it should; 101 if add's sum, 102 if repeat's text made with this program's
 *     context, 103 if greeting's string from the library's data was wrong.
 */
main :: fn(log: slop_os.DebugLog, platform: slop_os.Platform?, test_device: slop_os.Memory?, firmware: slop_os.Memory?,
    manager: os.Channel[process_manager.ProcessManager]?, program: slop_os.Memory?, peer: slop_os.Channel?, cpu_budget: slop_os.CpuBudget?) -> int {
    if greeting.add(40, 2) != 42 {
        return 1 + 100
    }
    if greeting.repeat("ab", 3) != "ababab" {
        return 2 + 100
    }
    if greeting.greeting() != "hello from a library" {
        return 3 + 100
    }
    log_line.write(log, "%: bound greeting, and called its exports", NAME)
    return 0
}
