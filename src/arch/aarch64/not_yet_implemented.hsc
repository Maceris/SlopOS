package arch_aarch64

import arch_interface from "../../arch_interface"

/*
 * What arch_interface declares that AArch64 doesn't implement yet (decisions/0005, 0065). The kernel's other code calls them, so they're here as
 * stubs to compile, but nothing the kernel runs on AArch64 reaches them yet. Each one stops the CPU. The
 * arch-interface house rule (src/checks) accepts stubs in this file only if they're listed, and fails once
 * one of them is implemented anywhere else, so the list stays true: take a name off, and its stub out,
 * when its stage adds it.
 */
NOT_YET_IMPLEMENTED :: string.[
    // An NMI needs pseudo-NMIs or FEAT_NMI (decisions/0065)
    "test_nmi",
]

// A stub reached, which the kernel never does on purpose: say which, and stop.
not_yet #never_returns :: fn(name: string) {
    early_console_write("[arch] not on AArch64 yet: ")
    early_console_write(name)
    early_console_write("\n")
    halt()
}

test_nmi :: fn() {
    not_yet("test_nmi")
}

