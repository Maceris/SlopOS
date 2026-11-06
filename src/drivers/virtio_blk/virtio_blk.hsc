/**
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
import service_kit from "../../libraries/service_kit"
import virtio from "../../virtio"

/** The bytes of a page: 4096. */
PAGE : u64 : 4096
/** The bytes of each connection's buffer, 64 KiB, which a transfer's data has to fit. */
BUFFER_BYTES : u64 : 64 * 1024
/** How many requests may be in flight at once, across every client: 16; one more is answered Busy. */
SLOTS :: 16
/** The port key the device's interrupt is bound with; clients are bound under their indexes, below it. */
IRQ_KEY : u64 : 1000
/** The feature bit of a read-only device, VIRTIO_BLK_F_RO (virtio 1.2 §5.2.3). */
FEATURE_READ_ONLY : u64 : 1 << 5
/** The feature bit of a device with a cache to flush, VIRTIO_BLK_F_FLUSH. */
FEATURE_FLUSH : u64 : 1 << 9
/** Where the device configuration's capacity is, in bytes: a u64 of 512-byte sectors, read as two u32s. */
CAPACITY : u64 : 0
/** A request header's kind for a read, VIRTIO_BLK_T_IN (virtio 1.2 §5.2.6). */
REQUEST_IN : u32 : 0
/** A request header's kind for a write, VIRTIO_BLK_T_OUT. */
REQUEST_OUT : u32 : 1
/** A request header's kind for a flush, VIRTIO_BLK_T_FLUSH. */
REQUEST_FLUSH : u32 : 4
/** The status byte the device writes for a request that succeeded, VIRTIO_BLK_S_OK. */
STATUS_OK : u8 : 0
/** The bytes of a request header, and of each slot's place for one in the requests' page: 16. */
HEADER_BYTES : u64 : 16
/** Where the slots' status bytes start in the requests' page, in bytes, one a slot, after their headers. */
STATUS_AT : u64 : 512

/** A request's header, as the device reads it, virtio_blk_req's first 16 bytes (virtio 1.2 §5.2.6). */
RequestHeader :: struct #packed {
    /** REQUEST_IN, REQUEST_OUT or REQUEST_FLUSH. */
    kind : u32le,
    /** Reserved, 0. */
    reserved : u32le,
    /** The first 512-byte sector read or written; 0 for a flush. */
    sector : u64le,
}

#assert size_of(RequestHeader) == 16

/** A request in flight: whose, its tag, and the chain the device has. */
Slot :: struct {
    /** Whether the slot holds a request in flight. */
    used : bool,
    /** The client that asked, by its index. */
    client : usize,
    /** The client's tag, given back in its Finished. */
    tag : u64,
    /** The chain's first descriptor, which the device gives back once it's done. */
    head : u16,
    /** The client's place's generation when it was asked, so it's answered only if the same client's still there. */
    generation : u32,
    /** The buffer the device reads or writes for it, kept until the device's done though its client goes. */
    memory : slop_os.Memory,
}

/** A connection's buffer, once it has one: the memory, and where it is to the device. */
Buffer :: struct {
    /** The buffer's DMA memory, BUFFER_BYTES of it, the driver's; NO_HANDLE before the first GetBuffer. */
    memory : slop_os.Memory,
    /** Where it is to the device, its device address. */
    device : u64,
}

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** Where its lines go, or NO_HANDLE when it wasn't given a log. */
    log : slop_os.DebugLog,
    /** The DMA domain the device is attached to, which every buffer is made in. */
    domain : slop_os.DmaDomain,
    /** The device's registers. */
    transport : virtio.Transport,
    /** The device's one queue, requestq. */
    queue : virtio.Queue,
    /** The disk's size, in block.BLOCK_BYTES blocks, which are its 512-byte sectors. */
    block_count : u64,
    /** Whether the device is read-only, so every Write is ReadOnly. */
    read_only : bool,
    /** Whether the device has a cache to flush; without it, a Flush is answered Done at once. */
    flushes : bool,
    /** Where the requests' page is, through the driver's mapping: each slot's header, then each slot's status byte. */
    requests : u64,
    /** Where the same page is to the device, its device address. */
    requests_device : u64,
    /** The requests in flight. */
    slots : Slot[SLOTS],
    /** Each client's buffer, by its index. */
    buffers : Buffer[service_kit.MAX_CLIENTS],
    /**
     * Each client's place's generation, by its index, moved on as a client leaves it, so what the device finishes for
     * one that left isn't answered to another in its place.
     */
    generations : u32[service_kit.MAX_CLIENTS],
    /** The one port its interrupt and its clients are bound to. */
    port : slop_os.Port,
    /** Its clients, the listener among them. */
    clients : service_kit.Clients,
}

/**
 * Drive a virtio block device as a disk, the block protocol, for the clients that connect to it.
 *
 * It sets the device up and serves the block protocol on its listener and each connection made through it, until
 * the system stops; each connection gets a buffer of its own, which the device reads and writes directly. It's
 * started by the supervisor, for a device the platform service gave it, with what its driver holds of it.
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
 * @param domain The DMA domain the device is attached to, which its queue and every connection's buffer are made in.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 99 if its state couldn't be had (decisions/0104), 2 if config couldn't
 *     be mapped, 3 if the device isn't a virtio one it can drive, 4 if it refused its features or has no device
 *     configuration, 5 if no port could be made, 6 if its MSI couldn't be set up, 7 if its DMA memory couldn't be
 *     made or mapped, 8 if its queue couldn't be set up, 9 if the listener couldn't be bound.
 */
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

/**
 * Answer, or start, every request a client has sent, until there are none left, or it's gone.
 *
 * A Read, Write or Flush is sent to the device, answered once it's done, or answered at once if it can't be; Describe
 * and GetBuffer are answered at once; a Connect adds a client, closing its end when there's no room. An unknown
 * request is answered Unsupported, and anything else is skipped.
 *
 * @param driver The driver, whose slots, buffers and clients change.
 * @param index Which client, by its index; one past them, or a freed place, is nothing to serve. A client whose end
 *     failed is dropped, its place's generation moved on and its buffer let go of, now or once the device is done
 *     with it.
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
        match block.receive_request(end, driver.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = block.answer_unsupported(end, driver.port)
                continue
            }
            case _ => {
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

/**
 * Send a client an answer, if there is one now; one that can't be sent is dropped.
 *
 * @param driver The driver, whose port is waited on while end's ring is full.
 * @param end The channel end of the client whose request is answered, one the driver's clients keep; not checked or
 *     closed here.
 * @param response The answer; null for a request in flight, answered when the device finishes it.
 */
answer :: fn(driver: ptr[mut Driver], end: slop_os.Channel, response: block.Response?) {
    given :: response or_return void
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = given
    _ = block.send_response(end, driver.port, &out)
}

/**
 * Make a Finished answer.
 *
 * @param tag The tag the client gave the request, given back as it is, any value.
 * @param status How it went.
 * @return Finished with tag and status; never null, the optional only for start's and the rest's results.
 */
finished :: fn(tag: u64, status: block.Status) -> block.Response? {
    return block.Response.Finished(block.Completion.{tag = tag, status = status})
}

/**
 * Send a Read or a Write to the device, a chain of the slot's header, the client's buffer at the transfer's offset,
 * and the slot's status byte.
 *
 * @param driver The driver, a slot of whose is taken when the request's sent.
 * @param client The asking client, by its index.
 * @param transfer The blocks, and where in the client's buffer.
 * @param writes True for a Write, which the device reads the buffer for; false for a Read, which it writes it for.
 * @return Null when it's sent, answered when the device finishes it; Finished now with OutOfRange for a client without
 *     a buffer, a count of 0, or blocks past the disk or bytes past the buffer; ReadOnly for a Write to a read-only
 *     disk; Busy with every slot or descriptor taken.
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

/**
 * Send a Flush to the device, a chain of the slot's header and status byte.
 *
 * @param driver The driver; a device without a cache needs nothing of it.
 * @param client The asking client, by its index.
 * @param tag The tag the client gave the Flush, any value; kept in the slot and given back in its Finished.
 * @return Null when it's sent, answered when the device finishes it; Finished now with Done for a device without a
 *     cache, whose writes are durable, or Busy with every slot or descriptor taken.
 */
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

/**
 * Offer a slot's chain to the device, and note the request in the slot.
 *
 * @param driver The driver, its queue offered the chain.
 * @param slot The slot, free, its header and status byte written.
 * @param client The asking client, by its index, whose generation and buffer the slot keeps.
 * @param tag The tag the client gave the request, any value; kept in the slot to answer with, or given back now with
 *     Busy.
 * @param parts The chain's buffers, at most virtio.MAX_CHAIN.
 * @return Null once it's offered; Finished with Busy if the queue hasn't the descriptors for it.
 */
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

/**
 * Close a buffer its client left, unless the device still has requests with it, the last of which closes it.
 *
 * @param driver The driver, whose slots are looked through for requests with the buffer.
 * @param memory The buffer's memory; NO_HANDLE is nothing to close.
 */
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

/**
 * Find a slot not in use.
 *
 * @param driver The driver, which isn't changed.
 * @return The lowest free slot's index; null if all SLOTS are in flight.
 */
free_slot :: fn(driver: ptr[Driver]) -> usize? {
    for slot, i in driver.slots {
        if !slot.used {
            return i
        }
    }
    return null
}

/**
 * Write a slot's request header, and mark its status byte not yet written (0xff).
 *
 * @param driver The driver, its requests' page written.
 * @param slot The slot, below SLOTS.
 * @param kind REQUEST_IN, REQUEST_OUT or REQUEST_FLUSH.
 * @param sector The first sector, 0 for a flush.
 * @return The header's device address, for the chain's first part.
 */
write_header :: fn(driver: ptr[mut Driver], slot: usize, kind: u32, sector: u64) -> u64 {
    header :: cast[ptr[mut RequestHeader]](driver.requests + cast[u64](slot) * HEADER_BYTES)
    header.kind = cast[u32le](kind)
    header.reserved = 0
    header.sector = cast[u64le](sector)
    // The status the device will write, not yet written
    set_status(driver, slot, 0xff)
    return driver.requests_device + cast[u64](slot) * HEADER_BYTES
}

/**
 * Give where a slot's status byte is to the device.
 *
 * @param driver The driver, for where its requests' page is to the device.
 * @param slot The slot, below SLOTS.
 * @return The status byte's device address, for the chain's last part.
 */
status_of :: fn(driver: ptr[Driver], slot: usize) -> u64 {
    return driver.requests_device + STATUS_AT + cast[u64](slot)
}

/**
 * Write a slot's status byte, with a volatile store, as the device will read it back.
 *
 * @param driver The driver, its requests' page written.
 * @param slot The slot, below SLOTS.
 * @param value The status byte written, 0xff for one the device hasn't written yet.
 */
set_status :: fn(driver: ptr[mut Driver], slot: usize, value: u8) {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](driver.requests + STATUS_AT + cast[u64](slot)), value)
}

/**
 * Answer every request the device has finished to its client, with its tag, Done for STATUS_OK and DeviceError
 * otherwise, and free its slot.
 *
 * A request whose client left isn't answered, and the last of a left client's lets its buffer go.
 *
 * @param driver The driver, its queue's finished chains taken and its slots freed.
 */
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

/**
 * Give a client a window onto its buffer, the buffer made at its first ask.
 *
 * @param driver The driver, whose buffer for the client is made in its DMA domain the first time.
 * @param client The asking client, by its index.
 * @return Buffer with a new window onto all of the buffer, read-write, which moves to the client; Unsupported if the
 *     client's index is past them, or the buffer or window couldn't be made.
 */
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
