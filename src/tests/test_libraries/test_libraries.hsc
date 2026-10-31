/*
 * test_libraries (roadmap 9e1, decisions/0119, 0120): a program bound to a typed library before its main, greeting, by
 * the grant library:greeting.library: its exports called, a sum, text made with this program's context, and a string
 * from the library's own data. Given a library whose export's type changed in its place, the program never starts: its
 * runtime refuses the import and ends it with 1.
 */
package test_libraries

import os from "std"
import slop_os from "std/os"
import process_manager from "std/os/slop_os"
import log_line from "../../log_line"
import greeting from "../../libraries/greeting"

NAME :: "test_libraries"

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
