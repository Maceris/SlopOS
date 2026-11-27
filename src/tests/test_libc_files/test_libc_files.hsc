/**
 * test_libc_files (decisions/0201, 20l): test_libc's C, run from the shell beneath the shell's directory, so its file
 * test runs too: stdio's streams, file descriptors, stat, rename, a directory listed and removed, all beneath it. It
 * leaves libc_words.txt there, for wc's part of the boot test. Its stdout is the shell's terminal, as a program the
 * shell runs has no debug log, and its logger's records don't reach the serial log; it links test_libc's C library,
 * which tools/c_libraries.py builds from src/tests/test_libc/c.
 */
package test_libc_files

import os from "std:os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import libc from "../../libc"

/** test_libc's C, test_libc_c's library. */
TEST_C :: #library("test_libc_c")

/**
 * test_libc's C main (src/tests/test_libc/c/test_libc.c).
 *
 * @param argc How many arguments argv has: 1, the program's name.
 * @param argv The arguments, then NULL.
 * @return How many of its tests failed.
 */
c_main #foreign(TEST_C) #link_name("main") : fn(argc : i32, argv : ptr[mut cstring?]) -> i32 : ---

/**
 * Run test_libc's C tests beneath the shell's directory, reporting on the shell's terminal.
 *
 * @param here The shell's directory, given without asking, which the file test works beneath, leaving libc_words.txt.
 * @param console The shell's terminal, given without asking, where each check that fails and the tests' count are
 *     written.
 * @return How many tests failed: 0 when every one passed, which the shell shows as nothing.
 */
main :: fn(here : os.Channel[dir.Dir], console : os.Channel[terminal.Terminal]) -> int {
    return libc.run(libc.Start.{name = "test_libc_files", here = here, console = console}, c_main)
}
