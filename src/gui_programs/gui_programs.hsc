/**
 * What a GUI program is given (decisions/0192, 15e): the entry every program the launcher starts has, and the GUI
 * session's first program, the launcher, has too. A program whose manifest is this entry's type is a GUI program: the
 * launcher lists those of the bundle store's, and starts each with its own connection to the compositor.
 */
package gui_programs

import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import process_manager from "std/os/slop_os"
import programs from "../protocols/programs"
import surface from "../protocols/surface"

/** What a GUI program is given; its handles move to it at its launch. */
GuiGrants :: struct {
    /** A copy of its starter's debug log, or null. */
    log : slop_os.DebugLog?,
    /** A connection to the compositor of its own, for its windows; null without a compositor. */
    surface : os.Channel[surface.Surface]?,
    /** The session's home volume's root; null without one. */
    home : os.Channel[dir.Dir]?,
    /** A connection to the process manager of its own, to launch programs; null if one couldn't be made. */
    manager : os.Channel[process_manager.ProcessManager]?,
    /** A programs connection to its session, which finds programs in the bundle store; null if one couldn't be made. */
    programs : os.Channel[programs.Programs]?,
}

/**
 * A GUI program's entry's shape: what launching one checks its manifest against. It isn't run.
 *
 * @param log A copy of its starter's debug log.
 * @param surface Its connection to the compositor.
 * @param home The session's home.
 * @param manager Its connection to the process manager.
 * @param programs Its programs connection.
 * @return Never run; 0.
 */
shape :: fn(log: slop_os.DebugLog?, surface: os.Channel[surface.Surface]?, home: os.Channel[dir.Dir]?,
    manager: os.Channel[process_manager.ProcessManager]?, programs: os.Channel[programs.Programs]?) -> int {
    return 0
}
