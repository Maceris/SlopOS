package arch_x86_64

import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"

// The early console: the first 16550 UART, at COM1's I/O ports
//SPEC: TI PC16550D datasheet (registers, line control, line status); COM1 at I/O port 0x3f8
/** The first I/O port of COM1, the early console's UART; its registers are at offsets from it. */
COM1 : u16 : 0x3f8
/** The UART's data register offset: a write sends a byte (with DLAB clear). */
UART_DATA : u16 : 0
/** The UART's interrupt enable register offset (with DLAB clear); 0 turns every interrupt off. */
UART_INTERRUPT_ENABLE : u16 : 1
// With DLAB set, registers 0 and 1 are the divisor latch
/** The offset of the divisor latch's low byte, with DLAB set. */
UART_DIVISOR_LOW : u16 : 0
/** The offset of the divisor latch's high byte, with DLAB set. */
UART_DIVISOR_HIGH : u16 : 1
/** The UART's FIFO control register offset, write-only. */
UART_FIFO_CONTROL : u16 : 2
/** The UART's line control register offset: word length, parity, stop bits and DLAB. */
UART_LINE_CONTROL : u16 : 3
/** The UART's modem control register offset: DTR and RTS among others. */
UART_MODEM_CONTROL : u16 : 4
/** The UART's line status register offset, read-only. */
UART_LINE_STATUS : u16 : 5

/** Line control bit 7, the divisor latch access bit: registers 0 and 1 become the divisor latch. */
LINE_CONTROL_DLAB : u8 : 0x80
/** Line control for 8 data bits, no parity, 1 stop bit, with DLAB clear. */
LINE_CONTROL_8N1 : u8 : 0x03
/** FIFO control: enable and clear both FIFOs, with the receive interrupt at 14 bytes. */
FIFO_ENABLE_AND_CLEAR : u8 : 0xc7
/** Modem control: DTR and RTS set, so the other end sees the UART ready. */
MODEM_READY : u8 : 0x03
/** Line status bit 5: the transmit holding register is empty, so another byte can be written. */
LINE_STATUS_TRANSMITTER_EMPTY : u8 : 0x20
/** The divisor latch's value for 115200 baud from the 1.8432 MHz clock, divided by 16. */
BAUD_DIVISOR : u16 : 1

/** The I/O port of QEMU's isa-debug-exit device, which the test harness adds (tools/boot.py). */
DEBUG_EXIT_PORT : u16 : 0xf4
/** The I/O port of the chipset's reset control register. */
RESET_CONTROL_PORT : u16 : 0xcf9

/*
 * The test device: QEMU's PIT, ISA IRQ 0, which QEMU's MADT routes to line 2 of its I/O APIC, at the
 * address the MP specification gives the first I/O APIC.
 */
//SPEC: Intel MultiProcessor Specification 1.4, §3.6.1 (the default I/O APIC address); Intel 8254 datasheet
/** The physical address of the test device's I/O APIC's registers, the first I/O APIC's default. */
TEST_IO_APIC : u64 : 0xfec00000
/** The I/O APIC line QEMU's PIT is wired to. */
TEST_PIT_LINE : u32 : 2
/** The I/O port of PIT channel 0's counter. */
PIT_CHANNEL_0 : u16 : 0x40
// Channel 0, low then high byte, binary: mode 2 (a rate generator), or mode 0 (once, at the end of its count)
/** The PIT command for channel 0, low then high byte, mode 2 (a rate generator), binary. */
PIT_CHANNEL_0_RATE : u8 : 0x34
/** The PIT command for channel 0, low then high byte, mode 0 (once, at the end of its count), binary. */
PIT_CHANNEL_0_ONCE : u8 : 0x30
/** The PIT count for the test device: 1193182 Hz / 1193, about a thousand interrupts a second. */
PIT_TEST_DIVISOR : u16 : 1193

/**
 * Set up the early console, COM1's UART: 115200 baud, 8N1, FIFOs on, no interrupts.
 *
 * Called once, before anything is written to it. It's in I/O ports, so nothing has to be mapped.
 *
 * @param direct_map_offset Where the bootloader's direct map is, not needed for I/O ports.
 * @param firmware The firmware's tables, not needed: COM1 is assumed at its usual ports.
 */
early_console_init :: fn(direct_map_offset: u64, firmware: ptr[boot_info.FirmwareTables]) {
    x86_64.out_u8(COM1 + UART_INTERRUPT_ENABLE, 0)
    x86_64.out_u8(COM1 + UART_LINE_CONTROL, LINE_CONTROL_DLAB)
    x86_64.out_u8(COM1 + UART_DIVISOR_LOW, cast[u8](BAUD_DIVISOR & 0xff))
    x86_64.out_u8(COM1 + UART_DIVISOR_HIGH, cast[u8](BAUD_DIVISOR >> 8))
    x86_64.out_u8(COM1 + UART_LINE_CONTROL, LINE_CONTROL_8N1)
    x86_64.out_u8(COM1 + UART_FIFO_CONTROL, FIFO_ENABLE_AND_CLEAR)
    x86_64.out_u8(COM1 + UART_MODEM_CONTROL, MODEM_READY)
}

/**
 * Write text to the early console, waiting for the UART to take each byte.
 *
 * Each line feed is preceded by a carriage return, as a terminal needs. Safe from any context, interrupts disabled or
 * not, but not serialized: writes from two CPUs at once interleave.
 *
 * @param text The text, sent byte by byte, UTF-8 as it is.
 */
early_console_write :: fn(text: string) {
    for character in text {
        // A terminal needs a carriage return before each line feed
        if character == '\n' {
            write_byte(cast[u8]('\r'))
        }
        write_byte(cast[u8](character))
    }
}

/**
 * Write one byte to COM1, busy-waiting until its transmit holding register is empty.
 *
 * @param byte The byte, sent as it is.
 */
write_byte :: fn(byte: u8) {
    loop {
        x86_64.pause()
    }
    while (x86_64.in_u8(COM1 + UART_LINE_STATUS) & LINE_STATUS_TRANSMITTER_EMPTY) == 0
    x86_64.out_u8(COM1 + UART_DATA, byte)
}

/**
 * Ask QEMU to exit through its isa-debug-exit device, for tests that boot the kernel.
 *
 * QEMU exits with a status made from code. Only called when the command line asks for it: on real hardware port 0xf4
 * may be something else entirely, and where nothing's there this returns, having done nothing.
 *
 * @param code The value written to the device.
 */
test_exit :: fn(code: u32) {
    x86_64.out_u32(DEBUG_EXIT_PORT, code)
}

/**
 * Choose how the machine resets, for reset to use later.
 *
 * @param firmware The firmware's tables, not needed.
 * @param direct_map_offset Where the bootloader's direct map is, not needed.
 * @return 1, the reset control register, the only method on x86-64, which needs nothing from the firmware.
 */
reset_method :: fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> u8 {
    return 1
}

/**
 * Reset the machine, warm, by the chipset's reset control register (0xcf9): RAM is kept.
 *
 * It normally doesn't return; where the chipset has no such register it returns, having done nothing.
 *
 * @param method What reset_method chose, not used: there's only the one method.
 */
reset :: fn(method: u8) {
    x86_64.out_u8(RESET_CONTROL_PORT, 0x02)
    x86_64.out_u8(RESET_CONTROL_PORT, 0x06)
}

/**
 * Tell whether power_off can turn the machine off by itself.
 *
 * @param method What reset_method chose, not used.
 * @return False: x86-64 turns off through ACPI's PM1 control registers, which only the firmware's tables and AML
 *     name, so the kernel is told them (power_set_off) and writes them itself.
 */
can_power_off :: fn(method: u8) -> bool {
    return false
}

/**
 * Turn the machine off by the architecture's own means: x86-64 has none, so this returns, having done nothing.
 *
 * @param method What reset_method chose, not used.
 */
power_off :: fn(method: u8) {}

/**
 * Describe the emulator's test device, QEMU's PIT on line 2 of its first I/O APIC, for test_ioapic.
 *
 * @return An I/O APIC at TEST_IO_APIC, line TEST_PIT_LINE, edge triggered and active high.
 */
test_device :: fn() -> arch_interface.TestDevice {
    return arch_interface.TestDevice.{
        kind = .IoApic,
        registers = cast[arch_interface.PhysicalAddress](TEST_IO_APIC),
        line = TEST_PIT_LINE,
        trigger = .Edge,
        polarity = .ActiveHigh,
    }
}

/**
 * Start or stop the test device's interrupts, PIT channel 0's.
 *
 * Started, it's a rate generator, about a thousand a second. Stopped, it counts once from its largest count, so at
 * most one more edge comes, which a masked line ignores.
 *
 * @param on True to start them, false to stop them.
 */
test_device_interrupts :: fn(on: bool) {
    divisor :: if on { PIT_TEST_DIVISOR } else { cast[u16](0) }
    x86_64.out_u8(PIT_COMMAND, if on { PIT_CHANNEL_0_RATE } else { PIT_CHANNEL_0_ONCE })
    x86_64.out_u8(PIT_CHANNEL_0, cast[u8](divisor & 0xff))
    x86_64.out_u8(PIT_CHANNEL_0, cast[u8](divisor >> 8))
}

/**
 * Tell whether the calling CPU takes interrupts now.
 *
 * @return RFLAGS.IF: true if maskable interrupts are enabled.
 */
interrupts_enabled :: fn() -> bool {
    return x86_64.read_rflags() & 0x200 != 0
}

/** Stop the calling CPU for good, with interrupts disabled. NMIs still wake it, so it halts again. */
halt :: fn() #never_returns {
    loop {
        x86_64.cli()
        x86_64.hlt()
    }
}

/**
 * Wait for an interrupt with interrupts enabled, never returning.
 *
 * sti takes effect after the next instruction, so no interrupt can slip in between it and hlt. The interrupt enters
 * the kernel on the kernel stack, which holds nothing while idle, through kernel_entry.interrupt with from = .Idle.
 */
idle :: fn() #never_returns {
    loop {
        x86_64.sti()
        x86_64.hlt()
    }
}

/** Hint that the caller is spinning, with pause, which saves power and helps the other hyperthread. */
spin_hint :: fn() {
    x86_64.pause()
}

/** Stop the calling CPU taking maskable interrupts, with cli; NMIs still arrive. */
mask_interrupts :: fn() {
    x86_64.cli()
}

/** Let the calling CPU take maskable interrupts again, with sti, from after the next instruction. */
unmask_interrupts :: fn() {
    x86_64.sti()
}

/**
 * Read one value from the CPU's random source, RDSEED.
 *
 * @return 64 bits of entropy, or null if the CPU has no RDSEED or it had nothing ready, in which case it may be asked
 *     again later.
 */
hardware_entropy :: fn() -> u64? {
    features :: detect_features()
    if !has(&features, .X86Rdseed) {
        return null
    }
    return x86_64.rdseed()
}

/**
 * Tell whether the architecture has I/O ports (decisions/0093).
 *
 * @return True: x86-64 has them, so port_read and port_write work.
 */
has_io_ports :: fn() -> bool {
    return true
}

/**
 * Read from an I/O port, with in.
 *
 * @param port The port, any of the 65536.
 * @param width How many bytes to read: 1, 2 or 4.
 * @return The value, zero-extended, or null for any other width, when nothing was read.
 */
port_read :: fn(port: u16, width: u32) -> u32? {
    if width == 1 {
        return cast[u32](x86_64.in_u8(port))
    }
    if width == 2 {
        return cast[u32](x86_64.in_u16(port))
    }
    if width == 4 {
        return x86_64.in_u32(port)
    }
    return null
}

/**
 * Write to an I/O port, with out.
 *
 * @param port The port, any of the 65536.
 * @param width How many bytes to write: 1, 2 or 4.
 * @param value The value, of which the low width bytes are written.
 * @return True if it was written; false for any other width, when nothing was.
 */
port_write :: fn(port: u16, width: u32, value: u32) -> bool {
    if width == 1 {
        x86_64.out_u8(port, cast[u8](value & 0xff))
        return true
    }
    if width == 2 {
        x86_64.out_u16(port, cast[u16](value & 0xffff))
        return true
    }
    if width == 4 {
        x86_64.out_u32(port, value)
        return true
    }
    return false
}
