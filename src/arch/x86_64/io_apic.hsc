package arch_x86_64

import x86_64 from "base/intrinsics"
import intrinsics from "base"
import arch_interface from "../../arch_interface"

/*
 * Wired interrupts through I/O APICs (arch_interface, Wired Interrupts): the only kind x86-64 has. The
 * platform service finds them in the MADT and registers them (decisions/0039); the kernel maps their
 * registers and calls these. L2 serializes calls on one controller, since each register is reached
 * through a select register and a window.
 *
 * The legacy 8259 PICs are masked by init_system and never used.
 */
//SPEC: Intel 82093AA I/O APIC datasheet, §3.1 (IOREGSEL, IOWIN), §3.2 (IOAPICVER, IOREDTBL)

/** The byte offset of IOREGSEL, the register select, in an I/O APIC's memory-mapped registers. */
IO_APIC_SELECT : u64 : 0x00
/** The byte offset of IOWIN, the window onto the selected register, in an I/O APIC's memory-mapped registers. */
IO_APIC_WINDOW : u64 : 0x10
/** The index of IOAPICVER: the version in bits 0-7 and the highest redirection entry in bits 16-23. */
IO_APIC_VERSION_REGISTER : u32 : 0x01
/** The index of the first redirection table register, IOREDTBL0's low half; each line takes two, low then high. */
IO_APIC_REDIRECTION_REGISTER : u32 : 0x10

/** Redirection entry bit 13: the input pin's polarity active low, not active high. */
REDIRECTION_ACTIVE_LOW : u32 : 1 << 13
/** Redirection entry bit 15: the line level triggered, not edge triggered. */
REDIRECTION_LEVEL : u32 : 1 << 15
/** Redirection entry bit 16: the line masked, its interrupts not delivered. */
REDIRECTION_MASKED : u32 : 1 << 16

/** An I/O APIC has at most 240 lines: its maximum redirection entry is 8 bits, and vectors stop at 255. */
MAX_IO_APIC_LINES : u32 : 240

// The 8259 PICs' data ports, where writing a mask masks their lines.
//SPEC: Intel 8259A datasheet (operation command word 1, the interrupt mask)
/** The master 8259 PIC's data port, which takes its interrupt mask. */
PIC_MASTER_DATA : u16 : 0x21
/** The slave 8259 PIC's data port, which takes its interrupt mask. */
PIC_SLAVE_DATA : u16 : 0xa1

/** One wired interrupt controller (arch_interface.InterruptController), an I/O APIC. */
InterruptController :: struct {
    /** The virtual address of its registers, mapped by L2 as device memory. */
    registers : u64,
    /** How many lines it has, 1 to MAX_IO_APIC_LINES, as its version register says. */
    lines : u32,
}

/**
 * Set up an I/O APIC, with every line masked and its destination 0.
 *
 * Its version register has to say it is one: a version from 0x10 to 0x2f, and a line count that fits.
 *
 * @param controller Where its state goes; on an error, registers may have been set, and nothing else.
 * @param kind The kind of controller, which has to be IoApic.
 * @param registers The virtual address its registers are mapped at, as device memory, for as long as it's used.
 * @return How many lines it has, 1 to MAX_IO_APIC_LINES.
 * @error UnsupportedKind kind isn't IoApic, the only kind x86-64 has; nothing was touched.
 * @error NotFound The version register doesn't read as an I/O APIC's; no line was changed.
 */
init_interrupt_controller :: fn(
    controller: ptr[mut InterruptController],
    kind: arch_interface.ControllerKind,
    registers: arch_interface.VirtualAddress,
) -> Result[u32, arch_interface.ControllerError] {
    if kind != .IoApic {
        return .Error(.UnsupportedKind)
    }
    controller.registers = cast[u64](registers)
    version :: read_io_apic(controller, IO_APIC_VERSION_REGISTER)
    lines :: ((version >> 16) & 0xff) + 1
    if (version & 0xff) < 0x10 || (version & 0xff) > 0x2f || lines > MAX_IO_APIC_LINES {
        return .Error(.NotFound)
    }
    controller.lines = lines
    for line in 0..<lines {
        write_io_apic(controller, redirection_high(line), 0)
        write_io_apic(controller, redirection_low(line), REDIRECTION_MASKED)
    }
    return .Ok(lines)
}

//TODO(claude): destinations above 255 need interrupt remapping through the IOMMU (M7)
/**
 * Deliver a line as id to the local APIC with this ID, fixed delivery in physical destination mode, still masked.
 *
 * The line is masked while its entry changes, and left masked; unmask_wired lets it through.
 *
 * @param controller The I/O APIC, set up by init_interrupt_controller.
 * @param line The line, below the controller's lines; not checked.
 * @param cpu_hardware_id The target CPU's APIC ID. Only its low 8 bits are used, so a CPU whose ID is above 255
 *     can't be reached: the CPU with those low 8 bits gets the interrupt instead.
 * @param id The vector to deliver, of which only the low 8 bits are used; one of device_interrupt_range's.
 * @param trigger Whether the line is edge or level triggered.
 * @param polarity Whether the line is active high or active low.
 */
route_wired :: fn(
    controller: ptr[mut InterruptController],
    line: u32,
    cpu_hardware_id: u64,
    id: arch_interface.InterruptId,
    trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity,
) {
    low := (cast[u32](id) & 0xff) | REDIRECTION_MASKED
    if trigger == .Level {
        low |= REDIRECTION_LEVEL
    }
    if polarity == .ActiveLow {
        low |= REDIRECTION_ACTIVE_LOW
    }
    write_io_apic(controller, redirection_low(line), REDIRECTION_MASKED)
    write_io_apic(controller, redirection_high(line), cast[u32](cpu_hardware_id & 0xff) << 24)
    write_io_apic(controller, redirection_low(line), low)
}

/**
 * Route a line through VT-d's interrupt remapping, in its entry's remappable format, still masked
 * (arch_interface.route_wired_remapped): the handle from the remapped message, the vector as the entry delivers it, so
 * a level-triggered line's EOI reaches it.
 *
 * @param controller The I/O APIC.
 * @param line The line, below the controller's lines; not checked.
 * @param message The remappable-format message the IOMMU gave: its handle's low 15 bits in address bits 5 to 19, its
 *     16th in bit 2.
 * @param id The vector the remapped interrupt delivers.
 * @param trigger Whether the line is edge or level triggered.
 * @param polarity Whether the line is active high or active low.
 */
//SPEC: Intel Virtualization Technology for Directed I/O, §5.1.5.1 (I/O xAPIC programming in remappable format)
route_wired_remapped :: fn(
    controller: ptr[mut InterruptController],
    line: u32,
    message: arch_interface.MsiMessage,
    id: arch_interface.InterruptId,
    trigger: arch_interface.Trigger,
    polarity: arch_interface.Polarity,
) {
    handle :: cast[u32]((message.address >> 5) & 0x7fff) | (cast[u32]((message.address >> 2) & 1) << 15)
    low := (cast[u32](id) & 0xff) | REDIRECTION_MASKED | (((handle >> 15) & 1) << 11)
    if trigger == .Level {
        low |= REDIRECTION_LEVEL
    }
    if polarity == .ActiveLow {
        low |= REDIRECTION_ACTIVE_LOW
    }
    // The upper half: bit 48, the remappable format, then the handle's low 15 bits from 49
    high :: (cast[u32](1) << 16) | ((handle & 0x7fff) << 17)
    write_io_apic(controller, redirection_low(line), REDIRECTION_MASKED)
    write_io_apic(controller, redirection_high(line), high)
    write_io_apic(controller, redirection_low(line), low)
}

/**
 * Mask a line, so its interrupts aren't delivered, keeping the rest of its entry.
 *
 * @param controller The I/O APIC.
 * @param line The line, below the controller's lines; not checked.
 */
mask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    low :: read_io_apic(controller, redirection_low(line))
    write_io_apic(controller, redirection_low(line), low | REDIRECTION_MASKED)
}

/**
 * Unmask a line, so its interrupts are delivered as route_wired routed them, keeping the rest of its entry.
 *
 * @param controller The I/O APIC.
 * @param line The line, below the controller's lines; not checked.
 */
unmask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    low :: read_io_apic(controller, redirection_low(line))
    write_io_apic(controller, redirection_low(line), low & ~REDIRECTION_MASKED)
}

/**
 * Give the register index of a line's redirection entry's low half: vector, delivery, polarity, trigger and mask.
 *
 * @param line The line, from 0.
 * @return The index to select through IOREGSEL.
 */
redirection_low :: fn(line: u32) -> u32 {
    return IO_APIC_REDIRECTION_REGISTER + line * 2
}

/**
 * Give the register index of a line's redirection entry's high half, whose bits 24-31 are the destination.
 *
 * @param line The line, from 0.
 * @return The index to select through IOREGSEL.
 */
redirection_high :: fn(line: u32) -> u32 {
    return IO_APIC_REDIRECTION_REGISTER + line * 2 + 1
}

/**
 * Read an I/O APIC register, selecting it, then reading the window.
 *
 * Not atomic: a caller has to keep other calls on the same controller out in between.
 *
 * @param controller The I/O APIC, whose registers are mapped.
 * @param register The register's index, like IO_APIC_VERSION_REGISTER.
 * @return The register's 32 bits.
 */
read_io_apic :: fn(controller: ptr[InterruptController], register: u32) -> u32 {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](controller.registers + IO_APIC_SELECT), register)
    return intrinsics.volatile_load_u32(cast[ptr[u32]](controller.registers + IO_APIC_WINDOW))
}

/**
 * Write an I/O APIC register, selecting it, then writing the window.
 *
 * Not atomic: a caller has to keep other calls on the same controller out in between.
 *
 * @param controller The I/O APIC, whose registers are mapped.
 * @param register The register's index, like a line's redirection_low.
 * @param value The register's new 32 bits.
 */
write_io_apic :: fn(controller: ptr[InterruptController], register: u32, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](controller.registers + IO_APIC_SELECT), register)
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](controller.registers + IO_APIC_WINDOW), value)
}

/** Mask every line of both 8259 PICs, which the I/O APICs replace. */
mask_legacy_pics :: fn() {
    x86_64.out_u8(PIC_MASTER_DATA, 0xff)
    x86_64.out_u8(PIC_SLAVE_DATA, 0xff)
}
