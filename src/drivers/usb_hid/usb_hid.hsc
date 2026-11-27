/**
 * The USB HID driver (roadmap 20e, decisions/0201): a keyboard's, mouse's or tablet's interface, through its host
 * controller's driver (the USB device protocol), as the input protocol for its clients, as virtio-input's are. A boot
 * keyboard or mouse (subclass 1) is put in the boot protocol, whose reports are fixed: a keyboard's modifiers and six
 * keys, a mouse's buttons, motion and wheel. Anything else, as a tablet, keeps the report protocol, and its report
 * descriptor is read for where its buttons, X, Y and wheel are, X and Y absolute or relative as it says.
 *
 * Each report, read from the interface's interrupt IN endpoint with one transfer always in flight, becomes events: a
 * keyboard's keys and modifiers by their USB HID usages as they go down and up, a pointer's buttons as they change,
 * its motion or position, and its wheel. They wait in order until a held Read takes them, and every client's Read
 * gets each, as virtio-input's do.
 *
 * SPEC: Device Class Definition for HID 1.11 (the boot protocol, appendix B; report descriptors §6.2.2; SET_PROTOCOL
 * and SET_IDLE §7.2); HID Usage Tables 1.4 (Generic Desktop §4, Button §12).
 */
package usb_hid

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import service_kit from "../../libraries/service_kit"
import input from "../../protocols/input"
import usb_device from "../../protocols/usb_device"

/** How many events the driver keeps for clients that haven't had them; a client further behind misses the oldest. */
WAITING :: 64
/** The port key the interface's connection is bound with; clients are bound under their indexes, below it. */
DEVICE_KEY : u64 : 1000
/** Where in the buffer the report descriptor's read, and each report. */
DESCRIPTOR_OFFSET : u32 : 0
REPORT_OFFSET : u32 : 4096
/** The most bytes of a report descriptor read. */
DESCRIPTOR_BYTES : u16 : 1024
/** The most bytes of a report taken. */
REPORT_BYTES : u32 : 64
/** How long a request made while starting, or a reset, may take: 5 s. */
CALL_WAIT : u64 : 5_000_000_000
/** How many times a control request answered Busy is sent again, and how far apart: 50, 2 ms. */
BUSY_TRIES :: 50
BUSY_PAUSE : u64 : 2_000_000
/** The most bits a report descriptor's field is taken as having, and the most fields an Input item's count gives. */
MAX_FIELD_BITS : u32 : 32
MAX_FIELD_COUNT : u32 : 64
/** The tag of the report transfer, and of the requests made while starting. */
REPORT_TAG : u64 : 1
SETUP_TAG : u64 : 2

/** HID's class requests (§7.2): SET_IDLE and SET_PROTOCOL; the HID class's report descriptor type, 0x22. */
REQUEST_SET_IDLE : u8 : 0x0a
REQUEST_SET_PROTOCOL : u8 : 0x0b
DESCRIPTOR_REPORT : u16 : 0x22
/** The boot interface subclass, and its protocols: a keyboard, a mouse. */
SUBCLASS_BOOT : u8 : 1
PROTOCOL_KEYBOARD : u8 : 1
PROTOCOL_MOUSE : u8 : 2
/** Usage pages: Generic Desktop, Button; Generic Desktop's X, Y and Wheel. */
PAGE_DESKTOP : u32 : 0x01
PAGE_BUTTON : u32 : 0x09
USAGE_X : u32 : 0x30
USAGE_Y : u32 : 0x31
USAGE_WHEEL : u32 : 0x38
/** The keyboard page's first modifier, Left Control, 0xe0; the eight run to 0xe7 as the boot report's bits. */
FIRST_MODIFIER : u16 : 0xe0

/** Where a field is in a report: its bit offset and size, and its logical range; size 0 for none. */
Field :: struct {
    offset : u32,
    size : u32,
    minimum : i32,
    maximum : i32,
    /** Whether it's relative (Input's bit 2), a motion, or absolute, a position. */
    relative : bool,
}

/** Where a report protocol pointer's fields are, from its report descriptor. */
Layout :: struct {
    /** The report ID its reports start with, or 0 for none. */
    report_id : u8,
    buttons : Field,
    /** How many buttons, at most 8 taken. */
    button_count : u32,
    x : Field,
    y : Field,
    wheel : Field,
}

/** What the driver drives. */
Kind :: enum {
    Keyboard,
    /** A boot mouse, its report fixed. */
    Mouse,
    /** A pointer read through its report descriptor, as a tablet. */
    Pointer,
}

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** The interface's connection, and its buffer, mapped. */
    device : slop_os.Channel,
    buffer : u64,
    /** The interface's interrupt IN endpoint's address, and its packet size. */
    endpoint : u8,
    packet : u32,
    kind : Kind,
    layout : Layout,
    /** The last report's keys, modifiers in their own byte, as a keyboard's; and its buttons, as a pointer's. */
    keys : u8[6],
    modifiers : u8,
    buttons : u32,
    /** The last position, a tablet's. */
    x : i32,
    y : i32,
    port : slop_os.Port,
    /** The events kept for clients, a ring: event n is at n % WAITING. */
    waiting : input.Event[WAITING],
    written : u64,
    next_of : u64[service_kit.MAX_CLIENTS],
    held : u32[service_kit.MAX_CLIENTS],
    clients : service_kit.Clients,
    axes : input.Axes,
}

/**
 * Drive a USB HID interface, a keyboard, mouse or tablet, as the input protocol, for the clients that connect to it.
 *
 * It's started by the supervisor for an interface of class 3 a host controller's driver found, with a connection to
 * it; it reads the device's reports and gives every client every event after it connected, until the system stops.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The connection to the interface, the driver's.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 0 once its device is gone; 99 if its state couldn't be had, 2 if the
 *     interface couldn't be described or its buffer had, 4 if a boot device refused the boot protocol, 5 if no port
 *     could be made, 9 if the listener couldn't be bound; 0 too for an interface with nothing to serve, no interrupt
 *     IN endpoint or no X and Y in its reports, so it isn't started again.
 */
main :: fn(log : slop_os.DebugLog?, device : os.Channel[usb_device.UsbDevice], clients : os.Listener[input.Input]) -> int {
    startup :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.device = device.end
    driver.port = slop_os.port_create(startup.budget) or_return 5
    _ = service_kit.watch_stop(driver.port)
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    slop_os.port_bind(driver.port, DEVICE_KEY, cast[slop_os.Handle](device.end), signals, .Persistent) or_return 5

    info :: match call(driver, .Describe) {
        case Described(described) => described
        case _ => return 2
    }
    window :: match call(driver, .GetBuffer) {
        case Buffer(memory) => memory
        case _ => return 2
    }
    driver.buffer = map_window(window, info.buffer_bytes) or_return 2
    for i in 0..<info.endpoints.count {
        if i < cast[usize](info.endpoint_count) && info.endpoints[i].kind == .Interrupt
            && info.endpoints[i].address & 0x80 != 0 {
            driver.endpoint = info.endpoints[i].address
            driver.packet = cast[u32](info.endpoints[i].max_packet)
            break
        }
    }
    // An interface with nothing to report on, as some HID interfaces are, isn't one to serve: it ends, not restarted
    if driver.endpoint == 0 {
        runtime.log_info("no interrupt IN endpoint, so nothing to serve")
        return 0
    }
    if driver.packet == 0 || driver.packet > REPORT_BYTES {
        driver.packet = REPORT_BYTES
    }
    boot :: info.subclass == SUBCLASS_BOOT && (info.protocol == PROTOCOL_KEYBOARD || info.protocol == PROTOCOL_MOUSE)
    if boot {
        driver.kind = if info.protocol == PROTOCOL_KEYBOARD { Kind.Keyboard } else { Kind.Mouse }
        // SET_PROTOCOL to the boot protocol (0), on the interface
        if !control(driver, 0x21, REQUEST_SET_PROTOCOL, 0, cast[u16](info.interface), 0) {
            return 4
        }
    }
    else {
        driver.kind = .Pointer
        // One that isn't a pointer, as a keyboard's consumer controls are, isn't served: it ends, not restarted
        if !read_layout(driver, info.interface) {
            runtime.log_info("no X and Y in its reports, so nothing to serve")
            return 0
        }
    }
    // SET_IDLE to 0, reports only on a change; a device that refuses it reports as it likes
    _ = control(driver, 0x21, REQUEST_SET_IDLE, 0, cast[u16](info.interface), 0)
    if driver.kind == .Pointer && !driver.layout.x.relative {
        driver.axes = input.Axes.{
            x_min = driver.layout.x.minimum,
            x_max = driver.layout.x.maximum,
            y_min = driver.layout.y.minimum,
            y_max = driver.layout.y.maximum,
        }
    }

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    what :: match driver.kind {
        case .Keyboard => "a keyboard"
        case .Mouse => "a mouse"
        case .Pointer => if driver.layout.x.relative { "a pointer" } else { "a tablet" }
    }
    runtime.log_info("serving %1:%2 as %3", info.vendor, info.product, what)
    if !ask_report(driver) {
        return 0
    }
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
        if !take_reports(driver) {
            runtime.log_info("its device is gone")
            return 0
        }
        answer_held(driver)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

// ---- The device

/**
 * Send one request on the interface's connection and wait for its answer, as starting needs.
 *
 * @param driver The driver, no transfer in flight.
 * @param request The request.
 * @return The answer; Unsupported if it couldn't be sent or the connection's gone.
 */
call :: fn(driver : ptr[Driver], request : usb_device.Request) -> usb_device.Response {
    port :: os.port_for(slop_os.startup_block().budget, driver.device) or_return usb_device.Response.Unsupported
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    made :: os.begin[usb_device.Request](&out)
    made^ = request
    if usb_device.send_request(driver.device, port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    deadline :: (slop_os.clock_monotonic() or_else 0) + CALL_WAIT
    match usb_device.receive_response(driver.device, port, &into, true, deadline) {
        case Received => return os.message_of[usb_device.Response](&into)^
        case _ => return .Unsupported
    }
}

/**
 * Make a control transfer and wait for it.
 *
 * @param driver The driver.
 * @param request_type The setup's bmRequestType.
 * @param request Its bRequest.
 * @param value Its wValue.
 * @param where Its wIndex.
 * @param length Its wLength, the data at DESCRIPTOR_OFFSET in the buffer.
 * @return True if it was Done.
 */
control :: fn(driver : ptr[Driver], request_type : u8, request : u8, value : u16, where : u16, length : u16) -> bool {
    setup :: usb_device.Setup.{request_type = request_type, request = request, value = value, index = where, length = length}
    // Again while it's Busy, as another interface's control transfer may hold the device's default endpoint
    for attempt in 0..<BUSY_TRIES {
        match call(driver, .Control(usb_device.Control.{tag = SETUP_TAG, setup = setup, offset = DESCRIPTOR_OFFSET})) {
            case Finished(done) => {
                if done.status != .Busy {
                    return done.status == .Done
                }
            }
            case _ => return false
        }
        pause(BUSY_PAUSE)
    }
    return false
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
 * Read a pointer's report descriptor, and where its buttons, X, Y and wheel are.
 *
 * @param driver The driver, whose layout is set.
 * @param interface The interface's number.
 * @return True if it was read and has an X and a Y.
 */
read_layout :: fn(driver : ptr[mut Driver], interface : u8) -> bool {
    setup :: usb_device.Setup.{
        request_type = 0x81,
        request = 6,
        value = DESCRIPTOR_REPORT << 8,
        index = cast[u16](interface),
        length = DESCRIPTOR_BYTES,
    }
    length :: match call(driver, .Control(usb_device.Control.{tag = SETUP_TAG, setup = setup, offset = DESCRIPTOR_OFFSET})) {
        case Finished(done) => if done.status == .Done { done.length } else { cast[u32](0) }
        case _ => cast[u32](0)
    }
    if length == 0 {
        return false
    }
    driver.layout = parse_layout(view_of(cast[ptr[u8]](driver.buffer + cast[u64](DESCRIPTOR_OFFSET)), cast[usize](length)))
    return driver.layout.x.size > 0 && driver.layout.y.size > 0
}

/**
 * Find a pointer's fields in its report descriptor (§6.2.2): its first report's buttons, X, Y and wheel, each an
 * Input main item's, by the usage page and usages before it. Collections, outputs and features are passed over.
 *
 * @param descriptor The report descriptor's bytes.
 * @return The layout; a field it hasn't has size 0.
 */
parse_layout :: fn(descriptor : u8[]) -> Layout {
    layout := Layout.{}
    page := cast[u32](0)
    minimum := cast[i32](0)
    maximum := cast[i32](0)
    size := cast[u32](0)
    count := cast[u32](0)
    report := cast[u32](0)
    usages : u32[8]
    usage_count := cast[usize](0)
    usage_minimum := cast[u32](0)
    usage_maximum := cast[u32](0)
    bit := cast[u32](0)
    at := cast[usize](0)
    loop {
        if at >= descriptor.count {
            break
        }
        prefix :: descriptor[at]
        // A long item (0xfe) is passed over by its size
        if prefix == 0xfe {
            if at + 1 >= descriptor.count {
                break
            }
            at += 3 + cast[usize](descriptor[at + 1])
            continue
        }
        bytes :: if prefix & 3 == 3 { cast[usize](4) } else { cast[usize](prefix & 3) }
        if at + 1 + bytes > descriptor.count {
            break
        }
        data := cast[u32](0)
        for i in 0..<bytes {
            where :: at + 1 + i
            if where < descriptor.count {
                data |= cast[u32](descriptor[where]) << (8 * cast[u32](i))
            }
        }
        // Sign-extended, for the logical range
        signed :: if bytes == 0 {
            cast[i32](0)
        }
        else if bytes == 4 {
            bit_cast[i32](data)
        }
        else {
            bit_cast[i32](data << (32 - 8 * cast[u32](bytes))) >> (32 - 8 * cast[u32](bytes))
        }
        tag :: prefix & 0xfc
        if tag == 0x04 {
            page = data
        }
        else if tag == 0x14 {
            minimum = signed
        }
        else if tag == 0x24 {
            maximum = signed
        }
        else if tag == 0x74 {
            size = if data > MAX_FIELD_BITS { MAX_FIELD_BITS } else { data }
        }
        else if tag == 0x94 {
            count = if data > MAX_FIELD_COUNT { MAX_FIELD_COUNT } else { data }
        }
        else if tag == 0x84 {
            // A report ID: only the first report's fields are taken
            if layout.report_id == 0 {
                layout.report_id = cast[u8](data)
                bit = 8
            }
            report = data
        }
        else if tag == 0x08 {
            if usage_count < usages.count {
                usages[usage_count] = data
                usage_count += 1
            }
        }
        else if tag == 0x18 {
            usage_minimum = data
        }
        else if tag == 0x28 {
            usage_maximum = data
        }
        else if tag == 0x80 {
            // An Input: count fields of size bits, constant ones (bit 0) padding
            first_report :: report == cast[u32](layout.report_id)
            if data & 1 == 0 && first_report {
                relative :: data & 4 != 0
                if page == PAGE_BUTTON {
                    layout.buttons = Field.{offset = bit, size = size}
                    layout.button_count = if count < 8 { count } else { 8 }
                }
                else if page == PAGE_DESKTOP {
                    for i in 0..<cast[usize](count) {
                        usage :: if i < usage_count { usages[i] } else if cast[u64](usage_minimum) + cast[u64](i) <= cast[u64](usage_maximum) { usage_minimum + cast[u32](i) } else { cast[u32](0) }
                        field :: Field.{
                            offset = bit + cast[u32](i) * size,
                            size = size,
                            minimum = minimum,
                            maximum = maximum,
                            relative = relative,
                        }
                        if usage == USAGE_X && layout.x.size == 0 {
                            layout.x = field
                        }
                        else if usage == USAGE_Y && layout.y.size == 0 {
                            layout.y = field
                        }
                        else if usage == USAGE_WHEEL && layout.wheel.size == 0 {
                            layout.wheel = field
                        }
                    }
                }
            }
            if first_report {
                bit += size * count
            }
            usage_count = 0
            usage_minimum = 0
            usage_maximum = 0
        }
        else if tag == 0x90 || tag == 0xb0 || tag == 0xa0 || tag == 0xc0 {
            // An Output, a Feature, a Collection or its end: the local items go
            usage_count = 0
            usage_minimum = 0
            usage_maximum = 0
        }
        at += 1 + bytes
    }
    return layout
}

/**
 * Ask for the next report: a transfer on the interrupt IN endpoint, always one in flight.
 *
 * @param driver The driver.
 * @return False if it couldn't be sent, as the connection's gone.
 */
ask_report :: fn(driver : ptr[Driver]) -> bool {
    out := os.Outgoing.{}
    made :: os.begin[usb_device.Request](&out)
    made^ = .Transfer(
        usb_device.Transfer.{tag = REPORT_TAG, endpoint = driver.endpoint, offset = REPORT_OFFSET, length = driver.packet}
    )
    return usb_device.send_request(driver.device, driver.port, &out) is_none
}

/**
 * Take every answer the interface's connection has: each report become events, and the next asked for.
 *
 * @param driver The driver, whose waiting events grow.
 * @return False once the device or its connection is gone; true otherwise.
 */
take_reports :: fn(driver : ptr[mut Driver]) -> bool {
    loop {
        into := os.Incoming.{}
        match usb_device.receive_response(driver.device, driver.port, &into, false) {
            case Received => {}
            case Empty => return true
            case _ => return false
        }
        match os.message_of[usb_device.Response](&into)^ {
            case Finished(done) => {
                if done.tag != REPORT_TAG {
                    continue
                }
                if done.status == .Gone {
                    return false
                }
                if done.status == .Done {
                    report(driver, cast[usize](done.length))
                }
                else if done.status == .Stalled && !call_reset(driver) {
                    return false
                }
                if !ask_report(driver) {
                    return false
                }
            }
            case _ => {}
        }
    }
}

/**
 * Clear the interrupt endpoint's halt after a stall, and wait for it, so the next report isn't asked for on an
 * endpoint still halted; again while it's Busy.
 *
 * @param driver The driver, its report transfer ended.
 * @return True once it's cleared; false if it couldn't be, as the device refuses or is gone.
 */
call_reset :: fn(driver : ptr[Driver]) -> bool {
    for attempt in 0..<BUSY_TRIES {
        match call(driver, .ResetEndpoint(usb_device.ResetEndpoint.{tag = SETUP_TAG, endpoint = driver.endpoint})) {
            case Finished(done) => {
                if done.status != .Busy {
                    return done.status == .Done
                }
            }
            case _ => return false
        }
        pause(BUSY_PAUSE)
    }
    return false
}

/**
 * Turn a report into events.
 *
 * @param driver The driver, whose last report changes.
 * @param length The report's bytes, at REPORT_OFFSET in the buffer.
 */
report :: fn(driver : ptr[mut Driver], length : usize) {
    bytes :: view_of(cast[ptr[u8]](driver.buffer + cast[u64](REPORT_OFFSET)), if length < cast[usize](REPORT_BYTES) { length } else { cast[usize](REPORT_BYTES) })
    match driver.kind {
        case .Keyboard => keyboard_report(driver, bytes)
        case .Mouse => {
            if bytes.count < 3 {
                return void
            }
            pointer_events(
                driver,
                cast[u32](bytes[0]) & 0x7,
                3,
                cast[i32](bit_cast[i8](bytes[1])),
                cast[i32](bit_cast[i8](bytes[2])),
                true,
                if bytes.count > 3 { cast[i32](bit_cast[i8](bytes[3])) } else { cast[i32](0) }
            )
        }
        case .Pointer => {
            layout :: driver.layout
            if layout.report_id != 0 && (bytes.count == 0 || bytes[0] != layout.report_id) {
                return void
            }
            buttons :: if layout.buttons.size == 1 { bits_of(bytes, layout.buttons.offset, layout.button_count) } else { cast[u32](0) }
            pointer_events(
                driver,
                buttons,
                layout.button_count,
                field_of(bytes, layout.x),
                field_of(bytes, layout.y),
                layout.x.relative,
                if layout.wheel.size > 0 { field_of(bytes, layout.wheel) } else { cast[i32](0) }
            )
        }
    }
}

/**
 * Turn a boot keyboard's report into its keys' events: each modifier and key that went down or up since the last.
 *
 * @param driver The driver, whose last keys and modifiers are set to the report's.
 * @param bytes The report: modifiers, a reserved byte, and six keys' usages, 1 for too many keys down.
 */
keyboard_report :: fn(driver : ptr[mut Driver], bytes : u8[]) {
    if bytes.count < 8 {
        return void
    }
    // Too many keys down: the report says nothing of which, so nothing changes
    if bytes[2] == 1 {
        return void
    }
    modifiers :: bytes[0]
    for bit in 0..<8 {
        was :: (driver.modifiers >> cast[u8](bit)) & 1 != 0
        is :: (modifiers >> cast[u8](bit)) & 1 != 0
        if was != is {
            keep(driver, input.event_of(.Key, is, FIRST_MODIFIER + cast[u16](bit), 0, 0))
        }
    }
    driver.modifiers = modifiers
    // Those let go first, then those pressed
    for old in driver.keys {
        if old != 0 && !has_key(bytes, old) {
            keep(driver, input.event_of(.Key, false, cast[u16](old), 0, 0))
        }
    }
    for i in cast[usize](2)..<8 {
        key :: bytes[i]
        if key > 3 && !has_old_key(driver, key) {
            keep(driver, input.event_of(.Key, true, cast[u16](key), 0, 0))
        }
    }
    for i in 0..<driver.keys.count {
        driver.keys[i] = bytes[2 + i]
    }
}

/**
 * Tell whether a report has a key down.
 *
 * @param bytes The report.
 * @param key The key's usage.
 * @return True if one of its six keys is it.
 */
has_key :: fn(bytes : u8[], key : u8) -> bool {
    for i in cast[usize](2)..<8 {
        if i < bytes.count && bytes[i] == key {
            return true
        }
    }
    return false
}

/**
 * Tell whether the last report had a key down.
 *
 * @param driver The driver.
 * @param key The key's usage.
 * @return True if it did.
 */
has_old_key :: fn(driver : ptr[Driver], key : u8) -> bool {
    for old in driver.keys {
        if old == key {
            return true
        }
    }
    return false
}

/**
 * Turn a pointer's state into its events: each button that changed, its motion or position, and its wheel.
 *
 * @param driver The driver, whose last buttons and position are set.
 * @param buttons Its buttons, a bit each from bit 0, the left.
 * @param count How many buttons it has.
 * @param x Its motion or position across.
 * @param y Its motion or position down.
 * @param relative Whether x and y are a motion, or a position.
 * @param wheel How far its wheel turned, positive away from the user.
 */
pointer_events :: fn(driver : ptr[mut Driver], buttons : u32, count : u32, x : i32, y : i32, relative : bool, wheel : i32) {
    for button in 0..<count {
        was :: (driver.buttons >> button) & 1 != 0
        is :: (buttons >> button) & 1 != 0
        if was != is {
            keep(driver, input.event_of(.Button, is, cast[u16](button), 0, 0))
        }
    }
    driver.buttons = buttons
    if relative {
        if x != 0 || y != 0 {
            keep(driver, input.event_of(.Motion, false, 0, x, y))
        }
    }
    else if x != driver.x || y != driver.y {
        driver.x = x
        driver.y = y
        keep(driver, input.event_of(.Position, false, 0, x, y))
    }
    if wheel != 0 {
        keep(driver, input.event_of(.Wheel, false, 0, 0, wheel))
    }
}

/**
 * Read a report's bits, low bit first.
 *
 * @param bytes The report.
 * @param offset The first bit's.
 * @param count How many, at most 32.
 * @return Them, as a number; bits past the report are 0.
 */
bits_of :: fn(bytes : u8[], offset : u32, count : u32) -> u32 {
    value := cast[u32](0)
    for i in 0..<count {
        at :: offset + i
        byte :: cast[usize](at / 8)
        if byte < bytes.count && (bytes[byte] >> cast[u8](at % 8)) & 1 != 0 {
            value |= cast[u32](1) << i
        }
    }
    return value
}

/**
 * Read a report's field, signed where its logical minimum is below 0.
 *
 * @param bytes The report.
 * @param field The field, of 1 to 32 bits.
 * @return Its value.
 */
field_of :: fn(bytes : u8[], field : Field) -> i32 {
    size :: if field.size > 32 { cast[u32](32) } else { field.size }
    raw :: bits_of(bytes, field.offset, size)
    if field.minimum < 0 && size > 0 && size < 32 && (raw >> (size - 1)) & 1 != 0 {
        return bit_cast[i32](raw | (~cast[u32](0) << size))
    }
    return bit_cast[i32](raw)
}

/**
 * Keep an event for the clients, stamped with when it was taken.
 *
 * @param driver The driver, whose waiting events grow; one WAITING ahead of a client overwrites the oldest it hasn't had.
 * @param event The event.
 */
keep :: fn(driver : ptr[mut Driver], event : input.Event) {
    stamped := event
    stamped.time_ns = slop_os.clock_monotonic() or_else 0
    driver.waiting[cast[usize](driver.written % WAITING)] = stamped
    driver.written += 1
}

// ---- Clients, as virtio-input's

/**
 * Take every request a client has sent: a Read held, a Describe answered, a Connect adding a client.
 *
 * @param driver The driver.
 * @param index Which client, by its index.
 * @param into Where each request is received.
 */
serve :: fn(driver : ptr[mut Driver], index : usize, into : ptr[mut os.Incoming]) {
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
            case _ => {
                service_kit.drop_client(&driver.clients, index)
                if index < driver.held.count {
                    driver.held[index] = 0
                }
                return void
            }
        }
        match os.message_of[input.Request](into)^ {
            case Read(most) => {
                if index < driver.held.count {
                    driver.held[index] = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case Describe => {
                out := os.Outgoing.{}
                response :: os.begin[input.Response](&out)
                response^ = .Described(driver.axes)
                _ = input.send_response(end, driver.port, &out)
            }
            case Connect(connection) => {
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
 * Answer each held Read with the events its client hasn't had, oldest first, as many as it asked for and
 * input.MAX_EVENTS; a client a whole ring behind skips to the oldest kept.
 *
 * @param driver The driver, whose clients' next events move on and held Reads are cleared as they're answered.
 */
answer_held :: fn(driver : ptr[mut Driver]) {
    for &most, index in driver.held {
        if most^ == 0 || index >= driver.clients.ends.count || index >= driver.next_of.count {
            continue
        }
        next := driver.next_of[index]
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

/**
 * Map the connection's buffer, read/write.
 *
 * @param window The window onto it, which the driver keeps.
 * @param bytes Its size.
 * @return Where it's mapped; null if addresses or the mapping couldn't be had.
 */
map_window :: fn(window : slop_os.Memory, bytes : u64) -> u64? {
    startup :: slop_os.startup_block()
    at :: runtime.reserve_addresses(cast[usize](bytes)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    match slop_os.memory_map(window, startup.space, at, 0, bytes, read_write) {
        case Ok => return at
        case Error(error) => return null
    }
}
