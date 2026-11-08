package arch_aarch64

import intrinsics from "base"
import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import kernel_entry from "../../kernel/entry"
import concurrency from "std"

/*
 * The GICv3 (docs/specs/arch_interface.md, AArch64): the distributor for shared peripheral interrupts (SPIs),
 * each CPU's redistributor for its SGIs (the IPIs) and PPIs (the timer), and each CPU's interface through the
 * ICC system registers. Every interrupt is in group 1, at one priority, with EOImode 0, so writing ICC_EOIR1
 * both drops the priority and deactivates it.
 *
 * An SPI's interrupt ID is its line's (32 + line), which software can't choose, so the kernel's device
 * interrupt IDs are translated: routes records which ID each line was routed to on which CPU. So for the LPIs
 * message-signaled interrupts raise (its.hsc).
 */
//SPEC: Arm GICv3 and GICv4 Architecture Specification (IHI 0069): §12.9 (GICD_*), §12.10/12.11 (GICR_* and the SGI frame), §12.2 (ICC_*_EL1)

// Distributor registers
/** GICD_CTLR's offset in the distributor: the distributor's control register. */
GICD_CTLR : u64 : 0x0000
/** GICD_TYPER's offset: what the distributor implements, ITLinesNumber in bits 0 to 4. */
GICD_TYPER : u64 : 0x0004
/** GICD_IGROUPR's offset: the interrupt group registers, a bit an interrupt ID, 32 to a word. */
GICD_IGROUPR : u64 : 0x0080
/** GICD_ISENABLER's offset: the set-enable registers, a bit an interrupt ID, 32 to a word; writing 1 enables. */
GICD_ISENABLER : u64 : 0x0100
/** GICD_ICENABLER's offset: the clear-enable registers, as GICD_ISENABLER; writing 1 disables. */
GICD_ICENABLER : u64 : 0x0180
/** GICD_ISPENDR's offset: the set-pending registers, a bit an interrupt ID; writing 1 pends it. */
GICD_ISPENDR : u64 : 0x0200
/** GICD_ICPENDR's offset: the clear-pending registers, a bit an interrupt ID; writing 1 clears its pending state. */
GICD_ICPENDR : u64 : 0x0280
/** GICD_IPRIORITYR's offset: the priority registers, a byte an interrupt ID. */
GICD_IPRIORITYR : u64 : 0x0400
/** GICD_ICFGR's offset: the configuration registers, two bits an interrupt ID, the upper one set for edge-triggered. */
GICD_ICFGR : u64 : 0x0c00
/** GICD_IROUTER's offset: the routing registers, 8 bytes an interrupt ID, holding the target CPU's affinity. */
GICD_IROUTER : u64 : 0x6000
/**
 * GICD_CTLR with affinity routing (ARE, bit 4) and group 1 on: with security, EnableGrp1NS (bit 1); without,
 * EnableGrp1 (bit 1), besides EnableGrp0 (bit 0).
 */
GICD_CTLR_ENABLE : u32 : (1 << 4) | (1 << 1) | 1
/** GICD_CTLR.RWP (bit 31): a write to GICD_CTLR is still taking effect. */
GICD_CTLR_WRITE_PENDING : u32 : 1 << 31
/** The distributor's registers' size in bytes: 64 KiB. */
DISTRIBUTOR_SIZE : u64 : 0x10000

// Redistributor registers: the RD frame, then the SGI frame 64 KiB on
/** GICR_TYPER's offset in the RD frame: the redistributor's affinity in bits 32 to 63, and what it implements. */
GICR_TYPER : u64 : 0x0008
/** GICR_WAKER's offset in the RD frame: whether the redistributor's CPU is asleep. */
GICR_WAKER : u64 : 0x0014
/** Where the SGI frame starts in a redistributor's registers, in bytes from the RD frame's start. */
GICR_SGI_FRAME : u64 : 0x10000
/** GICR_IGROUPR0's offset in the SGI frame: the group of each SGI and PPI, a bit an interrupt ID 0 to 31. */
GICR_IGROUPR0 : u64 : 0x0080
/** GICR_ISENABLER0's offset in the SGI frame: writing 1 enables an SGI or PPI. */
GICR_ISENABLER0 : u64 : 0x0100
/** GICR_ICENABLER0's offset in the SGI frame: writing 1 disables an SGI or PPI. */
GICR_ICENABLER0 : u64 : 0x0180
/** GICR_IPRIORITYR's offset in the SGI frame: the SGIs' and PPIs' priorities, a byte each. */
GICR_IPRIORITYR : u64 : 0x0400
/** GICR_WAKER.ProcessorSleep (bit 1): set while the CPU is asleep; cleared to wake the redistributor. */
WAKER_PROCESSOR_SLEEP : u32 : 1 << 1
/** GICR_WAKER.ChildrenAsleep (bit 2): set until the redistributor has woken. */
WAKER_CHILDREN_ASLEEP : u32 : 1 << 2
// GICR_TYPER: the last redistributor in the region, and one with virtual LPIs, whose frames are twice as many
/** GICR_TYPER.Last (bit 4): this is the last redistributor in its region. */
TYPER_LAST : u64 : 1 << 4
/** GICR_TYPER.VLPIS (bit 1): the redistributor has virtual LPIs, so its frames take two strides, not one. */
TYPER_VIRTUAL_LPIS : u64 : 1 << 1
/** The bytes from one redistributor's frames to the next's: an RD frame and an SGI frame, 64 KiB each. */
REDISTRIBUTOR_STRIDE : u64 : 0x20000

/** ICC_SRE_EL1 with SRE, DFB and DIB set: the system register interface on, with FIQ and IRQ bypass off. */
SRE_ENABLE : u64 : 0x7
// Every interrupt one priority, which the mask lets through
/** The priority every interrupt is given, lower numbers being higher priority. */
INTERRUPT_PRIORITY : u8 : 0xa0
/** ICC_PMR_EL1's value: interrupts of a priority below 0xf0, as INTERRUPT_PRIORITY is, are let through. */
PRIORITY_MASK : u64 : 0xf0

// Interrupt IDs: SGIs, PPIs, SPIs, and the special ones from 1020
/** The first PPI's interrupt ID; SGIs are 0 to 15. */
FIRST_PPI : u32 : 16
/** The first SPI's interrupt ID, line 0's. */
FIRST_SPI : u32 : 32
/** The first special interrupt ID (1020 to 1023), which ICC_IAR1_EL1 reads as when there's nothing to take. */
FIRST_SPECIAL : u32 : 1020
// The IPIs, as SGIs
/** The SGI for IpiKind.Reschedule. */
SGI_RESCHEDULE : u32 : 1
/** The SGI for IpiKind.TlbFlush. */
SGI_TLB_FLUSH : u32 : 2
/** The SGI for IpiKind.Stop. */
SGI_STOP : u32 : 3
// The virtual and the physical timer's PPIs where the device tree doesn't say
/** The virtual timer's PPI where the device tree doesn't say: 27. */
DEFAULT_TIMER_INTERRUPT : u32 : 27
/** The non-secure physical timer's PPI where the device tree doesn't say: 30. */
DEFAULT_TEST_TIMER_INTERRUPT : u32 : 30
/** The test device's rate, in interrupts a second: about a thousand. */
TEST_DEVICE_HZ : u64 : 1000

// The kernel's device interrupt IDs, on each CPU
/** The first of the kernel's device interrupt IDs; they're the kernel's own, translated through routes. */
FIRST_DEVICE_ID : u32 : 32
/** How many device interrupt IDs the kernel may give, from FIRST_DEVICE_ID. */
DEVICE_ID_COUNT : u32 : 224
/** How many routes ArchSystem keeps, lines and LPIs together. */
MAX_ROUTES :: 256
/** What device_id_for returns for an interrupt with no route. */
NO_ROUTE : u32 : 0xffffffff

/** The test device's line (arch_interface.test_device): an SPI no device on QEMU virt uses, pended in software. */
TEST_LINE : u32 : 100

/** One interrupt, a line's SPI or an LPI, routed to one of the kernel's device interrupt IDs on one CPU. */
Route :: struct {
    /** Whether this slot holds a route; the other fields mean nothing when it doesn't. */
    used : bool,
    /** The CPU's MPIDR, its affinity fields only, as ArchCpu.mpidr is. */
    cpu : u64,
    /** The kernel's device interrupt ID on that CPU, from device_interrupt_range. */
    id : u32,
    /** The GIC's interrupt ID: 32 + line for an SPI, from FIRST_LPI for an LPI. */
    interrupt : u32,
}

/** A GICv3 distributor L2 registered (arch_interface.InterruptController), through L2's mapping. */
InterruptController :: struct {
    /** The distributor's registers, a virtual address in L2's mapping. */
    registers : u64,
    /** How many SPI lines it has, numbered from 0; line n is interrupt ID 32 + n. */
    lines : u32,
}

/**
 * Turn the distributor on, through L1's own mapping, for what every CPU shares: affinity routing and group 1.
 *
 * Disables it first and waits for each write to take effect (GICD_CTLR.RWP).
 *
 * @param system The shared state, whose distributor is mapped (non-zero).
 */
init_distributor :: fn(system: ptr[mut ArchSystem]) {
    base :: system.distributor
    write_u32(base, GICD_CTLR, 0)
    wait_for_distributor(base)
    write_u32(base, GICD_CTLR, GICD_CTLR_ENABLE)
    wait_for_distributor(base)
}

/**
 * Wait, spinning without a timeout, until the distributor's last GICD_CTLR write has taken effect.
 *
 * @param base The distributor's registers, a virtual address.
 */
wait_for_distributor :: fn(base: u64) {
    loop {
        intrinsics.spin_hint()
    }
    while read_u32(base, GICD_CTLR) & GICD_CTLR_WRITE_PENDING != 0
}

/**
 * Set up the calling CPU's GIC: its redistributor awake, with its SGIs and the timers' PPIs in group 1, enabled,
 * every other PPI disabled; then its CPU interface on, letting every interrupt's priority through.
 *
 * Without a redistributor for the CPU, only the CPU interface is set up. Waking the redistributor spins without
 * a timeout.
 *
 * @param system The shared state, with the redistributor region and the timers' interrupt IDs.
 * @param cpu The calling CPU's state, whose mpidr is set; its redistributor is set here, 0 if none was found.
 */
init_cpu_interface :: fn(system: ptr[ArchSystem], cpu: ptr[mut ArchCpu]) {
    cpu.redistributor = find_redistributor(system, cpu.mpidr)
    base :: cpu.redistributor
    if base != 0 {
        write_u32(base, GICR_WAKER, read_u32(base, GICR_WAKER) & ~WAKER_PROCESSOR_SLEEP)
        loop {
            intrinsics.spin_hint()
        }
        while read_u32(base, GICR_WAKER) & WAKER_CHILDREN_ASLEEP != 0
        sgi :: base + GICR_SGI_FRAME
        write_u32(sgi, GICR_ICENABLER0, 0xffffffff)
        write_u32(sgi, GICR_IGROUPR0, 0xffffffff)
        for i in 0..<32 {
            write_u8(sgi, GICR_IPRIORITYR + cast[u64](i), INTERRUPT_PRIORITY)
        }
        write_u32(sgi, GICR_ISENABLER0, 0xffff | (cast[u32](1) << system.timer_interrupt) | (cast[u32](1) << system.test_timer_interrupt))
    }
    aarch64.write_system_register(.ICC_SRE_EL1, SRE_ENABLE)
    aarch64.isb()
    aarch64.write_system_register(.ICC_PMR_EL1, PRIORITY_MASK)
    aarch64.write_system_register(.ICC_BPR1_EL1, 0)
    aarch64.write_system_register(.ICC_CTLR_EL1, 0)
    aarch64.write_system_register(.ICC_IGRPEN1_EL1, 1)
    aarch64.isb()
}

/**
 * Find a CPU's redistributor in the region the device tree gave, walking its frames until GICR_TYPER.Last.
 *
 * @param system The shared state, with the redistributor region, 0 without one.
 * @param mpidr The CPU's MPIDR, its affinity fields (Aff3 in bits 32 to 39, Aff2 to Aff0 in bits 0 to 23).
 * @return The redistributor's registers, a virtual address through the direct map; 0 without a region, or if no
 *     redistributor in it has that affinity.
 */
find_redistributor :: fn(system: ptr[ArchSystem], mpidr: u64) -> u64 {
    if system.redistributors == 0 {
        return 0
    }
    affinity :: ((mpidr >> 32) & 0xff) << 24 | (mpidr & 0xffffff)
    frame := system.redistributors
    end :: system.redistributors + system.redistributors_size
    loop {
        if frame + REDISTRIBUTOR_STRIDE > end {
            return 0
        }
        typer :: read_u64(frame, GICR_TYPER)
        if typer >> 32 == affinity {
            return frame
        }
        if typer & TYPER_LAST != 0 {
            return 0
        }
        frame += if typer & TYPER_VIRTUAL_LPIS != 0 { 2 * REDISTRIBUTOR_STRIDE } else { REDISTRIBUTOR_STRIDE }
    }
}

/**
 * Read the calling CPU's MPIDR_EL1, its affinity fields only, as the bootloader gives each CPU's.
 *
 * @return Aff3 (bits 32 to 39) and Aff2 to Aff0 (bits 0 to 23), every other bit clear: the CPU's hardware ID.
 */
affinity_of_this_cpu :: fn() -> u64 {
    return aarch64.read_system_register(.MPIDR_EL1) & 0xff00ffffff
}

/**
 * Take the IRQ the calling CPU is entering for, from ICC_IAR1_EL1, and say what raised it.
 *
 * The timer, IPIs and interrupts with no route are acknowledged here; a routed device interrupt is the kernel's to
 * acknowledge (end_of_interrupt), and a spurious one isn't acknowledged at all. The virtual timer is disabled until
 * the next deadline, so the level it holds doesn't raise it again; the physical timer, the test device's clock,
 * pends the test line and rearms while the test device is on, and is disabled otherwise.
 *
 * @return Device with the kernel's ID for a routed SPI or LPI; Timer for the virtual timer; Ipi for the SGIs
 *     send_ipi raises; Spurious for a special ID, an SPI or LPI with no route on this CPU, the test device's
 *     clock, or any other SGI or PPI.
 */
interrupt_source :: fn() -> kernel_entry.InterruptSource {
    cpu :: current_cpu()
    system :: current_system()
    interrupt :: cast[u32](aarch64.read_system_register(.ICC_IAR1_EL1) & 0xffffff)
    if interrupt >= FIRST_SPECIAL && interrupt < FIRST_LPI {
        return .Spurious
    }
    if interrupt >= FIRST_SPI {
        id :: device_id_for(system, cpu.mpidr, interrupt)
        if id != NO_ROUTE {
            // Ended as the GIC gave it, whatever its route becomes meanwhile
            cpu.active_interrupt = interrupt
            return .Device(cast[arch_interface.InterruptId](id))
        }
        acknowledge(interrupt)
        return .Spurious
    }
    acknowledge(interrupt)
    if interrupt == system.timer_interrupt {
        // Until the next deadline, so the level the timer holds doesn't raise it again
        aarch64.write_system_register(.CNTV_CTL_EL0, 0)
        return .Timer
    }
    if interrupt == system.test_timer_interrupt {
        // The test device's clock: its line pended, and the next in a thousandth of a second, while it's on
        if system.test_interrupts {
            pend_test_line(system)
            aarch64.write_system_register(.CNTP_TVAL_EL0, aarch64.read_system_register(.CNTFRQ_EL0) / TEST_DEVICE_HZ)
        }
        else {
            aarch64.write_system_register(.CNTP_CTL_EL0, 0)
        }
        return .Spurious
    }
    return match interrupt {
        case SGI_RESCHEDULE => .Ipi(.Reschedule)
        case SGI_TLB_FLUSH => .Ipi(.TlbFlush)
        case SGI_STOP => .Ipi(.Stop)
        case _ => .Spurious
    }
}

/**
 * Acknowledge an interrupt to the calling CPU's interface: with EOImode 0, writing ICC_EOIR1_EL1 drops its
 * priority and deactivates it.
 *
 * @param interrupt The GIC's interrupt ID, as ICC_IAR1_EL1 read it.
 */
acknowledge :: fn(interrupt: u32) {
    aarch64.write_system_register(.ICC_EOIR1_EL1, cast[u64](interrupt))
    aarch64.isb()
}

/**
 * Find the kernel's ID for an interrupt on a CPU, in routes.
 *
 * Reads routes without routes_lock, so a route changed meanwhile may be seen either way.
 *
 * @param system The shared state, with routes.
 * @param cpu The CPU's MPIDR, its affinity fields only.
 * @param interrupt The GIC's interrupt ID, an SPI's or an LPI's.
 * @return The kernel's device interrupt ID, or NO_ROUTE if the interrupt isn't routed to that CPU.
 */
device_id_for :: fn(system: ptr[ArchSystem], cpu: u64, interrupt: u32) -> u32 {
    for route in system.routes {
        if route.used && route.cpu == cpu && route.interrupt == interrupt {
            return route.id
        }
    }
    return NO_ROUTE
}

/**
 * Give the IDs L2 may give to devices (arch_interface.device_interrupt_range).
 *
 * They're the kernel's own, not the GIC's: it picks one per line and CPU, and routes translates.
 *
 * @return first FIRST_DEVICE_ID, 32.
 * @return count DEVICE_ID_COUNT, 224, so the IDs are 32 to 255.
 */
device_interrupt_range :: fn() -> (first: arch_interface.InterruptId, count: u32) {
    return cast[arch_interface.InterruptId](FIRST_DEVICE_ID), DEVICE_ID_COUNT
}

/**
 * Acknowledge the device interrupt the calling CPU took (arch_interface.end_of_interrupt).
 *
 * It ends the GIC interrupt ID interrupt_source read for it, not one looked up by id, so an interrupt whose route
 * was moved or taken away between its delivery and now is still ended, and doesn't stay active, blocking its priority.
 *
 * @param id The kernel's device interrupt ID, as interrupt_source gave it; the interrupt ended is the one that ID was
 *     given for. Nothing is ended if this CPU has no device interrupt active.
 */
end_of_interrupt :: fn(id: arch_interface.InterruptId) {
    cpu :: current_cpu()
    if cpu.active_interrupt == NO_ACTIVE_INTERRUPT {
        return void
    }
    acknowledge(cpu.active_interrupt)
    cpu.active_interrupt = NO_ACTIVE_INTERRUPT
}

/** ArchCpu.active_interrupt when the CPU has no device interrupt active: no GIC interrupt has this ID. */
NO_ACTIVE_INTERRUPT : u32 : 0xffffffff

/**
 * Send an IPI to a CPU as an SGI, through ICC_SGI1R_EL1 (arch_interface.send_ipi).
 *
 * The register takes the target's Aff3, Aff2 and Aff1, and its Aff0 as a bit in a target list of 16, which RS
 * (Aff0 / 16) picks. Memory written before is visible to the target first (DSB ISH).
 *
 * @param cpu_hardware_id The target CPU's MPIDR, its affinity fields, as affinity_of_this_cpu gives them.
 * @param kind Which IPI: SGI_RESCHEDULE, SGI_TLB_FLUSH or SGI_STOP.
 */
send_ipi :: fn(cpu_hardware_id: u64, kind: arch_interface.IpiKind) {
    interrupt :: match kind {
        case .Reschedule => SGI_RESCHEDULE
        case .TlbFlush => SGI_TLB_FLUSH
        case .Stop => SGI_STOP
    }
    affinity_0 :: cpu_hardware_id & 0xff
    value := cast[u64](1) << (affinity_0 % 16)
    value |= ((cpu_hardware_id >> 8) & 0xff) << 16
    value |= cast[u64](interrupt) << 24
    value |= ((cpu_hardware_id >> 16) & 0xff) << 32
    value |= (affinity_0 / 16) << 44
    value |= ((cpu_hardware_id >> 32) & 0xff) << 48
    // What came before reaches the other CPU first
    aarch64.dsb(.ISH)
    aarch64.write_system_register(.ICC_SGI1R_EL1, value)
    aarch64.isb()
}

/**
 * Tell whether an IRQ or FIQ is waiting on the calling CPU (arch_interface.interrupt_pending).
 *
 * @return True if ISR_EL1's I or F bit is set, which it says even while they're masked.
 */
interrupt_pending :: fn() -> bool {
    return aarch64.read_system_register(.ISR_EL1) & 0xc0 != 0
}

/**
 * Set up a distributor L2 mapped (arch_interface.init_interrupt_controller): its SPIs, every one masked, its
 * pending state cleared, in group 1 at one priority.
 *
 * L1 has already turned the distributor on (init_distributor); this doesn't change GICD_CTLR.
 *
 * @param controller Where the controller's state goes, L2's.
 * @param kind The kind L2 registered it as; only GicDistributor is supported.
 * @param registers The distributor's registers, a virtual address in L2's mapping, DISTRIBUTOR_SIZE bytes.
 * @return How many SPI lines it has, from GICD_TYPER.ITLinesNumber: 32 * (N + 1) - 32, at least 32.
 * @error UnsupportedKind kind isn't GicDistributor; nothing was touched.
 * @error NotFound GICD_TYPER says there are no SPIs; nothing was written.
 */
init_interrupt_controller :: fn(
    controller: ptr[mut InterruptController],
    kind: arch_interface.ControllerKind,
    registers: arch_interface.VirtualAddress,
) -> Result[u32, arch_interface.ControllerError] {
    if kind != .GicDistributor {
        return .Error(.UnsupportedKind)
    }
    base :: cast[u64](registers)
    // ITLinesNumber: 32 * (N + 1) interrupt IDs, of which the first 32 aren't SPIs
    interrupts :: 32 * ((read_u32(base, GICD_TYPER) & 0x1f) + 1)
    if interrupts <= FIRST_SPI {
        return .Error(.NotFound)
    }
    controller.registers = base
    controller.lines = interrupts - FIRST_SPI
    for word in 1..<interrupts / 32 {
        offset :: cast[u64](word) * 4
        write_u32(base, GICD_ICENABLER + offset, 0xffffffff)
        write_u32(base, GICD_ICPENDR + offset, 0xffffffff)
        write_u32(base, GICD_IGROUPR + offset, 0xffffffff)
    }
    for interrupt in FIRST_SPI..<interrupts {
        write_u8(base, GICD_IPRIORITYR + cast[u64](interrupt), INTERRUPT_PRIORITY)
    }
    return .Ok(controller.lines)
}

/**
 * Route a line as route_wired does (arch_interface.route_wired_remapped): no IOMMU here remaps a GIC's lines, so the
 * message is unused.
 *
 * @param controller The distributor.
 * @param line The SPI line.
 * @param message Unused.
 * @param id The kernel's device interrupt ID, on the CPU route_wired was last given for it.
 * @param trigger Edge or level.
 * @param polarity Ignored, as route_wired ignores it.
 */
route_wired_remapped :: fn(
    controller: ptr[mut InterruptController],
    line: u32,
    message: arch_interface.MsiMessage,
    id: arch_interface.InterruptId,
    trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity,
) {
}

/**
 * Deliver a line to a CPU as the kernel's ID there, still masked (arch_interface.route_wired).
 *
 * The line is masked, its trigger set in GICD_ICFGR, and GICD_IROUTER pointed at the CPU; the route replaces any
 * for the same line, or for the same ID on the same CPU (record_route).
 *
 * @param controller The distributor, from init_interrupt_controller.
 * @param line The SPI line, below controller's lines; its interrupt ID is 32 + line.
 * @param cpu_hardware_id The CPU's MPIDR; only its affinity fields are used.
 * @param id The kernel's device interrupt ID on that CPU, from device_interrupt_range.
 * @param trigger Edge or level.
 * @param polarity Ignored: the GIC has no polarity of its own, so an active-low line is inverted before it.
 */
route_wired :: fn(
    controller: ptr[mut InterruptController],
    line: u32,
    cpu_hardware_id: u64,
    id: arch_interface.InterruptId,
    trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity,
) {
    interrupt :: FIRST_SPI + line
    base :: controller.registers
    write_u32(base, GICD_ICENABLER + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
    // Two bits an interrupt in ICFGR, the upper one set for edge-triggered
    configuration :: GICD_ICFGR + cast[u64](interrupt / 16) * 4
    shift :: (interrupt % 16) * 2 + 1
    edge :: if trigger == .Edge { cast[u32](1) } else { cast[u32](0) }
    write_u32(base, configuration, (read_u32(base, configuration) & ~(cast[u32](1) << shift)) | (edge << shift))
    write_u64(base, GICD_IROUTER + cast[u64](interrupt) * 8, cpu_hardware_id & 0xff00ffffff)
    record_route(current_system(), cpu_hardware_id, cast[u32](id), interrupt)
}

/**
 * Keep a route, replacing any for the same interrupt or for the same ID on the same CPU, under routes_lock.
 *
 * Asserts there's a free slot, which there always is while IDs come from device_interrupt_range.
 *
 * @param system The shared state, whose routes change.
 * @param cpu The CPU's MPIDR, compared as given with ArchCpu.mpidr, so its affinity fields only.
 * @param id The kernel's device interrupt ID on that CPU.
 * @param interrupt The GIC's interrupt ID, an SPI's or an LPI's.
 */
record_route :: fn(system: ptr[mut ArchSystem], cpu: u64, id: u32, interrupt: u32) {
    concurrency.lock(&system.routes_lock)
    defer concurrency.unlock(&system.routes_lock)
    free : usize = MAX_ROUTES
    for &route, index in system.routes {
        if route.used && (route.interrupt == interrupt || (route.cpu == cpu && route.id == id)) {
            route.used = false
        }
        if !route.used && free == MAX_ROUTES {
            free = index
        }
    }
    runtime.assert(free < MAX_ROUTES, "a route for every device interrupt ID")
    system.routes[free] = Route.{used = true, cpu = cpu, id = id, interrupt = interrupt}
}

/**
 * Forget the route from an interrupt, an LPI no longer raised (its.hsc), under routes_lock.
 *
 * @param system The shared state, whose routes change.
 * @param interrupt The GIC's interrupt ID; nothing happens if no route has it.
 */
forget_route :: fn(system: ptr[mut ArchSystem], interrupt: u32) {
    concurrency.lock(&system.routes_lock)
    defer concurrency.unlock(&system.routes_lock)
    for &route in system.routes {
        if route.used && route.interrupt == interrupt {
            route.used = false
        }
    }
}

/**
 * Mask a line at the distributor, through GICD_ICENABLER (arch_interface.mask_wired).
 *
 * @param controller The distributor, from init_interrupt_controller.
 * @param line The SPI line, below controller's lines.
 */
mask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    interrupt :: FIRST_SPI + line
    write_u32(controller.registers, GICD_ICENABLER + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
}

/**
 * Unmask a line at the distributor, through GICD_ISENABLER (arch_interface.unmask_wired).
 *
 * @param controller The distributor, from init_interrupt_controller.
 * @param line The SPI line, below controller's lines, routed already (route_wired).
 */
unmask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    interrupt :: FIRST_SPI + line
    write_u32(controller.registers, GICD_ISENABLER + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
}

/**
 * Say where the emulator's test device is (arch_interface.test_device).
 *
 * @return The GIC distributor, at its physical address (0 without a GIC), with TEST_LINE, an edge-triggered,
 *     active-high SPI no device on QEMU virt uses, which test_device_interrupts pends in software.
 */
test_device :: fn() -> arch_interface.TestDevice {
    return arch_interface.TestDevice.{
        kind = .GicDistributor,
        registers = cast[arch_interface.PhysicalAddress](current_system().distributor_physical),
        line = TEST_LINE,
        trigger = .Edge,
        polarity = .ActiveHigh,
    }
}

/**
 * Start or stop the test device (arch_interface.test_device_interrupts).
 *
 * While it's on, its line is pended through the distributor about a thousand times a second, by the generic
 * timer's physical timer on the CPU that started it, which the kernel doesn't use otherwise (its own is the
 * virtual timer).
 *
 * @param on True to start it, arming the calling CPU's physical timer; false to stop it, disarming the timer, so
 *     it should be called on the CPU that started it.
 */
test_device_interrupts :: fn(on: bool) {
    system :: current_system()
    system.test_interrupts = on
    if on {
        aarch64.write_system_register(.CNTP_TVAL_EL0, aarch64.read_system_register(.CNTFRQ_EL0) / TEST_DEVICE_HZ)
        aarch64.write_system_register(.CNTP_CTL_EL0, 1)
    }
    else {
        aarch64.write_system_register(.CNTP_CTL_EL0, 0)
    }
    aarch64.isb()
}

/**
 * Pend the test device's line at the distributor, through GICD_ISPENDR, as if a device raised it.
 *
 * @param system The shared state, whose distributor is mapped.
 */
pend_test_line :: fn(system: ptr[ArchSystem]) {
    interrupt :: FIRST_SPI + TEST_LINE
    write_u32(system.distributor, GICD_ISPENDR + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
}

/**
 * Read a 32-bit device register, volatile.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes, 4-aligned.
 * @return The 32 bits the register reads as now; each call loads afresh, never merged or skipped, so a polling loop
 *     sees changes.
 */
read_u32 :: fn(base: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

/**
 * Read a 64-bit device register, volatile.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes, 8-aligned.
 * @return The 64 bits the register reads as now, in one load; each call loads afresh, never merged or skipped.
 */
read_u64 :: fn(base: u64, offset: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](base + offset))
}

/**
 * Write an 8-bit device register, volatile, as the GIC's byte-wide priority registers are written.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes.
 * @param value What to write.
 */
write_u8 :: fn(base: u64, offset: u64, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](base + offset), value)
}

/**
 * Write a 32-bit device register, volatile.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes, 4-aligned.
 * @param value What to write.
 */
write_u32 :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

/**
 * Write a 64-bit device register, volatile.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes, 8-aligned.
 * @param value What to write.
 */
write_u64 :: fn(base: u64, offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](base + offset), value)
}
