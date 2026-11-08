/**
 * The AArch64 arch layer (L1): implements arch_interface (docs/specs/arch_interface.md, AArch64) for the
 * kernel core, which imports this package as arch.
 *
 * Everything but an NMI (not_yet_implemented.hsc): CPU setup, exception entry, paging, the GICv3 and its ITS
 * for MSIs, the generic timer, user mode and its vector state, the early console and the miscellaneous
 * functions, with the devices found in the device tree (roadmap A3 to A5, M7; decisions/0064 to 0066, 0073).
 */
package arch_aarch64

import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"
import concurrency from "std"

/**
 * One CPU's architecture state (arch_interface.ArchCpu).
 *
 * TPIDR_EL1 points at it, so entries find their CPU with current_cpu(); the early console tells it from a
 * console address by its 64-byte alignment (misc.hsc). It must not move after init_cpu, and L2 owns its memory.
 */
ArchCpu :: struct #align(64) {
    /** The CPU's carrier block, which entries load before calling the kernel; L2's, kept from init_cpu on. */
    carrier : ptr[mut runtime.CarrierBlock],
    /** The context entries push before calling the kernel; L2's, kept from init_cpu on. */
    context : ptr[runtime.Context],
    /** The kernel stack's stack_limit, runtime.STACK_GUARD bytes above its lowest address, which entries set. */
    kernel_stack_limit : rawptr,
    /**
     * The kernel stack's top, one past its highest address: where SP_EL1 starts from user mode and from idle, so
     * entries from there run on an empty stack.
     */
    kernel_stack_top : u64,
    /** The early console's registers, a virtual address through the direct map, or 0 without one (misc.hsc). */
    console : u64,
    /** The ArchSystem, as an address: L2 owns it, and it outlives every CPU (current_system). */
    system : u64,
    /** This CPU's MPIDR_EL1, its affinity fields (Aff3 to Aff0) only, as the bootloader names each CPU. */
    mpidr : u64,
    /** This CPU's GIC redistributor's registers, a virtual address through the direct map, or 0 if none was found. */
    redistributor : u64,
    /**
     * The GIC interrupt ID of the device interrupt this CPU took and hasn't ended yet, as ICC_IAR1_EL1 read it, which
     * end_of_interrupt ends; NO_ACTIVE_INTERRUPT when there's none.
     */
    active_interrupt : u32,
    /** Whether the CPU is still on the bootloader's page tables, until the first activate flushes its TLB. */
    bootloader_tables : bool,
    /** Whether a thread's breakpoints or stepping are in the debug registers (debug_on), so an entry turns them off. */
    debug_loaded : bool,
}

/**
 * The most 2 MiB blocks of device registers the kernel maps for L1 itself: the console's and the GIC's.
 *
 * A redistributor region is 128 KiB a CPU, which QEMU virt makes room for 123 of (8 blocks).
 */
MAX_DEVICE_BLOCKS :: 16

/**
 * State shared by every CPU (arch_interface.ArchSystem).
 *
 * It must not move after init_system, and L2 owns its memory. Addresses in it are virtual, through the direct map,
 * unless they're named physical.
 */
ArchSystem :: struct {
    /** The vector table every CPU's VBAR_EL1 points at (entries.hsc), a kernel virtual address. */
    vectors : u64,
    /** The early console's registers, through the direct map, or 0 without one. */
    console : u64,
    /** Whether the CPU has 16-bit ASIDs, which init_cpu turns on; 8-bit ones otherwise. */
    asid16 : bool,
    /** Whether the hardware sets a page's access flag as it's touched (FEAT_HAFDBS), which init_cpu turns on. */
    hardware_access_flag : bool,
    /** The GIC distributor's registers, through the direct map, from the device tree; 0 without a GIC. */
    distributor : u64,
    /** The GIC distributor's registers' physical address, which test_device reports; 0 without a GIC. */
    distributor_physical : u64,
    /** The GIC's redistributor region, through the direct map, from the device tree; 0 without a GIC. */
    redistributors : u64,
    /** The redistributor region's size in bytes, one redistributor's frames for each CPU. */
    redistributors_size : u64,
    /** The virtual timer's interrupt ID, a PPI (16 to 31), from the device tree or DEFAULT_TIMER_INTERRUPT. */
    timer_interrupt : u32,
    /**
     * The physical timer's interrupt ID, a PPI, which drives the test device (gic.hsc), from the device tree or
     * DEFAULT_TEST_TIMER_INTERRUPT.
     */
    test_timer_interrupt : u32,
    /**
     * The 2 MiB blocks of device registers mapped in the direct map, by physical address, 2 MiB-aligned
     * (paging.hsc); the first device_block_count are used.
     */
    device_blocks : u64[MAX_DEVICE_BLOCKS],
    /** How many of device_blocks are used, at most MAX_DEVICE_BLOCKS. */
    device_block_count : u32,
    /** Where physical address 0 is in the bootloader's and the kernel's direct map. */
    direct_map_offset : u64,
    /** Lines and LPIs routed to the kernel's device interrupt IDs (gic.hsc), read and written under routes_lock. */
    routes : Route[MAX_ROUTES],
    /** The lock that guards routes. */
    routes_lock : concurrency.SpinLock,
    /** The GIC's ITS, for message-signaled interrupts (its.hsc). */
    its : ItsState,
    /** Whether test_device_interrupts is on: the physical timer pends the test line while it is. */
    test_interrupts : bool,
}

/** User-mode registers saved at kernel entry (arch_interface.UserRegisters): what the entry function saves. */
UserRegisters :: struct {
    /** The interrupted code's registers, as aarch64.vector_table's generated code saves them on SP_EL1. */
    frame : aarch64.RegisterFrame,
}

/**
 * One thread's floating-point and SIMD state (arch_interface.VectorState): v0 to v31, then FPCR and FPSR, as
 * aarch64.save_fp_simd writes them (vector.hsc), 528 bytes, 16-byte aligned.
 */
VectorState :: struct #align(16) {
    /** v0 to v31, each 128 bits as two doublewords, the low one first. */
    registers : u64[64],
    /** The floating-point control register: rounding mode and trap enables. */
    fpcr : u64,
    /** The floating-point status register: the cumulative exception flags. */
    fpsr : u64,
}

/**
 * CPACR_EL1.FPEN (bits 20 and 21) set to 0b11: floating point and SIMD don't trap at EL0 or EL1, so threads' state
 * is switched eagerly (vector.hsc).
 */
CPACR_FP_ON : u64 : 3 << 20

/** SCTLR_EL1's SPAN (bit 23): kept clear, so taking an exception to EL1 sets PSTATE.PAN. */
SCTLR_SPAN : u64 : 1 << 23
/** PSTATE.PAN set, as the PAN register (S3_0_C4_C2_3) holds it, in bit 22. */
PAN_ON : u64 : 1 << 22

/**
 * Find the CPU these functions run on, through TPIDR_EL1, which init_cpu set.
 *
 * @return The calling CPU's ArchCpu. Only valid after init_cpu: before it, TPIDR_EL1 holds 0 or the early
 *     console's address (misc.hsc), not an ArchCpu.
 */
current_cpu :: fn() -> ptr[mut ArchCpu] {
    return cast[ptr[mut ArchCpu]](aarch64.read_system_register(.TPIDR_EL1))
}

/**
 * Find the ArchSystem every CPU shares, through the calling CPU's ArchCpu.
 *
 * @return The ArchSystem init_cpu recorded. Only valid after init_cpu, as current_cpu is.
 */
current_system :: fn() -> ptr[mut ArchSystem] {
    return cast[ptr[mut ArchSystem]](current_cpu().system)
}

/**
 * Compute a stack's stack_limit, the lowest address its code may use.
 *
 * @param stack The stack, whose low end has a guard below the limit.
 * @return The address runtime.STACK_GUARD bytes above the stack's lowest address.
 */
stack_limit_of :: fn(stack: arch_interface.StackRange) -> rawptr {
    return cast[rawptr](cast[u64](stack.low) + runtime.STACK_GUARD)
}

/**
 * Set up the state every CPU shares (arch_interface.init_system): the vector table, the early console, the CPU's
 * ASID size and access flag, and the GIC, its ITS and the timer's interrupts from the device tree, with the GIC's
 * and the ITS's registers mapped through the direct map (paging.hsc) and the distributor on.
 *
 * Called once, on the boot CPU, before init_cpu, on the bootloader's page tables. Without a device tree, or with a
 * GIC whose registers couldn't be mapped, there's no GIC (its addresses stay 0) and the timers' interrupts keep
 * their defaults.
 *
 * @param system The shared state to fill, L2's, which must not move afterwards.
 * @param firmware The firmware's tables, reached through the bootloader's direct map, which say where the device
 *     tree is.
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map.
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
    system.hardware_access_flag = has(&features, .Aarch64HardwareAccessFlag)
    system.timer_interrupt = DEFAULT_TIMER_INTERRUPT
    system.test_timer_interrupt = DEFAULT_TEST_TIMER_INTERRUPT
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
    its :: devicetree.find_compatible(&tree, "arm,gic-v3-its")
    if its is_some {
        node := its or_else devicetree.Node.{}
        registers :: devicetree.reg(&tree, &node, 0)
        if registers is_some {
            map_its(system, (registers or_else devicetree.Region.{}).address)
        }
    }
    timer :: devicetree.find_compatible(&tree, "arm,armv8-timer")
    if timer is_some {
        node := timer or_else devicetree.Node.{}
        // Four interrupts of three cells each: secure and non-secure physical, virtual, hypervisor
        interrupts :: devicetree.property(&tree, &node, "interrupts")
        if interrupts is_some {
            value :: interrupts or_else devicetree.Property.{}
            number :: devicetree.cell(value, 2 * 3 + 1)
            if number is_some {
                system.timer_interrupt = FIRST_PPI + (number or_else 0)
            }
            physical :: devicetree.cell(value, 1 * 3 + 1)
            if physical is_some {
                system.test_timer_interrupt = FIRST_PPI + (physical or_else 0)
            }
        }
    }
    if system.distributor != 0 {
        init_distributor(system)
    }
}

/**
 * Map the GIC's registers through the direct map and record where they are, if every 2 MiB block of them could be
 * mapped; otherwise leave the GIC's addresses 0, so there's no GIC.
 *
 * @param system The shared state, whose distributor and redistributor fields are set.
 * @param distributor The distributor's registers' physical address, DISTRIBUTOR_SIZE bytes of them.
 * @param redistributors The redistributor region's physical address.
 * @param redistributors_size The redistributor region's size in bytes.
 */
map_gic :: fn(system: ptr[mut ArchSystem], distributor: u64, redistributors: u64, redistributors_size: u64) {
    if !map_device_range(system, distributor, DISTRIBUTOR_SIZE) || !map_device_range(system, redistributors, redistributors_size) {
        return void
    }
    system.distributor_physical = distributor
    system.distributor = system.direct_map_offset + distributor
    system.redistributors = system.direct_map_offset + redistributors
    system.redistributors_size = redistributors_size
}

/**
 * Find the device tree through the direct map.
 *
 * @param firmware The firmware's tables, whose devicetree is the tree's physical address, if there is one.
 * @param direct_map_offset Where physical address 0 is in the direct map.
 * @return The device tree's virtual address through the direct map, or 0 without one.
 */
devicetree_address :: fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> u64 {
    physical :: firmware.devicetree or_return 0
    return direct_map_offset + cast[u64](physical)
}

/**
 * Set the calling CPU up (arch_interface.init_cpu): TPIDR_EL1 at its ArchCpu, the vector table, SP_EL1 at the
 * kernel stack's top, Privileged Access Never on and kept on at every exception, floating point on for user
 * threads (the kernel uses none), the memory attributes, 16-bit ASIDs where the CPU has them, with walks through
 * TTBR0 off until an address space is activated, and its GIC redistributor and CPU interface.
 *
 * A bootloader may start the kernel on SP_EL0 (PSTATE.SP clear), its boot stack, and every exception taken to EL1
 * switches to SP_EL1, so the kernel stack is where every entry runs, as the boot stack and the kernel stack
 * are on x86-64. A CPU already on SP_EL1 keeps taking exceptions on whatever stack it's on.
 *
 * Runs at EL1, on each CPU once, after init_system on the boot CPU. TPIDR_EL1 no longer holds the early console's
 * address afterwards; the console is found through the ArchCpu instead.
 *
 * @param system The shared state init_system set up, which must outlive the CPU.
 * @param cpu This CPU's state to fill, L2's, which must not move afterwards.
 * @param carrier The CPU's carrier block, kept in cpu for entries; it must outlive the CPU.
 * @param context The context entries push, kept in cpu; it must outlive the CPU.
 * @param stacks The CPU's stacks: only the kernel stack is used, since AArch64 has no separate stacks for
 *     critical events.
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
    cpu.active_interrupt = NO_ACTIVE_INTERRUPT
    cpu.bootloader_tables = true
    aarch64.write_system_register(.TPIDR_EL1, cast[u64](cpu))
    aarch64.write_system_register(.VBAR_EL1, system.vectors)
    if aarch64.read_system_register(.SPSel) & 1 == 0 {
        aarch64.write_sp_el1(cast[rawptr](stacks.kernel.high))
    }
    aarch64.write_system_register(.SCTLR_EL1, aarch64.read_system_register(.SCTLR_EL1) & ~SCTLR_SPAN)
    aarch64.write_system_register_encoded(3, 0, 4, 2, 3, PAN_ON)
    aarch64.write_system_register(.CPACR_EL1, CPACR_FP_ON)
    init_paging(system)
    init_cpu_interface(system, cpu)
    init_debug()
    aarch64.isb()
}
