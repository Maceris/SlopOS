/*
 * The AArch64 arch layer (L1): implements arch_interface (docs/specs/arch_interface.md, AArch64) for the
 * kernel core, which imports this package as arch.
 *
 * So far (roadmap A3, decisions/0064): CPU setup, exception entry, paging, the early console and the
 * miscellaneous functions. Interrupts, the timer and other CPUs come with A4, user mode and vector state
 * with A5; until then they're stubs (not_yet_implemented.hsc), and the kernel stops before it needs them
 * (TAKES_INTERRUPTS).
 */
package arch_aarch64

import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"

/*
 * Whether the kernel can go on past its own address space: take interrupts, start the timer and the
 * other CPUs. Not yet on AArch64, so the kernel stops there (kernel.boot).
 */
TAKES_INTERRUPTS :: false

/*
 * One CPU's architecture state (arch_interface.ArchCpu). TPIDR_EL1 points at it, so entries find their
 * CPU with current_cpu(). Must not move after init_cpu.
 */
ArchCpu :: struct #align(64) {
    // What entries load before calling the kernel: the CPU's carrier block and context.
    carrier : ptr[mut runtime.CarrierBlock],
    context : ptr[runtime.Context],
    // The kernel stack: its stack_limit, set by entries from user mode, and its top, where they start.
    kernel_stack_limit : rawptr,
    kernel_stack_top : u64,
    // The early console's registers, through the direct map, or 0 without one (misc.hsc).
    console : u64,
    // Still on the bootloader's page tables, until the first activate.
    bootloader_tables : bool,
}

// State shared by every CPU (arch_interface.ArchSystem). Must not move after init_system.
ArchSystem :: struct {
    // The vector table every CPU's VBAR_EL1 points at (entries.hsc).
    vectors : u64,
    // The early console's registers, through the direct map, or 0.
    console : u64,
    // Whether the CPU has 16-bit ASIDs, which init_cpu turns on.
    asid16 : bool,
}

// User-mode registers saved at kernel entry (arch_interface.UserRegisters): what the entry function saves.
UserRegisters :: struct {
    frame : aarch64.RegisterFrame,
}

/*
 * One thread's floating-point and SIMD state (arch_interface.VectorState): v0 to v31, then FPCR and FPSR.
 * Saving and restoring it comes with user mode (A5).
 */
VectorState :: struct #align(16) {
    registers : u64[64],
    fpcr : u64,
    fpsr : u64,
}

/*
 * A wired interrupt controller (arch_interface.InterruptController): a GICv3 distributor, which comes with
 * A4. For now only where its registers are.
 */
InterruptController :: struct {
    registers : u64,
}

// SCTLR_EL1's SPAN (bit 23): clear, so taking an exception to EL1 sets PSTATE.PAN.
SCTLR_SPAN : u64 : 1 << 23
// PSTATE.PAN, as the PAN register (S3_0_C4_C2_3) holds it, in bit 22.
PAN_ON : u64 : 1 << 22

// The CPU these functions run on, found through TPIDR_EL1, which init_cpu set.
current_cpu :: fn() -> ptr[mut ArchCpu] {
    return cast[ptr[mut ArchCpu]](aarch64.read_system_register(.TPIDR_EL1))
}

// stack_limit for a stack: STACK_GUARD bytes above its lowest address.
stack_limit_of :: fn(stack: arch_interface.StackRange) -> rawptr {
    return cast[rawptr](cast[u64](stack.low) + runtime.STACK_GUARD)
}

// The vector table, which every CPU shares, and the early console, which init_cpu passes on to each CPU.
init_system :: fn(system: ptr[mut ArchSystem]) {
    system.vectors = cast[u64](aarch64.vector_table(exception_entry))
    system.console = console_address()
    features :: detect_features()
    system.asid16 = has(&features, .Aarch64Asid16)
}

/*
 * Set the calling CPU up: TPIDR_EL1 at its ArchCpu, the vector table, SP_EL1 at the kernel stack's top,
 * Privileged Access Never on and kept on at every exception, floating point trapping (the kernel uses
 * none), the memory attributes, and 16-bit ASIDs where the CPU has them, with walks through TTBR0 off
 * until an address space is activated.
 *
 * Limine starts the kernel on SP_EL0 (PSTATE.SP clear), its boot stack, and every exception taken to EL1
 * switches to SP_EL1, so the kernel stack is where every entry runs, as the boot stack and the kernel stack
 * are on x86-64. A CPU already on SP_EL1 keeps taking exceptions on whatever stack it's on.
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
    cpu.kernel_stack_limit = stack_limit_of(stacks.kernel)
    cpu.kernel_stack_top = cast[u64](stacks.kernel.high)
    cpu.console = system.console
    cpu.bootloader_tables = true
    aarch64.write_system_register(.TPIDR_EL1, cast[u64](cpu))
    aarch64.write_system_register(.VBAR_EL1, system.vectors)
    if aarch64.read_system_register(.SPSel) & 1 == 0 {
        aarch64.write_sp_el1(cast[rawptr](stacks.kernel.high))
    }
    aarch64.write_system_register(.SCTLR_EL1, aarch64.read_system_register(.SCTLR_EL1) & ~SCTLR_SPAN)
    aarch64.write_system_register_encoded(3, 0, 4, 2, 3, PAN_ON)
    aarch64.write_system_register(.CPACR_EL1, 0)
    init_paging(system)
    aarch64.isb()
}
