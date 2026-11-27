/**
 * test_c_ports (decisions/0202, 21g): the files the C ports' boot test runs on, made beneath the shell's directory:
 * Lua's scripts (scripts/), and for minigzip, a file to compress, gzip_input.txt, and a copy of it to compare what it
 * gives back with, gzip_expected.txt, both checks.lua's text.
 */
package test_c_ports

import os from "std:os"
import dir from "std:os/slop_os/dir"

/** Lua's checks, which are minigzip's input too. */
CHECKS :: #file_data("scripts/checks.lua")
/** A script whose error nothing catches. */
FAILS :: #file_data("scripts/fails.lua")
/** A script describing what minigzip made and gave back. */
COMPARE :: #file_data("scripts/compare.lua")

/** How many files it makes. */
FILE_COUNT : u64 : 5

/** An error naming the parameter it came from. */
Problem :: struct {
    /** The parameter: here. */
    parameter : os.ParameterName,
}

/** Why it couldn't make them. */
PortsError :: union {
    /** The shell's directory couldn't be opened, or a file in it written. */
    Unwritable(Problem),
}

/**
 * Make the files, replacing any there of the same names.
 *
 * @param here The shell's directory, given without asking, which they're made in.
 * @return How many files it made, FILE_COUNT; Unwritable if the directory couldn't be opened or one couldn't be
 *     written, those before it left made.
 */
main :: fn(here : os.Channel[dir.Dir]) -> Result[u64, PortsError] {
    problem :: Problem.{parameter = os.ParameterName.{name = "here"}}
    directory, opened :: os.directory_on(here.end)
    if opened is_some {
        return .Error(.Unwritable(problem))
    }
    if !put(directory, "checks.lua", CHECKS) || !put(directory, "fails.lua", FAILS)
        || !put(directory, "compare.lua", COMPARE) || !put(directory, "gzip_input.txt", CHECKS)
        || !put(directory, "gzip_expected.txt", CHECKS) {
        return .Error(.Unwritable(problem))
    }
    return .Ok(FILE_COUNT)
}

/**
 * Write a file beneath a directory, replacing one there.
 *
 * @param directory The directory.
 * @param name The file's name in it.
 * @param bytes What it holds; none writes nothing and fails.
 * @return Whether it was written.
 */
put :: fn(directory : os.Directory, name : string, bytes : u8[]) -> bool {
    if bytes.count == 0 {
        return false
    }
    return os.write_entire_file_in(directory, name, string_of(&bytes[0], bytes.count)) is_none
}
