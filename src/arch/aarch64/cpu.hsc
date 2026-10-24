/*
 * The AArch64 arch layer (L1): implements arch_interface (docs/specs/arch_interface.md, AArch64) for the
 * kernel core, which imports this package as arch.
 *
 * So far (roadmap A4, decisions/0065): CPU setup, exception entry, paging, the GICv3, the generic timer, the
 * early console and the miscellaneous functions, with the devices found in the device tree. User mode and
 * vector state come with A5; until then they're stubs (not_yet_implemented.hsc).
 */
package arch_aarch64

import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"

/*
 * One CPU's architecture state (arch_interface.ArchCpu). TPIDR_EL1 points at it, so entries find their
 * CPU with current_cpu(). Must not move after init_cpu.
 */
ArchCpu :: struct #align(64) {
    // What entries load before calling the kernel: the CPU's carrier block and context.
    carrier : ptr[mut runtime.CarrierBlock],
    context : ptr[runtime.Context],
    // The kernel stack: its stack_limit, which entries set, and its top, where they start from user mode and idle.
    kernel_stack_limit : rawptr,
    kernel_stack_top : u64,
    // The early console's registers, through the direct map, or 0 without one (misc.hsc).
    console : u64,
    // The ArchSystem, as an address: L2 owns it, and it outlives every CPU (current_system).
    system : u64,
    // This CPU's MPIDR affinity, and its GIC redistributor's registers, or 0 if none was found.
    mpidr : u64,
    redistributor : u64,
    // Still on the bootloader's page tables, until the first activate.
    bootloader_tables : bool,
}

/*
 * Device blocks the kernel maps for L1 itself: the console's and the GIC's. A redistributor region is
 * 128 KiB a CPU, which QEMU virt makes room for 123 of (8 blocks).
 */
MAX_DEVICE_BLOCKS :: 16

// State shared by every CPU (arch_interface.ArchSystem). Must not move after init_system.
ArchSystem :: struct {
    // The vector table every CPU's VBAR_EL1 points at (entries.hsc).
    vectors : u64,
    // The early console's registers, through the direct map, or 0.
    console : u64,
    // Whether the CPU has 16-bit ASIDs, which init_cpu turns on.
    asid16 : bool,
    // The GIC's distributor and redistributor region, through the direct map, from the device tree, or 0.
    distributor : u64,
    distributor_physical : u64,
    redistributors : u64,
    redistributors_size : u64,
    // The virtual timer's interrupt ID.
    timer_interrupt : u32,
    // The 2 MiB blocks of device registers mapped in the direct map, by physical address (paging.hsc).
    device_blocks : u64[MAX_DEVICE_BLOCKS],
    device_block_count : u32,
    direct_map_offset : u64,
    // Lines routed to the kernel's device interrupt IDs (gic.hsc).
    routes : Route[MAX_ROUTES],
    // test_device_interrupts is on: the timer pends the test line.
    test_interrupts : bool,
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

// SCTLR_EL1's SPAN (bit 23): clear, so taking an exception to EL1 sets PSTATE.PAN.
SCTLR_SPAN : u64 : 1 << 23
// PSTATE.PAN, as the PAN register (S3_0_C4_C2_3) holds it, in bit 22.
PAN_ON : u64 : 1 << 22

// The CPU these functions run on, found through TPIDR_EL1, which init_cpu set.
current_cpu :: fn() -> ptr[mut ArchCpu] {
    return cast[ptr[mut ArchCpu]](aarch64.read_system_register(.TPIDR_EL1))
}

// The ArchSystem every CPU shares, through the calling CPU's.
current_system :: fn() -> ptr[mut ArchSystem] {
    return cast[ptr[mut ArchSystem]](current_cpu().system)
}

// stack_limit for a stack: STACK_GUARD bytes above its lowest address.
stack_limit_of :: fn(stack: arch_interface.StackRange) -> rawptr {
    return cast[rawptr](cast[u64](stack.low) + runtime.STACK_GUARD)
}

/*
 * What every CPU shares: the vector table, the early console, and the GIC and the timer's interrupt from the
 * device tree, with the GIC's registers mapped through the direct map (paging.hsc) and its distributor on.
 */
init_system :: fn(system: ptr[mut ArchSystem], firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) {
    system.vectors = cast[u64](aarch64.vector_table(exception_entry))
    system.direct_map_offset = direct_map_offset
    system.console = console_address()
    if system.console != 0 {
        add_device_block(system, system.console - direct_map_offset)
    }
    features :: detect_features()
    system.asid16 = has(&features, .Aarch64Asid16)
    system.timer_interrupt = DEFAULT_TIMER_INTERRUPT
    tree := devicetree.open(devicetree_address(firmware, direct_map_offset)) or_return void
    gic :: devicetree.find_compatible(&tree, "arm,gic-v3")
    if gic is_some {
        node := gic or_else devicetree.Node.{}
        distributor :: devicetree.reg(&tree, &node, 0)
        redistributors :: devicetree.reg(&tree, &node, 1)
        if (distributor is_some) && (redistributors is_some) {
            found :: redistributors or_else devicetree.Region.{}
            map_gic(system, (distributor or_else devicetree.Region.{}).address, found.address, found.size)
        }
    }
    timer :: devicetree.find_compatible(&tree, "arm,armv8-timer")
    if timer is_some {
        node := timer or_else devicetree.Node.{}
        // Four interrupts of three cells each: secure and non-secure physical, virtual, hypervisor
        interrupts :: devicetree.property(&tree, &node, "interrupts")
        if interrupts is_some {
            number :: devicetree.cell(interrupts or_else devicetree.Property.{}, 2 * 3 + 1)
            if number is_some {
                system.timer_interrupt = FIRST_PPI + (number or_else 0)
            }
        }
    }
    if system.distributor != 0 {
        init_distributor(system)
    }
}

// The GIC's registers, mapped through the direct map, if every block of them could be.
map_gic :: fn(system: ptr[mut ArchSystem], distributor: u64, redistributors: u64, redistributors_size: u64) {
    if !map_device_range(system, distributor, DISTRIBUTOR_SIZE) || !map_device_range(system, redistributors, redistributors_size) {
        return void
    }
    system.distributor_physical = distributor
    system.distributor = system.direct_map_offset + distributor
    system.redistributors = system.direct_map_offset + redistributors
    system.redistributors_size = redistributors_size
}

// The device tree's address through the direct map, or 0 without one.
devicetree_address :: fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> u64 {
    physical :: firmware.devicetree or_return 0
    return direct_map_offset + cast[u64](physical)
}

/*
 * Set the calling CPU up: TPIDR_EL1 at its ArchCpu, the vector table, SP_EL1 at the kernel stack's top,
 * Privileged Access Never on and kept on at every exception, floating point trapping (the kernel uses
 * none), the memory attributes, 16-bit ASIDs where the CPU has them, with walks through TTBR0 off until an
 * address space is activated, and its GIC redistributor and CPU interface.
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
    cpu.system = cast[u64](system)
    cpu.mpidr = affinity_of_this_cpu()
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
    init_cpu_interface(system, cpu)
    aarch64.isb()
}
