/**
 * remove (decisions/0179): a file, or a directory and everything in it, removed beneath the shell's directory, after a
 * snapshot that still has it, so recover can bring it back.
 */
package remove

import os from "std"
import strings from "std"
import dir from "std/os/slop_os"
import file_tools from "../../file_tools"

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: path. */
    parameter : os.ParameterName,
}

/** What it removed. */
Removed :: struct {
    /** The path removed. */
    path : string,
    /** How many files and directories went, it among them. */
    count : u64,
    /** The snapshot that still has it, for recover; "" when removed --forever. */
    snapshot : string,
}

/** Why it couldn't remove. */
RemoveError :: union {
    /** Nothing's at the path. */
    NotFound(Problem),
    /** The volume can't take a snapshot, so it couldn't be recovered. */
    Unrecoverable(Problem),
    /** Something couldn't be removed; what was removed before it stays recoverable. */
    Failed(Problem),
}

/**
 * Remove a file, or a directory and everything in it, beneath the shell's directory. A snapshot of the volume is taken
 * first, so recover can bring it back while the snapshot's kept, a day.
 *
 * @param here The shell's directory, given without asking, which path is beneath.
 * @param path What's removed.
 * @param forever Whether to remove it without a snapshot, as on a volume that has none; it can't be recovered then.
 * @return What it removed, how many entries, and the snapshot that has it.
 * @error NotFound There's nothing at that path to remove.
 * @error Unrecoverable The volume can't take a snapshot, so it couldn't be recovered; remove it with --forever.
 * @error Failed Something couldn't be removed; what went before it can be recovered.
 */
main :: fn(here: os.Channel[dir.Dir], path: string, forever: bool) -> Result[Removed, RemoveError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "path"}}
    snapshot := ""
    if !forever {
        match file_tools.take_snapshot(here.end) {
            case Ok(taken) => snapshot = taken
            case Error(error) => return .Error(.Unrecoverable(problem))
        }
    }
    directory, opened :: os.directory_on(here.end)
    if opened is_some {
        return .Error(.Failed(problem))
    }
    source :: file_tools.live_source(directory)
    if file_tools.kind_at(source, path) == .Missing || path == "." || path.count == 0 {
        return .Error(.NotFound(problem))
    }
    count := cast[u64](0)
    if !removed(source, directory, path, &count) {
        return .Error(.Failed(problem))
    }
    return .Ok(Removed.{path = path, count = count, snapshot = snapshot})
}

/**
 * Remove what's at a path: a file, or a directory once everything in it is.
 *
 * @param source The directory, as a Source, to tell what's there and list it.
 * @param directory The same directory.
 * @param path The path.
 * @param count How many entries have been removed, added to.
 * @return Whether it's all gone; false at the first that couldn't be removed.
 */
removed :: fn(source: file_tools.Source, directory: os.Directory, path: string, count: ptr[mut u64]) -> bool {
    match file_tools.kind_at(source, path) {
        case .Missing => return false
        case .File => {
            if os.delete_file_in(directory, path) is_some {
                return false
            }
            count^ += 1
            return true
        }
        case .Directory => {}
    }
    names : os.DirectoryEntry[..]
    defer file_tools.free_names(&names)
    if file_tools.names_at(source, path, &names) is_some {
        return false
    }
    for each in names {
        inner :: file_tools.joined(path, each.name) or_return false
        defer strings.free_string(inner)
        if !removed(source, directory, inner, count) {
            return false
        }
    }
    if os.remove_directory_in(directory, path) is_some {
        return false
    }
    count^ += 1
    return true
}
