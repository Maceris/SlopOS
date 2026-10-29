package platform

import os from "std"
import slop_os from "std/os"

/*
 * The platform service's protocol (decisions/0074, 0077, 0093): the devices it found, each claimed once, by the supervisor,
 * for a driver system_config names, with everything the driver holds of it, and given again for a driver that's
 * restarted; and the real-time clock, for the clock service, claimed by one client, which may claim it again, made anew.
 * Connections arrive on its listener as Connects.
 */

Platform :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "platform", major_version = 3, lending = .Server}

// A DeviceMatch's vendor, device or class that matches any.
ANY_ID : u16 : 0xffff
ANY_CLASS : u32 : 0xffffffff

// Which devices a driver takes: a vendor's device, or a class (its base class, subclass and programming interface,
// as the class register's top 24 bits), each ANY for any.
DeviceMatch :: struct {
    vendor : u16,
    device : u16,
    class : u32,
}

// What a Claim wants: devices that match, for a driver trusted with DMA no IOMMU confines, or not (decisions/0084).
Wanted :: struct {
    devices : DeviceMatch,
    trusted : bool,
}

/*
 * A device, and what its driver holds of it: its Device (slop_os.device_create), a window onto its 4 KiB of
 * configuration space, each BAR it has as device memory (NO_HANDLE for one it hasn't, or the upper half of a 64-bit
 * one), and a DMA domain it's attached to: trusted with DMA memory where no IOMMU confines it only if the claim was.
 */
PciDevice :: struct {
    // Its segment and requester ID (slop_os.device_address)
    address : u32,
    vendor : u16,
    device_id : u16,
    class : u32,
    device : slop_os.Device,
    config : slop_os.Memory,
    bar0 : slop_os.Memory,
    bar1 : slop_os.Memory,
    bar2 : slop_os.Memory,
    bar3 : slop_os.Memory,
    bar4 : slop_os.Memory,
    bar5 : slop_os.Memory,
    domain : slop_os.DmaDomain,
}

// Which real-time clock a ClaimedClock is.
ClockKind :: enum #backed_by(u32) {
    // x86's MC146818, at I/O ports 0x70 and 0x71: its index register, then its data register
    Mc146818 = 1,
    // Arm's PL031, its registers' 4 KiB, from the device tree's arm,pl031
    Pl031 = 2,
}

// The real-time clock, and what its driver holds of it: its ports, or its registers, NO_HANDLE for the other.
RealTimeClock :: struct {
    kind : ClockKind,
    ports : slop_os.IoPortRange,
    registers : slop_os.Memory,
}

Request :: union {
    // The next device that matches and nothing has claimed, which nothing else will
    Claim(Wanted),
    // Serve another client, on its end
    Connect(os.Channel[Platform]),
    // A device this client claimed, at its address, given again, made anew: the last bundle died with its driver
    Reissue(u32),
    // The real-time clock, unless another client has claimed it; given again, made anew, to the client that has
    ClaimClock,
}

Response :: union {
    Claimed(PciDevice),
    // No device left that matches
    NoDevice,
    Unsupported,
    ClaimedClock(RealTimeClock),
}

// A claim sent again would claim another device.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Claim(_) => false
        case Connect(_) => true
        case Reissue(_) => false
        case ClaimClock => true
    }
}

#insert os.protocol_code(Request, Response)

// A new connection to the service listening on end, or null (as entropy.connect).
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
