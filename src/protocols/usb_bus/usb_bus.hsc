package usb_bus

import os from "std:os"
import slop_os from "std:os/slop_os"
import usb_device from "../usb_device"

/*
 * What a USB host controller's driver tells the supervisor of the devices it finds (decisions/0201, 20d): each
 * interface of each device it's addressed and configured, through hubs too, with a connection the supervisor makes
 * its class driver's connections through; that what it found at start is all there (Settled); and an interface gone
 * when its device is unplugged. The supervisor holds a Next, answered with the next of these, in order.
 */

/** The USB bus protocol, for the channels between a host controller's driver, which answers, and the supervisor. */
UsbBus :: struct {}

/** What the protocol says of itself: its name, its major version, and that the client's budget is lent per connection. */
PROTOCOL :: slop_os.Protocol.{name = "usb_bus", major_version = 1, lending = .PerConnection}

/** An interface found. */
Interface :: struct {
    /**
     * What names it on the controller, the same each time it's found on the same port: the device's route string
     * (bits 19:0, a hub's port for each tier), its root port (27:20) and the interface's number (35:28).
     */
    key : u64,
    /** The device's vendor and product IDs. */
    vendor : u16,
    product : u16,
    /** The interface's class, subclass and protocol, which the class driver is chosen by. */
    class : u8,
    subclass : u8,
    protocol : u8,
    /**
     * A connection to the interface, which moves to the supervisor: its usb_device.Connects make the class driver's
     * connections. It's closed by the driver, as its peer gone, when the device is.
     */
    device : os.Channel[usb_device.UsbDevice],
}

/** What the supervisor asks. */
Request :: union {
    /** Ask for the next thing found; held until there's one. Answered with Attached, Detached or Settled. */
    Next,
    /** Have the driver serve another client, on the end given, which moves to it. Sent on the listener, unanswered. */
    Connect(os.Channel[UsbBus]),
}

/** What the host controller's driver answers. */
Response :: union {
    /** An interface found, each once to one client. */
    Attached(Interface),
    /** An interface gone, by its key, as its device was unplugged. */
    Detached(u64),
    /** Everything found on the ports at the driver's start has been Attached; once to each client. */
    Settled,
    /** The answer to a request the driver doesn't know; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True for every request: a Next again waits for the next thing found.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Next => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)
