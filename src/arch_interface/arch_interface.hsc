/*
 * The arch interface: what every architecture package (L1) implements and the kernel core (L2)
 * calls. Specified in docs/specs/arch_interface.md, with its rules for L2.
 *
 * Functions here are declarations only (---). The kernel imports one architecture package as
 * arch, which defines each of them with the same signature, and the per-architecture types
 * (the empty structs) under the same names.
 */
package arch_interface

import runtime from "base"
import boot_info from "../boot_info"
// The system ABI's types, like CpuFeatures (0019)
import slop_os from "std/os"

PhysicalAddress :: boot_info.PhysicalAddress
VirtualAddress :: boot_info.VirtualAddress

// User-mode registers saved at kernel entry: general registers, instruction and stack
// pointers, flags.
UserRegisters :: struct {}

// Vector and floating-point state of one thread. Its size depends on VectorConfig, so L2
// allocates it separately, with vector_state_size and vector_state_alignment.
VectorState :: struct {}

// One CPU's architecture state, like x86-64's GDT and TSS. Must not move after init_cpu.
ArchCpu :: struct {}

// State shared by every CPU, like x86-64's IDT. Must not move after init_system.
ArchSystem :: struct {}

// One address space's page-table root and address-space tag.
PageTable :: struct {}

// One wired interrupt controller the platform service registered (0039), like an I/O APIC.
InterruptController :: struct {}

// Where a stack is: low is its lowest address, high one past its highest.
StackRange :: struct {
    low : VirtualAddress,
    high : VirtualAddress,
}

// Separate stacks for events that can arrive at any time, including in the kernel.
CriticalEvent :: enum #backed_by(u8) {
    Nmi,
    DoubleFault,
    MachineCheck,
}

CpuStacks :: struct {
    // Where entries from user mode and from idle run.
    kernel : StackRange,
    // Indexed by CriticalEvent. Architectures without separate stacks for an event ignore its entry.
    critical : StackRange[3],
}

// The CPU's features, read once on the boot CPU. CpuFeatures is defined with the system ABI (0019).
detect_features : fn() -> slop_os.CpuFeatures : ---

// The first baseline feature the CPU lacks (x86-64-v3 on x86-64, 0003), or null.
missing_baseline_feature : fn(features: ptr[slop_os.CpuFeatures]) -> string? : ---

/*
 * Set up the state shared by every CPU. Called once, on the boot CPU, before init_cpu, with the firmware's
 * tables, reached through the bootloader's direct map, for what the architecture finds in them, like
 * AArch64's interrupt controller in the device tree.
 */
init_system : fn(system: ptr[mut ArchSystem], firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) : ---

/*
 * Set up the calling CPU: descriptor tables, entry points, the stacks entries use,
 * user-access protection, no-execute, address-space tags, and the default vector state.
 * Records carrier and context in cpu, and cpu in the architecture's per-CPU register
 * (x86-64: IA32_KERNEL_GS_BASE; AArch64: TPIDR_EL1; RISC-V: sscratch), for entry stubs.
 * Keeping carrier and context makes them #escaping (Hemera's docs/memory.md).
 */
init_cpu : fn(
    system: ptr[ArchSystem],
    cpu: ptr[mut ArchCpu],
    carrier #escaping : ptr[mut runtime.CarrierBlock],
    context #escaping : ptr[runtime.Context],
    stacks: ptr[CpuStacks],
) : ---

// W^X: a mapping is never both writable and executable.
Protection :: enum #backed_by(u8) {
    Read,
    ReadWrite,
    ReadExecute,
}

CacheMode :: enum #backed_by(u8) {
    WriteBack,
    WriteCombining,
    // Uncached and strongly ordered, for device registers.
    Device,
}

Mapping :: struct {
    protection : Protection,
    cache : CacheMode,
    // Accessible from user mode. Kernel mappings never are.
    user : bool,
    // Kept in the TLB across address-space switches. Kernel mappings only.
    global : bool,
}

PageSize :: enum #backed_by(u8) {
    Size4K,
    Size2M,
    Size1G,
}

// Distinguishes address spaces in the TLB (x86-64 PCID, AArch64 ASID, RISC-V ASID).
AddressSpaceTag :: distinct alias u16

// Zeroed frames L2 provides for new page-table levels. map takes frames from the end.
TableFrames :: struct {
    count : u32,
    frames : PhysicalAddress[4],
}

// Page-table frames a call emptied. L2 frees them once no CPU can still use them.
FreedTables :: struct {
    count : u32,
    frames : PhysicalAddress[4],
}

// TLB entries to flush. Once full, or with all set, it covers the whole tag.
TlbBatch :: struct {
    tag : AddressSpaceTag,
    all : bool,
    count : u32,
    addresses : VirtualAddress[16],
}

MapError :: enum #backed_by(u8) {
    // tables ran out. Refill it and call again; nothing was changed.
    NeedTableFrames,
    // Something is already mapped there.
    AlreadyMapped,
    // Not aligned to the page size, or outside the range for user or kernel mappings.
    InvalidAddress,
    // The CPU doesn't support this page size.
    UnsupportedPageSize,
}

UnmapError :: enum #backed_by(u8) {
    NotMapped,
    // The range covers part of a larger page.
    PartOfLargerPage,
    // freed is full. Empty it and call again; nothing was changed.
    NeedFreedSpace,
}

// The lowest and one past the highest user-mode address.
user_address_range : fn() -> (low, high: VirtualAddress) : ---

// Number of address-space tags the CPU supports. 1 means tags aren't supported.
address_space_tag_count : fn() -> u32 : ---

// Page sizes the CPU supports.
supports_page_size : fn(size: PageSize) -> bool : ---

/*
 * How many zeroed frames the kernel's own table needs besides its root: tables for the whole kernel
 * half, made up front so every address space shares it as it grows (x86-64: 256, one per top-level
 * entry). 0 where the kernel half has a root of its own (AArch64's TTBR1).
 */
kernel_half_frames : fn() -> u32 : ---

/*
 * Make table the kernel's own address space, which maps the kernel half and nothing else. root is a
 * zeroed frame, and half the first of kernel_half_frames() contiguous zeroed frames. Tables are
 * reached through the direct map at direct_map_offset.
 */
init_kernel_page_table : fn(
    table: ptr[mut PageTable],
    root: PhysicalAddress,
    half: PhysicalAddress,
    tag: AddressSpaceTag,
    direct_map_offset: u64,
) : ---

/*
 * Make table an address space whose top-level table is root, a zeroed frame, sharing kernel's
 * kernel half. It maps user addresses only.
 */
init_page_table : fn(
    table: ptr[mut PageTable],
    root: PhysicalAddress,
    tag: AddressSpaceTag,
    kernel: ptr[PageTable],
) : ---

map : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    size: PageSize,
    mapping: Mapping,
    tables: ptr[mut TableFrames],
) -> Result[void, MapError] : ---

// Unmap one page, returning its physical address. flush and freed cover one table.
unmap : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    size: PageSize,
    freed: ptr[mut FreedTables],
    flush: ptr[mut TlbBatch],
) -> Result[PhysicalAddress, UnmapError] : ---

protect : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    size: PageSize,
    mapping: Mapping,
    flush: ptr[mut TlbBatch],
) -> Result[void, UnmapError] : ---

Translation :: struct {
    physical_address : PhysicalAddress,
    mapping : Mapping,
}

/*
 * Free an address space's tables before its root is freed: as many as freed has room for each call, true
 * once only the root is left. What they mapped isn't touched. L2 frees them, and the root, once no CPU can
 * still use them.
 */
release_user_tables : fn(table: ptr[mut PageTable], freed: ptr[mut FreedTables]) -> bool : ---

// Where virtual_address is mapped, or null if nothing is mapped there.
translate : fn(table: ptr[PageTable], virtual_address: VirtualAddress) -> Translation? : ---

// Switch the calling CPU to table. The first switch from the bootloader's tables flushes the whole TLB.
activate : fn(table: ptr[PageTable]) : ---

// Flush batch from the calling CPU's TLB.
flush_tlb : fn(batch: ptr[TlbBatch]) : ---

// Flush every non-global entry for tag, before the tag is reused.
flush_tlb_tag : fn(tag: AddressSpaceTag) : ---

// An interrupt the CPU can receive, local to each CPU.
InterruptId :: distinct alias u32

IpiKind :: enum #backed_by(u8) {
    // Run the scheduler: a higher-priority thread became runnable.
    Reschedule,
    // Flush TLB entries L2 queued for this CPU.
    TlbFlush,
    // Stop this CPU (panic or shutdown).
    Stop,
}

// What a device writes, and where, to raise a message-signaled interrupt (PCIe MSI and MSI-X).
MsiMessage :: struct {
    address : u64,
    data : u32,
}

// The IDs L2 may give to devices.
device_interrupt_range : fn() -> (first: InterruptId, count: u32) : ---

// The message a device sends to raise id on the CPU with this hardware ID.
msi_message : fn(cpu_hardware_id: u64, id: InterruptId) -> MsiMessage : ---

// Acknowledge id to the interrupt controller.
end_of_interrupt : fn(id: InterruptId) : ---

send_ipi : fn(cpu_hardware_id: u64, kind: IpiKind) : ---

// Whether an interrupt is waiting, for preemption points. Interrupts stay disabled.
interrupt_pending : fn() -> bool : ---

// Wait for an interrupt with interrupts enabled. The interrupt enters
// kernel_entry.interrupt with from = .Idle.
idle #never_returns : fn() : ---

// Kinds of wired interrupt controller. An architecture supports only some of them.
ControllerKind :: enum #backed_by(u8) {
    // x86-64
    IoApic,
    // AArch64: a GIC distributor's shared peripheral interrupts
    GicDistributor,
    // RISC-V
    Plic,
    Aplic,
}

Trigger :: enum #backed_by(u8) {
    Edge,
    Level,
}

Polarity :: enum #backed_by(u8) {
    ActiveHigh,
    ActiveLow,
}

ControllerError :: enum #backed_by(u8) {
    // This architecture doesn't support the kind.
    UnsupportedKind,
    // The registers don't identify a controller of that kind.
    NotFound,
}

/*
 * Set up a controller whose registers L2 mapped at registers, with every line masked.
 * Returns how many lines it has.
 */
init_interrupt_controller : fn(
    controller: ptr[mut InterruptController],
    kind: ControllerKind,
    registers: VirtualAddress,
) -> Result[u32, ControllerError] : ---

// Deliver line as id on the CPU with this hardware ID, still masked.
route_wired : fn(
    controller: ptr[mut InterruptController],
    line: u32,
    cpu_hardware_id: u64,
    id: InterruptId,
    trigger: Trigger,
    polarity: Polarity,
) : ---

mask_wired : fn(controller: ptr[mut InterruptController], line: u32) : ---
unmask_wired : fn(controller: ptr[mut InterruptController], line: u32) : ---

// Calibrate the counter and start the timer. hint is BootInfo.counter_frequency_hint.
// Returns the counter's frequency in Hz.
init_timer : fn(hint: u64?) -> u64 : ---

counter : fn() -> u64 : ---

// Raise a timer interrupt on the calling CPU once counter() reaches value.
set_deadline : fn(value: u64) : ---

cancel_deadline : fn() : ---

UserStart :: struct {
    instruction_pointer : VirtualAddress,
    stack_pointer : VirtualAddress,
    // Goes in the first argument register (0026).
    argument : u64,
}

// The result of a system call, in the system ABI's result registers.
SyscallResult :: struct {
    // 0 for success, otherwise the error variant's tag.
    tag : u64,
    values : u64[2],
}

// Whether a thread uses the architecture's largest vector state (AVX-512, 0023).
VectorConfig :: struct {
    extended : bool,
}

// Registers for a new thread. Every other register is zero, so no kernel value leaks (0026).
init_user_registers : fn(registers: ptr[mut UserRegisters], start: ptr[UserStart]) : ---

syscall_number : fn(registers: ptr[UserRegisters]) -> u64 : ---
syscall_argument : fn(registers: ptr[UserRegisters], index: u32) -> u64 : ---
set_syscall_result : fn(registers: ptr[mut UserRegisters], result: ptr[SyscallResult]) : ---
instruction_pointer : fn(registers: ptr[UserRegisters]) -> VirtualAddress : ---

/*
 * Back to the system call instruction, so returning to user mode makes the call again: how a call a
 * debugger stopped at its entry runs once it's let go (knowledge/design/kernel.md §4).
 */
restart_syscall : fn(registers: ptr[mut UserRegisters]) : ---

/*
 * A thread's registers as a debugger sees them, by index, in the order the system ABI gives for this
 * architecture (slop_os.THREAD_REGISTERS): how many, one, and one set. Setting refuses a value user mode
 * can't have (an instruction or stack pointer outside user addresses), and keeps the flags user mode
 * can't change.
 */
user_register_count : fn() -> u32 : ---
get_user_register : fn(registers: ptr[UserRegisters], index: u32) -> u64 : ---
set_user_register : fn(registers: ptr[mut UserRegisters], index: u32, value: u64) -> bool : ---

// Return to user mode with registers, on the calling CPU's active page table.
return_to_user #never_returns : fn(registers: ptr[UserRegisters]) : ---

vector_state_size : fn(config: VectorConfig) -> usize : ---
vector_state_alignment : fn() -> usize : ---
init_vector_state : fn(state: ptr[mut VectorState], config: VectorConfig) : ---

// Save the calling CPU's vector registers into state.
save_vector_state : fn(state: ptr[mut VectorState]) : ---

// Load state into the calling CPU's vector registers, switching which state components are
// enabled if its VectorConfig differs from the last one loaded.
restore_vector_state : fn(state: ptr[VectorState]) : ---

Access :: enum #backed_by(u8) {
    Read,
    Write,
    Execute,
}

PageFault :: struct {
    address : VirtualAddress,
    access : Access,
    // A mapping exists, and the access broke its protection.
    present : bool,
}

Fault :: union {
    Page(PageFault),
    InvalidInstruction,
    Breakpoint,
    SingleStep,
    // Integer division by zero or overflow, where the architecture traps on it.
    Arithmetic,
    Alignment,
    // A privileged instruction, or an address the architecture rejects outright.
    Protection,
    FloatingPoint,
}

// Stop the calling CPU for good, with interrupts disabled.
halt #never_returns : fn() : ---

// Hint that the caller is spinning.
spin_hint : fn() : ---

/*
 * Stop the calling CPU taking interrupts (NMIs still arrive), and start again. Code running fibers
 * masks them: while a fiber resumes, its stack holds live frames above the stack pointer, which an
 * interrupt taken on that stack would overwrite (Hemera's docs/calling_convention.md).
 */
mask_interrupts : fn() : ---
unmask_interrupts : fn() : ---

// One value from the CPU's random source (RDSEED, RNDR, Zkr seed), or null if it has none or
// it failed.
hardware_entropy : fn() -> u64? : ---

/*
 * Set up the architecture's early console. Called once, by L0, before anything is written to it, with the
 * bootloader's direct map at direct_map_offset, through which a console in memory-mapped registers (AArch64's
 * PL011) is reached, in the bootloader's tables and then in the kernel's own (init_kernel_page_table), and the
 * firmware's tables, which say where it is.
 */
early_console_init : fn(direct_map_offset: u64, firmware: ptr[boot_info.FirmwareTables]) : ---

// Write to the architecture's early console, before any driver exists.
early_console_write : fn(text: string) : ---

/*
 * Ask the emulator the kernel runs in to exit with code, for tests that boot the kernel. Only
 * called when the command line asks for it (test_exit), since on real hardware the device it
 * writes to may be something else entirely.
 */
test_exit : fn(code: u32) : ---

/*
 * Raise an NMI on the calling CPU, for tests of the critical-event entry that resumes what it
 * interrupted. Only called when the command line asks for it (test_nmi).
 */
test_nmi : fn() : ---

// A device the emulator always has that raises a wired interrupt: its controller, and its line there.
TestDevice :: struct {
    kind : ControllerKind,
    registers : PhysicalAddress,
    line : u32,
    trigger : Trigger,
    polarity : Polarity,
}

/*
 * Where the emulator's test device is, for tests that route a wired interrupt (test_ioapic). On real
 * hardware the platform service finds controllers in the firmware tables instead.
 */
test_device : fn() -> TestDevice : ---

// Start or stop the test device's interrupts, about a thousand a second. Only for test_ioapic.
test_device_interrupts : fn(on: bool) : ---
