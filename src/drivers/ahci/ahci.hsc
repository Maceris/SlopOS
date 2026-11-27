/**
 * The AHCI driver (roadmap 20c, decisions/0201): the first SATA disk behind an AHCI controller as the block protocol
 * for its clients, who arrive on its listener, as virtio-blk's are. The controller is reset and taken from the
 * firmware, each implemented port's link looked at, and the first with an ATA disk on it (not an ATAPI drive, as a CD
 * is) started: its command list and received FISes in the driver's DMA memory, the disk identified, polled. Its
 * interrupts are one MSI.
 *
 * Reads and writes are queued (NCQ, READ and WRITE FPDMA QUEUED) where the controller and the disk both can, up to
 * the disk's queue depth; otherwise they're READ and WRITE DMA EXT, one at a time. A flush, FLUSH CACHE EXT, is never
 * queued, and ATA doesn't let one run beside queued commands: a request that can't be issued with what's in flight
 * waits, in the order asked, and everything after it waits too, so a flush is never passed over for long. Each
 * connection's buffer is DMA memory of its own, made at its first GetBuffer, which the controller reads and writes
 * directly, named by one PRD entry as the domain makes it contiguous to the device. Up to SLOTS requests are in
 * flight or waiting across the clients, each a command slot, answered with its client's tag as the controller
 * completes it; one past that is answered Busy. An error fails what was in flight, DeviceError, and starts the port
 * again.
 *
 * A controller with no ATA disk, as x86-64's q35 has with only its CD, serves a disk of no blocks, which the storage
 * manager passes over. A disk whose logical sectors are larger than block.BLOCK_BYTES serves them as BLOCK_BYTES
 * ones: a transfer has to start and end on one of the disk's, or it's OutOfRange.
 *
 * SPEC: Serial ATA AHCI 1.3.1 (registers §3, the command list and FIS §4, starting a port §10.1.2 and §10.3, errors
 * §6.2.2); ACS-3 (IDENTIFY DEVICE's words, READ and WRITE DMA EXT, READ and WRITE FPDMA QUEUED, FLUSH CACHE EXT).
 */
package ahci

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import driver_kit from "../../driver_kit"
import service_kit from "../../libraries/service_kit"
import pci from "../../pci"
import block from "../../protocols/block"

/** The bytes of a page. */
PAGE : u64 : 4096
/** The bytes of each connection's buffer, 64 KiB, which a transfer's data has to fit. */
BUFFER_BYTES : u64 : 64 * 1024
/** How many requests may be in flight or waiting at once, across every client: 16, fewer if the disk queues fewer. */
SLOTS :: 16
/** The port key the controller's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** The bytes of each slot's command table: its FIS, its ATAPI command, and one PRD entry, 128-byte aligned. */
TABLE_BYTES : u64 : 256

// How long the controller's given, in nanoseconds
/** For a reset, or the firmware to let it go: 1 s, 2 s. */
RESET_WAIT : u64 : 1_000_000_000
HANDOFF_WAIT : u64 : 2_000_000_000
/**
 * For a port to show a device (DET 1 or 3): 10 ms, as a device there answers COMRESET within it; then, for one that
 * does, for its link to come up (DET 3), which a real PHY may take up to a second for.
 */
LINK_WAIT : u64 : 10_000_000
LINK_UP_WAIT : u64 : 1_000_000_000
/** For a disk to be ready, which may be spinning up: 5 s. */
READY_WAIT : u64 : 5_000_000_000
/** For a port's command engine or FIS receive to stop: 500 ms, as §10.1.2 says. */
STOP_WAIT : u64 : 500_000_000
/** For IDENTIFY DEVICE: 1 s. */
IDENTIFY_WAIT : u64 : 1_000_000_000
/** How long COMRESET is held, 2 ms, past §10.4.2's 1. */
COMRESET_HOLD : u64 : 2_000_000

// The controller's registers, from BAR 5 (ABAR) (§3.1)
/** CAP: S64A (bit 31), 64-bit addresses; SNCQ (30), NCQ; SSS (27), staggered spin-up; NCS (12:8), slots less one. */
CAP : u64 : 0x00
CAP_64_BIT : u32 : 1 << 31
CAP_NCQ : u32 : 1 << 30
CAP_STAGGERED : u32 : 1 << 27
/** GHC: AE (bit 31), AHCI mode; IE (1), interrupts; HR (0), reset. */
GHC : u64 : 0x04
GHC_AHCI : u32 : 1 << 31
GHC_INTERRUPTS : u32 : 1 << 1
GHC_RESET : u32 : 1
/** IS: which ports are interrupting, a bit each, cleared by writing it. */
IS : u64 : 0x08
/** PI: which ports are implemented, a bit each. */
PI : u64 : 0x0c
/** CAP2: BOH (bit 0), BIOS handoff. */
CAP2 : u64 : 0x24
/** BOHC: OOS (bit 1), the driver asking for the controller; BOS (bit 0), the firmware still owning it. */
BOHC : u64 : 0x28
BOHC_OS_OWNS : u32 : 1 << 1
BOHC_BIOS_OWNS : u32 : 1

// A port's registers, 0x80 bytes each from 0x100 (§3.3)
PORTS : u64 : 0x100
PORT_BYTES : u64 : 0x80
/** PxCLB and PxCLBU: the command list's address; PxFB and PxFBU, the received FISes'. */
PORT_CLB : u64 : 0x00
PORT_CLBU : u64 : 0x04
PORT_FB : u64 : 0x08
PORT_FBU : u64 : 0x0c
/** PxIS: what the port's interrupting for, cleared by writing it; PxIE, which of those interrupt. */
PORT_IS : u64 : 0x10
PORT_IE : u64 : 0x14
/** PxCMD: ST (bit 0), SUD (1), POD (2), FRE (4), FR (14), CR (15). */
PORT_CMD : u64 : 0x18
CMD_START : u32 : 1
CMD_SPIN_UP : u32 : 1 << 1
CMD_POWER_ON : u32 : 1 << 2
CMD_FIS_RECEIVE : u32 : 1 << 4
CMD_FIS_RUNNING : u32 : 1 << 14
CMD_RUNNING : u32 : 1 << 15
/** PxTFD: the device's status, BSY (bit 7), DRQ (3) and ERR (0). */
PORT_TFD : u64 : 0x20
TFD_BUSY : u32 : 1 << 7
TFD_REQUEST : u32 : 1 << 3
TFD_ERROR : u32 : 1
/** PxSIG: what the device said it is, ATA for a disk. */
PORT_SIG : u64 : 0x24
SIGNATURE_ATA : u32 : 0x00000101
/** PxSSTS: the link, DET (bits 3:0) 3 for a device there and talking; PxSCTL, DET 1 to send COMRESET. */
PORT_SSTS : u64 : 0x28
PORT_SCTL : u64 : 0x2c
DET_PRESENT : u32 : 3
/** PxSERR: the link's errors, cleared by writing them. */
PORT_SERR : u64 : 0x30
/** PxSACT: the queued commands outstanding, a bit each; PxCI, the commands issued and not yet done. */
PORT_SACT : u64 : 0x34
PORT_CI : u64 : 0x38
/** PxIS's bits: a D2H register FIS (0), a PIO setup FIS (1), a DMA setup FIS (2), set device bits (3). */
IS_D2H : u32 : 1
IS_PIO_SETUP : u32 : 1 << 1
IS_DMA_SETUP : u32 : 1 << 2
IS_SET_DEVICE_BITS : u32 : 1 << 3
/** PxIS's errors: task file (30), host bus fatal (29), host bus data (28), interface fatal (27). */
IS_ERRORS : u32 : (1 << 30) | (1 << 29) | (1 << 28) | (1 << 27)
/** What the port interrupts for: every command's end, and every error. */
PORT_INTERRUPTS : u32 : IS_D2H | IS_PIO_SETUP | IS_DMA_SETUP | IS_SET_DEVICE_BITS | IS_ERRORS

// ATA's commands
ATA_IDENTIFY : u8 : 0xec
ATA_READ_DMA_EXT : u8 : 0x25
ATA_WRITE_DMA_EXT : u8 : 0x35
ATA_READ_QUEUED : u8 : 0x60
ATA_WRITE_QUEUED : u8 : 0x61
ATA_FLUSH_EXT : u8 : 0xea
/** The device register for an LBA: bit 6. */
DEVICE_LBA : u8 : 1 << 6
/** A register FIS from the host to the device, and its C bit: a command. */
FIS_HOST_TO_DEVICE : u8 : 0x27
FIS_COMMAND : u8 : 0x80
/** A command header's CFL, the FIS's length in dwords; W (bit 6), the device's written to. */
HEADER_FIS_DWORDS : u32 : 5
HEADER_WRITE : u32 : 1 << 6

/** Where in the driver's DMA memory each thing is: the command list at 0 and the received FISes after it, page 0. */
COMMAND_LIST : u64 : 0
RECEIVED_FIS : u64 : 0x400
/** The page IDENTIFY DEVICE writes into. */
IDENTIFY_PAGE : u64 : 1
/** The page the slots' command tables are in, TABLE_BYTES each. */
TABLES_PAGE : u64 : 2
/** The driver's DMA memory's pages. */
MEMORY_PAGES : u64 : 3

#assert cast[u64](SLOTS) * TABLE_BYTES <= PAGE

/** A command header in the command list (§4.2.2). */
Header :: struct #packed {
    /** DW0: CFL (bits 4:0), W (6), and PRDTL (31:16), the PRD entries. */
    flags : u32le,
    /** PRDBC: the bytes transferred, which the controller writes. */
    transferred : u32le,
    /** CTBA and CTBAU: the command table's address to the controller, 128-byte aligned. */
    table : u64le,
    reserved0 : u64le,
    reserved1 : u64le,
}

#assert size_of(Header) == 32

/** A register FIS from the host to the device (SATA 3.2 §10.5.5). */
Fis :: struct #packed {
    kind : u8,
    /** Bit 7, C: a command, not a control. */
    flags : u8,
    command : u8,
    feature_low : u8,
    lba0 : u8,
    lba1 : u8,
    lba2 : u8,
    device : u8,
    lba3 : u8,
    lba4 : u8,
    lba5 : u8,
    feature_high : u8,
    count_low : u8,
    count_high : u8,
    icc : u8,
    control : u8,
    reserved : u32le,
}

#assert size_of(Fis) == 20

/** A PRD entry (§4.2.3.3): data's address, word aligned, and its bytes, less one, in DBC (bits 21:0). */
Prd :: struct #packed {
    address : u64le,
    reserved : u32le,
    count : u32le,
}

#assert size_of(Prd) == 16

/** A command table (§4.2.3): the FIS, the ATAPI command, and from 0x80 the PRD entries, here one. */
CommandTable :: struct #packed {
    fis : Fis,
    /** The rest of the FIS's 64 bytes, the ATAPI command's 16, and 48 reserved. */
    padding : u8[108],
    prd : Prd,
}

#assert size_of(CommandTable) == 0x90

/** A request, in flight or waiting: whose, its tag, and how it's issued. */
Slot :: struct {
    /** Whether the slot holds a request, in flight or waiting. */
    used : bool,
    /** Whether it's been issued to the controller, or waits. */
    issued : bool,
    /** Whether it's a queued command (NCQ), which waits while one that isn't is in flight, and makes one wait. */
    queued : bool,
    /** When it was asked, counted, so what waits is issued in order. */
    sequence : u64,
    /** The client that asked, by its index. */
    client : usize,
    /** The client's tag, given back in its Finished. */
    tag : u64,
    /** The client's place's generation when it was asked, so it's answered only if the same client's still there. */
    generation : u32,
    /** The buffer the controller reads or writes for it, kept until it's done though its client goes. */
    memory : slop_os.Memory,
}

/** A connection's buffer, once it has one: the memory, and where it is to the controller. */
Buffer :: struct {
    /** The buffer's DMA memory, BUFFER_BYTES of it, the driver's; NO_HANDLE before the first GetBuffer. */
    memory : slop_os.Memory,
    /** Where it is to the controller. */
    device : u64,
}

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** The DMA domain the controller is attached to, which every buffer is made in. */
    domain : slop_os.DmaDomain,
    /** Where BAR 5, the controller's registers, is mapped. */
    registers : u64,
    /** Whether the controller takes addresses past 4 GiB. */
    wide : bool,
    /** Whether there's a disk; without one, every transfer is OutOfRange. */
    has_disk : bool,
    /** The disk's port, and where its registers are mapped. */
    port_index : u32,
    port_registers : u64,
    /** Where the driver's DMA memory is, through its mapping, and to the controller. */
    memory : u64,
    memory_device : u64,
    /** The disk's size, in block.BLOCK_BYTES blocks. */
    block_count : u64,
    /** How many BLOCK_BYTES blocks one of the disk's logical sectors is: 1, or more for a larger sector. */
    per_block : u64,
    /** Whether the disk's write cache is on, which FLUSH CACHE EXT writes back; without one, Flush is Done at once. */
    flushes : bool,
    /** Whether reads and writes are queued (NCQ). */
    queued : bool,
    /** How many slots are used: SLOTS, or fewer as the controller or the disk's queue has. */
    slot_limit : usize,
    /** The requests in flight or waiting, each the command slot of its index. */
    slots : Slot[SLOTS],
    /** The next request's sequence. */
    next_sequence : u64,
    /** Each client's buffer, by its index. */
    buffers : Buffer[service_kit.MAX_CLIENTS],
    /** Each client's place's generation, by its index, moved on as a client leaves it. */
    generations : u32[service_kit.MAX_CLIENTS],
    /** The one port its interrupt and its clients are bound to. */
    port : slop_os.Port,
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
}

/**
 * Drive the first SATA disk behind an AHCI controller, the block protocol, for the clients that connect to it.
 *
 * It resets the controller, starts the disk's port and serves the block protocol on its listener and each connection
 * made through it, until the system stops. It's started by the supervisor, for a controller the platform service gave
 * it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The controller, for its MSI.
 * @param config The controller's 4 KiB of configuration space, mapped to turn on its MSI and bus mastering.
 * @param bar0 BAR 0's memory, unused, as a legacy controller's I/O ports are.
 * @param bar1 BAR 1's memory, unused.
 * @param bar2 BAR 2's memory, unused.
 * @param bar3 BAR 3's memory, unused.
 * @param bar4 BAR 4's memory, unused.
 * @param bar5 BAR 5's memory, ABAR, its registers, which it has to have.
 * @param domain The DMA domain the controller is attached to, which its command list and every connection's buffer
 *     are made in.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had, 2 if config or BAR 5 couldn't be
 *     mapped, 3 if its DMA memory couldn't be made or mapped or is past 4 GiB for a controller that can't reach it, 4
 *     if the controller didn't reset or the firmware didn't let it go, 5 if the disk's port didn't start or IDENTIFY
 *     DEVICE failed or says what the driver can't drive, 6 if no port could be made, 7 if its MSI couldn't be set up,
 *     9 if the listener couldn't be bound.
 */
main :: fn(
    log : slop_os.DebugLog?,
    device : slop_os.Device,
    config : slop_os.Memory,
    bar0 : slop_os.Memory?,
    bar1 : slop_os.Memory?,
    bar2 : slop_os.Memory?,
    bar3 : slop_os.Memory?,
    bar4 : slop_os.Memory?,
    bar5 : slop_os.Memory?,
    domain : slop_os.DmaDomain,
    clients : os.Listener[block.Block]
) -> int {
    startup :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.domain = domain
    driver.per_block = 1
    driver.slot_limit = SLOTS
    config_at :: driver_kit.map_device(config) or_return 2
    driver.registers = driver_kit.map_device(bar5 or_return 2) or_return 2
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER)

    // The command list, received FISes, IDENTIFY's page and the command tables
    bytes :: MEMORY_PAGES * PAGE
    memory :: slop_os.dma_memory_create(domain, startup.budget, bytes, 0) or_return 3
    pages :: runtime.reserve_addresses(cast[usize](bytes)) or_return 3
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, startup.space, pages, 0, bytes, read_write) or_return 3
    driver.memory = pages
    driver.memory_device = slop_os.memory_device_address(memory) or_return 3

    capabilities :: read_u32(driver.registers, CAP)
    driver.wide = capabilities & CAP_64_BIT != 0
    if !driver.wide && (driver.memory_device + bytes - 1) >> 32 != 0 {
        return 3
    }
    if !take_controller(driver) {
        return 4
    }
    ports :: find_disk(driver, capabilities)
    if driver.has_disk {
        if !start_port(driver) || !identify(driver, capabilities) {
            return 5
        }
    }

    driver.port = slop_os.port_create(startup.budget) or_return 6
    _ = service_kit.watch_stop(driver.port)
    if driver.has_disk {
        irq :: slop_os.irq_create_msi(device, startup.budget) or_return 7
        message :: slop_os.irq_message(irq) or_return 7
        if !pci.enable_msi(config_at, message.address, message.data) {
            return 7
        }
        slop_os.port_bind(driver.port, IRQ_KEY, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), .Persistent)
            or_return 7
        write_port(driver, PORT_IS, ~cast[u32](0))
        write_u32(driver.registers, IS, ~cast[u32](0))
        write_port(driver, PORT_IE, PORT_INTERRUPTS)
        write_u32(driver.registers, GHC, read_u32(driver.registers, GHC) | GHC_INTERRUPTS)
    }

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    if driver.has_disk {
        runtime.log_info(
            "serving %1 blocks, %2 bytes each on port %3%4%5",
            driver.block_count,
            driver.per_block * block.BLOCK_BYTES,
            driver.port_index,
            if driver.flushes { ", with a write cache" } else { "" },
            if driver.queued { ", queued" } else { "" }
        )
    }
    else {
        runtime.log_info("no disk on any of % ports", ports)
    }
    into := os.Incoming.{}
    loop {
        with {
            i : usize = 0
        }
        loop {
            serve(driver, i, &into)
            i += 1
        }
        while i < driver.clients.count
        finish(driver)
        dispatch(driver)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Take the controller from the firmware where it has BIOS handoff, reset it, and put it in AHCI mode (§10.4.3,
 * §10.6.3).
 *
 * @param driver The driver, whose registers are written.
 * @return True once it's reset and in AHCI mode; false if the firmware didn't let it go or the reset didn't end within
 *     their waits.
 */
take_controller :: fn(driver : ptr[Driver]) -> bool {
    if read_u32(driver.registers, CAP2) & 1 != 0 {
        write_u32(driver.registers, BOHC, read_u32(driver.registers, BOHC) | BOHC_OS_OWNS)
        if !wait_for(driver.registers + BOHC, BOHC_BIOS_OWNS, 0, HANDOFF_WAIT) {
            return false
        }
    }
    write_u32(driver.registers, GHC, read_u32(driver.registers, GHC) | GHC_AHCI)
    write_u32(driver.registers, GHC, read_u32(driver.registers, GHC) | GHC_RESET)
    if !wait_for(driver.registers + GHC, GHC_RESET, 0, RESET_WAIT) {
        return false
    }
    write_u32(driver.registers, GHC, GHC_AHCI)
    return true
}

/**
 * Find the first implemented port with an ATA disk on it, each spun up where the controller staggers that, its link
 * waited for, and its FIS receive turned on to read what the device says it is; a port that isn't the disk's is left
 * with FIS receive off.
 *
 * @param driver The driver, whose has_disk, port_index and port_registers are set for the disk's port, its command
 *     list and received FISes pointed at the driver's memory.
 * @param capabilities The controller's CAP.
 * @return How many ports are implemented.
 */
find_disk :: fn(driver : ptr[mut Driver], capabilities : u32) -> u32 {
    implemented :: read_u32(driver.registers, PI)
    count := cast[u32](0)
    for index in 0..<32 {
        if (implemented >> cast[u32](index)) & 1 == 0 {
            continue
        }
        count += 1
        if driver.has_disk {
            continue
        }
        driver.port_index = cast[u32](index)
        driver.port_registers = driver.registers + PORTS + cast[u64](index) * PORT_BYTES
        if !stop_port(driver) {
            continue
        }
        if capabilities & CAP_STAGGERED != 0 {
            write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) | CMD_SPIN_UP | CMD_POWER_ON)
        }
        // A link up at once, or a device seen (DET 1) given longer for its link; nothing there passed over quickly
        if !wait_for(driver.port_registers + PORT_SSTS, 0xf, DET_PRESENT, LINK_WAIT) {
            if read_port(driver, PORT_SSTS) & 0xf == 0
                || !wait_for(driver.port_registers + PORT_SSTS, 0xf, DET_PRESENT, LINK_UP_WAIT) {
                continue
            }
        }
        write_port(driver, PORT_CLB, cast[u32](driver.memory_device + COMMAND_LIST))
        write_port(driver, PORT_CLBU, cast[u32]((driver.memory_device + COMMAND_LIST) >> 32))
        write_port(driver, PORT_FB, cast[u32](driver.memory_device + RECEIVED_FIS))
        write_port(driver, PORT_FBU, cast[u32]((driver.memory_device + RECEIVED_FIS) >> 32))
        write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) | CMD_FIS_RECEIVE)
        ready :: wait_for(driver.port_registers + PORT_TFD, TFD_BUSY | TFD_REQUEST, 0, READY_WAIT)
        if ready && read_port(driver, PORT_SIG) == SIGNATURE_ATA {
            driver.has_disk = true
            continue
        }
        write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) & ~CMD_FIS_RECEIVE)
        _ = wait_for(driver.port_registers + PORT_CMD, CMD_FIS_RUNNING, 0, STOP_WAIT)
    }
    return count
}

/**
 * Stop a port's command engine, then its FIS receive (§10.1.2).
 *
 * @param driver The driver, whose port_registers are the port's.
 * @return True once both have stopped; false if either didn't within STOP_WAIT.
 */
stop_port :: fn(driver : ptr[Driver]) -> bool {
    write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) & ~CMD_START)
    if !wait_for(driver.port_registers + PORT_CMD, CMD_RUNNING, 0, STOP_WAIT) {
        return false
    }
    write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) & ~CMD_FIS_RECEIVE)
    return wait_for(driver.port_registers + PORT_CMD, CMD_FIS_RUNNING, 0, STOP_WAIT)
}

/**
 * Start the disk's port's command engine, its errors and interrupts cleared, once the disk isn't busy.
 *
 * @param driver The driver, whose port is the disk's, its FIS receive on.
 * @return True once it's started; false if the disk stayed busy past READY_WAIT.
 */
start_port :: fn(driver : ptr[Driver]) -> bool {
    write_port(driver, PORT_SERR, ~cast[u32](0))
    write_port(driver, PORT_IS, ~cast[u32](0))
    if !wait_for(driver.port_registers + PORT_TFD, TFD_BUSY | TFD_REQUEST, 0, READY_WAIT) {
        return false
    }
    write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) | CMD_START)
    return true
}

/**
 * Identify the disk, polled: its size, its logical sector size, its write cache and whether it queues.
 *
 * @param driver The driver, whose block_count, per_block, flushes, queued and slot_limit are set.
 * @param capabilities The controller's CAP, for its slots and whether it queues.
 * @return True if the disk answered and has 48-bit addresses, blocks, and logical sectors of BLOCK_BYTES to 64 KiB;
 *     false otherwise.
 */
identify :: fn(driver : ptr[mut Driver], capabilities : u32) -> bool {
    fis := Fis.{kind = FIS_HOST_TO_DEVICE, flags = FIS_COMMAND, command = ATA_IDENTIFY}
    prepare(driver, 0, &fis, driver.memory_device + IDENTIFY_PAGE * PAGE, 512, false)
    driver_kit.before_device_write()
    write_port(driver, PORT_CI, 1)
    if !wait_for(driver.port_registers + PORT_CI, 1, 0, IDENTIFY_WAIT)
        || read_port(driver, PORT_IS) & IS_ERRORS != 0
        || read_port(driver, PORT_TFD) & TFD_ERROR != 0 {
        return false
    }
    // Words 83 (bit 10, 48-bit addresses), 100 to 103 (their sectors), 75 (bits 4:0, the queue's depth less one), 76
    // (bit 8, NCQ), 85 (bit 5, the write cache on), 106 (bits 15:14 01 if it's valid, bit 12 a larger logical
    // sector) and 117 to 118 (that sector's words)
    if word(driver, 83) & (1 << 10) == 0 {
        return false
    }
    sectors :: cast[u64](word(driver, 100))
        | (cast[u64](word(driver, 101)) << 16)
        | (cast[u64](word(driver, 102)) << 32)
        | (cast[u64](word(driver, 103)) << 48)
    sector_bytes := block.BLOCK_BYTES
    layout :: word(driver, 106)
    if layout & 0xc000 == 0x4000 && layout & (1 << 12) != 0 {
        sector_bytes = 2 * (cast[u64](word(driver, 117)) | (cast[u64](word(driver, 118)) << 16))
    }
    if sectors == 0
        || sector_bytes < block.BLOCK_BYTES
        || sector_bytes > 64 * 1024
        || sector_bytes % block.BLOCK_BYTES != 0 {
        return false
    }
    driver.per_block = sector_bytes / block.BLOCK_BYTES
    driver.block_count = sectors * driver.per_block
    driver.flushes = word(driver, 85) & (1 << 5) != 0
    driver.queued = capabilities & CAP_NCQ != 0 && word(driver, 76) & (1 << 8) != 0
    controller_slots :: cast[usize]((capabilities >> 8) & 0x1f) + 1
    if controller_slots < driver.slot_limit {
        driver.slot_limit = controller_slots
    }
    depth :: cast[usize](word(driver, 75) & 0x1f) + 1
    if driver.queued && depth < driver.slot_limit {
        driver.slot_limit = depth
    }
    return true
}

/**
 * One of IDENTIFY DEVICE's words.
 *
 * @param driver The driver, whose IDENTIFY page holds what the disk answered.
 * @param index The word, below 256.
 * @return Its value.
 */
word :: fn(driver : ptr[Driver], index : u64) -> u16 {
    return intrinsics.volatile_load_u16(cast[ptr[u16]](driver.memory + IDENTIFY_PAGE * PAGE + 2 * index))
}

/**
 * Write a slot's command header and table: a FIS, and the data it moves, if any, as one PRD entry.
 *
 * @param driver The driver, whose command list and tables are written.
 * @param slot The slot, below the controller's slots.
 * @param fis The command's FIS.
 * @param data The data's address to the controller, word aligned; unused for none.
 * @param bytes How many bytes, even, at most 4 MiB; 0 for none.
 * @param writes Whether the device is written to.
 */
prepare :: fn(driver : ptr[Driver], slot : usize, fis : ptr[Fis], data : u64, bytes : u64, writes : bool) {
    table_offset :: TABLES_PAGE * PAGE + cast[u64](slot) * TABLE_BYTES
    table := CommandTable.{}
    table.fis = fis^
    if bytes > 0 {
        table.prd = Prd.{address = cast[u64le](data), count = cast[u32le](cast[u32](bytes - 1))}
    }
    cast[ptr[mut CommandTable]](driver.memory + table_offset)^ = table
    flags := HEADER_FIS_DWORDS
    if writes {
        flags |= HEADER_WRITE
    }
    if bytes > 0 {
        flags |= 1 << 16
    }
    header :: Header.{flags = cast[u32le](flags), table = cast[u64le](driver.memory_device + table_offset)}
    cast[ptr[mut Header]](driver.memory + COMMAND_LIST + cast[u64](slot) * 32)^ = header
}

/**
 * Answer, or start, every request a client has sent, until there are none left, or it's gone; as virtio-blk does.
 *
 * @param driver The driver, whose slots, buffers and clients change.
 * @param index Which client, by its index; one past them, or a freed place, is nothing to serve.
 * @param into Where each request is received, reused for each.
 */
serve :: fn(driver : ptr[mut Driver], index : usize, into : ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match block.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = block.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&driver.clients, index)
                // Its buffer goes with it, now or once the controller's done with what it was asked with it
                if index < driver.buffers.count {
                    driver.generations[index] += 1
                    old :: driver.buffers[index].memory
                    driver.buffers[index] = Buffer.{memory = cast[slop_os.Memory](slop_os.NO_HANDLE)}
                    release_buffer(driver, old)
                }
                return void
            }
        }
        match os.message_of[block.Request](into)^ {
            case Read(transfer) => answer(driver, end, start(driver, index, transfer, false))
            case Write(transfer) => answer(driver, end, start(driver, index, transfer, true))
            case Flush(tag) => answer(driver, end, start_flush(driver, index, tag))
            case Describe => answer(
                driver,
                end,
                .Described(
                    block.Info.{
                        block_count = driver.block_count,
                        buffer_bytes = BUFFER_BYTES,
                        read_only = false,
                        flushes = driver.flushes,
                    }
                )
            )
            case GetBuffer => answer(driver, end, buffer_for(driver, index))
            case Connect(connection) => {
                if !service_kit.add_client(&driver.clients, driver.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Send a client an answer, if there is one now; one that can't be sent is dropped.
 *
 * @param driver The driver, whose port is waited on while end's ring is full.
 * @param end The client's channel end, one the driver's clients keep.
 * @param response The answer; null for a request in flight or waiting, answered when the controller completes it.
 */
answer :: fn(driver : ptr[mut Driver], end : slop_os.Channel, response : block.Response?) {
    given :: response or_return void
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = given
    _ = block.send_response(end, driver.port, &out)
}

/**
 * Make a Finished answer.
 *
 * @param tag The client's tag, given back as it is.
 * @param status How it went.
 * @return Finished with tag and status; never null.
 */
finished :: fn(tag : u64, status : block.Status) -> block.Response? {
    return block.Response.Finished(block.Completion.{tag = tag, status = status})
}

/**
 * Take a slot for a Read or a Write: the disk's sectors, its data the client's buffer at the transfer's offset,
 * queued where the driver queues, issued by dispatch.
 *
 * @param driver The driver, a slot of whose is taken.
 * @param client The asking client, by its index.
 * @param transfer The blocks, and where in the client's buffer.
 * @param writes True for a Write, false for a Read.
 * @return Null once it's in a slot, answered when the controller completes it; Finished now with OutOfRange for a
 *     client without a buffer, a count of 0, blocks past the disk or not on its own sectors, bytes past the buffer, or
 *     an odd offset, as a PRD entry needs word alignment; Busy with every slot taken.
 */
start :: fn(driver : ptr[mut Driver], client : usize, transfer : block.Transfer, writes : bool) -> block.Response? {
    if client >= driver.buffers.count || cast[slop_os.Handle](driver.buffers[client].memory) == slop_os.NO_HANDLE {
        return finished(transfer.tag, .OutOfRange)
    }
    bytes :: cast[u64](transfer.count) * block.BLOCK_BYTES
    if transfer.count == 0
        || transfer.first > driver.block_count
        || cast[u64](transfer.count) > driver.block_count - transfer.first
        || cast[u64](transfer.offset) > BUFFER_BYTES
        || bytes > BUFFER_BYTES - cast[u64](transfer.offset)
        || transfer.offset % 2 != 0
        || transfer.first % driver.per_block != 0
        || cast[u64](transfer.count) % driver.per_block != 0 {
        return finished(transfer.tag, .OutOfRange)
    }
    slot :: free_slot(driver) or_return finished(transfer.tag, .Busy)
    first :: transfer.first / driver.per_block
    sectors :: cast[u64](transfer.count) / driver.per_block
    fis := Fis.{kind = FIS_HOST_TO_DEVICE, flags = FIS_COMMAND, device = DEVICE_LBA}
    fis.lba0 = cast[u8](first & 0xff)
    fis.lba1 = cast[u8]((first >> 8) & 0xff)
    fis.lba2 = cast[u8]((first >> 16) & 0xff)
    fis.lba3 = cast[u8]((first >> 24) & 0xff)
    fis.lba4 = cast[u8]((first >> 32) & 0xff)
    fis.lba5 = cast[u8]((first >> 40) & 0xff)
    if driver.queued {
        // The count in the features, the tag in the count's bits 7:3
        fis.command = if writes { ATA_WRITE_QUEUED } else { ATA_READ_QUEUED }
        fis.feature_low = cast[u8](sectors & 0xff)
        fis.feature_high = cast[u8]((sectors >> 8) & 0xff)
        fis.count_low = cast[u8](slot << 3)
    }
    else {
        fis.command = if writes { ATA_WRITE_DMA_EXT } else { ATA_READ_DMA_EXT }
        fis.count_low = cast[u8](sectors & 0xff)
        fis.count_high = cast[u8]((sectors >> 8) & 0xff)
    }
    prepare(driver, slot, &fis, driver.buffers[client].device + cast[u64](transfer.offset), bytes, writes)
    return hold(driver, slot, client, transfer.tag, driver.queued)
}

/**
 * Take a slot for a FLUSH CACHE EXT, where the disk's write cache is on; it's never queued.
 *
 * @param driver The driver.
 * @param client The asking client, by its index.
 * @param tag The client's tag.
 * @return Null once it's in a slot; Finished now with Done without a write cache, whose writes are durable, or Busy
 *     with every slot taken.
 */
start_flush :: fn(driver : ptr[mut Driver], client : usize, tag : u64) -> block.Response? {
    if !driver.flushes {
        return finished(tag, .Done)
    }
    slot :: free_slot(driver) or_return finished(tag, .Busy)
    fis := Fis.{kind = FIS_HOST_TO_DEVICE, flags = FIS_COMMAND, command = ATA_FLUSH_EXT}
    prepare(driver, slot, &fis, 0, 0, false)
    return hold(driver, slot, client, tag, false)
}

/**
 * Note a request in a slot, waiting to be issued.
 *
 * @param driver The driver, whose next sequence is the request's.
 * @param slot The slot, free, its command written.
 * @param client The asking client, by its index.
 * @param tag The client's tag.
 * @param queued Whether its command is a queued one.
 * @return Null, as it's answered when the controller completes it.
 */
hold :: fn(driver : ptr[mut Driver], slot : usize, client : usize, tag : u64, queued : bool) -> block.Response? {
    if slot >= driver.slots.count {
        return finished(tag, .Busy)
    }
    generation :: if client < driver.generations.count { driver.generations[client] } else { cast[u32](0) }
    memory :: if client < driver.buffers.count { driver.buffers[client].memory } else { cast[slop_os.Memory](slop_os.NO_HANDLE) }
    driver.slots[slot] = Slot.{
        used = true,
        issued = false,
        queued = queued,
        sequence = driver.next_sequence,
        client = client,
        tag = tag,
        generation = generation,
        memory = memory,
    }
    driver.next_sequence += 1
    return null
}

/**
 * Issue what waits, in the order it was asked, while it can go beside what's in flight: a queued command beside
 * queued ones, and anything once nothing is; the first that can't stops it, so nothing passes it.
 *
 * @param driver The driver, whose waiting slots are issued, their bits set in PxSACT for a queued one and PxCI.
 */
dispatch :: fn(driver : ptr[mut Driver]) {
    if !driver.has_disk {
        return void
    }
    loop {
        next : usize? = null
        flying := false
        flying_unqueued := false
        earliest := cast[u64](0)
        for slot, i in driver.slots {
            if !slot.used {
                continue
            }
            if slot.issued {
                flying = true
                flying_unqueued = flying_unqueued || !slot.queued
            }
            else if next == null || slot.sequence < earliest {
                next = i
                earliest = slot.sequence
            }
        }
        index :: next or_break
        if index >= driver.slots.count {
            break
        }
        if flying && (flying_unqueued || !driver.slots[index].queued) {
            break
        }
        driver.slots[index].issued = true
        bit :: cast[u32](1) << cast[u32](index)
        driver_kit.before_device_write()
        if driver.slots[index].queued {
            write_port(driver, PORT_SACT, bit)
        }
        write_port(driver, PORT_CI, bit)
    }
}

/**
 * Close a buffer its client left, unless the controller still has commands with it, the last of which closes it.
 *
 * @param driver The driver, whose slots are looked through.
 * @param memory The buffer's memory; NO_HANDLE is nothing to close.
 */
release_buffer :: fn(driver : ptr[Driver], memory : slop_os.Memory) {
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        return void
    }
    for slot in driver.slots {
        if slot.used && slot.memory == memory {
            return void
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
}

/**
 * Find a slot not in use, among the slot_limit used.
 *
 * @param driver The driver.
 * @return The lowest free slot's index; null if all slot_limit are taken.
 */
free_slot :: fn(driver : ptr[Driver]) -> usize? {
    for slot, i in driver.slots {
        if i < driver.slot_limit && !slot.used {
            return i
        }
    }
    return null
}

/**
 * Answer every command the controller has completed: its interrupts cleared, then, after an error, everything in
 * flight failed and the port started again, or otherwise each issued command whose PxCI bit, and PxSACT bit for a
 * queued one, is clear answered Done.
 *
 * @param driver The driver, whose slots are freed.
 */
finish :: fn(driver : ptr[mut Driver]) {
    if !driver.has_disk {
        return void
    }
    // Cleared before PxCI's read, so a command that ends after it interrupts again
    status :: read_port(driver, PORT_IS)
    write_port(driver, PORT_IS, status)
    write_u32(driver.registers, IS, cast[u32](1) << driver.port_index)
    if status & IS_ERRORS != 0 {
        recover(driver)
        return void
    }
    issued :: read_port(driver, PORT_CI)
    active :: read_port(driver, PORT_SACT)
    for i in 0..<driver.slots.count {
        slot :: driver.slots[i]
        bit :: cast[u32](1) << cast[u32](i)
        if slot.used && slot.issued && issued & bit == 0 && (!slot.queued || active & bit == 0) {
            complete(driver, i, .Done)
        }
    }
}

/**
 * Fail everything in flight after an error, and start the port again (§6.2.2): its engine stopped, then what was in
 * flight failed, its errors cleared, a COMRESET sent, and its engine started; what waits is issued after.
 *
 * @param driver The driver, whose issued slots are answered DeviceError and freed.
 */
recover :: fn(driver : ptr[mut Driver]) {
    // The engine stopped first, so nothing it was doing still writes a buffer that completing a slot lets go
    write_port(driver, PORT_CMD, read_port(driver, PORT_CMD) & ~CMD_START)
    _ = wait_for(driver.port_registers + PORT_CMD, CMD_RUNNING, 0, STOP_WAIT)
    for i in 0..<driver.slots.count {
        if driver.slots[i].used && driver.slots[i].issued {
            complete(driver, i, .DeviceError)
        }
    }
    write_port(driver, PORT_SERR, ~cast[u32](0))
    write_port(driver, PORT_IS, ~cast[u32](0))
    /*
     * A COMRESET always: after a queued command's error the disk refuses every queued command until its NCQ error log
     * is read (READ LOG EXT page 10h), which the reset clears too, as it does a disk still busy
     */
    control :: read_port(driver, PORT_SCTL) & ~cast[u32](0xf)
    write_port(driver, PORT_SCTL, control | 1)
    pause(COMRESET_HOLD)
    write_port(driver, PORT_SCTL, control)
    _ = wait_for(driver.port_registers + PORT_SSTS, 0xf, DET_PRESENT, LINK_UP_WAIT)
    write_port(driver, PORT_SERR, ~cast[u32](0))
    if !start_port(driver) {
        runtime.log_info("port % didn't start again after an error", driver.port_index)
    }
}

/**
 * Answer a slot's request to its client, and free the slot; a left client's isn't answered, and its last lets its
 * buffer go.
 *
 * @param driver The driver.
 * @param index The slot, in use.
 * @param status How it went.
 */
complete :: fn(driver : ptr[mut Driver], index : usize, status : block.Status) {
    if index >= driver.slots.count {
        return void
    }
    slot :: &driver.slots[index]
    slot.used = false
    slot.issued = false
    current :: slot.client < driver.generations.count && driver.generations[slot.client] == slot.generation
    if current && slot.client < driver.clients.ends.count {
        end :: driver.clients.ends[slot.client]
        if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
            answer(driver, end, finished(slot.tag, status))
        }
    }
    if !current {
        release_buffer(driver, slot.memory)
    }
}

/**
 * Give a client a window onto its buffer, the buffer made at its first ask; as virtio-blk does.
 *
 * @param driver The driver, whose buffer for the client is made in its DMA domain the first time.
 * @param client The asking client, by its index.
 * @return Buffer with a new window onto all of the buffer; Unsupported if the client's index is past them, the buffer
 *     or window couldn't be made, or the buffer's past 4 GiB for a controller that can't reach it.
 */
buffer_for :: fn(driver : ptr[mut Driver], client : usize) -> block.Response? {
    startup :: slop_os.startup_block()
    if client >= driver.buffers.count {
        return block.Response.Unsupported
    }
    if cast[slop_os.Handle](driver.buffers[client].memory) == slop_os.NO_HANDLE {
        memory :: slop_os.dma_memory_create(driver.domain, startup.budget, BUFFER_BYTES, 0)
            or_return block.Response.Unsupported
        address :: slop_os.memory_device_address(memory) or_return block.Response.Unsupported
        if !driver.wide && (address + BUFFER_BYTES - 1) >> 32 != 0 {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return block.Response.Unsupported
        }
        driver.buffers[client] = Buffer.{memory = memory, device = address}
    }
    window :: slop_os.memory_create_window(driver.buffers[client].memory, startup.budget, 0, BUFFER_BYTES)
        or_return block.Response.Unsupported
    return block.Response.Buffer(window)
}

/**
 * Wait for a register's bits to be what's wanted, polling, until a deadline on the monotonic clock.
 *
 * @param address The register's address, mapped.
 * @param mask The bits looked at.
 * @param value What they're waited to be.
 * @param nanoseconds How long it waits at most.
 * @return True once they are; false once nanoseconds have passed, or the clock can't be read, without them being.
 */
wait_for :: fn(address : u64, mask : u32, value : u32, nanoseconds : u64) -> bool {
    deadline :: (slop_os.clock_monotonic() or_else 0) + nanoseconds
    loop {
        if intrinsics.volatile_load_u32(cast[ptr[u32]](address)) & mask == value {
            return true
        }
        if (slop_os.clock_monotonic() or_else deadline) >= deadline {
            return false
        }
        intrinsics.spin_hint()
    }
}

/**
 * Wait, polling the monotonic clock.
 *
 * @param nanoseconds How long; it returns at once if the clock can't be read.
 */
pause :: fn(nanoseconds : u64) {
    deadline :: (slop_os.clock_monotonic() or_else 0) + nanoseconds
    loop {
        if (slop_os.clock_monotonic() or_else deadline) >= deadline {
            return void
        }
        intrinsics.spin_hint()
    }
}

/**
 * Read a 32-bit register.
 *
 * @param base Where the registers are mapped.
 * @param offset The register's offset.
 * @return Its value.
 */
read_u32 :: fn(base : u64, offset : u64) -> u32 {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](base + offset))
}

/**
 * Write a 32-bit register.
 *
 * @param base Where the registers are mapped.
 * @param offset The register's offset.
 * @param value What's written.
 */
write_u32 :: fn(base : u64, offset : u64, value : u32) {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](base + offset), value)
}

/**
 * Read one of the disk's port's registers.
 *
 * @param driver The driver, whose port_registers are mapped.
 * @param offset The register's offset in the port's.
 * @return Its value.
 */
read_port :: fn(driver : ptr[Driver], offset : u64) -> u32 {
    return read_u32(driver.port_registers, offset)
}

/**
 * Write one of the disk's port's registers.
 *
 * @param driver The driver, whose port_registers are mapped.
 * @param offset The register's offset in the port's.
 * @param value What's written.
 */
write_port :: fn(driver : ptr[Driver], offset : u64, value : u32) {
    write_u32(driver.port_registers, offset, value)
}
