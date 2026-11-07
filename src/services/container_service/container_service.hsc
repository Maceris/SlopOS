/**
 * A container service (roadmap 8d, decisions/0089): one per SlopOS container partition, started by the storage manager
 * with a block connection narrowed to the partition, and nothing else. It mounts the container (src/slopfs), owns its
 * space map, its owners and its checkpoints, and serves the container protocol: a connection for each volume, on which
 * the volume's server allocates and gives back extents, reads and writes only them through block connections it
 * narrows further, and commits. It never reads a volume's tree, so on an encrypted volume (8e) it holds no plaintext.
 *
 * Every extent in use is kept here with its owner, from the owners tree at mount and as volumes allocate and give
 * back, and every read and write a volume's block connection makes is checked against it. A commit takes the
 * committing volume's changes and the container's own, and leaves other volumes' waiting for theirs.
 *
 * Snapshots and clones (roadmap 8e, slopfs/snapshot.hsc): each extent is kept with when it was allocated, whether it
 * has been since its volume's last commit, and whether it's on its volume's dead list. A volume writes only what it
 * allocated since its last commit, so nothing a snapshot holds or a commit made durable is ever written again, and
 * reads only its own live extents and, for a clone, its origins' up to what their snapshots hold. A snapshot's
 * connection reads only what its snapshot holds.
 */
package container_service

import runtime from "base"
import random from "std"
import os from "std"
import slop_os from "std/os"
import slopfs from "../../slopfs"
import log_line from "../../log_line"
import block from "../../protocols/block"
import container from "../../protocols/container"

/** The most connections at once: listeners, volumes' and block connections; one past them is closed at once. */
MAX_CONNECTIONS :: 32
/** The key a block connection's driver is bound to the port with, plus its slot; its client is bound under its slot. */
DRIVER_KEY : u64 : 1000
/** No channel: a connection without a driver. */
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
/** 512-byte sectors in a 4 KiB block. */
SECTORS_PER_BLOCK : u64 : 8
/** The most blocks one Allocate asks for: a node's or a chunk's, with room. */
MAX_ALLOCATE : u64 : 256

/** What a connection is. */
Kind :: enum {
    /** A slot no connection has. */
    Free,
    /** The listener, or another connection not yet for a volume: it asks for volumes, snapshots and the like. */
    Unbound,
    /** A volume's connection, or a snapshot's, from OpenVolume. */
    Volume,
    /** A block connection narrowed to a volume's extents. */
    Blocks,
}

/**
 * A connection: a volume's, or a block connection for one, with who wrote a clone's older blocks, and for a snapshot's,
 * the transaction it holds, 0 for the live volume's.
 */
Connection :: struct {
    /** What it is; Free for a slot no connection has. */
    kind : Kind,
    /** The client's end, the service's own, bound to the port under the connection's index; closed by drop. */
    end : slop_os.Channel,
    /** A block connection's own connection to the driver, through the container's partition; NONE for any other. */
    driver : slop_os.Channel,
    /** The volume's ID, for a volume's connection or a block connection; 0 for an unbound one. */
    volume : u64,
    /** A block connection's description, its driver's, answered to Describe without asking the driver. */
    info : block.Info,
    /** Who wrote a clone's older blocks, and up to which transaction, which it may read. */
    lineage : slopfs.Lineage,
    /** The transaction a snapshot's connection holds, read only; 0 for the live volume's. */
    snapshot : u64,
}

/**
 * An extent a volume has: when it was allocated, whether since its volume's last commit, and whether a snapshot holds
 * it after the volume gave it back.
 */
Owned :: struct {
    /** Its first 4 KiB block in the container. */
    start : u64,
    /** How many 4 KiB blocks it is. */
    blocks : u64,
    /** The ID of the volume that has it. */
    owner : u64,
    /** The transaction it was allocated in. */
    birth : u64,
    /** Whether it was allocated since its volume's last commit, and so may be written. */
    fresh : bool,
    /** Whether the volume gave it back and a snapshot holds it, on its dead list, read only through the snapshot. */
    dead : bool,
}

/** The container service's state, made once in main, on the heap, and kept for as long as it runs. */
Server :: struct {
    /** The debug log it says what it's doing in; NO_HANDLE for none. */
    log : slop_os.DebugLog,
    /** The port every connection's client, and every block connection's driver, is bound to. */
    port : slop_os.Port,
    /** The block connection to the container's partition, which the container's own blocks are moved through. */
    disk : slop_os.Channel,
    /** A port bound to disk, waited on for its answers. */
    disk_port : slop_os.Port,
    /** Where disk's buffer is mapped, readable and writable, in the process's address space. */
    buffer : u64,
    /** The buffer's size in bytes. */
    buffer_bytes : u64,
    /** The partition's size in 512-byte sectors. */
    sector_count : u64,
    /** The container, mounted, on the heap. */
    container : ptr[mut slopfs.Container],
    /** Every extent a volume has, sorted by start; the container's own aren't here. */
    owned : Owned[..],
    /** The connections, by slot, count of them used or once used. */
    connections : Connection[MAX_CONNECTIONS],
    /** How many slots of connections have ever been used: one past the highest. */
    count : usize,
    /** Whether a connection was added while serving, so main serves again before it waits. */
    added : bool,
}

/**
 * Serve a SlopOS container partition: mount it, keep its space and its volumes' extents, and give volume servers
 * connections to their volumes and block connections narrowed to their extents.
 *
 * Started by the storage manager, one per container partition. Runs until it's stopped.
 *
 * @param log The debug log it says what it's doing in; without one, it says nothing.
 * @param partition A block connection narrowed to the container's partition, which it takes the buffer of.
 * @param clients The listener the storage manager's connections arrive on, for volumes, snapshots, quotas and new
 *     volumes.
 * @return 99 without the memory for its state, 1 if its ports couldn't be made, 2 if the partition didn't describe
 *     itself, 3 if it didn't give its buffer, 4 if the buffer couldn't be mapped, 5 if there's no container on it, 6
 *     if the container's owners couldn't be read, and 7 if clients couldn't be added. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, partition: os.Channel[block.Block], clients: os.Listener[container.Container]) -> int {
    startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    server_made, server_error :: runtime.new_aligned(Server, align_of(Server))
    if server_error != null {
        return 99
    }
    server :: server_made
    server^ = Server.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), disk = partition.end}
    server.disk_port = os.port_for(startup.budget, partition.end) or_return 1
    server.port = slop_os.port_create(startup.budget) or_return 1
    info := block.Info.{}
    match call(server.disk, server.disk_port, .Describe) {
        case Described(described) => info = described
        case _ => return 2
    }
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match call(server.disk, server.disk_port, .GetBuffer) {
        case Buffer(memory) => window = memory
        case _ => return 3
    }
    server.buffer_bytes = info.buffer_bytes
    server.sector_count = info.block_count
    server.buffer = runtime.reserve_addresses(cast[usize](info.buffer_bytes)) or_return 4
    slop_os.memory_map(window, startup.space, server.buffer, 0, info.buffer_bytes, read_write()) or_return 4
    device :: slopfs.Device.{context = cast[rawptr](server), block_count = info.block_count / SECTORS_PER_BLOCK, read = read_blocks,
        write = write_blocks, flush = flush}
    match slopfs.mount(device) {
        case Ok(mounted) => server.container = mounted
        case Error(error) => {
            log_line.write(server.log, "container_service: no container on a partition of % blocks: %", info.block_count, error)
            return 5
        }
    }
    if !load_owned(server) {
        log_line.write(server.log, "container_service: the container's owners can't be read")
        return 6
    }
    log_line.write(server.log, "container_service: serving a container of % blocks, % of them free, at transaction %",
        device.block_count, slopfs.free_blocks(server.container), slopfs.durable_transaction(server.container))
    if add(server, .Unbound, clients.end, NONE, 0) is_none {
        return 7
    }
    into := os.Incoming.{}
    loop {
        loop #at_least_once {
            server.added = false
            with {
                i : usize = 0
            }
            loop {
                serve(server, i, &into)
                i += 1
            }
            while i < server.count
        }
        while server.added
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(server.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Give the protection to map memory readable and writable.
 *
 * @return PROTECTION_READ and PROTECTION_WRITE.
 */
read_write :: fn() -> slop_os.Protection {
    return cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
}

// The container's own blocks, through its connection to the partition

/**
 * Send one request on a block connection, and wait for its answer.
 *
 * @param end The block connection, with no other request in flight, so the next answer is this one's.
 * @param port A port bound to end.
 * @param request The request, copied whole into the message; a Read or Write moves bytes through end's buffer, not the
 *     message.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
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
            case _ => return .Unsupported
        }
    }
}

/**
 * Tell whether a block request finished as it should.
 *
 * @param response A block request's answer, as call gives it; only read.
 * @return Whether it's Finished with Done.
 */
done :: fn(response: block.Response) -> bool {
    return match response {
        case Finished(completion) => completion.status == .Done
        case _ => false
    }
}

/**
 * Read the container's own blocks, for slopfs's Device.
 *
 * @param context The Server main gave the Device, cast back; its disk, port and mapped buffer are used, and nothing
 *     else changes.
 * @param first The first 4 KiB block in the partition.
 * @param count How many 4 KiB blocks.
 * @param into Where they go, at least count blocks long.
 * @return Whether they were read whole.
 */
read_blocks :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    return move(server, first * SECTORS_PER_BLOCK, count * SECTORS_PER_BLOCK, into, false)
}

/**
 * Write the container's own blocks, for slopfs's Device; durable only once flush is.
 *
 * @param context The Server main gave the Device, cast back; its disk, port and mapped buffer are used, and nothing
 *     else changes.
 * @param first The first 4 KiB block in the partition.
 * @param count How many 4 KiB blocks.
 * @param from What's written, at least count blocks long.
 * @return Whether every write finished.
 */
write_blocks :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    return move(server, first * SECTORS_PER_BLOCK, count * SECTORS_PER_BLOCK, view_of(cast[ptr[mut u8]](from.data), from.count), true)
}

/**
 * Flush the partition's writes to the disk, for slopfs's Device.
 *
 * @param context The Server main gave the Device, cast back; a Flush is sent on its disk and waited for.
 * @return Whether the flush finished, everything written before it durable.
 */
flush :: fn(context: rawptr) -> bool {
    server :: cast[ptr[mut Server]](context)
    return done(call(server.disk, server.disk_port, .Flush(1)))
}

/**
 * Move sectors through the partition's buffer, as much at a time as it holds: read into bytes, or written from them.
 *
 * @param server The container service's state: its disk connection is used, waiting on each transfer, and its mapped
 *     buffer, of buffer_bytes, is overwritten.
 * @param first The first 512-byte sector in the partition.
 * @param count How many 512-byte sectors, moved in pieces of as many as the buffer holds.
 * @param bytes Where they're read to, or written from; at least count sectors long.
 * @param writing Whether they're written, or read.
 * @return Whether all of them moved; false if bytes is too short, the buffer holds no sector, or a transfer failed,
 *     what was moved before it moved.
 */
move :: fn(server: ptr[mut Server], first: u64, count: u64, bytes: mut u8[], writing: bool) -> bool {
    per :: server.buffer_bytes / block.BLOCK_BYTES
    if per == 0 || count * block.BLOCK_BYTES > cast[u64](bytes.count) {
        return false
    }
    moved := cast[u64](0)
    loop {
        if moved >= count {
            return true
        }
        now :: if count - moved < per { count - moved } else { per }
        window :: view_of(cast[ptr[mut u8]](server.buffer), cast[usize](now * block.BLOCK_BYTES))
        base :: cast[usize](moved * block.BLOCK_BYTES)
        if writing {
            for &byte, i in window {
                at :: base + i
                if at < bytes.count {
                    byte^ = bytes[at]
                }
            }
        }
        transfer :: block.Transfer.{tag = 1, first = first + moved, count = cast[u32](now), offset = 0}
        if !done(call(server.disk, server.disk_port, if writing { block.Request.Write(transfer) } else { block.Request.Read(transfer) })) {
            return false
        }
        if !writing {
            for byte, i in window {
                at :: base + i
                if at < bytes.count {
                    bytes[at] = byte
                }
            }
        }
        moved += now
    }
}

// Who owns what

/**
 * Load every extent the owners tree says a volume has, then mark those on each volume's dead list.
 *
 * The container's own aren't kept here: they change at every commit, and no volume may reach them, so they're never
 * what a check finds.
 *
 * @param server The server, its container mounted and owned empty.
 * @return Whether they were all loaded; false if a tree couldn't be read or there wasn't the memory.
 */
load_owned :: fn(server: ptr[mut Server]) -> bool {
    value := slopfs.OwnerValue.{}
    at := slopfs.Key.{}
    loop {
        found := slopfs.Found.{}
        match slopfs.tree_next(&server.container.nodes, &server.container.owners, at,
            view_of(cast[ptr[mut u8]](&value), size_of(slopfs.OwnerValue))) {
            case Ok(next) => found = next or_break
            case Error(error) => return false
        }
        if cast[u64](value.volume) != 0 && runtime.array_try_add(&server.owned, Owned.{start = found.key.object, blocks = cast[u64](value.blocks),
            owner = cast[u64](value.volume), birth = cast[u64](value.birth)}) != null {
            return false
        }
        at = slopfs.key_after(found.key) or_break
    }
    // What's on each volume's dead list
    volume : u64 = 0
    loop {
        id :: match slopfs.next_volume_id(server.container, volume) {
            case Ok(next) => next or_break
            case Error(error) => return false
        }
        dead : slopfs.DeadExtent[..]
        listed :: slopfs.dead_extents(server.container, id, &dead)
        for each in dead {
            index :: owned_index(server, each.start)
            if index < server.owned.count && server.owned[index].start == each.start {
                server.owned[index].dead = true
            }
        }
        runtime.array_free(&dead)
        if listed is_error {
            return false
        }
        if id == 0xffffffffffffffff {
            break
        }
        volume = id + 1
    }
    return true
}

/**
 * Find where an extent starting at a block is, or would go, in the owned list.
 *
 * @param server The container service's state, whose owned list, sorted by start, is searched and not changed.
 * @param start A 4 KiB block in the container, compared with each extent's start.
 * @return The index of the first extent whose start isn't below start; owned's count if there's none.
 */
owned_index :: fn(server: ptr[Server], start: u64) -> usize {
    low : usize = 0
    high := server.owned.count
    loop {
        middle :: low + (high - low) / 2
        if middle < server.owned.count && server.owned[middle].start < start {
            low = middle + 1
        }
        else {
            high = middle
        }
    }
    while low < high
    return low
}

/**
 * Keep an extent as a volume's, in its place in the owned list.
 *
 * @param server The container service's state; the extent is inserted in its owned list, which may grow from the
 *     context's allocator.
 * @param start Its first 4 KiB block in the container.
 * @param blocks How many 4 KiB blocks it is.
 * @param owner The ID of the volume it's kept as, as the container's records number volumes (a connection's volume);
 *     not checked here.
 * @param birth The transaction it was allocated in.
 * @param fresh Whether it was allocated since the volume's last commit.
 * @return Whether it could be kept: false, and nothing changed, without the memory (decisions/0104).
 */
own :: fn(server: ptr[mut Server], start: u64, blocks: u64, owner: u64, birth: u64, fresh: bool) -> bool {
    index :: owned_index(server, start)
    if runtime.array_try_add(&server.owned, Owned.{}) != null {
        return false
    }
    with {
        i := server.owned.count - 1
    }
    loop {
        previous :: i - 1
        if i < server.owned.count && previous < server.owned.count {
            server.owned[i] = server.owned[previous]
        }
        i -= 1
    }
    while i > index
    if index < server.owned.count {
        server.owned[index] = Owned.{start = start, blocks = blocks, owner = owner, birth = birth, fresh = fresh}
    }
    return true
}

/**
 * Find the extent that holds blocks, whoever's it is.
 *
 * @param server The container service's state, whose owned list is searched and not changed.
 * @param first The first 4 KiB block in the container.
 * @param count How many 4 KiB blocks, from first.
 * @return A copy of the one extent that holds all of them; null if none does, as for blocks across two extents.
 */
holding :: fn(server: ptr[Server], first: u64, count: u64) -> Owned? {
    index :: owned_index(server, first + 1)
    if index == 0 || index - 1 >= server.owned.count {
        return null
    }
    extent :: server.owned[index - 1]
    if first < extent.start || first + count > extent.start + extent.blocks {
        return null
    }
    return extent
}

/**
 * Tell whether a volume has blocks, all in one live extent of its own.
 *
 * @param server The container service's state, whose owned list is searched and not changed.
 * @param owner The ID of the volume that must own the extent, as a connection's volume has it; an ID no extent has
 *     gives false.
 * @param first The first 4 KiB block in the container.
 * @param count How many 4 KiB blocks, from first.
 * @return Whether one extent of owner's holds them all, and it isn't dead.
 */
owns :: fn(server: ptr[Server], owner: u64, first: u64, count: u64) -> bool {
    extent :: holding(server, first, count) or_return false
    return extent.owner == owner && !extent.dead
}

/**
 * Tell whether a connection may read blocks.
 *
 * @param server The container service's state, whose owned list is searched and not changed.
 * @param connection The connection: a block connection for a volume or a snapshot.
 * @param first The first 4 KiB block in the container.
 * @param count How many blocks, all in one extent.
 * @return Whether they're its volume's own live extents, or for a snapshot's, what the volume had by the snapshot's
 *     transaction, dead or not; or, for a clone, its origins', up to what their snapshots hold.
 */
may_read :: fn(server: ptr[Server], connection: ptr[Connection], first: u64, count: u64) -> bool {
    extent :: holding(server, first, count) or_return false
    if extent.owner == connection.volume {
        return if connection.snapshot == 0 { !extent.dead } else { extent.birth <= connection.snapshot }
    }
    for i in 0..<connection.lineage.count {
        if i < slopfs.MAX_LINEAGE && extent.owner == connection.lineage.owners[i] && extent.birth <= connection.lineage.up_to[i] {
            return true
        }
    }
    return false
}

/**
 * Tell whether a connection may write blocks: only what its live volume allocated since its last commit, so nothing a
 * snapshot holds or a commit made durable is ever written again.
 *
 * @param server The container service's state, whose owned list is searched and not changed.
 * @param connection The connection: a block connection for a volume; a snapshot's writes nothing.
 * @param first The first 4 KiB block in the container.
 * @param count How many blocks, all in one extent.
 * @return Whether one fresh, live extent of its volume's holds them all.
 */
may_write :: fn(server: ptr[Server], connection: ptr[Connection], first: u64, count: u64) -> bool {
    extent :: holding(server, first, count) or_return false
    return connection.snapshot == 0 && extent.owner == connection.volume && extent.fresh && !extent.dead
}

/**
 * Mark every extent of a volume's allocated since its last commit as committed, so it isn't written again.
 *
 * @param server The container service's state; every extent of volume's in its owned list is no longer fresh.
 * @param volume The volume's ID, which has just committed.
 */
settle_fresh :: fn(server: ptr[mut Server], volume: u64) {
    for &extent in server.owned {
        if extent.owner == volume {
            extent.fresh = false
        }
    }
}

/**
 * Mark an extent a volume gave back dead, or live again, as a snapshot holds it or no longer does.
 *
 * @param server The container service's state, whose owned list has the extent changed in place.
 * @param start The extent's first block; an extent not in the owned list is ignored.
 * @param dead Whether it's dead.
 */
mark_dead :: fn(server: ptr[mut Server], start: u64, dead: bool) {
    index :: owned_index(server, start)
    if index < server.owned.count && server.owned[index].start == start {
        server.owned[index].dead = dead
    }
}

/**
 * Take an extent no one has any more off the owned list, whoever had it.
 *
 * @param server The container service's state, whose owned list loses the extent.
 * @param start The extent's first block; an extent not in the owned list is ignored.
 */
forget :: fn(server: ptr[mut Server], start: u64) {
    index :: owned_index(server, start)
    if index < server.owned.count && server.owned[index].start == start {
        runtime.array_remove(&server.owned, index)
    }
}

/**
 * Take an extent a volume gave back off the owned list.
 *
 * @param server The container service's state, whose owned list loses the extent if it matches.
 * @param owner The ID of the volume giving the extent back, which must be the extent's owner, or nothing's taken.
 * @param start The extent's first 4 KiB block in the container.
 * @param blocks Its length in blocks, which must be the extent's whole length.
 * @return Whether it was owner's, exactly that extent, and was taken off; false, and nothing changed, otherwise.
 */
disown :: fn(server: ptr[mut Server], owner: u64, start: u64, blocks: u64) -> bool {
    index :: owned_index(server, start)
    if index >= server.owned.count {
        return false
    }
    extent :: server.owned[index]
    if extent.start != start || extent.blocks != blocks || extent.owner != owner {
        return false
    }
    runtime.array_remove(&server.owned, index)
    return true
}

// Connections

/**
 * Add a connection, in the first free slot, binding its end, and its driver if it has one, to the port.
 *
 * @param server The server, whose added is set.
 * @param kind The connection's kind, kept in its slot: Unbound for the listener or a client not yet for a volume,
 *     Volume for a volume's or snapshot's, Blocks for a block connection; never Free.
 * @param end The client's end, which the server takes over: closed here if it can't be added.
 * @param driver A block connection's own connection to the driver, taken over too and closed if binding it fails;
 *     NONE for another kind. If there's no free slot, it isn't closed.
 * @param volume The volume's ID, or 0 for an unbound connection.
 * @return Its slot; null if there are MAX_CONNECTIONS already, or binding failed.
 */
add :: fn(server: ptr[mut Server], kind: Kind, end: slop_os.Channel, driver: slop_os.Channel, volume: u64) -> usize? {
    slot := server.count
    for connection, i in server.connections {
        if i < server.count && connection.kind == .Free {
            slot = i
            break
        }
    }
    if slot >= server.connections.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](end))
        return null
    }
    signals :: cast[slop_os.Signals](cast[u32](slop_os.SIGNAL_READABLE) | cast[u32](slop_os.SIGNAL_PEER_CLOSED))
    _ = slop_os.port_unbind(server.port, cast[u64](slot))
    _ = slop_os.port_unbind(server.port, DRIVER_KEY + cast[u64](slot))
    match slop_os.port_bind(server.port, cast[slop_os.Handle](end), signals, cast[u64](slot), .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
            return null
        }
    }
    if cast[slop_os.Handle](driver) != slop_os.NO_HANDLE
        && (slop_os.port_bind(server.port, cast[slop_os.Handle](driver), signals, DRIVER_KEY + cast[u64](slot), .Persistent) is_error) {
        // Its driver unwatched, its replies would never be read
        _ = slop_os.port_unbind(server.port, cast[u64](slot))
        _ = slop_os.handle_close(cast[slop_os.Handle](end))
        _ = slop_os.handle_close(cast[slop_os.Handle](driver))
        return null
    }
    server.connections[slot] = Connection.{kind = kind, end = end, driver = driver, volume = volume}
    server.added = true
    if slot >= server.count {
        server.count = slot + 1
    }
    return slot
}

/**
 * Drop a connection whose client has gone: unbind it, close its end and its driver's, and free its slot.
 *
 * @param server The container service's state: the slot's keys are unbound from its port, its handles closed, and the
 *     slot left Free for add to reuse; count isn't lowered.
 * @param index The connection's slot; one past them is ignored.
 */
drop :: fn(server: ptr[mut Server], index: usize) {
    if index >= server.connections.count {
        return void
    }
    connection :: &server.connections[index]
    _ = slop_os.port_unbind(server.port, cast[u64](index))
    _ = slop_os.port_unbind(server.port, DRIVER_KEY + cast[u64](index))
    for end in slop_os.Channel.[connection.end, connection.driver] {
        if cast[slop_os.Handle](end) != slop_os.NO_HANDLE {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
        }
    }
    connection^ = Connection.{}
}

/**
 * Serve a connection: a container connection's requests, or a block connection's, and what its driver answered.
 *
 * @param server The container service's state, whose connections are served and may be added to or dropped.
 * @param index The connection's slot; a free one, or one past them, is left alone.
 * @param into Where each message is read into, reused.
 */
serve :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    kind :: server.connections[index].kind
    if kind == .Unbound || kind == .Volume {
        serve_container(server, index, into)
    }
    else if kind == .Blocks {
        serve_blocks(server, index, into)
        pass_back(server, index, into)
    }
}

/**
 * Answer a container connection's requests, until it has none, or it's gone.
 *
 * Requests on the listener's connections, OpenVolume, snapshots, clones, quotas, usage and new volumes, are answered
 * on a connection that isn't a volume's: one names a volume, so on a volume's it's NotYours (decisions/0179), as a
 * volume server reaches only its own. The rest are a volume's, NotAVolume on another: its own snapshots taken, listed
 * and opened (TakeOwnSnapshot, OwnSnapshotAt, OpenOwnSnapshot), NotYours on a snapshot's. Connect adds a connection,
 * with no answer, and on a volume's is closed. A connection whose end fails is dropped.
 *
 * @param server The container service's state: answers go out on the slot's end, Connect adds a slot, setting added,
 *     and a failed end drops the slot.
 * @param index The connection's slot among server's connections; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_container :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match container.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = container.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        connection :: server.connections[index]
        volume :: connection.volume
        out := os.Outgoing.{}
        response :: os.begin[container.Response](&out)
        response^ = .Unsupported
        request :: os.message_of[container.Request](into)^
        // A volume's connection reaches its own volume, and only that: what names a volume, or Connect, isn't its
        if connection.kind == .Volume && is_listeners(request) {
            match request {
                case Connect(other) => {
                    _ = slop_os.handle_close(cast[slop_os.Handle](other.end))
                    continue
                }
                case _ => response^ = .NotYours
            }
            _ = container.send_response(end, server.port, &out)
            continue
        }
        match request {
            case OpenVolume(at) => {
                name :: os.items(into, at)
                response^ = open_volume(server, name)
            }
            case TakeSnapshot(named) => response^ = take_snapshot(server, os.items(into, named.volume), os.items(into, named.snapshot), named.now)
            case DeleteSnapshot(named) => response^ = delete_snapshot(server, os.items(into, named.volume), os.items(into, named.snapshot))
            case SnapshotAt(at) => response^ = snapshot_at(server, os.items(into, at.volume), at.index, &out)
            case Clone(cloning) => response^ = clone(server, os.items(into, cloning.volume), os.items(into, cloning.snapshot),
                os.items(into, cloning.name), cloning.now)
            case SetQuota(quota) => {
                match volume_named(server, os.items(into, quota.volume)) {
                    case Some(id) => {
                        match slopfs.set_quota(server.container, id, quota.blocks) {
                            case Ok => response^ = commit_own(server)
                            case Error(error) => response^ = .Failed
                        }
                    }
                    case None => response^ = .NoVolume
                }
            }
            case Usage(named) => {
                match volume_named(server, os.items(into, named)) {
                    case Some(id) => response^ = .Used(slopfs.usage_of(server.container, id))
                    case None => response^ = .NoVolume
                }
            }
            case CreateVolume(creation) => response^ = create_volume(server, os.items(into, creation.name), creation.cipher, creation.now)
            case Connect(other) => {
                _ = add(server, .Unbound, other.end, NONE, 0)
                continue
            }
            // A volume's own snapshots (decisions/0179), from its live connection only
            case TakeOwnSnapshot(own) => {
                response^ = if connection.kind != .Volume { container.Response.NotAVolume } else if connection.snapshot != 0 {
                    container.Response.NotYours } else { snapshot_taken(server, volume, os.items(into, own.snapshot), own.now) }
            }
            case OwnSnapshotAt(index) => {
                response^ = if connection.kind != .Volume { container.Response.NotAVolume } else if connection.snapshot != 0 {
                    container.Response.NotYours } else { snapshot_found(server, volume, index, &out) }
            }
            case OpenOwnSnapshot(named) => {
                response^ = if connection.kind != .Volume { container.Response.NotAVolume } else if connection.snapshot != 0 {
                    container.Response.NotYours } else { volume_opened(server, volume, os.items(into, named), true) }
            }
            case _ => {
                if connection.kind != .Volume {
                    response^ = .NotAVolume
                }
                else {
                    response^ = for_volume(server, index, request)
                }
            }
        }
        _ = container.send_response(end, server.port, &out)
    }
}

/**
 * Find where '@' is in a name, which splits a volume's from its snapshot's.
 *
 * @param name The name, as OpenVolume's request gives it; only read.
 * @return The index of the first '@'; name's count if there's none.
 */
at_of :: fn(name: u8[]) -> usize {
    for byte, i in name {
        if byte == cast[u8]('@') {
            return i
        }
    }
    return name.count
}

/**
 * Tell whether a request is one of the listener's: one that names a volume, or Connect, which a volume's own connection
 * may not ask (decisions/0179).
 *
 * @param request The request, only read.
 * @return True for OpenVolume, TakeSnapshot, DeleteSnapshot, SnapshotAt, Clone, SetQuota, Usage, CreateVolume and
 *     Connect; false for a volume's own requests.
 */
is_listeners :: fn(request: container.Request) -> bool {
    return match request {
        case OpenVolume(_) => true
        case TakeSnapshot(_) => true
        case DeleteSnapshot(_) => true
        case SnapshotAt(_) => true
        case Clone(_) => true
        case SetQuota(_) => true
        case Usage(_) => true
        case CreateVolume(_) => true
        case Connect(_) => true
        case _ => false
    }
}

/**
 * Find a volume by its name.
 *
 * @param server The container service's state, whose mounted container is searched and not changed.
 * @param name The volume's name, as a request gave it; only read.
 * @return Its ID; null if there's no such volume, or the container couldn't be read.
 */
volume_named :: fn(server: ptr[mut Server], name: u8[]) -> u64? {
    match slopfs.find_volume_named(server.container, name) {
        case Ok(found) => return found
        case Error(error) => return null
    }
}

/**
 * Make a connection for a volume, or for a snapshot of one, read only. Each knows who wrote a clone's older blocks,
 * for its reads.
 *
 * @param server The container service's state: a Volume slot is added, with the volume's lineage and the snapshot's
 *     transaction, or 0.
 * @param name The volume's name, or "volume@snapshot" for its snapshot's.
 * @return OpenedVolume with the connection's other end, which the caller owns; NoVolume for no such volume, NoSnapshot
 *     for no such snapshot, NoSpace if a channel or a slot couldn't be had, or Failed if the container couldn't be
 *     read.
 */
open_volume :: fn(server: ptr[mut Server], name: u8[]) -> container.Response {
    split :: at_of(name)
    if split > name.count {
        return .NoVolume
    }
    id :: volume_named(server, name[0..<split]) or_return .NoVolume
    after :: split + 1
    if split < name.count && after <= name.count {
        return volume_opened(server, id, name[after..<name.count], true)
    }
    return volume_opened(server, id, u8.[], false)
}

/**
 * Make a connection for a volume by its ID, or for a snapshot of it, read only: OpenVolume's, and a volume's
 * OpenOwnSnapshot. Each knows who wrote a clone's older blocks, for its reads.
 *
 * @param server The container service's state: a Volume slot is added, with the volume's lineage and the snapshot's
 *     transaction, or 0.
 * @param id The volume's ID.
 * @param name The snapshot's name, if one's asked for.
 * @param of_snapshot Whether a snapshot's asked for, by name, rather than the volume.
 * @return OpenedVolume with the connection's other end, which the caller owns; NoVolume for no such volume, NoSnapshot
 *     for no such snapshot, NoSpace if a channel or a slot couldn't be had, or Failed if the container couldn't be
 *     read.
 */
volume_opened :: fn(server: ptr[mut Server], id: u64, name: u8[], of_snapshot: bool) -> container.Response {
    record := slopfs.volume_record(server.container, id) or_return .NoVolume
    lineage :: slopfs.lineage_of(server.container, &record) or_return .Failed
    snapshot : u64 = 0
    if of_snapshot {
        found :: match slopfs.find_snapshot(server.container, id, name) {
            case Ok(maybe) => maybe or_return .NoSnapshot
            case Error(error) => return .Failed
        }
        snapshot = cast[u64](found.record.transaction)
    }
    startup :: slop_os.startup_block()
    pair :: os.channel_for[container.Container](startup.budget, 0) or_return .NoSpace
    slot :: add(server, .Volume, pair.a, NONE, id) or_else server.connections.count
    if slot >= server.connections.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return .NoSpace
    }
    server.connections[slot].lineage = lineage
    server.connections[slot].snapshot = snapshot
    return .OpenedVolume(os.Channel[container.Container].{end = pair.b})
}

/**
 * Take a snapshot of a volume, of what its last commit left, durable at once with a commit of the container's own.
 *
 * @param server The container service's state, whose container takes the snapshot and commits it.
 * @param volume The volume's name, as the request gave it.
 * @param name The snapshot's name, as the request gave it; one the volume has already is AlreadyExists.
 * @param now When it's taken, as the taker says.
 * @return Done once it's durable; NoVolume, AlreadyExists for a name taken, or Failed if it couldn't be taken or
 *     committed.
 */
take_snapshot :: fn(server: ptr[mut Server], volume: u8[], name: u8[], now: u64) -> container.Response {
    id :: volume_named(server, volume) or_return .NoVolume
    return snapshot_taken(server, id, name, now)
}

/**
 * Take a snapshot of a volume by its ID, of what its last commit left, durable at once with a commit of the container's
 * own: TakeSnapshot's, and a volume's TakeOwnSnapshot.
 *
 * @param server The container service's state, whose container takes the snapshot and commits it.
 * @param id The volume's ID.
 * @param name The snapshot's name, as the request gave it; one the volume has already is AlreadyExists.
 * @param now When it's taken, as the taker says.
 * @return Done once it's durable; AlreadyExists for a name taken, or Failed if it couldn't be taken or committed.
 */
snapshot_taken :: fn(server: ptr[mut Server], id: u64, name: u8[], now: u64) -> container.Response {
    match slopfs.take_snapshot(server.container, id, name, now) {
        case Ok(number) => {}
        case Error(error) => return if error == .AlreadyExists { .AlreadyExists } else { .Failed }
    }
    return commit_own(server)
}

/**
 * Delete a volume's snapshot, and free what only it held, durable at once with a commit of the container's own.
 *
 * @param server The container service's state: the container deletes the snapshot and commits, and the extents freed
 *     leave the owned list.
 * @param volume The volume's name, as the request gave it.
 * @param name The snapshot's name, as the request gave it.
 * @return Done once it's durable; NoVolume, NoSnapshot, InUse for a snapshot a clone keeps, or Failed if it couldn't
 *     be deleted or committed.
 */
delete_snapshot :: fn(server: ptr[mut Server], volume: u8[], name: u8[]) -> container.Response {
    id :: volume_named(server, volume) or_return .NoVolume
    freed : slopfs.Extent[..]
    defer runtime.array_free(&freed)
    match slopfs.delete_snapshot(server.container, id, name, &freed) {
        case Ok => {}
        case Error(error) => {
            return if error == .InUse { .InUse } else if error == .NotFound { .NoSnapshot } else { .Failed }
        }
    }
    for extent in freed {
        forget(server, extent.start)
    }
    return commit_own(server)
}

/**
 * Find a volume's snapshot by its place among them, oldest first.
 *
 * @param server The container service's state, whose container's snapshot records are read and not changed.
 * @param volume The volume's name, as the request gave it.
 * @param index Its place, from 0.
 * @param out The answer being built, which the snapshot's name is appended to.
 * @return Snapshot with its name, transaction and when it was taken; NoMore past the last, NoVolume, or Failed if
 *     they couldn't be read.
 */
snapshot_at :: fn(server: ptr[mut Server], volume: u8[], index: u64, out: ptr[mut os.Outgoing]) -> container.Response {
    id :: volume_named(server, volume) or_return .NoVolume
    return snapshot_found(server, id, index, out)
}

/**
 * Find a volume's snapshot by the volume's ID and the snapshot's place among them, oldest first: SnapshotAt's, and a
 * volume's OwnSnapshotAt.
 *
 * @param server The container service's state, whose container's snapshot records are read and not changed.
 * @param id The volume's ID.
 * @param index Its place, from 0.
 * @param out The answer being built, which the snapshot's name is appended to.
 * @return Snapshot with its name, transaction and when it was taken; NoMore past the last, or Failed if they couldn't
 *     be read.
 */
snapshot_found :: fn(server: ptr[mut Server], id: u64, index: u64, out: ptr[mut os.Outgoing]) -> container.Response {
    snapshots : slopfs.NumberedSnapshot[..]
    defer runtime.array_free(&snapshots)
    if slopfs.snapshot_records(server.container, id, &snapshots) is_error {
        return .Failed
    }
    if index >= cast[u64](snapshots.count) {
        return .NoMore
    }
    found := snapshots[cast[usize](index)].record
    return .Snapshot(container.SnapshotInfo.{name = os.append(out, slopfs.name_of_snapshot(&found)), transaction = cast[u64](found.transaction),
        created = cast[u64](found.created)})
}

/**
 * Make a new volume cloned from a volume's snapshot, durable at once with a commit of the container's own.
 *
 * @param server The container service's state, whose container makes the clone and commits it.
 * @param volume The volume's name, as the request gave it.
 * @param snapshot The name of the volume's snapshot cloned, as the request gave it.
 * @param name The new volume's name, as the request gave it; one a volume has already is AlreadyExists.
 * @param now When it's made, as the asker says.
 * @return Done once it's durable; NoVolume, NoSnapshot, AlreadyExists for a name taken, or Failed.
 */
clone :: fn(server: ptr[mut Server], volume: u8[], snapshot: u8[], name: u8[], now: u64) -> container.Response {
    id :: volume_named(server, volume) or_return .NoVolume
    match slopfs.clone_snapshot(server.container, id, snapshot, name, now) {
        case Ok(made) => {}
        case Error(error) => {
            return if error == .AlreadyExists { .AlreadyExists } else if error == .NotFound { .NoSnapshot } else { .Failed }
        }
    }
    return commit_own(server)
}

/**
 * Make a new volume, registered with nothing in it, and make it durable (decisions/0141): its name hash key drawn
 * here, and everything that opens it left to the volume server that first serves it.
 *
 * @param server The container service's state, whose container registers the volume and commits it; it's logged once
 *     made.
 * @param name The new volume's name, as the request gave it; one a volume has already is AlreadyExists.
 * @param cipher slopfs.Cipher's value: None, ChaCha20Poly1305 or Aes256Gcm; another is refused.
 * @param now When it's made, as the asker says.
 * @return Created with its ID once it's durable; AlreadyExists for a name taken, or Failed.
 */
create_volume :: fn(server: ptr[mut Server], name: u8[], cipher: u8, now: u64) -> container.Response {
    if cipher != cast[u8](slopfs.Cipher.None) && cipher != cast[u8](slopfs.Cipher.ChaCha20Poly1305) && cipher != cast[u8](slopfs.Cipher.Aes256Gcm) {
        return .Failed
    }
    hash_key : u8[32]
    random.fill(hash_key)
    id :: match slopfs.register_volume(server.container, name, hash_key, now, cast[slopfs.Cipher](cipher)) {
        case Ok(made) => made
        case Error(error) => return if error == .AlreadyExists { .AlreadyExists } else { .Failed }
    }
    match commit_own(server) {
        case Done => {}
        case _ => return .Failed
    }
    if name.count > 0 {
        log_line.write(server.log, "container_service: made volume % (%)", id, string_of(&name[0], name.count))
    }
    return .Created(id)
}

/**
 * Commit the container's own changes: a snapshot, a deletion, a clone, a quota or a new volume; other volumes'
 * changes wait for their own commits.
 *
 * @param server The container service's state, whose container commits what it has pending, waiting until it's durable
 *     or failed.
 * @return Done once they're durable; Failed, logged, if the commit failed.
 */
commit_own :: fn(server: ptr[mut Server]) -> container.Response {
    match slopfs.commit_own(server.container) {
        case Ok => return .Done
        case Error(error) => {
            log_line.write(server.log, "container_service: a commit of its own failed: %", error)
            return .Failed
        }
    }
}

/**
 * Answer a request on a volume's connection, or a snapshot's: Describe, Allocate, Release, OpenBlocks, Abandon, the
 * keys' requests, and Commit.
 *
 * A snapshot's connection is read only: Describe, OpenBlocks, WrapAt and GenerationAt alone, NotYours for the rest.
 * Allocate keeps the extent as the volume's, fresh; Release gives one back, kept on the volume's dead list if a
 * snapshot holds it; Abandon undoes every change since the volume's last commit; Commit makes the volume's record
 * durable, its root checked to be in its own live extents.
 *
 * @param server The container service's state, whose container and owned list the request reads or changes, as it asks.
 * @param index The volume connection's slot among server's connections; one past them is answered NotAVolume.
 * @param request The request read from the slot's connection, a copy holding only values; one serve_container answers
 *     itself, as OpenVolume, gets Unsupported here.
 * @return The answer: NotYours for what the volume may not do, NoSpace for an allocation that can't be had or kept,
 *     NoMore past a volume's wraps or generations, Failed for what the container couldn't do, and the request's own
 *     answer otherwise.
 */
for_volume :: fn(server: ptr[mut Server], index: usize, request: container.Request) -> container.Response {
    if index >= server.connections.count {
        return .NotAVolume
    }
    connection := server.connections[index]
    volume :: connection.volume
    // A snapshot's is read only: what it holds is described, read and unlocked, and nothing else
    if connection.snapshot != 0 {
        match request {
            case Describe => {}
            case OpenBlocks => {}
            case WrapAt(_) => {}
            case GenerationAt(_) => {}
            case _ => return .NotYours
        }
    }
    match request {
        case Describe => {
            record := slopfs.volume_record(server.container, volume) or_return .NoVolume
            if connection.snapshot != 0 {
                // The snapshot's root and next object, as it holds them
                snapshots : slopfs.NumberedSnapshot[..]
                defer runtime.array_free(&snapshots)
                _ = slopfs.snapshot_records(server.container, volume, &snapshots)
                for each in snapshots {
                    if cast[u64](each.record.transaction) == connection.snapshot {
                        held := each.record
                        record = slopfs.snapshot_volume_record(&record, &held)
                    }
                }
            }
            return .Described(container.Described.{id = volume, record = record, transaction = server.container.nodes.transaction,
                container = server.container.id, lineage = connection.lineage, read_only = connection.snapshot != 0})
        }
        case Allocate(allocation) => {
            blocks :: allocation.blocks
            if blocks == 0 || blocks > MAX_ALLOCATE {
                return .NoSpace
            }
            start :: slopfs.space_allocate(cast[rawptr](&server.container.space), blocks, volume, allocation.data) or_return .NoSpace
            // Kept as the volume's, or not allocated at all
            if !own(server, start, blocks, volume, server.container.space.transaction, true) {
                slopfs.space_release(cast[rawptr](&server.container.space), start, blocks, volume, server.container.space.transaction)
                return .NoSpace
            }
            return .Allocated(start)
        }
        case Release(released) => {
            floor :: slopfs.floor_of(&server.container.space, volume)
            // A clone's block from its origin is the origin's, which the origin's snapshot holds
            if released.birth <= floor.origin {
                return .Done
            }
            extent :: holding(server, released.first, released.blocks) or_return .NotYours
            if extent.owner != volume || extent.dead || extent.start != released.first || extent.blocks != released.blocks {
                return .NotYours
            }
            // One a snapshot holds stays the volume's, on its dead list, for the snapshot to read
            if !extent.fresh && released.birth <= floor.snapshot {
                mark_dead(server, released.first, true)
            }
            else {
                _ = disown(server, volume, released.first, released.blocks)
            }
            slopfs.space_release(cast[rawptr](&server.container.space), released.first, released.blocks, volume, released.birth)
            return .Done
        }
        case OpenBlocks => return open_blocks(server, index)
        case Abandon => {
            undone : slopfs.Change[..]
            defer runtime.array_free(&undone)
            // Room to own again every extent it gave back, before anything's undone
            if runtime.array_try_reserve(&server.owned, server.owned.count + server.container.space.changes.count) != null
                || !slopfs.abandon_volume(server.container, volume, &undone) {
                return .Failed
            }
            // Its allocations aren't its own any more, and what it gave back is again
            for change in undone {
                if change.change == .Allocated {
                    _ = disown(server, volume, change.start, change.blocks)
                }
                else if change.change == .FreedLater {
                    _ = own(server, change.start, change.blocks, volume, change.birth, false)
                }
                else if change.change == .Dead {
                    mark_dead(server, change.start, false)
                }
            }
            return .Done
        }
        case WrapAt(index) => {
            match slopfs.volume_wrap(server.container, volume, index) {
                case Ok(found) => {
                    wrap :: found or_return .NoMore
                    return .Wrap(wrap)
                }
                case Error(error) => return .Failed
            }
        }
        case GenerationAt(number) => {
            match slopfs.volume_generation(server.container, volume, number) {
                case Ok(found) => {
                    generation :: found or_return .NoMore
                    return .Generation(generation)
                }
                case Error(error) => return .Failed
            }
        }
        case AddWrap(added) => {
            // Only a volume no volume server has filled yet takes a wrap this way; another's come with rotating keys
            current :: slopfs.volume_record(server.container, volume) or_return .Failed
            if !slopfs.is_unfilled(&current) {
                return .NotYours
            }
            record := added.record
            match slopfs.put_wrap(server.container, volume, added.index, &record) {
                case Ok => return .Done
                case Error(error) => return .Failed
            }
        }
        case AddGeneration(added) => {
            record := added.record
            match slopfs.add_generation(server.container, volume, added.number, &record) {
                case Ok => return .Done
                case Error(error) => {
                    log_line.write(server.log, "container_service: volume %'s generation % refused: %", volume, added.number, error)
                    return if error == .NotFound { .NotYours } else { .Failed }
                }
            }
        }
        case Commit(record) => {
            // Its root in its own extents, and nothing but its root and next object taken from it
            root :: cast[u64](record.root.address)
            if root != 0 && !owns(server, volume, root, slopfs.NODE_BLOCKS) {
                return .NotYours
            }
            committed := slopfs.volume_record(server.container, volume) or_return .NoVolume
            committed.root = record.root
            committed.next_object = record.next_object
            match slopfs.commit_volume(server.container, volume, &committed) {
                case Ok(transaction) => {
                    settle_fresh(server, volume)
                    return .Committed(server.container.nodes.transaction)
                }
                case Error(error) => {
                    log_line.write(server.log, "container_service: volume %'s commit failed: %", volume, error)
                    return .Failed
                }
            }
        }
        case _ => return .Unsupported
    }
}

// Block connections narrowed to a volume's extents

/**
 * Make a block connection for a volume's connection, reading and writing only what it may.
 *
 * It has a connection of its own to the driver, through the container's partition: its reads and writes are checked
 * against the volume's extents, and the driver's buffer is its own, so data moves with no copies here.
 *
 * @param server The container service's state: a new driver connection through its disk is made, and a Blocks slot
 *     added with it, copying the volume connection's volume, lineage and snapshot.
 * @param index The volume connection's slot among server's connections, whose volume, lineage and snapshot the new one
 *     gets.
 * @return Blocks with the connection's other end, which the caller owns; NotAVolume for a slot past them, or NoSpace
 *     if the driver, a channel or a slot couldn't be had.
 */
open_blocks :: fn(server: ptr[mut Server], index: usize) -> container.Response {
    if index >= server.connections.count {
        return .NotAVolume
    }
    volume_connection :: server.connections[index]
    volume :: volume_connection.volume
    startup :: slop_os.startup_block()
    driver :: block.connect(server.disk, server.disk_port, startup.budget) or_return .NoSpace
    driver_port :: os.port_for(startup.budget, driver.end) or_return .NoSpace
    info := block.Info.{}
    match call(driver.end, driver_port, .Describe) {
        case Described(described) => info = described
        case _ => {
            _ = slop_os.handle_close(cast[slop_os.Handle](driver.end))
            return .NoSpace
        }
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](driver_port))
    pair :: os.channel_for[block.Block](startup.budget, 0) or_return .NoSpace
    match add(server, .Blocks, pair.a, driver.end, volume) {
        case Some(slot) => {
            if slot < server.connections.count {
                server.connections[slot].info = info
                server.connections[slot].lineage = volume_connection.lineage
                server.connections[slot].snapshot = volume_connection.snapshot
            }
        }
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return .NoSpace
        }
    }
    return .Blocks(os.Channel[block.Block].{end = pair.b})
}

/**
 * Pass a block connection's requests to its driver, until it has none, or it's gone.
 *
 * Reads and writes outside what the connection may read or write are answered OutOfRange, Describe with its
 * description, and Connect by closing the connection given; everything else goes to the driver, which answers it.
 *
 * @param server The container service's state: what may go to the driver goes on the slot's driver connection, the rest
 *     is answered here, and a failed end drops the slot.
 * @param index The block connection's slot among server's connections; one past them, or no longer Blocks, is left
 *     alone.
 * @param into Where each request is read into, reused.
 */
serve_blocks :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    loop {
        connection :: server.connections[index]
        if connection.kind != .Blocks {
            return void
        }
        match block.receive_request(connection.end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = block.answer_unsupported(connection.end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        request :: os.message_of[block.Request](into)^
        match request {
            case Read(transfer) => {
                if !in_volume(server, &connection, transfer, false) {
                    answer(connection.end, server.port, .Finished(block.Completion.{tag = transfer.tag, status = .OutOfRange}))
                    continue
                }
            }
            case Write(transfer) => {
                if !in_volume(server, &connection, transfer, true) {
                    answer(connection.end, server.port, .Finished(block.Completion.{tag = transfer.tag, status = .OutOfRange}))
                    continue
                }
            }
            case Describe => {
                answer(connection.end, server.port, .Described(connection.info))
                continue
            }
            case Connect(other) => {
                // Another block connection for the same volume goes through the volume's own connection instead
                _ = slop_os.handle_close(cast[slop_os.Handle](other.end))
                continue
            }
            case _ => {}
        }
        out := os.Outgoing.{}
        made :: os.begin[block.Request](&out)
        made^ = request
        _ = block.send_request(connection.driver, server.port, &out)
    }
}

/**
 * Tell whether a transfer's sectors are all in one extent the connection may read, or write.
 *
 * @param server The container service's state, whose owned list is searched and not changed.
 * @param connection The block connection's slot, its volume, lineage and snapshot deciding what it may reach; only
 *     read.
 * @param transfer The transfer, in 512-byte sectors, which must be whole 4 KiB blocks and at least one.
 * @param writing Whether it writes.
 * @return Whether it may.
 */
in_volume :: fn(server: ptr[Server], connection: ptr[Connection], transfer: block.Transfer, writing: bool) -> bool {
    if transfer.first % SECTORS_PER_BLOCK != 0 || cast[u64](transfer.count) % SECTORS_PER_BLOCK != 0 || transfer.count == 0 {
        return false
    }
    first :: transfer.first / SECTORS_PER_BLOCK
    count :: cast[u64](transfer.count) / SECTORS_PER_BLOCK
    return if writing { may_write(server, connection, first, count) } else { may_read(server, connection, first, count) }
}

/**
 * Pass what the driver answered a block connection's requests back to its client, until there's nothing more.
 *
 * @param server The container service's state; answers go out on the slot's end, waiting on its port while the ring is
 *     full.
 * @param index The block connection's slot; it's dropped if its driver's connection fails.
 * @param into Where each answer is read into, reused.
 */
pass_back :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    loop {
        connection :: server.connections[index]
        if connection.kind != .Blocks {
            return void
        }
        match block.receive_response(connection.driver, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case _ => {
                drop(server, index)
                return void
            }
        }
        answer(connection.end, server.port, os.message_of[block.Response](into)^)
    }
}

/**
 * Send an answer on a block connection.
 *
 * @param end A block connection's client end, the server's own, kept open.
 * @param port The server's port, waited on while the ring is full.
 * @param response The answer, copied whole into the message; a failure to send it is ignored.
 */
answer :: fn(end: slop_os.Channel, port: slop_os.Port, response: block.Response) {
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = response
    _ = block.send_response(end, port, &out)
}
