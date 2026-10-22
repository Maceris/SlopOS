package arch_x86_64

/*
 * What arch_interface declares that x86-64 doesn't implement yet, by the milestone that brings it
 * (decisions/0005: missing parts are listed, knowledge/roadmap.md). The arch-interface house rule
 * (src/checks) accepts these as missing, and fails once one of them is implemented, so the list stays
 * true: take a name off when its milestone adds it.
 */
NOT_YET_IMPLEMENTED :: string.[
    // M3: wired interrupts
    "InterruptController", "init_interrupt_controller", "route_wired", "mask_wired", "unmask_wired",
    // M4 to M6: threads' vector state, and user mode
    "VectorState", "vector_state_size", "vector_state_alignment", "init_vector_state", "save_vector_state",
    "restore_vector_state", "init_user_registers", "syscall_number", "syscall_argument", "set_syscall_result",
    "instruction_pointer", "return_to_user",
]
