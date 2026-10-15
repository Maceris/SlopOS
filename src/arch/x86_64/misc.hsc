package arch_x86_64

import x86_64 from "base/intrinsics"

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

// Set the early console up: 115200 baud, 8N1, FIFOs on, no interrupts.
early_console_init :: fn() {
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

// A value from RDSEED, or null if the CPU has none or it had nothing ready.
hardware_entropy :: fn() -> u64? {
    features :: detect_features()
    if !has(&features, .X86Rdseed) {
        return null
    }
    return x86_64.rdseed()
}
