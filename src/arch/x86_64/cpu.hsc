/*
 * The x86-64 arch layer (L1): implements arch_interface (docs/specs/arch_interface.md, x86-64)
 * for the kernel core, which imports this package as arch.
 *
 * Not here yet, with the milestones that need them: wired interrupt controllers and device
 * interrupts (M3), user state, vector state and entry from user mode (M4 to M6).
 */
package arch_x86_64

import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

// Segment selectors, in GDT order. SYSRET needs user data right below user code (Intel SDM Vol. 3A §5.8.8).
KERNEL_CODE_SELECTOR : u16 : 0x08
KERNEL_DATA_SELECTOR : u16 : 0x10
USER_DATA_SELECTOR : u16 : 0x18 | 3
USER_CODE_SELECTOR : u16 : 0x20 | 3
TSS_SELECTOR : u16 : 0x28

// Null, kernel code and data, user data and code, and the TSS, which takes two entries.
GDT_ENTRIES :: 7

// Interrupt stack table slots (1-based in IDT entries; the TSS's ist array is 0-based).
IST_KERNEL : u8 : 1
IST_NMI : u8 : 2
IST_DOUBLE_FAULT : u8 : 3
IST_MACHINE_CHECK : u8 : 4

//SPEC: Intel SDM Vol. 3A §8.7, Figure 8-11 (64-bit TSS)
TaskStateSegment :: struct #packed {
    reserved_0 : u32,
    // Stacks for entering rings 0 to 2 from a less privileged ring. Only rsp[0] is used.
    rsp : u64[3],
    reserved_1 : u64,
    // Interrupt stack table, selected by an IDT entry's ist field.
    ist : u64[7],
    reserved_2 : u64,
    reserved_3 : u16,
    // Offset of the I/O permission bitmap; past the end of the segment means none.
    io_map_base : u16,
}

#assert size_of(TaskStateSegment) == 104

//SPEC: Intel SDM Vol. 3A §7.14.1, Figure 7-8 (64-bit IDT gate descriptors)
IdtEntry :: struct {
    offset_low : u16,
    selector : u16,
    // Bits 0-2: the interrupt stack table slot, 0 for none.
    ist : u8,
    // Present, DPL and gate type.
    attributes : u8,
    offset_middle : u16,
    offset_high : u32,
    reserved : u32,
}

#assert size_of(IdtEntry) == 16

// Present, DPL 0, 64-bit interrupt gate (interrupts disabled on entry).
INTERRUPT_GATE : u8 : 0x8e

/*
 * One CPU's architecture state (arch_interface.ArchCpu). The gs base points at it while the CPU is
 * in the kernel, so entries find their CPU with x86_64.read_gs_base(). Must not move after init_cpu.
 */
ArchCpu :: struct #align(64) {
    // First, where the gs base points: .syscall_entry functions keep the stack pointers here.
    syscall : x86_64.SyscallScratch,
    gdt : u64[GDT_ENTRIES],
    tss : TaskStateSegment,
    // What entries load before calling the kernel: the CPU's carrier block and context.
    carrier : ptr[mut runtime.CarrierBlock],
    context : ptr[runtime.Context],
    // stack_limit for the kernel stack and each critical-event stack, set by the entries that use them.
    kernel_stack_limit : rawptr,
    critical_stack_limits : rawptr[3],
    timer : TimerState,
    // Whether init_cpu turned PCIDs on.
    pcid : bool,
    // Still on the bootloader's page tables, until the first activate.
    bootloader_tables : bool,
    // One bit per PCID whose entries must be flushed when it's next activated (paging.hsc).
    stale_tags : u64[64],
}

// State shared by every CPU (arch_interface.ArchSystem): the IDT. Must not move after init_system.
ArchSystem :: struct #align(16) {
    idt : IdtEntry[256],
}

// User-mode registers saved at kernel entry (arch_interface.UserRegisters): what entry functions save.
UserRegisters :: struct {
    frame : x86_64.RegisterFrame,
}

// How the CPU's timer is driven, decided by init_timer.
TimerState :: struct {
    // TSC-deadline mode: the deadline is a TSC value. Otherwise the local APIC timer counts down.
    tsc_deadline : bool,
    tsc_frequency : u64,
    // Ticks per second of the local APIC timer, when it counts down.
    apic_frequency : u64,
}

// The CPU these functions run on, found through the gs base, which init_cpu set.
current_cpu :: fn() -> ptr[mut ArchCpu] {
    return cast[ptr[mut ArchCpu]](x86_64.read_gs_base())
}

// stack_limit for a stack: STACK_GUARD bytes above its lowest address.
stack_limit_of :: fn(stack: arch_interface.StackRange) -> rawptr {
    return cast[rawptr](cast[u64](stack.low) + runtime.STACK_GUARD)
}
