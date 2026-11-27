package arch_riscv64

import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"

/**
 * What arch_interface declares that RISC-V doesn't implement yet (decisions/0005, 0199), by name, by the stage of
 * M19 that brings it.
 *
 * The kernel's other code calls them, so they're here as stubs to compile, but nothing the kernel runs on RISC-V
 * reaches them yet. Each one stops the hart. The arch-interface house rule accepts stubs
 * here only if they're listed, and fails once one of them is implemented anywhere else, so the list stays true: take a
 * name off, and its stub out, when its stage adds it.
 */
NOT_YET_IMPLEMENTED :: string.[
    // An NMI, which RISC-V's supervisor doesn't have (Smrnmi's are the machine's)
    "test_nmi"
]

/**
 * Report a stub reached, which the kernel never does on purpose, on the early console, and stop the hart.
 *
 * @param name The stub's name, one of NOT_YET_IMPLEMENTED's.
 */
not_yet #never_returns :: fn(name : string) {
    early_console_write("[arch] not on RISC-V yet: ")
    early_console_write(name)
    early_console_write("\n")
    halt()
}

/**
 * arch_interface.test_nmi: an NMI, which RISC-V's supervisor doesn't have (Smrnmi's are the machine's), so this stops
 * the hart.
 */
test_nmi :: fn() {
    not_yet("test_nmi")
}
