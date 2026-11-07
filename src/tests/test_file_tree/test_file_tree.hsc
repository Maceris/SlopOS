/**
 * test_file_tree (decisions/0179): a few files and directories made beneath the shell's directory, for the file tools'
 * boot test to list, copy, move, remove and recover, and files to search, view and page.
 */
package test_file_tree

import runtime from "base"
import os from "std"
import schema from "std"
import strings from "std"
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
 * shell's directory; with reading, the directory reading too, of files to search, view and page. What's there already
 * is written over.
 *
 * @param here The shell's directory, given without asking, which they're made beneath.
 * @param reading Whether reading is made too: long.txt, of 60 lines, "line 1" to "line 60"; todo.txt, of three, the
 *     second "TODO: water the plants"; bytes.bin, the 32 bytes 0 to 31; and made.value, a typed file of this program's
 *     Made, of 3 files and 1 directory.
 * @return How many files and directories it made.
 * @error Unwritable Something couldn't be written there.
 */
main :: fn(here: os.Channel[dir.Dir], reading: bool) -> Result[Made, TreeError] {
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
    made := Made.{files = cast[u64](files.count), directories = 2}
    if reading {
        if !make_reading(directory) {
            return .Error(.Unwritable(problem))
        }
        made.files += 4
        made.directories += 1
    }
    return .Ok(made)
}

/**
 * Make the directory reading, and the files in it, as main says.
 *
 * @param directory The shell's directory.
 * @return Whether all of it was written.
 */
make_reading :: fn(directory: os.Directory) -> bool {
    match os.make_directory_in(directory, "reading") {
        case Some(error) => if error != .AlreadyExists {
            return false
        }
        case None => {}
    }
    long : u8[..]
    defer runtime.array_free(&long)
    for i in 1..=60 {
        for byte in string_bytes(strings.format("line %\n", i) or_return false) {
            runtime.array_add(&long, byte)
        }
    }
    if long.count == 0 || (os.write_entire_file_in(directory, "reading/long.txt", string_of(&long[0], long.count)) is_some) {
        return false
    }
    if os.write_entire_file_in(directory, "reading/todo.txt", "first\nTODO: water the plants\nlast\n") is_some {
        return false
    }
    bytes : u8[32]
    for i in 0..<32 {
        bytes[i] = cast[u8](i)
    }
    if os.write_entire_file_in(directory, "reading/bytes.bin", string_of(&bytes[0], bytes.count)) is_some {
        return false
    }
    value :: Made.{files = 3, directories = 1}
    written : u8[..]
    defer runtime.array_free(&written)
    if (schema.try_write_value(value, &written) is_some) || written.count == 0 {
        return false
    }
    file, error :: os.open_with_schema(directory, "reading/made.value", .WRITE, os.schema_hash_of[Made]())
    if error is_some {
        return false
    }
    defer os.close(file)
    if written.count == 0 {
        return false
    }
    return os.write(file, string_of(&written[0], written.count)) is_none
}
