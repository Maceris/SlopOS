package hotplug

import os from "std:os"
import slop_os from "std:os/slop_os"
import connector from "../connector"

/*
 * What the supervisor tells a service of devices found after the service started (decisions/0202, 21d): a USB keyboard
 * or mouse plugged in, for the input service, or a USB stick, for the storage manager. Each comes as a connector to its
 * class driver, as the devices found at start come in the service's grants. One unplugged isn't told of: the supervisor
 * closes its end of the device's connector, which the service sees as the connector's peer gone, and stops its driver.
 * Only the supervisor holds the client's end, so nothing else can give a service a device.
 */

/**
 * The hotplug protocol, for the channel between the supervisor, which sends, and a service that takes devices, which
 * serves it.
 */
Hotplug :: struct {}

/** What the protocol says of itself: its name, its major version, and that the service pays for its own work. */
PROTOCOL :: os.Protocol.{name = "hotplug", major_version = 1, lending = .Server}

/** What the supervisor sends. */
Request :: union {
    /**
     * A device found: a connector to its driver, which moves to the service, dialed for the protocol the service takes
     * devices in (input or block). Unanswered; a service with no room for it closes it.
     */
    Added(os.Channel[connector.Connector]),
}

/** What a service answers. */
Response :: union {
    /** The answer to a request the service doesn't know; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Added: a second would give the service the device twice.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Added(_) => false
    }
}

#insert os.protocol_code(Request, Response)
