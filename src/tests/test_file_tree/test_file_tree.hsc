/**
 * test_file_tree (decisions/0179): a few files and directories made beneath the shell's directory, for the file tools'
 * boot test to list, copy, move, remove and recover.
 */
package test_file_tree

import os from "std"
import dir from "std/os/slop_os"

/** What it made. */
Made :: struct {
    /** How many files. */
    files : u64,
    /** How many directories. */
    directories : u64,
}

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: here. */
    parameter : os.ParameterName,
}

/** Why it couldn't make them. */
TreeError :: union {
    /** Something couldn't be written. */
    Unwritable(Problem),
}

/**
 * Make notes.txt, Report.txt and pictures/cat.txt, with a line in each, and the empty directory Photos, beneath the
 * shell's directory; what's there already is written over.
 *
 * @param here The shell's directory, given without asking, which they're made beneath.
 * @return How many files and directories it made.
 * @error Unwritable Something couldn't be written there.
 */
main :: fn(here: os.Channel[dir.Dir]) -> Result[Made, TreeError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "here"}}
    directory, opened :: os.directory_on(here.end)
    if opened is_some {
        return .Error(.Unwritable(problem))
    }
    for name in string.["pictures", "Photos"] {
        match os.make_directory_in(directory, name) {
            case Some(error) => if error != .AlreadyExists {
                return .Error(.Unwritable(problem))
            }
            case None => {}
        }
    }
    files :: string.["notes.txt", "Report.txt", "pictures/cat.txt"]
    for name in files {
        if os.write_entire_file_in(directory, name, "a line in a file\n") is_some {
            return .Error(.Unwritable(problem))
        }
    }
    return .Ok(Made.{files = cast[u64](files.count), directories = 2})
}
