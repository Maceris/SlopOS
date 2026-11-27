package usb_device

import os from "std:os"
import slop_os from "std:os/slop_os"

/*
 * One interface of a USB device (decisions/0201, 20d), as its host controller's driver serves it to the class driver
 * the supervisor started for it: a keyboard's, a mouse's or a disk's. The host controller's driver addresses the device
 * and sets its configuration; a connection reaches only its interface's endpoints, and its default control endpoint
 * for what isn't the host controller's to do (SET_ADDRESS, SET_CONFIGURATION and SET_INTERFACE are refused). Data moves
 * through a buffer the host controller's driver makes for each connection, DMA memory a client reaches through a window
 * (GetBuffer), as the block protocol's does. A client may have several requests in flight, each with a tag of its own
 * choosing, answered as the device finishes them, in any order; at most one at a time on each endpoint, as a USB
 * endpoint's transfers run in order. Connections arrive on the interface's listener as Connects.
 */

/** The USB device protocol, for the channels between a host controller's driver and the class driver of an interface. */
UsbDevice :: struct {}

/** What the protocol says of itself: its name, its major version, and that the client's budget is lent for each connection. */
PROTOCOL :: slop_os.Protocol.{name = "usb_device", major_version = 1, lending = .PerConnection}

/** The most endpoints an interface's Info lists: 4, as the class drivers here use two at most. */
MAX_ENDPOINTS :: 4

/** How fast the device talks. */
Speed :: enum #backed_by(u8) {
    /** 1.5 Mb/s, USB 1's low speed. */
    Low = 0,
    /** 12 Mb/s, USB 1's full speed. */
    Full = 1,
    /** 480 Mb/s, USB 2's high speed. */
    High = 2,
    /** 5 Gb/s or more, USB 3's SuperSpeed. */
    Super = 3,
}

/** What an endpoint moves, as its descriptor's bmAttributes bits 1:0 say. */
EndpointKind :: enum #backed_by(u8) {
    Control = 0,
    Isochronous = 1,
    Bulk = 2,
    Interrupt = 3,
}

/** One of the interface's endpoints, from its descriptor. */
Endpoint :: struct {
    /** Its address: its number in bits 3:0, and bit 7 set for one that's IN, the device to the host. */
    address : u8,
    /** What it moves; an isochronous one is listed but can't be transferred on. */
    kind : EndpointKind,
    /** The most bytes in one of its packets. */
    max_packet : u16,
    /** Its descriptor's bInterval, as the device gave it, for an interrupt endpoint how often it's polled. */
    interval : u8,
}

/** What the interface is, and the device it's on. */
Info :: struct {
    /** The device's vendor and product IDs. */
    vendor : u16,
    product : u16,
    /** How fast it talks. */
    speed : Speed,
    /** The interface's number, which a class request's wIndex names. */
    interface : u8,
    /** Its class, subclass and protocol, as 3, 1, 1 for a boot keyboard. */
    class : u8,
    subclass : u8,
    protocol : u8,
    /** How many of endpoints are listed, 0 to MAX_ENDPOINTS. */
    endpoint_count : u8,
    /** Its endpoints, the default control endpoint not among them. */
    endpoints : Endpoint[MAX_ENDPOINTS],
    /** The size of the connection's buffer, in bytes, which a transfer's data has to fit. */
    buffer_bytes : u64,
}

/** A control transfer's setup packet (USB 2.0 §9.3). */
Setup :: struct {
    /** bmRequestType: bit 7 set for data IN, bits 6:5 standard, class or vendor, bits 4:0 the recipient. */
    request_type : u8,
    /** bRequest. */
    request : u8,
    /** wValue. */
    value : u16,
    /** wIndex. */
    index : u16,
    /** wLength: the data stage's bytes, 0 for none. */
    length : u16,
}

/** A control transfer on the default control endpoint, its data in the connection's buffer at offset. */
Control :: struct {
    /** The client's own value, given back in the Finished that answers it. */
    tag : u64,
    /** The setup packet. */
    setup : Setup,
    /** Where its data stage's setup.length bytes are in the buffer: read from for OUT, written for IN. */
    offset : u32,
}

/** A bulk or interrupt transfer on one of the interface's endpoints, its data in the connection's buffer. */
Transfer :: struct {
    /** The client's own value, given back in the Finished that answers it. */
    tag : u64,
    /** The endpoint's address, as Info lists it; its direction is the transfer's. */
    endpoint : u8,
    /** Where the data is in the buffer, in bytes from its start. */
    offset : u32,
    /** How many bytes: at most this many for IN, which may be fewer; exactly this many for OUT. At least 1. */
    length : u32,
}

/** How a request went. */
Status :: enum #backed_by(u32) {
    /** It's done: Completion.length says how many bytes moved, which for IN may be fewer than asked. */
    Done = 0,
    /** Past the buffer's end, a length of 0, or asked before the connection had a buffer. */
    OutOfRange = 1,
    /** An endpoint that isn't the interface's, an isochronous one, or the wrong direction for it. */
    NoEndpoint = 2,
    /** A request the host controller's driver keeps for itself: SET_ADDRESS, SET_CONFIGURATION or SET_INTERFACE. */
    Refused = 3,
    /** The device stalled it: the request isn't one it takes, or the endpoint's halted until ResetEndpoint. */
    Stalled = 4,
    /** The transfer failed on the bus, or the controller said it failed. */
    DeviceError = 5,
    /** The endpoint already has a request in flight, or every slot for one is taken: send it again once one's answered. */
    Busy = 6,
    /** The device was unplugged; every request from now on is answered Gone. */
    Gone = 7,
}

/** A request answered: its tag, how it went, and how many bytes moved. */
Completion :: struct {
    /** The tag the request was sent with. */
    tag : u64,
    /** How it went. */
    status : Status,
    /** How many bytes of its data moved; 0 for one that failed before any did. */
    length : u32,
}

/** What a class driver asks for its interface. */
Request :: union {
    /** Ask what the interface is. Answered with Described. */
    Describe,
    /** A control transfer. Answered with Finished, once the device has, or at once if not sent. */
    Control(Control),
    /** A bulk or interrupt transfer. Answered with Finished, once the device has, or at once if not sent. */
    Transfer(Transfer),
    /**
     * Clear a halt on an endpoint, the device's (CLEAR_FEATURE ENDPOINT_HALT) and the controller's, its tag given
     * back. Answered with Finished.
     */
    ResetEndpoint(ResetEndpoint),
    /**
     * Ask for a window onto the connection's buffer, read-write, made at the first ask. Answered with Buffer, or
     * Unsupported when it couldn't be made.
     */
    GetBuffer,
    /**
     * Have the driver serve another client for the interface, on the end given, which moves to it; it's closed if the
     * driver already has as many as it takes. Sent on the listener, and answered with nothing.
     */
    Connect(os.Channel[UsbDevice]),
}

/** ResetEndpoint's request: which endpoint, and the client's tag. */
ResetEndpoint :: struct {
    /** The client's own value, given back in the Finished that answers it. */
    tag : u64,
    /** The endpoint's address, as Info lists it. */
    endpoint : u8,
}

/** What a host controller's driver answers. */
Response :: union {
    /** Control's, Transfer's or ResetEndpoint's answer, in the order the device finishes them. */
    Finished(Completion),
    /** Describe's answer. */
    Described(Info),
    /** GetBuffer's answer: a window onto the connection's buffer, buffer_bytes of it, which moves to the client. */
    Buffer(slop_os.Memory),
    /** The answer to a request the driver doesn't know, as from a newer client; every protocol has it. */
    Unsupported,
}

/**
 * Tell whether a request may be sent again, after a reconnect, without doing more than sending it once did.
 *
 * @param request The request, which isn't changed.
 * @return False for Control and Transfer, which may have side effects on the device (a disk's command, a class
 *     request); true for the rest.
 */
is_idempotent :: fn(request : ptr[Request]) -> bool {
    return match request^ {
        case Describe => true
        case Control(_) => false
        case Transfer(_) => false
        case ResetEndpoint(_) => true
        case GetBuffer => true
        case Connect(_) => true
    }
}

#insert os.protocol_code(Request, Response)

/**
 * Make a new connection to an interface: a channel for the protocol, one end sent to the host controller's driver in
 * a Connect, as block.connect does.
 *
 * It doesn't wait: the driver takes the end when it next serves the interface, or closes it when it's full or the
 * device is gone, which the caller learns of as its end's peer gone.
 *
 * @param end A connection to the interface, kept by the caller.
 * @param port A port bound to end, waited on while end's ring is full.
 * @param budget The memory budget that pays for the new channel.
 * @return The caller's end of the new connection, its own to keep and close; null if the channel couldn't be made, or
 *     the Connect couldn't be sent, in which case both its ends are closed.
 */
connect :: fn(end : slop_os.Channel, port : slop_os.Port, budget : slop_os.MemoryBudget) -> os.Channel[UsbDevice]? {
    pair :: os.channel_for[UsbDevice](budget, 0) or_return null
    out := os.Outgoing.{}
    request :: os.begin[Request](&out)
    request^ = .Connect(os.Channel[UsbDevice].{end = pair.a})
    match send_request(end, port, &out) {
        case Some(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.a))
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return null
        }
        case None => return os.Channel[UsbDevice].{end = pair.b}
    }
}
