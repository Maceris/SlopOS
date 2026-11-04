/**
 * A partition server (roadmap 8a, decisions/0086): one per disk, started by the storage manager with a block
 * connection to the disk and nothing else, so a disk from outside is parsed by a process that can reach nothing but
 * it. It reads the disk's GPT (src/gpt), primary or backup, and serves the partitions protocol: each partition
 * described, and block connections narrowed to one.
 *
 * A narrowed connection is a connection of its own to the disk's driver, which the partition server stands between:
 * the client's GetBuffer is the driver's, so data moves between the device and the client with no copies; Reads and
 * Writes are checked against the partition's blocks and moved by its first, and one past its end is answered
 * OutOfRange without reaching the driver; Describe is answered with the partition's size; everything the driver
 * answers goes back to the client as it is.
 *
 * Built with robustness=on (decisions/0096's R4, 0112), it's a faulty block connection when the kernel's command
 * line, which it's given, says faulty_block=<read|write|tear>:<n>: the nth read or write through its narrowed
 * connections fails as a device's would, DeviceError, without reaching the disk, or for tear, with only its first half
 * written. Without robustness=on, none of that is compiled in.
 */
package partition_server

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import gpt from "../../gpt"
import log_line from "../../log_line"
import block from "../../protocols/block"
import partitions from "../../protocols/partitions"
import robustness from "../../robustness"
import service_kit from "../../libraries/service_kit"

/**
 * The most narrowed connections made in the server's life; a slot isn't used again once its connection closes, so one
 * past them is refused.
 */
MAX_NARROWED :: 16
/** The key a narrowed connection's client is bound to the port with, plus its slot. */
CLIENT_KEY : u64 : 100
/** The key a narrowed connection's driver is bound to the port with, plus its slot. */
DRIVER_KEY : u64 : 200
/** No channel: to open, a connection with no client's end given, for which one is made. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

/**
 * A connection narrowed to a partition: the client's end, the driver's, and the partition's blocks and what the
 * driver says.
 */
Narrowed :: struct {
    /** The client's end, the server's own; NO_HANDLE once it's closed. */
    client : slop_os.Channel,
    /** Its own connection to the disk's driver, the server's own; NO_HANDLE once it's closed. */
    driver : slop_os.Channel,
    /** The partition's first block on the disk, which the client's blocks are moved by. */
    first : u64,
    /** The partition's size in blocks; the client's blocks run from 0 to it. */
    count : u64,
    /** What the driver says of itself, with the partition's size for its block count, answered to Describe. */
    info : block.Info,
    /** Whether a torn write's answer is waited for, to go back as a failure. */
    torn : bool,
    /** The torn write's tag, while torn. */
    torn_tag : u64,
}

/** What faulty_block asks for (robustness=on only): which request fails, and how, and the reads and writes so far. */
FaultyBlock :: struct {
    /** Which kind of request fails, and how; None for none. */
    kind : FaultKind,
    /** Which one fails, counting reads, or writes, from 1 across every narrowed connection. */
    nth : u64,
    /** The reads through narrowed connections so far, inside their partitions. */
    reads : u64,
    /** The writes through narrowed connections so far, inside their partitions. */
    writes : u64,
}

/** How faulty_block makes a request fail. */
FaultKind :: enum {
    /** Nothing fails. */
    None,
    /** The nth read fails with DeviceError, without reaching the disk. */
    Read,
    /** The nth write fails with DeviceError, without reaching the disk. */
    Write,
    /** The nth write has only its first half written, and fails with DeviceError. */
    Tear,
}

/** The partition server's state, made once in main, on the heap, and kept for as long as it runs. */
Server :: struct {
    /** The debug log it says what it found in; NO_HANDLE for none. */
    log : slop_os.DebugLog,
    /** The port its clients and narrowed connections are bound to. */
    port : slop_os.Port,
    /** Its own connection to the disk, which it reads the table through and makes the narrowed ones' with. */
    disk : slop_os.Channel,
    /** A port bound to disk, waited on for its answers. */
    disk_port : slop_os.Port,
    /** Where disk's buffer is mapped, readable and writable, in the process's address space. */
    buffer : u64,
    /** The buffer's size in bytes. */
    buffer_bytes : u64,
    /** The disk's size in blocks. */
    block_count : u64,
    /** The disk's partitions, as its GPT says; none if it has no GPT that can be read. */
    table : gpt.Table,
    /** The clients' ends: the listener's, and connections arrived as Connects. */
    clients : service_kit.Clients,
    /** The narrowed connections, by slot, narrowed_count of them. */
    narrowed : Narrowed[MAX_NARROWED],
    /** How many slots of narrowed have been used, closed ones included. */
    narrowed_count : usize,
    /** What faulty_block asks for; nothing outside robustness=on. */
    faulty : FaultyBlock,
}

/**
 * Serve a disk's partitions: read its GPT, describe each partition, and give block connections narrowed to one.
 *
 * Started by the storage manager, one per disk, with nothing but the disk, so a disk from outside is parsed by a
 * process that can reach nothing else. A disk with no GPT that can be read has no partitions. Runs until it's stopped.
 *
 * @param log The debug log it says what it found in; without one, it says nothing.
 * @param disk A block connection to the whole disk, which it takes the buffer of.
 * @param clients The listener the storage manager's connection arrives on.
 * @param command_line The kernel's command line, read for faulty_block when built with robustness=on; without it, or
 *     without robustness=on, nothing fails on purpose.
 * @return 99 without the memory for its state, 1 if its ports couldn't be made, 2 if the disk didn't describe itself,
 *     3 if it didn't give its buffer, 4 if the buffer couldn't be mapped, 5 without the memory to read the table, and
 *     6 if clients couldn't be added. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, disk: os.Channel[block.Block], clients: os.Listener[partitions.Partitions], command_line: slop_os.Memory?)
    -> int {
    startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    server_made, server_error :: runtime.new_aligned(Server, align_of(Server))
    if server_error != null {
        return 99
    }
    server :: server_made
    server.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    server.disk = disk.end
    server.disk_port = os.port_for(startup.budget, disk.end) or_return 1
    server.port = slop_os.port_create(startup.budget) or_return 1
    #if robustness.ON {
        match command_line {
            case Some(memory) => server.faulty = faulty_of(service_kit.word_after(service_kit.text_of(startup, memory) or_else "", "faulty_block=") or_else "")
            case None => {}
        }
    }

    // The disk, its buffer, and its table
    info := block.Info.{}
    match call(server.disk, server.disk_port, .Describe) {
        case Described(described) => info = described
        case _ => return 2
    }
    server.block_count = info.block_count
    server.buffer_bytes = info.buffer_bytes
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match call(server.disk, server.disk_port, .GetBuffer) {
        case Buffer(memory) => window = memory
        case _ => return 3
    }
    server.buffer = runtime.reserve_addresses(cast[usize](info.buffer_bytes)) or_return 4
    read_write :: cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
    slop_os.memory_map(window, startup.space, server.buffer, 0, info.buffer_bytes, read_write) or_return 4
    entries, error :: runtime.new_array(u8, cast[usize](gpt.ENTRY_BLOCKS * gpt.BLOCK_BYTES))
    if error != null {
        return 5
    }
    reader := gpt.Disk.{context = cast[rawptr](server), block_count = info.block_count, read = read_blocks}
    match gpt.read_table(&reader, entries) {
        case Ok(table) => {
            server.table = table
            log_line.write(server.log, "partition_server: % partitions on a disk of % blocks%", table.count, info.block_count,
                if table.from_backup { ", from the backup GPT" } else { "" })
        }
        case Error(failure) => log_line.write(server.log, "partition_server: no GPT on a disk of % blocks: %", info.block_count, failure)
    }
    runtime.free_array(entries)

    if !service_kit.add_client(&server.clients, server.port, clients.end) {
        return 6
    }
    into := os.Incoming.{}
    loop {
        // Clients that connect meanwhile are read in the same pass, as a channel wakes its reader only once it's found empty
        with {
            i : usize = 0
        }
        loop {
            serve_client(server, i, &into)
            i += 1
        }
        while i < server.clients.count
        for j in 0..<server.narrowed_count {
            serve_narrowed(server, j, &into)
            pass_back(server, j, &into)
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(server.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Read blocks of the disk through its buffer, as many at a time as the buffer has room for, for gpt's Disk.
 *
 * @param context The partition server, a ptr[mut Server] passed as gpt's Disk context; its disk connection is asked,
 *     one read at a time, and its buffer overwritten.
 * @param first The first block on the disk.
 * @param count How many blocks.
 * @param into Where they go, at least count blocks long.
 * @return Whether they were all read; false if into is too short, the buffer holds no block, or a read failed.
 */
read_blocks :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    per_read :: server.buffer_bytes / block.BLOCK_BYTES
    if per_read == 0 || count * block.BLOCK_BYTES > cast[u64](into.count) {
        return false
    }
    done := cast[u64](0)
    loop {
        if done >= count {
            break
        }
        now :: if count - done < per_read { count - done } else { per_read }
        transfer :: block.Transfer.{tag = 1, first = first + done, count = cast[u32](now), offset = 0}
        match call(server.disk, server.disk_port, .Read(transfer)) {
            case Finished(completion) => {
                if completion.status != .Done {
                    return false
                }
            }
            case _ => return false
        }
        source :: view_of(cast[ptr[u8]](server.buffer), cast[usize](now * block.BLOCK_BYTES))
        for byte, i in source {
            at :: cast[usize](done * block.BLOCK_BYTES) + i
            if at < into.count {
                into[at] = byte
            }
        }
        done += now
    }
    return true
}

/**
 * Answer a client's requests, until it has none, or it's gone: its partitions described, and connections to them
 * made.
 *
 * Describe and Open of a partition the table hasn't are answered NoPartition, as an Open that can't be made is.
 * Connect adds a client, with no answer. A client whose end fails is dropped.
 *
 * @param server The server, whose table is read; a client whose end fails is dropped from its clients, and a Connect's
 *     end added to them.
 * @param index The client's index in server.clients; one past them, or one dropped, is left alone.
 * @param into Where each request is read into, reused.
 */
serve_client :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.clients.ends.count {
        return void
    }
    end :: server.clients.ends[index]
    if cast[slop_os.Handle](end) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match partitions.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = partitions.answer_unsupported(end, server.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                service_kit.drop_client(&server.clients, index)
                return void
            }
        }
        response : partitions.Response = .NoPartition
        match os.message_of[partitions.Request](into)^ {
            case Describe(which) => {
                if which < server.table.count && cast[usize](which) < server.table.partitions.count {
                    response = .Described(info_of(&server.table.partitions[cast[usize](which)]))
                }
            }
            case Open(which) => {
                if which < server.table.count && cast[usize](which) < server.table.partitions.count {
                    partition :: &server.table.partitions[cast[usize](which)]
                    match open(server, partition.first, partition.count, NONE) {
                        case Some(made) => response = .Opened(os.Channel[block.Block].{end = made})
                        case None => {}
                    }
                }
            }
            case Connect(connection) => {
                if !service_kit.add_client(&server.clients, server.port, connection.end) {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
        }
        out := os.Outgoing.{}
        made :: os.begin[partitions.Response](&out)
        made^ = response
        _ = partitions.send_response(end, server.port, &out)
    }
}

/**
 * Describe a partition as the protocol does.
 *
 * @param partition The partition, as the GPT says.
 * @return Its first block, its size in blocks, its type and unique GUIDs, and its name, cut to fit.
 */
info_of :: fn(partition: ptr[gpt.Partition]) -> partitions.PartitionInfo {
    info := partitions.PartitionInfo.{first = partition.first, count = partition.count, type_guid = partition.type_guid,
        unique_guid = partition.unique_guid, name_length = partition.name_length}
    for byte, i in partition.name {
        if i < info.name.count {
            info.name[i] = byte
        }
    }
    return info
}

/**
 * Make a connection narrowed to blocks of the disk: a connection of its own to the driver, made through the
 * partition server's, and described, and the client's end, both bound to the port.
 *
 * Its requests waiting already are served before it returns, so its next message wakes the port.
 *
 * @param server The server, whose next narrowed slot is taken; the driver is connected to through its disk connection,
 *     and asked to Describe, waited for.
 * @param first The first block on the disk.
 * @param count How many blocks.
 * @param client The end a client gave, which the server takes over once it's made; or NONE, for a new channel.
 * @return With NONE, the new channel's other end, the client's, which the caller owns; with an end given, NO_HANDLE.
 *     Null if it can't be made: MAX_NARROWED made already, or the driver, a port, a channel or a binding couldn't be
 *     had. An end given isn't closed then; the caller closes it.
 */
open :: fn(server: ptr[mut Server], first: u64, count: u64, client: slop_os.Channel) -> slop_os.Channel? {
    slot :: server.narrowed_count
    if slot >= server.narrowed.count {
        return null
    }
    startup :: slop_os.startup_block()
    driver :: block.connect(server.disk, server.disk_port, startup.budget) or_return null
    driver_port :: os.port_for(startup.budget, driver.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](driver_port) == slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](driver.end))
        return null
    }
    info := block.Info.{}
    match call(driver.end, driver_port, .Describe) {
        case Described(described) => info = described
        case _ => {
            _ = slop_os.handle_close(cast[slop_os.Handle](driver.end))
            return null
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](driver_port))
    ours := client
    theirs := NONE
    if cast[slop_os.Handle](client) == slop_os.NO_HANDLE {
        match os.channel_for[block.Block](startup.budget, 0) {
            case Ok(pair) => {
                ours = pair.a
                theirs = pair.b
            }
            case Error(error) => {
                _ = slop_os.handle_close(cast[slop_os.Handle](driver.end))
                return null
            }
        }
    }
    // Unwatched, a connection's requests would never be read: without both, there's no connection
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    if (slop_os.port_bind(server.port, cast[slop_os.Handle](ours), signals, CLIENT_KEY + cast[u64](slot), .Persistent) is_error)
        || (slop_os.port_bind(server.port, cast[slop_os.Handle](driver.end), signals, DRIVER_KEY + cast[u64](slot), .Persistent) is_error) {
        _ = slop_os.port_unbind(server.port, CLIENT_KEY + cast[u64](slot))
        _ = slop_os.handle_close(cast[slop_os.Handle](driver.end))
        if cast[slop_os.Handle](theirs) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](ours))
            _ = slop_os.handle_close(cast[slop_os.Handle](theirs))
        }
        return null
    }
    info.block_count = count
    server.narrowed[slot] = Narrowed.{client = ours, driver = driver.end, first = first, count = count, info = info}
    server.narrowed_count = slot + 1
    // Each read until it's empty, so its next message wakes the port
    into := os.Incoming.{}
    serve_narrowed(server, slot, &into)
    pass_back(server, slot, &into)
    return theirs
}

/**
 * Pass a narrowed connection's requests to its driver, until it has none, or it's gone.
 *
 * Reads and writes are checked against the partition's blocks and moved by its first, and one outside them answered
 * OutOfRange; faulty_block's read or write fails here. Describe is answered with the partition's size, and Connect
 * makes another narrowed connection to the same partition on the end given, closed if it can't be made. Everything
 * else goes to the driver as it is. A connection whose end fails is closed.
 *
 * @param server The server, whose faulty_block counts go up with each read and write inside the partition; a Connect
 *     takes another narrowed slot.
 * @param index The narrowed connection's slot; a closed one is left alone.
 * @param into Where each request is read into, reused.
 */
serve_narrowed :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.narrowed.count {
        return void
    }
    narrowed :: &server.narrowed[index]
    if cast[slop_os.Handle](narrowed.client) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match block.receive_request(narrowed.client, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = block.answer_unsupported(narrowed.client, server.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                close_narrowed(narrowed)
                return void
            }
        }
        request :: os.message_of[block.Request](into)^
        forwarded := request
        match request {
            case Read(transfer) => {
                if !inside(narrowed, transfer) {
                    answer(narrowed.client, server.port, .Finished(block.Completion.{tag = transfer.tag, status = .OutOfRange}))
                    continue
                }
                if faulty_read(server) {
                    answer(narrowed.client, server.port, .Finished(block.Completion.{tag = transfer.tag, status = .DeviceError}))
                    continue
                }
                moved := transfer
                moved.first += narrowed.first
                forwarded = .Read(moved)
            }
            case Write(transfer) => {
                if !inside(narrowed, transfer) {
                    answer(narrowed.client, server.port, .Finished(block.Completion.{tag = transfer.tag, status = .OutOfRange}))
                    continue
                }
                moved := transfer
                match faulty_write(server) {
                    case .Write => {
                        answer(narrowed.client, server.port, .Finished(block.Completion.{tag = transfer.tag, status = .DeviceError}))
                        continue
                    }
                    // Its first half written, and its answer a failure
                    case .Tear => {
                        moved.count = if transfer.count > 1 { transfer.count / 2 } else { transfer.count }
                        narrowed.torn = true
                        narrowed.torn_tag = transfer.tag
                    }
                    case _ => {}
                }
                moved.first += narrowed.first
                forwarded = .Write(moved)
            }
            case Describe => {
                answer(narrowed.client, server.port, .Described(narrowed.info))
                continue
            }
            case Connect(connection) => {
                // Another client of the same partition, on its end, with a driver connection of its own
                if open(server, narrowed.first, narrowed.count, connection.end) is_none {
                    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
                }
                continue
            }
            case _ => {}
        }
        out := os.Outgoing.{}
        made :: os.begin[block.Request](&out)
        made^ = forwarded
        _ = block.send_request(narrowed.driver, server.port, &out)
    }
}

/**
 * Pass what the driver answered a narrowed connection's requests back to its client as it is, until there's nothing
 * more; a torn write's answer goes back as DeviceError.
 *
 * @param server The server, on whose port the answers are read from the slot's driver connection and sent on to its
 *     client.
 * @param index The narrowed connection's slot; it's closed if its driver's connection fails.
 * @param into Where each answer is read into, reused.
 */
pass_back :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.narrowed.count {
        return void
    }
    narrowed :: &server.narrowed[index]
    if cast[slop_os.Handle](narrowed.driver) == slop_os.NO_HANDLE {
        return void
    }
    loop {
        match block.receive_response(narrowed.driver, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Failed(error) => {
                close_narrowed(narrowed)
                return void
            }
            case _ => continue
        }
        response := os.message_of[block.Response](into)^
        match response {
            case Finished(completion) => if narrowed.torn && completion.tag == narrowed.torn_tag {
                narrowed.torn = false
                response = .Finished(block.Completion.{tag = completion.tag, status = .DeviceError})
            }
            case _ => {}
        }
        answer(narrowed.client, server.port, response)
    }
}

/**
 * Read faulty_block's value.
 *
 * @param text The value: read:<n>, write:<n> or tear:<n>, n from 1.
 * @return Which request fails, and how; one where nothing fails for anything else.
 */
faulty_of :: fn(text: string) -> FaultyBlock {
    for kind in FaultKind.[.Read, .Write, .Tear] {
        prefix :: prefix_of(kind)
        if text.count > prefix.count && text[0..<prefix.count] == prefix {
            nth :: robustness.number_of(text[prefix.count..<text.count]) or_return FaultyBlock.{}
            return FaultyBlock.{kind = kind, nth = nth}
        }
    }
    return FaultyBlock.{}
}

/**
 * Give the prefix faulty_block's value has for a kind of fault.
 *
 * @param kind Read, Write or Tear.
 * @return "read:", "write:", or "tear:" for any other kind.
 */
prefix_of :: fn(kind: FaultKind) -> string {
    return if kind == .Read { "read:" } else if kind == .Write { "write:" } else { "tear:" }
}

/**
 * Count a read, and tell whether it's the one faulty_block fails, logging it if it is.
 *
 * @param server The server, whose faulty.reads is counted up.
 * @return Whether it fails; always false without robustness=on.
 */
faulty_read :: fn(server: ptr[mut Server]) -> bool {
    #if robustness.ON {
        server.faulty.reads += 1
        if server.faulty.kind == .Read && server.faulty.reads == server.faulty.nth {
            log_line.write(server.log, "partition_server: faulty_block: failed read %", server.faulty.nth)
            return true
        }
    }
    return false
}

/**
 * Count a write, and tell how it fails, if it's the one faulty_block fails, logging it if it is.
 *
 * @param server The server, whose faulty.writes is counted up.
 * @return Write or Tear for the write that fails; None otherwise, and always without robustness=on.
 */
faulty_write :: fn(server: ptr[mut Server]) -> FaultKind {
    #if robustness.ON {
        server.faulty.writes += 1
        if (server.faulty.kind == .Write || server.faulty.kind == .Tear) && server.faulty.writes == server.faulty.nth {
            log_line.write(server.log, "partition_server: faulty_block: % write %", if server.faulty.kind == .Tear { "tore" } else { "failed" },
                server.faulty.nth)
            return server.faulty.kind
        }
    }
    return .None
}

/**
 * Tell whether a transfer's blocks are all the partition's.
 *
 * @param narrowed The narrowed connection, read for its partition's size in blocks; not changed.
 * @param transfer The transfer, its blocks counted from the partition's start.
 * @return Whether its first block is inside the partition and its count reaches no further than the partition's end.
 */
inside :: fn(narrowed: ptr[Narrowed], transfer: block.Transfer) -> bool {
    return transfer.first < narrowed.count && cast[u64](transfer.count) <= narrowed.count - transfer.first
}

/**
 * Close a narrowed connection's ends, the client's and the driver's; its slot isn't used again.
 *
 * @param narrowed The narrowed connection, whose client and driver ends are closed and set to NO_HANDLE; an end that's
 *     NO_HANDLE already is left alone.
 */
close_narrowed :: fn(narrowed: ptr[mut Narrowed]) {
    for end in slop_os.Channel.[narrowed.client, narrowed.driver] {
        if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
        }
    }
    narrowed.client = cast[slop_os.Channel](slop_os.NO_HANDLE)
    narrowed.driver = cast[slop_os.Channel](slop_os.NO_HANDLE)
}

/**
 * Send an answer on a block connection.
 *
 * @param end The client's end, kept open.
 * @param port The server's port, waited on while the ring is full.
 * @param response The answer, sent as it is, with any handle it carries; whether it could be sent isn't told.
 */
answer :: fn(end: slop_os.Channel, port: slop_os.Port, response: block.Response) {
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = response
    _ = block.send_response(end, port, &out)
}

/**
 * Send one request on a block connection, and wait for its answer.
 *
 * @param end The block connection, with no other request in flight, so the next answer is this one's.
 * @param port A port bound to end.
 * @param request The request, sent as it is; a Read or Write's blocks are the disk's, its data in the buffer.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection's
 *     gone.
 */
call :: fn(end: slop_os.Channel, port: slop_os.Port, request: block.Request) -> block.Response {
    out := os.Outgoing.{}
    made :: os.begin[block.Request](&out)
    made^ = request
    if block.send_request(end, port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match block.receive_response(end, port, &into, true) {
            case Received => return os.message_of[block.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}
