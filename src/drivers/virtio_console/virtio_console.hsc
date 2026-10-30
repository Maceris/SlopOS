/*
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
import service_kit from "../../service_kit"
import virtio from "../../virtio"

PAGE : u64 : 4096
RECEIVE_QUEUE : u16 : 0
TRANSMIT_QUEUE : u16 : 1
RECEIVE_BUFFERS :: 4
BUFFER_BYTES : u64 : 256
INPUT_BYTES :: 1024
// Clients are bound to the port under their indexes, the IRQ above them
IRQ_KEY : u64 : 1000
// The longest the device may take to send a buffer
SEND_NANOSECONDS : u64 : 1_000_000_000

Driver :: struct {
    log : slop_os.DebugLog,
    transport : virtio.Transport,
    receive : virtio.Queue,
    transmit : virtio.Queue,
    // The buffers' page, through the driver's mapping and to the device: RECEIVE_BUFFERS to receive, then one to send
    buffers : u64,
    buffers_device : u64,
    // Which receive buffer each descriptor holds
    buffer_of : u8[virtio.MAX_QUEUE_SIZE],
    port : slop_os.Port,
    // What's arrived and no Read has taken yet
    input : u8[INPUT_BYTES],
    input_count : usize,
    // Each client's held Read: the most it takes, or 0 for none
    held : u32[service_kit.MAX_CLIENTS],
    clients : service_kit.Clients,
}

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
    driver.receive = virtio.setup_queue(&driver.transport, RECEIVE_QUEUE, pages, device_address, 0) or_return 8
    driver.transmit = virtio.setup_queue(&driver.transport, TRANSMIT_QUEUE, pages + PAGE, device_address + PAGE, 0) or_return 8
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
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

// Every request a client has sent, until there are none left, or it's gone.
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
            case Failed(error) => {
                service_kit.drop_client(&driver.clients, index)
                if index < driver.held.count {
                    driver.held[index] = 0
                }
                return void
            }
            case _ => continue
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

answer :: fn(driver: ptr[mut Driver], end: slop_os.Channel, response: serial.Response) {
    out := os.Outgoing.{}
    made :: os.begin[serial.Response](&out)
    made^ = response
    _ = serial.send_response(end, driver.port, &out)
}

// bytes, through the transmit queue a buffer at a time, each waited for: how many went.
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

// Whether the device took the buffer it was given to send, waiting for its MSI.
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

// A receive buffer offered to the device to write into.
offer_receive :: fn(driver: ptr[mut Driver], buffer: u8) {
    id :: virtio.offer(&driver.receive, driver.buffers_device + cast[u64](buffer) * BUFFER_BYTES, cast[u32](BUFFER_BYTES), true)
    if cast[usize](id) < driver.buffer_of.count {
        driver.buffer_of[id] = buffer
    }
}

// What the device has written into receive buffers, added to the input, and each buffer offered again.
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

// Held Reads answered from the input, in order, while there's any.
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
