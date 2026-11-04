/**
 * Installations (roadmap 9d4, decisions/0113, 0117, 0153, design/software.md §6): a program run under a name of its
 * own, in each session, whose data outlives its updates. Its entry takes its data directory as an AppData, a
 * directory it can't see out of, apps/<its name> in the session's home volume, and its configuration as Config[T],
 * owned by "user:", the session's user's name, ":" and its name.
 */
package installations

import slop_os from "std/os"

/**
 * An installation's data directory, as its entry takes it: one end, speaking dir (Hemera's base: an AppData is a
 * channel that must speak Dir).
 */
AppData :: struct {
    /**
     * The installation's end of a channel speaking the Dir protocol, served on apps/<its name> in the session's home
     * volume, which it can't see out of; the entry owns it.
     */
    end : slop_os.Channel,
}
