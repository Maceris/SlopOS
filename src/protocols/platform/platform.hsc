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

/** What a client, the supervisor or the clock or terminal service, asks the platform service. */
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
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Claim, which sent again would claim another device, and Reissue; true for Connect, ClaimClock and
 *     ClaimFramebuffer, which the same client is given again.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Claim(_) => false
        case Connect(_) => true
        case Reissue(_) => false
        case ClaimClock => true
        case ClaimFramebuffer => true
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
