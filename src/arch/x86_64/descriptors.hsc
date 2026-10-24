package arch_x86_64

import runtime from "base"
import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"

// Model-specific registers and control register bits
//SPEC: Intel SDM Vol. 4 (MSRs), Vol. 3A §2.5 (control registers), §2.2.1 (EFER)
IA32_EFER : u32 : 0xc0000080
IA32_STAR : u32 : 0xc0000081
IA32_LSTAR : u32 : 0xc0000082
IA32_FMASK : u32 : 0xc0000084
IA32_FS_BASE : u32 : 0xc0000100
IA32_GS_BASE : u32 : 0xc0000101
IA32_KERNEL_GS_BASE : u32 : 0xc0000102

EFER_SYSCALL_ENABLE : u64 : 1 << 0
EFER_NO_EXECUTE_ENABLE : u64 : 1 << 11

/*
 * SYSCALL loads the kernel's code selector and the data one after it; 64-bit SYSRET loads user code
 * at the base plus 16 and user data at the base plus 8, so the base sits below user data.
 */
//SPEC: Intel SDM Vol. 3A §5.8.8 (fast system calls in 64-bit mode)
STAR_SYSCALL_SELECTORS : u64 : cast[u64](KERNEL_CODE_SELECTOR) << 32
STAR_SYSRET_SELECTORS : u64 : cast[u64](USER_DATA_SELECTOR - 8) << 48
// Flags SYSCALL clears: trap, interrupts, direction and alignment check
SYSCALL_FLAGS_MASK : u64 : (1 << 8) | (1 << 9) | (1 << 10) | (1 << 18)

CR0_MONITOR_COPROCESSOR : u64 : 1 << 1
CR0_EMULATION : u64 : 1 << 2
CR0_NUMERIC_ERROR : u64 : 1 << 5

CR4_OSFXSR : u64 : 1 << 9
CR4_OSXMMEXCPT : u64 : 1 << 10
CR4_PCID : u64 : 1 << 17
CR4_OSXSAVE : u64 : 1 << 18
CR4_SMEP : u64 : 1 << 20
CR4_SMAP : u64 : 1 << 21

// XCR0 state components: x87, SSE and AVX by default (decisions/0023)
XCR0_X87 : u64 : 1 << 0
XCR0_SSE : u64 : 1 << 1
XCR0_AVX : u64 : 1 << 2

// Code and data segments for 64-bit mode: base and limit are ignored, only the access bits matter.
//SPEC: Intel SDM Vol. 3A §3.4.5, Figure 3-8 (segment descriptors), §5.2.1 (code segments in 64-bit mode)
KERNEL_CODE_DESCRIPTOR : u64 : 0x00af9a000000ffff
KERNEL_DATA_DESCRIPTOR : u64 : 0x00cf92000000ffff
USER_DATA_DESCRIPTOR : u64 : 0x00cff2000000ffff
USER_CODE_DESCRIPTOR : u64 : 0x00affa000000ffff

/*
 * The two GDT entries of a 64-bit TSS descriptor for a TSS at base: present, DPL 0, type 9
 * (available 64-bit TSS).
 */
//SPEC: Intel SDM Vol. 3A §8.2.3, Figure 8-4 (TSS descriptor in 64-bit mode)
tss_descriptor :: fn(base: u64) -> (u64, u64) {
    limit :: cast[u64](size_of(TaskStateSegment) - 1)
    low := limit & 0xffff
    low |= (base & 0xffffff) << 16
    low |= cast[u64](0x89) << 40
    low |= ((limit >> 16) & 0xf) << 48
    low |= ((base >> 24) & 0xff) << 56
    return low, base >> 32
}

// An interrupt gate to handler, on interrupt stack table slot ist (0 for none).
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

// Set up the IDT. Called once, on the boot CPU, before init_cpu.
init_system :: fn(system: ptr[mut ArchSystem], firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) {
    for &entry in system.idt {
        entry^ = IdtEntry.{}
    }
    fill_idt(system)
    mask_legacy_pics()
}

/*
 * Set up the calling CPU: GDT and TSS with the stacks entries use, the IDT, no-execute, user-access
 * protection, address-space tags, the default vector state, and the gs base for entries.
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
    cpu.xcr0 = XCR0_BASE
    features :: detect_features()
    cpu.xsaveopt = has(&features, .X86Xsaveopt)
    init_paging(cpu)
    enable_system_calls()
    // The gs base after load_segments, which resets it
    x86_64.wrmsr(IA32_GS_BASE, cast[u64](cpu))
    x86_64.wrmsr(IA32_KERNEL_GS_BASE, 0)
    enable_local_apic()
}

/*
 * Every entry runs on the kernel stack, through the interrupt stack table, including entries from
 * idle: the kernel stack holds nothing then, so each entry starts again at its top. The critical
 * events get stacks of their own, since they can arrive while the kernel stack is in use.
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

/*
 * No-execute, user-access protection and address-space tags where the CPU has them, and the
 * x87, SSE and AVX state for user threads. The kernel itself never uses vector registers.
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

// SYSCALL enters at system_call_entry, with interrupts disabled.
enable_system_calls :: fn() {
    x86_64.wrmsr(IA32_STAR, STAR_SYSCALL_SELECTORS | STAR_SYSRET_SELECTORS)
    x86_64.wrmsr(IA32_LSTAR, cast[u64](system_call_entry))
    x86_64.wrmsr(IA32_FMASK, SYSCALL_FLAGS_MASK)
    x86_64.wrmsr(IA32_EFER, x86_64.rdmsr(IA32_EFER) | EFER_SYSCALL_ENABLE)
}
