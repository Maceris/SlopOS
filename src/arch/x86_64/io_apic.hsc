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

IO_APIC_SELECT : u64 : 0x00
IO_APIC_WINDOW : u64 : 0x10
IO_APIC_VERSION_REGISTER : u32 : 0x01
IO_APIC_REDIRECTION_REGISTER : u32 : 0x10

REDIRECTION_ACTIVE_LOW : u32 : 1 << 13
REDIRECTION_LEVEL : u32 : 1 << 15
REDIRECTION_MASKED : u32 : 1 << 16

// An I/O APIC has at most 240 lines: its maximum redirection entry is 8 bits, and vectors stop at 255.
MAX_IO_APIC_LINES : u32 : 240

// The 8259 PICs' data ports, where writing a mask masks their lines.
//SPEC: Intel 8259A datasheet (operation command word 1, the interrupt mask)
PIC_MASTER_DATA : u16 : 0x21
PIC_SLAVE_DATA : u16 : 0xa1

// One wired interrupt controller (arch_interface.InterruptController).
InterruptController :: struct {
    // Its registers, mapped by L2 as device memory.
    registers : u64,
    lines : u32,
}

/*
 * An I/O APIC at registers, with every line masked: how many lines it has. Its version register
 * says it is one: a version from 0x10 to 0x2f, and a line count that fits.
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

/*
 * Deliver line as id to the local APIC with this ID, fixed delivery in physical destination mode,
 * still masked.
 */
//TODO(claude): destinations above 255 need interrupt remapping through the IOMMU (M7)
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

mask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    low :: read_io_apic(controller, redirection_low(line))
    write_io_apic(controller, redirection_low(line), low | REDIRECTION_MASKED)
}

unmask_wired :: fn(controller: ptr[mut InterruptController], line: u32) {
    low :: read_io_apic(controller, redirection_low(line))
    write_io_apic(controller, redirection_low(line), low & ~REDIRECTION_MASKED)
}

redirection_low :: fn(line: u32) -> u32 {
    return IO_APIC_REDIRECTION_REGISTER + line * 2
}

redirection_high :: fn(line: u32) -> u32 {
    return IO_APIC_REDIRECTION_REGISTER + line * 2 + 1
}

read_io_apic :: fn(controller: ptr[InterruptController], register: u32) -> u32 {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](controller.registers + IO_APIC_SELECT), register)
    return intrinsics.volatile_load_u32(cast[ptr[u32]](controller.registers + IO_APIC_WINDOW))
}

write_io_apic :: fn(controller: ptr[InterruptController], register: u32, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](controller.registers + IO_APIC_SELECT), register)
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](controller.registers + IO_APIC_WINDOW), value)
}

// Mask every line of both 8259 PICs, which the I/O APICs replace.
mask_legacy_pics :: fn() {
    x86_64.out_u8(PIC_MASTER_DATA, 0xff)
    x86_64.out_u8(PIC_SLAVE_DATA, 0xff)
}
