/*
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
 */
package partition_server

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import gpt from "../../gpt"
import log_line from "../../log_line"
import block from "../../protocols/block"
import partitions from "../../protocols/partitions"
import service_kit from "../../service_kit"

// Narrowed connections, at most; each is bound to the port twice, its client from CLIENT_KEY and the driver from DRIVER_KEY
MAX_NARROWED :: 16
CLIENT_KEY : u64 : 100
DRIVER_KEY : u64 : 200
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)

// A connection narrowed to a partition: the client's end, the driver's, and the partition's blocks and what the driver says.
Narrowed :: struct {
    client : slop_os.Channel,
    driver : slop_os.Channel,
    first : u64,
    count : u64,
    info : block.Info,
}

Server :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // Its own connection to the disk, which it reads the table through and makes the narrowed ones' with
    disk : slop_os.Channel,
    disk_port : slop_os.Port,
    buffer : u64,
    buffer_bytes : u64,
    block_count : u64,
    table : gpt.Table,
    clients : service_kit.Clients,
    narrowed : Narrowed[MAX_NARROWED],
    narrowed_count : usize,
}

main :: fn(log: slop_os.DebugLog?, disk: os.Channel[block.Block], clients: os.Listener[partitions.Partitions]) -> int {
    startup :: slop_os.startup_block()
    server := runtime.new(Server)
    server.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    server.disk = disk.end
    server.disk_port = os.port_for(startup.budget, disk.end) or_return 1
    server.port = slop_os.port_create(startup.budget) or_return 1

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

// count blocks from first into into, through the disk's buffer, BLOCK_BYTES at a time as the buffer has room.
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

// A client's requests, until it has none: its partitions described, and connections to them made.
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

/*
 * A connection to the blocks from first, count of them: a connection of its own to the driver, made through the
 * partition server's, and described; on client, the end a client gave, or, with NONE, a new channel, whose other end
 * is the client's, given back. Null if it can't be made.
 */
open :: fn(server: ptr[mut Server], first: u64, count: u64, client: slop_os.Channel) -> slop_os.Channel? {
    slot :: server.narrowed_count
    if slot >= server.narrowed.count {
        return null
    }
    startup :: slop_os.startup_block()
    driver :: block.connect(server.disk, server.disk_port, startup.budget) or_return null
    driver_port :: os.port_for(startup.budget, driver.end) or_return null
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
        pair :: os.channel_for[block.Block](startup.budget, 0) or_return null
        ours = pair.a
        theirs = pair.b
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    _ = slop_os.port_bind(server.port, cast[slop_os.Handle](ours), signals, CLIENT_KEY + cast[u64](slot), .Persistent)
    _ = slop_os.port_bind(server.port, cast[slop_os.Handle](driver.end), signals, DRIVER_KEY + cast[u64](slot), .Persistent)
    info.block_count = count
    server.narrowed[slot] = Narrowed.{client = ours, driver = driver.end, first = first, count = count, info = info}
    server.narrowed_count = slot + 1
    // Each read until it's empty, so its next message wakes the port
    into := os.Incoming.{}
    serve_narrowed(server, slot, &into)
    pass_back(server, slot, &into)
    return theirs
}

// A narrowed connection's requests, until it has none: checked and moved to the partition's blocks, or answered.
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

// What the driver answered a narrowed connection's requests, back to its client as it is.
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
        answer(narrowed.client, server.port, os.message_of[block.Response](into)^)
    }
}

// Whether a transfer's blocks are all the partition's.
inside :: fn(narrowed: ptr[Narrowed], transfer: block.Transfer) -> bool {
    return transfer.first < narrowed.count && cast[u64](transfer.count) <= narrowed.count - transfer.first
}

close_narrowed :: fn(narrowed: ptr[mut Narrowed]) {
    for end in slop_os.Channel.[narrowed.client, narrowed.driver] {
        if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
        }
    }
    narrowed.client = cast[slop_os.Channel](slop_os.NO_HANDLE)
    narrowed.driver = cast[slop_os.Channel](slop_os.NO_HANDLE)
}

answer :: fn(end: slop_os.Channel, port: slop_os.Port, response: block.Response) {
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = response
    _ = block.send_response(end, port, &out)
}

// One request on a block connection, and its answer, waited for; Unsupported if the connection's gone.
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
