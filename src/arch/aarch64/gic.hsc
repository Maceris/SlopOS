package arch_aarch64

import intrinsics from "base"
import runtime from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import kernel_entry from "../../kernel/entry"

/*
 * The GICv3 (docs/specs/arch_interface.md, AArch64): the distributor for shared peripheral interrupts (SPIs),
 * each CPU's redistributor for its SGIs (the IPIs) and PPIs (the timer), and each CPU's interface through the
 * ICC system registers. Every interrupt is in group 1, at one priority, with EOImode 0, so writing ICC_EOIR1
 * both drops the priority and deactivates it.
 *
 * An SPI's interrupt ID is its line's (32 + line), which software can't choose, so the kernel's device
 * interrupt IDs are translated: routes records which ID each line was routed to on which CPU.
 */
//SPEC: Arm GICv3 and GICv4 Architecture Specification (IHI 0069): §12.9 (GICD_*), §12.10/12.11 (GICR_* and the SGI frame), §12.2 (ICC_*_EL1)

// Distributor registers
GICD_CTLR : u64 : 0x0000
GICD_TYPER : u64 : 0x0004
GICD_IGROUPR : u64 : 0x0080
GICD_ISENABLER : u64 : 0x0100
GICD_ICENABLER : u64 : 0x0180
GICD_ISPENDR : u64 : 0x0200
GICD_ICPENDR : u64 : 0x0280
GICD_IPRIORITYR : u64 : 0x0400
GICD_ICFGR : u64 : 0x0c00
GICD_IROUTER : u64 : 0x6000
// Affinity routing (ARE), and group 1 on (with security, EnableGrp1NS; without, EnableGrp1, besides Grp0)
GICD_CTLR_ENABLE : u32 : (1 << 4) | (1 << 1) | 1
GICD_CTLR_WRITE_PENDING : u32 : 1 << 31
// The distributor's registers are 64 KiB
DISTRIBUTOR_SIZE : u64 : 0x10000

// Redistributor registers: the RD frame, then the SGI frame 64 KiB on
GICR_TYPER : u64 : 0x0008
GICR_WAKER : u64 : 0x0014
GICR_SGI_FRAME : u64 : 0x10000
GICR_IGROUPR0 : u64 : 0x0080
GICR_ISENABLER0 : u64 : 0x0100
GICR_ICENABLER0 : u64 : 0x0180
GICR_IPRIORITYR : u64 : 0x0400
WAKER_PROCESSOR_SLEEP : u32 : 1 << 1
WAKER_CHILDREN_ASLEEP : u32 : 1 << 2
// GICR_TYPER: the last redistributor in the region, and one with virtual LPIs, whose frames are twice as many
TYPER_LAST : u64 : 1 << 4
TYPER_VIRTUAL_LPIS : u64 : 1 << 1
REDISTRIBUTOR_STRIDE : u64 : 0x20000

// ICC_SRE_EL1: the system register interface, with FIQ and IRQ bypass off
SRE_ENABLE : u64 : 0x7
// Every interrupt one priority, which the mask lets through
INTERRUPT_PRIORITY : u8 : 0xa0
PRIORITY_MASK : u64 : 0xf0

// Interrupt IDs: SGIs, PPIs, SPIs, and the special ones from 1020
FIRST_PPI : u32 : 16
FIRST_SPI : u32 : 32
FIRST_SPECIAL : u32 : 1020
// The IPIs, as SGIs
SGI_RESCHEDULE : u32 : 1
SGI_TLB_FLUSH : u32 : 2
SGI_STOP : u32 : 3
// The virtual and the physical timer's PPIs where the device tree doesn't say
DEFAULT_TIMER_INTERRUPT : u32 : 27
DEFAULT_TEST_TIMER_INTERRUPT : u32 : 30
// The test device's rate: about a thousand interrupts a second
TEST_DEVICE_HZ : u64 : 1000

// The kernel's device interrupt IDs, on each CPU
FIRST_DEVICE_ID : u32 : 32
DEVICE_ID_COUNT : u32 : 224
MAX_ROUTES :: 256
NO_ROUTE : u32 : 0xffffffff

// The test device (arch_interface.test_device): an SPI no device on QEMU virt uses, pended in software
TEST_LINE : u32 : 100

// One line routed to one of the kernel's device interrupt IDs, on the CPU with an MPIDR's affinity.
Route :: struct {
    used : bool,
    cpu : u64,
    id : u32,
    interrupt : u32,
}

// A GICv3 distributor L2 registered (arch_interface.InterruptController), through L2's mapping.
InterruptController :: struct {
    registers : u64,
    lines : u32,
}

// The distributor through L1's own mapping, for what every CPU shares: affinity routing and group 1 on.
init_distributor :: fn(system: ptr[mut ArchSystem]) {
    base :: system.distributor
    write_u32(base, GICD_CTLR, 0)
    wait_for_distributor(base)
    write_u32(base, GICD_CTLR, GICD_CTLR_ENABLE)
    wait_for_distributor(base)
}

wait_for_distributor :: fn(base: u64) {
    loop {
        intrinsics.spin_hint()
    }
    while read_u32(base, GICD_CTLR) & GICD_CTLR_WRITE_PENDING != 0
}

/*
 * The calling CPU's redistributor, awake, with its SGIs and the timer's PPI in group 1, enabled; then its CPU
 * interface on, letting every interrupt's priority through.
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

// The redistributor whose affinity is mpidr's, from the region the device tree gave, or 0.
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

// This CPU's MPIDR, its affinity fields only, as Limine gives each CPU's.
affinity_of_this_cpu :: fn() -> u64 {
    return aarch64.read_system_register(.MPIDR_EL1) & 0xff00ffffff
}

/*
 * An IRQ's source. The timer and IPIs are acknowledged here; a device interrupt is the kernel's to
 * acknowledge (end_of_interrupt), and a spurious one isn't acknowledged at all.
 */
interrupt_source :: fn() -> kernel_entry.InterruptSource {
    cpu :: current_cpu()
    system :: current_system()
    interrupt :: cast[u32](aarch64.read_system_register(.ICC_IAR1_EL1) & 0xffffff)
    if interrupt >= FIRST_SPECIAL {
        return .Spurious
    }
    if interrupt >= FIRST_SPI {
        id :: device_id_for(system, cpu.mpidr, interrupt)
        if id != NO_ROUTE {
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

acknowledge :: fn(interrupt: u32) {
    aarch64.write_system_register(.ICC_EOIR1_EL1, cast[u64](interrupt))
    aarch64.isb()
}

// The kernel's ID for an interrupt on a CPU, or NO_ROUTE.
device_id_for :: fn(system: ptr[ArchSystem], cpu: u64, interrupt: u32) -> u32 {
    for route in system.routes {
        if route.used && route.cpu == cpu && route.interrupt == interrupt {
            return route.id
        }
    }
    return NO_ROUTE
}

// The kernel's own IDs: it picks one per line and CPU, and routes translates.
device_interrupt_range :: fn() -> (first: arch_interface.InterruptId, count: u32) {
    return cast[arch_interface.InterruptId](FIRST_DEVICE_ID), DEVICE_ID_COUNT
}

// The line routed to id on this CPU, acknowledged.
end_of_interrupt :: fn(id: arch_interface.InterruptId) {
    cpu :: current_cpu()
    for route in current_system().routes {
        if route.used && route.cpu == cpu.mpidr && route.id == cast[u32](id) {
            acknowledge(route.interrupt)
            return void
        }
    }
}

/*
 * An SGI to the CPU with an MPIDR's affinity, through ICC_SGI1R_EL1: its Aff3, Aff2 and Aff1, and Aff0 as a
 * bit in a target list of 16, which RS picks.
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

// Whether an IRQ or FIQ is waiting, which ISR_EL1 says even while they're masked.
interrupt_pending :: fn() -> bool {
    return aarch64.read_system_register(.ISR_EL1) & 0xc0 != 0
}

/*
 * A distributor L2 mapped: its SPIs, every one masked, cleared, in group 1 at one priority. L1 has already
 * turned the distributor on (init_distributor).
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

/*
 * Deliver line to the CPU with this affinity, as the kernel's id there, still masked. The GIC has no
 * polarity of its own: an active-low line is inverted before it.
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

// Keep a route, replacing any for the same line or for the same ID on the same CPU.
record_route :: fn(system: ptr[mut ArchSystem], cpu: u64, id: u32, interrupt: u32) {
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

mask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    interrupt :: FIRST_SPI + line
    write_u32(controller.registers, GICD_ICENABLER + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
}

unmask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    interrupt :: FIRST_SPI + line
    write_u32(controller.registers, GICD_ISENABLER + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
}

test_device :: fn() -> arch_interface.TestDevice {
    return arch_interface.TestDevice.{
        kind = .GicDistributor,
        registers = cast[arch_interface.PhysicalAddress](current_system().distributor_physical),
        line = TEST_LINE,
        trigger = .Edge,
        polarity = .ActiveHigh,
    }
}

/*
 * Start or stop the test device: while it's on, its line is pended through the distributor about a thousand
 * times a second, by the generic timer's physical timer on the CPU that started it, which the kernel doesn't
 * use otherwise (its own is the virtual timer).
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

pend_test_line :: fn(system: ptr[ArchSystem]) {
    interrupt :: FIRST_SPI + TEST_LINE
    write_u32(system.distributor, GICD_ISPENDR + cast[u64](interrupt / 32) * 4, cast[u32](1) << (interrupt % 32))
}

read_u32 :: fn(base: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

read_u64 :: fn(base: u64, offset: u64) -> u64 {
    return intrinsics.volatile_load_u64(cast[ptr[u64]](base + offset))
}

write_u8 :: fn(base: u64, offset: u64, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](base + offset), value)
}

write_u32 :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

write_u64 :: fn(base: u64, offset: u64, value: u64) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](base + offset), value)
}
