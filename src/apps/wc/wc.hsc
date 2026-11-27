/**
 * wc (decisions/0201, 20l): a C tool, c/wc.c, on SlopOS's libc, run from the shell: it counts lines, words and bytes
 * of files beneath the shell's directory, or of what's typed, writing what it counts on the shell's terminal.
 */
package wc

import os from "std:os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import libc from "../../libc"

/** wc's C, wc_c's library, which tools/c_libraries.py builds from c/ beside this. */
WC_C :: #library("wc_c")

/**
 * wc's C main (c/wc.c).
 *
 * @param argc How many arguments argv has, its name first.
 * @param argv The arguments, then NULL.
 * @return 0 once every file's counted; 1 if one couldn't be read; 2 for an option it doesn't take.
 */
c_main #foreign(WC_C) #link_name("main") : fn(argc : i32, argv : ptr[mut cstring?]) -> i32 : ---

/**
 * Count lines, words and bytes, as POSIX's wc.
 *
 * @param arguments What C's wc is given after its name: -l, -w or -c for only those counts, then the files, each a
 *     path beneath here. Without files, it counts what's typed on the terminal, until Ctrl-C.
 * @param here The shell's directory, given without asking, which the files are beneath.
 * @param console The shell's terminal, given without asking, which the counts are written on, and typed input read
 *     from.
 * @return 0 once every file's counted; 1 if one couldn't be read; 2 for an option it doesn't take.
 */
main :: fn(arguments : string[]?, here : os.Channel[dir.Dir], console : os.Channel[terminal.Terminal]) -> int {
    given :: arguments or_else string.[]
    return libc.run(libc.Start.{name = "wc", arguments = given, here = here, console = console}, c_main)
}
