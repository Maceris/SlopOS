/**
 * move (decisions/0179): a file or a directory moved, or renamed, beneath the shell's directory.
 */
package move

import os from "std"
import strings from "std"
import dir from "std/os/slop_os"
import file_tools from "../../file_tools"

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: from or to. */
    parameter : os.ParameterName,
}

/** What it moved: from where, to where. */
Moved :: struct {
    /** Where it was. */
    from : string,
    /** Where it is now. */
    to : string,
}

/** Why it couldn't move. */
MoveError :: union {
    /** Nothing's at from. */
    NotFound(Problem),
    /** to is inside from. */
    IntoItself(Problem),
    /** It couldn't be moved there, as a directory that isn't empty is in the way, or a directory to it is missing. */
    Failed(Problem),
}

/**
 * Move a file or a directory to another path beneath the shell's directory, or rename it; nothing's copied.
 *
 * @param here The shell's directory, given without asking, which both paths are beneath.
 * @param from What's moved.
 * @param to Where it goes: a file there is replaced; into a directory that's there, it goes in under its own name.
 * @return Where it was and where it is now.
 * @error NotFound There's nothing at from to move.
 * @error IntoItself That's inside what's moved; move it somewhere else.
 * @error Failed It couldn't go there, as a directory there isn't empty, or a directory on the way is missing.
 */
main :: fn(here: os.Channel[dir.Dir], from: string, to: string) -> Result[Moved, MoveError] {
    from_problem :: Problem.{parameter = os.ParameterName.{name = "from"}}
    to_problem :: Problem.{parameter = os.ParameterName.{name = "to"}}
    directory, opened :: os.directory_on(here.end)
    if opened is_some {
        return .Error(.Failed(to_problem))
    }
    source :: file_tools.live_source(directory)
    kind :: file_tools.kind_at(source, from)
    if kind == .Missing {
        return .Error(.NotFound(from_problem))
    }
    target := to
    if file_tools.kind_at(source, to) == .Directory {
        target = file_tools.joined(to, file_tools.last_name(from)) or_return .Error(.Failed(to_problem))
    }
    if target == from {
        return .Ok(Moved.{from = from, to = target})
    }
    inside :: strings.format("%/", from) or_return .Error(.Failed(to_problem))
    if kind == .Directory && strings.starts_with(target, inside) {
        return .Error(.IntoItself(to_problem))
    }
    match os.rename_in(directory, from, target) {
        case Some(error) => return .Error(.Failed(to_problem))
        case None => return .Ok(Moved.{from = from, to = target})
    }
}
