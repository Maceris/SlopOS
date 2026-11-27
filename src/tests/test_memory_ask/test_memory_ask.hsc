/**
 * A program that asks for more memory than a session has to give its programs (decisions/0202, 21i): its bundle asks
 * for 96 MiB, past the session's programs budget's 48 MiB, so the shell refuses to run it, saying so. Run, it would
 * end with 0.
 */
package test_memory_ask

/** What it asks for to run on, in bytes: 96 MiB. */
PROGRAM_MEMORY : u64 : 96 * 1024 * 1024

/**
 * Do nothing.
 *
 * @return 0.
 */
main :: fn() -> int {
    return 0
}
