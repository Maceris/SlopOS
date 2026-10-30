/*
 * The virtio-blk driver (decisions/0076): a virtio block device's one queue, through the virtio-pci transport
 * (src/virtio), as the block protocol for its clients, who arrive on its listener. Each connection's buffer is DMA
 * memory of its own, made at its first GetBuffer, which the client reaches through a window and the device reads and
 * writes directly. Up to SLOTS requests are in flight across the clients, each a chain of a header, the data and a
 * status byte, answered with its client's tag as the device finishes it; one past that is answered Busy.
 */
package virtio_blk

import intrinsics from "base"
import runtime from "base"
import os from "std"
import slop_os from "std/os"
import driver_kit from "../../driver_kit"
import pci from "../../pci"
import block from "../../protocols/block"
import service_kit from "../../service_kit"
import virtio from "../../virtio"

PAGE : u64 : 4096
BUFFER_BYTES : u64 : 64 * 1024
SLOTS :: 16
// Clients are bound to the port under their indexes, the IRQ above them
IRQ_KEY : u64 : 1000
// The device's features, and its configuration's capacity, in 512-byte sectors
FEATURE_READ_ONLY : u64 : 1 << 5
FEATURE_FLUSH : u64 : 1 << 9
CAPACITY : u64 : 0
// A request's kind, in its header, and the status the device writes
REQUEST_IN : u32 : 0
REQUEST_OUT : u32 : 1
REQUEST_FLUSH : u32 : 4
STATUS_OK : u8 : 0
HEADER_BYTES : u64 : 16
STATUS_AT : u64 : 512

RequestHeader :: struct #packed {
    kind : u32le,
    reserved : u32le,
    sector : u64le,
}

#assert size_of(RequestHeader) == 16

// A request in flight: whose, its tag, and the chain the device has.
Slot :: struct {
    used : bool,
    client : usize,
    tag : u64,
    head : u16,
    // The client's generation when it was asked for, and the buffer the device reads or writes for it
    generation : u32,
    memory : slop_os.Memory,
}

// A connection's buffer, once it has one: the memory, and where it is to the device.
Buffer :: struct {
    memory : slop_os.Memory,
    device : u64,
}

Driver :: struct {
    log : slop_os.DebugLog,
    domain : slop_os.DmaDomain,
    transport : virtio.Transport,
    queue : virtio.Queue,
    block_count : u64,
    read_only : bool,
    flushes : bool,
    // Each slot's header and status byte, through the driver's mapping and to the device
    requests : u64,
    requests_device : u64,
    slots : Slot[SLOTS],
    buffers : Buffer[service_kit.MAX_CLIENTS],
    // Each client's place's generation, moved on as a client leaves it, so what the device finishes for one that left
    // isn't answered to another in its place
    generations : u32[service_kit.MAX_CLIENTS],
    port : slop_os.Port,
    clients : service_kit.Clients,
}

main :: fn(log: slop_os.DebugLog?, device: slop_os.Device, config: slop_os.Memory, bar0: slop_os.Memory?, bar1: slop_os.Memory?,
    bar2: slop_os.Memory?, bar3: slop_os.Memory?, bar4: slop_os.Memory?, bar5: slop_os.Memory?, domain: slop_os.DmaDomain,
    clients: os.Listener[block.Block]) -> int {
    block_of_startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    driver.domain = domain
    config_at :: driver_kit.map_device(config) or_return 2
    bars := driver_kit.map_bars(bar0, bar1, bar2, bar3, bar4, bar5)
    driver.transport = virtio.open(config_at, bars) or_return 3
    features :: virtio.start(&driver.transport, FEATURE_READ_ONLY | FEATURE_FLUSH) or_return 4
    driver.read_only = features & FEATURE_READ_ONLY != 0
    driver.flushes = features & FEATURE_FLUSH != 0
    if driver.transport.device == 0 {
        return 4
    }
    driver.block_count = virtio.read_u32(driver.transport.device, CAPACITY) | (cast[u64](virtio.read_u32(driver.transport.device, CAPACITY + 4)) << 32)

    driver.port = slop_os.port_create(block_of_startup.budget) or_return 5
    irq :: slop_os.irq_create_msi(device, block_of_startup.budget) or_return 6
    message :: slop_os.irq_message(irq) or_return 6
    if !virtio.set_vector(&driver.transport, 0, message.address, message.data) {
        return 6
    }
    slop_os.port_bind(driver.port, cast[slop_os.Handle](irq), cast[slop_os.Signals](0), IRQ_KEY, .Persistent) or_return 6

    // The queue's page, then the requests' headers and status bytes
    memory :: slop_os.dma_memory_create(domain, block_of_startup.budget, 2 * PAGE, 0) or_return 7
    pages :: runtime.reserve_addresses(cast[usize](2 * PAGE)) or_return 7
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(memory, block_of_startup.space, pages, 0, 2 * PAGE, read_write) or_return 7
    device_address :: slop_os.memory_device_address(memory) or_return 7
    driver.queue = virtio.setup_queue(&driver.transport, 0, pages, device_address, 0) or_return 8
    driver.requests = pages + PAGE
    driver.requests_device = device_address + PAGE
    virtio.ready(&driver.transport)
    pci.write_u16(config_at, pci.COMMAND, pci.read_u16(config_at, pci.COMMAND) | pci.COMMAND_BUS_MASTER)

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    runtime.log_info("serving % blocks%", driver.block_count, if driver.read_only { ", read-only" } else { "" })
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
        finish(driver)
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

serve :: fn(driver: ptr[mut Driver], index: usize, into: ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count {
        return void
    }
    end :: driver.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match block.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = block.answer_unsupported(end, driver.port)
                continue
            }
            case Failed(error) => {
                service_kit.drop_client(&driver.clients, index)
                // Its buffer goes with it, windows and all, so a client taking its place never sees what it held: now,
                // or once the device has finished what it was asked for with it
                if index < driver.buffers.count {
                    driver.generations[index] += 1
                    old :: driver.buffers[index].memory
                    driver.buffers[index] = Buffer.{memory = cast[slop_os.Memory](slop_os.NO_HANDLE)}
                    release_buffer(driver, old)
                }
                return void
            }
            case _ => continue
        }
        match os.message_of[block.Request](into)^ {
            case Read(transfer) => answer(driver, end, start(driver, index, transfer, false))
            case Write(transfer) => answer(driver, end, start(driver, index, transfer, true))
            case Flush(tag) => answer(driver, end, start_flush(driver, index, tag))
            case Describe => answer(driver, end, .Described(block.Info.{block_count = driver.block_count, buffer_bytes = BUFFER_BYTES,
                read_only = driver.read_only, flushes = driver.flushes}))
            case GetBuffer => answer(driver, end, buffer_for(driver, index))
            case Connect(connection) => {
                if !service_kit.add_client(&driver.clients, driver.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

// An answer, if there is one now: a request in flight is answered when the device finishes it.
answer :: fn(driver: ptr[mut Driver], end: slop_os.Channel, response: block.Response?) {
    given :: response or_return void
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = given
    _ = block.send_response(end, driver.port, &out)
}

finished :: fn(tag: u64, status: block.Status) -> block.Response? {
    return block.Response.Finished(block.Completion.{tag = tag, status = status})
}

/*
 * A Read or a Write sent to the device, answered later; or answered now if it's out of range, onto a read-only disk,
 * from a client without a buffer, or with every slot or descriptor taken.
 */
start :: fn(driver: ptr[mut Driver], client: usize, transfer: block.Transfer, writes: bool) -> block.Response? {
    if client >= driver.buffers.count || cast[slop_os.Handle](driver.buffers[client].memory) == slop_os.NO_HANDLE {
        return finished(transfer.tag, .OutOfRange)
    }
    bytes :: cast[u64](transfer.count) * block.BLOCK_BYTES
    if transfer.count == 0 || transfer.first > driver.block_count || cast[u64](transfer.count) > driver.block_count - transfer.first
        || cast[u64](transfer.offset) > BUFFER_BYTES || bytes > BUFFER_BYTES - cast[u64](transfer.offset) {
        return finished(transfer.tag, .OutOfRange)
    }
    if writes && driver.read_only {
        return finished(transfer.tag, .ReadOnly)
    }
    slot :: free_slot(driver) or_return finished(transfer.tag, .Busy)
    header :: write_header(driver, slot, if writes { REQUEST_OUT } else { REQUEST_IN }, transfer.first)
    parts :: virtio.Part.[
        virtio.Part.{address = header, length = cast[u32](HEADER_BYTES), device_writes = false},
        virtio.Part.{address = driver.buffers[client].device + cast[u64](transfer.offset), length = cast[u32](bytes), device_writes = !writes},
        virtio.Part.{address = status_of(driver, slot), length = 1, device_writes = true},
    ]
    return send_slot(driver, slot, client, transfer.tag, parts)
}

// A flush sent to the device, answered later; or answered at once by a device without one, whose writes are durable.
start_flush :: fn(driver: ptr[mut Driver], client: usize, tag: u64) -> block.Response? {
    if !driver.flushes {
        return finished(tag, .Done)
    }
    slot :: free_slot(driver) or_return finished(tag, .Busy)
    header :: write_header(driver, slot, REQUEST_FLUSH, 0)
    parts :: virtio.Part.[
        virtio.Part.{address = header, length = cast[u32](HEADER_BYTES), device_writes = false},
        virtio.Part.{address = status_of(driver, slot), length = 1, device_writes = true},
    ]
    return send_slot(driver, slot, client, tag, parts)
}

// A slot's chain offered to the device: nothing to answer yet, or Busy if the queue has no room for it.
send_slot :: fn(driver: ptr[mut Driver], slot: usize, client: usize, tag: u64, parts: virtio.Part[]) -> block.Response? {
    head :: virtio.offer_chain(&driver.queue, parts)
    if head == virtio.NO_DESCRIPTOR || slot >= driver.slots.count {
        return finished(tag, .Busy)
    }
    generation :: if client < driver.generations.count { driver.generations[client] } else { cast[u32](0) }
    memory :: if client < driver.buffers.count { driver.buffers[client].memory } else { cast[slop_os.Memory](slop_os.NO_HANDLE) }
    driver.slots[slot] = Slot.{used = true, client = client, tag = tag, head = head, generation = generation, memory = memory}
    return null
}

// A buffer its client left, closed, unless the device still has requests with it, the last of which closes it.
release_buffer :: fn(driver: ptr[Driver], memory: slop_os.Memory) {
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        return void
    }
    for slot in driver.slots {
        if slot.used && slot.memory == memory {
            return void
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
}

free_slot :: fn(driver: ptr[Driver]) -> usize? {
    for slot, i in driver.slots {
        if !slot.used {
            return i
        }
    }
    return null
}

// A slot's header, for kind at sector: where it is to the device.
write_header :: fn(driver: ptr[mut Driver], slot: usize, kind: u32, sector: u64) -> u64 {
    header :: cast[ptr[mut RequestHeader]](driver.requests + cast[u64](slot) * HEADER_BYTES)
    header.kind = cast[u32le](kind)
    header.reserved = 0
    header.sector = cast[u64le](sector)
    // The status the device will write, not yet written
    set_status(driver, slot, 0xff)
    return driver.requests_device + cast[u64](slot) * HEADER_BYTES
}

status_of :: fn(driver: ptr[Driver], slot: usize) -> u64 {
    return driver.requests_device + STATUS_AT + cast[u64](slot)
}

set_status :: fn(driver: ptr[mut Driver], slot: usize, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](driver.requests + STATUS_AT + cast[u64](slot)), value)
}

// Every request the device has finished, answered to its client with its tag and how it went.
finish :: fn(driver: ptr[mut Driver]) {
    loop {
        used :: virtio.take_used(&driver.queue) or_break
        for &slot, index in driver.slots {
            if !slot.used || slot.head != used.id {
                continue
            }
            slot.used = false
            status :: intrinsics.volatile_load_u8(cast[ptr[u8]](driver.requests + STATUS_AT + cast[u64](index)))
            current :: slot.client < driver.generations.count && driver.generations[slot.client] == slot.generation
            if current && slot.client < driver.clients.ends.count {
                end :: driver.clients.ends[slot.client]
                if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
                    answer(driver, end, finished(slot.tag, if status == STATUS_OK { block.Status.Done } else { block.Status.DeviceError }))
                }
            }
            // The last request with a buffer its client left closes it
            if !current {
                release_buffer(driver, slot.memory)
            }
            break
        }
    }
}

// A window onto the client's buffer, made at its first ask.
buffer_for :: fn(driver: ptr[mut Driver], client: usize) -> block.Response? {
    block_of_startup :: slop_os.startup_block()
    if client >= driver.buffers.count {
        return block.Response.Unsupported
    }
    if cast[slop_os.Handle](driver.buffers[client].memory) == slop_os.NO_HANDLE {
        memory :: slop_os.dma_memory_create(driver.domain, block_of_startup.budget, BUFFER_BYTES, 0) or_return block.Response.Unsupported
        address :: slop_os.memory_device_address(memory) or_return block.Response.Unsupported
        driver.buffers[client] = Buffer.{memory = memory, device = address}
    }
    window :: slop_os.memory_create_window(driver.buffers[client].memory, block_of_startup.budget, 0, BUFFER_BYTES) or_return block.Response.Unsupported
    return block.Response.Buffer(window)
}
