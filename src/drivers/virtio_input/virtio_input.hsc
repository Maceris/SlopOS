/**
 * The virtio-input driver (decisions/0077): a virtio input device's event queue, through the virtio-pci transport
 * (src/virtio), as the input protocol for its clients, who arrive on its listener. The device's events are Linux's
 * evdev (type, code, value) triples; each becomes one of the protocol's: a key by its USB HID usage, a button, a
 * pointer's motion or position, a wheel. They wait in order until a held Read takes them, and every client's Read
 * gets each, so two clients both see a key.
 */
package virtio_input

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import pci from "../../pci"
import input from "../../protocols/input"
import service_kit from "../../libraries/service_kit"
import virtio from "../../virtio"

/** The bytes of a page: 4096. */
PAGE : u64 : 4096
/** The index of the device's event queue, eventq (virtio 1.2 §5.8.2). */
EVENT_QUEUE : u16 : 0
/** How many event buffers the device always has offered: 32. */
EVENT_BUFFERS :: 32
/** The bytes of each event buffer, one virtio_input_event: 8. */
EVENT_BYTES : u64 : 8
/**
 * How many events the driver keeps for clients that haven't had them, 64; a client further behind misses the oldest.
 */
WAITING :: 64
/** The port key the device's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000

// ---- evdev's event types, and the codes that aren't keys (Linux's input-event-codes.h)

/** evdev's event type of a synchronization, which ends a group of events; dropped here. */
EV_SYN : u16 : 0
/** evdev's event type of a key or a button, its value 1 down, 2 repeating, 0 up. */
EV_KEY : u16 : 1
/** evdev's event type of a relative axis's motion. */
EV_REL : u16 : 2
/** evdev's event type of an absolute axis's position. */
EV_ABS : u16 : 3
/** evdev's relative axis code across. */
REL_X : u16 : 0
/** evdev's relative axis code down. */
REL_Y : u16 : 1
/** evdev's relative axis code of the wheel. */
REL_WHEEL : u16 : 8
/** evdev's absolute axis code across. */
ABS_X : u16 : 0
/** evdev's absolute axis code down. */
ABS_Y : u16 : 1
/** evdev's code of the first mouse button, the left, which is button 0 here. */
BTN_LEFT : u16 : 0x110
/** evdev's code of the last mouse button taken as a button, button 7 here. */
BTN_LAST : u16 : 0x117

/**
 * evdev's key codes from 0 to 127, as USB HID usages (page 7), 0 for one that has none here.
 *
 * SPEC: Linux's input-event-codes.h; USB HID Usage Tables 1.4, §10 (Keyboard/Keypad Page)
 */
HID_OF_KEY :: u8.[
    0x00, 0x29, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e, 0x2a, 0x2b,
    0x14, 0x1a, 0x08, 0x15, 0x17, 0x1c, 0x18, 0x0c, 0x12, 0x13, 0x2f, 0x30, 0x28, 0xe0, 0x04, 0x16,
    0x07, 0x09, 0x0a, 0x0b, 0x0d, 0x0e, 0x0f, 0x33, 0x34, 0x35, 0xe1, 0x31, 0x1d, 0x1b, 0x06, 0x19,
    0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xe5, 0x55, 0xe2, 0x2c, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e,
    0x3f, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, 0x5f, 0x60, 0x61, 0x56, 0x5c, 0x5d, 0x5e, 0x57, 0x59,
    0x5a, 0x5b, 0x62, 0x63, 0x00, 0x00, 0x64, 0x44, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x58, 0xe4, 0x54, 0x46, 0xe6, 0x00, 0x4a, 0x52, 0x4b, 0x50, 0x4f, 0x4d, 0x51, 0x4e, 0x49, 0x4c,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe3, 0xe7, 0x65,
]

/** An event as the device writes it, virtio_input_event (virtio 1.2 §5.8.6): an evdev triple, little-endian. */
DeviceEvent :: struct #packed {
    /** Its evdev type, EV_ and the rest. */
    kind : u16le,
    /** Its evdev code, a key's, a button's or an axis's. */
    code : u16le,
    /** Its value: for a key 1 down, 2 repeating, 0 up; for an axis, a signed amount or position. */
    value : u32le,
}

#assert size_of(DeviceEvent) == 8

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log. */
    log : slop_os.DebugLog,
    /** The device's registers. */
    transport : virtio.Transport,
    /** The event queue, which EVENT_BUFFERS buffers are always offered on. */
    queue : virtio.Queue,
    /** Where the event buffers' page is, through the driver's mapping, EVENT_BYTES each. */
    buffers : u64,
    /** Where the same page is to the device, its device address. */
    buffers_device : u64,
    /** Which buffer each descriptor holds, by descriptor index. */
    buffer_of : u8[virtio.MAX_QUEUE_SIZE],
    /** The one port its interrupt and its clients are bound to. */
    port : slop_os.Port,
    /** The events kept for clients, a ring: event n is at n % WAITING, for the last WAITING written. */
    waiting : input.Event[WAITING],
    /** How many events have been written in all; only grows. */
    written : u64,
    /** Each client's next event, by its index: the number of the first it hasn't had. */
    next_of : u64[service_kit.MAX_CLIENTS],
    /** Each client's held Read, by its index: the most events it takes, or 0 for none held. */
    held : u32[service_kit.MAX_CLIENTS],
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
    /** A tablet's position across so far, which each ABS_X changes. */
    x : i32,
    /** A tablet's position down so far, which each ABS_Y changes. */
    y : i32,
}

/**
 * Drive a virtio input device, a keyboard, mouse or tablet, as the input protocol, for the clients that connect to it.
 *
 * It sets the device up, keeps EVENT_BUFFERS buffers offered, turns each evdev event into one of the protocol's, and
 * gives every client every event that arrives after it connected, until the system stops. It's started by the
 * supervisor, for a device the platform service gave it, with what its driver holds of it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The device, for its MSI.
 * @param config The device's 4 KiB of configuration space, mapped to find its capabilities and turn bus mastering on.
 * @param bar0 BAR 0's memory, if the device has it; each BAR given is mapped, for the virtio structures in it.
 * @param bar1 BAR 1's memory, if the device has it.
 * @param bar2 BAR 2's memory, if the device has it.
 * @param bar3 BAR 3's memory, if the device has it.
 * @param bar4 BAR 4's memory, if the device has it.
 * @param bar5 BAR 5's memory, if the device has it.
 * @param domain The DMA domain the device is attached to, which its queue and buffers are made in.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had (decisions/0104), 2 if config couldn't
 *     be mapped, 3 if the device isn't a virtio one it can drive, 4 if it refused its features, 5 if no port could be
 *     made, 6 if its MSI couldn't be set up, 7 if its DMA memory couldn't be made or mapped, 8 if its queue couldn't
 *     be set up, 9 if the listener couldn't be bound.
 */
main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    clients: os.Listener[input.Input]) -> int {
    startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    driver.transport = virtio.open(config_at, bars) or_return 3
    _ = virtio.start(&driver.transport, 0) or_return 4

    driver.port = slop_os.port_create(startup.budget) or_return 5
    irq :: slop_os.irq_create_msi(device, startup.budget) or_return 6
    message :: slop_os.irq_message(irq) or_return 6
    if !virtio.set_vector(&driver.transport, 0, message.address, message.data) {
        return 6
    }
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent) or_return 6

    memory :: slop_os.dma_memory_create(domain, startup.budget, 2 * PAGE, 0) or_return 7
    pages :: runtime.reserve_addresses(cast[usize](2 * PAGE)) or_return 7
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, startup.space, pages, 0, 2 * PAGE, read_write) or_return 7
    device_address :: slop_os.memory_device_address(memory) or_return 7
    driver.queue = virtio.setup_queue(&driver.transport, EVENT_QUEUE, pages, device_address, 0) or_return 8
    driver.buffers = pages + PAGE
    driver.buffers_device = device_address + PAGE
    virtio.ready(&driver.transport)
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)
    for buffer in 0..<EVENT_BUFFERS {
        offer_buffer(driver, cast[u8](buffer))
    }

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    runtime.log_info("serving")
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
        take_events(driver)
        answer_held(driver)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Take every request a client has sent, until there are none left, or it's gone.
 *
 * A Read is held, replacing one held, to be answered once there are events; a Connect adds a client, which sees what
 * arrives from then on, closing its end when there's no room. An unknown request is answered Unsupported, and
 * anything else is skipped.
 *
 * @param driver The driver, whose clients, next events and held Reads change.
 * @param index Which client, by its index; one past them, or a freed place, is nothing to serve. A client whose end
 *     failed is dropped, and its held Read with it.
 * @param into Where each request is received, reused for each.
 */
serve :: fn(driver: ptr[mut Driver], index: usize, into: ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match input.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = input.answer_unsupported(end, driver.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(&driver.clients, index)
                if index < driver.held.count {
                    driver.held[index] = 0
                }
                return void
            }
            case _ => continue
        }
        match os.message_of[input.Request](into)^ {
            case Read(most) => {
                if index < driver.held.count {
                    driver.held[index] = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case Connect(connection) => {
                // A new client sees what arrives from now on
                match service_kit.add_client_index(&driver.clients, driver.port, connection.end) {
                    case Some(added) => {
                        if added < driver.next_of.count {
                            driver.next_of[added] = driver.written
                        }
                        if added < driver.held.count {
                            driver.held[added] = 0
                        }
                    }
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Offer an event buffer to the device to write into, noting which buffer its descriptor holds.
 *
 * @param driver The driver, its event queue offered the buffer.
 * @param buffer Which buffer, 0 to EVENT_BUFFERS - 1.
 */
offer_buffer :: fn(driver: ptr[mut Driver], buffer: u8) {
    id :: virtio.offer(&driver.queue, driver.buffers_device + cast[u64](buffer) * EVENT_BYTES, cast[u32](EVENT_BYTES), true)
    if cast[usize](id) < driver.buffer_of.count {
        driver.buffer_of[id] = buffer
    }
}

/**
 * Take the device's events, as the protocol's, into what's waiting, offering each buffer again.
 *
 * An event with nothing in the protocol, like a SYN, is dropped; one past WAITING ahead of a client overwrites the
 * oldest it hasn't had.
 *
 * @param driver The driver, whose waiting events grow.
 */
take_events :: fn(driver: ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.queue) or_break
        buffer :: if cast[usize](used.id) < driver.buffer_of.count { driver.buffer_of[used.id] } else { cast[u8](0) }
        raw :: cast[ptr[DeviceEvent]](driver.buffers + cast[u64](buffer) * EVENT_BYTES)
        kind : u16 = raw.kind
        code : u16 = raw.code
        value : u32 = raw.value
        offer_buffer(driver, buffer)
        match translate(driver, kind, code, value) {
            case Some(event) => {
                driver.waiting[cast[usize](driver.written % WAITING)] = event
                driver.written += 1
            }
            case None => {}
        }
    }
}

/**
 * Turn an evdev event into the protocol's.
 *
 * Mouse buttons BTN_LEFT to BTN_LAST are Buttons 0 to 7; a key code below 128 with a HID usage is a Key; REL_X and
 * REL_Y are Motion, REL_WHEEL a Wheel; ABS_X and ABS_Y update the tablet's position and give it whole, as Position.
 *
 * @param driver The driver, whose tablet position an absolute axis's event changes.
 * @param kind The evdev event type: EV_KEY, EV_REL or EV_ABS give events, any other none.
 * @param code The evdev code: a key's, a button's or an axis's, as kind says.
 * @param value The evdev value, taken as signed for an axis.
 * @return The protocol's event; null for one it has nothing for, like a SYN or a key without a usage here.
 */
translate :: fn(driver: ptr[mut Driver], kind: u16, code: u16, value: u32) -> input.Event? {
    signed :: bit_cast[i32](value)
    if kind == EV_KEY && code >= BTN_LEFT && code <= BTN_LAST {
        return input.event_of(.Button, value != 0, code - BTN_LEFT, 0, 0)
    }
    if kind == EV_KEY && cast[usize](code) < HID_OF_KEY.count {
        usage :: HID_OF_KEY[cast[usize](code)]
        if usage == 0 {
            return null
        }
        // 1 pressed, 2 held down and repeating, 0 let go
        return input.event_of(.Key, value != 0, cast[u16](usage), 0, 0)
    }
    if kind == EV_REL && (code == REL_X || code == REL_Y) {
        return input.event_of(.Motion, false, 0, if code == REL_X { signed } else { 0 }, if code == REL_Y { signed } else { 0 })
    }
    if kind == EV_REL && code == REL_WHEEL {
        return input.event_of(.Wheel, false, 0, 0, signed)
    }
    if kind == EV_ABS && (code == ABS_X || code == ABS_Y) {
        if code == ABS_X {
            driver.x = signed
        }
        else {
            driver.y = signed
        }
        return input.event_of(.Position, false, 0, driver.x, driver.y)
    }
    return null
}

/**
 * Answer each held Read with the events its client hasn't had, oldest first, as many as it asked for and
 * input.MAX_EVENTS.
 *
 * A client a whole ring behind skips to the oldest still kept. A response that can't be sent is dropped, its events
 * counted as had.
 *
 * @param driver The driver, whose clients' next events move on and held Reads are cleared as they're answered.
 */
answer_held :: fn(driver: ptr[mut Driver]) {
    for &most, index in driver.held {
        if most^ == 0 || index >= driver.clients.ends.count || index >= driver.next_of.count {
            continue
        }
        next := driver.next_of[index]
        // A client that fell a whole ring behind skips to the oldest still waiting
        if driver.written - next > WAITING {
            next = driver.written - WAITING
        }
        if next == driver.written {
            continue
        }
        taken : input.Event[input.MAX_EVENTS]
        count : usize = 0
        loop {
            if count < taken.count {
                taken[count] = driver.waiting[cast[usize](next % WAITING)]
            }
            count += 1
            next += 1
        }
        while next < driver.written && count < cast[usize](most^) && count < taken.count
        out := os.Outgoing.{}
        response :: os.begin[input.Response](&out)
        response^ = .Events(os.append(&out, view_of(&taken[0], count)))
        _ = input.send_response(driver.clients.ends[index], driver.port, &out)
        driver.next_of[index] = next
        most^ = 0
    }
}
