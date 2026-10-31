/*
 * Installations (roadmap 9d4, decisions/0113, 0117, design/software.md §6): a program run under a name of its own,
 * whose data outlives its updates. Its entry takes its data directory as an AppData, a directory it can't see out of, on
 * the system volume, as apps/<its name>, and its configuration as Config[T], owned by its name.
 */
package installations

import slop_os from "std/os"

// An installation's data directory, as its entry takes it: one end, speaking dir (Hemera's base: an AppData is a channel
// that must speak Dir).
AppData :: struct {
    end : slop_os.Channel,
}
