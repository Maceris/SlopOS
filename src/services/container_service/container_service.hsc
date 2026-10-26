/*
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
import os from "std"
import slop_os from "std/os"
import slopfs from "../../slopfs"
import log_line from "../../log_line"
import block from "../../protocols/block"
import container from "../../protocols/container"

MAX_CONNECTIONS :: 32
// A connection's client is bound to the port under its index, and a block connection's driver from DRIVER_KEY
DRIVER_KEY : u64 : 1000
NONE : slop_os.Channel : cast[slop_os.Channel](slop_os.NO_HANDLE)
// 512-byte sectors in a 4 KiB block
SECTORS_PER_BLOCK : u64 : 8
// The most blocks one Allocate asks for: a node's or a chunk's, with room
MAX_ALLOCATE : u64 : 256

Kind :: enum {
    Free,
    // The listener, or another connection not yet for a volume
    Unbound,
    Volume,
    // A block connection narrowed to a volume's extents
    Blocks,
}

/*
 * A connection: a volume's, or a block connection for one, with who wrote a clone's older blocks, and for a snapshot's,
 * the transaction it holds, 0 for the live volume's.
 */
Connection :: struct {
    kind : Kind,
    end : slop_os.Channel,
    // A block connection's own connection to the driver, through the container's partition
    driver : slop_os.Channel,
    volume : u64,
    info : block.Info,
    lineage : slopfs.Lineage,
    snapshot : u64,
}

/*
 * An extent a volume has: when it was allocated, whether since its volume's last commit, and whether a snapshot holds
 * it after the volume gave it back.
 */
Owned :: struct {
    start : u64,
    blocks : u64,
    owner : u64,
    birth : u64,
    fresh : bool,
    dead : bool,
}

Server :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    disk : slop_os.Channel,
    disk_port : slop_os.Port,
    buffer : u64,
    buffer_bytes : u64,
    sector_count : u64,
    container : ptr[mut slopfs.Container],
    // Sorted by start
    owned : Owned[..],
    connections : Connection[MAX_CONNECTIONS],
    count : usize,
    added : bool,
}

main :: fn(log: slop_os.DebugLog?, partition: os.Channel[block.Block], clients: os.Listener[container.Container]) -> int {
    startup :: slop_os.startup_block()
    server := runtime.new(Server)
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

read_write :: fn() -> slop_os.Protection {
    return cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
}

// The container's own blocks, through its connection to the partition

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

done :: fn(response: block.Response) -> bool {
    return match response {
        case Finished(completion) => completion.status == .Done
        case _ => false
    }
}

read_blocks :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    return move(server, first * SECTORS_PER_BLOCK, count * SECTORS_PER_BLOCK, into, false)
}

write_blocks :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    return move(server, first * SECTORS_PER_BLOCK, count * SECTORS_PER_BLOCK, view_of(cast[ptr[mut u8]](from.data), from.count), true)
}

flush :: fn(context: rawptr) -> bool {
    server :: cast[ptr[mut Server]](context)
    return done(call(server.disk, server.disk_port, .Flush(1)))
}

// Sectors from first moved through the buffer, as much at a time as it holds: into bytes, or from them.
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

/*
 * Every extent the owners tree says a volume has. The container's own aren't kept here: they change at every commit,
 * and no volume may reach them, so they're never what a check finds.
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
        if cast[u64](value.volume) != 0 {
            runtime.array_add(&server.owned, Owned.{start = found.key.object, blocks = cast[u64](value.blocks), owner = cast[u64](value.volume),
                birth = cast[u64](value.birth)})
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
        match listed {
            case Ok => {}
            case Error(error) => return false
        }
        if id == 0xffffffffffffffff {
            break
        }
        volume = id + 1
    }
    return true
}

// Where an extent starting at start is, or would go, in the owned list.
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

own :: fn(server: ptr[mut Server], start: u64, blocks: u64, owner: u64, birth: u64, fresh: bool) {
    index :: owned_index(server, start)
    runtime.array_add(&server.owned, Owned.{})
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
}

// The extent holding blocks from first, count of them, whoever's it is, if one does.
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

// Whether owner has blocks from first, count of them, all in one live extent of its own.
owns :: fn(server: ptr[Server], owner: u64, first: u64, count: u64) -> bool {
    extent :: holding(server, first, count) or_return false
    return extent.owner == owner && !extent.dead
}

/*
 * Whether a connection may read blocks from first, count of them: its volume's own live extents, or for a snapshot's,
 * what the volume had by the snapshot's transaction, dead or not; and for a clone, its origins' up to what their
 * snapshots hold.
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

// Whether a connection may write blocks from first, count of them: only what its live volume allocated since its last commit.
may_write :: fn(server: ptr[Server], connection: ptr[Connection], first: u64, count: u64) -> bool {
    extent :: holding(server, first, count) or_return false
    return connection.snapshot == 0 && extent.owner == connection.volume && extent.fresh && !extent.dead
}

// Every extent of a volume's allocated since its last commit, committed now.
settle_fresh :: fn(server: ptr[mut Server], volume: u64) {
    for &extent in server.owned {
        if extent.owner == volume {
            extent.fresh = false
        }
    }
}

// An extent a volume gave back marked dead, or live again, as a snapshot holds it or no longer does.
mark_dead :: fn(server: ptr[mut Server], start: u64, dead: bool) {
    index :: owned_index(server, start)
    if index < server.owned.count && server.owned[index].start == start {
        server.owned[index].dead = dead
    }
}

// An extent no one has any more, whoever had it.
forget :: fn(server: ptr[mut Server], start: u64) {
    index :: owned_index(server, start)
    if index < server.owned.count && server.owned[index].start == start {
        runtime.array_remove(&server.owned, index)
    }
}

// An extent owner had exactly, given back: whether it was owner's.
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
    if cast[slop_os.Handle](driver) != slop_os.NO_HANDLE {
        _ = slop_os.port_bind(server.port, cast[slop_os.Handle](driver), signals, DRIVER_KEY + cast[u64](slot), .Persistent)
    }
    server.connections[slot] = Connection.{kind = kind, end = end, driver = driver, volume = volume}
    server.added = true
    if slot >= server.count {
        server.count = slot + 1
    }
    return slot
}

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

// A container connection's requests, until it has none.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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
            case Connect(other) => {
                _ = add(server, .Unbound, other.end, NONE, 0)
                continue
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

// Where '@' is in a name, which splits a volume's from its snapshot's, or its count if it isn't there.
at_of :: fn(name: u8[]) -> usize {
    for byte, i in name {
        if byte == cast[u8]('@') {
            return i
        }
    }
    return name.count
}

// The volume named name: its ID, or null.
volume_named :: fn(server: ptr[mut Server], name: u8[]) -> u64? {
    match slopfs.find_volume_named(server.container, name) {
        case Ok(found) => return found
        case Error(error) => return null
    }
}

/*
 * A connection for the volume named name, or for "volume@snapshot", its snapshot's, read only. Each knows who wrote
 * a clone's older blocks, for its reads.
 */
open_volume :: fn(server: ptr[mut Server], name: u8[]) -> container.Response {
    split :: at_of(name)
    if split > name.count {
        return .NoVolume
    }
    id :: volume_named(server, name[0..<split]) or_return .NoVolume
    record := slopfs.volume_record(server.container, id) or_return .NoVolume
    lineage :: slopfs.lineage_of(server.container, &record) or_return .Failed
    snapshot : u64 = 0
    after :: split + 1
    if split < name.count && after <= name.count {
        found :: match slopfs.find_snapshot(server.container, id, name[after..<name.count]) {
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

// A volume's snapshot taken, of what its last commit left, durable at once.
take_snapshot :: fn(server: ptr[mut Server], volume: u8[], name: u8[], now: u64) -> container.Response {
    id :: volume_named(server, volume) or_return .NoVolume
    match slopfs.take_snapshot(server.container, id, name, now) {
        case Ok(number) => {}
        case Error(error) => return if error == .AlreadyExists { .AlreadyExists } else { .Failed }
    }
    return commit_own(server)
}

// A volume's snapshot deleted, and what only it held freed, durable at once.
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

// A volume's snapshot by its place among them, its name in out.
snapshot_at :: fn(server: ptr[mut Server], volume: u8[], index: u64, out: ptr[mut os.Outgoing]) -> container.Response {
    id :: volume_named(server, volume) or_return .NoVolume
    snapshots : slopfs.NumberedSnapshot[..]
    defer runtime.array_free(&snapshots)
    match slopfs.snapshot_records(server.container, id, &snapshots) {
        case Ok => {}
        case Error(error) => return .Failed
    }
    if index >= cast[u64](snapshots.count) {
        return .NoMore
    }
    found := snapshots[cast[usize](index)].record
    return .Snapshot(container.SnapshotInfo.{name = os.append(out, slopfs.name_of_snapshot(&found)), transaction = cast[u64](found.transaction),
        created = cast[u64](found.created)})
}

// A new volume cloned from a volume's snapshot, durable at once.
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

// The container's own changes committed: a snapshot, a deletion or a clone.
commit_own :: fn(server: ptr[mut Server]) -> container.Response {
    match slopfs.commit_own(server.container) {
        case Ok => return .Done
        case Error(error) => {
            log_line.write(server.log, "container_service: a commit of its own failed: %", error)
            return .Failed
        }
    }
}

// A request on a volume's connection, or a snapshot's, at index.
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
            own(server, start, blocks, volume, server.container.space.transaction, true)
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
            slopfs.abandon_volume(server.container, volume, &undone)
            // Its allocations aren't its own any more, and what it gave back is again
            for change in undone {
                if change.change == .Allocated {
                    _ = disown(server, volume, change.start, change.blocks)
                }
                else if change.change == .FreedLater {
                    own(server, change.start, change.blocks, volume, change.birth, false)
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

/*
 * A connection of its own to the driver, through the container's partition, for a volume's server: its reads and
 * writes checked against the volume's extents, the driver's buffer its own, so data moves with no copies here.
 */
// A block connection for the volume connection at index, reading and writing what it may.
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

// A block connection's requests: reads and writes inside the volume's extents passed to the driver, the rest answered.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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

// Whether a transfer's sectors are all in one extent the connection may read, or write.
in_volume :: fn(server: ptr[Server], connection: ptr[Connection], transfer: block.Transfer, writing: bool) -> bool {
    if transfer.first % SECTORS_PER_BLOCK != 0 || cast[u64](transfer.count) % SECTORS_PER_BLOCK != 0 || transfer.count == 0 {
        return false
    }
    first :: transfer.first / SECTORS_PER_BLOCK
    count :: cast[u64](transfer.count) / SECTORS_PER_BLOCK
    return if writing { may_write(server, connection, first, count) } else { may_read(server, connection, first, count) }
}

// What the driver answered a block connection's requests, back to its client.
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
            case Failed(error) => {
                drop(server, index)
                return void
            }
            case _ => continue
        }
        answer(connection.end, server.port, os.message_of[block.Response](into)^)
    }
}

answer :: fn(end: slop_os.Channel, port: slop_os.Port, response: block.Response) {
    out := os.Outgoing.{}
    made :: os.begin[block.Response](&out)
    made^ = response
    _ = block.send_response(end, port, &out)
}
