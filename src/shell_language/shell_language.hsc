/**
 * The shell's language (design/shell.md §2, decisions/0169 to 0172) without the shell: its syntax parsed to a tree,
 * its typed values and how they're rendered, the names a scope binds, arithmetic that says when it overflows, bare
 * words read by a type, the built-in stages' sorting and grouping, and values written and read as a manifest's types
 * lay them out. Nothing here runs a program or makes a system call, so it's tested on the host.
 */
package shell_language
