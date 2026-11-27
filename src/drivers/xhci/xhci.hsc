/**
 * The xHCI driver (roadmap 20d, decisions/0201): a USB host controller, the devices on its root ports and behind hubs
 * addressed and configured, and each interface of each device served, the USB device protocol, to the class driver
 * the supervisor starts for it. What's found is told to the supervisor, the USB bus protocol, on the driver's
 * listener: each interface, with a connection to it, then Settled once what was there at start is all told, then
 * what comes and goes after.
 *
 * Hubs are the driver's own: their ports powered, reset and watched through their status change endpoint, and the
 * devices behind them addressed with their route strings, those at full or low speed behind a high-speed hub through
 * its transaction translator. Commands to the controller are waited for, polled, the events that come meanwhile
 * handled as they come; so are the driver's own control transfers, as a device is found. A class driver's transfers
 * are answered as they complete: one at a time on each endpoint, as an endpoint's transfers run in order.
 *
 * A connection reaches only its interface: its endpoints, and requests on the default control endpoint to the
 * interface or its endpoints, or the device's descriptors and status; SET_ADDRESS, SET_CONFIGURATION and
 * SET_INTERFACE are refused, as the configuration is the driver's. Its data moves through a buffer of its own, DMA
 * memory made at its first GetBuffer, which the controller reads and writes directly.
 *
 * SPEC: xHCI 1.2 (registers §5, rings and TRBs §4.9 and §6.4, contexts §6.2, enumeration §4.3, commands §4.6,
 * interrupts §4.17, extended capabilities §7); USB 2.0 (standard requests §9.4, descriptors §9.6, the hub class §11).
 */
package xhci

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import driver_kit from "../../driver_kit"
import service_kit from "../../libraries/service_kit"
import pci from "../../pci"
import usb_bus from "../../protocols/usb_bus"
import usb_device from "../../protocols/usb_device"

/** The bytes of a page, and of the controller's pages. */
PAGE : u64 : 4096
/** The bytes of each connection's buffer: 64 KiB. */
BUFFER_BYTES : u64 : 64 * 1024
/** The most devices the driver keeps at once, hubs among them: 16, and the slots it enables on the controller. */
MAX_DEVICES :: 16
/** The most interfaces of a device it serves, and endpoints besides the default one: 4 each. */
MAX_INTERFACES :: 4
MAX_ENDPOINTS :: 4
/** The most ports it watches, on the controller and on each hub: 64 and 15. */
MAX_PORTS : u32 : 64
MAX_HUB_PORTS : u32 : 15
/** How many TRBs each ring has, one page of them, the last a link back to the first. */
RING_TRBS : u32 : 256
/** The bytes of a TRB. */
TRB_BYTES : u64 : 16
/** No device, client or interface. */
NONE : usize : 0xffff_ffff
/** The port key the controller's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** The deepest a device may be behind hubs: 5 tiers, as a route string has room for. */
MAX_DEPTH : u32 : 5

// How long things are given, in nanoseconds
/** The controller's reset, its halt, and the firmware letting it go: 1 s each. */
CONTROLLER_WAIT : u64 : 1_000_000_000
/** A command, or one of the driver's own control transfers: 2 s. */
COMMAND_WAIT : u64 : 2_000_000_000
/** A port's reset: 500 ms; then 10 ms for the device to recover, as USB 2.0 §7.1.7.3 says. */
RESET_WAIT : u64 : 500_000_000
RESET_RECOVERY : u64 : 10_000_000
/** A USB 3 port's link to come up without a reset: 200 ms. */
LINK_WAIT : u64 : 200_000_000
/** Between polls of a hub's port while it resets: 5 ms. */
HUB_POLL : u64 : 5_000_000

// Capability registers (§5.3)
CAPLENGTH : u64 : 0x00
HCSPARAMS1 : u64 : 0x04
HCSPARAMS2 : u64 : 0x08
HCCPARAMS1 : u64 : 0x10
DBOFF : u64 : 0x14
RTSOFF : u64 : 0x18
/** HCCPARAMS1's AC64 (bit 0), 64-bit addresses; PPC (bit 3), port power control; CSZ (bit 2), 64-byte contexts. */
HCC_64_BIT : u32 : 1
HCC_CONTEXT_64 : u32 : 1 << 2
HCC_PORT_POWER : u32 : 1 << 3

// Operational registers, from CAPLENGTH (§5.4)
USBCMD : u64 : 0x00
USBSTS : u64 : 0x04
CRCR : u64 : 0x18
DCBAAP : u64 : 0x30
CONFIG : u64 : 0x38
/** USBCMD's R/S (bit 0), HCRST (1) and INTE (2). */
CMD_RUN : u32 : 1
CMD_RESET : u32 : 1 << 1
CMD_INTERRUPTS : u32 : 1 << 2
/** USBSTS's HCH (bit 0), EINT (3) and CNR (11). */
STS_HALTED : u32 : 1
STS_EVENT : u32 : 1 << 3
STS_NOT_READY : u32 : 1 << 11
/** Where the ports' registers are, 16 bytes each from port 1. */
PORT_REGISTERS : u64 : 0x400
/** PORTSC's CCS (0), PED (1), PR (4), PP (9), its speed (13:10), and its change bits (23:17), PRC among them (21). */
PORT_CONNECTED : u32 : 1
PORT_ENABLED : u32 : 1 << 1
PORT_RESET : u32 : 1 << 4
PORT_POWER : u32 : 1 << 9
PORT_RESET_CHANGE : u32 : 1 << 21
/** PORTSC's CSC (17): the port's connection changed since it was last cleared. */
PORT_CONNECT_CHANGE : u32 : 1 << 17
PORT_CHANGES : u32 : 0x7f << 17
/** PORTSC's bits kept as they are by a write: those read-only and those written as read (Linux's neutral state). */
PORT_KEEP : u32 : 1 | (1 << 3) | (0xf << 10) | (1 << 30) | (0xf << 5) | (1 << 9) | (3 << 14) | (7 << 25)

// Runtime registers, interrupter 0's (§5.5)
IMAN : u64 : 0x20
IMOD : u64 : 0x24
ERSTSZ : u64 : 0x28
ERSTBA : u64 : 0x30
ERDP : u64 : 0x38
/** IMAN's IP (bit 0) and IE (1); ERDP's EHB (bit 3). */
IMAN_PENDING : u32 : 1
IMAN_ENABLE : u32 : 1 << 1
ERDP_BUSY : u64 : 1 << 3

// TRB types (§6.4.6) and bits
TRB_NORMAL : u32 : 1
TRB_SETUP : u32 : 2
TRB_DATA : u32 : 3
TRB_STATUS : u32 : 4
TRB_LINK : u32 : 6
TRB_ENABLE_SLOT : u32 : 9
TRB_DISABLE_SLOT : u32 : 10
TRB_ADDRESS_DEVICE : u32 : 11
TRB_CONFIGURE_ENDPOINT : u32 : 12
TRB_EVALUATE_CONTEXT : u32 : 13
TRB_RESET_ENDPOINT : u32 : 14
TRB_STOP_ENDPOINT : u32 : 15
TRB_SET_DEQUEUE : u32 : 16
TRB_TRANSFER_EVENT : u32 : 32
TRB_COMMAND_COMPLETION : u32 : 33
TRB_PORT_STATUS_CHANGE : u32 : 34
/** A TRB's cycle bit (0), a link's toggle cycle (1), ISP (2), CH (4), IOC (5), IDT (6), and a stage's DIR (16). */
TRB_CYCLE : u32 : 1
TRB_TOGGLE : u32 : 1 << 1
TRB_SHORT : u32 : 1 << 2
TRB_CHAIN : u32 : 1 << 4
TRB_INTERRUPT : u32 : 1 << 5
TRB_IMMEDIATE : u32 : 1 << 6
TRB_IN : u32 : 1 << 16
/** Completion codes (§6.4.5): success, stall, short packet. */
CODE_SUCCESS : u32 : 1
CODE_STALL : u32 : 6
CODE_SHORT : u32 : 13

// Extended capabilities (§7)
/** USB Legacy Support: its BIOS owned (bit 16) and OS owned (24) semaphores. */
EXTENDED_LEGACY : u32 : 1
LEGACY_BIOS : u32 : 1 << 16
LEGACY_OS : u32 : 1 << 24
/** Supported Protocol, which says which ports are USB 3's. */
EXTENDED_PROTOCOL : u32 : 2

// Standard requests and descriptors (USB 2.0 §9.4, §9.6), and the hub class's (§11.24)
REQUEST_GET_STATUS : u8 : 0
REQUEST_CLEAR_FEATURE : u8 : 1
REQUEST_SET_FEATURE : u8 : 3
REQUEST_SET_ADDRESS : u8 : 5
REQUEST_GET_DESCRIPTOR : u8 : 6
REQUEST_SET_CONFIGURATION : u8 : 9
REQUEST_SET_INTERFACE : u8 : 11
DESCRIPTOR_DEVICE : u16 : 1
DESCRIPTOR_CONFIGURATION : u16 : 2
DESCRIPTOR_INTERFACE : u8 : 4
DESCRIPTOR_ENDPOINT : u8 : 5
DESCRIPTOR_HUB : u16 : 0x29
CLASS_HUB : u8 : 9
/** A hub port's features: its reset and power, and its change bits' clearing, from C_PORT_CONNECTION (16). */
HUB_PORT_RESET : u16 : 4
HUB_PORT_POWER : u16 : 8
HUB_CHANGE_FEATURES : u16 : 16
/** A hub port's status bits: connected, enabled, low speed (9), high speed (10); its reset's change bit, 4. */
HUB_CONNECTED : u32 : 1
HUB_ENABLED : u32 : 1 << 1
HUB_LOW_SPEED : u32 : 1 << 9
HUB_HIGH_SPEED : u32 : 1 << 10
HUB_RESET_CHANGE : u32 : 1 << 4

/** xHCI's speed IDs (PORTSC, the slot context): full, low, high, and SuperSpeed and above from 4. */
SPEED_FULL : u32 : 1
SPEED_LOW : u32 : 2
SPEED_HIGH : u32 : 3
SPEED_SUPER : u32 : 4

// The driver's memory: the device context base address array, the command ring, the event ring, and its segment table
DCBAA_PAGE : u64 : 0
COMMAND_PAGE : u64 : 1
EVENT_PAGE : u64 : 2
ERST_PAGE : u64 : 3
MEMORY_PAGES : u64 : 4
// Each device's memory: its output context, its input context, its default endpoint's ring, a page for the driver's
// own control transfers' data (a hub's status changes from its middle), and a ring for each endpoint
OUTPUT_PAGE : u64 : 0
INPUT_PAGE : u64 : 1
CONTROL_RING_PAGE : u64 : 2
DATA_PAGE : u64 : 3
RINGS_PAGE : u64 : 4
DEVICE_PAGES : u64 : RINGS_PAGE + cast[u64](MAX_ENDPOINTS)
/** Where in the data page a hub's status change endpoint writes. */
HUB_STATUS_OFFSET : u64 : 2048

/** A TRB (§4.11): its parameter, its status, and its control, whose bit 0 is its cycle bit. */
Trb :: struct #packed {
    parameter : u64le,
    status : u32le,
    control : u32le,
}

#assert size_of(Trb) == 16

/** A ring the driver fills, a command or transfer ring, or one it takes from, the event ring. */
Ring :: struct {
    /** Where its TRBs are, through the driver's mapping, and to the controller. */
    entries : u64,
    device : u64,
    /** The next TRB's index. */
    index : u32,
    /** The cycle bit the next TRB has. */
    cycle : u32,
}

/** An endpoint: what its descriptor says, its ring, and the transfer in flight on it. */
Endpoint :: struct {
    /** Its device context index: 1 for the default control endpoint, 2 times the number plus 1 for IN. */
    dci : u32,
    /** Its descriptor's address, kind, packet size and interval, and which of the device's interfaces it's of. */
    address : u8,
    kind : usb_device.EndpointKind,
    max_packet : u16,
    interval : u8,
    interface : usize,
    /** Its transfer ring. */
    ring : Ring,
    /** Whether a transfer's in flight, and whether it's the driver's own, a client's otherwise. */
    busy : bool,
    own : bool,
    /** The driver's own transfer's end: whether it's done, its completion code, and its bytes. */
    own_done : bool,
    own_code : u32,
    /** A client's transfer's client, by index, tag, the client's generation then, and its buffer's memory. */
    client : usize,
    tag : u64,
    generation : u32,
    memory : slop_os.Memory,
    /** The transfer's first data TRB, its bytes, and the bytes of the whole: what an event's residue is taken from. */
    first_trb : u64,
    first_bytes : u32,
    bytes : u32,
    /** The bytes moved so far, from a control transfer's data stage, as its status stage's event says none. */
    moved : u32,
    /** Whether it's a control transfer, whose status stage's event ends it, and that stage's TRB. */
    control : bool,
    status_trb : u64,
    /** Whether the controller halted it after an error, so it's reset before the next transfer. */
    halted : bool,
}

/** An interface the driver serves. */
Interface :: struct {
    /** Its number, class, subclass and protocol. */
    number : u8,
    class : u8,
    subclass : u8,
    protocol : u8,
    /** The supervisor's end of its connection, until it's Attached; NO_HANDLE after. */
    peer : slop_os.Channel,
    /** Whether it's been Attached, and whether its Detached has been told. */
    announced : bool,
    gone_told : bool,
}

/** A device the driver's addressed. */
Device :: struct {
    /** Whether the place holds a device, and whether it's been unplugged, kept until its interfaces are Detached. */
    used : bool,
    gone : bool,
    /** Its slot on the controller. */
    slot : u32,
    /** Its speed, xHCI's ID. */
    speed : u32,
    /** Its route string, root port, and tier: 0 on a root port. */
    route : u32,
    root_port : u32,
    depth : u32,
    /** The hub it's behind, by index, and that hub's port; NONE and 0 on a root port. */
    parent : usize,
    parent_port : u32,
    /** Its transaction translator, for a full or low speed device behind a high-speed hub: the hub's slot and port. */
    tt_slot : u32,
    tt_port : u32,
    /** Whether it's a hub, its ports, and the status changes its endpoint reported, a bit per port, not yet looked at. */
    hub : bool,
    hub_ports : u32,
    hub_changes : u32,
    /** Its memory (DEVICE_PAGES), through the driver's mapping, and to the controller. */
    memory : slop_os.Memory,
    memory_at : u64,
    memory_device : u64,
    /** Its IDs. */
    vendor : u16,
    product : u16,
    /** The default control endpoint, and its others. */
    control : Endpoint,
    endpoints : Endpoint[MAX_ENDPOINTS],
    endpoint_count : usize,
    interfaces : Interface[MAX_INTERFACES],
    interface_count : usize,
}

/** What a client is. */
ClientKind :: enum #backed_by(u8) {
    Nothing = 0,
    /** A supervisor's, the USB bus protocol. */
    Bus = 1,
    /** A class driver's, or an interface's own connection, the USB device protocol. */
    Interface = 2,
}

/** A client's state, by its index. */
Client :: struct {
    kind : ClientKind,
    /** A bus client's held Next, and whether it's been told Settled. */
    waiting : bool,
    settled_told : bool,
    /** An interface client's device and interface, by index. */
    device : usize,
    interface : usize,
    /** Its buffer, once it has one, and where it is to the controller. */
    buffer : slop_os.Memory,
    buffer_device : u64,
    /** Its place's generation, moved on as a client leaves it. */
    generation : u32,
}

/** What a command answered. */
CommandResult :: struct {
    code : u32,
    slot : u32,
}

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    domain : slop_os.DmaDomain,
    /** Where BAR 0 is mapped, and its operational, runtime and doorbell registers. */
    registers : u64,
    operational : u64,
    runtime_registers : u64,
    doorbells : u64,
    /** Whether the controller takes 64-bit addresses, and its contexts' bytes, 32 or 64. */
    wide : bool,
    context_bytes : u64,
    /** Its ports, at most MAX_PORTS, and which are USB 3's, a bit each from port 1's. */
    port_count : u32,
    usb3 : u64,
    /** Ports a status change event came for, a bit each from port 1's, not yet looked at. */
    port_changes : u64,
    /** The driver's memory, through its mapping and to the controller. */
    memory_at : u64,
    memory_device : u64,
    commands : Ring,
    events : Ring,
    /** The command waited for: its TRB, to the controller, whose completion alone answers it; whether it's answered, and how. */
    command_trb : u64,
    command_done : bool,
    command_result : CommandResult,
    devices : Device[MAX_DEVICES],
    /** Whether what was on the ports at start has all been found. */
    settled : bool,
    port : slop_os.Port,
    clients : service_kit.Clients,
    client_state : Client[service_kit.MAX_CLIENTS],
}

/**
 * Drive a USB host controller, xHCI: find its devices, tell the supervisor of their interfaces, and serve each to its
 * class driver, until the system stops. It's started by the supervisor, for a controller the platform service gave it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The controller, for its MSI-X or MSI.
 * @param config The controller's 4 KiB of configuration space, mapped to turn bus mastering and its interrupts on.
 * @param bar0 BAR 0's memory, its registers, which it has to have.
 * @param bar1 BAR 1's memory, if the controller has it.
 * @param bar2 BAR 2's memory, if it has it.
 * @param bar3 BAR 3's memory, if it has it.
 * @param bar4 BAR 4's memory, if it has it.
 * @param bar5 BAR 5's memory, if it has it.
 * @param domain The DMA domain the controller is attached to, which its rings, contexts and buffers are made in.
 * @param clients The listener the supervisor's Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had, 2 if config or BAR 0 couldn't be
 *     mapped, 3 if its memory couldn't be made or mapped or is past 4 GiB for a controller that can't reach it, 4 if
 *     the firmware didn't let it go or it didn't stop, reset or start, 6 if no port could be made, 7 if its interrupt
 *     couldn't be set up, 9 if the listener couldn't be bound.
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
    clients : os.Listener[usb_bus.UsbBus]
) -> int {
    startup :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.domain = domain
    for i in 0..<driver.devices.count {
        driver.devices[i].parent = NONE
    }
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    if bars[0] == 0 {
        return 2
    }
    driver.registers = bars[0]
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER)

    capabilities :: read_u32(driver.registers, HCCPARAMS1)
    structure :: read_u32(driver.registers, HCSPARAMS1)
    driver.operational = driver.registers + cast[u64](read_u32(driver.registers, CAPLENGTH) & 0xff)
    driver.runtime_registers = driver.registers + cast[u64](read_u32(driver.registers, RTSOFF) & ~cast[u32](0x1f))
    driver.doorbells = driver.registers + cast[u64](read_u32(driver.registers, DBOFF) & ~cast[u32](3))
    driver.wide = capabilities & HCC_64_BIT != 0
    driver.context_bytes = if capabilities & HCC_CONTEXT_64 != 0 { cast[u64](64) } else { cast[u64](32) }
    driver.port_count = (structure >> 24) & 0xff
    if driver.port_count > MAX_PORTS {
        driver.port_count = MAX_PORTS
    }
    if !extended_capabilities(driver, capabilities) || !reset_controller(driver) {
        return 4
    }

    bytes :: MEMORY_PAGES * PAGE
    memory :: slop_os.dma_memory_create(domain, startup.budget, bytes, 0) or_return 3
    driver.memory_at = map_memory(memory, bytes) or_return 3
    driver.memory_device = slop_os.memory_device_address(memory) or_return 3
    if !reachable(driver, driver.memory_device, bytes) || !scratchpads(driver) {
        return 3
    }
    driver.commands = Ring.{
        entries = driver.memory_at + COMMAND_PAGE * PAGE,
        device = driver.memory_device + COMMAND_PAGE * PAGE,
        cycle = 1,
    }
    driver.events = Ring.{
        entries = driver.memory_at + EVENT_PAGE * PAGE,
        device = driver.memory_device + EVENT_PAGE * PAGE,
        cycle = 1,
    }

    driver.port = slop_os.port_create(startup.budget) or_return 6
    _ = service_kit.watch_stop(driver.port)
    irq :: slop_os.irq_create_msi(device, startup.budget) or_return 7
    message :: slop_os.irq_message(irq) or_return 7
    match pci.find_msix(config_at, bars) {
        case Some(found) => {
            msix := found
            if !pci.set_msix_entry(&msix, 0, message.address, message.data) {
                return 7
            }
            pci.enable_msix(config_at, &msix)
        }
        case None => {
            if !pci.enable_msi(config_at, message.address, message.data) {
                return 7
            }
        }
    }
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent)
        or_return 7
    if !start_controller(driver, capabilities) {
        return 4
    }

    // What's on the ports now, each found and, through hubs, what's behind them
    for port in 1..=driver.port_count {
        check_port(driver, port)
    }
    driver.port_changes = 0
    driver.settled = true
    found := cast[usize](0)
    for each in driver.devices {
        if each.used && !each.hub {
            found += 1
        }
    }
    runtime.log_info("serving % ports, % devices found", driver.port_count, found)

    match service_kit.add_client_index(&driver.clients, driver.port, clients.end) {
        case Some(index) => set_client(driver, index, .Bus, NONE, NONE)
        case None => return 9
    }
    loop {
        // The interrupt's acknowledged before the events are taken, so one that comes after interrupts again
        write_u32(driver.runtime_registers, IMAN, IMAN_PENDING | IMAN_ENABLE)
        write_u32(driver.operational, USBSTS, STS_EVENT)
        take_events(driver)
        with {
            i : usize = 0
        }
        loop {
            serve(driver, i)
            i += 1
        }
        while i < driver.clients.count
        watch_ports(driver)
        tell_bus(driver)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

// ---- The controller

/**
 * Read the extended capabilities: take the controller from the firmware (USB Legacy Support), and note which ports
 * are USB 3's (Supported Protocol).
 *
 * @param driver The driver, whose usb3 is set.
 * @param capabilities HCCPARAMS1, whose xECP (bits 31:16) is where the list starts, in dwords.
 * @return False if the firmware didn't let the controller go within CONTROLLER_WAIT; true otherwise.
 */
extended_capabilities :: fn(driver : ptr[mut Driver], capabilities : u32) -> bool {
    at := cast[u64](capabilities >> 16) * 4
    for step in 0..<64 {
        if at == 0 || at >= 0x10000 {
            break
        }
        header :: read_u32(driver.registers, at)
        id :: header & 0xff
        if id == EXTENDED_LEGACY && header & LEGACY_BIOS != 0 {
            write_u32(driver.registers, at, header | LEGACY_OS)
            if !wait_for(driver.registers + at, LEGACY_BIOS, 0, CONTROLLER_WAIT) {
                return false
            }
        }
        if id == EXTENDED_PROTOCOL && header >> 24 == 3 {
            ports :: read_u32(driver.registers, at + 8)
            first :: ports & 0xff
            count :: (ports >> 8) & 0xff
            for port in first..<(first + count) {
                if port >= 1 && port <= MAX_PORTS {
                    driver.usb3 |= cast[u64](1) << cast[u64](port - 1)
                }
            }
        }
        next :: cast[u64]((header >> 8) & 0xff) * 4
        if next == 0 {
            break
        }
        at += next
    }
    return true
}

/**
 * Stop the controller and reset it (§4.22.1).
 *
 * @param driver The driver, whose operational registers are written.
 * @return True once it's reset and ready; false if it didn't halt, reset or become ready within CONTROLLER_WAIT.
 */
reset_controller :: fn(driver : ptr[Driver]) -> bool {
    write_u32(driver.operational, USBCMD, read_u32(driver.operational, USBCMD) & ~CMD_RUN)
    if !wait_for(driver.operational + USBSTS, STS_HALTED, STS_HALTED, CONTROLLER_WAIT) {
        return false
    }
    write_u32(driver.operational, USBCMD, CMD_RESET)
    return wait_for(driver.operational + USBCMD, CMD_RESET, 0, CONTROLLER_WAIT)
        && wait_for(driver.operational + USBSTS, STS_NOT_READY, 0, CONTROLLER_WAIT)
}

/**
 * Give the controller the scratchpad buffers it asks for, if any, their array in the DCBAA's entry 0.
 *
 * @param driver The driver, whose DCBAA is written.
 * @return True once they're given, or none are asked for; false if their memory couldn't be made or reached.
 */
scratchpads :: fn(driver : ptr[Driver]) -> bool {
    parameters :: read_u32(driver.registers, HCSPARAMS2)
    count :: cast[u64](((parameters >> 27) & 0x1f) | (((parameters >> 21) & 0x1f) << 5))
    if count == 0 {
        return true
    }
    if count > PAGE / 8 - 1 {
        return false
    }
    startup :: slop_os.startup_block()
    bytes :: (count + 1) * PAGE
    memory :: slop_os.dma_memory_create(driver.domain, startup.budget, bytes, 0) or_return false
    at :: map_memory(memory, bytes) or_return false
    device :: slop_os.memory_device_address(memory) or_return false
    if !reachable(driver, device, bytes) {
        return false
    }
    // The array's first page, then a page for each buffer
    for i in 0..<count {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](at + i * 8), device + (i + 1) * PAGE)
    }
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](driver.memory_at + DCBAA_PAGE * PAGE), device)
    return true
}

/**
 * Point the controller at its DCBAA, command ring and event ring, turn its interrupter on, and start it.
 *
 * @param driver The driver, whose memory holds them.
 * @param capabilities HCCPARAMS1, for whether ports need power.
 * @return True once it's running; false if it didn't start within CONTROLLER_WAIT.
 */
start_controller :: fn(driver : ptr[Driver], capabilities : u32) -> bool {
    slots :: read_u32(driver.registers, HCSPARAMS1) & 0xff
    enabled :: if slots < cast[u32](MAX_DEVICES) { slots } else { cast[u32](MAX_DEVICES) }
    write_u32(driver.operational, CONFIG, enabled)
    write_u64(driver.operational, DCBAAP, driver.memory_device + DCBAA_PAGE * PAGE)
    write_u64(driver.operational, CRCR, driver.commands.device | 1)
    // The event ring: one segment, its table's one entry
    table :: driver.memory_at + ERST_PAGE * PAGE
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](table), driver.events.device)
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](table + 8), RING_TRBS)
    write_u32(driver.runtime_registers, ERSTSZ, 1)
    write_u64(driver.runtime_registers, ERDP, driver.events.device)
    write_u64(driver.runtime_registers, ERSTBA, driver.memory_device + ERST_PAGE * PAGE)
    // 40 µs between interrupts at least, in 250 ns
    write_u32(driver.runtime_registers, IMOD, 160)
    write_u32(driver.runtime_registers, IMAN, IMAN_PENDING | IMAN_ENABLE)
    write_u32(driver.operational, USBCMD, CMD_RUN | CMD_INTERRUPTS)
    if !wait_for(driver.operational + USBSTS, STS_HALTED, 0, CONTROLLER_WAIT) {
        return false
    }
    if capabilities & HCC_PORT_POWER != 0 {
        powered := false
        for port in 1..=driver.port_count {
            status :: read_port(driver, port)
            if status & PORT_POWER == 0 {
                write_port(driver, port, (status & PORT_KEEP) | PORT_POWER)
                powered = true
            }
        }
        if powered {
            pause(20_000_000)
        }
    }
    return true
}

// ---- Rings, events and commands

/**
 * Put a TRB on a ring the driver fills, the link back to its start first where it's at its last TRB.
 *
 * @param ring The ring, whose index and cycle move on.
 * @param parameter The TRB's parameter.
 * @param status Its status.
 * @param control Its control, without its cycle bit, which the ring's is put in.
 * @param chained Whether the TRB before it is chained to it (CH), so a link between them carries the chain.
 * @return Where the TRB is, to the controller, as an event names it.
 */
enqueue :: fn(ring : ptr[mut Ring], parameter : u64, status : u32, control : u32, chained : bool = false) -> u64 {
    if ring.index >= RING_TRBS - 1 {
        // Inside a TD (the TRB before had CH), the link has CH too, as §4.11.5.1 has it
        chain :: if chained { TRB_CHAIN } else { cast[u32](0) }
        write_trb(ring.entries + cast[u64](ring.index) * TRB_BYTES, ring.device, 0, (TRB_LINK << 10) | TRB_TOGGLE | chain | ring.cycle)
        ring.index = 0
        ring.cycle = ring.cycle ~ 1
    }
    at :: cast[u64](ring.index) * TRB_BYTES
    write_trb(ring.entries + at, parameter, status, control | ring.cycle)
    ring.index += 1
    return ring.device + at
}

/**
 * Write a TRB, its control last, so the controller never sees its cycle bit before the rest.
 *
 * @param at Where it is, through the driver's mapping.
 * @param parameter Its parameter.
 * @param status Its status.
 * @param control Its control, its cycle bit as it's to be.
 */
write_trb :: fn(at : u64, parameter : u64, status : u32, control : u32) {
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](at), parameter)
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](at + 8), status)
    intrinsics.fence_release()
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](at + 12), control)
}

/**
 * Where a ring's next TRB is, with its cycle bit, as Set TR Dequeue Pointer and a context's dequeue pointer take it.
 *
 * @param ring The ring.
 * @return Its next TRB's address to the controller, its cycle bit in bit 0.
 */
dequeue_of :: fn(ring : ptr[Ring]) -> u64 {
    return ring.device + cast[u64](ring.index) * TRB_BYTES | cast[u64](ring.cycle)
}

/**
 * Ring a doorbell.
 *
 * @param driver The driver.
 * @param slot The slot, or 0 for the command ring.
 * @param target The endpoint's DCI, or 0 for the command ring.
 */
ring_doorbell :: fn(driver : ptr[Driver], slot : u32, target : u32) {
    driver_kit.before_device_write()
    write_u32(driver.doorbells, cast[u64](slot) * 4, target)
}

/**
 * Take and handle every event the controller has written, and tell it where the event ring's been read to.
 *
 * @param driver The driver, whose command, transfers and ports change as the events say.
 */
take_events :: fn(driver : ptr[mut Driver]) {
    loop {
        at :: driver.events.entries + cast[u64](driver.events.index) * TRB_BYTES
        control :: intrinsics.volatile_load_u32(cast[ptr[u32]](at + 12))
        if control & TRB_CYCLE != driver.events.cycle {
            break
        }
        intrinsics.fence_acquire()
        parameter :: intrinsics.volatile_load_u64(cast[ptr[u64]](at))
        status :: intrinsics.volatile_load_u32(cast[ptr[u32]](at + 8))
        driver.events.index += 1
        if driver.events.index == RING_TRBS {
            driver.events.index = 0
            driver.events.cycle = driver.events.cycle ~ 1
        }
        kind :: (control >> 10) & 0x3f
        if kind == TRB_COMMAND_COMPLETION && parameter == driver.command_trb {
            driver.command_done = true
            driver.command_result = CommandResult.{code = status >> 24, slot = control >> 24}
        }
        else if kind == TRB_TRANSFER_EVENT {
            transferred(driver, control >> 24, (control >> 16) & 0x1f, status >> 24, status & 0xff_ffff, parameter)
        }
        else if kind == TRB_PORT_STATUS_CHANGE {
            port :: cast[u32]((parameter >> 24) & 0xff)
            if port >= 1 && port <= driver.port_count {
                driver.port_changes |= cast[u64](1) << cast[u64](port - 1)
            }
        }
    }
    // Always, EHB with it: events a polling loop took left it set, and while it's set the interrupter raises nothing
    write_u64(
        driver.runtime_registers,
        ERDP,
        (driver.events.device + cast[u64](driver.events.index) * TRB_BYTES) | ERDP_BUSY
    )
}

/**
 * Run a command and wait for its completion, taking the events that come meanwhile.
 *
 * @param driver The driver, whose command ring takes it.
 * @param parameter The command TRB's parameter.
 * @param control Its control: its type, slot and the rest, without its cycle bit.
 * @return What it completed with; null if it didn't within COMMAND_WAIT, when its late completion, if one comes, is
 *     passed over, as only the command waited for's is taken.
 */
command :: fn(driver : ptr[mut Driver], parameter : u64, control : u32) -> CommandResult? {
    driver.command_done = false
    driver.command_trb = enqueue(&driver.commands, parameter, 0, control)
    ring_doorbell(driver, 0, 0)
    deadline :: (slop_os.clock_monotonic() or_else 0) + COMMAND_WAIT
    loop {
        take_events(driver)
        if driver.command_done {
            return driver.command_result
        }
        if (slop_os.clock_monotonic() or_else deadline) >= deadline {
            return null
        }
        intrinsics.spin_hint()
    }
}

/**
 * Run a command, and tell whether it succeeded.
 *
 * @param driver The driver.
 * @param parameter The command TRB's parameter.
 * @param control Its control.
 * @return True if it completed with success.
 */
succeeds :: fn(driver : ptr[mut Driver], parameter : u64, control : u32) -> bool {
    done :: command(driver, parameter, control) or_return false
    return done.code == CODE_SUCCESS
}

/**
 * Handle a transfer event: the transfer in flight on its endpoint finished, or a control transfer's data stage did.
 *
 * @param driver The driver, whose endpoint's transfer is answered or noted.
 * @param slot The event's slot.
 * @param dci The endpoint's DCI.
 * @param code Its completion code.
 * @param residue The bytes of its TRB not moved.
 * @param trb Its TRB, to the controller.
 */
transferred :: fn(driver : ptr[mut Driver], slot : u32, dci : u32, code : u32, residue : u32, trb : u64) {
    index :: device_of_slot(driver, slot) or_return void
    if index >= driver.devices.count {
        return void
    }
    device :: &driver.devices[index]
    endpoint :: endpoint_of(device, dci) or_return void
    if !endpoint.busy {
        return void
    }
    ok :: code == CODE_SUCCESS || code == CODE_SHORT
    // Bytes moved by the TRB the event's for: the first data TRB's, or all of them for the last
    moved :: if trb == endpoint.first_trb {
        endpoint.first_bytes - smaller(residue, endpoint.first_bytes)
    }
    else {
        endpoint.bytes - smaller(residue, endpoint.bytes)
    }
    if ok && endpoint.control {
        // A control transfer's data stage ended, short or not; its status stage's event ends it
        if endpoint.first_trb != 0 && (trb == endpoint.first_trb || trb != endpoint.status_trb) {
            endpoint.moved = moved
            return void
        }
        end_transfer(driver, index, endpoint, .Done, endpoint.moved)
        return void
    }
    if !ok {
        endpoint.halted = true
    }
    end_transfer(driver, index, endpoint, status_of(code), if ok { moved } else { cast[u32](0) })
}

/**
 * A completion code as the USB device protocol's status.
 *
 * @param code The completion code.
 * @return Done for success or a short packet, Stalled for a stall, DeviceError for the rest.
 */
status_of :: fn(code : u32) -> usb_device.Status {
    if code == CODE_SUCCESS || code == CODE_SHORT {
        return .Done
    }
    if code == CODE_STALL {
        return .Stalled
    }
    return .DeviceError
}

/**
 * End an endpoint's transfer: the driver's own is noted, a client's answered unless it's left.
 *
 * @param driver The driver.
 * @param device The device's index.
 * @param endpoint The endpoint, busy.
 * @param status How it went.
 * @param moved The bytes moved.
 */
end_transfer :: fn(driver : ptr[mut Driver], device : usize, endpoint : ptr[mut Endpoint], status : usb_device.Status, moved : u32) {
    endpoint.busy = false
    if endpoint.own {
        endpoint.own_done = true
        endpoint.own_code = cast[u32](status)
        endpoint.moved = moved
        if device < driver.devices.count && driver.devices[device].hub && endpoint.dci != 1 && status == .Done {
            // A hub's status change endpoint: the ports whose bits are set, from bit 1
            changes :: intrinsics.volatile_load_u32(
                cast[ptr[u32]](driver.devices[device].memory_at + DATA_PAGE * PAGE + HUB_STATUS_OFFSET)
            )
            driver.devices[device].hub_changes |= changes
        }
        return void
    }
    answer_client(driver, endpoint.client, endpoint.generation, endpoint.memory, endpoint.tag, status, moved)
}

/**
 * Answer a client's transfer, if it's the same client still; one that's left lets its buffer go once nothing else has it.
 *
 * @param driver The driver.
 * @param client The client's index.
 * @param generation Its place's generation when it asked.
 * @param memory Its buffer then.
 * @param tag Its tag.
 * @param status How it went.
 * @param moved The bytes moved.
 */
answer_client :: fn(
    driver : ptr[mut Driver],
    client : usize,
    generation : u32,
    memory : slop_os.Memory,
    tag : u64,
    status : usb_device.Status,
    moved : u32
) {
    if client < driver.client_state.count && driver.client_state[client].generation == generation
        && client < driver.clients.ends.count {
        end :: driver.clients.ends[client]
        if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
            answer(driver, end, finished(tag, status, moved))
        }
        return void
    }
    release_buffer(driver, memory)
}

// ---- Ports and devices

/**
 * Look at a root port: a device that's come is reset if it has to be and found, one that's gone is let go.
 *
 * @param driver The driver.
 * @param port The port, 1 to port_count.
 */
check_port :: fn(driver : ptr[mut Driver], port : u32) {
    status :: read_port(driver, port)
    write_port(driver, port, (status & PORT_KEEP) | (status & PORT_CHANGES))
    there :: device_on(driver, NONE, port)
    if status & PORT_CONNECTED == 0 {
        match there {
            case Some(index) => detach(driver, index)
            case None => {}
        }
        return void
    }
    // Connected still, but a connection changed: the device there was unplugged and another plugged in
    if there is_some && status & PORT_CONNECT_CHANGE != 0 {
        match there {
            case Some(index) => detach(driver, index)
            case None => {}
        }
    }
    else if there is_some {
        return void
    }
    usb3 :: port <= MAX_PORTS && (driver.usb3 >> cast[u64](port - 1)) & 1 != 0
    if usb3 {
        _ = wait_for(driver.operational + PORT_REGISTERS + cast[u64](port - 1) * 16, PORT_ENABLED, PORT_ENABLED, LINK_WAIT)
    }
    if read_port(driver, port) & PORT_ENABLED == 0 {
        now :: read_port(driver, port)
        write_port(driver, port, (now & PORT_KEEP) | PORT_RESET)
        if !wait_for(driver.operational + PORT_REGISTERS + cast[u64](port - 1) * 16, PORT_RESET_CHANGE, PORT_RESET_CHANGE, RESET_WAIT) {
            return void
        }
        after :: read_port(driver, port)
        write_port(driver, port, (after & PORT_KEEP) | (after & PORT_CHANGES))
        pause(RESET_RECOVERY)
    }
    enabled :: read_port(driver, port)
    if enabled & PORT_ENABLED == 0 {
        return void
    }
    _ = enumerate(driver, (enabled >> 10) & 0xf, port, 0, 0, NONE, 0)
}

/**
 * Look at the ports a status change came for, the controller's and each hub's.
 *
 * @param driver The driver, whose port_changes and hubs' hub_changes are cleared as they're looked at.
 */
watch_ports :: fn(driver : ptr[mut Driver]) {
    for step in 0..<8 {
        changes :: driver.port_changes
        driver.port_changes = 0
        for port in 1..=driver.port_count {
            if (changes >> cast[u64](port - 1)) & 1 != 0 {
                check_port(driver, port)
            }
        }
        hubs_changed := false
        for i in 0..<driver.devices.count {
            if !driver.devices[i].used || driver.devices[i].gone || !driver.devices[i].hub {
                continue
            }
            hub_changes :: driver.devices[i].hub_changes
            driver.devices[i].hub_changes = 0
            for port in 1..=driver.devices[i].hub_ports {
                if (hub_changes >> port) & 1 != 0 {
                    check_hub_port(driver, i, port)
                    hubs_changed = true
                }
            }
            watch_hub(driver, i)
        }
        if driver.port_changes == 0 && !hubs_changed {
            break
        }
    }
    // The default endpoints a stall halted, reset for the next control transfer
    for i in 0..<driver.devices.count {
        if driver.devices[i].used && !driver.devices[i].gone && driver.devices[i].control.halted
            && !driver.devices[i].control.busy {
            _ = reset_ring(driver, i, &driver.devices[i].control)
        }
    }
}

/**
 * Find the device on a port: a root port, or a hub's.
 *
 * @param driver The driver.
 * @param parent The hub's index, or NONE for a root port.
 * @param port The port.
 * @return The device's index; null if none's there.
 */
device_on :: fn(driver : ptr[Driver], parent : usize, port : u32) -> usize? {
    for each, i in driver.devices {
        if each.used && !each.gone && each.parent == parent && (if parent == NONE { each.depth == 0 && each.root_port == port } else { each.parent_port == port }) {
            return i
        }
    }
    return null
}

/**
 * Find a device by its slot.
 *
 * @param driver The driver.
 * @param slot The slot.
 * @return Its index; null if no device the driver keeps has it.
 */
device_of_slot :: fn(driver : ptr[Driver], slot : u32) -> usize? {
    for each, i in driver.devices {
        if each.used && !each.gone && each.slot == slot {
            return i
        }
    }
    return null
}

/**
 * Find a device's endpoint by its DCI.
 *
 * @param device The device.
 * @param dci The DCI.
 * @return The endpoint; null if the device has none with it.
 */
endpoint_of :: fn(device : ptr[mut Device], dci : u32) -> ptr[mut Endpoint]? {
    if dci == 1 {
        return &device.control
    }
    for i in 0..<device.endpoints.count {
        if i < device.endpoint_count && device.endpoints[i].dci == dci {
            return &device.endpoints[i]
        }
    }
    return null
}

/**
 * Address a device that's come, read its descriptors, configure it, and either watch its ports, a hub's, or make its
 * interfaces' connections, for the supervisor's Attached.
 *
 * @param driver The driver.
 * @param speed Its speed, xHCI's ID.
 * @param root_port The root port it's on, or behind.
 * @param route Its route string.
 * @param depth Its tier: 0 on a root port.
 * @param parent The hub it's behind, by index, or NONE.
 * @param parent_port That hub's port.
 * @return Its index; null if there's no room for it, or it couldn't be addressed, read or configured, in which case
 *     its slot is given back.
 */
enumerate :: fn(
    driver : ptr[mut Driver],
    speed : u32,
    root_port : u32,
    route : u32,
    depth : u32,
    parent : usize,
    parent_port : u32
) -> usize? {
    startup :: slop_os.startup_block()
    index := NONE
    for each, i in driver.devices {
        if !each.used {
            index = i
            break
        }
    }
    if index >= driver.devices.count {
        runtime.log_info("no room for a device on port %", root_port)
        return null
    }
    enabled :: command(driver, 0, TRB_ENABLE_SLOT << 10) or_return null
    if enabled.code != CODE_SUCCESS {
        return null
    }
    bytes :: DEVICE_PAGES * PAGE
    disable :: (TRB_DISABLE_SLOT << 10) | (enabled.slot << 24)
    memory :: match slop_os.dma_memory_create(driver.domain, startup.budget, bytes, 0) {
        case Ok(made) => made
        case Error(error) => {
            _ = command(driver, 0, disable)
            return null
        }
    }
    at := cast[u64](0)
    device_address := cast[u64](0)
    match map_memory(memory, bytes) {
        case Some(mapped) => at = mapped
        case None => {}
    }
    match slop_os.memory_device_address(memory) {
        case Ok(address) => device_address = address
        case Error(error) => {}
    }
    if at == 0 || device_address == 0 {
        _ = command(driver, 0, disable)
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return null
    }
    driver.devices[index] = Device.{
        used = true,
        slot = enabled.slot,
        speed = speed,
        route = route,
        root_port = root_port,
        depth = depth,
        parent = parent,
        parent_port = parent_port,
        memory = memory,
        memory_at = at,
        memory_device = device_address,
    }
    device :: &driver.devices[index]
    device.control = Endpoint.{dci = 1, interface = NONE, ring = ring_at(device, CONTROL_RING_PAGE)}
    if parent < driver.devices.count {
        hub :: &driver.devices[parent]
        if (speed == SPEED_FULL || speed == SPEED_LOW) && hub.speed == SPEED_HIGH {
            device.tt_slot = hub.slot
            device.tt_port = parent_port
        }
        else {
            device.tt_slot = hub.tt_slot
            device.tt_port = hub.tt_port
        }
    }
    if !reachable(driver, device_address, bytes) || !set_up(driver, index) {
        runtime.log_info("a device on port % couldn't be set up", root_port)
        release_device(driver, index)
        return null
    }
    return index
}

/**
 * Address, read and configure a device just given a slot (§4.3).
 *
 * @param driver The driver.
 * @param index The device's index, its slot and memory set.
 * @return True once it's configured and its ports or interfaces are set up; false if a step failed.
 */
set_up :: fn(driver : ptr[mut Driver], index : usize) -> bool {
    if index >= driver.devices.count {
        return false
    }
    device :: &driver.devices[index]
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](driver.memory_at + DCBAA_PAGE * PAGE + cast[u64](device.slot) * 8), device.memory_device + OUTPUT_PAGE * PAGE)
    // The default endpoint's first packet size, until the device's descriptor says
    packet := if device.speed >= SPEED_SUPER { cast[u32](512) } else if device.speed == SPEED_LOW { cast[u32](8) } else { cast[u32](64) }
    clear_input(driver, device)
    set_input(driver, device, 0, 0, 0b11)
    write_slot_context(driver, device, 1)
    write_control_context(driver, device, packet)
    if !succeeds(driver, device.memory_device + INPUT_PAGE * PAGE, (TRB_ADDRESS_DEVICE << 10) | (device.slot << 24)) {
        return false
    }
    data :: device.memory_at + DATA_PAGE * PAGE
    get_descriptor(driver, index, DESCRIPTOR_DEVICE << 8, 8) or_return false
    given :: cast[u32](byte_at(data, 7))
    real_packet :: if device.speed >= SPEED_SUPER { cast[u32](1) << smaller(given, 15) } else { given }
    if real_packet != packet && real_packet >= 8 {
        packet = real_packet
        clear_input(driver, device)
        set_input(driver, device, 0, 0, 0b10)
        write_control_context(driver, device, packet)
        if !succeeds(driver, device.memory_device + INPUT_PAGE * PAGE, (TRB_EVALUATE_CONTEXT << 10) | (device.slot << 24)) {
            return false
        }
    }
    if (get_descriptor(driver, index, DESCRIPTOR_DEVICE << 8, 18) or_else 0) < 18 {
        return false
    }
    device.vendor = word_at(data, 8)
    device.product = word_at(data, 10)
    device_class :: byte_at(data, 4)
    if (get_descriptor(driver, index, DESCRIPTOR_CONFIGURATION << 8, 9) or_else 0) < 9 {
        return false
    }
    total :: smaller(cast[u32](word_at(data, 2)), cast[u32](HUB_STATUS_OFFSET))
    configuration :: byte_at(data, 5)
    got :: get_descriptor(driver, index, DESCRIPTOR_CONFIGURATION << 8, cast[u16](total)) or_return false
    parse_configuration(device, data, got)
    device.hub = device_class == CLASS_HUB
        || (device.interface_count > 0 && device.interfaces[0].class == CLASS_HUB)
    good_after := cast[u64](0)
    if device.hub {
        // The hub descriptor (§11.23.2.1): its ports (byte 2), its power-on-to-good time in 2 ms (byte 5)
        got_hub :: own_control(driver, index, 0xa0, REQUEST_GET_DESCRIPTOR, DESCRIPTOR_HUB << 8, 0, 9) or_return false
        if got_hub < 7 || device.depth + 1 > MAX_DEPTH {
            return false
        }
        device.hub_ports = smaller(cast[u32](byte_at(data, 2)), MAX_HUB_PORTS)
        good_after = cast[u64](byte_at(data, 5)) * 2_000_000
    }
    if !configure_endpoints(driver, index) {
        return false
    }
    own_control(driver, index, 0x00, REQUEST_SET_CONFIGURATION, cast[u16](configuration), 0, 0) or_return false
    if device.hub {
        for port in 1..=device.hub_ports {
            _ = own_control(driver, index, 0x23, REQUEST_SET_FEATURE, HUB_PORT_POWER, cast[u16](port), 0)
        }
        pause(good_after + 20_000_000)
        runtime.log_info("a hub of %1 ports on port %2%3", device.hub_ports, device.root_port, tier_text(device.depth))
        for port in 1..=device.hub_ports {
            check_hub_port(driver, index, port)
        }
        watch_hub(driver, index)
        return true
    }
    startup :: slop_os.startup_block()
    for i in 0..<device.interfaces.count {
        if i >= device.interface_count {
            break
        }
        pair :: os.channel_for[usb_device.UsbDevice](startup.budget, 0) or_return false
        match service_kit.add_client_index(&driver.clients, driver.port, pair.a) {
            case Some(client) => {
                set_client(driver, client, .Interface, index, i)
                device.interfaces[i].peer = pair.b
            }
            case None => {
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
                _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
                device.interfaces[i].gone_told = true
                device.interfaces[i].announced = true
            }
        }
        runtime.log_info(
            "%1:%2 on port %3%4: interface %5, class %6, subclass %7, protocol %8",
            device.vendor,
            device.product,
            device.root_port,
            tier_text(device.depth),
            device.interfaces[i].number,
            device.interfaces[i].class,
            device.interfaces[i].subclass,
            device.interfaces[i].protocol
        )
    }
    return true
}

/**
 * Say how deep a device is, for a log line.
 *
 * @param depth Its tier.
 * @return Nothing for a root port's, ", behind a hub" otherwise.
 */
tier_text :: fn(depth : u32) -> string {
    return if depth == 0 { "" } else { ", behind a hub" }
}

/**
 * Note a configuration descriptor's interfaces (their first alternate settings) and their endpoints, as many as the
 * driver keeps.
 *
 * @param device The device, whose interfaces and endpoints are set.
 * @param data Where the descriptor is, through the driver's mapping.
 * @param bytes How many of its bytes were read.
 */
parse_configuration :: fn(device : ptr[mut Device], data : u64, bytes : u32) {
    at := cast[u32](0)
    current := NONE
    for step in 0..<256 {
        if at + 2 > bytes {
            break
        }
        length :: cast[u32](byte_at(data, cast[u64](at)))
        kind :: byte_at(data, cast[u64](at) + 1)
        if length < 2 || at + length > bytes {
            break
        }
        here :: cast[u64](at)
        if kind == DESCRIPTOR_INTERFACE && length >= 9 {
            current = NONE
            if byte_at(data, here + 3) == 0 && device.interface_count < device.interfaces.count {
                current = device.interface_count
                device.interfaces[current] = Interface.{
                    number = byte_at(data, here + 2),
                    class = byte_at(data, here + 5),
                    subclass = byte_at(data, here + 6),
                    protocol = byte_at(data, here + 7),
                    peer = cast[slop_os.Channel](slop_os.NO_HANDLE),
                }
                device.interface_count += 1
            }
        }
        else if kind == DESCRIPTOR_ENDPOINT && length >= 7 && current != NONE
            && device.endpoint_count < device.endpoints.count {
            address :: byte_at(data, here + 2)
            slot :: device.endpoint_count
            if slot >= device.endpoints.count {
                break
            }
            if address & 0xf == 0 {
                at += length
                continue
            }
            device.endpoints[slot] = Endpoint.{
                dci = cast[u32](address & 0xf) * 2 + (if address & 0x80 != 0 { cast[u32](1) } else { cast[u32](0) }),
                address = address,
                kind = cast[usb_device.EndpointKind](byte_at(data, here + 3) & 3),
                max_packet = word_at(data, here + 4) & 0x7ff,
                interval = byte_at(data, here + 6),
                interface = current,
                ring = ring_at(device, RINGS_PAGE + cast[u64](slot)),
            }
            device.endpoint_count += 1
        }
        at += length
    }
}

/**
 * Add a device's endpoints to its slot, its slot context updated: its context entries, and a hub's ports (§4.6.6).
 *
 * @param driver The driver.
 * @param index The device's index, its endpoints noted.
 * @return True if the controller took them.
 */
configure_endpoints :: fn(driver : ptr[mut Driver], index : usize) -> bool {
    if index >= driver.devices.count {
        return false
    }
    device :: &driver.devices[index]
    clear_input(driver, device)
    adds := cast[u32](1)
    last := cast[u32](1)
    for i in 0..<device.endpoints.count {
        if i >= device.endpoint_count {
            break
        }
        endpoint :: device.endpoints[i]
        if endpoint.kind == .Isochronous || endpoint.kind == .Control {
            continue
        }
        adds |= cast[u32](1) << endpoint.dci
        last = larger(last, endpoint.dci)
        write_endpoint_context(driver, device, &device.endpoints[i])
    }
    if adds == 1 && !device.hub {
        return true
    }
    set_input(driver, device, 0, 0, adds)
    write_slot_context(driver, device, last)
    return succeeds(driver, device.memory_device + INPUT_PAGE * PAGE, (TRB_CONFIGURE_ENDPOINT << 10) | (device.slot << 24))
}

/**
 * Look at a hub's port: a device that's come is reset and found, one that's gone let go, its change bits cleared.
 *
 * @param driver The driver.
 * @param hub The hub's index.
 * @param port The port, 1 to its hub_ports.
 */
check_hub_port :: fn(driver : ptr[mut Driver], hub : usize, port : u32) {
    if hub >= driver.devices.count {
        return void
    }
    status := hub_port_status(driver, hub, port) or_return void
    clear_hub_changes(driver, hub, port, status)
    there :: device_on(driver, hub, port)
    if status & HUB_CONNECTED == 0 {
        match there {
            case Some(index) => detach(driver, index)
            case None => {}
        }
        return void
    }
    // Connected still, but its connection changed (C_PORT_CONNECTION): another device is there now
    if there is_some && (status >> 16) & HUB_CONNECTED != 0 {
        match there {
            case Some(index) => detach(driver, index)
            case None => {}
        }
    }
    else if there is_some {
        return void
    }
    _ = own_control(driver, hub, 0x23, REQUEST_SET_FEATURE, HUB_PORT_RESET, cast[u16](port), 0)
    deadline :: (slop_os.clock_monotonic() or_else 0) + RESET_WAIT
    loop {
        pause(HUB_POLL)
        status = hub_port_status(driver, hub, port) or_return void
        if (status >> 16) & HUB_RESET_CHANGE != 0 {
            break
        }
        if (slop_os.clock_monotonic() or_else deadline) >= deadline {
            return void
        }
    }
    clear_hub_changes(driver, hub, port, status)
    if status & HUB_ENABLED == 0 {
        return void
    }
    pause(RESET_RECOVERY)
    speed :: if status & HUB_LOW_SPEED != 0 { SPEED_LOW } else if status & HUB_HIGH_SPEED != 0 { SPEED_HIGH } else { SPEED_FULL }
    parent :: driver.devices[hub]
    route :: parent.route | (smaller(port, 15) << (4 * parent.depth))
    _ = enumerate(driver, speed, parent.root_port, route, parent.depth + 1, hub, port)
}

/**
 * Read a hub port's status (GET_STATUS, §11.24.2.7).
 *
 * @param driver The driver.
 * @param hub The hub's index.
 * @param port The port.
 * @return Its status in bits 15:0 and its changes in 31:16; null if the hub didn't answer.
 */
hub_port_status :: fn(driver : ptr[mut Driver], hub : usize, port : u32) -> u32? {
    if hub >= driver.devices.count {
        return null
    }
    got :: own_control(driver, hub, 0xa3, REQUEST_GET_STATUS, 0, cast[u16](port), 4) or_return null
    if got < 4 {
        return null
    }
    return intrinsics.volatile_load_u32(cast[ptr[u32]](driver.devices[hub].memory_at + DATA_PAGE * PAGE))
}

/**
 * Clear a hub port's change bits that are set (CLEAR_FEATURE C_PORT_CONNECTION to C_PORT_RESET).
 *
 * @param driver The driver.
 * @param hub The hub's index.
 * @param port The port.
 * @param status Its status and changes, as hub_port_status gave them.
 */
clear_hub_changes :: fn(driver : ptr[mut Driver], hub : usize, port : u32, status : u32) {
    for bit in 0..<5 {
        if (status >> (16 + cast[u32](bit))) & 1 != 0 {
            _ = own_control(driver, hub, 0x23, REQUEST_CLEAR_FEATURE, HUB_CHANGE_FEATURES + cast[u16](bit), cast[u16](port), 0)
        }
    }
}

/**
 * Keep a transfer waiting on a hub's status change endpoint, so its ports' changes come as events.
 *
 * @param driver The driver.
 * @param hub The hub's index; one without an interrupt IN endpoint, or with one in flight or halted, is left.
 */
watch_hub :: fn(driver : ptr[mut Driver], hub : usize) {
    if hub >= driver.devices.count {
        return void
    }
    device :: &driver.devices[hub]
    for i in 0..<device.endpoints.count {
        if i >= device.endpoint_count {
            break
        }
        endpoint :: &device.endpoints[i]
        if endpoint.kind != .Interrupt || endpoint.address & 0x80 == 0 || endpoint.busy {
            continue
        }
        if endpoint.halted && !reset_ring(driver, hub, endpoint) {
            return void
        }
        bytes :: smaller(cast[u32](endpoint.max_packet), 4)
        intrinsics.volatile_store_u32(cast[ptr[mut u32]](device.memory_at + DATA_PAGE * PAGE + HUB_STATUS_OFFSET), 0)
        endpoint.own = true
        endpoint.own_done = false
        start_normal(driver, device, endpoint, device.memory_device + DATA_PAGE * PAGE + HUB_STATUS_OFFSET, bytes)
        return void
    }
}

/**
 * Let a device that's gone go, and those behind it if it's a hub: its slot disabled, its transfers answered Gone,
 * its clients closed, and its interfaces left to be Detached.
 *
 * @param driver The driver.
 * @param index The device's index.
 */
detach :: fn(driver : ptr[mut Driver], index : usize) {
    if index >= driver.devices.count {
        return void
    }
    for i in 0..<driver.devices.count {
        if driver.devices[i].used && !driver.devices[i].gone && driver.devices[i].parent == index {
            detach(driver, i)
        }
    }
    device :: &driver.devices[index]
    runtime.log_info("%1:%2 on port %3%4 is gone", device.vendor, device.product, device.root_port, tier_text(device.depth))
    _ = command(driver, 0, (TRB_DISABLE_SLOT << 10) | (device.slot << 24))
    device.gone = true
    if device.control.busy {
        end_transfer(driver, index, &device.control, .Gone, 0)
    }
    for i in 0..<device.endpoints.count {
        if device.endpoints[i].busy {
            end_transfer(driver, index, &device.endpoints[i], .Gone, 0)
        }
    }
    for client in 0..<driver.client_state.count {
        state :: &driver.client_state[client]
        if state.kind == .Interface && state.device == index {
            drop(driver, client)
        }
    }
    release_device(driver, index)
}

/**
 * Give back a device's slot and memory; its place is freed once nothing's left to tell of it.
 *
 * @param driver The driver.
 * @param index The device's index.
 */
release_device :: fn(driver : ptr[mut Driver], index : usize) {
    if index >= driver.devices.count {
        return void
    }
    device :: &driver.devices[index]
    if !device.gone {
        _ = command(driver, 0, (TRB_DISABLE_SLOT << 10) | (device.slot << 24))
        device.gone = true
    }
    intrinsics.volatile_store_u64(cast[ptr[mut u64]](driver.memory_at + DCBAA_PAGE * PAGE + cast[u64](device.slot) * 8), 0)
    for i in 0..<device.interfaces.count {
        each :: &device.interfaces[i]
        if cast[slop_os.Handle](each.peer) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](each.peer))
            each.peer = cast[slop_os.Channel](slop_os.NO_HANDLE)
        }
        if !each.announced {
            each.gone_told = true
        }
    }
    // The memory goes once the controller can't touch it: its slot's disabled
    _ = slop_os.handle_close(cast[slop_os.Handle](device.memory))
    device.memory = cast[slop_os.Memory](slop_os.NO_HANDLE)
    free_if_told(device)
}

/**
 * Free a gone device's place once each of its interfaces has been Detached, or never Attached.
 *
 * @param device The device.
 */
free_if_told :: fn(device : ptr[mut Device]) {
    if !device.gone {
        return void
    }
    for i in 0..<device.interfaces.count {
        if i < device.interface_count && !device.interfaces[i].gone_told {
            return void
        }
    }
    device.used = false
}

// ---- Contexts

/**
 * A ring in one of a device's pages, empty, its cycle 1.
 *
 * @param device The device, whose memory it's in.
 * @param page Which of its pages.
 * @return The ring.
 */
ring_at :: fn(device : ptr[Device], page : u64) -> Ring {
    return Ring.{entries = device.memory_at + page * PAGE, device = device.memory_device + page * PAGE, cycle = 1}
}

/**
 * Zero a device's input context.
 *
 * @param driver The driver, for its contexts' size.
 * @param device The device.
 */
clear_input :: fn(driver : ptr[Driver], device : ptr[Device]) {
    for i in 0..<(PAGE / 8) {
        intrinsics.volatile_store_u64(cast[ptr[mut u64]](device.memory_at + INPUT_PAGE * PAGE + i * 8), 0)
    }
}

/**
 * Where a context is in a device's input context: 0 the input control context, 1 the slot's, then each DCI's.
 *
 * @param driver The driver, for its contexts' size.
 * @param device The device.
 * @param context Which.
 * @return Its address, through the driver's mapping.
 */
input_context :: fn(driver : ptr[Driver], device : ptr[Device], context : u32) -> u64 {
    return device.memory_at + INPUT_PAGE * PAGE + cast[u64](context) * driver.context_bytes
}

/**
 * Write the input control context's drop and add flags.
 *
 * @param driver The driver.
 * @param device The device.
 * @param unused Kept 0.
 * @param drops The contexts dropped, a bit each.
 * @param adds The contexts added or evaluated, a bit each: bit 0 the slot's, bit n DCI n's.
 */
set_input :: fn(driver : ptr[Driver], device : ptr[Device], unused : u32, drops : u32, adds : u32) {
    at :: input_context(driver, device, 0)
    write_u32(at, 0, drops)
    write_u32(at, 4, adds)
}

/**
 * Write the slot context (§6.2.2): its route, speed, context entries, root port, a hub's ports, and its transaction
 * translator.
 *
 * @param driver The driver.
 * @param device The device.
 * @param entries Its last DCI in use.
 */
write_slot_context :: fn(driver : ptr[Driver], device : ptr[Device], entries : u32) {
    at :: input_context(driver, device, 1)
    hub :: if device.hub { cast[u32](1) << 26 } else { cast[u32](0) }
    write_u32(at, 0, (device.route & 0xf_ffff) | (device.speed << 20) | hub | (entries << 27))
    ports :: if device.hub { device.hub_ports << 24 } else { cast[u32](0) }
    write_u32(at, 4, (device.root_port << 16) | ports)
    write_u32(at, 8, (device.tt_slot & 0xff) | ((device.tt_port & 0xff) << 8))
}

/**
 * Write the default control endpoint's context (§6.2.3), its ring's dequeue pointer the ring's next TRB.
 *
 * @param driver The driver.
 * @param device The device.
 * @param packet Its packet size.
 */
write_control_context :: fn(driver : ptr[Driver], device : ptr[Device], packet : u32) {
    at :: input_context(driver, device, 2)
    // CErr 3, type 4 (control), its packet size
    write_u32(at, 4, (3 << 1) | (4 << 3) | (packet << 16))
    write_u64(at, 8, dequeue_of(&device.control.ring))
    write_u32(at, 16, 8)
}

/**
 * Write a bulk or interrupt endpoint's context.
 *
 * @param driver The driver.
 * @param device The device.
 * @param endpoint The endpoint, its ring empty.
 */
write_endpoint_context :: fn(driver : ptr[Driver], device : ptr[Device], endpoint : ptr[Endpoint]) {
    at :: input_context(driver, device, endpoint.dci + 1)
    into :: endpoint.address & 0x80 != 0
    // Its type: 2 bulk OUT, 3 interrupt OUT, 6 bulk IN, 7 interrupt IN
    kind := if endpoint.kind == .Bulk { cast[u32](2) } else { cast[u32](3) }
    if into {
        kind += 4
    }
    interval := cast[u32](0)
    if endpoint.kind == .Interrupt {
        if device.speed == SPEED_FULL || device.speed == SPEED_LOW {
            // bInterval in frames, as 125 µs times a power of 2: 2^3 is a frame
            frames :: larger(cast[u32](endpoint.interval), 1)
            interval = 3
            loop {
                if interval >= 10 || (cast[u32](1) << (interval + 1)) > frames * 8 {
                    break
                }
                interval += 1
            }
        }
        else {
            interval = smaller(larger(cast[u32](endpoint.interval), 1) - 1, 15)
        }
    }
    write_u32(at, 0, interval << 16)
    write_u32(at, 4, (3 << 1) | (kind << 3) | (cast[u32](endpoint.max_packet) << 16))
    write_u64(at, 8, dequeue_of(&endpoint.ring))
    payload :: cast[u32](endpoint.max_packet)
    write_u32(at, 16, payload | (if endpoint.kind == .Interrupt { payload << 16 } else { cast[u32](0) }))
}

/**
 * Stop an endpoint's transfer in flight and move its dequeue pointer past what was on its ring (Stop Endpoint, then
 * Set TR Dequeue Pointer, §4.6.9): the transfer is dropped unanswered, its event, if one comes, passed over.
 *
 * @param driver The driver.
 * @param index The device's index.
 * @param endpoint The endpoint, busy.
 */
abort_transfer :: fn(driver : ptr[mut Driver], index : usize, endpoint : ptr[mut Endpoint]) {
    if index >= driver.devices.count {
        return void
    }
    slot :: driver.devices[index].slot
    _ = command(driver, 0, (TRB_STOP_ENDPOINT << 10) | (endpoint.dci << 16) | (slot << 24))
    _ = command(driver, dequeue_of(&endpoint.ring), (TRB_SET_DEQUEUE << 10) | (endpoint.dci << 16) | (slot << 24))
    endpoint.busy = false
    endpoint.halted = false
}

/**
 * Reset an endpoint the controller halted, and move its dequeue pointer past what was on its ring (§4.6.8, §4.6.10).
 *
 * @param driver The driver.
 * @param index The device's index.
 * @param endpoint The endpoint, not busy.
 * @return True once it's reset; false if a command failed, as it's left halted.
 */
reset_ring :: fn(driver : ptr[mut Driver], index : usize, endpoint : ptr[mut Endpoint]) -> bool {
    if index >= driver.devices.count {
        return false
    }
    slot :: driver.devices[index].slot
    _ = command(driver, 0, (TRB_RESET_ENDPOINT << 10) | (endpoint.dci << 16) | (slot << 24))
    if !succeeds(driver, dequeue_of(&endpoint.ring), (TRB_SET_DEQUEUE << 10) | (endpoint.dci << 16) | (slot << 24)) {
        return false
    }
    endpoint.halted = false
    return true
}

// ---- Transfers

/**
 * Put a transfer's data TRBs on an endpoint's ring, two chained where the data crosses a 64 KiB boundary, as one
 * TRB's mustn't (§4.11.7.1); the last interrupts on completion, each on a short packet.
 *
 * @param endpoint The endpoint, whose ring takes them and whose first_trb, first_bytes and bytes are set.
 * @param first_kind The first TRB's type, Data for a control transfer's data stage, Normal otherwise.
 * @param first_flags Its own bits: a data stage's direction.
 * @param data The data's address to the controller.
 * @param bytes Its bytes, 1 to 64 KiB.
 */
put_data :: fn(endpoint : ptr[mut Endpoint], first_kind : u32, first_flags : u32, data : u64, bytes : u32) {
    boundary :: (data | 0xffff) + 1
    first :: if data + cast[u64](bytes) > boundary { cast[u32](boundary - data) } else { bytes }
    endpoint.bytes = bytes
    endpoint.first_bytes = first
    if first == bytes {
        endpoint.first_trb = enqueue(
            &endpoint.ring, data, bytes, (first_kind << 10) | first_flags | TRB_INTERRUPT | TRB_SHORT
        )
        return void
    }
    endpoint.first_trb = enqueue(&endpoint.ring, data, first, (first_kind << 10) | first_flags | TRB_CHAIN | TRB_SHORT)
    _ = enqueue(&endpoint.ring, boundary, bytes - first, (TRB_NORMAL << 10) | TRB_INTERRUPT | TRB_SHORT, true)
}

/**
 * Start a control transfer on a device's default endpoint: its setup, data and status stages (§4.11.2.2).
 *
 * @param driver The driver.
 * @param device The device.
 * @param setup The setup packet.
 * @param data Its data's address to the controller, for a setup.length past 0.
 */
start_control :: fn(driver : ptr[Driver], device : ptr[mut Device], setup : usb_device.Setup, data : u64) {
    endpoint :: &device.control
    packet :: cast[u64](setup.request_type)
        | (cast[u64](setup.request) << 8)
        | (cast[u64](setup.value) << 16)
        | (cast[u64](setup.index) << 32)
        | (cast[u64](setup.length) << 48)
    into :: setup.request_type & 0x80 != 0
    transfer_type :: if setup.length == 0 { cast[u32](0) } else if into { cast[u32](3) } else { cast[u32](2) }
    endpoint.busy = true
    endpoint.control = true
    endpoint.moved = 0
    endpoint.first_trb = 0
    _ = enqueue(&endpoint.ring, packet, 8, (TRB_SETUP << 10) | TRB_IMMEDIATE | (transfer_type << 16))
    if setup.length > 0 {
        put_data(endpoint, TRB_DATA, if into { TRB_IN } else { cast[u32](0) }, data, cast[u32](setup.length))
    }
    status_in :: setup.length == 0 || !into
    endpoint.status_trb = enqueue(
        &endpoint.ring, 0, 0, (TRB_STATUS << 10) | TRB_INTERRUPT | (if status_in { TRB_IN } else { cast[u32](0) })
    )
    ring_doorbell(driver, device.slot, 1)
}

/**
 * Start a bulk or interrupt transfer on an endpoint.
 *
 * @param driver The driver.
 * @param device The device.
 * @param endpoint The endpoint, not busy.
 * @param data The data's address to the controller.
 * @param bytes Its bytes, 1 to 64 KiB.
 */
start_normal :: fn(driver : ptr[Driver], device : ptr[Device], endpoint : ptr[mut Endpoint], data : u64, bytes : u32) {
    endpoint.busy = true
    endpoint.control = false
    endpoint.moved = 0
    endpoint.status_trb = 0
    put_data(endpoint, TRB_NORMAL, 0, data, bytes)
    ring_doorbell(driver, device.slot, endpoint.dci)
}

/**
 * Run one of the driver's own control transfers on a device, its data in the device's data page, and wait for it.
 *
 * @param driver The driver.
 * @param index The device's index; its default endpoint not busy.
 * @param request_type The setup's bmRequestType.
 * @param request Its bRequest.
 * @param value Its wValue.
 * @param where Its wIndex.
 * @param length Its wLength, at most 2048.
 * @return The bytes its data stage moved; null if it failed, stalled or didn't end within COMMAND_WAIT, a stall's
 *     halt reset.
 */
own_control :: fn(
    driver : ptr[mut Driver],
    index : usize,
    request_type : u8,
    request : u8,
    value : u16,
    where : u16,
    length : u16
) -> u32? {
    if index >= driver.devices.count {
        return null
    }
    device :: &driver.devices[index]
    if device.control.busy || device.gone {
        return null
    }
    device.control.own = true
    device.control.own_done = false
    setup :: usb_device.Setup.{request_type = request_type, request = request, value = value, index = where, length = length}
    start_control(driver, device, setup, device.memory_device + DATA_PAGE * PAGE)
    deadline :: (slop_os.clock_monotonic() or_else 0) + COMMAND_WAIT
    loop {
        take_events(driver)
        if device.control.own_done {
            break
        }
        if (slop_os.clock_monotonic() or_else deadline) >= deadline {
            // Stopped, so the default endpoint isn't busy for good
            abort_transfer(driver, index, &device.control)
            device.control.own = false
            return null
        }
        intrinsics.spin_hint()
    }
    device.control.own = false
    if device.control.halted {
        _ = reset_ring(driver, index, &device.control)
    }
    if device.control.own_code != cast[u32](usb_device.Status.Done) {
        return null
    }
    return device.control.moved
}

/**
 * Read a standard descriptor into the device's data page.
 *
 * @param driver The driver.
 * @param index The device's index.
 * @param value Its type in the high byte, its index in the low.
 * @param length The bytes asked for.
 * @return The bytes read; null if the device didn't answer.
 */
get_descriptor :: fn(driver : ptr[mut Driver], index : usize, value : u16, length : u16) -> u32? {
    return own_control(driver, index, 0x80, REQUEST_GET_DESCRIPTOR, value, 0, length)
}

// ---- Clients

/**
 * Note what a client is, its place's generation moved on.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param kind What it is.
 * @param device An interface client's device, or NONE.
 * @param interface Its interface, or NONE.
 */
set_client :: fn(driver : ptr[mut Driver], index : usize, kind : ClientKind, device : usize, interface : usize) {
    if index >= driver.client_state.count {
        return void
    }
    generation :: driver.client_state[index].generation + 1
    driver.client_state[index] = Client.{
        kind = kind,
        device = device,
        interface = interface,
        buffer = cast[slop_os.Memory](slop_os.NO_HANDLE),
        generation = generation,
    }
}

/**
 * Let a client go: its end closed, its buffer let go once nothing in flight has it.
 *
 * @param driver The driver.
 * @param index The client's index.
 */
drop :: fn(driver : ptr[mut Driver], index : usize) {
    if index >= driver.client_state.count {
        return void
    }
    // Its transfers in flight stopped, so its endpoints are free for the next client, as a restarted class driver
    for device in 0..<driver.devices.count {
        if !driver.devices[device].used || driver.devices[device].gone {
            continue
        }
        if driver.devices[device].control.busy && !driver.devices[device].control.own
            && driver.devices[device].control.client == index {
            abort_transfer(driver, device, &driver.devices[device].control)
        }
        for i in 0..<driver.devices[device].endpoints.count {
            if driver.devices[device].endpoints[i].busy && !driver.devices[device].endpoints[i].own
                && driver.devices[device].endpoints[i].client == index {
                abort_transfer(driver, device, &driver.devices[device].endpoints[i])
            }
        }
    }
    service_kit.drop_client(&driver.clients, index)
    buffer :: driver.client_state[index].buffer
    set_client(driver, index, .Nothing, NONE, NONE)
    release_buffer(driver, buffer)
}

/**
 * Close a buffer a client left, unless a transfer in flight still has it, whose end closes it.
 *
 * @param driver The driver.
 * @param memory The buffer's memory; NO_HANDLE is nothing.
 */
release_buffer :: fn(driver : ptr[Driver], memory : slop_os.Memory) {
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        return void
    }
    for device in driver.devices {
        if device.used && device.control.busy && !device.control.own && device.control.memory == memory {
            return void
        }
        for endpoint in device.endpoints {
            if device.used && endpoint.busy && !endpoint.own && endpoint.memory == memory {
                return void
            }
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
}

/**
 * Answer every request a client has sent, until it has none, or it's gone.
 *
 * @param driver The driver.
 * @param index The client's index.
 */
serve :: fn(driver : ptr[mut Driver], index : usize) {
    if index >= driver.clients.ends.count || index >= driver.client_state.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    match driver.client_state[index].kind {
        case .Bus => serve_bus(driver, index, end)
        case .Interface => serve_interface(driver, index, end)
        case .Nothing => {}
    }
}

/**
 * Take a bus client's requests: a Next held, a Connect adding a bus client.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param end Its end.
 */
serve_bus :: fn(driver : ptr[mut Driver], index : usize, end : slop_os.Channel) {
    if index >= driver.client_state.count {
        return void
    }
    into := os.Incoming.{}
    loop {
        match usb_bus.receive_request(end, driver.port, &into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = usb_bus.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                drop(driver, index)
                return void
            }
        }
        match os.message_of[usb_bus.Request](&into)^ {
            case Next => driver.client_state[index].waiting = true
            case Connect(connection) => {
                match service_kit.add_client_index(&driver.clients, driver.port, connection.end) {
                    case Some(added) => set_client(driver, added, .Bus, NONE, NONE)
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Answer each bus client's held Next with the next thing it hasn't been told: an interface not yet Attached, one gone
 * not yet Detached, or Settled.
 *
 * @param driver The driver.
 */
tell_bus :: fn(driver : ptr[mut Driver]) {
    for client in 0..<driver.client_state.count {
        if driver.client_state[client].kind != .Bus || !driver.client_state[client].waiting
            || client >= driver.clients.ends.count {
            continue
        }
        end :: driver.clients.ends[client]
        told :: next_news(driver, client) or_continue
        driver.client_state[client].waiting = false
        out := os.Outgoing.{}
        made :: os.begin[usb_bus.Response](&out)
        made^ = told
        _ = usb_bus.send_response(end, driver.port, &out)
    }
}

/**
 * Take the next thing a bus client hasn't been told.
 *
 * @param driver The driver, whose interfaces are marked told.
 * @param client The client's index.
 * @return Attached, its connection moving out of the driver; Detached; Settled; null if there's nothing new.
 */
next_news :: fn(driver : ptr[mut Driver], client : usize) -> usb_bus.Response? {
    if client >= driver.client_state.count {
        return null
    }
    for i in 0..<driver.devices.count {
        device :: &driver.devices[i]
        if !device.used {
            continue
        }
        for j in 0..<device.interfaces.count {
            if j >= device.interface_count {
                break
            }
            each :: &device.interfaces[j]
            key :: cast[u64](device.route & 0xf_ffff) | (cast[u64](device.root_port) << 20) | (cast[u64](each.number) << 28)
            if !each.announced && !device.gone && cast[slop_os.Handle](each.peer) != slop_os.NO_HANDLE {
                each.announced = true
                peer :: each.peer
                each.peer = cast[slop_os.Channel](slop_os.NO_HANDLE)
                return usb_bus.Response.Attached(
                    usb_bus.Interface.{
                        key = key,
                        vendor = device.vendor,
                        product = device.product,
                        class = each.class,
                        subclass = each.subclass,
                        protocol = each.protocol,
                        device = os.Channel[usb_device.UsbDevice].{end = peer},
                    }
                )
            }
            if each.announced && device.gone && !each.gone_told {
                each.gone_told = true
                free_if_told(device)
                return usb_bus.Response.Detached(key)
            }
        }
    }
    if driver.settled && !driver.client_state[client].settled_told {
        driver.client_state[client].settled_told = true
        return usb_bus.Response.Settled
    }
    return null
}

/**
 * Answer, or start, every request an interface's client has sent.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param end Its end.
 */
serve_interface :: fn(driver : ptr[mut Driver], index : usize, end : slop_os.Channel) {
    if index >= driver.client_state.count {
        return void
    }
    into := os.Incoming.{}
    loop {
        match usb_device.receive_request(end, driver.port, &into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = usb_device.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                drop(driver, index)
                return void
            }
        }
        state :: driver.client_state[index]
        if state.device >= driver.devices.count || driver.devices[state.device].gone
            || state.interface >= driver.devices[state.device].interface_count {
            gone :: match os.message_of[usb_device.Request](&into)^ {
                case Control(asked) => finished(asked.tag, .Gone, 0)
                case Transfer(asked) => finished(asked.tag, .Gone, 0)
                case ResetEndpoint(asked) => finished(asked.tag, .Gone, 0)
                case Connect(connection) => {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                    null
                }
                case _ => usb_device.Response.Unsupported
            }
            answer(driver, end, gone)
            continue
        }
        match os.message_of[usb_device.Request](&into)^ {
            case Describe => answer(driver, end, describe(driver, state.device, state.interface))
            case GetBuffer => answer(driver, end, buffer_for(driver, index))
            case Control(asked) => answer(driver, end, client_control(driver, index, asked))
            case Transfer(asked) => answer(driver, end, client_transfer(driver, index, asked))
            case ResetEndpoint(asked) => answer(driver, end, reset_endpoint(driver, index, asked))
            case Connect(connection) => {
                match service_kit.add_client_index(&driver.clients, driver.port, connection.end) {
                    case Some(added) => set_client(driver, added, .Interface, state.device, state.interface)
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Say what an interface is.
 *
 * @param driver The driver.
 * @param index The device's index.
 * @param interface The interface's index.
 * @return Described.
 */
describe :: fn(driver : ptr[Driver], index : usize, interface : usize) -> usb_device.Response? {
    if index >= driver.devices.count || interface >= driver.devices[index].interfaces.count {
        return usb_device.Response.Unsupported
    }
    device :: &driver.devices[index]
    each :: device.interfaces[interface]
    info := usb_device.Info.{
        vendor = device.vendor,
        product = device.product,
        speed = if device.speed == SPEED_LOW {
            usb_device.Speed.Low
        }
        else if device.speed == SPEED_FULL {
            usb_device.Speed.Full
        }
        else if device.speed == SPEED_HIGH {
            usb_device.Speed.High
        }
        else {
            usb_device.Speed.Super
        },
        interface = each.number,
        class = each.class,
        subclass = each.subclass,
        protocol = each.protocol,
        buffer_bytes = BUFFER_BYTES,
    }
    for i in 0..<device.endpoints.count {
        if i >= device.endpoint_count || device.endpoints[i].interface != interface {
            continue
        }
        at :: cast[usize](info.endpoint_count)
        if at >= info.endpoints.count {
            break
        }
        info.endpoints[at] = usb_device.Endpoint.{
            address = device.endpoints[i].address,
            kind = device.endpoints[i].kind,
            max_packet = device.endpoints[i].max_packet,
            interval = device.endpoints[i].interval,
        }
        info.endpoint_count += 1
    }
    return usb_device.Response.Described(info)
}

/**
 * Start a client's control transfer, if it's one it may make.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param asked The transfer.
 * @return Null once it's started; Finished now with Refused for a request the driver keeps or one to another
 *     interface, its endpoints, or the device but for GET_DESCRIPTOR and GET_STATUS; OutOfRange past the buffer or
 *     without one; Busy while the default endpoint has a transfer in flight.
 */
client_control :: fn(driver : ptr[mut Driver], index : usize, asked : usb_device.Control) -> usb_device.Response? {
    if index >= driver.client_state.count {
        return usb_device.Response.Unsupported
    }
    state :: driver.client_state[index]
    if state.device >= driver.devices.count || state.interface >= driver.devices[state.device].interfaces.count {
        return usb_device.Response.Unsupported
    }
    device :: &driver.devices[state.device]
    setup :: asked.setup
    standard :: setup.request_type & 0x60 == 0
    recipient :: setup.request_type & 0x1f
    if standard && (setup.request == REQUEST_SET_ADDRESS || setup.request == REQUEST_SET_CONFIGURATION
        || setup.request == REQUEST_SET_INTERFACE) {
        return finished(asked.tag, .Refused, 0)
    }
    allowed :: if recipient == 0 {
        standard && (setup.request == REQUEST_GET_DESCRIPTOR || setup.request == REQUEST_GET_STATUS)
    }
    else if recipient == 1 {
        cast[u8](setup.index & 0xff) == device.interfaces[state.interface].number
    }
    else if recipient == 2 {
        own_endpoint(device, state.interface, cast[u8](setup.index & 0xff)) is_some
    }
    else {
        false
    }
    if !allowed {
        return finished(asked.tag, .Refused, 0)
    }
    if setup.length > 0 && (cast[slop_os.Handle](state.buffer) == slop_os.NO_HANDLE
        || cast[u64](asked.offset) + cast[u64](setup.length) > BUFFER_BYTES) {
        return finished(asked.tag, .OutOfRange, 0)
    }
    if device.control.busy {
        return finished(asked.tag, .Busy, 0)
    }
    if device.control.halted && !reset_ring(driver, state.device, &device.control) {
        return finished(asked.tag, .DeviceError, 0)
    }
    note_client(&device.control, state, index, asked.tag)
    start_control(driver, device, setup, state.buffer_device + cast[u64](asked.offset))
    return null
}

/**
 * Find one of an interface's endpoints by its address.
 *
 * @param device The device.
 * @param interface The interface's index.
 * @param address The endpoint's address.
 * @return The endpoint's index among the device's; null if the interface hasn't it.
 */
own_endpoint :: fn(device : ptr[Device], interface : usize, address : u8) -> usize? {
    for i in 0..<device.endpoints.count {
        if i < device.endpoint_count && device.endpoints[i].interface == interface && device.endpoints[i].address == address {
            return i
        }
    }
    return null
}

/**
 * Note whose transfer an endpoint's next is.
 *
 * @param endpoint The endpoint.
 * @param state The client's state.
 * @param index The client's index.
 * @param tag Its tag.
 */
note_client :: fn(endpoint : ptr[mut Endpoint], state : Client, index : usize, tag : u64) {
    endpoint.own = false
    endpoint.client = index
    endpoint.tag = tag
    endpoint.generation = state.generation
    endpoint.memory = state.buffer
}

/**
 * Start a client's bulk or interrupt transfer on one of its interface's endpoints.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param asked The transfer.
 * @return Null once it's started; Finished now with NoEndpoint for an endpoint not the interface's or isochronous,
 *     OutOfRange for no bytes or past the buffer, Stalled for one halted, Busy for one with a transfer in flight.
 */
client_transfer :: fn(driver : ptr[mut Driver], index : usize, asked : usb_device.Transfer) -> usb_device.Response? {
    if index >= driver.client_state.count {
        return usb_device.Response.Unsupported
    }
    state :: driver.client_state[index]
    if state.device >= driver.devices.count || state.interface >= driver.devices[state.device].interfaces.count {
        return usb_device.Response.Unsupported
    }
    device :: &driver.devices[state.device]
    which :: own_endpoint(device, state.interface, asked.endpoint) or_return finished(asked.tag, .NoEndpoint, 0)
    if which >= device.endpoints.count {
        return finished(asked.tag, .NoEndpoint, 0)
    }
    endpoint :: &device.endpoints[which]
    if endpoint.kind != .Bulk && endpoint.kind != .Interrupt {
        return finished(asked.tag, .NoEndpoint, 0)
    }
    if asked.length == 0 || cast[slop_os.Handle](state.buffer) == slop_os.NO_HANDLE
        || cast[u64](asked.offset) + cast[u64](asked.length) > BUFFER_BYTES {
        return finished(asked.tag, .OutOfRange, 0)
    }
    if endpoint.halted {
        return finished(asked.tag, .Stalled, 0)
    }
    if endpoint.busy {
        return finished(asked.tag, .Busy, 0)
    }
    note_client(endpoint, state, index, asked.tag)
    start_normal(driver, device, endpoint, state.buffer_device + cast[u64](asked.offset), asked.length)
    return null
}

/**
 * Clear an endpoint's halt, the device's (CLEAR_FEATURE ENDPOINT_HALT) and the controller's.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @param asked Which endpoint, and the tag.
 * @return Finished: Done once both are cleared; NoEndpoint for one not the interface's; Busy while it or the default
 *     endpoint has a transfer in flight; Stalled or DeviceError if the device or the controller refused.
 */
reset_endpoint :: fn(driver : ptr[mut Driver], index : usize, asked : usb_device.ResetEndpoint) -> usb_device.Response? {
    if index >= driver.client_state.count {
        return usb_device.Response.Unsupported
    }
    state :: driver.client_state[index]
    if state.device >= driver.devices.count || state.interface >= driver.devices[state.device].interfaces.count {
        return usb_device.Response.Unsupported
    }
    device :: &driver.devices[state.device]
    which :: own_endpoint(device, state.interface, asked.endpoint) or_return finished(asked.tag, .NoEndpoint, 0)
    if which >= device.endpoints.count {
        return finished(asked.tag, .NoEndpoint, 0)
    }
    if device.endpoints[which].busy || device.control.busy {
        return finished(asked.tag, .Busy, 0)
    }
    if device.endpoints[which].halted && !reset_ring(driver, state.device, &device.endpoints[which]) {
        return finished(asked.tag, .DeviceError, 0)
    }
    // ENDPOINT_HALT is feature 0
    if own_control(driver, state.device, 0x02, REQUEST_CLEAR_FEATURE, 0, cast[u16](asked.endpoint), 0) is_none {
        return finished(asked.tag, .Stalled, 0)
    }
    return finished(asked.tag, .Done, 0)
}

/**
 * Give a client a window onto its buffer, made at its first ask.
 *
 * @param driver The driver.
 * @param index The client's index.
 * @return Buffer with a new window; Unsupported if it couldn't be made, or is past 4 GiB for a controller that can't
 *     reach it.
 */
buffer_for :: fn(driver : ptr[mut Driver], index : usize) -> usb_device.Response? {
    if index >= driver.client_state.count {
        return usb_device.Response.Unsupported
    }
    startup :: slop_os.startup_block()
    state :: &driver.client_state[index]
    if cast[slop_os.Handle](state.buffer) == slop_os.NO_HANDLE {
        memory :: slop_os.dma_memory_create(driver.domain, startup.budget, BUFFER_BYTES, 0)
            or_return usb_device.Response.Unsupported
        address :: slop_os.memory_device_address(memory) or_return usb_device.Response.Unsupported
        if !reachable(driver, address, BUFFER_BYTES) {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return usb_device.Response.Unsupported
        }
        state.buffer = memory
        state.buffer_device = address
    }
    window :: slop_os.memory_create_window(state.buffer, startup.budget, 0, BUFFER_BYTES)
        or_return usb_device.Response.Unsupported
    return usb_device.Response.Buffer(window)
}

/**
 * Send a client an answer, if there is one now.
 *
 * @param driver The driver.
 * @param end The client's end.
 * @param response The answer; null for a transfer in flight.
 */
answer :: fn(driver : ptr[mut Driver], end : slop_os.Channel, response : usb_device.Response?) {
    given :: response or_return void
    out := os.Outgoing.{}
    made :: os.begin[usb_device.Response](&out)
    made^ = given
    _ = usb_device.send_response(end, driver.port, &out)
}

/**
 * Make a Finished answer.
 *
 * @param tag The client's tag.
 * @param status How it went.
 * @param moved The bytes moved.
 * @return Finished; never null.
 */
finished :: fn(tag : u64, status : usb_device.Status, moved : u32) -> usb_device.Response? {
    return usb_device.Response.Finished(usb_device.Completion.{tag = tag, status = status, length = moved})
}

// ---- Memory and registers

/**
 * Map DMA memory read/write into the driver's address space.
 *
 * @param memory The memory, the driver's.
 * @param bytes Its size.
 * @return Where it's mapped; null if addresses or the mapping couldn't be had.
 */
map_memory :: fn(memory : slop_os.Memory, bytes : u64) -> u64? {
    startup :: slop_os.startup_block()
    at :: runtime.reserve_addresses(cast[usize](bytes)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    match slop_os.memory_map(memory, startup.space, at, 0, bytes, read_write) {
        case Ok => return at
        case Error(error) => return null
    }
}

/**
 * Tell whether the controller reaches memory at a device address.
 *
 * @param driver The driver.
 * @param device The memory's device address.
 * @param bytes Its size.
 * @return True for a controller with 64-bit addresses, or memory below 4 GiB.
 */
reachable :: fn(driver : ptr[Driver], device : u64, bytes : u64) -> bool {
    return driver.wide || (device + bytes - 1) >> 32 == 0
}

/**
 * Read a byte of memory.
 *
 * @param base Where it's mapped.
 * @param offset Its offset.
 * @return The byte.
 */
byte_at :: fn(base : u64, offset : u64) -> u8 {
    return intrinsics.volatile_load_u8(cast[ptr[u8]](base + offset))
}

/**
 * Read a little-endian 16-bit value of memory, a byte at a time, as a descriptor's may be unaligned.
 *
 * @param base Where it's mapped.
 * @param offset Its offset.
 * @return The value.
 */
word_at :: fn(base : u64, offset : u64) -> u16 {
    return cast[u16](byte_at(base, offset)) | (cast[u16](byte_at(base, offset + 1)) << 8)
}

/**
 * Read a root port's PORTSC.
 *
 * @param driver The driver.
 * @param port The port, from 1.
 * @return Its value.
 */
read_port :: fn(driver : ptr[Driver], port : u32) -> u32 {
    return read_u32(driver.operational, PORT_REGISTERS + cast[u64](port - 1) * 16)
}

/**
 * Write a root port's PORTSC.
 *
 * @param driver The driver.
 * @param port The port, from 1.
 * @param value What's written: PORT_KEEP's bits as read, with the bits to set or clear.
 */
write_port :: fn(driver : ptr[Driver], port : u32, value : u32) {
    write_u32(driver.operational, PORT_REGISTERS + cast[u64](port - 1) * 16, value)
}

/**
 * Wait for a register's bits to be what's wanted, polling, until a deadline on the monotonic clock.
 *
 * @param address The register's address, mapped.
 * @param mask The bits looked at.
 * @param value What they're waited to be.
 * @param nanoseconds How long it waits at most.
 * @return True once they are; false once nanoseconds have passed without them being.
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
 * The smaller of two values.
 *
 * @param a One.
 * @param b The other.
 * @return The smaller.
 */
smaller :: fn(a : u32, b : u32) -> u32 {
    return if a < b { a } else { b }
}

/**
 * The larger of two values.
 *
 * @param a One.
 * @param b The other.
 * @return The larger.
 */
larger :: fn(a : u32, b : u32) -> u32 {
    return if a > b { a } else { b }
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
 * Write a 64-bit register as two 32-bit writes, low then high, as a controller without 64-bit access takes them.
 *
 * @param base Where the registers are mapped.
 * @param offset The register's offset, 8-byte aligned.
 * @param value What's written.
 */
write_u64 :: fn(base : u64, offset : u64, value : u64) {
    write_u32(base, offset, cast[u32](value))
    write_u32(base, offset + 4, cast[u32](value >> 32))
}
