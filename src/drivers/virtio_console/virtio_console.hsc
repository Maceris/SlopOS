/**
 * The virtio-console driver (decisions/0075): a virtio console device's first port, without multiport, through the
 * virtio-pci transport (src/virtio), as the serial protocol for its clients, who arrive on its listener. Its receive
 * queue always has RECEIVE_BUFFERS buffers offered, whose bytes go into its input until a Read takes them; a Read
 * that finds none is held until some arrive. A Write's bytes go out through its transmit queue, one buffer at a time,
 * waited for. Both queues interrupt through one MSI-X vector.
 */
package virtio_console

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import pci from "../../pci"
import serial from "../../protocols/serial"
import service_kit from "../../libraries/service_kit"
import virtio from "../../virtio"

/** The bytes of a page: 4096. */
PAGE : u64 : 4096
/** The index of port 0's receive queue, receiveq (virtio 1.2 §5.3.2). */
RECEIVE_QUEUE : u16 : 0
/** The index of port 0's transmit queue, transmitq. */
TRANSMIT_QUEUE : u16 : 1
/** How many receive buffers the device always has offered: 4. */
RECEIVE_BUFFERS :: 4
/** The bytes of each buffer, receive or transmit: 256. */
BUFFER_BYTES : u64 : 256
/** The most bytes that have arrived the driver keeps for Reads, 1024; what arrives past them is dropped. */
INPUT_BYTES :: 1024
/** The port key the device's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** The longest the device may take to send a buffer, in nanoseconds, 1 s, before a Write stops there. */
SEND_NANOSECONDS : u64 : 1_000_000_000

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log. */
    log : slop_os.DebugLog,
    /** The device's registers. */
    transport : virtio.Transport,
    /** The receive queue, which RECEIVE_BUFFERS buffers are always offered on. */
    receive : virtio.Queue,
    /** The transmit queue, which one buffer at a time is offered on. */
    transmit : virtio.Queue,
    /**
     * Where the buffers' page is, through the driver's mapping: RECEIVE_BUFFERS buffers to receive, then one to send,
     * BUFFER_BYTES each.
     */
    buffers : u64,
    /** Where the same page is to the device, its device address. */
    buffers_device : u64,
    /** Which receive buffer each receive descriptor holds, by descriptor index. */
    buffer_of : u8[virtio.MAX_QUEUE_SIZE],
    /** The one port its interrupt and its clients are bound to. */
    port : slop_os.Port,
    /** What's arrived and no Read has taken yet, oldest first, in the first input_count bytes. */
    input : u8[INPUT_BYTES],
    /** How many of input's bytes are waiting, 0 to INPUT_BYTES. */
    input_count : usize,
    /** Each client's held Read, by its index: the most bytes it takes, or 0 for none held. */
    held : u32[service_kit.MAX_CLIENTS],
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
}

/**
 * Drive a virtio console device's first port as a serial line, for the clients that connect to it.
 *
 * It sets the device up, keeps RECEIVE_BUFFERS receive buffers offered, and serves the serial protocol on its
 * listener and each connection made through it, until the system stops. It's started by the supervisor, for a device
 * the platform service gave it, with what its driver holds of it.
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
 * @param domain The DMA domain the device is attached to, which its queues and buffers are made in.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had (decisions/0104), 2 if config couldn't
 *     be mapped, 3 if the device isn't a virtio one it can drive, 4 if it refused its features, 5 if no port could be
 *     made, 6 if its MSI couldn't be set up, 7 if its DMA memory couldn't be made or mapped, 8 if its queues couldn't
 *     be set up, 9 if the listener couldn't be bound.
 */
main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    clients: os.Listener[serial.Serial]) -> int {
    block :: slop_os.startup_block()
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

    driver.port = slop_os.port_create(block.budget) or_return 5
    _ = service_kit.watch_stop(driver.port)
    irq :: slop_os.irq_create_msi(device, block.budget) or_return 6
    message :: slop_os.irq_message(irq) or_return 6
    if !virtio.set_vector(&driver.transport, 0, message.address, message.data) {
        return 6
    }
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent) or_return 6

    // A page for each queue, then the buffers' page
    memory :: slop_os.dma_memory_create(domain, block.budget, 3 * PAGE, 0) or_return 7
    pages :: runtime.reserve_addresses(cast[usize](3 * PAGE)) or_return 7
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, block.space, pages, 0, 3 * PAGE, read_write) or_return 7
    device_address :: slop_os.memory_device_address(memory) or_return 7
    driver.receive = virtio.setup_queue(&driver.transport, RECEIVE_QUEUE, pages, device_address,virtio.QUEUE_PAGE, 0) or_return 8
    driver.transmit = virtio.setup_queue(&driver.transport, TRANSMIT_QUEUE, pages + PAGE, device_address + PAGE,virtio.QUEUE_PAGE, 0) or_return 8
    driver.buffers = pages + 2 * PAGE
    driver.buffers_device = device_address + 2 * PAGE
    virtio.ready(&driver.transport)
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)
    for buffer in 0..<RECEIVE_BUFFERS {
        offer_receive(driver, cast[u8](buffer))
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
        take_input(driver)
        answer_held(driver)
        // Asked to stop, as the system shuts down (decisions/0182): what it was doing is done
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
 * A Write is sent at once, waited for, and answered; a Read is held, to be answered once there's input; Features is
 * answered Line(0); a Connect adds a client, closing its end when there's no room. An unknown request is answered
 * Unsupported, and anything else is skipped.
 *
 * @param driver The driver, whose clients and held Reads change.
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
        match serial.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = serial.answer_unsupported(end, driver.port)
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
        match os.message_of[serial.Request](into)^ {
            case Write(given) => {
                bytes :: os.items(into, given)
                sent :: send(driver, bytes)
                answer(driver, end, .Written(sent))
            }
            case Read(most) => {
                if index < driver.held.count {
                    driver.held[index] = if most == 0 { cast[u32](1) } else { most }
                }
            }
            case Features => answer(driver, end, .Line(0))
            case Connect(connection) => {
                if !service_kit.add_client(&driver.clients, driver.port, connection.end) {
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
 * @param end The channel end of the client whose request is answered, one the driver's clients keep; not checked or
 *     closed here.
 * @param response The response, which has no variable-size data.
 */
answer :: fn(driver: ptr[mut Driver], end: slop_os.Channel, response: serial.Response) {
    out := os.Outgoing.{}
    made :: os.begin[serial.Response](&out)
    made^ = response
    _ = serial.send_response(end, driver.port, &out)
}

/**
 * Send bytes through the transmit queue, a buffer of BUFFER_BYTES at a time, each waited for.
 *
 * @param driver The driver, its transmit queue and buffer used, waiting on its port.
 * @param bytes The bytes, copied into the transmit buffer; empty sends one empty buffer.
 * @return How many bytes went, from the first: all of them, or fewer when the device didn't take a buffer within
 *     SEND_NANOSECONDS, which is logged.
 */
send :: fn(driver: ptr[mut Driver], bytes: u8[]) -> u32 {
    buffer :: driver.buffers + cast[u64](RECEIVE_BUFFERS) * BUFFER_BYTES
    sent : usize = 0
    loop {
        count :: if bytes.count - sent < cast[usize](BUFFER_BYTES) { bytes.count - sent } else { cast[usize](BUFFER_BYTES) }
        chunk :: view_of(cast[ptr[mut u8]](buffer), count)
        for &byte, i in chunk {
            from :: sent + i
            if from < bytes.count {
                byte^ = bytes[from]
            }
        }
        _ = virtio.offer(&driver.transmit, driver.buffers_device + cast[u64](RECEIVE_BUFFERS) * BUFFER_BYTES, cast[u32](count), false)
        if !wait_sent(driver) {
            runtime.log_info("the device didn't take % bytes to send", count)
            break
        }
        sent += count
    }
    while sent < bytes.count
    return cast[u32](sent)
}

/**
 * Wait for the device to take the buffer it was given to send, at most SEND_NANOSECONDS.
 *
 * Any packet on the driver's port wakes it to look again, a client's included.
 *
 * @param driver The driver, a buffer offered on its transmit queue.
 * @return True once the device has given back a transmit buffer; false if it didn't in time.
 */
wait_sent :: fn(driver: ptr[mut Driver]) -> bool {
    deadline :: (slop_os.clock_monotonic() or_else 0) + SEND_NANOSECONDS
    loop {
        if virtio.take_used(&driver.transmit) is_some {
            return true
        }
        packets : slop_os.Packet[4]
        if (slop_os.port_wait(driver.port, packets, deadline) or_else 0) == 0 {
            return false
        }
    }
}

/**
 * Offer a receive buffer to the device to write into, noting which buffer its descriptor holds.
 *
 * @param driver The driver, its receive queue offered the buffer.
 * @param buffer Which receive buffer, 0 to RECEIVE_BUFFERS - 1.
 */
offer_receive :: fn(driver: ptr[mut Driver], buffer: u8) {
    id :: virtio.offer(&driver.receive, driver.buffers_device + cast[u64](buffer) * BUFFER_BYTES, cast[u32](BUFFER_BYTES), true)
    if cast[usize](id) < driver.buffer_of.count {
        driver.buffer_of[id] = buffer
    }
}

/**
 * Take what the device has written into receive buffers into the input, offering each buffer again.
 *
 * Bytes past INPUT_BYTES waiting are dropped.
 *
 * @param driver The driver, whose input grows.
 */
take_input :: fn(driver: ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.receive) or_break
        buffer :: if cast[usize](used.id) < driver.buffer_of.count { driver.buffer_of[used.id] } else { cast[u8](0) }
        length :: if cast[u64](used.length) < BUFFER_BYTES { cast[usize](used.length) } else { cast[usize](BUFFER_BYTES) }
        written :: view_of(cast[ptr[u8]](driver.buffers + cast[u64](buffer) * BUFFER_BYTES), length)
        for byte in written {
            if driver.input_count < driver.input.count {
                driver.input[driver.input_count] = byte
                driver.input_count += 1
            }
        }
        offer_receive(driver, buffer)
    }
}

/**
 * Answer held Reads from the input, client by client in index order, while there's any.
 *
 * Each takes the oldest bytes, as many as it asked for and serial.MAX_BYTES; what's left moves to the input's front.
 *
 * @param driver The driver, whose input shrinks and held Reads are cleared as they're answered.
 */
answer_held :: fn(driver: ptr[mut Driver]) {
    for &most, index in driver.held {
        if driver.input_count == 0 {
            return void
        }
        if most^ == 0 || index >= driver.clients.ends.count {
            continue
        }
        end :: driver.clients.ends[index]
        count :: if driver.input_count < cast[usize](most^) { driver.input_count } else { cast[usize](most^) }
        taken :: if count < serial.MAX_BYTES { count } else { cast[usize](serial.MAX_BYTES) }
        out := os.Outgoing.{}
        response :: os.begin[serial.Response](&out)
        response^ = .Data(os.append(&out, view_of(&driver.input[0], taken)))
        _ = serial.send_response(end, driver.port, &out)
        most^ = 0
        // What's left moves to the front
        for i in 0..<driver.input_count - taken {
            from :: i + taken
            if from < driver.input.count && i < driver.input.count {
                driver.input[i] = driver.input[from]
            }
        }
        driver.input_count -= taken
    }
}
