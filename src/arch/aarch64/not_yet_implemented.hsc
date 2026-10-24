package arch_aarch64

import arch_interface from "../../arch_interface"

/*
 * What arch_interface declares that AArch64 doesn't implement yet, by the stage that brings it
 * (decisions/0005, 0061; knowledge/roadmap.md, A). The kernel's other code calls them, so they're here as
 * stubs to compile, but nothing the kernel runs on AArch64 reaches them yet. Each one stops the CPU. The
 * arch-interface house rule (src/checks) accepts stubs in this file only if they're listed, and fails once
 * one of them is implemented anywhere else, so the list stays true: take a name off, and its stub out,
 * when its stage adds it.
 */
NOT_YET_IMPLEMENTED :: string.[
    // MSI needs the GICv3 ITS, once PCIe devices do; an NMI needs pseudo-NMIs or FEAT_NMI (decisions/0065)
    "msi_message", "test_nmi",
    // A5: user mode and its floating-point and SIMD state
    "init_user_registers", "syscall_number", "syscall_argument", "set_syscall_result", "instruction_pointer",
    "restart_syscall", "user_register_count", "get_user_register", "set_user_register", "return_to_user",
    "vector_state_size", "vector_state_alignment", "init_vector_state", "save_vector_state", "restore_vector_state",
]

// A stub reached, which the kernel never does on purpose: say which, and stop.
not_yet #never_returns :: fn(name: string) {
    early_console_write("[arch] not on AArch64 yet: ")
    early_console_write(name)
    early_console_write("\n")
    halt()
}

msi_message :: fn(cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    not_yet("msi_message")
}

test_nmi :: fn() {
    not_yet("test_nmi")
}

init_user_registers :: fn(registers: ptr[mut UserRegisters], start: ptr[arch_interface.UserStart]) {
    not_yet("init_user_registers")
}

syscall_number :: fn(registers: ptr[UserRegisters]) -> u64 {
    not_yet("syscall_number")
}

syscall_argument :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    not_yet("syscall_argument")
}

set_syscall_result :: fn(registers: ptr[mut UserRegisters], result: ptr[arch_interface.SyscallResult]) {
    not_yet("set_syscall_result")
}

instruction_pointer :: fn(registers: ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    not_yet("instruction_pointer")
}

restart_syscall :: fn(registers: ptr[mut UserRegisters]) {
    not_yet("restart_syscall")
}

user_register_count :: fn() -> u32 {
    not_yet("user_register_count")
}

get_user_register :: fn(registers: ptr[UserRegisters], index: u32) -> u64 {
    not_yet("get_user_register")
}

set_user_register :: fn(registers: ptr[mut UserRegisters], index: u32, value: u64) -> bool {
    not_yet("set_user_register")
}

return_to_user :: fn(registers: ptr[UserRegisters]) #never_returns {
    not_yet("return_to_user")
}

vector_state_size :: fn(config: arch_interface.VectorConfig) -> usize {
    not_yet("vector_state_size")
}

vector_state_alignment :: fn() -> usize {
    not_yet("vector_state_alignment")
}

init_vector_state :: fn(state: ptr[mut VectorState], config: arch_interface.VectorConfig) {
    not_yet("init_vector_state")
}

save_vector_state :: fn(state: ptr[mut VectorState]) {
    not_yet("save_vector_state")
}

restore_vector_state :: fn(state: ptr[VectorState]) {
    not_yet("restore_vector_state")
}
