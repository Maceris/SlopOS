package arch_x86_64

import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"

// Model-specific registers and control register bits
//SPEC: Intel SDM Vol. 4 (MSRs), Vol. 3A §2.5 (control registers), §2.2.1 (EFER)
/** The IA32_EFER MSR's number: extended features, like SYSCALL and no-execute. */
IA32_EFER : u32 : 0xc0000080
/** The IA32_STAR MSR's number: the segment selectors SYSCALL and SYSRET load. */
IA32_STAR : u32 : 0xc0000081
/** The IA32_LSTAR MSR's number: the virtual address SYSCALL jumps to in 64-bit mode. */
IA32_LSTAR : u32 : 0xc0000082
/** The IA32_FMASK MSR's number: the RFLAGS bits SYSCALL clears. */
IA32_FMASK : u32 : 0xc0000084
/** The IA32_FS_BASE MSR's number: the fs segment's base address. */
IA32_FS_BASE : u32 : 0xc0000100
/** The IA32_GS_BASE MSR's number: the gs segment's base address, the CPU's ArchCpu while in the kernel. */
IA32_GS_BASE : u32 : 0xc0000101
/** The IA32_KERNEL_GS_BASE MSR's number: the gs base swapgs exchanges with IA32_GS_BASE. */
IA32_KERNEL_GS_BASE : u32 : 0xc0000102

/** IA32_EFER bit 0 (SCE): SYSCALL and SYSRET enabled. */
EFER_SYSCALL_ENABLE : u64 : 1 << 0
/** IA32_EFER bit 11 (NXE): the no-execute bit in page-table entries enabled. */
EFER_NO_EXECUTE_ENABLE : u64 : 1 << 11

/*
 * SYSCALL loads the kernel's code selector and the data one after it; 64-bit SYSRET loads user code
 * at the base plus 16 and user data at the base plus 8, so the base sits below user data.
 */
//SPEC: Intel SDM Vol. 3A §5.8.8 (fast system calls in 64-bit mode)
/** IA32_STAR bits 32-47: the selector base SYSCALL loads cs (and ss, 8 above it) from, the kernel's code selector. */
STAR_SYSCALL_SELECTORS : u64 : cast[u64](KERNEL_CODE_SELECTOR) << 32
/** IA32_STAR bits 48-63: the selector base 64-bit SYSRET loads from, 8 below user data, with RPL 3. */
STAR_SYSRET_SELECTORS : u64 : cast[u64](USER_DATA_SELECTOR - 8) << 48
/** The RFLAGS bits SYSCALL clears, for IA32_FMASK: trap (8), interrupt (9), direction (10), alignment check (18). */
SYSCALL_FLAGS_MASK : u64 : (1 << 8) | (1 << 9) | (1 << 10) | (1 << 18)

/** CR0 bit 1 (MP): with TS, WAIT and FWAIT raise device-not-available too. */
CR0_MONITOR_COPROCESSOR : u64 : 1 << 1
/** CR0 bit 2 (EM): x87 instructions emulated, raising device-not-available; cleared for the FPU to work. */
CR0_EMULATION : u64 : 1 << 2
/** CR0 bit 5 (NE): x87 errors reported natively, as #MF, not through the legacy external interrupt. */
CR0_NUMERIC_ERROR : u64 : 1 << 5

/** CR4 bit 9 (OSFXSR): the OS saves SSE state with FXSAVE and XSAVE, which enables SSE instructions. */
CR4_OSFXSR : u64 : 1 << 9
/** CR4 bit 10 (OSXMMEXCPT): unmasked SIMD floating-point exceptions raise #XM. */
CR4_OSXMMEXCPT : u64 : 1 << 10
/** CR4 bit 17 (PCIDE): process-context identifiers enabled, the address-space tags in CR3's low 12 bits. */
CR4_PCID : u64 : 1 << 17
/** CR4 bit 18 (OSXSAVE): XSAVE and XSETBV enabled, and XCR0 in use. */
CR4_OSXSAVE : u64 : 1 << 18
/** CR4 bit 20 (SMEP): the kernel can't execute user-mode pages. */
CR4_SMEP : u64 : 1 << 20
/** CR4 bit 21 (SMAP): the kernel can't access user-mode pages unless RFLAGS.AC is set. */
CR4_SMAP : u64 : 1 << 21

// XCR0 state components: x87, SSE and AVX by default (decisions/0023)
/** XCR0 bit 0: the x87 state component, which has to be set. */
XCR0_X87 : u64 : 1 << 0
/** XCR0 bit 1: the SSE state component, XMM registers and MXCSR. */
XCR0_SSE : u64 : 1 << 1
/** XCR0 bit 2: the AVX state component, the YMM registers' upper halves. */
XCR0_AVX : u64 : 1 << 2

// Code and data segments for 64-bit mode: base and limit are ignored, only the access bits matter.
//SPEC: Intel SDM Vol. 3A §3.4.5, Figure 3-8 (segment descriptors), §5.2.1 (code segments in 64-bit mode)
/** The kernel's code segment descriptor: present, DPL 0, execute/read, 64-bit (L set). */
KERNEL_CODE_DESCRIPTOR : u64 : 0x00af9a000000ffff
/** The kernel's data segment descriptor: present, DPL 0, read/write. */
KERNEL_DATA_DESCRIPTOR : u64 : 0x00cf92000000ffff
/** User mode's data segment descriptor: present, DPL 3, read/write. */
USER_DATA_DESCRIPTOR : u64 : 0x00cff2000000ffff
/** User mode's code segment descriptor: present, DPL 3, execute/read, 64-bit (L set). */
USER_CODE_DESCRIPTOR : u64 : 0x00affa000000ffff

/**
 * Make the two GDT entries of a 64-bit TSS descriptor: present, DPL 0, type 9 (available 64-bit TSS).
 *
 * SPEC: Intel SDM Vol. 3A §8.2.3, Figure 8-4 (TSS descriptor in 64-bit mode).
 *
 * @param base The TSS's virtual address. Its limit is the size of TaskStateSegment, less 1.
 * @return The descriptor's low 8 bytes, the entry the TSS's selector names.
 * @return Its high 8 bytes, bits 32-63 of base, the entry after it.
 */
tss_descriptor :: fn(base: u64) -> (u64, u64) {
    limit :: cast[u64](size_of(TaskStateSegment) - 1)
    low := limit & 0xffff
    low |= (base & 0xffffff) << 16
    low |= cast[u64](0x89) << 40
    low |= ((limit >> 16) & 0xf) << 48
    low |= ((base >> 24) & 0xff) << 56
    return low, base >> 32
}

/**
 * Make an IDT entry: an interrupt gate, DPL 0, in the kernel's code segment, so user mode can't raise it with INT.
 *
 * @param handler The entry stub's virtual address.
 * @param ist The interrupt stack table slot to switch to, 1 to 7, or 0 for none.
 * @return The 16-byte gate, present, for the caller to store in the IDT; handler's 64 bits are split across its
 *     three offset fields.
 */
gate :: fn(handler: u64, ist: u8) -> IdtEntry {
    return IdtEntry.{
        offset_low = cast[u16](handler & 0xffff),
        selector = KERNEL_CODE_SELECTOR,
        ist = ist,
        attributes = INTERRUPT_GATE,
        offset_middle = cast[u16]((handler >> 16) & 0xffff),
        offset_high = cast[u32](handler >> 32),
        reserved = 0,
    }
}

/**
 * Set up the state shared by every CPU: the IDT, every vector at its entry point, and the legacy PICs masked.
 *
 * Called once, on the boot CPU, before init_cpu.
 *
 * @param system Where the IDT goes, which mustn't move afterwards: each CPU's IDTR points at it.
 * @param firmware The firmware's tables, which x86-64 doesn't need here.
 * @param direct_map_offset Where the bootloader's direct map is, not needed here either.
 */
init_system :: fn(system: ptr[mut ArchSystem], firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) {
    for &entry in system.idt {
        entry^ = IdtEntry.{}
    }
    fill_idt(system)
    mask_legacy_pics()
}

/**
 * Set up the calling CPU.
 *
 * In order: its GDT and TSS with the stacks entries use, the IDT, no-execute, user-access protection, the x87, SSE and
 * AVX state, enhanced IBRS where it's there (hardening.hsc), address-space tags, SYSCALL, the gs base for entries, and its local APIC in x2APIC mode. It runs once on
 * each CPU, at ring 0 with interrupts disabled, after init_system.
 *
 * @param system The shared state init_system set up, whose IDT this CPU loads.
 * @param cpu This CPU's state, which mustn't move afterwards: the GDT, TSS and gs base point into it.
 * @param carrier The CPU's carrier block, which entries load; kept, so it has to outlive the CPU's running.
 * @param context The context entries push; kept, so it has to outlive the CPU's running.
 * @param stacks The kernel stack and the critical events' stacks, their tops put in the TSS.
 */
init_cpu :: fn(
    system: ptr[ArchSystem],
    cpu: ptr[mut ArchCpu],
    carrier #escaping : ptr[mut runtime.CarrierBlock],
    context #escaping : ptr[runtime.Context],
    stacks: ptr[arch_interface.CpuStacks],
) {
    cpu.carrier = carrier
    cpu.context = context
    record_stacks(cpu, stacks)
    load_descriptor_tables(system, cpu)
    enable_cpu_features()
    enable_speculation_controls()
    cpu.xcr0 = XCR0_BASE
    features :: detect_features()
    cpu.xsaveopt = has(&features, .X86Xsaveopt)
    enable_control_flow(cpu, &features)
    init_paging(cpu)
    enable_system_calls()
    // The gs base after load_segments, which resets it
    x86_64.wrmsr(IA32_GS_BASE, cast[u64](cpu))
    x86_64.wrmsr(IA32_KERNEL_GS_BASE, 0)
    enable_local_apic()
}

/**
 * Record where the calling CPU's entries run, in its TSS, its SYSCALL scratch and its stack limits.
 *
 * Every entry runs on the kernel stack, through the interrupt stack table, including entries from idle: the kernel
 * stack holds nothing then, so each entry starts again at its top. The critical events get stacks of their own, since
 * they can arrive while the kernel stack is in use. The TSS is rebuilt from zero, with no I/O permission bitmap.
 *
 * @param cpu The CPU's state, whose tss, syscall.kernel_stack and stack limits are set.
 * @param stacks The kernel stack and the critical events' stacks, indexed by arch_interface.CriticalEvent.
 */
record_stacks :: fn(cpu: ptr[mut ArchCpu], stacks: ptr[arch_interface.CpuStacks]) {
    kernel_top :: cast[u64](stacks.kernel.high)
    cpu.syscall.kernel_stack = kernel_top
    cpu.tss = TaskStateSegment.{}
    cpu.tss.rsp[0] = kernel_top
    cpu.tss.ist[IST_KERNEL - 1] = kernel_top
    cpu.tss.ist[IST_NMI - 1] = cast[u64](stacks.critical[cast[u8](arch_interface.CriticalEvent.Nmi)].high)
    cpu.tss.ist[IST_DOUBLE_FAULT - 1] = cast[u64](stacks.critical[cast[u8](arch_interface.CriticalEvent.DoubleFault)].high)
    cpu.tss.ist[IST_MACHINE_CHECK - 1] = cast[u64](stacks.critical[cast[u8](arch_interface.CriticalEvent.MachineCheck)].high)
    cpu.tss.io_map_base = cast[u16](size_of(TaskStateSegment))
    cpu.kernel_stack_limit = stack_limit_of(stacks.kernel)
    for i in 0..<3 {
        cpu.critical_stack_limits[i] = stack_limit_of(stacks.critical[i])
    }
}

/**
 * Fill the calling CPU's GDT and load it, the kernel's segments, the TSS and the IDT.
 *
 * Loading the segments resets the fs and gs bases, so they're set after this.
 *
 * @param system The shared state whose IDT is loaded.
 * @param cpu The CPU's state, whose gdt is filled and whose tss is loaded, so it has to be filled first.
 */
load_descriptor_tables :: fn(system: ptr[ArchSystem], cpu: ptr[mut ArchCpu]) {
    cpu.gdt[0] = 0
    cpu.gdt[1] = KERNEL_CODE_DESCRIPTOR
    cpu.gdt[2] = KERNEL_DATA_DESCRIPTOR
    cpu.gdt[3] = USER_DATA_DESCRIPTOR
    cpu.gdt[4] = USER_CODE_DESCRIPTOR
    low, high := tss_descriptor(cast[u64](&cpu.tss))
    cpu.gdt[5] = low
    cpu.gdt[6] = high

    gdt_pointer := x86_64.DescriptorTablePointer.{cast[u16](size_of(u64) * GDT_ENTRIES - 1), cast[u64](&cpu.gdt)}
    x86_64.lgdt(&gdt_pointer)
    x86_64.load_segments(KERNEL_CODE_SELECTOR, KERNEL_DATA_SELECTOR)
    x86_64.ltr(TSS_SELECTOR)
    idt_pointer := x86_64.DescriptorTablePointer.{cast[u16](size_of(IdtEntry) * 256 - 1), cast[u64](&system.idt)}
    x86_64.lidt(&idt_pointer)
}

/**
 * Turn on the calling CPU's features: no-execute, SMEP, SMAP and PCIDs where the CPU has them, and the x87, SSE and
 * AVX state for user threads, XCR0 set to XCR0_BASE.
 *
 * The kernel itself never uses vector registers. PCIDs are only turned on when CR3's low 12 bits are 0, as the CPU
 * requires; init_paging records whether they were.
 */
enable_cpu_features :: fn() {
    x86_64.wrmsr(IA32_EFER, x86_64.rdmsr(IA32_EFER) | EFER_NO_EXECUTE_ENABLE)

    x86_64.write_cr0((x86_64.read_cr0() & ~CR0_EMULATION) | CR0_MONITOR_COPROCESSOR | CR0_NUMERIC_ERROR)

    features :: detect_features()
    cr4 := x86_64.read_cr4() | CR4_OSFXSR | CR4_OSXMMEXCPT | CR4_OSXSAVE
    if has(&features, .X86Smep) {
        cr4 |= CR4_SMEP
    }
    if has(&features, .X86Smap) {
        cr4 |= CR4_SMAP
    }
    /*
     * Not CR4.FSGSBASE: it would let user code set its own fs and gs bases, which every thread switch
     * would then have to save and restore. Hemera code has no thread-local storage (its carrier is
     * r14), and the kernel reads its gs base through the MSR (decisions/0050).
     */
    // PCIDE can only be set while CR3's low 12 bits are 0 (Intel SDM Vol. 3A §4.10.1)
    if has(&features, .X86Pcid) && (x86_64.read_cr3() & 0xfff) == 0 {
        cr4 |= CR4_PCID
    }
    x86_64.write_cr4(cr4)
    x86_64.xsetbv(0, XCR0_BASE)
}

/**
 * Turn on SYSCALL on the calling CPU: it enters at system_call_entry, in the kernel's code segment, with the trap,
 * interrupt, direction and alignment-check flags cleared, so interrupts are disabled.
 */
enable_system_calls :: fn() {
    x86_64.wrmsr(IA32_STAR, STAR_SYSCALL_SELECTORS | STAR_SYSRET_SELECTORS)
    x86_64.wrmsr(IA32_LSTAR, cast[u64](system_call_entry))
    x86_64.wrmsr(IA32_FMASK, SYSCALL_FLAGS_MASK)
    x86_64.wrmsr(IA32_EFER, x86_64.rdmsr(IA32_EFER) | EFER_SYSCALL_ENABLE)
}
