/**
 * The RISC-V arch layer (L1): implements arch_interface (docs/specs/arch_interface.md, RISC-V) for the kernel core,
 * which imports this package as arch.
 *
 * So far (roadmap M19's R3, decisions/0199): the features from the device tree and RVA23's baseline, trap entry
 * through stvec, Sv48 paging with Svpbmt's memory types, the device tree's 16550 UART as the early console, the SBI's
 * system reset, and semihosting for test_exit. The interrupt controllers, the timer and the other harts are R4, user
 * mode and its vector state R5, the IOMMU and control-flow integrity R6 (not_yet_implemented.hsc); until R4 the kernel
 * stops after its own address space (TAKES_INTERRUPTS).
 */
package arch_riscv64

import riscv64 from "base:intrinsics/riscv64"
import runtime from "base:runtime"
import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"

/**
 * Whether the kernel goes on past its own address space on RISC-V: not yet, until R4 brings the interrupt
 * controllers, the timer and the other harts (the kernel's stop_before_interrupts).
 */
TAKES_INTERRUPTS :: false

/**
 * One hart's architecture state (arch_interface.ArchCpu).
 *
 * In the kernel, tp points at it, so entries find their hart with current_cpu(); in user mode, sscratch does, and a
 * trap from there swaps the two (Hemera's riscv64.TrapScratch), so it starts with its TrapScratch. Before init_cpu, tp
 * holds the early console's word instead (misc.hsc), which is odd. It must not move after init_cpu, and L2 owns its
 * memory.
 */
ArchCpu :: struct #align(64) {
    /** What a trap from user mode needs first: the kernel stack's top, where it runs, and room for user mode's sp. */
    scratch : riscv64.TrapScratch,
    /** The hart's carrier block, which entries load before calling the kernel; L2's, kept from init_cpu on. */
    carrier : ptr[mut runtime.CarrierBlock],
    /** The context entries push before calling the kernel; L2's, kept from init_cpu on. */
    context : ptr[runtime.Context],
    /** The kernel stack's stack_limit, with room for a trap's frame below it as well as the guard (stack_limit_of). */
    kernel_stack_limit : rawptr,
    /** The kernel stack's top, one past its highest address: where a trap from user mode starts. */
    kernel_stack_top : u64,
    /**
     * The top of the stack an exception in the kernel is handled on, CpuStacks.critical's DoubleFault one, so one that
     * ran its stack out (the stack check's ebreak) has room (entries.hsc).
     */
    trap_stack_top : u64,
    /** That stack's stack_limit. */
    trap_stack_limit : rawptr,
    /** The early console's word, through the direct map (misc.hsc), or 0 without one. */
    console : u64,
    /** The ArchSystem, as an address: L2 owns it, and it outlives every hart (current_system). */
    system : u64,
    /** Whether the hart is still on the bootloader's page tables, until the first activate flushes its TLB. */
    bootloader_tables : bool,
}

/**
 * The most 2 MiB blocks of device registers the kernel maps for L1 itself: the console's, and from R4 the interrupt
 * controllers'.
 */
MAX_DEVICE_BLOCKS :: 16

/**
 * State shared by every hart (arch_interface.ArchSystem).
 *
 * It must not move after init_system, and L2 owns its memory. Addresses in it are virtual, through the direct map,
 * unless they're named physical.
 */
ArchSystem :: struct {
    /** The early console's word, through the direct map, or 0 without one (misc.hsc). */
    console : u64,
    /** The boot hart's features, from the device tree, every hart being alike. */
    features : slop_os.CpuFeatures,
    /** How many ASID bits satp keeps, 0 to 16 (paging.hsc). */
    asid_bits : u32,
    /** How the machine resets and turns off, as reset_method found it: 1 for the SBI's system reset, 0 for none. */
    reset : u8,
    /**
     * The 2 MiB blocks of device registers mapped in the direct map, by physical address, 2 MiB-aligned (paging.hsc);
     * the first device_block_count are used.
     */
    device_blocks : u64[MAX_DEVICE_BLOCKS],
    /** How many of device_blocks are used, at most MAX_DEVICE_BLOCKS. */
    device_block_count : u32,
    /** Where physical address 0 is in the bootloader's and the kernel's direct map. */
    direct_map_offset : u64,
}

/** User-mode registers saved at kernel entry (arch_interface.UserRegisters): what the entry function saves. */
UserRegisters :: struct {
    /** The interrupted code's registers, as the entry function's generated code saves them on the kernel stack. */
    frame : riscv64.RegisterFrame,
}

/**
 * One thread's floating-point and vector state (arch_interface.VectorState): f0 to f31 and fcsr here, then the vector
 * registers, vlenb bytes each, and vstart, vtype, vl and vcsr, after it, which vector_state_size counts (R5).
 */
VectorState :: struct #align(16) {
    /** f0 to f31, 64 bits each, D's registers. */
    floating : u64[32],
    /** The floating-point control and status register: the rounding mode and the accrued exception flags. */
    fcsr : u64,
}

/**
 * A thread's debugging state (arch_interface.DebugRegisters): whether it steps, and its triggers, as the SBI's debug
 * triggers extension takes them (R5). All zero is none.
 */
DebugRegisters :: struct {
    /** Whether the thread stops after each instruction it runs in user mode. */
    step : bool,
    /** Each trigger's tdata1, its kind and what it matches, 0 for none: up to slop_os.DEBUG_SLOTS of them. */
    triggers : u64[4],
    /** Each trigger's tdata2, the address it matches. */
    addresses : u64[4],
}

/** One wired interrupt controller the platform service registered (arch_interface.InterruptController), from R4. */
InterruptController :: struct {
    /** Which kind it is: the PLIC or an APLIC. */
    kind : arch_interface.ControllerKind,
    /** Where L2 mapped its registers, as Device memory. */
    registers : u64,
    /** How many lines it has, numbered from 0 (the PLIC's source 0 is none, so line n is its source n). */
    lines : u32,
}

/** The bytes a trap's frame takes below a stack's limit, past the guard: RegisterFrame's 288, rounded up. */
TRAP_FRAME_ROOM : u64 : 512

#assert cast[u64](size_of(riscv64.RegisterFrame)) <= TRAP_FRAME_ROOM

/**
 * Find the hart these functions run on, through tp, which init_cpu set.
 *
 * @return The calling hart's ArchCpu. Only valid after init_cpu: before it, tp holds 0 or the early console's word
 *     (misc.hsc), not an ArchCpu.
 */
current_cpu :: fn() -> ptr[mut ArchCpu] {
    return cast[ptr[mut ArchCpu]](riscv64.read_tp())
}

/**
 * Find the ArchSystem every hart shares, through the calling hart's ArchCpu.
 *
 * @return The ArchSystem init_cpu recorded. Only valid after init_cpu, as current_cpu is.
 */
current_system :: fn() -> ptr[mut ArchSystem] {
    return cast[ptr[mut ArchSystem]](current_cpu().system)
}

/**
 * Compute a stack's stack_limit, the lowest address its code may use: above the guard, with room below it for a trap's
 * frame, since a trap in the kernel builds its frame on the stack it came from, wherever that is.
 *
 * @param stack The stack.
 * @return The address runtime.STACK_GUARD and TRAP_FRAME_ROOM bytes above the stack's lowest address.
 */
stack_limit_of :: fn(stack : arch_interface.StackRange) -> rawptr {
    return cast[rawptr](cast[u64](stack.low) + runtime.STACK_GUARD + TRAP_FRAME_ROOM)
}

/**
 * Set up the state every hart shares (arch_interface.init_system): the early console's registers, kept for the
 * kernel's own tables, the features from the device tree, and how many ASID bits satp keeps.
 *
 * Called once, on the boot hart, before init_cpu, on the bootloader's page tables.
 *
 * @param system The shared state to fill, L2's, which must not move afterwards.
 * @param firmware The firmware's tables, reached through the bootloader's direct map, which say where the device tree
 *     is.
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map.
 */
init_system :: fn(system : ptr[mut ArchSystem], firmware : ptr[boot_info.FirmwareTables], direct_map_offset : u64) {
    system.direct_map_offset = direct_map_offset
    system.console = console_word()
    if system.console != 0 {
        add_device_block(system, console_base(system.console) - direct_map_offset)
    }
    system.features = detect_features(firmware, direct_map_offset)
    system.asid_bits = probe_asid_bits()
}

/**
 * Keep the 2 MiB block holding some device registers, for the kernel's own table, unless it's kept already.
 *
 * Asserts there's room for it, MAX_DEVICE_BLOCKS in all.
 *
 * @param system The shared state, whose device_blocks grows.
 * @param physical A physical address in the block; it's rounded down to 2 MiB.
 */
add_device_block :: fn(system : ptr[mut ArchSystem], physical : u64) {
    block :: physical & ~(BLOCK_2M - 1)
    count :: cast[usize](system.device_block_count)
    for kept, i in system.device_blocks {
        if i < count && kept == block {
            return void
        }
    }
    runtime.assert(count < MAX_DEVICE_BLOCKS, "room for L1's device blocks")
    if count < MAX_DEVICE_BLOCKS {
        system.device_blocks[count] = block
        system.device_block_count += 1
    }
}

/**
 * Find the device tree through the direct map.
 *
 * @param firmware The firmware's tables, whose devicetree is the tree's physical address, if there is one.
 * @param direct_map_offset Where physical address 0 is in the direct map.
 * @return The device tree's virtual address through the direct map, or 0 without one.
 */
devicetree_address :: fn(firmware : ptr[boot_info.FirmwareTables], direct_map_offset : u64) -> u64 {
    physical :: firmware.devicetree or_return 0
    return direct_map_offset + cast[u64](physical)
}

/**
 * Set the calling hart up (arch_interface.init_cpu): tp at its ArchCpu, sscratch 0 for the kernel, stvec at the trap
 * entry in direct mode, interrupts off (sstatus.SIE, and sie), user memory unreachable (SUM clear), and floating point
 * and vectors off, which the kernel doesn't use.
 *
 * Runs in supervisor mode, on each hart once, after init_system on the boot hart. tp no longer holds the early
 * console's
 * word afterwards; the console is found through the ArchCpu instead.
 *
 * @param system The shared state init_system set up, which must outlive the hart.
 * @param cpu This hart's state to fill, L2's, which must not move afterwards.
 * @param carrier The hart's carrier block, kept in cpu for entries; it must outlive the hart.
 * @param context The context entries push, kept in cpu; it must outlive the hart.
 * @param stacks The hart's stacks: the kernel stack, for traps from user mode, and the DoubleFault critical stack, for
 *     exceptions in the kernel; RISC-V's supervisor has no NMI or machine check to take on the others.
 */
init_cpu :: fn(
    system : ptr[ArchSystem],
    cpu : ptr[mut ArchCpu],
    carrier #escaping : ptr[mut runtime.CarrierBlock],
    context #escaping : ptr[runtime.Context],
    stacks : ptr[arch_interface.CpuStacks]
) {
    cpu.carrier = carrier
    cpu.context = context
    cpu.kernel_stack_limit = stack_limit_of(stacks.kernel)
    cpu.kernel_stack_top = cast[u64](stacks.kernel.high)
    cpu.scratch.kernel_stack = cpu.kernel_stack_top
    trap_stack :: stacks.critical[cast[u8](arch_interface.CriticalEvent.DoubleFault)]
    cpu.trap_stack_top = cast[u64](trap_stack.high)
    cpu.trap_stack_limit = cast[rawptr](cast[u64](trap_stack.low) + runtime.STACK_GUARD)
    cpu.console = system.console
    cpu.system = cast[u64](system)
    cpu.bootloader_tables = true
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_SIE)
    riscv64.csrw(.SIE, 0)
    riscv64.write_tp(cast[rawptr](cpu))
    riscv64.csrw(.SSCRATCH, 0)
    riscv64.csrw(.STVEC, cast[u64](trap_entry))
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_SUM | riscv64.SSTATUS_FS | riscv64.SSTATUS_VS)
}
