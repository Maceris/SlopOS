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
/** UARTDR's offset: the data register; writing its low byte transmits it. */
UART_DATA : u64 : 0x00
/** UARTFR's offset: the flag register. */
UART_FLAGS : u64 : 0x18
/** UARTIBRD's offset: the integer part of the baud rate divisor. */
UART_INTEGER_BAUD : u64 : 0x24
/** UARTFBRD's offset: the fractional part of the baud rate divisor, in 64ths. */
UART_FRACTIONAL_BAUD : u64 : 0x28
/** UARTLCR_H's offset: the line control register. */
UART_LINE_CONTROL : u64 : 0x2c
/** UARTCR's offset: the control register. */
UART_CONTROL : u64 : 0x30
/** UARTIMSC's offset: the interrupt mask set/clear register; 0 masks every interrupt. */
UART_INTERRUPT_MASK : u64 : 0x38
/** UARTFR.TXFF (bit 5): the transmit FIFO is full. */
FLAGS_TRANSMIT_FULL : u32 : 1 << 5
/** UARTLCR_H with WLEN 0b11 (8 data bits) and FEN (FIFOs on); no parity, one stop bit. */
LINE_CONTROL_8N1_FIFO : u32 : 0x70
/** UARTCR with UARTEN (bit 0) and TXE (bit 8): the UART and its transmitter on. */
CONTROL_ENABLE_TRANSMIT : u32 : 0x101
// 115200 baud from QEMU's 24 MHz reference clock: 13 and 1/64ths of 1
/** The baud rate divisor's integer part for 115200 baud from a 24 MHz reference clock. */
BAUD_INTEGER : u32 : 13
/** The baud rate divisor's fractional part, in 64ths, for 115200 baud from a 24 MHz reference clock. */
BAUD_FRACTION : u32 : 1

// Semihosting's SYS_EXIT, and what its parameter block says (ADP_Stopped_ApplicationExit)
/** Semihosting's SYS_EXIT operation number. */
SEMIHOSTING_EXIT : u64 : 0x18
/** ADP_Stopped_ApplicationExit, the reason SYS_EXIT's parameter block gives: the application exited. */
APPLICATION_EXIT : u64 : 0x20026

/**
 * Find the UART in the device tree, map it and set it up (arch_interface.early_console_init): 115200 baud, 8N1,
 * FIFOs on, no interrupts.
 *
 * Without a direct map, a device tree with one, or room for the mapping in the bootloader's tables, there's no early
 * console, and writes go nowhere. With one, TPIDR_EL1 holds its registers' address with bit 0 set until init_cpu.
 * Called once, by L0, at EL1, on the bootloader's page tables.
 *
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map; 0 means there's none.
 * @param firmware The firmware's tables, which say where the device tree is.
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

/**
 * Write text to the early console (arch_interface.early_console_write), spinning while the transmit FIFO is full.
 *
 * Nothing is written without a console. Not locked: text from two CPUs at once may interleave.
 *
 * @param text The bytes to write; each line feed is preceded by a carriage return, as a terminal needs.
 */
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

/**
 * Find the console's registers from TPIDR_EL1: the address itself with bit 0 set before init_cpu, or the ArchCpu's
 * console after.
 *
 * @return The registers' virtual address through the direct map, or 0 without a console.
 */
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

/**
 * Write one byte to the UART, once the transmit FIFO has room, spinning without a timeout until it does.
 *
 * @param base The UART's registers' virtual address.
 * @param byte The byte to transmit.
 */
write_byte :: fn(base: u64, byte: u8) {
    loop {
        aarch64.dmb(.SY)
    }
    while read_register(base, UART_FLAGS) & FLAGS_TRANSMIT_FULL != 0
    write_register(base, UART_DATA, cast[u32](byte))
}

/**
 * Read a 32-bit UART register, volatile.
 *
 * @param base The UART's registers' virtual address.
 * @param offset The register's offset in bytes.
 * @return The 32 bits the register reads as now (such as UART_FLAGS' busy and full bits); each call loads afresh, so a
 *     polling loop sees changes.
 */
read_register :: fn(base: u64, offset: u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

/**
 * Write a 32-bit UART register, volatile.
 *
 * @param base The UART's registers' virtual address.
 * @param offset The register's offset in bytes.
 * @param value What to write.
 */
write_register :: fn(base: u64, offset: u64, value: u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

/**
 * Ask QEMU to exit with a code, through semihosting's SYS_EXIT (arch_interface.test_exit), which tools/boot.py
 * turns on.
 *
 * QEMU exits with (code << 1) | 1, as x86-64's debug exit device makes it, so an even code is still QEMU's own.
 * Only called when the command line asks for it (test_exit).
 *
 * @param code The test's result, below 2^31 so the shifted code fits.
 */
test_exit :: fn(code: u32) {
    block : u64[2] = u64.[APPLICATION_EXIT, (cast[u64](code) << 1) | 1]
    aarch64.semihosting(SEMIHOSTING_EXIT, cast[rawptr](&block))
}

/** PSCI's SYSTEM_OFF function ID, an SMC32 fast call. */
PSCI_SYSTEM_OFF : u64 : 0x84000008
/** PSCI's SYSTEM_RESET function ID, an SMC32 fast call. */
PSCI_SYSTEM_RESET : u64 : 0x84000009

/**
 * Find how the machine resets: by PSCI, through the conduit the device tree's psci node names.
 *
 * @param firmware The firmware's tables, which say where the device tree is.
 * @param direct_map_offset Where physical address 0 is in the direct map; 0 means there's none.
 * @return 2 for SMC, if the node's method lists "smc"; 1 for HVC, for any other method; 0 without a direct map, a
 *     device tree, a PSCI 1.0 or 0.2 node, or its method.
 */
reset_method :: fn(firmware: ptr[boot_info.FirmwareTables], direct_map_offset: u64) -> u8 {
    if direct_map_offset == 0 {
        return 0
    }
    tree := devicetree.open(devicetree_address(firmware, direct_map_offset)) or_return 0
    psci := devicetree.find_compatible(&tree, "arm,psci-1.0")
    if psci is_none {
        psci = devicetree.find_compatible(&tree, "arm,psci-0.2")
    }
    node := psci or_return 0
    method :: devicetree.property(&tree, &node, "method") or_return 0
    return if devicetree.lists(method, "smc") { 2 } else { 1 }
}

/**
 * Reset the machine by PSCI's SYSTEM_RESET, which keeps RAM on QEMU.
 *
 * @param method The conduit, as reset_method gives it: 1 for HVC, 2 for SMC; any other value does nothing. Returns
 *     only if the reset didn't happen.
 */
reset :: fn(method: u8) {
    if method == 1 {
        _ = aarch64.hvc(PSCI_SYSTEM_RESET)
    }
    if method == 2 {
        _ = aarch64.smc(PSCI_SYSTEM_RESET)
    }
}

/**
 * Tell whether power_off can turn the machine off by itself.
 *
 * @param method The conduit, as reset_method gives it.
 * @return True for HVC or SMC (1 or 2): PSCI turns it off; false without PSCI.
 */
can_power_off :: fn(method: u8) -> bool {
    return method == 1 || method == 2
}

/**
 * Turn the machine off by PSCI's SYSTEM_OFF.
 *
 * @param method The conduit, as reset_method gives it: 1 for HVC, 2 for SMC; any other value does nothing. Returns
 *     only if the machine didn't turn off.
 */
power_off :: fn(method: u8) {
    if method == 1 {
        _ = aarch64.hvc(PSCI_SYSTEM_OFF)
    }
    if method == 2 {
        _ = aarch64.smc(PSCI_SYSTEM_OFF)
    }
}

/**
 * Tell whether the calling CPU takes interrupts now.
 *
 * @return True if DAIF's I bit (IRQs) is clear and the priority mask lets every interrupt through; FIQs aren't looked
 *     at. The kernel's mask, which lets only the pseudo-NMI through, is taken as interrupts off.
 */
interrupts_enabled :: fn() -> bool {
    return aarch64.read_system_register(.DAIF) & 0x80 == 0 && aarch64.read_system_register(.ICC_PMR_EL1) == PRIORITY_MASK
}

/** Stop the calling CPU for good, with IRQs, FIQs and SErrors masked, waiting for interrupts forever. */
halt :: fn() #never_returns {
    loop {
        aarch64.daif_set(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ | aarch64.DAIF_SERROR)
        aarch64.wfi()
    }
}

/** Hint to the CPU that the caller is spinning (arch_interface.spin_hint). */
spin_hint :: fn() {
    intrinsics.spin_hint()
}

/**
 * Stop the calling CPU taking interrupts but the pseudo-NMI (arch_interface.mask_interrupts): the priority mask at
 * KERNEL_PRIORITY_MASK, DAIF as it is.
 */
mask_interrupts :: fn() {
    aarch64.write_system_register(.ICC_PMR_EL1, KERNEL_PRIORITY_MASK)
    aarch64.isb()
}

/**
 * Let the calling CPU take every interrupt again (arch_interface.unmask_interrupts): the priority mask at PRIORITY_MASK,
 * and DAIF's I and F clear.
 */
unmask_interrupts :: fn() {
    aarch64.write_system_register(.ICC_PMR_EL1, PRIORITY_MASK)
    aarch64.isb()
    aarch64.daif_clear(aarch64.DAIF_IRQ | aarch64.DAIF_FIQ)
}

/**
 * Read one value from the CPU's random source (arch_interface.hardware_entropy): RNDRRS, which reseeds from the
 * CPU's entropy source first.
 *
 * @return 64 random bits; null if the CPU has no FEAT_RNG, or RNDRRS had nothing ready.
 */
hardware_entropy :: fn() -> u64? {
    features :: detect_features()
    if !has(&features, .Aarch64Rng) {
        return null
    }
    return aarch64.rndrrs()
}

/**
 * Wait for an interrupt with interrupts unmasked, on the kernel stack's top (arch_interface.idle).
 *
 * An eret to idle_wait at EL1 with SP_EL1 at the top, so the interrupt enters on a kernel stack holding nothing, as
 * kernel_entry.interrupt from Idle; this never returns.
 */
idle :: fn() #never_returns {
    cpu :: current_cpu()
    frame : aarch64.RegisterFrame
    frame.elr = cast[u64](idle_wait)
    frame.spsr = SPSR_EL1H | SPSR_PAN
    // The kernel's key, with pointer authentication on from the first idle
    key :: current_system().kernel_key
    if has_pointer_authentication() {
        // APIAKeyLo_EL1 and APIAKeyHi_EL1 (S3_0_C2_C1_0 and S3_0_C2_C1_1), then SCTLR_EL1.EnIA, here, where no frame below returns
        aarch64.write_system_register_encoded(3, 0, 2, 1, 0, key[0])
        aarch64.write_system_register_encoded(3, 0, 2, 1, 1, key[1])
        aarch64.write_system_register(.SCTLR_EL1, aarch64.read_system_register(.SCTLR_EL1) | SCTLR_ENABLE_IA)
        aarch64.isb()
    }
    // The kernel's Guarded Control Stack from its top, as SP_EL1 is, and on (decisions/0186, Hd): GCSPR_EL1 (S3_0_C2_C5_1), GCSCR_EL1 (S3_0_C2_C5_0)
    if cpu.kernel_shadow_top != 0 {
        aarch64.write_system_register_encoded(3, 0, 2, 5, 1, cpu.kernel_shadow_top)
        aarch64.write_system_register_encoded(3, 0, 2, 5, 0, GCSCR_ON)
        aarch64.isb()
    }
    unmask_for_return()
    aarch64.return_to_user(&frame, cast[rawptr](cpu.kernel_stack_top))
}

// SPSR_EL1: EL1 on SP_EL1 (EL1h) with DAIF clear, and PAN on.
/** SPSR_EL1.M for EL1h: EL1 on SP_EL1, with DAIF clear, so interrupts are unmasked. */
SPSR_EL1H : u64 : 0b0101
/** SPSR_EL1.PAN (bit 22): Privileged Access Never stays on. */
SPSR_PAN : u64 : 1 << 22

/** Wait where idle sends the CPU: no stack, no carrier block, no context, just wfi with interrupts unmasked. */
idle_wait #calling_convention(.c) #no_context :: fn() #never_returns {
    loop {
        aarch64.wfi()
    }
}

/**
 * Tell whether the architecture has I/O ports (arch_interface.has_io_ports).
 *
 * @return False: AArch64's devices are all memory (decisions/0093).
 */
has_io_ports :: fn() -> bool {
    return false
}

/**
 * Read an I/O port (arch_interface.port_read), which AArch64 doesn't have.
 *
 * @param port Ignored.
 * @param width Ignored.
 * @return Null, always.
 */
port_read :: fn(port: u16, width: u32) -> u32? {
    return null
}

/**
 * Write an I/O port (arch_interface.port_write), which AArch64 doesn't have.
 *
 * @param port Ignored.
 * @param width Ignored.
 * @param value Ignored.
 * @return False, always.
 */
port_write :: fn(port: u16, width: u32, value: u32) -> bool {
    return false
}
