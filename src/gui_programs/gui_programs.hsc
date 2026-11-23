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
import sound as sound_protocol from "../protocols/sound"
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
    /**
     * The activation token for the user's gesture that started it, which its first window presents to take focus
     * (the surface protocol's WindowSpec.activation); null for none (decisions/0193, 16d).
     */
    activation : u64?,
    /**
     * A sound connection in its session's group (decisions/0196, 17g), played at the session's volume; null without an
     * audio service. A program that plays nothing closes it.
     */
    sound : os.Channel[sound_protocol.Sound]?,
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
 * @param activation Its activation token (GuiGrants' activation).
 * @param sound Its sound connection (GuiGrants' sound).
 * @return Never run; 0.
 */
shape :: fn(
    log : slop_os.DebugLog?,
    surface : os.Channel[surface.Surface]?,
    home : os.Channel[dir.Dir]?,
    programs : os.Channel[programs.Programs]?,
    open : string?,
    terminal : os.Channel[terminal.Terminal]?,
    activation : u64?,
    sound : os.Channel[sound_protocol.Sound]?
) -> int {
    return 0
}

/** A font GUI programs draw with: its bundle's name in the bundle store's root, and the label it's granted under. */
Font :: struct {
    /** Its bundle's name, its file's without the extension, as the store builder names it. */
    name : string,
    /** The label of its grant, beside the entry's (os.LaunchOptions.extra), which gui_kit finds it by. */
    label : string,
}

/** How many fonts FONTS has. */
FONT_COUNT :: 2

/**
 * The fonts every GUI program's given (decisions/0193, 16f), Noto Sans and Noto Sans Mono (SIL Open Font License,
 * assets/fonts/OFL.txt), in this order: each the bundle store's memory, read-only and shared by every program given it,
 * rather than built into each.
 */
FONTS :: Font.[
    Font.{name = "NotoSans-Regular", label = "font_sans"},
    Font.{name = "NotoSansMono-Regular", label = "font_mono"}
]

/**
 * Make the font grants for one launch: a copy of each font's memory, read-only, under its label.
 *
 * @param fonts Each of FONTS' memory, in its order, which stays the caller's; NO_HANDLE for one the caller hasn't,
 *     which
 *     isn't given.
 * @param into Where the grants are made, the first of them the count returned.
 * @return The grants made, a view of into's first: the program's once it's launched with them, the caller's to close
 *     otherwise (close_font_grants). One whose copy couldn't be made isn't among them.
 */
font_grants :: fn(fonts : slop_os.Memory[FONT_COUNT], into : ptr[mut os.NamedGrant[FONT_COUNT]]) -> os.NamedGrant[] {
    rights :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_MEMORY_READ) | cast[u32](slop_os.RIGHT_TRANSFER))
    made := cast[usize](0)
    for memory, i in fonts {
        if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE || i >= FONTS.count || made >= into.count {
            continue
        }
        match slop_os.handle_duplicate(cast[slop_os.Handle](memory), rights) {
            case Ok(copy) => {
                into^[made] = os.NamedGrant.{label = FONTS[i].label, handle = copy}
                made += 1
            }
            case Error(_) => {}
        }
    }
    if made > into.count {
        return into^[0..<0]
    }
    return into^[0..<made]
}

/**
 * Close font grants a launch didn't take (font_grants): it failed before the process manager was sent them, so they're
 * still the caller's. Past that, they went to the manager, and are left alone, as their numbers may name others now.
 *
 * @param grants The grants made for the launch.
 * @param error Why the launch failed.
 */
close_font_grants :: fn(grants : os.NamedGrant[], error : os.LaunchError) {
    if error == .ManagerGone || error == .NotLoaded {
        return void
    }
    for grant in grants {
        _ = slop_os.handle_close(grant.handle)
    }
}
