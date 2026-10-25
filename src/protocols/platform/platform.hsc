package platform

import os from "std"
import slop_os from "std/os"

/*
 * The platform service's protocol (decisions/0074): the devices it found, each claimed once, by the supervisor, for a
 * driver system_config names, with everything the driver holds of it. Connections arrive on its listener as Connects.
 */

Platform :: struct {}

PROTOCOL :: slop_os.Protocol.{name = "platform", major_version = 1, lending = .Server}

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

/*
 * A device, and what its driver holds of it: its Device (slop_os.device_create), a window onto its 4 KiB of
 * configuration space, each BAR it has as device memory (NO_HANDLE for one it hasn't, or the upper half of a 64-bit
 * one), and a DMA domain it's attached to.
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

Request :: union {
    // The next device that matches and nothing has claimed, which nothing else will
    Claim(DeviceMatch),
    // Serve another client, on its end
    Connect(os.Channel[Platform]),
}

Response :: union {
    Claimed(PciDevice),
    // No device left that matches
    NoDevice,
    Unsupported,
}

// A claim sent again would claim another device.
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return match request^ {
        case Claim(_) => false
        case Connect(_) => true
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
