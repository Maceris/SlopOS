/**
 * lua (decisions/0202, 21g): Lua 5.4, its own lua.c and the rest of its sources in c/, unchanged, on SlopOS's libc,
 * run from the shell. It runs a script beneath the shell's directory, or -e's code, with Lua's own options; with
 * neither, its interactive prompt on the shell's terminal. Lua's copyright and license are in LICENSE.txt beside this.
 */
package lua

import os from "std:os"
import dir from "std:os/slop_os/dir"
import terminal from "std:os/slop_os/terminal"
import libc from "../../libc"

/** Lua's C, lua_c's library, which tools/c_libraries.py builds from c/ beside this. */
LUA_C :: #library("lua_c")

/**
 * Lua's C main (c/lua.c).
 *
 * @param argc How many arguments argv has, its name first.
 * @param argv The arguments, then NULL.
 * @return 0 once what it was given has run; 1 if a script couldn't be loaded or raised an error that wasn't caught.
 */
c_main #foreign(LUA_C) #link_name("main") : fn(argc : i32, argv : ptr[mut cstring?]) -> i32 : ---

/**
 * The memory Lua asks to run on (decisions/0202, 21f and 21i): 32 MiB, for scripts whose tables and strings outgrow
 * the 4 MiB a program that asks for none is given, and more than the shell's own budget, as it comes out of the
 * session's programs budget.
 */
PROGRAM_MEMORY : u64 : 32 * 1024 * 1024

/**
 * Run Lua, as its own lua does.
 *
 * @param arguments What C's lua is given after its name: its options (-e code, -l module, -i, -v, -E, -W, -), then a
 *     script, a path beneath here, and the script's own arguments, its arg table. Without a script or -e, the prompt.
 * @param here The shell's directory, given without asking, which scripts and the files they open are beneath.
 * @param console The shell's terminal, given without asking: print's and io.write's, an error's message, and the
 *     prompt's typed lines.
 * @return 0 once it's run; 1 for a script that couldn't be loaded or an error nothing caught, its message on the
 *     terminal.
 */
main :: fn(arguments : string[]?, here : os.Channel[dir.Dir], console : os.Channel[terminal.Terminal]) -> int {
    given :: arguments or_else string.[]
    return libc.run(libc.Start.{name = "lua", arguments = given, here = here, console = console}, c_main)
}
