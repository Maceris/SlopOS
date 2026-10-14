# Arch Interface

The arch interface is the boundary between the arch layer (L1) and the kernel core (L2)
(`../architecture/layers.md`). It runs in both directions:
- **`arch_interface`**: what every architecture package implements and L2 calls (CPU setup,
  paging, interrupts, the timer, user state).
- **`kernel_entry`**: what L2 implements and L1's entry stubs call (system calls, faults,
  interrupts).

Status: **specified**, not implemented. Choices and alternatives are in
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

- **The kernel runs with interrupts disabled.** They're enabled only while a CPU is idle (`idle`).
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
- **L1 never allocates.** Memory for page tables, stacks, vector state and the per-architecture
  types comes from L2.
- **L1 holds no policy and no global state.** Its state lives in `ArchSystem` and `ArchCpu`,
  which L2 embeds in its own `Kernel` and `PerCpu` blocks.
- **Each page table is changed by one CPU at a time.** L2 serializes calls on the same
  `PageTable`. TLB shootdown across CPUs is L2's job, using `send_ipi` and `flush_tlb`.

## `arch_interface`

```
package arch_interface

import runtime from "base"
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

// The CPU's features, read once on the boot CPU. CpuFeatures is defined with the system ABI (0019).
detect_features : fn() -> abi.CpuFeatures : ---

// The first baseline feature the CPU lacks (x86-64-v3 on x86-64, 0003), or null.
missing_baseline_feature : fn(features: ptr[abi.CpuFeatures]) -> string? : ---

// Set up the state shared by every CPU. Called once, on the boot CPU, before init_cpu.
init_system : fn(system: ptr[mut ArchSystem]) : ---

/*
 * Set up the calling CPU: descriptor tables, entry points, the stacks entries use,
 * user-access protection, no-execute, address-space tags, and the default vector state.
 * Records carrier and context in cpu, and cpu in the architecture's per-CPU register
 * (x86-64: IA32_KERNEL_GS_BASE; AArch64: TPIDR_EL1; RISC-V: sscratch), for entry stubs.
 */
init_cpu : fn(
    system: ptr[ArchSystem],
    cpu: ptr[mut ArchCpu],
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
 * Make table an address space whose top-level table is root, a zeroed frame.
 * Copies the kernel half from kernel, or starts the kernel's own table if kernel is null.
 */
init_page_table : fn(
    table: ptr[mut PageTable],
    root: PhysicalAddress,
    tag: AddressSpaceTag,
    kernel: ptr[PageTable]?,
) : ---

map : fn(
    table: ptr[mut PageTable],
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    size: PageSize,
    mapping: Mapping,
    tables: ptr[mut TableFrames],
) -> Result[void, MapError] : ---

// Unmap one page, returning its physical address.
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

// Where virtual_address is mapped, or null if nothing is mapped there.
translate : fn(table: ptr[PageTable], virtual_address: VirtualAddress) -> Translation? : ---

// Switch the calling CPU to table.
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

// Write to the architecture's early console, before any driver exists.
early_console_write : fn(text: string) : ---
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

// An NMI, at any time. Returns to the interrupted code.
nmi : fn() : ---

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

**Not yet expressible in Hemera:** on x86-64, interrupt functions cover IDT entries, but not
`SYSCALL` entry, `return_to_user`, `XSAVE`-family instructions, `RDSEED`, or AArch64 and
RISC-V entry (`../../knowledge/hemera-feedback.md`, *Kernel entry and return to user mode*).
The interface doesn't depend on how stubs are written.

## x86-64

How `arch/x86_64` meets the interface (`../../knowledge/design/arch-x86-64.md`):

| Interface | x86-64 |
|---|---|
| `ArchSystem` | The IDT |
| `ArchCpu` | The GDT and TSS (with IST entries for the critical stacks), and the carrier block and context for entry stubs |
| `init_cpu` | `lgdt`, `ltr`, `lidt`; `EFER.NXE`, `EFER.SCE`; `STAR`/`LSTAR`/`FMASK`; `CR4.SMEP`, `CR4.SMAP`, `CR4.PCIDE` (if present), `CR4.OSXSAVE`; `XCR0` for x87, SSE and AVX; `IA32_KERNEL_GS_BASE` → the `ArchCpu` |
| `AddressSpaceTag` | PCID, 4096 tags (1 without PCID) |
| Paging | 4-level page tables; `Device` uses PAT uncached, `WriteCombining` the PAT WC entry |
| Interrupts | x2APIC (xAPIC if absent). Device IDs are vectors 48–239 |
| Timer | TSC with TSC-deadline, frequency from the hint, `CPUID` leaf `0x15`, or calibration against the PIT |
| `hardware_entropy` | `RDSEED` |
| `early_console_write` | 16550 UART at I/O port `0x3F8` |

## Not Covered

- **Wired interrupts** (I/O APIC, GIC SPIs, PLIC): routing them needs the platform's description
  of its interrupt controllers, which comes from ACPI or the devicetree in user space. How the
  platform service hands that to the kernel is open.
- **IOMMU domains:** IOMMUs differ per platform rather than per architecture (Intel VT-d,
  AMD-Vi, Arm SMMU, the RISC-V IOMMU), so they'll get their own interface, needed before
  untrusted drivers get DMA (roadmap M7).
- **Cache maintenance for DMA** on architectures where devices aren't cache-coherent.
- **Debug registers** for hardware breakpoints and watchpoints.
- **Reading and writing a stopped thread's full register set** for debuggers (`0017`), which
  belongs with the system ABI.
