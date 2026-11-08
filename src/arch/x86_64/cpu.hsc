/**
 * The x86-64 arch layer (L1): implements arch_interface (docs/specs/arch_interface.md, x86-64)
 * for the kernel core, which imports this package as arch.
 *
 * Everything arch_interface declares is here.
 */
package arch_x86_64

import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

// Segment selectors, in GDT order. SYSRET needs user data right below user code (Intel SDM Vol. 3A §5.8.8).
/** The kernel's code segment selector: GDT entry 1, RPL 0. */
KERNEL_CODE_SELECTOR : u16 : 0x08
/** The kernel's data segment selector: GDT entry 2, RPL 0, right after kernel code as SYSCALL needs. */
KERNEL_DATA_SELECTOR : u16 : 0x10
/** User mode's data segment selector: GDT entry 3, RPL 3. */
USER_DATA_SELECTOR : u16 : 0x18 | 3
/** User mode's 64-bit code segment selector: GDT entry 4, RPL 3, right after user data as SYSRET needs. */
USER_CODE_SELECTOR : u16 : 0x20 | 3
/** The TSS's selector: GDT entries 5 and 6, a 64-bit TSS descriptor taking two. */
TSS_SELECTOR : u16 : 0x28

/** How many 8-byte entries the GDT has: null, kernel code and data, user data and code, and the TSS's two. */
GDT_ENTRIES :: 7

// Interrupt stack table slots (1-based in IDT entries; the TSS's ist array is 0-based).
/** The interrupt stack table slot of the kernel stack, which every entry but the critical events' runs on. */
IST_KERNEL : u8 : 1
/** The interrupt stack table slot of the NMI's own stack. */
IST_NMI : u8 : 2
/** The interrupt stack table slot of the double fault's own stack. */
IST_DOUBLE_FAULT : u8 : 3
/** The interrupt stack table slot of the machine check's own stack. */
IST_MACHINE_CHECK : u8 : 4

/**
 * The 64-bit task-state segment, which in 64-bit mode only holds stack pointers and the I/O permission bitmap's place.
 *
 * SPEC: Intel SDM Vol. 3A §8.7, Figure 8-11 (64-bit TSS). Its layout is the hardware's, 104 bytes, packed.
 */
TaskStateSegment :: struct #packed {
    /** Reserved, 0. */
    reserved_0 : u32,
    /**
     * The stacks the CPU switches to entering rings 0 to 2 from a less privileged ring, each the virtual address one
     * past its highest byte. Only rsp[0] is used, the kernel stack's top.
     */
    rsp : u64[3],
    /** Reserved, 0. */
    reserved_1 : u64,
    /**
     * The interrupt stack table: 7 stack tops, each the virtual address one past its highest byte, selected by an IDT
     * entry's ist field, which is 1-based (slot n is ist[n - 1]).
     */
    ist : u64[7],
    /** Reserved, 0. */
    reserved_2 : u64,
    /** Reserved, 0. */
    reserved_3 : u16,
    /** Offset in bytes of the I/O permission bitmap from the TSS's start; past the end of the segment means none. */
    io_map_base : u16,
}

#assert size_of(TaskStateSegment) == 104

/**
 * One 16-byte entry of the IDT, a 64-bit gate descriptor; all zero is a gate not present.
 *
 * SPEC: Intel SDM Vol. 3A §7.14.1, Figure 7-8 (64-bit IDT gate descriptors).
 */
IdtEntry :: struct {
    /** Bits 0-15 of the handler's virtual address. */
    offset_low : u16,
    /** The code segment selector the handler runs in, KERNEL_CODE_SELECTOR. */
    selector : u16,
    /** Bits 0-2: the interrupt stack table slot, 1 to 7, or 0 for none. The other bits are 0. */
    ist : u8,
    /** Present (bit 7), DPL (bits 5-6) and gate type (bits 0-3), like INTERRUPT_GATE. */
    attributes : u8,
    /** Bits 16-31 of the handler's virtual address. */
    offset_middle : u16,
    /** Bits 32-63 of the handler's virtual address. */
    offset_high : u32,
    /** Reserved, 0. */
    reserved : u32,
}

#assert size_of(IdtEntry) == 16

/** IdtEntry attributes: present, DPL 0, 64-bit interrupt gate (interrupts disabled on entry). */
INTERRUPT_GATE : u8 : 0x8e

/**
 * One CPU's architecture state (arch_interface.ArchCpu). The gs base points at it while the CPU is
 * in the kernel, so entries find their CPU with x86_64.read_gs_base(). Must not move after init_cpu.
 */
ArchCpu :: struct #align(64) {
    /**
     * Where the gs base points, so first: .syscall_entry functions load the kernel stack's top from here and save the
     * user's stack pointer here.
     */
    syscall : x86_64.SyscallScratch,
    /** The CPU's GDT: null, kernel code and data, user data and code, and the TSS's two entries. */
    gdt : u64[GDT_ENTRIES],
    /** The CPU's TSS, with the kernel stack and the critical events' stacks. */
    tss : TaskStateSegment,
    /** The CPU's carrier block, which entries load before calling the kernel; it lives as long as the CPU runs. */
    carrier : ptr[mut runtime.CarrierBlock],
    /** The CPU's context, which entries load before calling the kernel; it lives as long as the CPU runs. */
    context : ptr[runtime.Context],
    /** The kernel stack's stack_limit, STACK_GUARD bytes above its lowest address, set by the entries that use it. */
    kernel_stack_limit : rawptr,
    /** Each critical-event stack's stack_limit, indexed by arch_interface.CriticalEvent, set by its entry. */
    critical_stack_limits : rawptr[3],
    /** How this CPU's timer is driven, set by init_timer. */
    timer : TimerState,
    /** Whether init_cpu turned PCIDs on, so address-space tags are used. */
    pcid : bool,
    /** Still on the bootloader's page tables, until the first activate, which then flushes the whole TLB. */
    bootloader_tables : bool,
    /** One bit per PCID, 4096 of them, whose entries must be flushed when it's next activated (paging.hsc). */
    stale_tags : u64[64],
    /** XCR0 as it's set now, which restoring a thread's vector state may change (vector.hsc). */
    xcr0 : u64,
    /** Whether the CPU has XSAVEOPT, which saving vector state then uses (vector.hsc). */
    xsaveopt : bool,
    /** Whether a thread's breakpoints are in the debug registers (debug_on), so an entry turns them off. */
    debug_loaded : bool,
    /** Whether CR4.TSD is set, so user mode's RDTSC traps (set_counter_trap). */
    counter_trapped : bool,
}

/** State shared by every CPU (arch_interface.ArchSystem): the IDT. Must not move after init_system. */
ArchSystem :: struct #align(16) {
    /** The IDT, which every CPU loads, one entry for each of the 256 vectors. */
    idt : IdtEntry[256],
}

/** User-mode registers saved at kernel entry (arch_interface.UserRegisters): what entry functions save. */
UserRegisters :: struct {
    /** The registers as the entry saved them, and as returning to user mode loads them. */
    frame : x86_64.RegisterFrame,
}

/** How the CPU's timer is driven, decided by init_timer. */
TimerState :: struct {
    /** Whether the timer is in TSC-deadline mode, deadlines TSC values; otherwise the local APIC timer counts down. */
    tsc_deadline : bool,
    /** The TSC's frequency in Hz, the rate counter() counts at. */
    tsc_frequency : u64,
    /** Ticks per second of the local APIC timer, when it counts down; not set in TSC-deadline mode. */
    apic_frequency : u64,
}

/**
 * Find the calling CPU's architecture state, through the gs base, which init_cpu set.
 *
 * Only valid in the kernel after init_cpu, with the kernel's gs base loaded: not on an entry from user mode before its
 * swapgs.
 *
 * @return The calling CPU's ArchCpu, which lives as long as the CPU runs.
 */
current_cpu :: fn() -> ptr[mut ArchCpu] {
    return cast[ptr[mut ArchCpu]](x86_64.read_gs_base())
}

/**
 * Compute the stack_limit for a stack, the lowest address code on it may reach before it's taken to overflow.
 *
 * @param stack The stack's range, only read; low must be at least STACK_GUARD bytes below high for the limit to
 *     fall inside it, which isn't checked.
 * @return STACK_GUARD bytes above the stack's lowest address.
 */
stack_limit_of :: fn(stack: arch_interface.StackRange) -> rawptr {
    return cast[rawptr](cast[u64](stack.low) + runtime.STACK_GUARD)
}
