/**
 * The USB storage driver (roadmap 20f, decisions/0201): a USB mass storage interface, bulk-only transport and SCSI's
 * transparent command set, through its host controller's driver (the USB device protocol), as the block protocol for
 * its clients, as a disk driver's are, so the storage manager takes it as it does any disk.
 *
 * Bulk-only transport runs one command at a time: a command block wrapper on the bulk OUT endpoint, its data on the IN
 * or OUT one, and a status wrapper on the IN one. So each request is done, the whole exchange waited for, before the
 * next is taken; a client's other requests wait in its channel meanwhile. A stalled endpoint is cleared and the status
 * read; a phase error, or a status that doesn't check, starts the reset recovery (§5.3.4). The data moves through the
 * interface's buffer, copied from or to the client's, ordinary memory the driver makes for each connection.
 *
 * Only LUN 0 is served, as a stick's one. A disk whose blocks are larger than block.BLOCK_BYTES serves them as
 * BLOCK_BYTES ones: a transfer has to start and end on one of the disk's, or it's OutOfRange.
 *
 * SPEC: USB Mass Storage Class Bulk-Only Transport 1.0 (the wrappers §5, GET MAX LUN and the reset §3, recovery
 * §5.3.4); SCSI Block Commands 3 and SCSI Primary Commands 4 (TEST UNIT READY, REQUEST SENSE, READ CAPACITY (10),
 * READ (10), WRITE (10), SYNCHRONIZE CACHE (10)).
 */
package usb_storage

import intrinsics from "base:intrinsics"
import runtime from "base:runtime"
import os from "std:os"
import slop_os from "std:os/slop_os"
import service_kit from "../../libraries/service_kit"
import block from "../../protocols/block"
import usb_device from "../../protocols/usb_device"

/** The bytes of each connection's buffer, 32 KiB, which a transfer's data has to fit. */
BUFFER_BYTES : u64 : 32 * 1024
/** Where in the interface's buffer the command wrapper, the status wrapper and the data are. */
COMMAND_OFFSET : u32 : 0
STATUS_OFFSET : u32 : 64
DATA_OFFSET : u32 : 4096
/** The bytes of a command block wrapper, and of a command status wrapper. */
COMMAND_BYTES : u32 : 31
STATUS_BYTES : u32 : 13
/** Their signatures, "USBC" and "USBS" as little-endian u32s. */
COMMAND_SIGNATURE : u32 : 0x43425355
STATUS_SIGNATURE : u32 : 0x53425355
/** How long one transfer may take: 10 s, as a disk may spin up. */
TRANSFER_WAIT : u64 : 10_000_000_000
/** How many times TEST UNIT READY is tried as the disk becomes ready, a unit attention cleared between. */
READY_TRIES :: 20

/** Bulk-only's class requests: the reset (0xff) and GET MAX LUN (0xfe). */
REQUEST_RESET : u8 : 0xff
REQUEST_MAX_LUN : u8 : 0xfe
/** SCSI's operation codes. */
SCSI_TEST_UNIT_READY : u8 : 0x00
SCSI_REQUEST_SENSE : u8 : 0x03
SCSI_READ_CAPACITY : u8 : 0x25
SCSI_READ : u8 : 0x28
SCSI_WRITE : u8 : 0x2a
SCSI_SYNCHRONIZE_CACHE : u8 : 0x35

/** How a command went. */
Outcome :: enum {
    /** Its status said it passed. */
    Passed,
    /** Its status said it failed: a check condition, which REQUEST SENSE says more of. */
    Failed,
    /** The transport failed, or the device is gone. */
    Broken,
}

/** A connection's buffer, once it has one: the memory, and where it's mapped. */
Buffer :: struct {
    memory : slop_os.Memory,
    at : u64,
}

/** The driver's state, on the heap, main's for its life. */
Driver :: struct {
    /** The interface's connection, a port of its own for it, and its buffer, mapped. */
    device : slop_os.Channel,
    device_port : slop_os.Port,
    usb_buffer : u64,
    /** The interface's number, and its bulk IN and OUT endpoints' addresses. */
    interface : u8,
    bulk_in : u8,
    bulk_out : u8,
    /** The next command's tag. */
    tag : u32,
    /** Whether the device is gone. */
    gone : bool,
    /** The disk's size in block.BLOCK_BYTES blocks, and how many of those one of its own is. */
    block_count : u64,
    per_block : u64,
    /** The one port its clients are bound to. */
    port : slop_os.Port,
    clients : service_kit.Clients,
    buffers : Buffer[service_kit.MAX_CLIENTS],
}

/**
 * Drive a USB mass storage interface's LUN 0 as a disk, the block protocol, for the clients that connect to it.
 *
 * It's started by the supervisor for an interface of class 8, subclass 6, protocol 0x50 a host controller's driver
 * found, with a connection to it; it serves until the system stops, or the device's gone.
 *
 * @param log The debug log its lines go to; without one, it writes nothing there.
 * @param device The connection to the interface, the driver's.
 * @param clients The listener its clients' Connects arrive on, served as a client itself.
 * @return It doesn't return while it serves; 0 once its device is gone; 99 if its state couldn't be had, 2 if the
 *     interface couldn't be described or its buffer had, 3 if it hasn't bulk IN and OUT endpoints, 4 if the disk
 *     didn't become ready or its capacity couldn't be read or has blocks the driver can't serve, 5 if no port could be
 *     made, 9 if the listener couldn't be bound.
 */
main :: fn(log : slop_os.DebugLog?, device : os.Channel[usb_device.UsbDevice], clients : os.Listener[block.Block]) -> int {
    startup :: slop_os.startup_block()
    driver_made, driver_error :: runtime.new_aligned(Driver, align_of(Driver))
    if driver_error != null {
        return 99
    }
    driver :: driver_made
    driver.device = device.end
    driver.per_block = 1
    driver.port = slop_os.port_create(startup.budget) or_return 5
    _ = service_kit.watch_stop(driver.port)
    driver.device_port = os.port_for(startup.budget, device.end) or_return 5

    info :: match call(driver, .Describe) {
        case Described(described) => described
        case _ => return 2
    }
    window :: match call(driver, .GetBuffer) {
        case Buffer(memory) => memory
        case _ => return 2
    }
    driver.usb_buffer = map_memory(window, info.buffer_bytes) or_return 2
    if info.buffer_bytes < cast[u64](DATA_OFFSET) + BUFFER_BYTES {
        return 2
    }
    driver.interface = info.interface
    for i in 0..<info.endpoints.count {
        if i >= cast[usize](info.endpoint_count) || info.endpoints[i].kind != .Bulk {
            continue
        }
        if info.endpoints[i].address & 0x80 != 0 {
            driver.bulk_in = info.endpoints[i].address
        }
        else {
            driver.bulk_out = info.endpoints[i].address
        }
    }
    if driver.bulk_in == 0 || driver.bulk_out == 0 {
        return 3
    }
    // GET MAX LUN, which a device with one LUN may stall; LUN 0 is served either way
    _ = control(driver, 0xa1, REQUEST_MAX_LUN, 0, 1)
    if !become_ready(driver) || !read_capacity(driver) {
        return 4
    }

    if !service_kit.add_client(&driver.clients, driver.port, clients.end) {
        return 9
    }
    runtime.log_info("serving %1 blocks, %2 bytes each", driver.block_count, driver.per_block * block.BLOCK_BYTES)
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
        if driver.gone {
            runtime.log_info("its device is gone")
            return 0
        }
        if service_kit.stopping() {
            return 0
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(driver.port, packets, slop_os.NO_DEADLINE)
    }
}

// ---- The device

/**
 * Send one request on the interface's connection and wait for its answer, as each exchange does.
 *
 * @param driver The driver, nothing else in flight on the connection.
 * @param request The request.
 * @return The answer; Unsupported if it couldn't be sent, didn't come within TRANSFER_WAIT, or the connection's gone,
 *     which marks the device gone.
 */
call :: fn(driver : ptr[mut Driver], request : usb_device.Request) -> usb_device.Response {
    out := os.Outgoing.{}
    made :: os.begin[usb_device.Request](&out)
    made^ = request
    if usb_device.send_request(driver.device, driver.device_port, &out) is_some {
        driver.gone = true
        return .Unsupported
    }
    deadline :: (slop_os.clock_monotonic() or_else 0) + TRANSFER_WAIT
    into := os.Incoming.{}
    match usb_device.receive_response(driver.device, driver.device_port, &into, true, deadline) {
        case Received => {}
        case Empty => return .Unsupported
        case _ => {
            driver.gone = true
            return .Unsupported
        }
    }
    answer :: os.message_of[usb_device.Response](&into)^
    match answer {
        case Finished(done) => {
            if done.status == .Gone {
                driver.gone = true
            }
        }
        case _ => {}
    }
    return answer
}

/**
 * Make a control transfer to the interface, its data at DATA_OFFSET, and wait for it.
 *
 * @param driver The driver.
 * @param request_type The setup's bmRequestType.
 * @param request Its bRequest.
 * @param value Its wValue.
 * @param length Its wLength.
 * @return True if it was Done.
 */
control :: fn(driver : ptr[mut Driver], request_type : u8, request : u8, value : u16, length : u16) -> bool {
    setup :: usb_device.Setup.{
        request_type = request_type,
        request = request,
        value = value,
        index = cast[u16](driver.interface),
        length = length,
    }
    return match call(driver, .Control(usb_device.Control.{tag = 0, setup = setup, offset = DATA_OFFSET})) {
        case Finished(done) => done.status == .Done
        case _ => false
    }
}

/**
 * Make a bulk transfer and wait for it.
 *
 * @param driver The driver.
 * @param endpoint The endpoint, bulk_in or bulk_out.
 * @param offset Where the data is in the interface's buffer.
 * @param length Its bytes.
 * @return How it went, and the bytes moved.
 */
bulk :: fn(driver : ptr[mut Driver], endpoint : u8, offset : u32, length : u32) -> usb_device.Completion {
    asked :: usb_device.Transfer.{tag = 0, endpoint = endpoint, offset = offset, length = length}
    return match call(driver, .Transfer(asked)) {
        case Finished(done) => done
        case _ => usb_device.Completion.{status = .DeviceError}
    }
}

/**
 * Clear an endpoint's halt.
 *
 * @param driver The driver.
 * @param endpoint The endpoint.
 * @return True if it's cleared.
 */
clear_halt :: fn(driver : ptr[mut Driver], endpoint : u8) -> bool {
    return match call(driver, .ResetEndpoint(usb_device.ResetEndpoint.{tag = 0, endpoint = endpoint})) {
        case Finished(done) => done.status == .Done
        case _ => false
    }
}

/**
 * The reset recovery (§5.3.4): the bulk-only reset, then both endpoints' halts cleared.
 *
 * @param driver The driver.
 */
reset_recovery :: fn(driver : ptr[mut Driver]) {
    _ = control(driver, 0x21, REQUEST_RESET, 0, 0)
    _ = clear_halt(driver, driver.bulk_in)
    _ = clear_halt(driver, driver.bulk_out)
}

/**
 * Run a SCSI command through bulk-only transport: its command wrapper, its data, and its status.
 *
 * @param driver The driver, whose next tag is the command's.
 * @param command The command block's bytes, 6 to 16.
 * @param length The data's bytes, at DATA_OFFSET, at most BUFFER_BYTES; 0 for none.
 * @param into Whether the data comes from the device.
 * @return How it went; Broken after a transport failure, the reset recovery done.
 */
scsi :: fn(driver : ptr[mut Driver], command : u8[], length : u32, into : bool) -> Outcome {
    if driver.gone {
        return .Broken
    }
    driver.tag += 1
    wrapper :: driver.usb_buffer + cast[u64](COMMAND_OFFSET)
    for i in 0..<cast[u64](COMMAND_BYTES) {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](wrapper + i), 0)
    }
    store_u32(wrapper, 0, COMMAND_SIGNATURE)
    store_u32(wrapper, 4, driver.tag)
    store_u32(wrapper, 8, length)
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](wrapper + 12), if into { cast[u8](0x80) } else { cast[u8](0) })
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](wrapper + 14), cast[u8](command.count))
    for byte, i in command {
        if i < 16 {
            intrinsics.volatile_store_u8(cast[ptr[mut u8]](wrapper + 15 + cast[u64](i)), byte)
        }
    }
    sent :: bulk(driver, driver.bulk_out, COMMAND_OFFSET, COMMAND_BYTES)
    if sent.status != .Done {
        reset_recovery(driver)
        return .Broken
    }
    if length > 0 {
        moved :: bulk(driver, if into { driver.bulk_in } else { driver.bulk_out }, DATA_OFFSET, length)
        if moved.status == .Stalled {
            _ = clear_halt(driver, if into { driver.bulk_in } else { driver.bulk_out })
        }
        else if moved.status != .Done {
            reset_recovery(driver)
            return .Broken
        }
    }
    status := bulk(driver, driver.bulk_in, STATUS_OFFSET, STATUS_BYTES)
    if status.status == .Stalled {
        _ = clear_halt(driver, driver.bulk_in)
        status = bulk(driver, driver.bulk_in, STATUS_OFFSET, STATUS_BYTES)
    }
    at :: driver.usb_buffer + cast[u64](STATUS_OFFSET)
    if status.status != .Done || status.length != STATUS_BYTES || load_u32(at, 0) != STATUS_SIGNATURE
        || load_u32(at, 4) != driver.tag {
        reset_recovery(driver)
        return .Broken
    }
    result :: intrinsics.volatile_load_u8(cast[ptr[u8]](at + 12))
    if result == 0 {
        return .Passed
    }
    if result == 1 {
        return .Failed
    }
    // A phase error
    reset_recovery(driver)
    return .Broken
}

/**
 * Wait for the disk to be ready: TEST UNIT READY until it passes, REQUEST SENSE after each failure, which clears a
 * unit attention, as a reset leaves.
 *
 * @param driver The driver.
 * @return True once it's ready; false after READY_TRIES, or once the transport's broken.
 */
become_ready :: fn(driver : ptr[mut Driver]) -> bool {
    for attempt in 0..<READY_TRIES {
        match scsi(driver, u8.[SCSI_TEST_UNIT_READY, 0, 0, 0, 0, 0], 0, false) {
            case .Passed => return true
            case .Failed => _ = scsi(driver, u8.[SCSI_REQUEST_SENSE, 0, 0, 0, 18, 0], 18, true)
            case .Broken => {
                if driver.gone {
                    return false
                }
            }
        }
    }
    return false
}

/**
 * Read the disk's size and block size (READ CAPACITY (10)).
 *
 * @param driver The driver, whose block_count and per_block are set.
 * @return True if it was read, and its blocks are BLOCK_BYTES to 64 KiB, a whole number of BLOCK_BYTES.
 */
read_capacity :: fn(driver : ptr[mut Driver]) -> bool {
    if scsi(driver, u8.[SCSI_READ_CAPACITY, 0, 0, 0, 0, 0, 0, 0, 0, 0], 8, true) != .Passed {
        return false
    }
    data :: driver.usb_buffer + cast[u64](DATA_OFFSET)
    last :: cast[u64](load_u32_big(data, 0))
    bytes :: cast[u64](load_u32_big(data, 4))
    if bytes < block.BLOCK_BYTES || bytes > 64 * 1024 || bytes % block.BLOCK_BYTES != 0 || last == 0xffff_ffff {
        return false
    }
    driver.per_block = bytes / block.BLOCK_BYTES
    driver.block_count = (last + 1) * driver.per_block
    return true
}

// ---- Clients

/**
 * Answer every request a client has sent, each done before the next, until there are none left, or it's gone.
 *
 * @param driver The driver.
 * @param index Which client, by its index.
 * @param into Where each request is received, reused for each.
 */
serve :: fn(driver : ptr[mut Driver], index : usize, into : ptr[mut os.Incoming]) {
    if index >= driver.clients.ends.count || index >= driver.buffers.count {
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
                release_buffer(driver, index)
                return void
            }
        }
        match os.message_of[block.Request](into)^ {
            case Read(transfer) => answer(driver, end, finished(transfer.tag, transfer_blocks(driver, index, transfer, false)))
            case Write(transfer) => answer(driver, end, finished(transfer.tag, transfer_blocks(driver, index, transfer, true)))
            case Flush(tag) => {
                outcome :: scsi(driver, u8.[SCSI_SYNCHRONIZE_CACHE, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0, false)
                answer(driver, end, finished(tag, if outcome == .Passed { block.Status.Done } else { block.Status.DeviceError }))
            }
            case Describe => answer(
                driver,
                end,
                .Described(
                    block.Info.{
                        block_count = driver.block_count,
                        buffer_bytes = BUFFER_BYTES,
                        read_only = false,
                        flushes = true,
                    }
                )
            )
            case GetBuffer => answer(driver, end, buffer_for(driver, index))
            case Connect(connection) => {
                match service_kit.add_client_index(&driver.clients, driver.port, connection.end) {
                    case Some(added) => release_buffer(driver, added)
                    case None => _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
            }
        }
    }
}

/**
 * Read or write a client's blocks: READ (10) or WRITE (10), the data copied between the client's buffer and the
 * interface's.
 *
 * @param driver The driver.
 * @param client The client's index, below MAX_CLIENTS.
 * @param transfer The blocks, and where in the client's buffer.
 * @param writes True for a Write.
 * @return Done; OutOfRange for a client without a buffer, a count of 0, blocks past the disk or not on its own, or
 *     bytes past the buffer; DeviceError if the command failed.
 */
transfer_blocks :: fn(driver : ptr[mut Driver], client : usize, transfer : block.Transfer, writes : bool) -> block.Status {
    if client >= driver.buffers.count || driver.buffers[client].at == 0 {
        return .OutOfRange
    }
    bytes :: cast[u64](transfer.count) * block.BLOCK_BYTES
    if transfer.count == 0
        || transfer.first > driver.block_count
        || cast[u64](transfer.count) > driver.block_count - transfer.first
        || cast[u64](transfer.offset) > BUFFER_BYTES
        || bytes > BUFFER_BYTES - cast[u64](transfer.offset)
        || transfer.first % driver.per_block != 0
        || cast[u64](transfer.count) % driver.per_block != 0 {
        return .OutOfRange
    }
    first :: transfer.first / driver.per_block
    if first > 0xffff_ffff {
        return .OutOfRange
    }
    count :: cast[u64](transfer.count) / driver.per_block
    data :: driver.usb_buffer + cast[u64](DATA_OFFSET)
    theirs :: driver.buffers[client].at + cast[u64](transfer.offset)
    if writes {
        copy_bytes(data, theirs, bytes)
    }
    command :: u8.[
        if writes { SCSI_WRITE } else { SCSI_READ },
        0,
        cast[u8]((first >> 24) & 0xff),
        cast[u8]((first >> 16) & 0xff),
        cast[u8]((first >> 8) & 0xff),
        cast[u8](first & 0xff),
        0,
        cast[u8]((count >> 8) & 0xff),
        cast[u8](count & 0xff),
        0,
    ]
    if scsi(driver, command, cast[u32](bytes), !writes) != .Passed {
        return .DeviceError
    }
    if !writes {
        copy_bytes(theirs, data, bytes)
    }
    return .Done
}

/**
 * Give a client a window onto its buffer, made and mapped at its first ask.
 *
 * @param driver The driver.
 * @param client The client's index.
 * @return Buffer with a new window; Unsupported if it couldn't be made or mapped.
 */
buffer_for :: fn(driver : ptr[mut Driver], client : usize) -> block.Response? {
    startup :: slop_os.startup_block()
    if client >= driver.buffers.count {
        return block.Response.Unsupported
    }
    if driver.buffers[client].at == 0 {
        memory :: slop_os.memory_create(startup.budget, BUFFER_BYTES) or_return block.Response.Unsupported
        match map_memory(memory, BUFFER_BYTES) {
            case Some(at) => driver.buffers[client] = Buffer.{memory = memory, at = at}
            case None => {
                _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                return block.Response.Unsupported
            }
        }
    }
    window :: slop_os.memory_create_window(driver.buffers[client].memory, startup.budget, 0, BUFFER_BYTES)
        or_return block.Response.Unsupported
    return block.Response.Buffer(window)
}

/**
 * Let a client's buffer go, unmapped and closed, as its client leaves or its place is taken by another.
 *
 * @param driver The driver.
 * @param client The client's index.
 */
release_buffer :: fn(driver : ptr[mut Driver], client : usize) {
    if client >= driver.buffers.count || driver.buffers[client].at == 0 {
        return void
    }
    _ = slop_os.memory_unmap(slop_os.startup_block().space, driver.buffers[client].at)
    _ = slop_os.handle_close(cast[slop_os.Handle](driver.buffers[client].memory))
    driver.buffers[client] = Buffer.{}
}

/**
 * Send a client an answer; one that can't be sent is dropped.
 *
 * @param driver The driver.
 * @param end The client's end.
 * @param response The answer.
 */
answer :: fn(driver : ptr[mut Driver], end : slop_os.Channel, response : block.Response?) {
    given :: response or_return void
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = given
    _ = block.send_response(end, driver.port, &out)
}

/**
 * Make a Finished answer.
 *
 * @param tag The client's tag.
 * @param status How it went.
 * @return Finished; never null.
 */
finished :: fn(tag : u64, status : block.Status) -> block.Response? {
    return block.Response.Finished(block.Completion.{tag = tag, status = status})
}

// ---- Memory

/**
 * Map memory read/write into the driver's address space.
 *
 * @param memory The memory.
 * @param bytes Its size.
 * @return Where it's mapped; null if addresses or the mapping couldn't be had.
 */
map_memory :: fn(memory : slop_os.Memory, bytes : u64) -> u64? {
    startup :: slop_os.startup_block()
    at :: runtime.reserve_addresses(cast[usize](bytes)) or_return null
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    match slop_os.memory_map(memory, startup.space, at, 0, bytes, read_write) {
        case Ok => return at
        case Error(error) => return null
    }
}

/**
 * Copy bytes between two mapped places that don't overlap, 8 at a time where both are aligned.
 *
 * @param to Where they go.
 * @param from Where they come from.
 * @param bytes How many.
 */
copy_bytes :: fn(to : u64, from : u64, bytes : u64) {
    done := cast[u64](0)
    if to % 8 == 0 && from % 8 == 0 {
        loop {
            if done + 8 > bytes {
                break
            }
            cast[ptr[mut u64]](to + done)^ = cast[ptr[u64]](from + done)^
            done += 8
        }
    }
    loop {
        if done >= bytes {
            break
        }
        cast[ptr[mut u8]](to + done)^ = cast[ptr[u8]](from + done)^
        done += 1
    }
}

/**
 * Write a little-endian u32, as a wrapper's fields are.
 *
 * @param base Where the wrapper's mapped.
 * @param offset The field's offset.
 * @param value What's written.
 */
store_u32 :: fn(base : u64, offset : u64, value : u32) {
    for i in 0..<4 {
        intrinsics.volatile_store_u8(cast[ptr[mut u8]](base + offset + cast[u64](i)), cast[u8]((value >> (8 * cast[u32](i))) & 0xff))
    }
}

/**
 * Read a little-endian u32.
 *
 * @param base Where it's mapped.
 * @param offset Its offset.
 * @return Its value.
 */
load_u32 :: fn(base : u64, offset : u64) -> u32 {
    value := cast[u32](0)
    for i in 0..<4 {
        value |= cast[u32](intrinsics.volatile_load_u8(cast[ptr[u8]](base + offset + cast[u64](i)))) << (8 * cast[u32](i))
    }
    return value
}

/**
 * Read a big-endian u32, as SCSI's are.
 *
 * @param base Where it's mapped.
 * @param offset Its offset.
 * @return Its value.
 */
load_u32_big :: fn(base : u64, offset : u64) -> u32 {
    value := cast[u32](0)
    for i in 0..<4 {
        value = (value << 8) | cast[u32](intrinsics.volatile_load_u8(cast[ptr[u8]](base + offset + cast[u64](i))))
    }
    return value
}
