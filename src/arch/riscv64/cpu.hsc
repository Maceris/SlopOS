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
import concurrency from "std:concurrency"
import slop_os from "std:os/slop_os"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"

/**
 * Whether the kernel goes on past its own address space on RISC-V: true since R4, it takes interrupts, starts the timer
 * and the other harts (the kernel's stop_before_interrupts).
 */
TAKES_INTERRUPTS :: true

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
    /** The hart's ID, its mhartid, as L2 gave it to init_cpu: supervisor mode can't read it. */
    hart_id : u64,
    /** The hart's supervisor context on the PLIC, its claim and threshold registers', or NO_CONTEXT without one. */
    plic_context : u32,
    /** The hart's supervisor interrupt file on the IMSIC, through the direct map, or 0 without an IMSIC. */
    imsic : u64,
    /**
     * The PLIC source this hart claimed and hasn't completed, which end_of_interrupt completes; NO_ACTIVE_LINE when
     * there's none.
     */
    active_line : u32,
    /**
     * The IPIs sent to this hart by the SBI and not yet taken, a bit for each IpiKind, set atomically by the senders.
     */
    ipis : u32,
    /** Whether the kernel's landing pads are on, from init_cpu (hardening.hsc, enable_landing_pads). */
    landing_pads : bool,
    /** The top of the hart's kernel shadow stack, from set_kernel_shadow_stack; 0 until then, or without one. */
    kernel_shadow_top : u64,
    /** Whether the kernel's shadow stacks are on, from the hart's first idle or return to user mode. */
    shadow_stacks_on : bool,
    /** senvcfg for the thread returning to user mode: its landing pads and shadow stack (load_user_control_flow). */
    user_envcfg : u64,
    /** The kernel's deadline on this hart, a time CSR value (set_deadline), or NO_DEADLINE when it has none. */
    deadline : u64,
    /**
     * When this hart next pends the test device's line, a time CSR value, or NO_DEADLINE when it doesn't
     * (test_device_interrupts). stimecmp holds the earlier of it and deadline.
     */
    test_deadline : u64,
}

/**
 * The most 2 MiB blocks of device registers the kernel maps for L1 itself: the console's and the interrupt
 * controllers'.
 */
MAX_DEVICE_BLOCKS :: 16
/** The most harts the kernel knows of, as the boot protocol's MAX_CPUS. */
MAX_HARTS :: 64

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
    /** The time CSR's frequency in Hz, the device tree's timebase-frequency; 0 if it doesn't say. */
    timebase : u64,
    /** The vector registers' length in bytes, vlenb, read once by init_system; 0 without V. */
    vlenb : u64,
    /** Whether the kernel and user threads can have shadow stacks: Zicfiss, and FWFT's SHADOW_STACK (hardening.hsc). */
    shadow_stacks : bool,
    /** Which interrupt controller the harts have, found in the device tree (interrupts.hsc). */
    controller : Controller,
    /** The harts the device tree lists, by hart ID, with their place on the interrupt controller (interrupts.hsc). */
    harts : Hart[MAX_HARTS],
    /** How many of harts are used, at most MAX_HARTS. */
    hart_count #at_most(harts.count) : u32,
    /** The PLIC's registers, through the direct map, or 0 without a PLIC. */
    plic : u64,
    /** The PLIC's registers' physical address, which test_device reports; 0 without a PLIC. */
    plic_physical : u64,
    /**
     * How many identities each hart's supervisor interrupt file has, the device tree's riscv,num-ids; 0 without one.
     */
    imsic_ids : u32,
    /** The supervisor-level APLIC's registers, through the direct map, or 0 without one. */
    aplic : u64,
    /** The supervisor-level APLIC's registers' physical address, which test_device reports; 0 without one. */
    aplic_physical : u64,
    /** How many sources the supervisor-level APLIC has, the device tree's riscv,num-sources. */
    aplic_sources : u32,
    /** The PLIC lines routed to the kernel's device interrupt IDs (interrupts.hsc), under routes_lock. */
    routes : Route[MAX_ROUTES],
    /** The lock that guards routes. */
    routes_lock : concurrency.SpinLock,
    /**
     * Whether test_device_interrupts is on: the hart that started it pends the test line TEST_DEVICE_HZ times a
     * second.
     */
    test_interrupts : bool,
    /** The hart test_device_interrupts was started on, which pends the test line. */
    test_hart : u64,
    /** The UART's line on the PLIC, the test device on a machine with a PLIC; 0 if the device tree doesn't say. */
    uart_line : u32,
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
 * kernel's own tables, the features from the device tree, how many ASID bits satp keeps, the time CSR's frequency, and
 * the interrupt controller, the PLIC or the AIA, with its registers mapped through the direct map (interrupts.hsc).
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
    find_shadow_stacks(system)
    if has(&system.features, .RiscvV) {
        // vlenb, which only reads with sstatus.VS on
        _ = riscv64.csrrs(.SSTATUS, SSTATUS_VS_INITIAL)
        system.vlenb = riscv64.csrr(.VLENB)
        _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_VS)
    }
    tree := devicetree.open(devicetree_address(firmware, direct_map_offset)) or_return void
    cpus := devicetree.find_node_named(&tree, "cpus") or_else devicetree.Node.{}
    if cpus.offset != 0 {
        match devicetree.property(&tree, &cpus, "timebase-frequency") {
            case Some(value) => system.timebase = cast[u64](devicetree.cell(value, 0) or_else 0)
            case None => {}
        }
    }
    init_controller(system, &tree)
}

/**
 * Map device registers through the direct map: in the bootloader's tables now (map_early_device), and in the kernel's
 * own once it's made, each 2 MiB block of them kept for init_kernel_page_table.
 *
 * Stops at the first block that can't be mapped, with the blocks before it mapped and kept.
 *
 * @param system The shared state, with the direct map's offset, whose device_blocks grows.
 * @param physical The registers' physical address.
 * @param size Their size in bytes; at least the block holding physical is mapped, even for 0.
 * @return True if every block was mapped; false if one couldn't be.
 */
map_device_range :: fn(system : ptr[mut ArchSystem], physical : u64, size : u64) -> bool {
    block := physical & ~(BLOCK_2M - 1)
    loop {
        if !map_early_device(system.direct_map_offset, block) {
            return false
        }
        add_device_block(system, block)
        block += BLOCK_2M
    }
    while block < physical + size
    return true
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
 * entry in direct mode, interrupts off in sstatus.SIE but its software, timer and external ones enabled in sie, the
 * timer's compare at its largest, user memory unreachable (SUM clear), floating point and vectors off, which the kernel
 * doesn't use, and its part of the interrupt controller (interrupts.hsc).
 *
 * Runs in supervisor mode, on each hart once, after init_system on the boot hart. tp no longer holds the early
 * console's word afterwards; the console is found through the ArchCpu instead.
 *
 * @param system The shared state init_system set up, which must outlive the hart.
 * @param cpu This hart's state to fill, L2's, which must not move afterwards.
 * @param hardware_id The hart's ID, which supervisor mode can't read for itself, kept in cpu.
 * @param carrier The hart's carrier block, kept in cpu for entries; it must outlive the hart.
 * @param context The context entries push, kept in cpu; it must outlive the hart.
 * @param stacks The hart's stacks: the kernel stack, for traps from user mode, and the DoubleFault critical stack, for
 *     exceptions in the kernel; RISC-V's supervisor has no NMI or machine check to take on the others.
 */
init_cpu :: fn(
    system : ptr[ArchSystem],
    cpu : ptr[mut ArchCpu],
    hardware_id : u64,
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
    cpu.hart_id = hardware_id
    cpu.active_line = NO_ACTIVE_LINE
    cpu.deadline = NO_DEADLINE
    cpu.test_deadline = NO_DEADLINE
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_SIE)
    riscv64.csrw(.SIE, 0)
    riscv64.write_tp(cast[rawptr](cpu))
    riscv64.csrw(.SSCRATCH, 0)
    riscv64.csrw(.STVEC, cast[u64](trap_entry))
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_SUM | riscv64.SSTATUS_FS | riscv64.SSTATUS_VS)
    riscv64.csrw(.STIMECMP, NO_DEADLINE)
    // User mode reads the time CSR, until a recorded process's thread runs (set_counter_trap)
    riscv64.csrw(.SCOUNTEREN, COUNTEREN_TIME)
    init_hart_controller(system, cpu)
    enable_landing_pads(system, cpu)
    riscv64.csrw(.SENVCFG, 0)
    riscv64.csrw(.SIE, SIE_SOFTWARE | SIE_TIMER | SIE_EXTERNAL)
}

/** sie's SSIE (bit 1): supervisor software interrupts, the SBI's IPIs. */
SIE_SOFTWARE : u64 : 1 << 1
/** sie's STIE (bit 5): supervisor timer interrupts, from stimecmp. */
SIE_TIMER : u64 : 1 << 5
/** sie's SEIE (bit 9): supervisor external interrupts, from the PLIC or the IMSIC. */
SIE_EXTERNAL : u64 : 1 << 9
