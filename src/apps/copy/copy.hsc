/**
 * copy (decisions/0179): a file, or a directory and everything in it, copied beneath the shell's directory.
 */
package copy

import os from "std"
import strings from "std"
import dir from "std/os/slop_os"
import file_tools from "../../file_tools"

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: from or to. */
    parameter : os.ParameterName,
}

/** Why it couldn't copy. */
CopyError :: union {
    /** Nothing's at from. */
    NotFound(Problem),
    /** A directory's at to already, where a directory would be copied. */
    AlreadyExists(Problem),
    /** to is inside from, so the copy would never end. */
    IntoItself(Problem),
    /** Something couldn't be read or written; what was copied before it stays. */
    Failed(Problem),
}

/**
 * Copy a file, or a directory and everything in it, to another path beneath the shell's directory, saying how far
 * along it is as it goes.
 *
 * @param here The shell's directory, given without asking, which both paths are beneath.
 * @param from What's copied: a file, or a directory, which is copied whole.
 * @param to Where it's copied to: a file there is replaced; into a directory that's there, it's copied in under its own
 *     name.
 * @return How many files, bytes and directories it copied.
 * @error NotFound There's nothing at from to copy.
 * @error AlreadyExists A directory is there already; copy into it, or to a new name.
 * @error IntoItself The copy would be inside what it copies; copy it somewhere else.
 * @error Failed Something couldn't be read or written; what was copied before it stays.
 */
main :: fn(here: os.Channel[dir.Dir], from: string, to: string) -> Result[file_tools.Copied, CopyError] {
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
    // Into a directory that's there, under its own name
    target := to
    if file_tools.kind_at(source, to) == .Directory {
        target = file_tools.joined(to, file_tools.last_name(from)) or_return .Error(.Failed(to_problem))
        if kind == .Directory && file_tools.kind_at(source, target) != .Missing {
            return .Error(.AlreadyExists(to_problem))
        }
    }
    if kind == .Directory && is_inside(target, from) {
        return .Error(.IntoItself(to_problem))
    }
    copied := file_tools.Copied.{}
    match file_tools.copy_tree(source, from, directory, target, file_tools.count_files(source, from), &copied) {
        case Some(stop) => return .Error(.Failed(if stop.why == .NotFound && stop.path == target { from_problem } else { to_problem }))
        case None => return .Ok(copied)
    }
}

/**
 * Tell whether a path is a directory's, or beneath it.
 *
 * @param path The path.
 * @param directory The directory's path.
 * @return Whether path is directory, or starts with it and a /.
 */
is_inside :: fn(path: string, directory: string) -> bool {
    if path == directory {
        return true
    }
    inside :: strings.format("%/", directory) or_return false
    defer strings.free_string(inside)
    return strings.starts_with(path, inside)
}
