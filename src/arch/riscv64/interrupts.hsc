package arch_riscv64

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import runtime from "base:runtime"
import concurrency from "std:concurrency"
import arch_interface from "../../arch_interface"
import devicetree from "../../devicetree"
import kernel_entry from "../../kernel/entry"

/*
 * Interrupts (decisions/0199, R4): the device tree's PLIC, or the AIA, an IMSIC with an interrupt file for each hart
 * and
 * an APLIC in MSI mode in front of the wired lines. The timer is Sstc's (timer.hsc).
 *
 * With the AIA every interrupt is a message: the kernel's device interrupt IDs are each hart's IMSIC identities, which
 * MSIs and the APLIC's lines name directly, and IPIs are identities written to the target's file. With the PLIC the IDs
 * are the kernel's own, translated through routes from the lines a hart claims, there are no MSIs, and IPIs are the
 * SBI's, which raise a supervisor software interrupt, with their kinds in the target's ArchCpu.
 *
 * SPEC: RISC-V Platform-Level Interrupt Controller Specification 1.0.0 (priorities, enables, threshold, claim and
 * complete); The RISC-V Advanced Interrupt Architecture 1.0, chapters 3 (IMSIC: the interrupt files, eidelivery,
 * eithreshold, eie, stopei) and 4 (APLIC: domaincfg, sourcecfg, setipnum, setienum, clrienum, target in MSI mode);
 * RISC-V
 * Supervisor Binary Interface Specification 2.0, §5 (IPI); the Linux kernel's devicetree bindings for
 * sifive,plic-1.0.0, riscv,imsics and riscv,aplic.
 */

/** Which interrupt controller the harts have. */
Controller :: enum #backed_by(u8) {
    /** None found: only the timer and the SBI's IPIs. */
    None,
    /** A PLIC, its lines claimed by each hart through its supervisor context. */
    Plic,
    /** The AIA: an IMSIC interrupt file for each hart, and an APLIC sending its lines to them as messages. */
    Aia,
}

/** One hart the interrupt controller serves: its ID, and where it is on the controller. */
Hart :: struct {
    /** The hart's ID, its cpu node's reg. */
    id : u64,
    /** Its supervisor context on the PLIC, by interrupts-extended's order; NO_CONTEXT on the AIA. */
    plic_context : u32,
    /** Its supervisor interrupt file's physical address on the IMSIC; 0 on a PLIC. */
    imsic_file : u64,
    /** Its index among the IMSIC's files, which the APLIC's targets name it by; 0 on a PLIC. */
    imsic_index : u32,
    /** Its ArchCpu, as an address, once init_cpu has run on it, for the SBI's IPIs; 0 until then. */
    cpu : u64,
}

/** A PLIC line routed to one of the kernel's device interrupt IDs on one hart. */
Route :: struct {
    /** Whether this slot holds a route; the other fields mean nothing when it doesn't. */
    used : bool,
    /** The hart's ID. */
    hart : u64,
    /** The kernel's device interrupt ID on that hart, from device_interrupt_range. */
    id : u32,
    /** The PLIC's source number. */
    line : u32,
}

/** How many routes ArchSystem keeps. */
MAX_ROUTES :: 256
/** What device_id_for gives for a line with no route. */
NO_ROUTE : u32 : 0xffffffff
/** Hart.plic_context and ArchCpu.plic_context without a PLIC context. */
NO_CONTEXT : u32 : 0xffffffff
/** ArchCpu.active_line with no PLIC source claimed: no source has this number. */
NO_ACTIVE_LINE : u32 : 0xffffffff

// The kernel's device interrupt IDs: with the PLIC its own, from 32; with the AIA the IMSIC's identities, from 16
/** The first device interrupt ID with the PLIC, the kernel's own. */
PLIC_FIRST_ID : u32 : 32
/** How many device interrupt IDs there are with the PLIC, from PLIC_FIRST_ID. */
PLIC_ID_COUNT : u32 : 224
/** The first device interrupt ID with the AIA: the identities below are the IPIs' and kept free. */
AIA_FIRST_ID : u32 : 16
/** The IMSIC identity of the Reschedule IPI. */
IPI_RESCHEDULE : u32 : 1
/** The IMSIC identity of the TlbFlush IPI. */
IPI_TLB_FLUSH : u32 : 2
/** The IMSIC identity of the Stop IPI. */
IPI_STOP : u32 : 3

// PLIC registers: byte offsets from its base
/** A source's priority, 4 bytes each by source number; 0 means it never interrupts. */
PLIC_PRIORITY : u64 : 0x0
/** A context's enable bits, 0x80 bytes each, a bit for each source. */
PLIC_ENABLE : u64 : 0x2000
/** A context's threshold, 0x1000 bytes each, then its claim and complete register 4 bytes on. */
PLIC_CONTEXT : u64 : 0x200000
/** The most sources a PLIC has, numbered 1 to 1023. */
PLIC_MAX_SOURCES : u32 : 1023

// APLIC registers, in an interrupt domain's registers
/** domaincfg: IE (bit 8) turns delivery on, DM (bit 2) makes it by message. */
APLIC_DOMAINCFG : u64 : 0x0000
/** domaincfg with IE and DM. */
DOMAIN_ON_BY_MESSAGE : u32 : (1 << 8) | (1 << 2)
/** sourcecfg[1], the first source's; sourcecfg[i] is 4 * (i - 1) on. */
APLIC_SOURCECFG : u64 : 0x0004
/** setipnum: writing a source's number makes it pending. */
APLIC_SETIPNUM : u64 : 0x1cdc
/** setienum: writing a source's number enables it. */
APLIC_SETIENUM : u64 : 0x1edc
/** clrienum: writing a source's number disables it. */
APLIC_CLRIENUM : u64 : 0x1fdc
/** target[1], the first source's; target[i] is 4 * (i - 1) on. In MSI mode: the hart index, bits 18 to 31, and EIID. */
APLIC_TARGET : u64 : 0x3004
/** sourcecfg's source modes: edge, rising and falling, and level, high and low. */
SOURCE_EDGE_RISING  : u32 : 4
SOURCE_EDGE_FALLING : u32 : 5
SOURCE_LEVEL_HIGH   : u32 : 6
SOURCE_LEVEL_LOW    : u32 : 7

// IMSIC: a file's seteipnum_le, and the indirect registers siselect reaches
/** seteipnum_le, at an interrupt file's start: writing an identity makes it pending there. */
IMSIC_SETEIPNUM : u64 : 0x0
/** siselect's eidelivery: 1 delivers the file's interrupts to the hart. */
ISELECT_DELIVERY : u64 : 0x70
/** siselect's eithreshold: 0 lets every enabled identity through. */
ISELECT_THRESHOLD : u64 : 0x72
/** siselect's eie0, enables for identities 0 to 63; eie2, eie4 and eie6 the next, as RV64 has the even ones only. */
ISELECT_ENABLE : u64 : 0xc0

// The SBI's IPI extension
/** The IPI extension's ID, "sPI". */
SBI_IPI : u64 : 0x735049
/** Its sbi_send_ipi function. */
SBI_SEND_IPI : u64 : 0

/**
 * Find the harts' interrupt controller in the device tree and map its registers through the direct map: an IMSIC with
 * supervisor interrupt files and an APLIC sending to it, if there is one, else a PLIC, else none. The harts are the
 * controller's, by its interrupts-extended, each the hart its interrupt controller's cpu node is.
 *
 * @param system The shared state, whose controller, harts and the controller's registers are set; device_blocks grows.
 * @param tree The device tree, open.
 */
init_controller :: fn(system : ptr[mut ArchSystem], tree : ptr[devicetree.Tree]) {
    if init_aia(system, tree) {
        system.controller = .Aia
        return void
    }
    if init_plic(system, tree) {
        system.controller = .Plic
        uart := devicetree.find_compatible(tree, "ns16550a") or_else devicetree.Node.{}
        if uart.offset != 0 {
            system.uart_line = cell_property(tree, &uart, "interrupts", 0)
        }
        return void
    }
    system.controller = .None
}

/**
 * Find the IMSIC with supervisor interrupt files, among the device tree's riscv,imsics nodes, and the APLIC sending to
 * it,
 * and map both.
 *
 * @param system The shared state, whose harts, imsic_ids, aplic and aplic_physical are set when this succeeds.
 * @param tree The device tree, open.
 * @return True if there's such an IMSIC, its files' harts found and its registers mapped; false otherwise, with harts
 *     left empty.
 */
init_aia :: fn(system : ptr[mut ArchSystem], tree : ptr[devicetree.Tree]) -> bool {
    for skip in cast[u32](0)..<4 {
        node := devicetree.find_compatible_after(tree, "riscv,imsics", skip) or_return false
        files :: devicetree.property(tree, &node, "interrupts-extended") or_continue
        // The supervisor's files take external interrupt 9; the machine's 11
        if (devicetree.cell(files, 1) or_else 0) != 9 {
            continue
        }
        region :: devicetree.reg(tree, &node, 0) or_return false
        if !map_device_range(system, region.address, region.size) {
            return false
        }
        guest_bits :: cell_property(tree, &node, "riscv,guest-index-bits", 0)
        stride :: cast[u64](1) << (12 + cast[u64](guest_bits))
        system.imsic_ids = cell_property(tree, &node, "riscv,num-ids", 0)
        count :: files.size / 8
        for index in cast[u64](0)..<count {
            hart :: devicetree.parent_reg_of(tree, devicetree.cell(files, index * 2) or_else 0) or_continue
            at :: cast[usize](system.hart_count)
            if at >= system.harts.count {
                break
            }
            system.harts[at] = Hart.{
                id = hart,
                plic_context = NO_CONTEXT,
                imsic_file = region.address + index * stride,
                imsic_index = cast[u32](index),
            }
            system.hart_count += 1
        }
        find_aplic(system, tree, cell_property(tree, &node, "phandle", 0))
        return system.hart_count > 0
    }
    return false
}

/**
 * Find the APLIC that sends its lines to an IMSIC as messages, its msi-parent, and map it.
 *
 * @param system The shared state, whose aplic, aplic_physical and aplic_sources are set if it's found and mapped.
 * @param tree The device tree, open.
 * @param imsic The IMSIC's phandle.
 */
find_aplic :: fn(system : ptr[mut ArchSystem], tree : ptr[devicetree.Tree], imsic : u32) {
    for skip in cast[u32](0)..<4 {
        node := devicetree.find_compatible_after(tree, "riscv,aplic", skip) or_return void
        if cell_property(tree, &node, "msi-parent", 0) != imsic || imsic == 0 {
            continue
        }
        region :: devicetree.reg(tree, &node, 0) or_return void
        if !map_device_range(system, region.address, region.size) {
            return void
        }
        system.aplic_physical = region.address
        system.aplic = system.direct_map_offset + region.address
        system.aplic_sources = cell_property(tree, &node, "riscv,num-sources", 0)
        return void
    }
}

/**
 * Find the PLIC, sifive,plic-1.0.0 or riscv,plic0, its supervisor contexts' harts, and map it.
 *
 * @param system The shared state, whose harts, plic and plic_physical are set when this succeeds.
 * @param tree The device tree, open.
 * @return True if there's a PLIC with a supervisor context, its registers mapped; false otherwise, harts left empty.
 */
init_plic :: fn(system : ptr[mut ArchSystem], tree : ptr[devicetree.Tree]) -> bool {
    found := devicetree.find_compatible(tree, "sifive,plic-1.0.0")
    if found is_none {
        found = devicetree.find_compatible(tree, "riscv,plic0")
    }
    node := found or_return false
    region :: devicetree.reg(tree, &node, 0) or_return false
    contexts :: devicetree.property(tree, &node, "interrupts-extended") or_return false
    if !map_device_range(system, region.address, region.size) {
        return false
    }
    system.plic_physical = region.address
    system.plic = system.direct_map_offset + region.address
    // A context for each pair: its hart's interrupt controller's phandle, and 9 for supervisor external, 11 machine
    for context in cast[u64](0)..<contexts.size / 8 {
        if (devicetree.cell(contexts, context * 2 + 1) or_else 0) != 9 {
            continue
        }
        hart :: devicetree.parent_reg_of(tree, devicetree.cell(contexts, context * 2) or_else 0) or_continue
        at :: cast[usize](system.hart_count)
        if at >= system.harts.count {
            break
        }
        system.harts[at] = Hart.{id = hart, plic_context = cast[u32](context)}
        system.hart_count += 1
    }
    return system.hart_count > 0
}

/**
 * Find a hart among those the interrupt controller serves.
 *
 * @param system The shared state, with harts.
 * @param id The hart's ID.
 * @return Its slot in harts, or null if the controller doesn't serve it.
 */
hart_of :: fn(system : ptr[mut ArchSystem], id : u64) -> ptr[mut Hart]? {
    count :: cast[usize](system.hart_count)
    for &hart, i in system.harts {
        if i < count && hart.id == id {
            return hart
        }
    }
    return null
}

/**
 * Set the calling hart's part of the interrupt controller up, for init_cpu: on the AIA, its interrupt file delivering
 * every identity it has; on a PLIC, its context's threshold at 0 and every line disabled there. Either way it's
 * recorded in its Hart, for the SBI's IPIs.
 *
 * @param system The shared state, whose harts has the calling hart's slot, if the controller serves it.
 * @param cpu The calling hart's state, whose hart_id is set; its plic_context and imsic are set here.
 */
init_hart_controller :: fn(system : ptr[ArchSystem], cpu : ptr[mut ArchCpu]) {
    cpu.plic_context = NO_CONTEXT
    hart :: hart_of(cast[ptr[mut ArchSystem]](system), cpu.hart_id) or_return void
    intrinsics.atomic_store_u64_release(&hart.cpu, cast[u64](cpu))
    if system.controller == .Aia {
        cpu.imsic = system.direct_map_offset + hart.imsic_file
        write_indirect(ISELECT_DELIVERY, 1)
        write_indirect(ISELECT_THRESHOLD, 0)
        // Every identity the file has but 0, which is none; 64 a register, RV64's even-numbered ones
        for word in cast[u64](0)..<4 {
            bits := cast[u64](0)
            for bit in cast[u64](0)..<64 {
                identity :: word * 64 + bit
                if identity != 0 && identity < cast[u64](system.imsic_ids) {
                    bits |= cast[u64](1) << bit
                }
            }
            write_indirect(ISELECT_ENABLE + word * 2, bits)
        }
        return void
    }
    if system.controller == .Plic {
        cpu.plic_context = hart.plic_context
        context :: cast[u64](hart.plic_context)
        for word in cast[u64](0)..<32 {
            write_u32(system.plic, PLIC_ENABLE + context * 0x80 + word * 4, 0)
        }
        write_u32(system.plic, PLIC_CONTEXT + context * 0x1000, 0)
    }
}

/**
 * Write one of the IMSIC's indirect registers through siselect and sireg.
 *
 * @param select The register's number, an ISELECT_*.
 * @param value What to write.
 */
write_indirect :: fn(select : u64, value : u64) {
    riscv64.csrw(.SISELECT, select)
    riscv64.csrw(.SIREG, value)
}

/**
 * Decode an interrupt into what kernel_entry handles: the timer's compare put back at its largest; an IPI's kind; a
 * device's interrupt ID, its PLIC line claimed, to be completed at end_of_interrupt, or its IMSIC identity claimed.
 *
 * @param cause scause, CAUSE_INTERRUPT with the interrupt's number.
 * @return Timer, Ipi or Device; Spurious for anything else: nothing claimed, a line with no route on this hart (it's
 *     completed here), an identity that's neither an IPI's nor a device's.
 */
interrupt_source :: fn(cause : u64) -> kernel_entry.InterruptSource {
    cpu :: current_cpu()
    system :: current_system()
    number :: cause & ~riscv64.CAUSE_INTERRUPT
    if number == riscv64.CAUSE_SUPERVISOR_TIMER {
        return if take_timer(cpu, system) { kernel_entry.InterruptSource.Timer } else { .Spurious }
    }
    if number == riscv64.CAUSE_SUPERVISOR_SOFTWARE {
        return take_sbi_ipi(cpu)
    }
    if number != riscv64.CAUSE_SUPERVISOR_EXTERNAL {
        return .Spurious
    }
    if system.controller == .Aia {
        identity :: cast[u32](riscv64.csrrw(.STOPEI, 0) >> 16)
        return match identity {
            case IPI_RESCHEDULE => .Ipi(.Reschedule)
            case IPI_TLB_FLUSH => .Ipi(.TlbFlush)
            case IPI_STOP => .Ipi(.Stop)
            case _ => if identity >= AIA_FIRST_ID {
                .Device(cast[arch_interface.InterruptId](identity))
            }
            else {
                .Spurious
            }
        }
    }
    if system.controller != .Plic || cpu.plic_context == NO_CONTEXT {
        return .Spurious
    }
    claim :: PLIC_CONTEXT + cast[u64](cpu.plic_context) * 0x1000 + 4
    line :: read_u32(system.plic, claim)
    if line == 0 {
        return .Spurious
    }
    id :: device_id_for(system, cpu.hart_id, line)
    if id == NO_ROUTE {
        write_u32(system.plic, claim, line)
        return .Spurious
    }
    // Completed as the PLIC gave it, whatever its route becomes meanwhile
    cpu.active_line = line
    return .Device(cast[arch_interface.InterruptId](id))
}

/**
 * Take one of the IPIs the SBI raised on the calling hart: sip.SSIP cleared, the lowest kind of those waiting taken,
 * and
 * SSIP raised again if others still wait, so each comes as an interrupt of its own.
 *
 * @param cpu The calling hart's state, whose ipis are taken from.
 * @return The IPI's kind; Spurious if none was waiting.
 */
take_sbi_ipi :: fn(cpu : ptr[mut ArchCpu]) -> kernel_entry.InterruptSource {
    _ = riscv64.csrrc(.SIP, SIE_SOFTWARE)
    waiting :: intrinsics.interlocked_exchange_u32(&cpu.ipis, 0)
    if waiting == 0 {
        return .Spurious
    }
    lowest :: waiting & (~waiting + 1)
    rest :: waiting & ~lowest
    if rest != 0 {
        _ = intrinsics.interlocked_or_u32(&cpu.ipis, rest)
        _ = riscv64.csrrs(.SIP, SIE_SOFTWARE)
    }
    if lowest == ipi_bit(.Reschedule) {
        return .Ipi(.Reschedule)
    }
    if lowest == ipi_bit(.TlbFlush) {
        return .Ipi(.TlbFlush)
    }
    return .Ipi(.Stop)
}

/**
 * Give an IPI kind's bit in ArchCpu.ipis.
 *
 * @param kind The kind.
 * @return 1 shifted by the kind's number.
 */
ipi_bit :: fn(kind : arch_interface.IpiKind) -> u32 {
    return cast[u32](1) << cast[u32](cast[u8](kind))
}

/**
 * Find the kernel's ID for a PLIC line on a hart, in routes.
 *
 * Reads routes without routes_lock, so a route changed meanwhile may be seen either way.
 *
 * @param system The shared state, with routes.
 * @param hart The hart's ID.
 * @param line The PLIC's source number.
 * @return The kernel's device interrupt ID, or NO_ROUTE if the line isn't routed to that hart.
 */
device_id_for :: fn(system : ptr[ArchSystem], hart : u64, line : u32) -> u32 {
    for route in system.routes {
        if route.used && route.hart == hart && route.line == line {
            return route.id
        }
    }
    return NO_ROUTE
}

/**
 * Give the IDs L2 may give to devices (arch_interface.device_interrupt_range).
 *
 * @return first AIA_FIRST_ID with the AIA, the IMSIC's identities from the IPIs' up; PLIC_FIRST_ID otherwise.
 * @return count With the AIA, the IMSIC's identities from AIA_FIRST_ID below riscv,num-ids, at most 256; PLIC_ID_COUNT
 *     otherwise.
 */
device_interrupt_range :: fn() -> (first : arch_interface.InterruptId, count : u32) {
    system :: current_system()
    if system.controller == .Aia {
        ids :: if system.imsic_ids > 256 { cast[u32](256) } else { system.imsic_ids }
        count :: if ids > AIA_FIRST_ID { ids - AIA_FIRST_ID } else { cast[u32](0) }
        return cast[arch_interface.InterruptId](AIA_FIRST_ID), count
    }
    return cast[arch_interface.InterruptId](PLIC_FIRST_ID), PLIC_ID_COUNT
}

/**
 * Acknowledge the device interrupt the calling hart took (arch_interface.end_of_interrupt): on a PLIC, the line it
 * claimed completed, after the UART's transmitter interrupt is taken back when it's the test device's; on the AIA,
 * nothing, the IMSIC's claim having ended it.
 *
 * @param id The kernel's device interrupt ID, as interrupt_source gave it; the line completed is the one claimed for
 *     it. Nothing is completed if this hart has none claimed.
 */
end_of_interrupt :: fn(id : arch_interface.InterruptId) {
    cpu :: current_cpu()
    system :: current_system()
    if cpu.active_line == NO_ACTIVE_LINE || cpu.plic_context == NO_CONTEXT {
        return void
    }
    if cpu.active_line == system.uart_line && system.test_interrupts {
        // Reading IIR takes the transmitter's interrupt back, until pend_test_line arms it again
        _ = read_register(system.console, UART_FIFO_CONTROL)
    }
    write_u32(system.plic, PLIC_CONTEXT + cast[u64](cpu.plic_context) * 0x1000 + 4, cpu.active_line)
    cpu.active_line = NO_ACTIVE_LINE
}

/**
 * Send an IPI to a hart (arch_interface.send_ipi): with the AIA, its identity written to the hart's interrupt file;
 * otherwise its kind set in the hart's ArchCpu and the SBI's sbi_send_ipi raising its software interrupt. Memory
 * written before is visible to the target first.
 *
 * @param cpu_hardware_id The target hart's ID; one the controller doesn't serve, or not yet set up by init_cpu, isn't
 *     sent anything.
 * @param kind What it asks of the hart.
 */
send_ipi :: fn(cpu_hardware_id : u64, kind : arch_interface.IpiKind) {
    system :: current_system()
    hart :: hart_of(system, cpu_hardware_id) or_return void
    if system.controller == .Aia {
        identity :: match kind {
            case .Reschedule => IPI_RESCHEDULE
            case .TlbFlush => IPI_TLB_FLUSH
            case .Stop => IPI_STOP
        }
        // What came before reaches the other hart first
        riscv64.fence(riscv64.FENCE_READ | riscv64.FENCE_WRITE, riscv64.FENCE_OUTPUT)
        write_u32(system.direct_map_offset + hart.imsic_file, IMSIC_SETEIPNUM, identity)
        return void
    }
    target :: intrinsics.atomic_load_u64_acquire(&hart.cpu)
    if target == 0 {
        return void
    }
    _ = intrinsics.interlocked_or_u32(&cast[ptr[mut ArchCpu]](target).ipis, ipi_bit(kind))
    _ = riscv64.sbi_call(SBI_IPI, SBI_SEND_IPI, 1, cpu_hardware_id)
}

/**
 * Set up a wired controller L2 mapped (arch_interface.init_interrupt_controller), every line masked: a PLIC's lines
 * disabled in every supervisor context, each at priority 1; an APLIC delivering by message, each source inactive.
 *
 * @param controller Where the controller's state goes, L2's.
 * @param kind The kind L2 registered it as: Plic or Aplic, whichever the harts have.
 * @param registers Its registers, a virtual address in L2's mapping.
 * @return How many lines it has, numbered from 1, so that many plus one: line 0 is never a source's.
 * @error UnsupportedKind kind is neither, or isn't the harts' controller; nothing was touched.
 * @error NotFound No source answers, as probing each one's priority or sourcecfg finds.
 */
init_interrupt_controller :: fn(
    controller : ptr[mut InterruptController],
    kind : arch_interface.ControllerKind,
    registers : arch_interface.VirtualAddress
) -> Result[u32, arch_interface.ControllerError] {
    system :: current_system()
    base :: cast[u64](registers)
    supported :: (kind == .Plic && system.controller == .Plic) || (kind == .Aplic && system.controller == .Aia)
    if !supported {
        return .Error(.UnsupportedKind)
    }
    controller.kind = kind
    controller.registers = base
    // The highest source that keeps what's written to its priority or its mode: those past the last read as 0
    highest := cast[u32](0)
    for source in cast[u32](1)..=PLIC_MAX_SOURCES {
        at :: cast[u64](source - 1) * 4
        if kind == .Plic {
            write_u32(base, PLIC_PRIORITY + cast[u64](source) * 4, 1)
            if read_u32(base, PLIC_PRIORITY + cast[u64](source) * 4) != 0 {
                highest = source
            }
        }
        else {
            write_u32(base, APLIC_SOURCECFG + at, SOURCE_EDGE_RISING)
            if read_u32(base, APLIC_SOURCECFG + at) != 0 {
                highest = source
            }
            write_u32(base, APLIC_CLRIENUM, source)
            write_u32(base, APLIC_SOURCECFG + at, 0)
        }
    }
    if highest == 0 {
        return .Error(.NotFound)
    }
    if kind == .Plic {
        for i in 0..<cast[usize](system.hart_count) {
            if i >= system.harts.count {
                break
            }
            context :: cast[u64](system.harts[i].plic_context)
            for word in cast[u64](0)..<32 {
                write_u32(base, PLIC_ENABLE + context * 0x80 + word * 4, 0)
            }
        }
    }
    else {
        write_u32(base, APLIC_DOMAINCFG, DOMAIN_ON_BY_MESSAGE)
    }
    controller.lines = highest + 1
    return .Ok(controller.lines)
}

/**
 * Deliver a line to a hart as the kernel's ID there, still masked (arch_interface.route_wired).
 *
 * On a PLIC the line is disabled in every context and the route kept, replacing any for the same line or the same ID
 * on the same hart; unmask_wired enables it in the hart's. On the APLIC its mode is set from trigger and polarity and
 * its target is the hart's interrupt file with the ID as the identity.
 *
 * @param controller The controller, from init_interrupt_controller.
 * @param line The line, from 1, below controller's lines.
 * @param cpu_hardware_id The hart's ID; one the controller doesn't serve leaves the line unrouted.
 * @param id The kernel's device interrupt ID on that hart, from device_interrupt_range.
 * @param trigger Edge or level.
 * @param polarity Which level or edge is active.
 */
route_wired :: fn(
    controller : ptr[mut InterruptController],
    line : u32,
    cpu_hardware_id : u64,
    id : arch_interface.InterruptId,
    trigger : arch_interface.Trigger,
    polarity : arch_interface.Polarity
) {
    system :: current_system()
    hart :: hart_of(system, cpu_hardware_id) or_return void
    mask_wired(controller, line)
    if controller.kind == .Aplic {
        high :: polarity == .ActiveHigh
        mode :: if trigger == .Edge {
            if high {
                SOURCE_EDGE_RISING
            }
            else {
                SOURCE_EDGE_FALLING
            }
        }
        else if high {
            SOURCE_LEVEL_HIGH
        }
        else {
            SOURCE_LEVEL_LOW
        }
        at :: cast[u64](line - 1) * 4
        write_u32(controller.registers, APLIC_SOURCECFG + at, mode)
        write_u32(controller.registers, APLIC_TARGET + at, (hart.imsic_index << 18) | (cast[u32](id) & 0x7ff))
        return void
    }
    record_route(system, cpu_hardware_id, cast[u32](id), line)
}

/**
 * Keep a PLIC route, replacing any for the same line or for the same ID on the same hart, under routes_lock.
 *
 * Asserts there's a free slot, which there always is while IDs come from device_interrupt_range.
 *
 * @param system The shared state, whose routes change.
 * @param hart The hart's ID.
 * @param id The kernel's device interrupt ID on that hart.
 * @param line The PLIC's source number.
 */
record_route :: fn(system : ptr[mut ArchSystem], hart : u64, id : u32, line : u32) {
    concurrency.lock(&system.routes_lock)
    defer concurrency.unlock(&system.routes_lock)
    free : usize = MAX_ROUTES
    for &route, index in system.routes {
        if route.used && (route.line == line || (route.hart == hart && route.id == id)) {
            route.used = false
        }
        if !route.used && free == MAX_ROUTES {
            free = index
        }
    }
    runtime.assert(free < MAX_ROUTES, "a route for every device interrupt ID")
    if free < MAX_ROUTES {
        system.routes[free] = Route.{used = true, hart = hart, id = id, line = line}
    }
}

/**
 * Mask a line (arch_interface.mask_wired): on a PLIC disabled in every supervisor context, on the APLIC through
 * clrienum.
 *
 * @param controller The controller, from init_interrupt_controller.
 * @param line The line, from 1, below controller's lines.
 */
mask_wired :: fn(controller : ptr[mut InterruptController], line : u32) {
    if controller.kind == .Aplic {
        write_u32(controller.registers, APLIC_CLRIENUM, line)
        return void
    }
    system :: current_system()
    for i in 0..<cast[usize](system.hart_count) {
        if i >= system.harts.count {
            break
        }
        enable :: PLIC_ENABLE + cast[u64](system.harts[i].plic_context) * 0x80 + cast[u64](line / 32) * 4
        write_u32(controller.registers, enable, read_u32(controller.registers, enable) & ~(cast[u32](1) << (line % 32)))
    }
}

/**
 * Unmask a line (arch_interface.unmask_wired): on a PLIC enabled in its routed hart's supervisor context, on the APLIC
 * through setienum.
 *
 * @param controller The controller, from init_interrupt_controller.
 * @param line The line, from 1, below controller's lines, routed already (route_wired); a PLIC line without a route
 *     stays masked.
 */
unmask_wired :: fn(controller : ptr[mut InterruptController], line : u32) {
    if controller.kind == .Aplic {
        write_u32(controller.registers, APLIC_SETIENUM, line)
        return void
    }
    system :: current_system()
    hart_id := NO_HART
    for route in system.routes {
        if route.used && route.line == line {
            hart_id = route.hart
        }
    }
    hart :: hart_of(system, hart_id) or_return void
    enable :: PLIC_ENABLE + cast[u64](hart.plic_context) * 0x80 + cast[u64](line / 32) * 4
    write_u32(controller.registers, enable, read_u32(controller.registers, enable) | (cast[u32](1) << (line % 32)))
}

/** A hart ID no hart has, for a line with no route. */
NO_HART : u64 : 0xffffffffffffffff

/**
 * Give the bytes the controller keeps for each device's MSIs (arch_interface.msi_device_memory).
 *
 * @return 0 with the AIA, whose IMSIC keeps nothing per device; null with a PLIC, which takes no MSIs.
 */
msi_device_memory :: fn() -> u64? {
    return if current_system().controller == .Aia { cast[u64](0) } else { null }
}

/**
 * Give the bytes the controller needs for MSIs (arch_interface.msi_controller_memory).
 *
 * @return 0: the IMSIC needs none of L2's.
 */
msi_controller_memory :: fn() -> u64 {
    return 0
}

/**
 * Set up MSIs (arch_interface.init_msi): nothing, as each hart's interrupt file was set up by init_cpu.
 *
 * @param memory Unused.
 */
init_msi :: fn(memory : arch_interface.PhysicalAddress) {}

/**
 * Make a device's MSIs known (arch_interface.add_msi_device): nothing, as the IMSIC takes a message from any device.
 *
 * @param source Unused.
 * @param memory Unused.
 * @param events Unused.
 */
add_msi_device :: fn(source : u32, memory : arch_interface.PhysicalAddress, events : u32) {}

/**
 * Forget a device's MSIs (arch_interface.remove_msi_device): nothing, as add_msi_device kept nothing.
 *
 * @param source Unused.
 */
remove_msi_device :: fn(source : u32) {}

/**
 * Route a device's event to a hart (arch_interface.route_msi): its message is the ID written to the hart's interrupt
 * file.
 *
 * @param source Unused: the IMSIC takes a message from any device.
 * @param event Unused, for the same reason.
 * @param cpu_hardware_id The hart's ID.
 * @param id The interrupt it arrives as, an IMSIC identity from device_interrupt_range.
 * @return The hart's supervisor interrupt file's physical address, its seteipnum_le, and id; address 0, which the
 *     driver mustn't program, if the controller doesn't serve the hart.
 */
route_msi :: fn(
    source : u32,
    event : u32,
    cpu_hardware_id : u64,
    id : arch_interface.InterruptId
) -> arch_interface.MsiMessage {
    hart :: hart_of(current_system(), cpu_hardware_id) or_return arch_interface.MsiMessage.{}
    return arch_interface.MsiMessage.{address = hart.imsic_file + IMSIC_SETEIPNUM, data = cast[u32](id)}
}

/**
 * Deliver a routed event elsewhere (arch_interface.move_msi): a new message, as route_msi gives it.
 *
 * @param source Unused.
 * @param event Unused.
 * @param cpu_hardware_id The hart it goes to now.
 * @param id The interrupt it arrives as now.
 * @return The message the device sends now, which the driver programs.
 */
move_msi :: fn(
    source : u32,
    event : u32,
    cpu_hardware_id : u64,
    id : arch_interface.InterruptId
) -> arch_interface.MsiMessage {
    return route_msi(source, event, cpu_hardware_id, id)
}

/**
 * Stop delivering an event (arch_interface.unroute_msi): nothing to undo at the IMSIC; the device's driver stops it.
 *
 * @param source Unused.
 * @param event Unused.
 */
unroute_msi :: fn(source : u32, event : u32) {}

/**
 * Give the page devices write their MSIs to (arch_interface.msi_doorbell): none yet, as the IOMMU, which would map the
 * harts' interrupt files into each domain, comes with R6.
 *
 * @return Null.
 */
msi_doorbell :: fn() -> arch_interface.PhysicalAddress? {
    return null
}

/**
 * Say where the emulator's test device is (arch_interface.test_device): with the AIA, the APLIC's last source, which
 * nothing on QEMU's virt uses, pended through setipnum; with a PLIC, the UART's line, whose transmitter's interrupt
 * test_device_interrupts arms.
 *
 * @return The controller, at its physical address (0 without one), the line, edge-triggered and active high: the
 *     UART's interrupt is a level, but end_of_interrupt takes it back, so it comes once for each time it's armed.
 */
test_device :: fn() -> arch_interface.TestDevice {
    system :: current_system()
    if system.controller == .Aia {
        return arch_interface.TestDevice.{
            kind = .Aplic,
            registers = cast[arch_interface.PhysicalAddress](system.aplic_physical),
            line = system.aplic_sources,
            trigger = .Edge,
            polarity = .ActiveHigh,
        }
    }
    return arch_interface.TestDevice.{
        kind = .Plic,
        registers = cast[arch_interface.PhysicalAddress](system.plic_physical),
        line = system.uart_line,
        trigger = .Edge,
        polarity = .ActiveHigh,
    }
}

/**
 * Start or stop the test device (arch_interface.test_device_interrupts): while it's on, each tick of the hart that
 * started it pends its line once (pend_test_line), TEST_DEVICE_HZ a second, by a deadline of the test device's own
 * (take_timer), as the kernel's ticks stop while the hart's idle.
 *
 * @param on True to start it on the calling hart, its line pended at once; false to stop it, from any hart, the
 *     UART's transmitter interrupt turned off. The starting hart's own deadline lapses at its next timer interrupt.
 */
test_device_interrupts :: fn(on : bool) {
    system :: current_system()
    cpu :: current_cpu()
    system.test_interrupts = on
    if on {
        system.test_hart = cpu.hart_id
        arm_test_line(cpu, system, riscv64.csrr(.TIME))
        write_compare(cpu)
    }
    else if system.controller == .Plic {
        write_register(system.console, UART_INTERRUPT_ENABLE, 0)
    }
}

/** IER's ETBEI (bit 1): the UART interrupts while its transmitter holding register is empty. */
UART_TRANSMIT_INTERRUPT : u32 : 1 << 1

/**
 * Pend the test device's line once: with the AIA through the APLIC's setipnum, as if a device raised it; with a PLIC by
 * arming the UART's transmitter interrupt again, which an empty transmitter raises at once.
 *
 * @param system The shared state, with the controller's and the console's registers.
 */
pend_test_line :: fn(system : ptr[ArchSystem]) {
    if system.controller == .Aia {
        write_u32(system.aplic, APLIC_SETIPNUM, system.aplic_sources)
        return void
    }
    write_register(system.console, UART_INTERRUPT_ENABLE, 0)
    write_register(system.console, UART_INTERRUPT_ENABLE, UART_TRANSMIT_INTERRUPT)
}

/**
 * Read a 32-bit device register, volatile.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes, 4-aligned.
 * @return The 32 bits the register reads as now; each call loads afresh.
 */
read_u32 :: fn(base : u64, offset : u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

/**
 * Write a 32-bit device register, volatile.
 *
 * @param base The register block's virtual address.
 * @param offset The register's offset in bytes, 4-aligned.
 * @param value What to write.
 */
write_u32 :: fn(base : u64, offset : u64, value : u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}
