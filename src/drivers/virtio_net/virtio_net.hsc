/**
 * The virtio-net driver (decisions/0188, 13a): a virtio network device's first queue pair, through the virtio-pci
 * transport (src/virtio), as the net protocol for its one client, who arrives on its listener.
 *
 * Frames are in the slots of a buffer the driver makes, DMA memory its client reaches through a window, so the device
 * reads and writes them in place: each chain the device gets is the frame's virtio header, in the driver's own memory,
 * then the slot. A receive slot the client gives stays offered until a frame arrives in it; a send slot's frame is
 * offered as it's sent. Each queue interrupts through its own MSI-X vector, and configuration changes, the link's state
 * among them, through a third, where the device has enough.
 *
 * SPEC: Virtual I/O Device (VIRTIO) Version 1.2, §5.1 (network device)
 */
package virtio_net

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import pci from "../../pci"
import net from "../../protocols/net"
import service_kit from "../../libraries/service_kit"
import virtio from "../../virtio"

/** The bytes of a page: 4096. */
PAGE : u64 : 4096
/** The index of the first receive queue, receiveq1 (virtio 1.2 §5.1.2). */
RECEIVE_QUEUE : u16 : 0
/** The index of the first transmit queue, transmitq1. */
TRANSMIT_QUEUE : u16 : 1
/** The bytes each queue's memory has: two pages, for MAX_QUEUE_SIZE descriptors. */
QUEUE_BYTES : u64 : 2 * PAGE

// ---- Features (virtio 1.2 §5.1.3)

/** The device completes a sent frame's partial checksum. */
FEATURE_CSUM : u64 : 1 << 0
/** The device checks received frames' checksums, or leaves them partial for the driver to complete. */
FEATURE_GUEST_CSUM : u64 : 1 << 1
/** The device's configuration has its MTU. */
FEATURE_MTU : u64 : 1 << 3
/** The device's configuration has its MAC address. */
FEATURE_MAC : u64 : 1 << 5
/** The device's configuration has its link's state. */
FEATURE_STATUS : u64 : 1 << 16

// ---- The device's configuration (virtio 1.2 §5.1.4), as byte offsets into it

/** Where its MAC address is: 6 bytes. */
CONFIG_MAC : u64 : 0
/** Where its status is: a u16, STATUS_LINK_UP. */
CONFIG_STATUS : u64 : 6
/** Where its MTU is: a u16. */
CONFIG_MTU : u64 : 10
/** The status's bit for a link that's up. */
STATUS_LINK_UP : u16 : 1

// ---- The header each frame has (virtio 1.2 §5.1.6)

/** The bytes of a frame's header with VERSION_1: flags, gso_type, hdr_len, gso_size, csum_start, csum_offset, num_buffers. */
HEADER_BYTES : u64 : 12
/** Each header's place in the headers' page: 16 bytes, receive slots' first, then send slots'. */
HEADER_SPACING : u64 : 16
/** A header's flag: the frame's checksum is partial, from csum_start, to be written at csum_offset past it. */
HEADER_NEEDS_CSUM : u8 : 1
/** A header's flag: the received frame's checksum was checked. */
HEADER_DATA_VALID : u8 : 2

// ---- Port keys

/** The port key the receive queue's interrupt is bound with; clients are bound under their indexes, below it. */
RECEIVE_KEY : u64 : 1000
/** The port key the transmit queue's interrupt is bound with. */
SEND_KEY : u64 : 1001
/** The port key configuration changes' interrupt is bound with. */
CONFIG_KEY : u64 : 1002
/** No client: the current one's index when there's none. */
NOBODY : usize : 0xffffffffffffffff

/** A frame's virtio header, as the device reads and writes it. */
Header :: struct #packed {
    flags : u8,
    gso_type : u8,
    header_length : u16le,
    gso_size : u16le,
    checksum_start : u16le,
    checksum_offset : u16le,
    buffer_count : u16le,
}

#assert size_of(Header) == 12

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log. */
    log : slop_os.DebugLog,
    /** The device's registers. */
    transport : virtio.Transport,
    /** The features taken. */
    features : u64,
    /** The receive queue, which given receive slots are offered on. */
    receive : virtio.Queue,
    /** The transmit queue, which sent frames are offered on. */
    transmit : virtio.Queue,
    /** Where the headers' page is, through the driver's mapping: receive slots' headers, then send slots'. */
    headers : u64,
    /** Where the same page is to the device. */
    headers_device : u64,
    /** The DMA domain the device is attached to, which the buffer is made in. */
    domain : slop_os.DmaDomain,
    /** The connections' buffer, made at the first GetBuffer; NO_HANDLE before. */
    buffer : slop_os.Memory,
    /** Where the buffer is, through the driver's mapping, for checksums it completes; 0 before it's made. */
    buffer_at : u64,
    /** Where the buffer is to the device. */
    buffer_device : u64,
    /** Which receive slot each receive descriptor's chain holds, by its first descriptor's index. */
    receive_slot_of : u8[virtio.MAX_QUEUE_SIZE],
    /** Which send slot each transmit descriptor's chain holds, by its first descriptor's index. */
    send_slot_of : u8[virtio.MAX_QUEUE_SIZE],
    /** Whether each receive slot is offered to the device. */
    given : bool[net.SLOTS],
    /** Whether each send slot's frame is with the device. */
    sending : bool[net.SLOTS],
    /** The client served, by its index in clients; NOBODY for none. */
    current : usize,
    /** The state a held WatchLink waits for the link to leave: 0 for down, 1 for up, -1 for none held. */
    watching : i8,
    /** The one port its interrupts and clients are bound to. */
    port : slop_os.Port,
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
}

/**
 * Drive a virtio network device as a NIC, for the client that connects to it.
 *
 * It sets the device up and serves the net protocol on its listener and its client's connection, until the system
 * stops. It's started by the supervisor, for a device the platform service gave it, with what its driver holds of it.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The device, for its MSIs.
 * @param config The device's 4 KiB of configuration space, mapped to find its capabilities and turn bus mastering on.
 * @param bar0 BAR 0's memory, if the device has it; each BAR given is mapped, for the virtio structures in it.
 * @param bar1 BAR 1's memory, if the device has it.
 * @param bar2 BAR 2's memory, if the device has it.
 * @param bar3 BAR 3's memory, if the device has it.
 * @param bar4 BAR 4's memory, if the device has it.
 * @param bar5 BAR 5's memory, if the device has it.
 * @param domain The DMA domain the device is attached to, which its queues, headers and buffer are made in.
 * @param clients The listener its client's Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 0 once it's asked to stop; 99 if its state couldn't be had
 *     (decisions/0104), 2 if config couldn't be mapped, 3 if the device isn't a virtio one it can drive, 4 if it
 *     refused its features, 5 if no port could be made, 6 if its MSIs couldn't be set up, 7 if its DMA memory couldn't
 *     be made or mapped, 8 if its queues couldn't be set up, 9 if the listener couldn't be bound.
 */
main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    clients: os.Listener[net.Net]) -> int {
    block :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    driver.domain = domain
    driver.buffer = cast[slop_os.Memory](slop_os.NO_HANDLE)
    driver.current = NOBODY
    driver.watching = -1
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    driver.transport = virtio.open(config_at, bars) or_return 3
    driver.features = virtio.start(&driver.transport, FEATURE_CSUM | FEATURE_GUEST_CSUM | FEATURE_MTU | FEATURE_MAC | FEATURE_STATUS)
        or_return 4

    driver.port = slop_os.port_create(block.budget) or_return 5
    _ = service_kit.watch_stop(driver.port)
    // A vector for each queue, and one for configuration changes, where the device has three; else one for all
    vectors :: if driver.transport.msix_entries >= 3 { cast[u32](3) } else { cast[u32](1) }
    keys :: u64.[RECEIVE_KEY, SEND_KEY, CONFIG_KEY]
    for entry in cast[u32](0)..<vectors {
        irq :: slop_os.irq_create_msi(device, block.budget) or_return 6
        message :: slop_os.irq_message(irq) or_return 6
        if !virtio.set_vector(&driver.transport, entry, message.address, message.data) {
            return 6
        }
        key :: if cast[usize](entry) < keys.count { keys[entry] } else { RECEIVE_KEY }
        slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), key, .Persistent) or_return 6
    }
    send_vector :: if vectors >= 3 { cast[u16](1) } else { cast[u16](0) }
    config_vector :: if vectors >= 3 { cast[u16](2) } else { cast[u16](0) }

    // Each queue's two pages, then the headers' page
    bytes :: 2 * QUEUE_BYTES + PAGE
    memory :: slop_os.dma_memory_create(domain, block.budget, bytes, 0) or_return 7
    pages :: runtime.reserve_addresses(cast[usize](bytes)) or_return 7
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, block.space, pages, 0, bytes, read_write) or_return 7
    device_address :: slop_os.memory_device_address(memory) or_return 7
    driver.receive = virtio.setup_queue(&driver.transport, RECEIVE_QUEUE, pages, device_address, QUEUE_BYTES, 0) or_return 8
    driver.transmit = virtio.setup_queue(&driver.transport, TRANSMIT_QUEUE, pages + QUEUE_BYTES, device_address + QUEUE_BYTES,
        QUEUE_BYTES, send_vector) or_return 8
    driver.headers = pages + 2 * QUEUE_BYTES
    driver.headers_device = device_address + 2 * QUEUE_BYTES
    if driver.features & FEATURE_STATUS != 0 {
        _ = virtio.set_config_vector(&driver.transport, config_vector)
    }
    virtio.ready(&driver.transport)
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    info :: describe(driver)
    mac :: info.mac
    runtime.log_info("serving %{02x}:%{02x}:%{02x}:%{02x}:%{02x}:%{02x}, its link %", mac[0], mac[1], mac[2], mac[3], mac[4],
        mac[5], if info.link_up { "up" } else { "down" })
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
        take_received(driver)
        take_sent(driver)
        answer_link(driver)
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Answer every request a client has sent, until there are none left, or it's gone.
 *
 * @param driver The driver, whose clients, slots and held WatchLink change.
 * @param index Which client, by its index; one past them, or a freed place, is nothing to serve. A client whose end
 *     failed is dropped; if it was the current one, there's none until the next Connect.
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
        match net.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = net.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
                service_kit.drop_client(&driver.clients, index)
                if driver.current == index {
                    driver.current = NOBODY
                    driver.watching = -1
                }
                return void
            }
        }
        match os.message_of[net.Request](into)^ {
            case Describe => answer(driver, end, .Described(describe(driver)))
            case GetBuffer => answer(driver, end, buffer_for(driver))
            case Receive(slot) => {
                match offer_slot(driver, slot) {
                    case Some(refusal) => answer(driver, end, .Refused(net.Refused.{slot = slot, reason = refusal}))
                    case None => {}
                }
            }
            case Send(frame) => {
                match send(driver, frame) {
                    case Some(refusal) => answer(driver, end, .Refused(net.Refused.{slot = frame.slot, reason = refusal}))
                    case None => {}
                }
            }
            case WatchLink(known) => driver.watching = if known { cast[i8](1) } else { cast[i8](0) }
            case Connect(connection) => {
                // One client at a time: the one before goes
                if driver.current != NOBODY {
                    service_kit.drop_client(&driver.clients, driver.current)
                    driver.watching = -1
                }
                driver.current = service_kit.add_client_index(&driver.clients, driver.port, connection.end) or_else NOBODY
                if driver.current == NOBODY {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Send a response to a client; one that can't be sent is dropped.
 *
 * @param driver The driver, whose port is waited on while end's ring is full.
 * @param end The client's channel end, one the driver's clients keep; not checked or closed here.
 * @param response The response, which has no variable-size data.
 */
answer :: fn(driver: ptr[mut Driver], end: slop_os.Channel, response: net.Response) {
    out := os.Outgoing.{}
    made :: os.begin[net.Response](&out)
    made^ = response
    _ = net.send_response(end, driver.port, &out)
}

/**
 * Send a response to the current client, if there is one; otherwise it's dropped.
 *
 * @param driver The driver.
 * @param response The response, which has no variable-size data.
 */
answer_current :: fn(driver: ptr[mut Driver], response: net.Response) {
    if driver.current >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[driver.current]
    if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
        answer(driver, end, response)
    }
}

/**
 * Read what the interface is from the device's configuration.
 *
 * @param driver The driver, its features taken.
 * @return Its MAC address, all zeroes without FEATURE_MAC; its MTU, 1500 unless FEATURE_MTU says less; its link's
 *     state, up without FEATURE_STATUS; and the offloads its features give.
 */
describe :: fn(driver: ptr[Driver]) -> net.Info {
    info := net.Info.{mtu = 1500, link_up = true, slots = net.SLOTS, slot_bytes = net.SLOT_BYTES}
    device :: driver.transport.device
    if device == 0 {
        return info
    }
    if driver.features & FEATURE_MAC != 0 {
        for &byte, i in info.mac {
            byte^ = virtio.read_u8(device, CONFIG_MAC + cast[u64](i))
        }
    }
    if driver.features & FEATURE_MTU != 0 {
        mtu :: virtio.read_u16(device, CONFIG_MTU)
        if mtu >= 68 && mtu < info.mtu {
            info.mtu = mtu
        }
    }
    if driver.features & FEATURE_STATUS != 0 {
        info.link_up = virtio.read_u16(device, CONFIG_STATUS) & STATUS_LINK_UP != 0
    }
    if driver.features & FEATURE_CSUM != 0 {
        info.offloads |= net.OFFLOAD_SEND_CHECKSUM
    }
    if driver.features & FEATURE_GUEST_CSUM != 0 {
        info.offloads |= net.OFFLOAD_RECEIVE_CHECKSUM
    }
    return info
}

/**
 * Give a client a window onto the buffer, made at the first ask, and mapped for the driver too.
 *
 * @param driver The driver, whose buffer is made in its DMA domain the first time.
 * @return Buffer with a new window onto all of it, read-write, which moves to the client; Unsupported if the buffer,
 *     its mapping or the window couldn't be made.
 */
buffer_for :: fn(driver: ptr[mut Driver]) -> net.Response {
    startup :: slop_os.startup_block()
    if cast[slop_os.Handle](driver.buffer) == slop_os.NO_HANDLE {
        memory :: slop_os.dma_memory_create(driver.domain, startup.budget, net.BUFFER_BYTES, 0) or_return net.Response.Unsupported
        address :: slop_os.memory_device_address(memory) or_return net.Response.Unsupported
        at :: runtime.reserve_addresses(cast[usize](net.BUFFER_BYTES)) or_return net.Response.Unsupported
        read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
        if slop_os.memory_map(memory, startup.space, at, 0, net.BUFFER_BYTES, read_write) is_error {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return net.Response.Unsupported
        }
        driver.buffer = memory
        driver.buffer_at = at
        driver.buffer_device = address
    }
    window :: slop_os.memory_create_window(driver.buffer, startup.budget, 0, net.BUFFER_BYTES) or_return net.Response.Unsupported
    return net.Response.Buffer(window)
}

/**
 * Offer a receive slot to the device, its header first, then the slot, both for the device to write.
 *
 * @param driver The driver, its receive queue offered the chain, and given marked.
 * @param slot The slot, 0 to net.SLOTS - 1.
 * @return Null once it's offered, or if it was already; why not otherwise.
 */
offer_slot :: fn(driver: ptr[mut Driver], slot: u32) -> net.Refusal? {
    if slot >= net.SLOTS {
        return net.Refusal.WrongSlot
    }
    if driver.buffer_at == 0 {
        return net.Refusal.NoBuffer
    }
    if cast[usize](slot) >= driver.given.count || driver.given[slot] {
        return null
    }
    header :: driver.headers_device + cast[u64](slot) * HEADER_SPACING
    frame :: driver.buffer_device + cast[u64](slot) * cast[u64](net.SLOT_BYTES)
    id :: virtio.offer_chain(&driver.receive, virtio.Part.[
        virtio.Part.{address = header, length = cast[u32](HEADER_BYTES), device_writes = true},
        virtio.Part.{address = frame, length = net.SLOT_BYTES, device_writes = true}])
    if id == virtio.NO_DESCRIPTOR || cast[usize](id) >= driver.receive_slot_of.count {
        return net.Refusal.Busy
    }
    driver.receive_slot_of[id] = cast[u8](slot)
    driver.given[slot] = true
    return null
}

/**
 * Offer a send slot's frame to the device, its header first, then the frame, both for the device to read.
 *
 * @param driver The driver, its transmit queue offered the chain, and sending marked.
 * @param frame The frame: its slot net.SLOTS to 2 * net.SLOTS - 1, its length net.MIN_FRAME to the slot's bytes, and
 *     with checksum_start, its checksum's two bytes within it.
 * @return Null once it's offered; why not otherwise.
 */
send :: fn(driver: ptr[mut Driver], frame: net.Frame) -> net.Refusal? {
    if frame.slot < net.SLOTS || frame.slot >= 2 * net.SLOTS {
        return net.Refusal.WrongSlot
    }
    if driver.buffer_at == 0 {
        return net.Refusal.NoBuffer
    }
    if frame.length < net.MIN_FRAME || frame.length > net.SLOT_BYTES {
        return net.Refusal.BadFrame
    }
    checksummed :: frame.checksum_start != 0
    if checksummed && (driver.features & FEATURE_CSUM == 0
        || cast[u32](frame.checksum_start) + cast[u32](frame.checksum_at) + 2 > frame.length) {
        return net.Refusal.BadFrame
    }
    index :: frame.slot - net.SLOTS
    if cast[usize](index) >= driver.sending.count || driver.sending[index] {
        return net.Refusal.Busy
    }
    header_at :: driver.headers + cast[u64](net.SLOTS + index) * HEADER_SPACING
    header :: cast[ptr[mut Header]](header_at)
    header^ = Header.{}
    if checksummed {
        header.flags = HEADER_NEEDS_CSUM
        header.checksum_start = cast[u16le](frame.checksum_start)
        header.checksum_offset = cast[u16le](frame.checksum_at)
    }
    id :: virtio.offer_chain(&driver.transmit, virtio.Part.[
        virtio.Part.{address = driver.headers_device + cast[u64](net.SLOTS + index) * HEADER_SPACING, length = cast[u32](HEADER_BYTES)},
        virtio.Part.{address = driver.buffer_device + cast[u64](frame.slot) * cast[u64](net.SLOT_BYTES), length = frame.length}])
    if id == virtio.NO_DESCRIPTOR || cast[usize](id) >= driver.send_slot_of.count {
        return net.Refusal.Busy
    }
    driver.send_slot_of[id] = cast[u8](index)
    driver.sending[index] = true
    return null
}

/**
 * Answer each frame the device has received, a Received to the current client, completing a partial checksum first.
 *
 * A slot whose frame no one's served for stays the device's no longer: the client gives it again.
 *
 * @param driver The driver, whose given slots are cleared as their frames arrive.
 */
take_received :: fn(driver: ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.receive) or_break
        if cast[usize](used.id) >= driver.receive_slot_of.count {
            continue
        }
        slot :: cast[u32](driver.receive_slot_of[used.id])
        if cast[usize](slot) < driver.given.count {
            driver.given[slot] = false
        }
        written :: cast[u64](used.length)
        if written <= HEADER_BYTES {
            continue
        }
        length :: written - HEADER_BYTES
        if length > cast[u64](net.SLOT_BYTES) {
            continue
        }
        header :: cast[ptr[Header]](driver.headers + cast[u64](slot) * HEADER_SPACING)
        flags := cast[u32](0)
        if header.flags & HEADER_DATA_VALID != 0 {
            flags |= net.CHECKSUM_VALID
        }
        else if header.flags & HEADER_NEEDS_CSUM != 0 {
            start : u16 = header.checksum_start
            offset : u16 = header.checksum_offset
            if complete_checksum(driver.buffer_at + cast[u64](slot) * cast[u64](net.SLOT_BYTES), length, cast[u64](start), cast[u64](offset)) {
                flags |= net.CHECKSUM_VALID
            }
        }
        answer_current(driver, .Received(net.Frame.{slot = slot, length = cast[u32](length), flags = flags}))
    }
}

/**
 * Complete a received frame's partial checksum, as the device left it: the ones' complement of the sum from start to
 * the frame's end, the sum's start already in place, written big-endian at offset past start.
 *
 * @param frame Where the frame is, through the driver's mapping.
 * @param length The frame's length in bytes.
 * @param start Where the checksummed part starts, in bytes from the frame's start.
 * @param offset Where the checksum goes, in bytes past start.
 * @return True once it's written; false, nothing written, if its place isn't within the frame.
 */
complete_checksum :: fn(frame: u64, length: u64, start: u64, offset: u64) -> bool {
    if start + offset + 2 > length {
        return false
    }
    bytes :: view_of(cast[ptr[mut u8]](frame), cast[usize](length))
    sum := cast[u64](0)
    with {
        at := cast[usize](start)
    }
    loop {
        high :: cast[u64](bytes[at]) << 8
        low :: if at + 1 < bytes.count { cast[u64](bytes[at + 1]) } else { cast[u64](0) }
        sum += high | low
        at += 2
    }
    while at < bytes.count
    loop {
        sum = (sum & 0xffff) + (sum >> 16)
    }
    while sum > 0xffff
    checksum :: ~cast[u16](sum)
    place :: cast[usize](start + offset)
    after :: place + 1
    if place < bytes.count && after < bytes.count {
        bytes[place] = cast[u8](checksum >> 8)
        bytes[after] = cast[u8](checksum)
    }
    return true
}

/**
 * Answer each frame the device has taken, a Sent to the current client.
 *
 * @param driver The driver, whose sending slots are cleared.
 */
take_sent :: fn(driver: ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.transmit) or_break
        if cast[usize](used.id) >= driver.send_slot_of.count {
            continue
        }
        index :: cast[u32](driver.send_slot_of[used.id])
        if cast[usize](index) < driver.sending.count {
            driver.sending[index] = false
        }
        answer_current(driver, .Sent(net.SLOTS + index))
    }
}

/**
 * Answer a held WatchLink, if the link's state isn't what it waits to change from.
 *
 * @param driver The driver, whose watching is cleared once it's answered.
 */
answer_link :: fn(driver: ptr[mut Driver]) {
    if driver.watching < 0 {
        return void
    }
    up :: describe(driver).link_up
    if up == (driver.watching == 1) {
        return void
    }
    driver.watching = -1
    answer_current(driver, .Link(up))
}
