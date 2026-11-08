package power

import os from "std"
import slop_os from "std/os"

/*
 * Asking for the system to shut down or restart (decisions/0180, 0182): the supervisor serves it, to the terminal
 * service, whose secure attention key's screen asks it for the person at the console, and to what brings the power
 * button, the ACPI service or a GPIO controller's driver; and passes it on to the root task, which has the kernel turn
 * the machine off or reset it once it ends, and with it everything. Only who holds a connection can ask.
 */

/**
 * The power protocol, for the channels between the supervisor and the terminal service, and what brings the power
 * button: they send the requests, and the supervisor answers them.
 */
Power :: struct {}

/**
 * What the protocol says of itself: its name, which its channels' tag is made from, its major version, and that the
 * server, here the supervisor, pays for its work from its own budget.
 */
PROTOCOL :: slop_os.Protocol.{name = "power", major_version = 1, lending = .Server}

/** What the terminal service, or what brings the power button, asks the supervisor. */
Request :: union {
    /**
     * Shut the system down: the root task is told, and ends, ending everything, and the machine is turned off where
     * the kernel can. Answered with Done once the root task is told, which may not be seen before the system's gone;
     * Refused if it couldn't be told.
     */
    ShutDown,
    /**
     * Restart the system: as ShutDown, but the machine is reset, so it boots again. Answered as ShutDown is; once
     * either is asked, the other is answered Done and changes nothing.
     */
    Restart,
    /** The power button was pressed: shut the system down, as ShutDown does (decisions/0182). Answered as it is. */
    PowerButton,
}

/** What the supervisor answers. */
Response :: union {
    /** ShutDown's, Restart's and PowerButton's answer: the root task's been told. */
    Done,
    /** Their answer when the root task couldn't be told, as when its channel's gone. */
    Refused,
    /** The answer to a request the supervisor doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return True: shutting down or restarting again changes nothing.
 */
is_idempotent :: fn(request: ptr[Request]) -> bool {
    return true
}

#insert os.protocol_code(Request, Response)
