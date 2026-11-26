package arch_riscv64

import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"

/**
 * What arch_interface declares that RISC-V doesn't implement yet (decisions/0005, 0199), by name, by the stage of
 * M19 that brings it.
 *
 * The kernel's other code calls them, so they're here as stubs to compile, but the kernel stops before it would
 * (TAKES_INTERRUPTS). Each one stops the hart. The arch-interface house rule (src/checks) accepts stubs in this file
 * only if they're listed, and fails once one of them is implemented anywhere else, so the list stays true: take a
 * name off, and its stub out, when its stage adds it.
 */
NOT_YET_IMPLEMENTED :: string.[
    // R4: the AIA and the PLIC, the timer, the other harts and their IPIs
    "device_interrupt_range",
    "msi_device_memory",
    "msi_controller_memory",
    "init_msi",
    "add_msi_device",
    "remove_msi_device",
    "route_msi",
    "move_msi",
    "unroute_msi",
    "msi_doorbell",
    "end_of_interrupt",
    "send_ipi",
    "idle",
    "init_interrupt_controller",
    "route_wired",
    "mask_wired",
    "unmask_wired",
    "init_timer",
    "set_deadline",
    "cancel_deadline",
    "test_device",
    "test_device_interrupts",
    // R5: user mode, its system calls and debugging, and its floating-point and vector state
    "init_user_registers",
    "syscall_number",
    "syscall_argument",
    "set_syscall_result",
    "instruction_pointer",
    "restart_syscall",
    "user_register_count",
    "get_user_register",
    "set_user_register",
    "set_debug",
    "debug_on",
    "set_counter_trap",
    "emulate_counter_read",
    "debug_off",
    "return_to_user",
    "vector_state_size",
    "vector_state_alignment",
    "init_vector_state",
    "save_vector_state",
    "restore_vector_state",
    // R6: the IOMMU's interrupt remapping, and Zicfilp's and Zicfiss's control-flow integrity
    "route_wired_remapped",
    "load_user_control_flow",
    "read_user_shadow_stack",
    "set_kernel_shadow_stack",
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
 * arch_interface.device_interrupt_range: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and
 * their IPIs, so this stops the hart.
 */
device_interrupt_range :: fn() -> (first : arch_interface.InterruptId, count : u32) {
    not_yet("device_interrupt_range")
}

/**
 * arch_interface.msi_device_memory: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their
 * IPIs, so this stops the hart.
 */
msi_device_memory :: fn() -> u64? {
    not_yet("msi_device_memory")
}

/**
 * arch_interface.msi_controller_memory: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and
 * their IPIs, so this stops the hart.
 */
msi_controller_memory :: fn() -> u64 {
    not_yet("msi_controller_memory")
}

/**
 * arch_interface.init_msi: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs, so
 * this stops the hart.
 */
init_msi :: fn(memory : arch_interface.PhysicalAddress) {
    not_yet("init_msi")
}

/**
 * arch_interface.add_msi_device: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their
 * IPIs, so this stops the hart.
 */
add_msi_device :: fn(source : u32, memory : arch_interface.PhysicalAddress, events : u32) {
    not_yet("add_msi_device")
}

/**
 * arch_interface.remove_msi_device: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their
 * IPIs, so this stops the hart.
 */
remove_msi_device :: fn(source : u32) {
    not_yet("remove_msi_device")
}

/**
 * arch_interface.route_msi: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs, so
 * this stops the hart.
 */
route_msi :: fn(
    source : u32,
    event : u32,
    cpu_hardware_id : u64,
    id : arch_interface.InterruptId
) -> arch_interface.MsiMessage {
    not_yet("route_msi")
}

/**
 * arch_interface.move_msi: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs, so
 * this stops the hart.
 */
move_msi :: fn(
    source : u32,
    event : u32,
    cpu_hardware_id : u64,
    id : arch_interface.InterruptId
) -> arch_interface.MsiMessage {
    not_yet("move_msi")
}

/**
 * arch_interface.unroute_msi: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
unroute_msi :: fn(source : u32, event : u32) {
    not_yet("unroute_msi")
}

/**
 * arch_interface.msi_doorbell: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
msi_doorbell :: fn() -> arch_interface.PhysicalAddress? {
    not_yet("msi_doorbell")
}

/**
 * arch_interface.end_of_interrupt: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their
 * IPIs, so this stops the hart.
 */
end_of_interrupt :: fn(id : arch_interface.InterruptId) {
    not_yet("end_of_interrupt")
}

/**
 * arch_interface.send_ipi: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs, so
 * this stops the hart.
 */
send_ipi :: fn(cpu_hardware_id : u64, kind : arch_interface.IpiKind) {
    not_yet("send_ipi")
}

/**
 * arch_interface.idle: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs, so this
 * stops the hart.
 */
idle #never_returns :: fn() {
    not_yet("idle")
}

/**
 * arch_interface.init_interrupt_controller: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts
 * and their IPIs, so this stops the hart.
 */
init_interrupt_controller :: fn(
    controller : ptr[mut InterruptController],
    kind : arch_interface.ControllerKind,
    registers : arch_interface.VirtualAddress
) -> Result[u32, arch_interface.ControllerError] {
    not_yet("init_interrupt_controller")
}

/**
 * arch_interface.route_wired: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
route_wired :: fn(
    controller : ptr[mut InterruptController],
    line : u32,
    cpu_hardware_id : u64,
    id : arch_interface.InterruptId,
    trigger : arch_interface.Trigger,
    polarity : arch_interface.Polarity
) {
    not_yet("route_wired")
}

/**
 * arch_interface.mask_wired: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
mask_wired :: fn(controller : ptr[mut InterruptController], line : u32) {
    not_yet("mask_wired")
}

/**
 * arch_interface.unmask_wired: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
unmask_wired :: fn(controller : ptr[mut InterruptController], line : u32) {
    not_yet("unmask_wired")
}

/**
 * arch_interface.init_timer: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
init_timer :: fn(hint : u64?) -> u64 {
    not_yet("init_timer")
}

/**
 * arch_interface.set_deadline: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
set_deadline :: fn(value : u64) {
    not_yet("set_deadline")
}

/**
 * arch_interface.cancel_deadline: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their
 * IPIs, so this stops the hart.
 */
cancel_deadline :: fn() {
    not_yet("cancel_deadline")
}

/**
 * arch_interface.test_device: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and their IPIs,
 * so this stops the hart.
 */
test_device :: fn() -> arch_interface.TestDevice {
    not_yet("test_device")
}

/**
 * arch_interface.test_device_interrupts: not on RISC-V until R4: the AIA and the PLIC, the timer, the other harts and
 * their IPIs, so this stops the hart.
 */
test_device_interrupts :: fn(on : bool) {
    not_yet("test_device_interrupts")
}

/**
 * arch_interface.init_user_registers: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
init_user_registers :: fn(registers : ptr[mut UserRegisters], start : ptr[arch_interface.UserStart]) {
    not_yet("init_user_registers")
}

/**
 * arch_interface.syscall_number: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
syscall_number :: fn(registers : ptr[UserRegisters]) -> u64 {
    not_yet("syscall_number")
}

/**
 * arch_interface.syscall_argument: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
syscall_argument :: fn(registers : ptr[UserRegisters], index : u32) -> u64 {
    not_yet("syscall_argument")
}

/**
 * arch_interface.set_syscall_result: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
set_syscall_result :: fn(registers : ptr[mut UserRegisters], result : ptr[arch_interface.SyscallResult]) {
    not_yet("set_syscall_result")
}

/**
 * arch_interface.instruction_pointer: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
instruction_pointer :: fn(registers : ptr[UserRegisters]) -> arch_interface.VirtualAddress {
    not_yet("instruction_pointer")
}

/**
 * arch_interface.restart_syscall: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
restart_syscall :: fn(registers : ptr[mut UserRegisters]) {
    not_yet("restart_syscall")
}

/**
 * arch_interface.user_register_count: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
user_register_count :: fn() -> u32 {
    not_yet("user_register_count")
}

/**
 * arch_interface.get_user_register: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
get_user_register :: fn(registers : ptr[UserRegisters], index : u32) -> u64 {
    not_yet("get_user_register")
}

/**
 * arch_interface.set_user_register: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
set_user_register :: fn(registers : ptr[mut UserRegisters], index : u32, value : u64) -> bool {
    not_yet("set_user_register")
}

/**
 * arch_interface.set_debug: not on RISC-V until R5: user mode, its system calls and debugging, and its floating-point
 * and vector state, so this stops the hart.
 */
set_debug :: fn(
    debug : ptr[mut DebugRegisters],
    registers : ptr[mut UserRegisters],
    step : bool,
    slots : slop_os.DebugSlot[]
) -> bool {
    not_yet("set_debug")
}

/**
 * arch_interface.debug_on: not on RISC-V until R5: user mode, its system calls and debugging, and its floating-point
 * and vector state, so this stops the hart.
 */
debug_on :: fn(debug : ptr[DebugRegisters], registers : ptr[mut UserRegisters]) {
    not_yet("debug_on")
}

/**
 * arch_interface.set_counter_trap: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
set_counter_trap :: fn(trapped : bool) {
    not_yet("set_counter_trap")
}

/**
 * arch_interface.emulate_counter_read: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
emulate_counter_read :: fn(registers : ptr[mut UserRegisters], instruction : u32) -> u64? {
    not_yet("emulate_counter_read")
}

/**
 * arch_interface.debug_off: not on RISC-V until R5: user mode, its system calls and debugging, and its floating-point
 * and vector state, so this stops the hart.
 */
debug_off :: fn() {
    not_yet("debug_off")
}

/**
 * arch_interface.return_to_user: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
return_to_user #never_returns :: fn(registers : ptr[UserRegisters]) {
    not_yet("return_to_user")
}

/**
 * arch_interface.vector_state_size: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
vector_state_size :: fn(config : arch_interface.VectorConfig) -> usize {
    not_yet("vector_state_size")
}

/**
 * arch_interface.vector_state_alignment: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
vector_state_alignment :: fn() -> usize {
    not_yet("vector_state_alignment")
}

/**
 * arch_interface.init_vector_state: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
init_vector_state :: fn(state : ptr[mut VectorState], config : arch_interface.VectorConfig) {
    not_yet("init_vector_state")
}

/**
 * arch_interface.save_vector_state: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
save_vector_state :: fn(state : ptr[mut VectorState]) {
    not_yet("save_vector_state")
}

/**
 * arch_interface.restore_vector_state: not on RISC-V until R5: user mode, its system calls and debugging, and its
 * floating-point and vector state, so this stops the hart.
 */
restore_vector_state :: fn(state : ptr[VectorState]) {
    not_yet("restore_vector_state")
}

/**
 * arch_interface.route_wired_remapped: not on RISC-V until R6: the IOMMU's interrupt remapping, and Zicfilp's and
 * Zicfiss's control-flow integrity, so this stops the hart.
 */
route_wired_remapped :: fn(
    controller : ptr[mut InterruptController],
    line : u32,
    message : arch_interface.MsiMessage,
    id : arch_interface.InterruptId,
    trigger : arch_interface.Trigger,
    polarity : arch_interface.Polarity
) {
    not_yet("route_wired_remapped")
}

/**
 * arch_interface.load_user_control_flow: not on RISC-V until R6: the IOMMU's interrupt remapping, and Zicfilp's and
 * Zicfiss's control-flow integrity, so this stops the hart.
 */
load_user_control_flow :: fn(landing_pads : bool, shadow_stack : u64) {
    not_yet("load_user_control_flow")
}

/**
 * arch_interface.read_user_shadow_stack: not on RISC-V until R6: the IOMMU's interrupt remapping, and Zicfilp's and
 * Zicfiss's control-flow integrity, so this stops the hart.
 */
read_user_shadow_stack :: fn() -> u64 {
    not_yet("read_user_shadow_stack")
}

/**
 * arch_interface.set_kernel_shadow_stack: not on RISC-V until R6: the IOMMU's interrupt remapping, and Zicfilp's and
 * Zicfiss's control-flow integrity, so this stops the hart.
 */
set_kernel_shadow_stack :: fn(cpu : ptr[mut ArchCpu], base : u64, size : u64) {
    not_yet("set_kernel_shadow_stack")
}

/**
 * arch_interface.test_nmi: an NMI, which RISC-V's supervisor doesn't have (Smrnmi's are the machine's), so this stops
 * the hart.
 */
test_nmi :: fn() {
    not_yet("test_nmi")
}
