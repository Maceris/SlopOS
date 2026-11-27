# Arch Interface

The arch interface is the boundary between the arch layer (L1) and the kernel core (L2)
(`../architecture/layers.md`). It runs in both directions:
- **`arch_interface`**: what every architecture package implements and L2 calls (CPU setup,
  paging, interrupts, the timer, user state).
- **`kernel_entry`**: what L2 implements and L1's entry stubs call (system calls, faults,
  interrupts).

Status: **specified**, and implemented on x86-64 (`src/arch/x86_64`): CPU setup, interrupts, the timer
and the miscellaneous functions (roadmap M1), paging (M2), wired interrupts (M3), and user and vector
state (M4). On AArch64 (`src/arch/aarch64`): CPU setup, entry, paging and the miscellaneous functions
(roadmap A3), interrupts, wired interrupts and the timer (A4), user and vector state (A5), and MSIs through the
GICv3's ITS (M7); an NMI comes later. On RISC-V (`src/arch/riscv64`): CPU setup, entry, paging and the miscellaneous
functions (M19's R3), and interrupts, wired interrupts, MSIs and the timer, on the PLIC and on the AIA (R4); user and
vector state come with R5. Choices and alternatives are in
`../../knowledge/decisions/0032-arch-interface.md`. Four-digit numbers like `0023` refer
to decision records in `../../knowledge/decisions/`.

The interface is internal to the kernel image. It changes together with every architecture
package, in one change, and carries no version number.

## Conformance


The kernel imports one architecture package as `arch` (`../architecture/layers.md`, L1). A
house-rule check registered by the build (`0029`) verifies that the package:
- defines every function declared in `arch_interface`, with a body and an identical signature;
- defines every **per-architecture type** (below) under the same name, as a struct.

Per-architecture types are the empty structs in `arch_interface`. When comparing signatures, one
of them matches the architecture package's type of the same name. Every other type must be
identical, so architecture packages write portable types by `arch_interface`'s own names
(`arch_interface.PhysicalAddress`, not `boot_info.PhysicalAddress`, since every alias is a
distinct type value).

Functions that never return are marked `#never_returns`, which is part of their type, so the
check compares it like the rest of the signature.

## Rules for L2

These rules are what keep the interface small.

- **The kernel runs with interrupts disabled.** They're enabled only while a CPU is idle (`idle`). An NMI still
  reaches it: x86-64's, or on AArch64 a pseudo-NMI, an SGI whose priority alone passes the GIC's priority mask, which
  is how AArch64 masks interrupts in the kernel (`0185`).
  Long operations reach preemption points (`0023`), which check `interrupt_pending` and, if one
  is pending, record a continuation and go back to the scheduler. So every interrupt arrives
  from user mode or from idle, and no handler ever returns into kernel code. The only
  exceptions are the critical events (NMI, machine check, double fault), which can arrive at
  any time.
- **The kernel never accesses memory through a user address.** To read or write user memory,
  it translates the address in the address space's page table (`translate`) and uses the
  direct map. A kernel access can therefore never fault on user memory, so the arch layer keeps
  user-access protection (x86-64 SMAP, AArch64 PAN, RISC-V `sstatus.SUM` clear) on permanently
  and needs no fault recovery.
- **L1 acknowledges local interrupts itself.** Entry stubs acknowledge the timer and IPIs before
  calling `kernel_entry.interrupt`; L2 acknowledges device interrupts with `end_of_interrupt`, once
  it has masked a level-triggered line.
- **L1 never allocates.** Memory for page tables, stacks, vector state and the per-architecture
  types comes from L2.
- **L1 holds no policy and no global state.** Its state lives in `ArchSystem` and `ArchCpu`,
  which L2 embeds in its own `Kernel` and `PerCpu` blocks.
- **Each page table is changed by one CPU at a time.** L2 serializes calls on the same
  `PageTable`. TLB shootdown across CPUs is L2's job, using `send_ipi` and `flush_tlb`.

## `arch_interface`

```
package arch_interface

import runtime from "base:runtime"
import boot_info from "../boot_info"
// The system ABI's types, like CpuFeatures (0019). Not yet specified.
import abi from "../abi"

PhysicalAddress :: boot_info.PhysicalAddress
VirtualAddress :: boot_info.VirtualAddress
```

### Per-Architecture Types

Declared here as empty structs, and defined by every architecture package under the same name.
L2 stores them and passes pointers to them, but never reads their fields. L2 may use
`size_of` and `align_of` on them, since the architecture package is known at compile time.

```
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
```

### CPU Setup

```
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

/*
 * The CPU's features, read once on the boot CPU, before init_system. CpuFeatures is defined with the system ABI
 * (0019). The firmware's tables, through the direct map, are for an architecture whose CPUs say what they have only
 * there, like RISC-V's device tree.
 */
detect_features : fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> abi.CpuFeatures : ---

// The first baseline feature the CPU lacks (x86-64-v3 on x86-64, 0003), or null.
missing_baseline_feature : fn(features: ptr[abi.CpuFeatures]) -> string? : ---

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
 * (x86-64: the gs base while in the kernel; AArch64: TPIDR_EL1; RISC-V: tp, and sscratch in user mode), for entry stubs.
 */
// hardware_id is the CPU's BootCpu.hardware_id, for an architecture whose CPUs can't read their own (RISC-V's harts).
init_cpu : fn(
    system: ptr[ArchSystem],
    cpu: ptr[mut ArchCpu],
    hardware_id: u64,
    carrier: ptr[mut runtime.CarrierBlock],
    context: ptr[runtime.Context],
    stacks: ptr[CpuStacks],
) : ---
```

### Paging

```
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
```

### Interrupts

```
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

/*
 * Message-signaled interrupts (0073). A device's are known to the interrupt controller by its source (on
 * AArch64, the ITS's device ID; unused on x86-64), and each of them by an event, from 0. The bytes of memory the
 * controller keeps for each device's (an ITS's translation table), 0 for none; null if it takes no MSIs at all.
 */
msi_device_memory : fn() -> u64? : ---

// Bytes of memory the interrupt controller needs for MSIs at all, asked once every CPU has started; 0 for none.
msi_controller_memory : fn() -> u64 : ---

// MSIs set up, with msi_controller_memory's bytes, zeroed and contiguous, aligned to their size rounded up to a power of two.
init_msi : fn(memory: PhysicalAddress) : ---

// A device's MSIs, known as source, up to events of them, with memory, msi_device_memory's bytes, zeroed and contiguous.
add_msi_device : fn(source: u32, memory: PhysicalAddress, events: u32) : ---

// The device's MSIs forgotten, every event of them.
remove_msi_device : fn(source: u32) : ---

// Source's event, delivered as id to the CPU with this hardware ID: the message the device sends to raise it.
route_msi : fn(source: u32, event: u32, cpu_hardware_id: u64, id: InterruptId) -> MsiMessage : ---

// Source's event no longer delivered.
unroute_msi : fn(source: u32, event: u32) : ---

// The pages msi_doorbell gives: the first's physical address, 4 KiB aligned, and how many, at least 1.
MsiDoorbell :: struct { address: PhysicalAddress, pages: u32 }

/*
 * The pages devices write their MSIs to as memory, which an IOMMU translating their DMA must map into each of their
 * domains, at their own addresses, for the MSIs to arrive (AArch64: the ITS's GITS_TRANSLATER's page; RISC-V: the
 * IMSIC's supervisor interrupt files, from the lowest hart's to the highest's); null where MSIs aren't DMA an IOMMU
 * translates (x86-64, whose interrupt range VT-d takes as interrupts, and RISC-V with a PLIC).
 */
msi_doorbell : fn() -> MsiDoorbell? : ---

// Acknowledge id to the interrupt controller.
end_of_interrupt : fn(id: InterruptId) : ---

send_ipi : fn(cpu_hardware_id: u64, kind: IpiKind) : ---

// Whether an interrupt is waiting, for preemption points. Interrupts stay disabled.
interrupt_pending : fn() -> bool : ---

// Wait for an interrupt with interrupts enabled. The interrupt enters
// kernel_entry.interrupt with from = .Idle.
idle #never_returns : fn() : ---
```

### Wired Interrupts

Interrupt lines on controllers the platform service describes to the kernel (`0039`). L2 maps each
controller's registers, picks an `InterruptId` and a CPU for each line, and keeps a level-triggered
line masked from its interrupt until its driver acknowledges it.

```
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

/*
 * Deliver line through an IOMMU's interrupt remapping, still masked: its entry names the remapped interrupt message
 * gives, which delivers id (decisions/0182). x86-64's I/O APIC writes the remappable format, the handle from the
 * message and id as the vector, so a level-triggered line's EOI reaches it; AArch64's GIC, which no IOMMU remaps, does
 * nothing.
 */
route_wired_remapped : fn(
    controller: ptr[mut InterruptController],
    line: u32,
    message: MsiMessage,
    id: InterruptId,
    trigger: Trigger,
    polarity: Polarity,
) : ---

mask_wired : fn(controller: ptr[mut InterruptController], line: u32) : ---
unmask_wired : fn(controller: ptr[mut InterruptController], line: u32) : ---
```

### Timer

Each CPU has a counter and a one-shot deadline in counter units. L2 turns counter values into
`runtime.Instant`.

```
// Calibrate the counter and start the timer. hint is BootInfo.counter_frequency_hint.
// Returns the counter's frequency in Hz.
init_timer : fn(hint: u64?) -> u64 : ---

counter : fn() -> u64 : ---

// Raise a timer interrupt on the calling CPU once counter() reaches value.
set_deadline : fn(value: u64) : ---

cancel_deadline : fn() : ---
```

### User State

```
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
```

### Faults

```
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
```

### Miscellaneous

```
// Stop the calling CPU for good, with interrupts disabled.
halt #never_returns : fn() : ---

// Hint that the caller is spinning.
spin_hint : fn() : ---

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
 * Choose how the machine resets and turns off, once, at boot, from the firmware's tables: a method, opaque to L2,
 * which passes it back to reset, can_power_off and power_off; 0 where there's none.
 */
reset_method : fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> u8 : ---

// Reset the machine, warm, keeping RAM where the hardware does; returns only if it didn't reset.
reset : fn(method: u8) : ---

/*
 * Whether power_off turns the machine off by itself (decisions/0182); where it doesn't, L2 turns it off through the
 * registers it's told (power_set_off).
 */
can_power_off : fn(method: u8) -> bool : ---

// Turn the machine off by the architecture's own means; returns only if it didn't turn off.
power_off : fn(method: u8) : ---

/*
 * Raise an NMI on the calling CPU, for tests of the critical-event entry that resumes what it
 * interrupted. Only called when the command line asks for it (test_nmi).
 */
test_nmi : fn() : ---

/*
 * Send another CPU an NMI, for lockup detection (decisions/0183), which interrupts it even with interrupts off.
 * Returns false where the architecture has none to send.
 */
send_nmi : fn(cpu_hardware_id: u64) -> bool : ---

// Name a register of those the NMI entry passes kernel_entry.nmi, for a lockup's report (0185); "?" past them.
nmi_register_name : fn(index: usize) -> string : ---

// Log, once at boot, the CPU's control-flow integrity mechanisms, the transient-execution issues that apply to it,
// and the mitigations on (0186, 0097).
log_hardening : fn(features: ptr[slop_os.CpuFeatures]) : ---

/*
 * Hardware control-flow integrity (0186). Pointer authentication keys, the kernel's once at boot and each thread's
 * process's before it returns to user mode, loaded where no frame signed before returns; ignored without it.
 */
set_kernel_pointer_key : fn(system: ptr[mut ArchSystem], key: u64[2]) : ---
set_user_pointer_key : fn(key: u64[2]) : ---

// Whether user threads can have shadow stacks; then each thread's, loaded as it returns and read as it enters.
has_user_shadow_stacks : fn() -> bool : ---
load_user_control_flow : fn(landing_pads: bool, shadow_stack: u64) : ---
read_user_shadow_stack : fn() -> u64 : ---

/*
 * The kernel's own: whether its stacks have shadow stacks, which L2 maps in the kernel window and gives each CPU
 * before it first goes idle; and what it runs under now, for test_tamper, test_branch and test_shadow_write.
 */
has_kernel_shadow_stacks : fn() -> bool : ---
set_kernel_shadow_stack : fn(cpu: ptr[mut ArchCpu], base: u64, size: u64) : ---
KernelControlFlow :: struct {
    landing_pads : bool,
    signed_returns : bool,
    shadow_stack : bool,
    shadow_stack_pointer : u64,
}
kernel_control_flow : fn() -> KernelControlFlow : ---

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
```

## `kernel_entry`

Part of L2. L1's entry stubs call these functions directly, by name.

```
package kernel_entry

import arch_interface from "../arch_interface"
// And the selected architecture, as arch, with the same #if imports as the rest of L2.

Interrupted :: union {
    User(ptr[mut arch.UserRegisters]),
    Idle,
}

InterruptSource :: union {
    Timer,
    Ipi(arch_interface.IpiKind),
    Device(arch_interface.InterruptId),
    Spurious,
}

// A system call from user mode.
syscall #never_returns : fn(registers: ptr[mut arch.UserRegisters]) : ---

// A fault in user mode.
user_fault #never_returns : fn(registers: ptr[mut arch.UserRegisters], fault: arch_interface.Fault) : ---

// An interrupt from user mode or idle.
interrupt #never_returns : fn(from: Interrupted, source: InterruptSource) : ---

// A fault in kernel code, which is a bug. The kernel stops with a stack trace.
kernel_fault #never_returns : fn(fault: arch_interface.Fault, instruction_pointer: arch_interface.VirtualAddress) : ---

// An NMI, at any time, with the interrupted code's program counter, frame pointer and registers (nmi_register_name's
// order). Returns to the interrupted code.
nmi : fn(pc: u64, frame_pointer: u64, registers: u64[]) : ---

// A machine check or double fault, at any time. The kernel stops with a stack trace.
fatal_critical #never_returns : fn(event: arch_interface.CriticalEvent) : ---
```

### Entry Stubs

Every entry stub, before calling into `kernel_entry`:
1. **From user mode:** switches to the CPU's kernel stack (x86-64: `swapgs`, and the stack from
   the TSS or the per-CPU block), and saves the user registers in an `UserRegisters` on it,
   including the user's carrier register.
2. Finds the CPU's `ArchCpu` through the per-CPU register, and loads the carrier block
   `init_cpu` recorded there with `intrinsics.set_carrier`. Critical-event stubs first save the
   carrier block's `stack_limit`, set it for their own stack, and restore it on the way out.
3. Pushes the context `init_cpu` recorded (L2 passes `PerCpu.context`).
4. Decodes the cause into the portable arguments, and calls the `kernel_entry` function.

Interrupts stay disabled throughout. Saved registers stay where the stub put them. If L2
switches threads, it copies them into the thread's control block, and `return_to_user` can
resume from either place.

On x86-64, entry stubs are Hemera entry functions (`#calling_convention(.entry)` and
`.syscall_entry`, Hemera `docs/calling_convention.md`, *Entry Functions*), whose compiler-generated
code does step 1. Step 3 is `push_context cpu_context from` the recorded context (Hemera
`docs/control_flow.md`, *Pushing a Whole Context*). On AArch64 it's one `.entry` function for the whole
vector table, through `aarch64.vector_table`. On RISC-V it's one `.entry` function, which `stvec` points at, its
frame found through `sscratch` from user mode.

## x86-64

How `arch/x86_64` meets the interface (`../../knowledge/design/arch-x86-64.md`):

| Interface | x86-64 |
|---|---|
| `ArchSystem` | The IDT, filled from `x86_64.entry_points` |
| `UserRegisters` | `x86_64.RegisterFrame` |
| `ArchCpu` | `x86_64.SyscallScratch` first (the `gs` base points here), then the GDT and TSS (with IST entries for the critical stacks), and the carrier block and context for entry stubs |
| `init_cpu` | `lgdt`, `ltr`, `lidt`; `EFER.NXE`, `EFER.SCE`; `STAR`/`LSTAR`/`FMASK`; `CR4.SMEP`, `CR4.SMAP`, `CR4.PCIDE` (if present), `CR4.PGE`, `CR4.OSXSAVE`; `IA32_PAT`; `XCR0` for x87, SSE and AVX; the gs base (`IA32_GS_BASE`) → the `ArchCpu`, which `swapgs` moves to `IA32_KERNEL_GS_BASE` while in user mode |
| `AddressSpaceTag` | PCID, 4096 tags (1 without PCID) |
| Paging | 4-level page tables, reached through the direct map. The kernel's table gets all 256 tables of the kernel half up front, and other address spaces copy its top-level entries. Each non-leaf entry counts the present entries of the table below it in bits 61:52, which the CPU ignores, so `unmap` frees a table that empties without reading it. `init_cpu` sets the PAT (entries 0–3 as at reset, 5 write-combining): `WriteBack` is entry 0, `WriteCombining` 5, `Device` 3 (uncached) |
| TLB | `CR4.PGE` for global pages. With PCIDs, `activate` keeps a tag's entries, unless `flush_tlb` or `flush_tlb_tag` marked the tag stale while it wasn't the current one; `invlpg` flushes the current tag's addresses and global entries, and `all` flushes everything by toggling `CR4.PGE`. The first `activate` on a CPU does that too, leaving nothing of the bootloader's tables |
| Interrupts | x2APIC (xAPIC if absent). Device IDs are vectors 48–239 |
| Wired interrupts | I/O APICs (`ControllerKind.IoApic`), version 0x10 to 0x2f, up to 240 lines, every line masked at first; routed in physical destination mode, so to APIC IDs up to 255 until interrupt remapping. L2 serializes calls on one controller, whose registers are behind a select register. `init_system` masks the legacy 8259 PICs |
| MSIs | Straight to the local APICs, which keep nothing per device: `route_msi`'s message is `0xfee00000` with the APIC ID in bits 12 to 19, and the vector as its data, fixed delivery, edge-triggered; APIC IDs up to 255 until interrupt remapping |
| Timer | TSC with TSC-deadline, frequency from the hint, `CPUID` leaf `0x15`, or calibration against the PIT |
| Entry | One `.entry` function for every vector, through `x86_64.entry_points`, which returns only for NMIs, and a `.syscall_entry` function (`STAR`, `LSTAR` and `FMASK` set by `init_cpu`). Every vector runs on an IST stack: the critical events on their own, the rest on the kernel stack's own slot, so an entry from idle starts again at its top |
| `return_to_user` | `x86_64.return_to_user` |
| System calls | The number in `rax`, arguments in `rdi`, `rsi`, `rdx`, `r10`, `r8` and `r9` (`SYSCALL` takes `rcx` and `r11`), results in `rax`, `rdx` and `r8` (`../../knowledge/design/system-abi.md`) |
| `init_user_registers` | Every register zero but `rip`, `rsp` and `rdi` (the argument); user code and stack selectors; `rflags` 0x202 |
| Vector state | A 64-byte header naming its state components, then an XSAVE area in the standard format: x87, SSE and AVX, plus AVX-512's where the CPU has them with `VectorConfig.extended`. `xsaveopt` where the CPU has it, otherwise `xsave`, and `xrstor`; `xsetbv` when the thread's state components change (`0023`, `0050`) |
| `fs` and `gs` bases | `CR4.FSGSBASE` stays off, so user code can't set them and threads have none to save (`0050`) |
| `hardware_entropy` | `rdseed` |
| `early_console_write` | 16550 UART at I/O port `0x3F8`, 115200 baud, 8N1 |
| `test_exit` | QEMU's `isa-debug-exit` device at I/O port `0xf4` |
| `reset` | The chipset's reset control register, `0xcf9`; L2 writes the FADT's reset register first, where `power_set_reset` gave it |
| `power_off` | None: `can_power_off` is false, and L2 writes ACPI's PM1 control registers with `\_S5`'s sleep types, as `power_set_off` gave them |
| `test_nmi` | An NMI IPI to the CPU's own x2APIC ID |
| `send_nmi` | An NMI IPI to the CPU's x2APIC ID |
| `log_hardening` | Shadow stacks and IBT (CPUID leaf 7); the issues `IA32_ARCH_CAPABILITIES` says don't apply, every one taken as applying without it; SMEP, SMAP, and enhanced IBRS, which `init_cpu` sets in `IA32_SPEC_CTRL` where `IBRS_ALL` says it's there |
| `nmi_register_name` | `rax`, `rbx`, `rcx`, `rdx`, `rsi`, `rdi`, `rbp`, `rsp`, `r8` to `r15`, `rip` and `rflags` |
| `test_device` | QEMU's I/O APIC at `0xfec00000` (the MP specification's default) and its PIT, ISA IRQ 0, on line 2, edge triggered and active high, as QEMU's MADT says; `test_device_interrupts` runs PIT channel 0 at about 1 kHz, or stops it |

## AArch64

How `arch/aarch64` meets the interface (roadmap A3 to A5, `../../knowledge/decisions/0064-aarch64-boot-as-built.md`,
`0065-aarch64-interrupts-as-built.md`, `0066-aarch64-user-mode-as-built.md`). It finds its devices in the device tree (`src/devicetree`): the GICv3, the
virtual timer's interrupt and the PL011.

| Interface | AArch64 |
|---|---|
| `ArchSystem` | The vector table's address, the early console's, whether the CPU has 16-bit ASIDs, the GIC's distributor and redistributor region, the timer's interrupt ID, the device blocks L1 maps, and the routes from lines to the kernel's device interrupt IDs |
| `UserRegisters` | `aarch64.RegisterFrame` |
| `ArchCpu` | The carrier block and context for entries, the kernel stack's limit and top, the early console's address, the `ArchSystem`, its MPIDR affinity and its redistributor; `TPIDR_EL1` points at it |
| `init_system` | The vector table; from the device tree, the GICv3's distributor (turned on, with affinity routing and group 1) and redistributor region, mapped through the direct map, and the virtual timer's PPI |
| `init_cpu` | `TPIDR_EL1`; `VBAR_EL1`; `SP_EL1` at the kernel stack's top (`aarch64.write_sp_el1`) when the kernel was started on `SP_EL0`, which stays its boot stack; PAN on, and kept on at every exception (`SCTLR_EL1.SPAN` clear); `CPACR_EL1.FPEN` set, so floating point and SIMD don't trap at EL0 or EL1; `MAIR_EL1`; `TCR_EL1` with 16-bit ASIDs where the CPU has them, ASIDs from `TTBR0`, and `TTBR0` walks off until an address space is activated; its redistributor (found by MPIDR affinity) awake, with its SGIs and the timer's PPI enabled in group 1, and its CPU interface (`ICC_SRE_EL1`, `ICC_PMR_EL1`, `ICC_IGRPEN1_EL1`) |
| `AddressSpaceTag` | ASID: 65536 tags with 16-bit ASIDs, otherwise 256 |
| Paging | 4 KiB pages, 48-bit addresses, four levels. The kernel's table is `TTBR1`'s and every address space's `TTBR0`'s, so nothing is copied to share the kernel half. Table entries count the valid entries below them in bits 11:2. Kernel mappings are global, user ones `nG` with their ASID, PXN, and only reachable from EL0. `MAIR_EL1`: `WriteBack` index 0 (as the bootloader's), `WriteCombining` index 1 (normal non-cacheable), `Device` index 2 (Device-nGnRnE). A changed memory type is break-before-make |
| TLB | `tlbi vae1` by ASID for user pages, `vaae1` for the kernel's global ones, `aside1` for a tag, `vmalle1` for everything. The first `activate` on a CPU flushes everything, leaving nothing of the bootloader's tables |
| Entry | One `.entry` function for all 16 vectors, through `aarch64.vector_table`, which never returns: faults in the kernel stop it, `svc` from EL0 is a system call, and an IRQ or FIQ is acknowledged through `ICC_IAR1_EL1`. SError is fatal, like a machine check |
| Interrupts | GICv3, every interrupt in group 1 at one priority, with EOImode 0. The timer and IPIs are acknowledged at entry; the timer is stopped first, since its interrupt is a level. IPIs are SGIs 1 (reschedule), 2 (TLB flush) and 3 (stop), through `ICC_SGI1R_EL1`. Device interrupt IDs are the kernel's own, 32 to 255: an SPI's interrupt ID is its line's, so routes translate between them |
| Wired interrupts | The distributor's SPIs (`ControllerKind.GicDistributor`), every one masked at first, routed by `GICD_IROUTER` to one CPU's affinity, with `GICD_ICFGR` for the trigger. The GIC has no polarity: an active-low line is inverted before it |
| Timer | The generic timer's virtual counter and timer (`CNTVCT_EL0`, `CNTV_CVAL_EL0`, `CNTV_CTL_EL0`), at `CNTFRQ_EL0` |
| `idle` | An `eret` to a wait loop at EL1, with `SP_EL1` at the kernel stack's top and interrupts unmasked, so the interrupt starts at the stack's top |
| System calls | `svc #0`: the number in `x8`, arguments in `x0` to `x5`, results in `x0`, `x1` and `x2` (`../../knowledge/design/system-abi.md`). `restart_syscall` steps `ELR_EL1` back over the `svc` |
| `init_user_registers` | Every register zero but `ELR_EL1` (the entry), `SP_EL0` and `x0` (the argument), with `SPSR_EL1` 0: EL0, no interrupt masked |
| `return_to_user` | `aarch64.return_to_user`, with `SP_EL1` at the CPU's kernel stack's top |
| User registers | `x0` to `x30`, `sp`, `pc` and `pstate` (34), of which user mode may only change `pstate`'s condition flags |
| Vector state | `v0` to `v31`, `FPCR` and `FPSR`, 528 bytes, switched eagerly with `aarch64.save_fp_simd` and `restore_fp_simd`, as x86-64's XSAVE state is. SVE isn't kept yet |
| `hardware_entropy` | `rndrrs`, where the CPU has `FEAT_RNG` |
| `early_console_write` | The device tree's first PL011, through the direct map: `early_console_init` maps its registers there as a Device block in the bootloader's tables, and `init_kernel_page_table` again in the kernel's, as it does the GIC's, with `kernel_half_frames` (2 for each 2 MiB block) for its tables. Its address is in `TPIDR_EL1` until `init_cpu`, then in the `ArchCpu` |
| `test_exit` | QEMU's semihosting, `SYS_EXIT` with `(code << 1) \| 1`, so codes read as the debug exit device's do |
| `reset` and `power_off` | PSCI's `SYSTEM_RESET` and `SYSTEM_OFF`, by HVC or SMC as the device tree's `psci` node's method says; `can_power_off` is true with one |
| `test_device` | SPI line 100 of the distributor, which nothing on QEMU `virt` uses, edge-triggered; `test_device_interrupts` pends it through `GICD_ISPENDR`, and again each time it's acknowledged and at every timer interrupt, until it's stopped |
| `msi_doorbell` | One page, the ITS's `GITS_TRANSLATER`'s, which an SMMU maps into each domain |
| MSIs | Through the GICv3's ITS, found in the device tree (`arm,gic-v3-its`): `init_msi` gives it flat device and collection tables and a command queue, and every redistributor the one LPI property table and a pending table of its own, with LPIs on; each redistributor is a collection. `add_msi_device` maps a device's translation table (`MAPD`); `route_msi` gives the event an LPI of its own (8192 of them, from 8192), enabled, mapped to the CPU's collection (`MAPTI`, `INV`), and routes it to the kernel's ID as an SPI is. The message is the event's number, to `GITS_TRANSLATER` |
| Interrupt masking | In the kernel, `ICC_PMR_EL1` at `0x80` with PSTATE's I clear, so only the pseudo-NMI's priority (`0x20`) passes; in user mode and idle, `0xf0`, letting every interrupt's (`0xa0`) through. Each exception takes an IRQ's ID from `ICC_IAR1_EL1` first, which the kernel's mask would hide, then sets that mask and clears I; every `eret` to user mode or idle sets I and the mask back to `0xf0` first (`0185`) |
| `send_nmi` | SGI 4, the pseudo-NMI, at priority `0x20`; its entry returns to what it interrupted, kernel code included, the interrupted mask restored |
| `log_hardening` | BTI, PAC and GCS (`ID_AA64PFR1_EL1`, `ID_AA64ISAR1_EL1`); Spectre v2 and Meltdown not applying by `CSV2` and `CSV3`; PAN, and whether there's SSBS |
| `nmi_register_name` | `x0` to `x30`, `sp`, `pc` and `pstate` |
| Not yet | `test_nmi`, which needs pseudo-NMIs or FEAT_NMI |

## RISC-V

How `arch/riscv64` meets the interface so far (M19's R3 and R4, `../../knowledge/decisions/0199-m19-risc-v-plan.md`,
`../../knowledge/design/arch-riscv64.md`). It finds its devices and its features in the device tree: the 16550, and the
PLIC, or the AIA's IMSIC and APLIC.

| Interface | RISC-V |
|---|---|
| `ArchSystem` | The early console's word, the harts' features, the ASID bits `satp` keeps, the device blocks L1 maps, the timebase, which controller the harts have and each hart's place on it (its PLIC context, or its IMSIC file and index), the PLIC's or the APLIC's registers, and the routes from PLIC lines to the kernel's IDs |
| `UserRegisters` | `riscv64.RegisterFrame` |
| `ArchCpu` | `riscv64.TrapScratch` first (`tp` points here in the kernel, `sscratch` in user mode), then the carrier block and context for entries, the kernel stack's limit and top, the trap stack's top and limit, the early console's word, the `ArchSystem`, the hart's ID (`init_cpu`'s `hardware_id`), its PLIC context or IMSIC file, the PLIC line it claimed, and the kinds of the SBI's IPIs sent it, the kernel's deadline and the test device's, and its control-flow integrity: its landing pads, its kernel shadow stack's top and whether shadow stacks are on, and the `senvcfg` the thread returning to user mode gets |
| `detect_features` | The device tree's first cpu node: its `riscv,isa-extensions`, or its `riscv,isa` string, and its `mmu-type`. The baseline is RVA23 as the kernel and programs are built for it, with Sv48 |
| `init_system` | The early console's registers kept for the kernel's own tables; the features; the ASID bits, found by writing all ones to `satp`'s ASID field and reading it back; `/cpus`' `timebase-frequency`; and the controller, mapped through the direct map: an IMSIC with supervisor files (`riscv,imsics`, external interrupt 9) and the APLIC whose `msi-parent` it is, else a PLIC (`sifive,plic-1.0.0`), each hart by its interrupt controller's cpu node |
| `init_cpu` | `tp` at the `ArchCpu`; `sscratch` 0; `stvec` at the entry, direct mode; `sstatus.SIE` clear but `sie`'s software, timer and external interrupts on; `stimecmp` at its largest; `sstatus.SUM`, `FS` and `VS` clear; `scounteren`'s `TM`; the hart's IMSIC file delivering every identity (`eidelivery`, `eithreshold`, `eie`, through `siselect`), or its PLIC context's threshold 0 and every line disabled there; the kernel's landing pads on, the SBI's FWFT `LANDING_PAD` |
| `AddressSpaceTag` | ASID: as many as `satp` keeps bits for, up to 65536 |
| Paging | Sv48, one root for both halves, as on x86-64: the kernel's table gets all 256 tables of the kernel half up front, and other address spaces copy its top-level entries. A non-leaf entry has no bits to spare, so `unmap` looks for a second valid entry to know a table emptied. Every leaf has D set; A is kept by software, as Svade faults on a clear one: a kernel leaf's is set, a user leaf's is cleared by `take_accessed`, and the entry sets it again on the fault the next access takes, and retries it. Kernel mappings are global, user ones `U` with their ASID. Svpbmt: `WriteBack` is the physical memory attributes (0), `WriteCombining` NC, `Device` IO; a changed memory type is taken out and fenced before the new one goes in. A shadow stack's page is W alone, Zicfiss's encoding |
| TLB | `sfence.vma` by address and ASID for user pages, by address alone for the kernel's global ones, by ASID for a tag, and whole for everything. `map` fences the new entry on the calling hart, which may have walked it while it was invalid. The first `activate` on a hart flushes everything |
| Entry | One `.entry` function, which `stvec` points at. From user mode it runs on the kernel stack's top and never returns: `ecall` is a system call, a hardware error (code 19) a machine check, an interrupt decoded, any other exception the thread's fault. In the kernel, the entry only rewrites the frame and returns, its `sret` landing on a fresh stack: an exception in `kernel_trap` on the CPU's DoubleFault critical stack, since the frame is on the stack the trap came from, which may be the one the stack check found full; an interrupt, which comes only while idle, in `idle_interrupt` on the kernel stack's top. The interrupted `s0` and `ra` stay, so a stack trace goes on through the faulting code. A page fault on a kernel mapping the tables now allow, which a hart may have walked before another made it, is fenced and retried. A page fault is `present` if the active tables map the address |
| Stacks | A stack's limit leaves room below it for the guard and for a trap's frame (288 bytes), since a trap in the kernel builds its frame wherever the stack pointer is |
| `counter` | The `time` CSR |
| `hardware_entropy` | Zkr's `seed`, 16 bits at a time, where the harts have Zkr; null before `init_cpu` |
| `early_console_write` | The device tree's first `ns16550a` (or `ns16550`), through the direct map: `early_console_init` maps its registers there as an I/O page in the bootloader's tables, and `init_kernel_page_table` again in the kernel's, with `kernel_half_frames` (one for each 2 MiB block). It honours `reg-shift`, `reg-io-width` and `clock-frequency`. Its word is in `tp` until `init_cpu`, then in the `ArchCpu` |
| `test_exit` | QEMU's semihosting, `SYS_EXIT` with `(code << 1) \| 1`, as on AArch64 |
| `reset` and `power_off` | The SBI's system reset extension, a warm reboot and a shutdown; `can_power_off` is true where the SBI has it |
| `send_nmi`, `nmi_register_name` | RISC-V's supervisor has no NMI: false, and `"?"` |
| `log_hardening` | Zicfilp and Zicfiss, and whether the firmware's FWFT lets the kernel have each; nothing in the ISA says which transient-execution issues apply |
| User mode | `ecall` system calls, the number in `a7`, arguments in `a0` to `a5`, results in `a0` to `a2`; `sepc` moved past the `ecall` (4 bytes) before the call. `return_to_user` through `riscv64.return_to_user`, `sscratch` the hart's `TrapScratch`. A debugger's 33 registers are `x0` to `x31`, then `pc`. A trapped `rdtime` (`scounteren.TM` clear) is a Protection fault, which `emulate_counter_read` answers |
| Vector state | Eager, by `riscv64.save_floating` and `save_vector`: `f0` to `f31` and `fcsr`, then `v0` to `v31` and `vstart`, `vtype`, `vl` and `vcsr`. `sstatus.FS` and `VS` are off in the kernel, Initial in user mode |
| `set_debug` | Takes no slots and no stepping yet: the SBI's debug triggers aren't driven |
| Control-flow integrity | Zicfilp's landing pads and Zicfiss's shadow stacks, supervisor mode's turned on by the SBI's FWFT (`LANDING_PAD` at `init_cpu`, `SHADOW_STACK` at the hart's first idle or return to user mode, in those functions' own bodies, which never return), user mode's by `senvcfg`'s `LPE` and `SSE` for each thread. One `ssp` serves every mode: a trap from user mode keeps user mode's in the `TrapScratch` and starts the kernel's shadow stack from its top, and a return to user mode puts it back. A shadow-stack fault and a branch to no landing pad are software-check exceptions (18); an ordinary store to a shadow stack's page is an access fault, a Protection fault |
| Interrupts | With the AIA every interrupt is a message: the kernel's device IDs are each hart's IMSIC identities, 16 up to `riscv,num-ids`, claimed through `stopei`, and IPIs are identities 1 to 3 written to the target's file. With a PLIC the device IDs are the kernel's own, 32 to 255, translated through routes from the line a hart claims, which `end_of_interrupt` completes; IPIs are the SBI's `sbi_send_ipi`, their kinds in the target's `ArchCpu` |
| Wired interrupts | The PLIC (`ControllerKind.Plic`), every line at priority 1 and disabled in every supervisor context, enabled in its routed hart's; or the APLIC (`Aplic`), delivering by message, each source inactive until it's routed, its target the hart's IMSIC index and the ID as its identity, masked through `clrienum` and `setienum` |
| MSIs | Straight to the IMSIC, which keeps nothing per device: `route_msi`'s message is the hart's file's `seteipnum_le` and the ID. A PLIC takes none (`msi_device_memory` is null). `msi_doorbell` is the harts' supervisor interrupt files, from the lowest's to the highest's, which the RISC-V IOMMU translates as other DMA; it remaps none, so `route_wired_remapped` does nothing |
| Timer | Sstc's `stimecmp`, at `/cpus`' `timebase-frequency`, holding the earlier of the kernel's deadline and the test device's |
| `idle` | The kernel shadow stack from its top, then `sstatus.SIE` set and `wfi` in a loop: the interrupt's entry starts again at the kernel stack's top |
| `test_device` | With the AIA, the APLIC's last source, pended through `setipnum`; with a PLIC, the UART's line, its transmitter's interrupt armed. Either is pended again a hundred times a second, by a deadline of its own on the hart that started it, as the kernel's stop while it's idle |
| Not yet | Hardware breakpoints, steps and watchpoints (the SBI's debug triggers); `test_nmi` (there's no NMI) |

## Not Covered

- **IOMMUs** are driven by the kernel behind a separate interface, `iommu_interface` (`iommu_interface.md`),
  since they differ per platform rather than per architecture (Intel VT-d, AMD-Vi, Arm SMMU, the RISC-V IOMMU)
  and an architecture may need several (`0039`, `0079`).
- **Cache maintenance for DMA** on architectures where devices aren't cache-coherent.
- **Debug registers** for hardware breakpoints and watchpoints.
- **Reading and writing a stopped thread's full register set** for debuggers (`0017`), which
  belongs with the system ABI.
