package arch_aarch64

import intrinsics from "base"
import aarch64 from "base/intrinsics"
import arch_interface from "../../arch_interface"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"

/*
 * The early console: the device tree's first PL011 UART, through the direct map. Its registers aren't in
 * the bootloader's direct map, which only covers memory, so early_console_init maps them there in the
 * bootloader's tables, as a Device block in the first gap the walk finds, and init_kernel_page_table maps
 * them again in the kernel's own table, at the same address (paging.hsc).
 *
 * L1 keeps no global state, so where the registers are is in TPIDR_EL1: until init_cpu, the address itself
 * with bit 0 set; after, in the ArchCpu it points at, which is 64-byte aligned.
 */
//SPEC: Arm PrimeCell UART (PL011) TRM (DDI 0183): UARTDR, UARTFR, UARTIBRD/FBRD, UARTLCR_H, UARTCR
UART_DATA : u64 : 0x00
UART_FLAGS : u64 : 0x18
UART_INTEGER_BAUD : u64 : 0x24
UART_FRACTIONAL_BAUD : u64 : 0x28
UART_LINE_CONTROL : u64 : 0x2c
UART_CONTROL : u64 : 0x30
UART_INTERRUPT_MASK : u64 : 0x38
// The transmit FIFO is full
FLAGS_TRANSMIT_FULL : u32 : 1 << 5
// 8 data bits, FIFOs on
LINE_CONTROL_8N1_FIFO : u32 : 0x70
// The UART and its transmitter on
CONTROL_ENABLE_TRANSMIT : u32 : 0x101
// 115200 baud from QEMU's 24 MHz reference clock: 13 and 1/64ths of 1
BAUD_INTEGER : u32 : 13
BAUD_FRACTION : u32 : 1

// Semihosting's SYS_EXIT, and what its parameter block says (ADP_Stopped_ApplicationExit)
SEMIHOSTING_EXIT : u64 : 0x18
APPLICATION_EXIT : u64 : 0x20026

/*
 * Find the UART in the device tree, map it and set it up: 115200 baud, 8N1, FIFOs on, no interrupts. Without
 * a direct map, a device tree with one, or room for the mapping in the bootloader's tables, there's no early
 * console, and writes go nowhere.
 */
early_console_init :: fn(direct_map_offset: u64, firmware: ptr[boot_info.FirmwareTables]) {
    if direct_map_offset == 0 {
        return void
    }
    tree := devicetree.open(devicetree_address(firmware, direct_map_offset)) or_return void
    node := devicetree.find_compatible(&tree, "arm,pl011") or_return void
    registers :: (devicetree.reg(&tree, &node, 0) or_return void).address
    if !map_early_device(direct_map_offset, registers) {
        return void
    }
    base :: direct_map_offset + registers
    aarch64.write_system_register(.TPIDR_EL1, base | 1)
    write_register(base, UART_CONTROL, 0)
    write_register(base, UART_INTERRUPT_MASK, 0)
    write_register(base, UART_INTEGER_BAUD, BAUD_INTEGER)
    write_register(base, UART_FRACTIONAL_BAUD, BAUD_FRACTION)
    write_register(base, UART_LINE_CONTROL, LINE_CONTROL_8N1_FIFO)
    write_register(base, UART_CONTROL, CONTROL_ENABLE_TRANSMIT)
}

early_console_write :: fn(text: string) {
    base :: console_address()
    if base == 0 {
        return void
    }
    for character in text {
        // A terminal needs a carriage return before each line feed
        if character == '\n' {
            write_byte(base, cast[u8]('\r'))
        }
        write_byte(base, cast[u8](character))
    }
}

// Where the console's registers are, from TPIDR_EL1, or 0 without one.
console_address :: fn() -> u64 {
    value :: aarch64.read_system_register(.TPIDR_EL1)
    if value & 1 != 0 {
        return value & ~cast[u64](1)
    }
    if value == 0 {
        return 0
    }
    return cast[ptr[ArchCpu]](value).console
}

write_byte :: fn(base: u64, byte: u8) {
    loop {
        aarch64.dmb(.SY)
    }
    while read_register(base, UART_FLAGS) & FLAGS_TRANSMIT_FULL != 0
    write_register(base, UART_DATA, cast[u32](byte))
}

read_register :: fn(base: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

write_register :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

/*
 * QEMU's semihosting, which tools/boot.py turns on: SYS_EXIT ends QEMU with (code << 1) | 1, as x86-64's debug
 * exit device does, so an even code is still QEMU's own.
 */
test_exit :: fn(code: u32) {
    block : u64[2] = u64.[APPLICATION_EXIT, (cast[u64](code) << 1) | 1]
    aarch64.semihosting(SEMIHOSTING_EXIT, cast[rawptr](&block))
}

// Stop the calling CPU for good, with interrupts masked.
halt :: fn() #never_returns {
    loop {
        aarch64.daif_set(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ | aarch64.DAIF_SERROR)
        aarch64.wfi()
    }
}

spin_hint :: fn() {
    intrinsics.spin_hint()
}

mask_interrupts :: fn() {
    aarch64.daif_set(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ)
}

unmask_interrupts :: fn() {
    aarch64.daif_clear(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ)
}

// A value from RNDRRS, which reseeds from the CPU's entropy source first, or null if it has none or had nothing ready.
hardware_entropy :: fn() -> u64? {
    features :: detect_features()
    if !has(&features, .Aarch64Rng) {
        return null
    }
    return aarch64.rndrrs()
}

/*
 * Wait for an interrupt with interrupts unmasked, on the kernel stack's top: an eret to idle_wait at EL1 with
 * SP_EL1 there, so the interrupt enters on a kernel stack holding nothing, and this never returns.
 */
idle :: fn() #never_returns {
    cpu :: current_cpu()
    frame : aarch64.RegisterFrame
    frame.elr = cast[u64](idle_wait)
    frame.spsr = SPSR_EL1H | SPSR_PAN
    aarch64.return_to_user(&frame, cast[rawptr](cpu.kernel_stack_top))
}

// SPSR_EL1: EL1 on SP_EL1 (EL1h) with DAIF clear, and PAN on.
SPSR_EL1H : u64 : 0b0101
SPSR_PAN : u64 : 1 << 22

// Where idle waits: no stack, no carrier block, no context, just wfi with interrupts unmasked.
idle_wait #calling_convention(.c) #no_context :: fn() #never_returns {
    loop {
        aarch64.wfi()
    }
}

// AArch64 has no I/O ports: its devices are all memory (decisions/0093).
has_io_ports :: fn() -> bool {
    return false
}

port_read :: fn(port: u16, width: u32) -> u32? {
    return null
}

port_write :: fn(port: u16, width: u32, value: u32) -> bool {
    return false
}
