package platform

import os from "std"
import slop_os from "std/os"

/*
 * The platform service's protocol (decisions/0074, 0077, 0093): the devices it found, each claimed once, by the
 * supervisor, for a driver system_config names, with everything the driver holds of it, and given again for a driver
 * that's restarted; and the real-time clock, for the clock service, claimed by one client, which may claim it again,
 * made anew. Connections arrive on its listener as Connects.
 */

/**
 * The platform protocol, for the channels between the platform service and its clients, and its listener: the clients
 * send the requests, and the platform service answers them.
 */
Platform :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the platform service, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "platform", major_version = 3, lending = .Server}

/** A DeviceMatch's vendor or device that matches any. */
ANY_ID : u16 : 0xffff
/** A DeviceMatch's class that matches any. */
ANY_CLASS : u32 : 0xffffffff

/**
 * Which devices a driver takes: a vendor's device, or a class (its base class, subclass and programming interface,
 * as the class register's top 24 bits), each ANY for any. A device matches when all three do.
 */
DeviceMatch :: struct {
    /** The PCI vendor ID, or ANY_ID for any. */
    vendor : u16,
    /** The PCI device ID, or ANY_ID for any. */
    device : u16,
    /** The class register's top 24 bits, base class, subclass and programming interface, or ANY_CLASS for any. */
    class : u32,
}

/** What a Claim wants: devices that match, for a driver trusted with DMA no IOMMU confines, or not (decisions/0084). */
Wanted :: struct {
    /** Which devices the driver takes. Bridges and host bridges never match. */
    devices : DeviceMatch,
    /**
     * Whether the driver is trusted with DMA where no IOMMU confines its device: the device's DMA domain is made so,
     * and stays so when it's reissued.
     */
    trusted : bool,
}

/**
 * A device, and what its driver holds of it: its Device (slop_os.device_create), a window onto its 4 KiB of
 * configuration space, each BAR it has as device memory (NO_HANDLE for one it hasn't, or the upper half of a 64-bit
 * one), and a DMA domain it's attached to: trusted with DMA memory where no IOMMU confines it only if the claim was.
 *
 * Every handle in it moves to the client with the response that carries it.
 */
PciDevice :: struct {
    /**
     * Its segment and requester ID (slop_os.device_address): the segment in the high 16 bits, then bus, device,
     * function.
     */
    address : u32,
    /** Its PCI vendor ID. */
    vendor : u16,
    /** Its PCI device ID. */
    device_id : u16,
    /** Its class register's top 24 bits: base class, subclass and programming interface. */
    class : u32,
    /** The device, for its MSIs (slop_os.irq_create_msi) and its DMA. */
    device : slop_os.Device,
    /** Its 4 KiB of PCIe configuration space, as device memory, to map readable and writable. */
    config : slop_os.Memory,
    /**
     * BAR 0's device memory: whole pages, from the page its CPU address is in, so a BAR not page-aligned starts at
     * its address's offset in the first page. NO_HANDLE if it hasn't one, or its memory couldn't be made.
     */
    bar0 : slop_os.Memory,
    /** BAR 1's device memory, as bar0's; NO_HANDLE too for the upper half of a 64-bit BAR 0. */
    bar1 : slop_os.Memory,
    /** BAR 2's device memory, as bar0's. */
    bar2 : slop_os.Memory,
    /** BAR 3's device memory, as bar0's; NO_HANDLE too for the upper half of a 64-bit BAR 2. */
    bar3 : slop_os.Memory,
    /** BAR 4's device memory, as bar0's. */
    bar4 : slop_os.Memory,
    /** BAR 5's device memory, as bar0's; NO_HANDLE too for the upper half of a 64-bit BAR 4. */
    bar5 : slop_os.Memory,
    /** The DMA domain the device is attached to, which its driver makes DMA memory in. */
    domain : slop_os.DmaDomain,
}

/** Which real-time clock a ClaimedClock is. */
ClockKind :: enum #backed_by(u32) {
    /** x86's MC146818, at I/O ports 0x70 and 0x71: its index register, then its data register. */
    Mc146818 = 1,
    /** Arm's PL031, its registers' 4 KiB, from the device tree's arm,pl031. */
    Pl031 = 2,
}

/** The real-time clock, and what its driver holds of it: its ports, or its registers, NO_HANDLE for the other. */
RealTimeClock :: struct {
    /** Which clock it is, which says which of ports and registers it has. */
    kind : ClockKind,
    /** For an Mc146818, its two I/O ports, which move to the client; NO_HANDLE otherwise. */
    ports : slop_os.IoPortRange,
    /** For a Pl031, its registers' 4 KiB as device memory, which moves to the client; NO_HANDLE otherwise. */
    registers : slop_os.Memory,
}

/** The first framebuffer (decisions/0138): its pixels, and a page holding its slop_os.FramebufferLayout. */
Framebuffer :: struct {
    /**
     * Its pixels, write-combining device memory rounded up to whole pages, which moves to the client; making it takes
     * the framebuffer from the kernel's console.
     */
    pixels : slop_os.Memory,
    /** A page holding the framebuffer's slop_os.FramebufferLayout, at its start, which moves to the client. */
    layout : slop_os.Memory,
}

/**
 * What the ACPI service is given when it claims ACPI (decisions/0182, P3): the firmware tables, and the SCI's IRQ.
 * Everything in it moves to the client.
 */
AcpiHardware :: struct {
    /** A read-only copy of the firmware tables' copy (slop_os.FirmwareTables), its DSDT, SSDTs and FADT among them. */
    tables : slop_os.Memory,
    /** The SCI's IRQ, routed as the FADT and the MADT say; NO_HANDLE without one. */
    sci : slop_os.Irq,
}

/** I/O ports the ACPI service asks for: first to first + count - 1. */
PortRange :: struct {
    /** The first port, below 65536. */
    first : u32,
    /** How many, at least 1. */
    count : u32,
}

/** Physical memory the ACPI service asks for, for a SystemMemory region. */
MemoryRange :: struct {
    /** Its first byte's physical address. */
    address : u64,
    /** Its bytes, at least 1. */
    size : u64,
}

/** An access to a PCI function's configuration space, for a PCI_Config region. */
ConfigAccess :: struct {
    /**
     * The function and offset: the segment in bits 32 to 47, the bus in 24 to 31, the device in 19 to 23, the function
     * in 16 to 18 and the offset in 0 to 15, as aml.pci_address makes it.
     */
    address : u64,
    /** The bits read or written: 8, 16 or 32. */
    width : u32,
    /** What's written; ignored for a read. */
    value : u64,
}

/** S5's sleep types, `\_S5`'s first two elements, for turning the machine off (decisions/0182). */
SleepTypes :: struct {
    /** PM1a's, 0 to 7. */
    a : u8,
    /** PM1b's, 0 to 7, ignored without a PM1b block. */
    b : u8,
}

/** A window of the host bridge's, as its _CRS gives it: memory the platform service places BARs in. */
BridgeWindow :: struct {
    /** Where it starts as the CPU sees it, a physical address. */
    cpu : u64,
    /** Where it starts as its devices see it, a PCI bus address: cpu less _CRS's translation. */
    pci : u64,
    /** Its bytes, at least 1 MiB. */
    size : u64,
    /** Whether it's prefetchable, as _CRS's memory attribute says. */
    prefetchable : bool,
}

/** The most windows HostWindows gives. */
MAX_BRIDGE_WINDOWS :: 4

/** The host bridge's memory windows, as its _CRS gives them (decisions/0182, P3). */
BridgeWindows :: struct {
    /** The windows, the first count of them. */
    windows : BridgeWindow[MAX_BRIDGE_WINDOWS],
    /** How many there are, 0 to MAX_BRIDGE_WINDOWS. */
    count : u32,
}

/** What a client, the supervisor or the clock, terminal or ACPI service, asks the platform service. */
Request :: union {
    /**
     * Claim the next device that matches and nothing has claimed, which nothing else will. Answered with Claimed,
     * or NoDevice when nothing unclaimed matches.
     */
    Claim(Wanted),
    /**
     * Have the platform service serve another client, on the end given, which moves to it; it's closed if the
     * service already has as many clients as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[Platform]),
    /**
     * Ask for a device this client claimed, by its address (slop_os.device_address), given again, made anew: the
     * last bundle died with its driver. A device not claimed here, as after the platform service was started again,
     * is claimed by the client asking. Answered with Claimed, or NoDevice when no device has that address, another
     * client claimed it, or it can't be made.
     */
    Reissue(u32),
    /**
     * Claim the real-time clock, unless another client has claimed it; given again, made anew, to the client that
     * has. Answered with ClaimedClock, or NoDevice.
     */
    ClaimClock,
    /** Claim the first framebuffer, as ClaimClock claims the clock. Answered with ClaimedFramebuffer, or NoDevice. */
    ClaimFramebuffer,
    /**
     * Claim ACPI, for the ACPI service: the firmware tables, and the SCI. The client asking is the claimer from then
     * on, so an ACPI service started again claims it again; the requests after are the claimer's alone. Answered with
     * ClaimedAcpi, or NoDevice where the firmware tables have no FADT or no DSDT.
     */
    ClaimAcpi,
    /**
     * I/O ports for an AML region, made anew. Answered with GivenPorts, or Refused for a client that hasn't claimed
     * ACPI, or for ports past 65535 or among the PCI configuration mechanism's, 0xcf8 to 0xcff.
     */
    Ports(PortRange),
    /**
     * Device memory for an AML region, its pages made anew. Answered with GivenMemory, of the whole pages the range is
     * in; or Refused for a client that hasn't claimed ACPI, a range over 16 MiB, or one overlapping RAM the kernel
     * owns or the host bridge's configuration space.
     */
    PhysicalMemory(MemoryRange),
    /**
     * Read a PCI function's configuration space, for a PCI_Config region. Answered with ConfigValue, or Refused for a
     * client that hasn't claimed ACPI, a function the host bridge doesn't reach, or an access past its 4 KiB.
     */
    ConfigRead(ConfigAccess),
    /**
     * Write a PCI function's configuration space. Answered with Done, or Refused as ConfigRead is, and for a write to
     * a type 0 header's command register or BARs, which only the platform service sets.
     */
    ConfigWrite(ConfigAccess),
    /**
     * S5's sleep types, which the platform service gives the kernel with the FADT's PM1 control registers
     * (power_set_off), so the machine can be turned off. Answered with Done, or Refused for a client that hasn't
     * claimed ACPI, a machine without PM1a's control block, or the kernel refusing them.
     */
    GiveSleepTypes(SleepTypes),
    /**
     * The host bridge's memory windows, from its _CRS, which BARs are placed in rather than the gaps the memory map
     * leaves (decisions/0074, 0182). Until the claimer gives them, or a few seconds pass, the platform service places
     * no BARs, and answers no Claim or Reissue. Answered with Done, or Refused for a client that hasn't claimed ACPI.
     * Given once the BARs are placed, as by an ACPI service started again, they're kept but don't move what's placed.
     */
    HostWindows(BridgeWindows),
}

/** What the platform service answers. */
Response :: union {
    /** Claim's or Reissue's answer: the device, and what its driver holds of it, which moves to the client. */
    Claimed(PciDevice),
    /**
     * The answer when there's no device left that matches, none at the address, or it's another client's, or what's
     * asked for couldn't be made.
     */
    NoDevice,
    /** The answer to a request the platform service doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
    /** ClaimClock's answer: the clock, with its ports or registers made anew, which move to the client. */
    ClaimedClock(RealTimeClock),
    /** ClaimFramebuffer's answer: the framebuffer, with its memory made anew, which moves to the client. */
    ClaimedFramebuffer(Framebuffer),
    /** ClaimAcpi's answer: the firmware tables and the SCI, which move to the client. */
    ClaimedAcpi(AcpiHardware),
    /** Ports' answer: the ports, which move to the client. */
    GivenPorts(slop_os.IoPortRange),
    /** PhysicalMemory's answer: the device memory, its first byte at the range's address rounded down to a page. */
    GivenMemory(slop_os.Memory),
    /** ConfigRead's answer: what was read, its upper bits 0. */
    ConfigValue(u64),
    /** ConfigWrite's, GiveSleepTypes' and HostWindows' answer: it's done. */
    Done,
    /** The answer to a request of the ACPI service's that's refused, as each says. */
    Refused,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Claim, which sent again would claim another device, and Reissue; true for the others, which
 *     the same client is given again, or which do what they did once more.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Claim(_) => false
        case Connect(_) => true
        case Reissue(_) => false
        case ClaimClock => true
        case ClaimFramebuffer => true
        case ClaimAcpi => true
        case Ports(_) => true
        case PhysicalMemory(_) => true
        case ConfigRead(_) => true
        case ConfigWrite(_) => true
        case GiveSleepTypes(_) => true
        case HostWindows(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to the platform service: a channel for the protocol, one end sent to it in a Connect, as
 * entropy.connect does.
 *
 * It doesn't wait: the service takes the end when it next serves its listener, or closes it when it's full, which the
 * caller learns of as its end's peer gone.
 *
 * @param end The service's listener, or any connection to it, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end: slop_os.Channel, port: slop_os.Port, budget: slop_os.MemoryBudget) -> os.Channel[Platform]? {
    pair :: os.channel_for[Platform](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[Platform].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[Platform].{end = pair.b}
    }
}
