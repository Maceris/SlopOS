package arch_x86_64

import x86_64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"

// The early console: the first 16550 UART, at COM1's I/O ports
//SPEC: TI PC16550D datasheet (registers, line control, line status); COM1 at I/O port 0x3f8
COM1 : u16 : 0x3f8
UART_DATA : u16 : 0
UART_INTERRUPT_ENABLE : u16 : 1
// With DLAB set, registers 0 and 1 are the divisor latch
UART_DIVISOR_LOW : u16 : 0
UART_DIVISOR_HIGH : u16 : 1
UART_FIFO_CONTROL : u16 : 2
UART_LINE_CONTROL : u16 : 3
UART_MODEM_CONTROL : u16 : 4
UART_LINE_STATUS : u16 : 5

LINE_CONTROL_DLAB : u8 : 0x80
// 8 data bits, no parity, 1 stop bit
LINE_CONTROL_8N1 : u8 : 0x03
// Enable and clear both FIFOs, interrupt at 14 bytes
FIFO_ENABLE_AND_CLEAR : u8 : 0xc7
// DTR and RTS
MODEM_READY : u8 : 0x03
LINE_STATUS_TRANSMITTER_EMPTY : u8 : 0x20
// 115200 baud from the 1.8432 MHz clock
BAUD_DIVISOR : u16 : 1

// QEMU's isa-debug-exit device, which the test harness adds (tools/boot.py)
DEBUG_EXIT_PORT : u16 : 0xf4

/*
 * The test device: QEMU's PIT, ISA IRQ 0, which QEMU's MADT routes to line 2 of its I/O APIC, at the
 * address the MP specification gives the first I/O APIC.
 */
//SPEC: Intel MultiProcessor Specification 1.4, §3.6.1 (the default I/O APIC address); Intel 8254 datasheet
TEST_IO_APIC : u64 : 0xfec00000
TEST_PIT_LINE : u32 : 2
PIT_CHANNEL_0 : u16 : 0x40
// Channel 0, low then high byte, binary: mode 2 (a rate generator), or mode 0 (once, at the end of its count)
PIT_CHANNEL_0_RATE : u8 : 0x34
PIT_CHANNEL_0_ONCE : u8 : 0x30
// 1193182 Hz / 1193: about a thousand interrupts a second
PIT_TEST_DIVISOR : u16 : 1193

// Set the early console up: 115200 baud, 8N1, FIFOs on, no interrupts. It's in I/O ports, so nothing is mapped.
early_console_init :: fn(direct_map_offset: u64, firmware: ptr[boot_info.FirmwareTables]) {
    x86_64.out_u8(COM1 + UART_INTERRUPT_ENABLE, 0)
    x86_64.out_u8(COM1 + UART_LINE_CONTROL, LINE_CONTROL_DLAB)
    x86_64.out_u8(COM1 + UART_DIVISOR_LOW, cast[u8](BAUD_DIVISOR & 0xff))
    x86_64.out_u8(COM1 + UART_DIVISOR_HIGH, cast[u8](BAUD_DIVISOR >> 8))
    x86_64.out_u8(COM1 + UART_LINE_CONTROL, LINE_CONTROL_8N1)
    x86_64.out_u8(COM1 + UART_FIFO_CONTROL, FIFO_ENABLE_AND_CLEAR)
    x86_64.out_u8(COM1 + UART_MODEM_CONTROL, MODEM_READY)
}

early_console_write :: fn(text: string) {
    for character in text {
        // A terminal needs a carriage return before each line feed
        if character == '\n' {
            write_byte(cast[u8]('\r'))
        }
        write_byte(cast[u8](character))
    }
}

write_byte :: fn(byte: u8) {
    loop {
        x86_64.pause()
    }
    while (x86_64.in_u8(COM1 + UART_LINE_STATUS) & LINE_STATUS_TRANSMITTER_EMPTY) == 0
    x86_64.out_u8(COM1 + UART_DATA, byte)
}

test_exit :: fn(code: u32) {
    x86_64.out_u32(DEBUG_EXIT_PORT, code)
}

test_device :: fn() -> arch_interface.TestDevice {
    return arch_interface.TestDevice.{
        kind = .IoApic,
        registers = cast[arch_interface.PhysicalAddress](TEST_IO_APIC),
        line = TEST_PIT_LINE,
        trigger = .Edge,
        polarity = .ActiveHigh,
    }
}

/*
 * The PIT's channel 0 as a rate generator, or stopped: counting once from its largest count, so at
 * most one more edge comes, which a masked line ignores.
 */
test_device_interrupts :: fn(on: bool) {
    divisor :: if on { PIT_TEST_DIVISOR } else { cast[u16](0) }
    x86_64.out_u8(PIT_COMMAND, if on { PIT_CHANNEL_0_RATE } else { PIT_CHANNEL_0_ONCE })
    x86_64.out_u8(PIT_CHANNEL_0, cast[u8](divisor & 0xff))
    x86_64.out_u8(PIT_CHANNEL_0, cast[u8](divisor >> 8))
}

// Stop the calling CPU for good, with interrupts disabled. NMIs still wake it, so it halts again.
halt :: fn() #never_returns {
    loop {
        x86_64.cli()
        x86_64.hlt()
    }
}

/*
 * Wait for an interrupt with interrupts enabled. sti takes effect after the next instruction, so
 * no interrupt can slip in between it and hlt. The interrupt enters the kernel on the kernel
 * stack, which holds nothing while idle, so this never returns.
 */
idle :: fn() #never_returns {
    loop {
        x86_64.sti()
        x86_64.hlt()
    }
}

spin_hint :: fn() {
    x86_64.pause()
}

mask_interrupts :: fn() {
    x86_64.cli()
}

unmask_interrupts :: fn() {
    x86_64.sti()
}

// A value from RDSEED, or null if the CPU has none or it had nothing ready.
hardware_entropy :: fn() -> u64? {
    features :: detect_features()
    if !has(&features, .X86Rdseed) {
        return null
    }
    return x86_64.rdseed()
}

// I/O ports (decisions/0093), which x86-64 has.
has_io_ports :: fn() -> bool {
    return true
}

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
