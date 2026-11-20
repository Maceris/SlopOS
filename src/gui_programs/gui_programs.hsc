/**
 * What a GUI program is given (decisions/0192, 15e and 15g): the entry every GUI program has, the launcher, the GUI
 * session's first program, too. A program whose manifest is this entry's type is a GUI program: the launcher lists
 * those of the bundle store's, and the session manager starts each, as one of the session's programs, with its own
 * connection to the compositor.
 */
package gui_programs

import os from "std:os"
import slop_os from "std:os/slop_os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import programs from "../protocols/programs"
import surface from "../protocols/surface"

/** What a GUI program is given; its handles move to it at its launch. */
GuiGrants :: struct {
    /** A copy of the session manager's debug log, or null. */
    log : slop_os.DebugLog?,
    /** A connection to the compositor of its own, for its windows; null without a compositor. */
    surface : os.Channel[surface.Surface]?,
    /** A connection to the session's home volume's root; null without one. */
    home : os.Channel[dir.Dir]?,
    /**
     * A programs connection to its session: the launcher's is the session's own, which starts programs (Start); every
     * other's only finds them. Null if one couldn't be made.
     */
    programs : os.Channel[programs.Programs]?,
    /**
     * What it's asked to open: for the viewer, a file's path beneath home. Null for nothing, as when it's started from
     * the launcher's list.
     */
    open : string?,
    /** The terminal window's only: the terminal it serves, whose other end its shell's given. Null for the rest. */
    terminal : os.Channel[terminal.Terminal]?,
}

/**
 * A GUI program's entry's shape: what launching one checks its manifest against. It isn't run.
 *
 * @param log A copy of the session manager's debug log.
 * @param surface Its connection to the compositor.
 * @param home The session's home.
 * @param programs Its programs connection.
 * @param open What it's asked to open (GuiGrants' open).
 * @param terminal The terminal it serves (GuiGrants' terminal).
 * @return Never run; 0.
 */
shape :: fn(
    log : slop_os.DebugLog?,
    surface : os.Channel[surface.Surface]?,
    home : os.Channel[dir.Dir]?,
    programs : os.Channel[programs.Programs]?,
    open : string?,
    terminal : os.Channel[terminal.Terminal]?
) -> int {
    return 0
}
