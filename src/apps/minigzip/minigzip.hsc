/**
 * minigzip (decisions/0202, 21g): zlib 1.4's test/minigzip.c and zlib itself in c/, on SlopOS's libc, run from the
 * shell. It compresses a file beneath the shell's directory into <file>.gz, removing the file, or with -d gives one
 * back from its .gz. zlib's license is in LICENSE.txt beside this; c/zconf.h is changed, as it says, to have unistd.h.
 */
package minigzip

import os from "std:os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import libc from "../../libc"

/** minigzip's C, minigzip_c's library, which tools/c_libraries.py builds from c/ beside this. */
MINIGZIP_C :: #library("minigzip_c")

/**
 * minigzip's C main (c/minigzip.c).
 *
 * @param argc How many arguments argv has, its name first.
 * @param argv The arguments, then NULL.
 * @return 0 once every file's done; 1 if one couldn't be read, written or decompressed, which it says on stderr.
 */
c_main #foreign(MINIGZIP_C) #link_name("main") : fn(argc : i32, argv : ptr[mut cstring?]) -> i32 : ---

/**
 * Compress or decompress files, as zlib's minigzip.
 *
 * @param arguments What C's minigzip is given after its name: -d to decompress, -c to write to stdout rather than a
 *     file, -1 to -9 for the level, -f, -h or -r for deflate's filtered, Huffman-only or run-length strategy, then the
 *     files, each a path beneath here. Without files, stdin, the terminal's typed lines, to stdout.
 * @param here The shell's directory, given without asking, which the files are beneath.
 * @param console The shell's terminal, given without asking: an error's message.
 * @return 0 once every file's done; 1 if one couldn't be.
 */
main :: fn(arguments : string[]?, here : os.Channel[dir.Dir], console : os.Channel[terminal.Terminal]) -> int {
    given :: arguments or_else string.[]
    return libc.run(libc.Start.{name = "minigzip", arguments = given, here = here, console = console}, c_main)
}
