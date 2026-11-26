package arch_riscv64

import intrinsics from "base:intrinsics"
import riscv64 from "base:intrinsics/riscv64"
import boot_info from "../../boot_info"
import devicetree from "../../devicetree"

/*
 * The early console: the device tree's first 16550 UART ("ns16550a", or "ns16550"), through the direct map. Its
 * registers aren't in the bootloader's direct map, which only covers memory, so early_console_init maps them there in
 * the bootloader's tables, as an I/O page in the first gap the walk finds, and init_kernel_page_table maps them again
 * in the kernel's own table, at the same address (paging.hsc).
 *
 * L1 keeps no global state, so where the registers are is in tp: until init_cpu, the console's word itself, which is
 * odd; after, in the ArchCpu it points at, which is 64-byte aligned. The word is the registers' address, 16-byte
 * aligned, with bit 0 set, the registers' shift in bits 1 and 2 (reg-shift: each register is 1 << shift bytes from
 * the last), and bit 3 set for 32-bit accesses (reg-io-width 4) rather than bytes.
 */
// SPEC: National Semiconductor PC16550D datasheet: THR, IER, FCR, LCR, MCR, LSR, and the divisor latch
/** THR's register number: the transmit holding register; writing it transmits a byte. With LCR.DLAB, DLL. */
UART_DATA : u64 : 0
/** IER's register number: which interrupts are on; 0 for none. With LCR.DLAB, DLM. */
UART_INTERRUPT_ENABLE : u64 : 1
/** FCR's register number: the FIFO control register. */
UART_FIFO_CONTROL : u64 : 2
/** LCR's register number: the line control register. */
UART_LINE_CONTROL : u64 : 3
/** MCR's register number: the modem control register. */
UART_MODEM_CONTROL : u64 : 4
/** LSR's register number: the line status register. */
UART_LINE_STATUS : u64 : 5
/** LCR.DLAB (bit 7): registers 0 and 1 are the divisor latch while it's set. */
LINE_CONTROL_DIVISOR : u32 : 0x80
/** LCR with 8 data bits, no parity and one stop bit. */
LINE_CONTROL_8N1 : u32 : 0x03
/** FCR with the FIFOs on and both cleared. */
FIFO_ON_AND_CLEARED : u32 : 0x07
/** MCR with DTR and RTS set. */
MODEM_DTR_RTS : u32 : 0x03
/** LSR.THRE (bit 5): the transmit holding register is empty, so another byte can be written. */
STATUS_TRANSMIT_EMPTY : u32 : 1 << 5
/** The console's speed: 115200 baud. */
BAUD : u64 : 115200

// Semihosting's SYS_EXIT, and what its parameter block says (ADP_Stopped_ApplicationExit)
/** Semihosting's SYS_EXIT operation number. */
SEMIHOSTING_EXIT : u64 : 0x18
/** ADP_Stopped_ApplicationExit, the reason SYS_EXIT's parameter block gives: the application exited. */
APPLICATION_EXIT : u64 : 0x20026

/**
 * Find the UART in the device tree, map it and set it up (arch_interface.early_console_init): 115200 baud from its
 * clock-frequency, 8N1, FIFOs on, no interrupts.
 *
 * tp is 0 from here, whatever the bootloader left in it, until there's a console. Without a direct map, a device tree
 * with a 16550, room for the mapping in the bootloader's tables, or registers 16-byte aligned, there's no early
 * console, and writes go nowhere. With one, tp holds its word until init_cpu. Without a clock-frequency, the speed is
 * left as the firmware set it. Called once, by L0, in supervisor mode, on the bootloader's page tables.
 *
 * @param direct_map_offset Where physical address 0 is in the bootloader's direct map; 0 means there's none.
 * @param firmware The firmware's tables, which say where the device tree is.
 */
early_console_init :: fn(direct_map_offset : u64, firmware : ptr[boot_info.FirmwareTables]) {
    riscv64.write_tp(null)
    if direct_map_offset == 0 {
        return void
    }
    tree := devicetree.open(devicetree_address(firmware, direct_map_offset)) or_return void
    found := devicetree.find_compatible(&tree, "ns16550a")
    if found is_none {
        found = devicetree.find_compatible(&tree, "ns16550")
    }
    node := found or_return void
    registers :: (devicetree.reg(&tree, &node, 0) or_return void).address
    shift :: cell_property(&tree, &node, "reg-shift", 0)
    wide :: cell_property(&tree, &node, "reg-io-width", 1) == 4
    if registers & 15 != 0 || shift > 3 || !map_early_device(direct_map_offset, registers) {
        return void
    }
    word :: (direct_map_offset + registers) | 1 | (cast[u64](shift) << 1) | (if wide { cast[u64](8) } else { 0 })
    riscv64.write_tp(cast[rawptr](word))
    write_register(word, UART_INTERRUPT_ENABLE, 0)
    clock :: cell_property(&tree, &node, "clock-frequency", 0)
    divisor :: cast[u64](clock) / (16 * BAUD)
    if divisor > 0 && divisor <= 0xffff {
        write_register(word, UART_LINE_CONTROL, LINE_CONTROL_DIVISOR)
        write_register(word, UART_DATA, cast[u32](divisor & 0xff))
        write_register(word, UART_INTERRUPT_ENABLE, cast[u32](divisor >> 8))
    }
    write_register(word, UART_LINE_CONTROL, LINE_CONTROL_8N1)
    write_register(word, UART_FIFO_CONTROL, FIFO_ON_AND_CLEARED)
    write_register(word, UART_MODEM_CONTROL, MODEM_DTR_RTS)
}

/**
 * Read a node's property of one cell.
 *
 * @param tree The tree node is in.
 * @param node The node.
 * @param name The property's name, like "reg-shift".
 * @param default What to give without it.
 * @return The property's first cell; default if the node hasn't it, or it has no cell.
 */
cell_property :: fn(tree : ptr[devicetree.Tree], node : ptr[devicetree.Node], name : string, default : u32) -> u32 {
    value :: devicetree.property(tree, node, name) or_return default
    return devicetree.cell(value, 0) or_else default
}

/**
 * Write text to the early console (arch_interface.early_console_write), spinning while the transmitter is full.
 *
 * Nothing is written without a console. Not locked: text from two harts at once may interleave.
 *
 * @param text The bytes to write; each line feed is preceded by a carriage return, as a terminal needs.
 */
early_console_write :: fn(text : string) {
    word :: console_word()
    if word == 0 {
        return void
    }
    for character in text {
        // A terminal needs a carriage return before each line feed
        if character == '\n' {
            write_byte(word, cast[u8]('\r'))
        }
        write_byte(word, cast[u8](character))
    }
}

/**
 * Find the console's word from tp: the word itself, which is odd, before init_cpu, or the ArchCpu's console after.
 *
 * @return The console's word, its registers' address through the direct map with what's packed in its low bits, or 0
 *     without a console.
 */
console_word :: fn() -> u64 {
    value :: cast[u64](riscv64.read_tp())
    if value & 1 != 0 {
        return value
    }
    if value == 0 {
        return 0
    }
    return cast[ptr[ArchCpu]](value).console
}

/**
 * Take a console's word apart for its registers' address.
 *
 * @param word The console's word, not 0.
 * @return The registers' virtual address through the direct map.
 */
console_base :: fn(word : u64) -> u64 {
    return word & ~cast[u64](15)
}

/**
 * Write one byte to the UART, once its transmitter has room, spinning without a timeout until it does.
 *
 * @param word The console's word.
 * @param byte The byte to transmit.
 */
write_byte :: fn(word : u64, byte : u8) {
    loop {
        riscv64.pause()
    }
    while read_register(word, UART_LINE_STATUS) & STATUS_TRANSMIT_EMPTY == 0
    write_register(word, UART_DATA, cast[u32](byte))
}

/**
 * Read a UART register, volatile, a byte or 32 bits as the word says.
 *
 * @param word The console's word.
 * @param register The register's number, which the word's shift spaces out.
 * @return The register's value, zero-extended; each call loads afresh, so a polling loop sees changes.
 */
read_register :: fn(word : u64, register : u64) -> u32 {
    address :: console_base(word) + (register << ((word >> 1) & 3))
    if word & 8 != 0 {
        return intrinsics.volatile_load_u32(cast[ptr[u32]](address))
    }
    return cast[u32](intrinsics.volatile_load_u8(cast[ptr[u8]](address)))
}

/**
 * Write a UART register, volatile, a byte or 32 bits as the word says.
 *
 * @param word The console's word.
 * @param register The register's number, which the word's shift spaces out.
 * @param value What to write; for a byte register, its low 8 bits.
 */
write_register :: fn(word : u64, register : u64, value : u32) {
    address :: console_base(word) + (register << ((word >> 1) & 3))
    if word & 8 != 0 {
        intrinsics.volatile_store_u32(cast[ptr[mut u32]](address), value)
    }
    else {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](address), cast[u8](value))
    }
}

/**
 * Ask QEMU to exit with a code, through semihosting's SYS_EXIT (arch_interface.test_exit), which tools/boot.py turns
 * on.
 *
 * QEMU exits with (code << 1) | 1, as x86-64's debug exit device makes it, so an even code is still QEMU's own. Only
 * called when the command line asks for it (test_exit).
 *
 * @param code The test's result, below 2^31 so the shifted code fits.
 */
test_exit :: fn(code : u32) {
    block : u64[2] = u64.[APPLICATION_EXIT, (cast[u64](code) << 1) | 1]
    _ = riscv64.semihosting(SEMIHOSTING_EXIT, cast[rawptr](&block))
}

/*
 * The SBI's base extension, for probing, and its system reset extension.
 * SPEC: RISC-V Supervisor Binary Interface Specification 2.0, §4 (the base extension), §10 (system reset, SRST)
 */
/** The SBI base extension's ID. */
SBI_BASE : u64 : 0x10
/** The base extension's sbi_probe_extension function: whether an extension is there. */
SBI_PROBE_EXTENSION : u64 : 3
/** The system reset extension's ID, "SRST". */
SBI_SYSTEM_RESET : u64 : 0x53525354
/** SRST's sbi_system_reset function. */
SBI_SYSTEM_RESET_FUNCTION : u64 : 0
/** sbi_system_reset's type: shut down. */
RESET_SHUTDOWN : u64 : 0
/** sbi_system_reset's type: a warm reboot, which keeps RAM where the platform does. */
RESET_WARM_REBOOT : u64 : 2
/** reset_method's method: the SBI's system reset. */
METHOD_SBI : u8 : 1

/**
 * Find how the machine resets (arch_interface.reset_method): by the SBI's system reset, if the firmware has it.
 *
 * @param firmware Unused: the SBI is asked.
 * @param direct_map_offset Unused.
 * @return METHOD_SBI if sbi_probe_extension finds SRST; 0 without it.
 */
reset_method :: fn(firmware : ptr[boot_info.FirmwareTables], direct_map_offset : u64) -> u8 {
    probed :: riscv64.sbi_call(SBI_BASE, SBI_PROBE_EXTENSION, SBI_SYSTEM_RESET)
    return if probed.error == 0 && probed.value != 0 { METHOD_SBI } else { 0 }
}

/**
 * Reset the machine with a warm reboot, by the SBI's system reset (arch_interface.reset), which keeps RAM on QEMU.
 *
 * @param method As reset_method gives it: METHOD_SBI; any other value does nothing. Returns only if the reset didn't
 *     happen.
 */
reset :: fn(method : u8) {
    if method == METHOD_SBI {
        _ = riscv64.sbi_call(SBI_SYSTEM_RESET, SBI_SYSTEM_RESET_FUNCTION, RESET_WARM_REBOOT, 0)
    }
}

/**
 * Tell whether power_off can turn the machine off by itself (arch_interface.can_power_off).
 *
 * @param method As reset_method gives it.
 * @return True for METHOD_SBI, the SBI's system reset turning it off; false without it.
 */
can_power_off :: fn(method : u8) -> bool {
    return method == METHOD_SBI
}

/**
 * Turn the machine off by the SBI's system reset (arch_interface.power_off).
 *
 * @param method As reset_method gives it: METHOD_SBI; any other value does nothing. Returns only if the machine didn't
 *     turn off.
 */
power_off :: fn(method : u8) {
    if method == METHOD_SBI {
        _ = riscv64.sbi_call(SBI_SYSTEM_RESET, SBI_SYSTEM_RESET_FUNCTION, RESET_SHUTDOWN, 0)
    }
}

/**
 * Tell whether the calling hart takes interrupts now.
 *
 * @return True if sstatus.SIE is set.
 */
interrupts_enabled :: fn() -> bool {
    return riscv64.csrr(.SSTATUS) & riscv64.SSTATUS_SIE != 0
}

/** Stop the calling hart for good (arch_interface.halt): interrupts off, waiting for interrupts forever. */
halt :: fn() #never_returns {
    loop {
        _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_SIE)
        riscv64.wfi()
    }
}

/** Hint to the hart that the caller is spinning (arch_interface.spin_hint): Zihintpause's pause. */
spin_hint :: fn() {
    riscv64.pause()
}

/** Stop the calling hart taking interrupts (arch_interface.mask_interrupts): sstatus.SIE clear. */
mask_interrupts :: fn() {
    _ = riscv64.csrrc(.SSTATUS, riscv64.SSTATUS_SIE)
}

/** Let the calling hart take interrupts again (arch_interface.unmask_interrupts): sstatus.SIE set. */
unmask_interrupts :: fn() {
    _ = riscv64.csrrs(.SSTATUS, riscv64.SSTATUS_SIE)
}

/**
 * Tell whether an interrupt is waiting (arch_interface.interrupt_pending), interrupts staying as they are.
 *
 * @return True if an interrupt sie enables is pending in sip.
 */
interrupt_pending :: fn() -> bool {
    return riscv64.csrr(.SIP) & riscv64.csrr(.SIE) != 0
}

/** How many times hardware_entropy reads seed for one 16-bit piece before it gives up. */
SEED_TRIES :: 1024

/**
 * Read 64 bits from the hart's entropy source (arch_interface.hardware_entropy): Zkr's seed, 16 bits at a time.
 *
 * @return 64 random bits; null before init_cpu, which is when the harts' features are known, or if they have no Zkr,
 *     the source is dead, or it had nothing ready in SEED_TRIES reads for a piece.
 */
hardware_entropy :: fn() -> u64? {
    // tp is the ArchCpu only once init_cpu has run: before, it's 0 or the console's word, which is odd
    here :: cast[u64](riscv64.read_tp())
    if here == 0 || here & 1 != 0 || !has(&current_system().features, .RiscvZkr) {
        return null
    }
    value := cast[u64](0)
    for piece in 0..<4 {
        found := false
        for try in 0..<SEED_TRIES {
            read :: riscv64.seed()
            state :: read & riscv64.SEED_DEAD
            if state == riscv64.SEED_DEAD {
                return null
            }
            if state == riscv64.SEED_ES16 {
                value = (value << 16) | (read & 0xffff)
                found = true
                break
            }
        }
        if !found {
            return null
        }
    }
    return value
}

/**
 * Read the calling hart's counter (arch_interface.counter): the time CSR, which every hart shares.
 *
 * @return The time, in ticks at the device tree's timebase-frequency; it only grows.
 */
counter :: fn() -> u64 {
    return riscv64.csrr(.TIME)
}

/**
 * Send another hart an NMI (arch_interface.send_nmi): RISC-V's supervisor has none to send.
 *
 * @param cpu_hardware_id Unused.
 * @return False, always.
 */
send_nmi :: fn(cpu_hardware_id : u64) -> bool {
    return false
}

/**
 * Name a register of those the NMI entry passes kernel_entry.nmi (arch_interface.nmi_register_name): there's no NMI,
 * so no registers.
 *
 * @param index Unused.
 * @return "?", every index being past them.
 */
nmi_register_name :: fn(index : usize) -> string {
    return "?"
}

/**
 * Tell whether the architecture has I/O ports (arch_interface.has_io_ports).
 *
 * @return False: RISC-V's devices are all memory (decisions/0093).
 */
has_io_ports :: fn() -> bool {
    return false
}

/**
 * Read an I/O port (arch_interface.port_read), which RISC-V doesn't have.
 *
 * @param port Ignored.
 * @param width Ignored.
 * @return Null, always.
 */
port_read :: fn(port : u16, width : u32) -> u32? {
    return null
}

/**
 * Write an I/O port (arch_interface.port_write), which RISC-V doesn't have.
 *
 * @param port Ignored.
 * @param width Ignored.
 * @param value Ignored.
 * @return False, always.
 */
port_write :: fn(port : u16, width : u32, value : u32) -> bool {
    return false
}
