package arch_aarch64

import arch_interface from "../../arch_interface"

/*
 * What arch_interface declares that AArch64 doesn't implement yet, by the stage that brings it
 * (decisions/0005, 0061; knowledge/roadmap.md, A). The kernel's other code calls them, so they're here as
 * stubs to compile, but the kernel stops before it would (TAKES_INTERRUPTS). Each one stops the CPU. The
 * arch-interface house rule (src/checks) accepts stubs in this file only if they're listed, and fails once
 * one of them is implemented anywhere else, so the list stays true: take a name off, and its stub out,
 * when its stage adds it.
 */
NOT_YET_IMPLEMENTED :: string.[
    // A4: the GICv3, the generic timer's interrupts, and the other CPUs
    "device_interrupt_range", "msi_message", "end_of_interrupt", "send_ipi", "interrupt_pending", "idle",
    "init_interrupt_controller", "route_wired", "mask_wired", "unmask_wired",
    "init_timer", "set_deadline", "cancel_deadline", "test_device", "test_device_interrupts", "test_nmi",
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

device_interrupt_range :: fn() -> (first: arch_interface.InterruptId, count: u32) {
    not_yet("device_interrupt_range")
}

msi_message :: fn(cpu_hardware_id: u64, id: arch_interface.InterruptId) -> arch_interface.MsiMessage {
    not_yet("msi_message")
}

end_of_interrupt :: fn(id: arch_interface.InterruptId) {
    not_yet("end_of_interrupt")
}

send_ipi :: fn(cpu_hardware_id: u64, kind: arch_interface.IpiKind) {
    not_yet("send_ipi")
}

interrupt_pending :: fn() -> bool {
    not_yet("interrupt_pending")
}

idle :: fn() #never_returns {
    not_yet("idle")
}

init_interrupt_controller :: fn(
    controller: ptr[mut InterruptController],
    kind: arch_interface.ControllerKind,
    registers: arch_interface.VirtualAddress,
) -> Result[u32, arch_interface.ControllerError] {
    not_yet("init_interrupt_controller")
}

route_wired :: fn(
    controller: ptr[mut InterruptController],
    line: u32,
    cpu_hardware_id: u64,
    id: arch_interface.InterruptId,
    trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity,
) {
    not_yet("route_wired")
}

mask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    not_yet("mask_wired")
}

unmask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    not_yet("unmask_wired")
}

init_timer :: fn(hint: u64?) -> u64 {
    not_yet("init_timer")
}

set_deadline :: fn(value: u64) {
    not_yet("set_deadline")
}

cancel_deadline :: fn() {
    not_yet("cancel_deadline")
}

test_device :: fn() -> arch_interface.TestDevice {
    not_yet("test_device")
}

test_device_interrupts :: fn(on: bool) {
    not_yet("test_device_interrupts")
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
