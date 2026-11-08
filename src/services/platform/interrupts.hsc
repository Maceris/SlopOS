package platform

import slop_os from "std/os"
import acpi_tables from "../../acpi_tables"
import devicetree from "../../devicetree"
import log_line from "../../log_line"
import pci from "../../pci"
import platform as protocol from "../../protocols/platform"

/*
 * Wired interrupts (decisions/0039, 0182 P3): the interrupt controllers the firmware tables describe, registered with
 * the kernel the first time a line of one is wanted, and IRQs made for the lines of the devices that don't signal by
 * MSIs: the SCI, for the ACPI service; and on AArch64 the GPIO controller the power button is wired to.
 */
//SPEC: ACPI 6.5, §5.2.12 (MADT); Linux's gpio-keys, arm,pl061 and arm,gic-v3 bindings

/** The most interrupt controllers registered. */
MAX_CONTROLLERS :: 8
/** KEY_POWER, the power button's key code in a gpio-keys node's "linux,code". */
KEY_POWER : u32 : 116
/** A PL061's registers' bytes. */
PL061_SIZE : u64 : 4096

/** An interrupt controller registered with the kernel. */
Controller :: struct {
    /** Its registers' physical address. */
    address : u64,
    /** The kernel's number for it, for irq_create. */
    number : u32,
    /** How many lines it has. */
    lines : u32,
}

/**
 * Register an interrupt controller with the kernel, once.
 *
 * @param to The debug log; a controller the kernel refuses is logged.
 * @param platform The platform capability.
 * @param state The platform service's state, whose controllers keep it.
 * @param kind What it is.
 * @param address Its registers' physical address.
 * @return It; null if the kernel refused it, or there's no room to keep it.
 */
controller_at :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], kind: slop_os.ControllerKind, address: u64)
    -> Controller? {
    for controller, i in state.controllers {
        if i >= state.controller_count {
            break
        }
        if controller.address == address {
            return controller
        }
    }
    at :: state.controller_count
    if at >= state.controllers.count {
        return null
    }
    match slop_os.controller_register(platform, kind, address) {
        case Ok(info) => {
            made :: Controller.{address = address, number = info.number, lines = info.lines}
            state.controllers[at] = made
            state.controller_count = at + 1
            return made
        }
        case Error(error) => {
            log_line.write(to, "platform: the kernel refused the interrupt controller at %: %", address, error)
            return null
        }
    }
}

/**
 * Make an IRQ for a controller's line.
 *
 * @param to The debug log; a refusal is logged.
 * @param platform The platform capability.
 * @param controller The controller.
 * @param line Its line.
 * @param level Whether it's level-triggered.
 * @param low Whether it's active-low.
 * @return The IRQ, which moves to whoever it's given; NO_HANDLE if the line's past the controller's or the kernel
 *     refused it.
 */
irq_for :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, controller: Controller, line: u32, level: bool, low: bool) -> slop_os.Irq {
    none :: cast[slop_os.Irq](slop_os.NO_HANDLE)
    if line >= controller.lines {
        return none
    }
    flags :: (if level { slop_os.IRQ_LEVEL } else { cast[u32](0) }) | (if low { slop_os.IRQ_ACTIVE_LOW } else { cast[u32](0) })
    match slop_os.irq_create(platform, slop_os.startup_block().budget, controller.number, line, flags) {
        case Ok(irq) => return irq
        case Error(error) => {
            log_line.write(to, "platform: no IRQ for line % of the interrupt controller at %: %", line, controller.address, error)
            return none
        }
    }
}

/**
 * Make the SCI's IRQ: the FADT's SCI_INT, routed by the MADT's overrides to an I/O APIC's line, level-triggered and
 * active-low unless an override says otherwise.
 *
 * @param to The debug log.
 * @param platform The platform capability.
 * @param state The platform service's state, its firmware tables mapped.
 * @return The IRQ, which moves to the ACPI service; NO_HANDLE without a MADT, a FADT, or an I/O APIC with the line.
 */
sci_irq :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform]) -> slop_os.Irq {
    none :: cast[slop_os.Irq](slop_os.NO_HANDLE)
    fadt_region :: pci.firmware_table(state.tables, state.tables_size, "FACP") or_return none
    madt_region := pci.firmware_table(state.tables, state.tables_size, "APIC") or_else devicetree.Region.{}
    if madt_region.size == 0 {
        log_line.write(to, "platform: no SCI, as there's no MADT")
        return none
    }
    fadt :: acpi_tables.parse_fadt(view_of(cast[ptr[u8]](fadt_region.address), cast[usize](fadt_region.size))) or_return none
    madt := acpi_tables.parse_madt(view_of(cast[ptr[u8]](madt_region.address), cast[usize](madt_region.size))) or_return none
    signaling :: acpi_tables.route_isa(&madt, cast[u32](fadt.sci), true, true)
    // The I/O APIC whose lines start nearest below the GSI
    chosen : acpi_tables.IoApic? = null
    for io_apic, i in madt.io_apics {
        if i >= madt.io_apic_count {
            break
        }
        if io_apic.gsi_base <= signaling.gsi && ((chosen is_none) || io_apic.gsi_base > (chosen or_else io_apic).gsi_base) {
            chosen = io_apic
        }
    }
    if chosen is_none {
        log_line.write(to, "platform: no SCI, as no I/O APIC of the MADT's % has GSI %", madt.io_apic_count, signaling.gsi)
        return none
    }
    io_apic :: chosen or_return none
    controller :: controller_at(to, platform, state, .IoApic, io_apic.address) or_return none
    // Its requester ID, for remapping its lines where an IOMMU remaps interrupts
    for known, i in state.io_apic_sources {
        if i < state.io_apic_source_count && known.id == io_apic.id {
            if slop_os.controller_set_source(platform, controller.number, known.source) is_error {
                log_line.write(to, "platform: the kernel refused the I/O APIC's requester ID")
            }
        }
    }
    irq :: irq_for(to, platform, controller, signaling.gsi - io_apic.gsi_base, signaling.level, signaling.low)
    if cast[slop_os.Handle](irq) != slop_os.NO_HANDLE {
        log_line.write(to, "platform: the SCI is GSI %, %-triggered, active-%", signaling.gsi, if signaling.level { "level" } else { "edge" },
            if signaling.low { "low" } else { "high" })
    }
    return irq
}

/**
 * Claim the power button, on a machine whose devicetree wires it to a GPIO controller (gpio-keys' KEY_POWER on a
 * PL061): its registers, its IRQ through the GIC, and its pin.
 *
 * @param to The debug log.
 * @param platform The platform capability.
 * @param state The platform service's state, its firmware tables mapped.
 * @return ClaimedPowerButton, whose handles move to the client; NoDevice without a devicetree, such a key, a PL061, a
 *     GIC, or if they can't be made.
 */
claim_power_button :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform]) -> protocol.Response {
    blob :: pci.firmware_table(state.tables, state.tables_size, "DTB ") or_return .NoDevice
    tree := devicetree.open(blob.address) or_return .NoDevice
    key := devicetree.find_node(&tree, "", 0, false, "linux,code", KEY_POWER) or_return .NoDevice
    gpios :: devicetree.property(&tree, &key, "gpios") or_return .NoDevice
    phandle :: devicetree.cell(gpios, 0) or_return .NoDevice
    pin :: devicetree.cell(gpios, 1) or_return .NoDevice
    controller := devicetree.find_phandle(&tree, phandle) or_return .NoDevice
    compatible :: devicetree.property(&tree, &controller, "compatible") or_return .NoDevice
    if !devicetree.lists(compatible, "arm,pl061") {
        return .NoDevice
    }
    registers :: devicetree.reg(&tree, &controller, 0) or_return .NoDevice
    interrupts :: devicetree.property(&tree, &controller, "interrupts") or_return .NoDevice
    kind :: devicetree.cell(interrupts, 0) or_return .NoDevice
    number :: devicetree.cell(interrupts, 1) or_return .NoDevice
    flags :: devicetree.cell(interrupts, 2) or_return .NoDevice
    found := devicetree.find_compatible(&tree, "arm,gic-v3")
    if found is_none {
        found = devicetree.find_compatible(&tree, "arm,cortex-a15-gic")
    }
    gic := found or_return .NoDevice
    distributor :: devicetree.reg(&tree, &gic, 0) or_return .NoDevice
    gic_controller :: controller_at(to, platform, state, .GicDistributor, distributor.address) or_return .NoDevice
    // The distributor's lines are SPIs, by their numbers, which the kernel adds 32 to; flags 4 and 8 level, 2 and 8 low
    if kind != 0 {
        return .NoDevice
    }
    line :: number
    irq :: irq_for(to, platform, gic_controller, line, flags & 12 != 0, flags & 10 != 0)
    if cast[slop_os.Handle](irq) == slop_os.NO_HANDLE {
        return .NoDevice
    }
    memory := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match slop_os.memory_create_physical(platform, slop_os.startup_block().budget, registers.address, PL061_SIZE, .Device) {
        case Ok(made) => memory = made
        case Error(_) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](irq))
            return .NoDevice
        }
    }
    log_line.write(to, "platform: the power button is pin % of the PL061 at %", pin, registers.address)
    return .ClaimedPowerButton(protocol.PowerButton.{registers = memory, irq = irq, pin = pin})
}
