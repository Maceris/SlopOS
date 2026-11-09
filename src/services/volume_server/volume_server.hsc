/**
 * A volume server (roadmap 8d, decisions/0089): one per volume in use, started by the storage manager with a
 * connection to its container service for that volume, and nothing else. It holds the volume's tree (src/slopfs), its
 * cache of dirty nodes and its clients, and serves the file protocols as the FAT server does: dir and read_only_dir
 * for directories, file and read_only_file for files, and file_set. A bug exploited through one volume's files
 * reaches that volume, and no other.
 *
 * Its blocks come from the container service, which it reads and writes them through, and its changes are committed
 * there: a Sync on any connection commits at once and answers once that's durable, and a second after the last
 * change, whatever changed is committed anyway. After a crash, the volume is as it was after some prefix of what was
 * done to it (decisions/0085). Transactions, Replace and change cursors are in transactions.hsc.
 *
 * An encrypted volume's keys are here and nowhere else (roadmap 8e): it waits for the storage manager's Unlock, on its
 * own protocol, before it serves anything, unwraps the volume's key with the passphrase from the records the container
 * service keeps sealed, and holds them until it ends. Rotate starts a new key generation. A snapshot is served read
 * only, its root a read_only_dir, and a clone's tree knows whose its older blocks are.
 *
 * Stored links (roadmap 8f) are in links.hsc: followed through the storage manager, made from grants, and issued.
 *
 * Snapshots (decisions/0179) are in snapshots.hsc: taken, listed and opened through dir, on its own volume's
 * connection to the container service, and a snapshot's tree served read only beside the live one, with its keys.
 *
 * Loans (Perf's Pc, decisions/0037, 0127, 0130): a client may lend a dir connection a CPU budget (Lend), which what's
 * opened through it has too. Requests are served one at a time, always from the connection whose loan has the highest
 * priority of those with one waiting, the server's thread running on that loan while it serves it; a connection
 * without one is served at the server's own priority, 0 here. So a background writer's queue doesn't hold up an
 * interactive client's reads.
 */
package volume_server

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import file_set from "std/os/slop_os"
import files from "std/os/slop_os"
import grant from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import slopfs from "../../slopfs"
import log_line from "../../log_line"
import block from "../../protocols/block"
import container from "../../protocols/container"
import links from "../../protocols/links"
import volume_protocol from "../../protocols/volume"

/** The most connections at once, of every kind; one past them is closed at once, and an open answered NoSpace. */
MAX_CONNECTIONS :: 64
/** The rights the server keeps of a loan, for what's opened through its connection too. */
LOAN_RIGHTS :: cast[slop_os.Rights](cast[u32](slop_os.RIGHT_CPU_BUDGET_BIND) | cast[u32](slop_os.RIGHT_DUPLICATE))
/** The most bytes of a client's buffer, or a transaction's log, mapped here; a bigger one is refused. */
MAX_BUFFER_BYTES : u64 : 16 << 20
/** 512-byte sectors in a 4 KiB block. */
SECTORS_PER_BLOCK : u64 : 8
/** How many blocks a step of sealing again after a new volume key seals (decisions/0181's F5). */
RESEAL_BLOCKS : u64 : 16
/** How long the server waits for a client between steps of sealing again, in nanoseconds: 2 ms. */
RESEAL_PAUSE : u64 : 2_000_000

/** How long after a change it's committed without a Sync, in nanoseconds: a second. */
COMMIT_NANOSECONDS : u64 : 1000000000

/** What a connection is, and so which protocol it speaks. */
Kind :: enum {
    /** A slot no connection has. */
    Free,
    /** A directory, speaking dir: the listener's, and those opened beneath it. */
    Dir,
    /** A directory read only, speaking read_only_dir: a snapshot's root, a narrowed one, or one opened beneath. */
    ReadOnlyDir,
    /** A file, speaking file, to read and write. */
    File,
    /** A file, speaking read_only_file. */
    ReadOnlyFile,
    /** A directory's files matching a pattern, speaking file_set. */
    FileSet,
    /** A dir connection in a transaction, its changes logged until Commit. */
    Transaction,
    /** A file opened in a transaction, its writes logged too. */
    TransactionFile,
    /** A new file from Replace, until it's installed. */
    Replacement,
    /** The storage manager's, on the volume protocol. */
    Control,
    /** A grant this volume gave, speaking grant (links.hsc). */
    Grant,
    /** A grant from another volume this one is claiming, to keep as a link (links.hsc). */
    Claim,
    /** Its connection to the storage manager for stored links (links.hsc). */
    Links,
}

/** A connection: the object it's to, its informational name (a set's pattern), and a file's buffer, mapped here. */
Connection :: struct {
    /** What it is; Free for a slot no connection has. */
    kind : Kind,
    /** The client's end, the server's own, bound to the port under the connection's slot; closed by drop. */
    end : slop_os.Channel,
    /** The object it's to: a directory, a file, or a grant's; 0 for a file not yet there in a transaction. */
    object : u64,
    /** Whether it may change nothing. */
    read_only : bool,
    /** Its name: the path it was opened at, a set's pattern, or a claim's or replacement's name in its target. */
    name : u8[files.PATH_BYTES],
    /** How many of name's bytes are its. */
    name_length : u32,
    /** The size in bytes of a file's buffer, its client's memory, at most MAX_BUFFER_BYTES; 0 before UseBuffer. */
    buffer_bytes : u64,
    /**
     * The buffer's memory, the server's handle to it, read and written through memory_read and memory_write, never
     * mapped, so its client ending meanwhile fails a transfer rather than the server (decisions/0098, 0181's F6);
     * closed when it's let go of. Meaningless while buffer_bytes is 0.
     */
    buffer_memory : slop_os.Memory,
    /** A transaction's index, for one in a transaction. */
    transaction : usize,
    /** A replacement's directory, where it's installed under its name; a claim's, where its link goes. */
    target : u64,
    /** Opened through a stored link, or from what was: it grants, links, and lists or revokes links not at all (8f). */
    linked : bool,
    /** Waiting for what it asked to be answered by the storage manager or a grant, so it isn't read meanwhile. */
    waiting : bool,
    /** A grant's ticket, made at random once it's claimed. */
    ticket : u8[32],
    /** Whether a grant has been claimed, or a claim's grant has answered. */
    claimed : bool,
    /** Whether a link's been issued with a grant's ticket, so it isn't again. */
    issued : bool,
    /** A claim's: the slot of the connection waiting for it. */
    client : usize,
    /** A claim's: what the grant's server said. */
    claim : grant.Claim,
    /**
     * The snapshot its object is in (snapshots.hsc): its slot in the server's pasts plus 1; 0 for the live volume. One
     * with a snapshot is a ReadOnlyDir or ReadOnlyFile.
     */
    past : usize,
    /** The CPU budget lent for its work, the server's handle; NO_HANDLE for none. */
    loan : slop_os.CpuBudget,
    /** The loan's priority, which orders whose request is served next; 0 without one. */
    priority : u32,
}

/**
 * How a tree's blocks are reached: a connection to the container service for its volume, or a snapshot of it, and the
 * block connection that gives, with its buffer mapped here. The live volume's and each snapshot's served (snapshots.hsc)
 * have one each; a Device's context is one.
 */
Reach :: struct {
    /** The connection to the container service. */
    container : slop_os.Channel,
    /** A port bound to container, waited on for its answers. */
    container_port : slop_os.Port,
    /** The block connection, through the container service, narrowed to what the volume, or snapshot, may reach. */
    blocks : slop_os.Channel,
    /** A port bound to blocks, waited on for its answers. */
    blocks_port : slop_os.Port,
    /** The block connection's buffer's size in bytes; 0 before it's had. */
    buffer_bytes : u64,
    /**
     * The buffer's memory, its block driver's, written and read through memory_write and memory_read, never mapped, so
     * the driver ending meanwhile fails a transfer rather than the server (decisions/0098, 0181's F6).
     */
    window : slop_os.Memory,
    /** How many 4 KiB blocks the container's partition has, for a Device. */
    block_count : u64,
}

/** The volume server's state, made once in main, on the heap, and kept for as long as it runs. */
Server :: struct {
    /** The debug log it says what it's doing in; NO_HANDLE for none. */
    log : slop_os.DebugLog,
    /** The port every connection is bound to, under its slot. */
    port : slop_os.Port,
    /** Its volume's connection to the container service, and its block connection, whose context its device is. */
    own : Reach,
    /** The tree's nodes: its device, its cache, and the volume's next transaction. */
    nodes : slopfs.Nodes,
    /** The volume, attached, on the heap. */
    volume : ptr[mut slopfs.Volume],
    /** What the volume server was told of its volume and container. */
    described : container.Described,
    /** When what's changed is committed without a Sync, in nanoseconds of the monotonic clock; 0 when nothing has. */
    commit_at : u64,
    /** The connections, by slot. */
    connections : Connection[MAX_CONNECTIONS],
    /** How many slots of connections have ever been used: one past the highest. */
    count : usize,
    /** Whether a connection was added, or let be read again, while serving, so main serves again before it waits. */
    added : bool,
    /** The transactions open, by index. */
    transactions : Transaction[MAX_TRANSACTIONS],
    /** Its connection to the storage manager for stored links (links.hsc); NO_HANDLE once it's gone. */
    links : slop_os.Channel,
    /** What it's asked on links, in order, a ring of asked_count from asked_first. */
    asked : Asked[MAX_CONNECTIONS],
    /** Where the ring of what's asked starts. */
    asked_first : usize,
    /** How many are asked and not yet answered. */
    asked_count : usize,
    /** Whether connections added now are reached through a link. */
    linking : bool,
    /** The snapshots being served, read only, beside the live volume (snapshots.hsc). */
    pasts : Past[MAX_PASTS],
    /** The past connections added now have: a slot in pasts plus 1, while serving a snapshot's; 0 otherwise. */
    pasting : usize,
    /** The connection being served, whose loan what it opens has too. */
    serving : usize,
    /** Whether a request of a client's was served this time, which is one at a time. */
    handled : bool,
    /** Whether the thread runs on a loan now. */
    on_loan : bool,
    /** Where the next search for a request starts, among connections of the same priority. */
    next_first : usize,
    /**
     * The floor its blocks are being sealed again to after a new volume key (decisions/0181's F5), a step at a time
     * while it's otherwise idle; 0 when they aren't.
     */
    resealing : u32,
    /** Where the next step of sealing again walks from. */
    reseal_from : slopfs.Key,
}

/**
 * Serve one volume of a SlopOS container: hold its tree, cache and keys, and serve its files, committing what changes
 * through the container service.
 *
 * Started by the storage manager, one per volume in use, with a connection to the container service for that volume
 * and nothing else. An encrypted volume waits for the storage manager's Unlock before it serves anything. A volume
 * made with nothing in it is given its root and first commit; orphans a crash left are given back. Runs until it's
 * stopped.
 *
 * @param log The debug log it says what it's doing in; without one, it says nothing.
 * @param volume A connection to the container service for this volume, or a snapshot of it, served read only.
 * @param clients The listener for connections to the volume's root.
 * @param control The listener the storage manager speaks the volume protocol on: Unlock, Commit, Rotate, IssueTo and
 *     OpenIssued.
 * @param stored_links Its connection to the storage manager for stored links, which knows it's this volume's.
 * @return 99 without the memory for its state, 1 if its ports couldn't be made, 2 if the volume couldn't be described,
 *     3 if no block connection could be had, 4 if its description or buffer couldn't be had or mapped, 5 if the
 *     listeners or links couldn't be added, 6 if the storage manager went before unlocking it, 7 if the volume
 *     couldn't be attached, and 8 if a new volume couldn't be filled. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, volume: os.Channel[container.Container], clients: os.Listener[dir.Dir],
    control: os.Listener[volume_protocol.Volume], stored_links: os.Channel[links.Links]) -> int {
    startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    server_made, server_error :: runtime.new_aligned(Server, align_of(Server))
    if server_error != null {
        return 99
    }
    server :: server_made
    server^ = Server.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), links = stored_links.end}
    server.port = slop_os.port_create(startup.budget) or_return 1
    described :: match reach(&server.own, volume.end) {
        case Ok(made) => made
        case Error(code) => return cast[int](code)
    }
    device :: slopfs.Device.{context = cast[rawptr](&server.own), block_count = server.own.block_count, read = read_blocks,
        write = write_blocks, flush = no_flush}
    server.nodes = slopfs.Nodes.{device = device, transaction = described.transaction, space = cast[rawptr](server), allocate = allocate,
        release = release}
    server.described = described
    // An encrypted volume is served once it's unlocked
    keys : ptr[mut slopfs.Keys]? = null
    if described.record.cipher != cast[u8](slopfs.Cipher.None) {
        keys = wait_for_unlock(server, control.end) or_return 6
    }
    server.volume = slopfs.attach_volume(&server.nodes, device, described.id, described.record, keys) or_return 7
    server.volume.tree.lineage = described.lineage
    // A volume made with nothing in it (decisions/0141) given its root directory, its first commit
    if !described.read_only && slopfs.is_unfilled(&described.record) {
        // Its root directory made when the volume was
        slopfs.fill_volume(server.volume, cast[u64](described.record.created)) or_return 8
        if !commit(server) {
            return 8
        }
        log_line.write(server.log, "volume_server: volume % filled", described.id)
    }
    if !described.read_only {
        server.volume.history_bytes = slopfs.HISTORY_BYTES
        // Nothing has anything open yet, so every orphan a crash left is given back
        swept :: slopfs.sweep_orphans(server.volume) or_else 0
        if swept > 0 {
            _ = commit(server)
        }
    }
    if !described.read_only && (server.volume.tree.keys is_some) {
        // A new volume key's sealing again, gone on with, or its old generations deleted if nothing needs them now
        resume_floor(server)
    }
    name :: string_of(&described.record.name[0], cast[usize](cast[u16](described.record.name_bytes)))
    log_line.write(server.log, "volume_server: serving volume % (%), from transaction %", described.id, name, described.transaction)
    // The listener is a connection to the root, as any client's Connect on it gives another
    if add(server, if described.read_only { Kind.ReadOnlyDir } else { Kind.Dir }, clients.end, slopfs.ROOT_OBJECT, described.read_only, "") is_none {
        return 5
    }
    if add(server, .Control, control.end, 0, false, "") is_none {
        return 5
    }
    if add(server, .Links, stored_links.end, 0, false, "") is_none {
        return 5
    }
    into := os.Incoming.{}
    loop {
        // One request at a time, from the highest priority with one waiting, and again from the top after each
        loop {
            server.added = false
            if !serve_one(server, &into) && !server.added {
                break
            }
        }
        now :: slop_os.clock_monotonic() or_else 0
        if server.volume.dirty && server.commit_at == 0 {
            server.commit_at = now + COMMIT_NANOSECONDS
        }
        if server.commit_at != 0 && now >= server.commit_at {
            _ = commit(server)
            continue
        }
        // Sealing again goes on a step at a time, clients' requests served between each
        if server.resealing != 0 {
            reseal_some(server)
        }
        until := if server.commit_at != 0 { server.commit_at } else { slop_os.NO_DEADLINE }
        if server.resealing != 0 && now + RESEAL_PAUSE < until {
            until = now + RESEAL_PAUSE
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(server.port, packets, until)
    }
}

/**
 * Reach a volume's blocks, or a snapshot's, through its connection to the container service: described, a block
 * connection opened, and its buffer's memory had.
 *
 * @param into Where it's kept: its container end, block connection, ports and buffer; what's made before a failure is
 *     left there, for the caller to close (let_go_of_reach).
 * @param end The connection to the container service for the volume or snapshot, which into takes over.
 * @return What the container service says of it; on failure, main's exit code for it: 1 if a port couldn't be made, 2
 *     if it couldn't be described, 3 if no block connection could be had, 4 if the block connection's description or
 *     buffer couldn't be had.
 */
reach :: fn(into: ptr[mut Reach], end: slop_os.Channel) -> Result[container.Described, u32] {
    startup :: slop_os.startup_block()
    into^ = Reach.{container = end, container_port = cast[slop_os.Port](slop_os.NO_HANDLE), blocks = cast[slop_os.Channel](slop_os.NO_HANDLE),
        blocks_port = cast[slop_os.Port](slop_os.NO_HANDLE), window = cast[slop_os.Memory](slop_os.NO_HANDLE)}
    into.container_port = os.port_for(startup.budget, end) or_return .Error(1)
    described := container.Described.{}
    match ask_on(into, .Describe) {
        case Described(made) => described = made
        case _ => return .Error(2)
    }
    match ask_on(into, .OpenBlocks) {
        case Blocks(made) => into.blocks = made.end
        case _ => return .Error(3)
    }
    into.blocks_port = os.port_for(startup.budget, into.blocks) or_return .Error(3)
    info := block.Info.{}
    match call(into, .Describe) {
        case Described(made) => info = made
        case _ => return .Error(4)
    }
    match call(into, .GetBuffer) {
        case Buffer(memory) => into.window = memory
        case _ => return .Error(4)
    }
    into.buffer_bytes = info.buffer_bytes
    into.block_count = info.block_count / SECTORS_PER_BLOCK
    return .Ok(described)
}

/**
 * Let go of what reaches a tree's blocks: its connections, ports and buffer's memory closed.
 *
 * @param reached What reach made, or began to; each part not made is NO_HANDLE, and left. It's left with nothing.
 */
let_go_of_reach :: fn(reached: ptr[mut Reach]) {
    for handle in slop_os.Handle.[cast[slop_os.Handle](reached.window), cast[slop_os.Handle](reached.blocks_port),
        cast[slop_os.Handle](reached.blocks), cast[slop_os.Handle](reached.container_port), cast[slop_os.Handle](reached.container)] {
        if handle != slop_os.NO_HANDLE && handle != 0 {
            _ = slop_os.handle_close(handle)
        }
    }
    reached^ = Reach.{container = cast[slop_os.Channel](slop_os.NO_HANDLE), container_port = cast[slop_os.Port](slop_os.NO_HANDLE),
        blocks = cast[slop_os.Channel](slop_os.NO_HANDLE), blocks_port = cast[slop_os.Port](slop_os.NO_HANDLE),
        window = cast[slop_os.Memory](slop_os.NO_HANDLE)}
}

// The container service, a request at a time

/**
 * Send one request to the container service, and wait for its answer.
 *
 * @param server The server; the request goes on its container connection and the answer is waited for on its container
 *     port, so nothing else is served meanwhile.
 * @param request The request, which holds no Relatives.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
ask :: fn(server: ptr[mut Server], request: container.Request) -> container.Response {
    return ask_on(&server.own, request)
}

/**
 * Send one request to the container service on a tree's connection, and wait for its answer.
 *
 * @param reached The tree's connection to the container service, and the port it's waited on, so nothing else is
 *     served meanwhile.
 * @param request The request, which holds no Relatives.
 * @return The answer, a copy, whose handles the caller owns, and which holds no Relatives the caller reads; Unsupported
 *     if it couldn't be sent or the connection failed.
 */
ask_on :: fn(reached: ptr[Reach], request: container.Request) -> container.Response {
    out := os.Outgoing.{}
    made :: os.begin[container.Request](&out)
    made^ = request
    into := os.Incoming.{}
    return ask_built(reached, &out, &into)
}

/**
 * Send a request built with its variable-size data to the container service on a tree's connection, and wait for its
 * answer, kept in into for what's in its variable-size data.
 *
 * @param reached The tree's connection to the container service, and its port.
 * @param out The request, built by the caller; its handles are moved out when it's sent.
 * @param into Where the answer is read into, which a Relative in it is read from.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
ask_built :: fn(reached: ptr[Reach], out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> container.Response {
    if container.send_request(reached.container, reached.container_port, out) is_some {
        return .Unsupported
    }
    loop {
        match container.receive_response(reached.container, reached.container_port, into, true) {
            case Received => return os.message_of[container.Response](into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Allocate an extent for the volume's tree, or a file's chunk, from the container service, for slopfs's Nodes.
 *
 * @param context The volume server, a ptr[mut Server] passed as slopfs's Nodes space; its container service is asked,
 *     and waited for.
 * @param blocks How many 4 KiB blocks, at most the container's MAX_ALLOCATE.
 * @param owner Unused: the container service knows whose volume it is.
 * @param data Whether it's a file's bytes, which the volume's quota and the reserve hold back, or a tree's nodes.
 * @return Its first block; null if the container refused it, as a full container or a quota does.
 */
allocate :: fn(context: rawptr, blocks: u64, owner: u64, data: bool) -> u64? {
    server :: cast[ptr[mut Server]](context)
    return match ask(server, .Allocate(container.Allocation.{blocks = blocks, data = data})) {
        case Allocated(first) => first
        case _ => null
    }
}

/**
 * Give an extent back to the container service, for slopfs's Nodes; a refusal is ignored.
 *
 * @param context The volume server, a ptr[mut Server] passed as slopfs's Nodes space; its container service is asked,
 *     and waited for.
 * @param address Its first block.
 * @param blocks How many blocks, its whole length.
 * @param owner Unused: the container service knows whose volume it is.
 * @param birth The transaction it was written in, which says whether a snapshot or a clone's origin holds it.
 */
release :: fn(context: rawptr, address: u64, blocks: u64, owner: u64, birth: u64) {
    server :: cast[ptr[mut Server]](context)
    _ = ask(server, .Release(container.Released.{first = address, blocks = blocks, birth = birth}))
}

/**
 * Make what's changed durable: the volume's dirty nodes written, every write done, then its record committed by the
 * container service, which makes it durable with a checkpoint.
 *
 * @param server The server, whose commit_at is cleared and whose next transaction is the one the container gives.
 * @return Whether it was committed; a failure marks the volume failed, logged, and every later commit fails too.
 */
commit :: fn(server: ptr[mut Server]) -> bool {
    server.commit_at = 0
    record := slopfs.VolumeRecord.{}
    match slopfs.write_volume(server.volume) {
        case Ok(written) => record = written
        case Error(error) => {
            log_line.write(server.log, "volume_server: volume %'s tree can't be written: %", server.volume.id, error)
            server.volume.failed = true
            return false
        }
    }
    match ask(server, .Commit(record)) {
        case Committed(next) => {
            server.nodes.transaction = next
            return true
        }
        case _ => {
            server.volume.failed = true
            return false
        }
    }
}

// The volume's blocks, through its block connection

/**
 * Send one request on the block connection, and wait for its answer.
 *
 * @param reached The tree's block connection; the request goes on it and the answer is waited for on its blocks port,
 *     so nothing else is served meanwhile.
 * @param request The request, sent as it is; a Read or Write's blocks are 512-byte sectors of the volume's extents, its
 *     data in the buffer.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
call :: fn(reached: ptr[Reach], request: block.Request) -> block.Response {
    out := os.Outgoing.{}
    made :: os.begin[block.Request](&out)
    made^ = request
    if block.send_request(reached.blocks, reached.blocks_port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match block.receive_response(reached.blocks, reached.blocks_port, &into, true) {
            case Received => return os.message_of[block.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => return .Unsupported
        }
    }
}

/**
 * Tell whether a block request finished as it should.
 *
 * @param response The block driver's answer to a Read or Write, as call gives it; Unsupported, for a request that
 *     couldn't be sent or answered, is false like any other.
 * @return Whether it's Finished with Done.
 */
done :: fn(response: block.Response) -> bool {
    return match response {
        case Finished(completion) => completion.status == .Done
        case _ => false
    }
}

/**
 * Read 4 KiB blocks of the container, for slopfs's Device; the container service checks the volume may.
 *
 * @param context The tree's Reach, a ptr[Reach] passed as slopfs's Device context; its block buffer is
 *     overwritten.
 * @param first The first block in the container.
 * @param count How many blocks.
 * @param into Where they go, at least count blocks long.
 * @return Whether they were all read.
 */
read_blocks :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    reached :: cast[ptr[Reach]](context)
    return move(reached, first, count, into, false)
}

/**
 * Write 4 KiB blocks of the container, for slopfs's Device; the container service checks the volume allocated them
 * since its last commit. Durable only once a commit is.
 *
 * @param context The tree's Reach, a ptr[Reach] passed as slopfs's Device context; its block buffer is
 *     overwritten.
 * @param first The first block in the container.
 * @param count How many blocks.
 * @param from What's written, at least count blocks long.
 * @return Whether they were all written.
 */
write_blocks :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    reached :: cast[ptr[Reach]](context)
    return move(reached, first, count, view_of(cast[ptr[mut u8]](from.data), from.count), true)
}

/**
 * Flush nothing, for slopfs's Device: the container service flushes when it commits; a volume server never does
 * itself.
 *
 * @param context Unused.
 * @return True.
 */
no_flush :: fn(context: rawptr) -> bool {
    return true
}

/**
 * Move 4 KiB blocks through the block connection's buffer, as many at a time as it holds: read into bytes, or written
 * from them. Each transfer is a whole extent's blocks, or part of one, as the container service checks. The buffer is
 * its driver's memory, copied into before a write and out of after a read through the kernel, so a driver that ended
 * fails the move.
 *
 * @param reached How the tree's blocks are reached, whose buffer is overwritten by each transfer, at most buffer_bytes
 *     of it at a time, each waited for.
 * @param first The first block in the container.
 * @param count How many blocks.
 * @param bytes Where they're read to, or written from; at least count blocks long.
 * @param writing Whether they're written, or read.
 * @return Whether all of them moved; false if bytes is too short, the buffer holds no block, a copy through the buffer
 *     failed, or a transfer did, what was moved before it moved.
 */
move :: fn(reached: ptr[Reach], first: u64, count: u64, bytes: mut u8[], writing: bool) -> bool {
    per :: reached.buffer_bytes / slopfs.BLOCK_BYTES
    if per == 0 || count * slopfs.BLOCK_BYTES > cast[u64](bytes.count) {
        return false
    }
    moved := cast[u64](0)
    loop {
        if moved >= count {
            return true
        }
        now :: if count - moved < per { count - moved } else { per }
        base :: cast[usize](moved * slopfs.BLOCK_BYTES)
        end :: base + cast[usize](now * slopfs.BLOCK_BYTES)
        available :: bytes.count
        if base > end || end > available {
            return false
        }
        part :: bytes[base..<end]
        if writing && (slop_os.memory_write(reached.window, 0, part) is_error) {
            return false
        }
        transfer :: block.Transfer.{tag = 1, first = (first + moved) * SECTORS_PER_BLOCK, count = cast[u32](now * SECTORS_PER_BLOCK), offset = 0}
        if !done(call(reached, if writing { block.Request.Write(transfer) } else { block.Request.Read(transfer) })) {
            return false
        }
        if !writing && (slop_os.memory_read(reached.window, 0, part) is_error) {
            return false
        }
        moved += now
    }
}

// Connections

/**
 * Add a connection, in the first free slot, bound to the port under its slot.
 *
 * It's linked if it's added while serving a linked connection, in the snapshot pasting names, and has a copy of the loan
 * of the connection being served, if that has one, at its priority.
 *
 * @param server The server, whose added is set.
 * @param kind The protocol and role the connection has, kept in its slot and choosing the serve function that reads
 *     it; never Free.
 * @param end The client's end, which the server takes over: closed here if it can't be added.
 * @param object The object it's to.
 * @param read_only Whether it may change nothing.
 * @param name The path it was opened at, a set's pattern, or a name in a target; cut to files.PATH_BYTES.
 * @return Its slot; null, with end closed, if there are MAX_CONNECTIONS already or it couldn't be bound.
 */
add :: fn(server: ptr[mut Server], kind: Kind, end: slop_os.Channel, object: u64, read_only: bool, name: string) -> usize? {
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
    match slop_os.port_bind(server.port, cast[slop_os.Handle](end), signals, cast[u64](slot), .Persistent) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](end))
            return null
        }
    }
    connection := Connection.{kind = kind, end = end, object = object, read_only = read_only, linked = server.linking,
        past = server.pasting, loan = cast[slop_os.CpuBudget](slop_os.NO_HANDLE)}
    // What's opened through a connection with a loan has a copy of it
    serving :: server.serving
    if serving < server.connections.count && serving < server.count
        && cast[slop_os.Handle](server.connections[serving].loan) != slop_os.NO_HANDLE {
        match slop_os.handle_duplicate(cast[slop_os.Handle](server.connections[serving].loan), LOAN_RIGHTS) {
            case Ok(copy) => {
                connection.loan = cast[slop_os.CpuBudget](copy)
                connection.priority = server.connections[serving].priority
            }
            case Error(error) => {}
        }
    }
    for character, i in name {
        if i < connection.name.count {
            connection.name[i] = cast[u8](character)
            connection.name_length = cast[u32](i + 1)
        }
    }
    server.connections[slot] = connection
    server.added = true
    if slot >= server.count {
        server.count = slot + 1
    }
    return slot
}

/**
 * Make a new connection speaking P's protocol, and add it.
 *
 * @tparam P The protocol: dir, read_only_dir, file, read_only_file, file_set or grant's.
 * @param server The server, which the connection is added to, with a copy of the loan of the connection being served,
 *     as add gives it.
 * @param kind What it is, which must speak P.
 * @param object The object it's to.
 * @param read_only Whether it may change nothing.
 * @param name The path it was opened at, or a set's pattern.
 * @return The other end, the client's, which the caller sends; null if a channel or a slot couldn't be had.
 */
open_connection :: fn[P](server: ptr[mut Server], kind: Kind, object: u64, read_only: bool, name: string) -> os.Channel[P]? {
    startup :: slop_os.startup_block()
    pair :: os.channel_for[P](startup.budget, 0) or_return null
    if add(server, kind, pair.a, object, read_only, name) is_none {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return os.Channel[P].{end = pair.b}
}

/**
 * Drop a connection whose client went: unbind it, close its end and its loan, let go of its buffer, and free its slot.
 *
 * A transaction's is aborted; a replacement never installed is given back, as is a file's orphan nothing else has
 * open.
 *
 * @param server The server: a transaction's connection ends its transaction, a replacement's gives its orphan back, and
 *     a file's gives back an orphan nothing else has open.
 * @param index The connection's slot; one past them is ignored.
 */
drop :: fn(server: ptr[mut Server], index: usize) {
    if index >= server.connections.count {
        return void
    }
    connection :: &server.connections[index]
    _ = slop_os.port_unbind(server.port, cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
    if cast[slop_os.Handle](connection.loan) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.loan))
        connection.loan = cast[slop_os.CpuBudget](slop_os.NO_HANDLE)
        connection.priority = 0
    }
    release_buffer(connection)
    kind :: connection.kind
    object :: connection.object
    past :: connection.past
    connection.kind = .Free
    connection.past = 0
    // A snapshot's tree is let go of with the last thing open in it; nothing of the live volume's is touched
    if past != 0 {
        let_go_if_unused(server, past - 1)
        return void
    }
    // A transaction closed is aborted; a replacement never installed, and an orphan nothing has open, given back
    if kind == .Transaction {
        end_transaction(server, connection.transaction)
    }
    else if kind == .Replacement {
        _ = slopfs.release_orphan(server.volume, object)
    }
    else if kind == .File || kind == .ReadOnlyFile {
        release_if_unused(server, object, index)
    }
}

/**
 * Let go of a file connection's buffer: close its memory, if it has one.
 *
 * @param connection The connection, whose buffer's memory, if it has one, is closed, buffer_bytes left 0; one without
 *     a buffer is left alone.
 */
release_buffer :: fn(connection: ptr[mut Connection]) {
    if connection.buffer_bytes != 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.buffer_memory))
        connection.buffer_bytes = 0
    }
}

/**
 * Give a connection's name.
 *
 * @param connection The connection, read; a name_length past files.PATH_BYTES is cut to it.
 * @return A view of its name's bytes, good while the connection is unchanged.
 */
name_of :: fn(connection: ptr[Connection]) -> string {
    return string_of(&connection.name[0], cast[usize](if connection.name_length > files.PATH_BYTES { cast[u32](files.PATH_BYTES) } else { connection.name_length }))
}

/**
 * Serve one client's request, the connections tried by their loans' priorities, highest first, ties going round from
 * the one after the last served; the server's own connections (the storage manager's, its links, grants and claims)
 * are drained as they're tried.
 *
 * @param server The server, whose next_first moves past the connection served; one whose end fails is dropped, and the
 *     thread leaves a loan once it's served.
 * @param into Where each message is read into, reused.
 * @return Whether a client's request was served; false once no connection has one waiting.
 */
serve_one :: fn(server: ptr[mut Server], into: ptr[mut os.Incoming]) -> bool {
    tried : bool[MAX_CONNECTIONS]
    loop {
        // Ties go round, from the one after the last served
        best := server.connections.count
        for k in 0..<server.count {
            i :: (server.next_first + k) % server.count
            if i < server.connections.count && i < tried.count && !tried[i] && server.connections[i].kind != .Free
                && (best >= server.connections.count || server.connections[i].priority > server.connections[best].priority) {
                best = i
            }
        }
        if best >= server.connections.count || best >= tried.count {
            return false
        }
        tried[best] = true
        server.handled = false
        server.serving = best
        serve(server, best, into)
        if server.on_loan {
            _ = runtime.bind_cpu_budget(0)
            server.on_loan = false
        }
        if server.handled {
            server.next_first = best + 1
            return true
        }
    }
}

/**
 * Mark a client's request received, the one served this time, and run the thread on the connection's loan, if it has
 * one, while it's served: bound through its per-thread page (runtime.bind_cpu_budget, decisions/0185), which the
 * kernel reads at its next scheduling point, the next system call, so no call of its own is made.
 *
 * @param server The server, whose handled, and on_loan if the loan could be used, are set.
 * @param index The connection's slot, whose loan, if it has one, the thread runs on; one past them sets only handled.
 */
received :: fn(server: ptr[mut Server], index: usize) {
    server.handled = true
    if index < server.connections.count && cast[slop_os.Handle](server.connections[index].loan) != slop_os.NO_HANDLE {
        server.on_loan = runtime.bind_cpu_budget(cast[u64](server.connections[index].loan))
    }
}

/**
 * Take a loan for a connection's work, in place of the one it had, which is closed.
 *
 * @param server The server, whose connection at index takes budget in place of its loan.
 * @param index The connection's slot; past them, the budget is closed.
 * @param budget The CPU budget lent, which the server takes over; its priority orders the connection's requests, 0
 *     if it can't be read.
 */
lend :: fn(server: ptr[mut Server], index: usize, budget: slop_os.CpuBudget) {
    if index >= server.connections.count {
        _ = slop_os.handle_close(cast[slop_os.Handle](budget))
        return void
    }
    connection :: &server.connections[index]
    if cast[slop_os.Handle](connection.loan) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.loan))
    }
    connection.loan = budget
    connection.priority = cast[u32]((slop_os.cpu_budget_describe(budget) or_else slop_os.CpuBudgetInfo.{}).priority)
}

/**
 * Serve a connection's requests, as its kind says; one waiting for the storage manager or a grant isn't read.
 *
 * @param server The server; the connection's kind's own serve function reads it, and may drop it.
 * @param index The connection's slot; a free one, or one past them, is left alone.
 * @param into Where each message is read into, reused.
 */
serve :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    kind :: server.connections[index].kind
    if server.connections[index].waiting {
        return void
    }
    if kind == .Dir || kind == .Transaction {
        serve_dir(server, index, into)
    }
    else if kind == .ReadOnlyDir {
        serve_read_only_dir(server, index, into)
    }
    else if kind == .File || kind == .TransactionFile || kind == .Replacement {
        serve_file(server, index, into)
    }
    else if kind == .ReadOnlyFile {
        serve_read_only_file(server, index, into)
    }
    else if kind == .FileSet {
        serve_file_set(server, index, into)
    }
    else if kind == .Control {
        serve_control(server, index, into)
    }
    else if kind == .Grant {
        serve_grant(server, index, into)
    }
    else if kind == .Claim {
        serve_claim(server, index, into)
    }
    else if kind == .Links {
        serve_links(server, index, into)
    }
}

// Paths and answers

/**
 * Read a path from a message.
 *
 * @param into The message received, read and kept; the path is a view into it.
 * @param path Where the path's bytes are in it.
 * @return The path, a view into the message, good while it is; null if it's empty or longer than files.PATH_BYTES.
 */
path_of :: fn(into: ptr[os.Incoming], path: slop_os.Relative[u8]) -> string? {
    bytes :: os.items(into, path)
    if bytes.count == 0 || bytes.count > files.PATH_BYTES {
        return null
    }
    return string_of(&bytes[0], bytes.count)
}

/**
 * Give the file protocols' error for a slopfs error.
 *
 * @param error Any slopfs error; each one maps to a file error.
 * @return The same error where there is one; NoSpace for TooLarge, InvalidPath for InvalidName, Corrupt for NotSlopfs,
 *     NoMemory for OutOfMemory, and DeviceError for Failed and for those no file's request meets (Locked, WrongKey,
 *     InUse).
 */
file_error :: fn(error: slopfs.Error) -> files.FileError {
    return match error {
        case .DeviceError => files.FileError.DeviceError
        case .Corrupt => files.FileError.Corrupt
        case .NoSpace => files.FileError.NoSpace
        case .NotFound => files.FileError.NotFound
        case .NotADirectory => files.FileError.NotADirectory
        case .IsADirectory => files.FileError.IsADirectory
        case .AlreadyExists => files.FileError.AlreadyExists
        case .DirectoryNotEmpty => files.FileError.DirectoryNotEmpty
        case .InvalidName => files.FileError.InvalidPath
        case .TooLarge => files.FileError.NoSpace
        case .NotSlopfs => files.FileError.Corrupt
        case .Failed => files.FileError.DeviceError
        // An open volume has its keys, so neither comes from a file's request
        case .Locked => files.FileError.DeviceError
        case .WrongKey => files.FileError.DeviceError
        case .InUse => files.FileError.DeviceError
        case .IsALink => files.FileError.IsALink
        case .OutOfMemory => files.FileError.NoMemory
        case .WrongType => files.FileError.WrongType
    }
}

/**
 * Find or make a file, as creation says.
 *
 * @param volume The volume, changed when a file is made, typed or cut; that's durable only with its next commit.
 * @param directory The directory object the path is beneath.
 * @param path The path from directory: names separated by single '/', none empty; links on the way aren't followed.
 * @param creation New makes it, refusing one there; Existing finds it, refusing none; Truncate finds or makes it, cut
 *     to nothing; Either finds or makes it.
 * @param schema A schema hash (decisions/0046, 0108): one made is of that type, and one there must be, or it's
 *     WrongType. All zeros asks for no type.
 * @return The object number of the file found or made; nothing is opened.
 * @error AlreadyExists It's there, and creation is New.
 * @error NotFound It isn't there, and creation is Existing; or a directory on the way isn't.
 * @error IsADirectory What's at path is a directory.
 * @error IsALink What's at path is a link, which isn't followed here.
 * @error WrongType It's there, of another type than schema.
 * @error NotADirectory What's on the way to it isn't a directory.
 * @error InvalidName Its name can't be one.
 * @error NoSpace Making it, or cutting it, needed space the container wouldn't give.
 * @error DeviceError A block couldn't be read or written.
 * @error Corrupt The tree couldn't be read as one.
 */
open_file_object :: fn(volume: ptr[mut slopfs.Volume], directory: u64, path: string, creation: files.Creation, schema: u8[32])
    -> Result[u64, slopfs.Error] {
    leaf :: slopfs.leaf_of(volume, directory, path)?
    existing :: slopfs.lookup(volume, leaf.directory, leaf.name)?
    match existing {
        case Some(object) => {
            info :: slopfs.info(volume, object)?
            if info.kind == .Directory {
                return .Error(.IsADirectory)
            }
            if info.kind == .Link {
                return .Error(.IsALink)
            }
            if creation == .New {
                return .Error(.AlreadyExists)
            }
            if !untyped(schema) && info.schema != schema {
                return .Error(.WrongType)
            }
            if creation == .Truncate && info.size != 0 {
                slopfs.set_size(volume, object, 0)?
            }
            return .Ok(object)
        }
        case None => {
            if creation == .Existing {
                return .Error(.NotFound)
            }
            made :: slopfs.create(volume, leaf.directory, leaf.name, .File)?
            if !untyped(schema) {
                slopfs.set_schema(volume, made, schema)?
            }
            return .Ok(made)
        }
    }
}

/**
 * Give a schema hash that asks for no type.
 *
 * @return All zeros.
 */
no_schema :: fn() -> u8[32] {
    none : u8[32]
    return none
}

/**
 * Tell whether a schema hash asks for no type.
 *
 * @param schema A schema hash, as a request or a file's record carries it.
 * @return Whether it's all zeros.
 */
untyped :: fn(schema: u8[32]) -> bool {
    for byte in schema {
        if byte != 0 {
            return false
        }
    }
    return true
}

/**
 * Find a directory, or make it, with any missing on the way to it.
 *
 * @param volume The volume, changed only when create makes a directory; that's durable only with its next commit.
 * @param directory The directory object the path is beneath.
 * @param path The directory's path; "" is directory itself.
 * @param create Whether it, and each directory missing on the way, is made.
 * @return The object number of the directory at path, directory itself for ""; nothing is opened.
 * @error NotFound It isn't there, and create is false.
 * @error NotADirectory What's at path, or on the way to it, isn't a directory.
 * @error InvalidName A component can't be a name, as an empty one.
 * @error NoSpace Making it needed space the container wouldn't give.
 * @error DeviceError A block couldn't be read or written.
 * @error Corrupt The tree couldn't be read as one.
 */
open_directory_object :: fn(volume: ptr[mut slopfs.Volume], directory: u64, path: string, create: bool) -> Result[u64, slopfs.Error] {
    current := directory
    start : usize = 0
    for i in 0..<path.count + 1 {
        if i < path.count && path[i] != '/' {
            continue
        }
        if start > i {
            return .Error(.InvalidName)
        }
        component :: path[start..<i]
        start = i + 1
        found :: slopfs.lookup(volume, current, component)?
        match found {
            case Some(object) => current = object
            case None => {
                if !create {
                    return .Error(.NotFound)
                }
                current = slopfs.create(volume, current, component, .Directory)?
            }
        }
    }
    slopfs.directory_record(volume, current)?
    return .Ok(current)
}

/**
 * List a directory's entry at or after a cursor, the first that matches a pattern.
 *
 * @param volume The volume, read only.
 * @param directory The directory object whose entries are listed.
 * @param cursor Where to start: 0 for the first entry, or what the last listing's next said.
 * @param pattern The pattern the name must match, exactly as slopfs compares names; "" for every entry.
 * @param out The answer being built, which the entry's name is appended to.
 * @return The entry: its name, kind (a file, a directory or a link), size in bytes and the cursor after it; null past
 *     the last.
 * @error Corrupt A name longer than a name may be, or a tree that couldn't be read as one.
 * @error DeviceError A block couldn't be read.
 */
listing_of :: fn(volume: ptr[mut slopfs.Volume], directory: u64, cursor: u64, pattern: string, out: ptr[mut os.Outgoing]) -> Result[files.Listing?, slopfs.Error] {
    name : u8[slopfs.NAME_BYTES]
    at := cursor
    loop {
        listed :: slopfs.list(volume, directory, at, name)? or_return .Ok(null)
        at = listed.next
        if listed.name_bytes > name.count {
            return .Error(.Corrupt)
        }
        text :: string_of(&name[0], listed.name_bytes)
        if pattern.count != 0 && !file_set.matches(pattern, text, same_byte) {
            continue
        }
        info :: slopfs.info(volume, listed.object)?
        kind :: if listed.kind == .Directory { files.Kind.Directory } else if listed.kind == .Link { files.Kind.Link } else { files.Kind.File }
        return .Ok(files.Listing.{name = os.append(out, name[0..<listed.name_bytes]), kind = kind, size = info.size, next = at})
    }
}

/**
 * Tell whether two bytes of a name are the same: exactly, as slopfs compares names.
 *
 * @param a A byte of one name.
 * @param b A byte of the other name, compared with a as it is, case and all.
 * @return Whether they're equal.
 */
same_byte :: fn(a: u8, b: u8) -> bool {
    return a == b
}

/**
 * Describe a connection's directory or file.
 *
 * @param out The answer being built, which the name is appended to.
 * @param kind Directory or File.
 * @param size A file's size in bytes; 0 for a directory.
 * @param name The connection's name, as name_of gives it, or a set's pattern; appended to out as bytes.
 * @return The description, without a type: kind and size as given, and name as the bytes appended to out, so it's
 *     good in out's answer only.
 */
info_of :: fn(out: ptr[mut os.Outgoing], kind: files.Kind, size: u64, name: string) -> files.Info {
    return files.Info.{kind = kind, size = size, name = os.append(out, string_bytes(name))}
}

/**
 * Say what slopfs does that FAT doesn't: atomic replace, transactions, snapshots and change cursors.
 *
 * @return Always atomic_replace, transactions, snapshots and change_cursors true; ignores_case false.
 */
features :: fn() -> files.Features {
    return files.Features.{atomic_replace = true, transactions = true, snapshots = true, change_cursors = true}
}

/**
 * Answer a Sync: commit what's changed, and answer once it's durable.
 *
 * @param server The server, whose volume's dirty nodes are written and its record committed, each waited for; commit_at
 *     is cleared.
 * @return Whether it's committed; false after any failed commit.
 */
synced :: fn(server: ptr[mut Server]) -> bool {
    return commit(server)
}

// Directories

/**
 * Serve a directory connection's request, or a transaction's: one client request at a time, as serve_one asks.
 *
 * A path that runs through a link, outside a transaction and for an untyped open, is asked of the storage manager,
 * and the connection waits for its answer, with none now. On a transaction, opens, removes and renames are logged;
 * Begin, Replace, Grant, Links, Revoke and the snapshots' requests are answered Unsupported, and Link IsALink. Commit
 * and Abort are a transaction's only. Room is the container's, answered Unsupported. Snapshot, Snapshots and
 * OpenSnapshot are snapshots.hsc's, waited for. Lend takes a loan for the connection's work; Connect adds a connection
 * to the same directory, with no answer. A connection whose end fails is dropped.
 *
 * @param server The server, whose volume changes with what's asked; once its handled is set, no further request is
 *     read.
 * @param index The connection's slot, a Dir or a Transaction; one past them is left alone. Its loan, if it has one,
 *     runs the thread while a request is served.
 * @param into Where each request is read into, reused.
 */
serve_dir :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    volume :: server.volume
    loop {
        if server.handled {
            return void
        }
        match dir.receive_request(end, server.port, into, false) {
            case Received => received(server, index)
            case Empty => return void
            case Unsupported => {
                _ = dir.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        directory :: server.connections[index].object
        in_transaction :: server.connections[index].kind == .Transaction
        transaction :: server.connections[index].transaction
        // What's opened from a linked connection is linked too
        server.linking = server.connections[index].linked
        defer server.linking = false
        out := os.Outgoing.{}
        response :: os.begin[dir.Response](&out)
        response^ = .Unsupported
        match os.message_of[dir.Request](into)^ {
            case Lend(budget) => {
                lend(server, index, budget)
                response^ = .Done
            }
            case OpenFile(open) => {
                path :: path_of(into, open.path) or_else ""
                // A typed open stays on this volume: a link on its way is refused (IsALink), not followed untyped
                typed :: !untyped(open.schema)
                followed :: if in_transaction || typed { Followed.Local }
                    else { follow(server, index, directory, path, links.Opening.{kind = .File, creation = open.creation}) }
                failed : files.FileError? = null
                match followed {
                    case Asked => return void
                    case Failed(error) => failed = error
                    case Local => {}
                }
                if failed is_some {
                    response^ = .Failed(failed or_else .Unavailable)
                }
                else if in_transaction && typed {
                    // A transaction's log keeps no types yet (decisions/0108)
                    response^ = .Failed(.WrongType)
                }
                else if in_transaction {
                    response^ = open_in_transaction(server, transaction, path, open.creation)
                }
                else {
                    match open_file_object(volume, directory, path, open.creation, open.schema) {
                        case Ok(object) => {
                            match open_connection[file.File](server, .File, object, false, path) {
                                case Some(made) => response^ = .OpenedFile(made)
                                case None => response^ = .Failed(.NoSpace)
                            }
                        }
                        case Error(error) => response^ = .Failed(file_error(error))
                    }
                }
            }
            case OpenReadOnlyFile(at) => {
                path :: path_of(into, at) or_else ""
                match follow(server, index, directory, path, links.Opening.{kind = .ReadOnlyFile, creation = .Existing}) {
                    case Asked => return void
                    case Failed(error) => response^ = .Failed(error)
                    case Local => response^ = read_only_open(server, directory, path)
                }
            }
            case OpenDirectory(open) => {
                path :: path_of(into, open.path) or_else ""
                match follow(server, index, directory, path, links.Opening.{kind = .Directory, creation = .Existing, create = open.create}) {
                    case Asked => return void
                    case Failed(error) => response^ = .Failed(error)
                    case Local => {
                        match open_directory_object(volume, directory, path, open.create) {
                            case Ok(object) => {
                                match open_connection[dir.Dir](server, .Dir, object, false, path) {
                                    case Some(made) => response^ = .OpenedDirectory(made)
                                    case None => response^ = .Failed(.NoSpace)
                                }
                            }
                            case Error(error) => response^ = .Failed(file_error(error))
                        }
                    }
                }
            }
            case List(cursor) => {
                match listing_of(volume, directory, cursor, "", &out) {
                    case Ok(listed) => {
                        match listed {
                            case Some(listing) => response^ = .Listed(listing)
                            case None => response^ = .End
                        }
                    }
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case Info => response^ = .Described(info_of(&out, .Directory, 0, name_of(&server.connections[index])))
            case Remove(at) => {
                path :: path_of(into, at) or_else ""
                response^ = .Done
                if in_transaction {
                    if !note_versions(server, transaction, path) || !log_op(server, transaction, .Remove, 0, 0, path, "", nothing()) {
                        response^ = .Failed(.NoSpace)
                    }
                }
                else {
                    match removed(server, directory, path) {
                        case Some(error) => response^ = .Failed(error)
                        case None => {}
                    }
                }
            }
            case Rename(rename) => {
                from :: path_of(into, rename.from) or_else ""
                to :: path_of(into, rename.to) or_else ""
                response^ = .Done
                if in_transaction {
                    if !note_versions(server, transaction, from) || !note_versions(server, transaction, to)
                        || !log_op(server, transaction, .Rename, 0, 0, from, to, nothing()) {
                        response^ = .Failed(.NoSpace)
                    }
                }
                else {
                    match moved(volume, directory, from, to) {
                        case Some(error) => response^ = .Failed(file_error(error))
                        case None => {}
                    }
                }
            }
            case Narrow => {
                match open_connection[read_only_dir.ReadOnlyDir](server, .ReadOnlyDir, directory, true, name_of(&server.connections[index])) {
                    case Some(made) => response^ = .Narrowed(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            case Select(pattern) => {
                text :: path_of(into, pattern) or_else ""
                match open_connection[file_set.FileSet](server, .FileSet, directory, false, text) {
                    case Some(made) => response^ = .Selected(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            case Sync => response^ = if synced(server) { dir.Response.Done } else { dir.Response.Failed(.DeviceError) }
            case Features => response^ = .Supports(features())
            // A volume's room is its container's, which it doesn't know: Unsupported
            case Room => {}
            case Connect(connection) => {
                _ = add(server, .Dir, connection.end, directory, false, name_of(&server.connections[index]))
                continue
            }
            case Begin(memory) => {
                if in_transaction {
                    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
                }
                else {
                    response^ = transaction_connection(server, directory, memory, name_of(&server.connections[index]))
                }
            }
            case Commit => {
                if in_transaction {
                    response^ = commit_transaction(server, transaction)
                }
            }
            case Abort => {
                if in_transaction {
                    reset(server, transaction)
                    response^ = .Done
                }
            }
            case Replace(at) => {
                if !in_transaction {
                    response^ = replacement_of(server, directory, path_of(into, at) or_else "")
                }
            }
            case Changes(cursor) => response^ = changes_of(server, directory, cursor, &out)
            case Grant(granting) => {
                if !in_transaction {
                    response^ = grant_of(server, index, directory, path_of(into, granting.path) or_else "", granting.write)
                }
            }
            case Link(linking) => {
                if in_transaction || server.connections[index].linked {
                    _ = slop_os.handle_close(cast[slop_os.Handle](linking.grant.end))
                    response^ = .Failed(if in_transaction { files.FileError.IsALink } else { files.FileError.ReadOnly })
                }
                else {
                    match begin_link(server, index, directory, path_of(into, linking.path) or_else "", linking.grant) {
                        case Some(error) => response^ = .Failed(error)
                        case None => return void
                    }
                }
            }
            case Links(cursor) => {
                if !in_transaction {
                    response^ = issued_link(server, index, directory, cursor, &out)
                }
            }
            case Revoke(number) => {
                if !in_transaction {
                    response^ = revoked(server, index, directory, number)
                }
            }
            // Snapshots, of the whole volume (snapshots.hsc); none on a transaction
            case Snapshot => {
                if !in_transaction {
                    response^ = snapshot_answer(server, index, .Snapshot, u8.[], &out)
                }
            }
            case Snapshots(cursor) => {
                if !in_transaction {
                    response^ = snapshot_answer(server, index, .Snapshots(cursor), u8.[], &out)
                }
            }
            case OpenSnapshot(at) => {
                if !in_transaction {
                    response^ = snapshot_answer(server, index, .OpenSnapshot(at), os.items(into, at), &out)
                }
            }
        }
        _ = dir.send_response(end, server.port, &out)
    }
}

/**
 * Move a file, a directory or a link, durable with the volume's next commit.
 *
 * @param volume The volume, changed in its cache; durable only with its next commit.
 * @param directory The directory object both paths are beneath.
 * @param from Where it is.
 * @param to Where it goes; the directory that holds it must exist.
 * @return Null once it's moved; why not, otherwise.
 */
moved :: fn(volume: ptr[mut slopfs.Volume], directory: u64, from: string, to: string) -> slopfs.Error? {
    source := slopfs.Leaf.{}
    match slopfs.leaf_of(volume, directory, from) {
        case Ok(leaf) => source = leaf
        case Error(error) => return error
    }
    match slopfs.leaf_of(volume, directory, to) {
        case Ok(target) => {
            match slopfs.rename(volume, source.directory, source.name, target.directory, target.name) {
                case Ok => return null
                case Error(error) => return error
            }
        }
        case Error(error) => return error
    }
}

/**
 * Tell whether a read_only_dir request is Select or Changes, which a snapshot's directory answers Unsupported.
 *
 * @param request The request, only read.
 * @return True for Select and Changes.
 */
is_set_or_changes :: fn(request: read_only_dir.Request) -> bool {
    return match request {
        case Select(_) => true
        case Changes(_) => true
        case _ => false
    }
}

/**
 * Open a file read only, for a dir, a read_only_dir or a file set.
 *
 * @param server The server, whose volume, or the snapshot its pasting names, is read, and which a ReadOnlyFile
 *     connection is added to.
 * @param directory The directory object the path is beneath.
 * @param path The file's path; "" is refused with InvalidPath.
 * @return OpenedReadOnlyFile with the connection's other end, which the caller sends; Failed with IsADirectory,
 *     IsALink, NoSpace without a slot, or why it couldn't be found.
 */
read_only_open :: fn(server: ptr[mut Server], directory: u64, path: string) -> dir.Response {
    if path.count == 0 {
        return .Failed(.InvalidPath)
    }
    match slopfs.resolve(volume_of_past(server, server.pasting), directory, path) {
        case Ok(object) => {
            match slopfs.info(volume_of_past(server, server.pasting), object) {
                case Ok(info) => {
                    if info.kind == .Directory {
                        return .Failed(.IsADirectory)
                    }
                    if info.kind == .Link {
                        return .Failed(.IsALink)
                    }
                }
                case Error(error) => return .Failed(file_error(error))
            }
            match open_connection[read_only_file.ReadOnlyFile](server, .ReadOnlyFile, object, true, path) {
                case Some(made) => return .OpenedReadOnlyFile(made)
                case None => return .Failed(.NoSpace)
            }
        }
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Serve a read-only directory connection's request: files and directories opened read only, through links too,
 * listings, sets, change cursors, and Connect, which adds a connection with no answer. A connection whose end fails
 * is dropped.
 *
 * @param server The server, whose volume nothing here changes; once its handled is set, no further request is read.
 * @param index The connection's slot, a ReadOnlyDir; one past them is left alone. Its loan, if it has one, runs the
 *     thread while a request is served.
 * @param into Where each request is read into, reused.
 */
serve_read_only_dir :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    past :: server.connections[index].past
    volume :: volume_of_past(server, past)
    loop {
        if server.handled {
            return void
        }
        match read_only_dir.receive_request(end, server.port, into, false) {
            case Received => received(server, index)
            case Empty => return void
            case Unsupported => {
                _ = read_only_dir.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        directory :: server.connections[index].object
        server.linking = server.connections[index].linked
        defer server.linking = false
        // What's opened from a snapshot is in it too
        server.pasting = past
        defer server.pasting = 0
        out := os.Outgoing.{}
        response :: os.begin[read_only_dir.Response](&out)
        response^ = .Unsupported
        request :: os.message_of[read_only_dir.Request](into)^
        // A snapshot has no sets and no changes to list
        if past != 0 && is_set_or_changes(request) {
            _ = read_only_dir.send_response(end, server.port, &out)
            continue
        }
        match request {
            case OpenReadOnlyFile(at) => {
                path :: path_of(into, at) or_else ""
                match follow(server, index, directory, path, links.Opening.{kind = .ReadOnlyFile, creation = .Existing}) {
                    case Asked => return void
                    case Failed(error) => response^ = .Failed(error)
                    case Local => {
                        match read_only_open(server, directory, path) {
                            case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
                            case Failed(error) => response^ = .Failed(error)
                            case _ => {}
                        }
                    }
                }
            }
            case OpenDirectory(at) => {
                path :: path_of(into, at) or_else ""
                match follow(server, index, directory, path, links.Opening.{kind = .ReadOnlyDirectory, creation = .Existing}) {
                    case Asked => return void
                    case Failed(error) => response^ = .Failed(error)
                    case Local => {
                        match open_directory_object(volume, directory, path, false) {
                            case Ok(object) => {
                                match open_connection[read_only_dir.ReadOnlyDir](server, .ReadOnlyDir, object, true, path) {
                                    case Some(made) => response^ = .OpenedDirectory(made)
                                    case None => response^ = .Failed(.NoSpace)
                                }
                            }
                            case Error(error) => response^ = .Failed(file_error(error))
                        }
                    }
                }
            }
            case List(cursor) => {
                match listing_of(volume, directory, cursor, "", &out) {
                    case Ok(listed) => {
                        match listed {
                            case Some(listing) => response^ = .Listed(listing)
                            case None => response^ = .End
                        }
                    }
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case Info => response^ = .Described(info_of(&out, .Directory, 0, name_of(&server.connections[index])))
            case Select(pattern) => {
                text :: path_of(into, pattern) or_else ""
                match open_connection[file_set.FileSet](server, .FileSet, directory, true, text) {
                    case Some(made) => response^ = .Selected(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            case Features => response^ = .Supports(features())
            case Connect(connection) => {
                _ = add(server, .ReadOnlyDir, connection.end, directory, true, name_of(&server.connections[index]))
                continue
            }
            case Changes(cursor) => {
                match changes_of(server, directory, cursor, &out) {
                    case Changed(change) => response^ = .Changed(change)
                    case UpToDate(next) => response^ = .UpToDate(next)
                    case Resync(next) => response^ = .Resync(next)
                    case Failed(error) => response^ = .Failed(error)
                    case _ => {}
                }
            }
        }
        _ = read_only_dir.send_response(end, server.port, &out)
    }
}

/**
 * Serve a file set's request: its files listed, and opened by a name of one component matching its pattern, NotFound
 * for another, and ReadOnly for a read-only set's OpenFile. Connect adds a connection with no answer. A connection
 * whose end fails is dropped.
 *
 * @param server The server; a writable set's OpenFile can make or cut a file in its volume, durable with its next
 *     commit.
 * @param index The connection's slot, a FileSet, whose name is its pattern; one past them is left alone. Its loan, if
 *     it has one, runs the thread while a request is served.
 * @param into Where each request is read into, reused.
 */
serve_file_set :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    volume :: server.volume
    loop {
        if server.handled {
            return void
        }
        match file_set.receive_request(end, server.port, into, false) {
            case Received => received(server, index)
            case Empty => return void
            case Unsupported => {
                _ = file_set.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        connection :: server.connections[index]
        pattern :: name_of(&connection)
        server.linking = connection.linked
        defer server.linking = false
        out := os.Outgoing.{}
        response :: os.begin[file_set.Response](&out)
        response^ = .Unsupported
        match os.message_of[file_set.Request](into)^ {
            case List(cursor) => {
                match listing_of(volume, connection.object, cursor, pattern, &out) {
                    case Ok(listed) => {
                        match listed {
                            case Some(listing) => response^ = .Listed(listing)
                            case None => response^ = .End
                        }
                    }
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case OpenFile(open) => {
                name :: path_of(into, open.name) or_else ""
                if connection.read_only {
                    response^ = .Failed(.ReadOnly)
                }
                else if !in_set(pattern, name) {
                    response^ = .Failed(.NotFound)
                }
                else {
                    match open_file_object(volume, connection.object, name, open.creation, no_schema()) {
                        case Ok(object) => {
                            match open_connection[file.File](server, .File, object, false, name) {
                                case Some(made) => response^ = .OpenedFile(made)
                                case None => response^ = .Failed(.NoSpace)
                            }
                        }
                        case Error(error) => response^ = .Failed(file_error(error))
                    }
                }
            }
            case OpenReadOnlyFile(at) => {
                name :: path_of(into, at) or_else ""
                if !in_set(pattern, name) {
                    response^ = .Failed(.NotFound)
                }
                else {
                    match read_only_open(server, connection.object, name) {
                        case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
                        case Failed(error) => response^ = .Failed(error)
                        case _ => {}
                    }
                }
            }
            case Info => response^ = .Described(info_of(&out, .Directory, 0, pattern))
            case Connect(other) => {
                _ = add(server, .FileSet, other.end, connection.object, connection.read_only, pattern)
                continue
            }
        }
        _ = file_set.send_response(end, server.port, &out)
    }
}

/**
 * Tell whether a name is one of a set's.
 *
 * @param pattern The set's pattern, as it was opened: '*' matches any run of bytes, '?' any one byte, and any other
 *     byte only itself, case and all.
 * @param name A name a client gave, any bytes; one with a '/' is never in a set.
 * @return Whether it's one component, not empty, matching the pattern exactly.
 */
in_set :: fn(pattern: string, name: string) -> bool {
    for character in name {
        if character == '/' {
            return false
        }
    }
    return name.count != 0 && file_set.matches(pattern, name, same_byte)
}

// Files

/**
 * Take a file connection's buffer: its client's memory, kept to copy through, in place of any before. It's never
 * mapped, so the client ending, or taking it back, fails a transfer rather than the server (decisions/0098, 0181's F6).
 *
 * @param connection The file connection, whose buffer before, if any, is let go of first, even when memory is refused.
 * @param memory The memory, which the server takes over: kept, or closed when it's refused.
 * @return Null once it's kept; NoBuffer if it's empty, its size can't be had, or it's larger than MAX_BUFFER_BYTES.
 */
use_buffer :: fn(connection: ptr[mut Connection], memory: slop_os.Memory) -> files.FileError? {
    release_buffer(connection)
    size :: slop_os.memory_size(memory) or_else 0
    if size == 0 || size > MAX_BUFFER_BYTES {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return files.FileError.NoBuffer
    }
    connection.buffer_bytes = size
    connection.buffer_memory = memory
    return null
}

/**
 * Tell whether a transfer's bytes are all in a connection's buffer.
 *
 * @param connection The connection, read for its buffer; one without a buffer fits nothing.
 * @param transfer The transfer a client asked for, its buffer_offset and count in bytes; its offset in the file isn't
 *     checked.
 * @return Whether it has a buffer and the transfer's offset and count, in bytes, are inside it.
 */
fits :: fn(connection: ptr[Connection], transfer: files.Transfer) -> bool {
    return connection.buffer_bytes != 0 && cast[u64](transfer.buffer_offset) + cast[u64](transfer.count) <= connection.buffer_bytes
}

/**
 * Copy a transfer's bytes out of a connection's buffer, onto the heap, as the client has them now.
 *
 * @param connection The connection, whose buffer is read through memory_read.
 * @param transfer The transfer, which fits.
 * @return The bytes, transfer.count of them, which the caller gives back with runtime.free_array; empty for a count of
 *     0.
 * @error NoMemory The server hadn't the memory for them.
 * @error NoBuffer The buffer couldn't be read: its client ended, or the memory's gone.
 */
client_bytes :: fn(connection: ptr[Connection], transfer: files.Transfer) -> Result[mut u8[], files.FileError] {
    bytes, error :: runtime.new_array(u8, cast[usize](transfer.count))
    if error != null {
        return .Error(.NoMemory)
    }
    if slop_os.memory_read(connection.buffer_memory, cast[u64](transfer.buffer_offset), bytes) is_error {
        runtime.free_array(bytes)
        return .Error(.NoBuffer)
    }
    return .Ok(bytes)
}

/**
 * Read a file into its connection's buffer: onto the heap, then copied into the buffer through memory_write.
 *
 * @param server The server, whose volume is read; nothing's changed.
 * @param connection The file's connection, read only: its object is read into its buffer, which must hold the
 *     transfer, or it's NoBuffer.
 * @param transfer Where to read from in the file and to in the buffer, and how many bytes.
 * @return How many bytes were read: fewer than asked only at the file's end, 0 past it.
 * @error NoBuffer The connection has no buffer, the transfer doesn't fit in it, or it couldn't be written: its client
 *     ended, or the memory's gone.
 * @error NoMemory The server hadn't the memory to read it into.
 * @error NotFound The file is gone.
 * @error DeviceError A block couldn't be read.
 * @error Corrupt The tree, or the file's chunk, couldn't be read as one.
 */
read_file :: fn(server: ptr[mut Server], connection: ptr[Connection], transfer: files.Transfer) -> Result[u32, files.FileError] {
    if !fits(connection, transfer) {
        return .Error(.NoBuffer)
    }
    bytes, error :: runtime.new_array(u8, cast[usize](transfer.count))
    if error != null {
        return .Error(.NoMemory)
    }
    defer runtime.free_array(bytes)
    count := cast[usize](0)
    match slopfs.read(volume_of_past(server, connection.past), connection.object, transfer.offset, bytes) {
        case Ok(read) => count = read
        case Error(failure) => return .Error(file_error(failure))
    }
    available :: bytes.count
    if count > available {
        return .Error(.Corrupt)
    }
    if slop_os.memory_write(connection.buffer_memory, cast[u64](transfer.buffer_offset), bytes[0..<count]) is_error {
        return .Error(.NoBuffer)
    }
    return .Ok(cast[u32](count))
}

/**
 * Describe a file connection's file, with its type.
 *
 * @param server The server, whose volume is read; nothing's changed.
 * @param connection The file's connection, read only: its object is described under its name.
 * @param out The answer being built, which the name is appended to.
 * @return Its kind, size in bytes, name and schema hash, all zeros for none.
 * @error NotFound The file is gone.
 * @error DeviceError A block couldn't be read.
 * @error Corrupt The tree couldn't be read as one.
 */
file_info :: fn(server: ptr[mut Server], connection: ptr[Connection], out: ptr[mut os.Outgoing]) -> Result[files.Info, files.FileError] {
    match slopfs.info(volume_of_past(server, connection.past), connection.object) {
        case Ok(info) => {
            described := info_of(out, .File, info.size, name_of(connection))
            described.schema = info.schema
            return .Ok(described)
        }
        case Error(error) => return .Error(file_error(error))
    }
}

/**
 * Serve a file connection's request, a transaction's file's, or a replacement's.
 *
 * Writes go to the tree, durable with the next commit, a second after the last change or at a Sync, which commits at
 * once. A transaction's file's writes and sizes are logged, and its Sync is Done at once; reads see the file as it is.
 * A replacement's Install puts it in place. A connection whose end fails is dropped.
 *
 * @param server The server, whose volume a file's writes and sizes change, and a replacement's Install; once its
 *     handled is set, no further request is read.
 * @param index The connection's slot, a File, a TransactionFile or a Replacement; one past them is left alone. Its
 *     loan, if it has one, runs the thread while a request is served.
 * @param into Where each request is read into, reused.
 */
serve_file :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        if server.handled {
            return void
        }
        match file.receive_request(end, server.port, into, false) {
            case Received => received(server, index)
            case Empty => return void
            case Unsupported => {
                _ = file.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        connection :: &server.connections[index]
        logged :: connection.kind == .TransactionFile
        server.linking = connection.linked
        defer server.linking = false
        out := os.Outgoing.{}
        response :: os.begin[file.Response](&out)
        response^ = .Unsupported
        match os.message_of[file.Request](into)^ {
            case UseBuffer(memory) => response^ = if use_buffer(connection, memory) is_none { file.Response.Done } else { file.Response.Failed(.NoBuffer) }
            case Read(transfer) => {
                if logged && connection.object == 0 {
                    response^ = .Transferred(0)
                }
                else {
                    match read_file(server, connection, transfer) {
                        case Ok(count) => response^ = .Transferred(count)
                        case Error(error) => response^ = .Failed(error)
                    }
                }
            }
            case Write(transfer) => {
                if !fits(connection, transfer) {
                    response^ = .Failed(.NoBuffer)
                }
                else {
                    match client_bytes(connection, transfer) {
                        case Error(error) => response^ = .Failed(error)
                        case Ok(bytes) => {
                            defer runtime.free_array(bytes)
                            if logged {
                                response^ = if log_op(server, connection.transaction, .Write, 0, transfer.offset, name_of(connection), "", bytes) {
                                    file.Response.Transferred(transfer.count)
                                }
                                else {
                                    file.Response.Failed(.NoSpace)
                                }
                            }
                            else {
                                match slopfs.write(server.volume, connection.object, transfer.offset, bytes) {
                                    case Ok => response^ = .Transferred(transfer.count)
                                    case Error(error) => response^ = .Failed(file_error(error))
                                }
                            }
                        }
                    }
                }
            }
            case SetSize(size) => {
                if logged {
                    response^ = if log_op(server, connection.transaction, .SetSize, 0, size, name_of(connection), "", nothing()) { file.Response.Done }
                        else { file.Response.Failed(.NoSpace) }
                }
                else {
                    match slopfs.set_size(server.volume, connection.object, size) {
                        case Ok => response^ = .Done
                        case Error(error) => response^ = .Failed(file_error(error))
                    }
                }
            }
            case Info => {
                if logged && connection.object == 0 {
                    response^ = .Described(info_of(&out, .File, 0, name_of(connection)))
                }
                else {
                    match file_info(server, connection, &out) {
                        case Ok(info) => response^ = .Described(info)
                        case Error(error) => response^ = .Failed(error)
                    }
                }
            }
            case Sync => response^ = if logged || synced(server) { file.Response.Done } else { file.Response.Failed(.DeviceError) }
            case Narrow => {
                if connection.kind == .File {
                    match open_connection[read_only_file.ReadOnlyFile](server, .ReadOnlyFile, connection.object, true, name_of(connection)) {
                        case Some(made) => response^ = .Narrowed(made)
                        case None => response^ = .Failed(.NoSpace)
                    }
                }
            }
            case Connect(other) => {
                if connection.kind == .File {
                    _ = add(server, .File, other.end, connection.object, false, name_of(connection))
                }
                else {
                    _ = slop_os.handle_close(cast[slop_os.Handle](other.end))
                }
                continue
            }
            case Install => {
                if connection.kind == .Replacement {
                    response^ = .Done
                    match installed(server, index) {
                        case Some(error) => response^ = .Failed(error)
                        case None => {}
                    }
                }
            }
        }
        _ = file.send_response(end, server.port, &out)
    }
}

/**
 * Serve a read-only file connection's request: UseBuffer, Read, Info, and Connect, which adds a connection with no
 * answer. A connection whose end fails is dropped.
 *
 * @param server The server, whose volume nothing here changes; once its handled is set, no further request is read.
 * @param index The connection's slot, a ReadOnlyFile; one past them is left alone. Its loan, if it has one, runs the
 *     thread while a request is served.
 * @param into Where each request is read into, reused.
 */
serve_read_only_file :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        if server.handled {
            return void
        }
        match read_only_file.receive_request(end, server.port, into, false) {
            case Received => received(server, index)
            case Empty => return void
            case Unsupported => {
                _ = read_only_file.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        connection :: &server.connections[index]
        server.linking = connection.linked
        defer server.linking = false
        server.pasting = connection.past
        defer server.pasting = 0
        out := os.Outgoing.{}
        response :: os.begin[read_only_file.Response](&out)
        response^ = .Unsupported
        match os.message_of[read_only_file.Request](into)^ {
            case UseBuffer(memory) => response^ = if use_buffer(connection, memory) is_none { read_only_file.Response.Done }
                else { read_only_file.Response.Failed(.NoBuffer) }
            case Read(transfer) => {
                match read_file(server, connection, transfer) {
                    case Ok(count) => response^ = .Transferred(count)
                    case Error(error) => response^ = .Failed(error)
                }
            }
            case Info => {
                match file_info(server, connection, &out) {
                    case Ok(info) => response^ = .Described(info)
                    case Error(error) => response^ = .Failed(error)
                }
            }
            case Connect(other) => {
                _ = add(server, .ReadOnlyFile, other.end, connection.object, true, name_of(connection))
                continue
            }
        }
        _ = read_only_file.send_response(end, server.port, &out)
    }
}

// Encryption (roadmap 8e)

/**
 * Wait for the storage manager's Unlock with a passphrase that unwraps an encrypted volume's keys, before anything's
 * served; each that doesn't is answered WrongKey, and the next waited for. A new volume's keys are made with the first
 * passphrase given. Other requests are refused meanwhile.
 *
 * @param server The server, before it serves anything: its described record says whether a new volume's keys are made,
 *     and its container service is asked for, or given, the key records.
 * @param end The storage manager's control end, read here with a port of its own.
 * @return The keys, on the heap, the volume's from then on; null if the storage manager goes, or a port or keys
 *     couldn't be made.
 */
wait_for_unlock :: fn(server: ptr[mut Server], end: slop_os.Channel) -> ptr[mut slopfs.Keys]? {
    startup :: slop_os.startup_block()
    port :: os.port_for(startup.budget, end) or_return null
    defer _ = slop_os.handle_close(cast[slop_os.Handle](port))
    into := os.Incoming.{}
    loop {
        match volume_protocol.receive_request(end, port, &into, true) {
            case Received => {}
            case Unsupported => {
                _ = volume_protocol.answer_unsupported(end, port)
                continue
            }
            case Failed(error) => return null
            case _ => return null
        }
        response : volume_protocol.Response = .Failed
        keys :: slopfs.new_keys(.None) or_return null
        unlocked := false
        match os.message_of[volume_protocol.Request](&into)^ {
            case Unlock(given) => {
                // A volume made with nothing in it yet (decisions/0141) has no keys to unwrap: they're made here
                unlocked = if slopfs.is_unfilled(&server.described.record) { make_first_keys(server, os.items(&into, given), keys) }
                    else { unlock_keys(server, os.items(&into, given), keys) }
                response = if unlocked { .Unlocked } else { .WrongKey }
            }
            case Rotate => response = .Failed
            case Rekey(_) => response = .Failed
            case Commit => response = .Failed
            case IssueTo(_) => response = .Refused(.Unavailable)
            case OpenIssued(_) => response = .Refused(.Unavailable)
        }
        out := os.Outgoing.{}
        made :: os.begin[volume_protocol.Response](&out)
        made^ = response
        _ = volume_protocol.send_response(end, port, &out)
        if unlocked {
            log_line.write(server.log, "volume_server: volume % unlocked", server.described.id)
            return keys
        }
        slopfs.free_keys(keys)
    }
}

/**
 * Make a new sealed volume's keys (decisions/0141): its key made and wrapped by a passphrase, and its first generation
 * started, the records given the container service to keep, which can't open the volume without the passphrase.
 *
 * @param server The server, whose described volume is unfilled and encrypted, its cipher Aes256Gcm or else
 *     ChaCha20Poly1305; its container service is asked to keep the new wrap and first generation, each waited for.
 * @param passphrase The passphrase's bytes, as Unlock gave them; read, not kept.
 * @param keys Where the keys are made, new; the caller frees them with free_keys if this fails.
 * @return Whether they were made and kept by the container service.
 */
make_first_keys :: fn(server: ptr[mut Server], passphrase: u8[], keys: ptr[mut slopfs.Keys]) -> bool {
    cipher :: server.described.record.cipher
    keys.cipher = if cipher == cast[u8](slopfs.Cipher.Aes256Gcm) { slopfs.Cipher.Aes256Gcm } else { slopfs.Cipher.ChaCha20Poly1305 }
    made :: match slopfs.first_keys(keys, passphrase, slopfs.MADE_PASSPHRASE, server.described.container, server.described.id,
        server.described.transaction) {
        case Ok(first) => first
        case Error(error) => return false
    }
    match ask(server, .AddWrap(container.AddedWrap.{index = 0, record = made.wrap})) {
        case Done => {}
        case _ => return false
    }
    match ask(server, .AddGeneration(container.AddedGeneration.{number = made.number, record = made.generation})) {
        case Done => {}
        case _ => return false
    }
    log_line.write(server.log, "volume_server: volume % given its first keys", server.described.id)
    return true
}

/**
 * Unwrap the volume's keys with a passphrase, from the wrap and generation records the container service keeps.
 *
 * @param server The server, whose container service is asked for up to 16 wrap records and every generation record, one
 *     at a time.
 * @param passphrase The passphrase's bytes, read, not kept; a wrong one gives false, and isn't logged.
 * @param keys Where the keys go, new; for free_keys either way.
 * @return Whether they were unwrapped; false if it isn't the passphrase, or the records can't be read, which is logged.
 */
unlock_keys :: fn(server: ptr[mut Server], passphrase: u8[], keys: ptr[mut slopfs.Keys]) -> bool {
    wraps : slopfs.WrapRecord[..]
    defer runtime.array_free(&wraps)
    for index in 0..<cast[u64](16) {
        match ask(server, .WrapAt(index)) {
            case Wrap(record) => {
                if runtime.array_try_add(&wraps, record) != null {
                    return false
                }
            }
            case NoMore => break
            case _ => return false
        }
    }
    generations : slopfs.NumberedGeneration[..]
    defer runtime.array_free(&generations)
    if !listed_generations(server, &generations) {
        return false
    }
    match slopfs.unlock(server.described.container, key_owner(server), server.described.record, wraps, generations, passphrase, keys) {
        case Ok => return true
        case Error(error) => {
            if error != .WrongKey {
                log_line.write(server.log, "volume_server: volume %'s keys don't open: %", server.described.id, error)
            }
            return false
        }
    }
}

/**
 * Answer the storage manager's requests on the volume protocol, once the volume is served, until it has none.
 *
 * Unlock checks the passphrase again, for whoever asks the storage manager for the volume again; NotEncrypted for a
 * plain volume. Commit commits what's waiting. A connection whose end fails is dropped.
 *
 * @param server The server, whose volume Commit and Rotate commit, and Rotate gives a new key generation; IssueTo and
 *     OpenIssued are links.hsc's.
 * @param index The control connection's slot.
 * @param into Where each request is read into, reused.
 */
serve_control :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match volume_protocol.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = volume_protocol.answer_unsupported(end, server.port)
                continue
            }
            case _ => {
                drop(server, index)
                return void
            }
        }
        response : volume_protocol.Response = .NotEncrypted
        out := os.Outgoing.{}
        made :: os.begin[volume_protocol.Response](&out)
        match os.message_of[volume_protocol.Request](into)^ {
            case Unlock(given) => {
                if server.volume.tree.keys is_some {
                    // Unlocked already: the passphrase checked, for whoever asks the storage manager for the volume again
                    match slopfs.new_keys(.None) {
                        case Ok(checked) => {
                            response = if unlock_keys(server, os.items(into, given), checked) { .Unlocked } else { .WrongKey }
                            slopfs.free_keys(checked)
                        }
                        case Error(error) => response = .Failed
                    }
                }
            }
            case Rotate => response = rotate(server)
            case Rekey(given) => response = rekey(server, os.items(into, given))
            case Commit => {
                response = if server.described.read_only || !server.volume.dirty || commit(server) { .Committed } else { .Failed }
            }
            case IssueTo(to) => {
                response = if server.described.read_only { volume_protocol.Response.Refused(.ReadOnly) } else { issue_to(server, to) }
            }
            case OpenIssued(asked) => {
                bytes :: os.items(into, asked.path)
                if bytes.count > files.PATH_BYTES {
                    response = .Refused(.InvalidPath)
                }
                else {
                    response = open_issued(server, asked, if bytes.count == 0 { "" } else { string_of(&bytes[0], bytes.count) })
                }
            }
        }
        made^ = response
        _ = volume_protocol.send_response(end, server.port, &out)
    }
}

/**
 * Start a new key generation: made and wrapped here, its record kept by the container service, and what's written
 * from now on sealed with it. What's changed is committed first, so the generation begins with a transaction of its
 * own.
 *
 * @param server The server, whose volume is served: what's dirty is committed first, and its keys' current generation
 *     changes.
 * @return Rotated with the new generation's number, after the newest of the key records', which a clone shares with
 *     its origin; NotEncrypted for a plain volume; Failed for a snapshot, a commit that failed, or a generation that
 *     couldn't be made or kept, the one before still sealing.
 */
rotate :: fn(server: ptr[mut Server]) -> volume_protocol.Response {
    keys :: server.volume.tree.keys or_return .NotEncrypted
    if server.described.read_only {
        return .Failed
    }
    if server.volume.dirty && !commit(server) {
        return .Failed
    }
    previous :: keys.current
    // Numbered after the newest of the key records', which a clone shares with its origin
    generations : slopfs.NumberedGeneration[..]
    defer runtime.array_free(&generations)
    if !listed_generations(server, &generations) {
        return .Failed
    }
    newest : u32 = 0
    for each in generations {
        if each.number > newest {
            newest = each.number
        }
    }
    keys.current = newest
    record := slopfs.GenerationRecord.{}
    match slopfs.start_generation(keys, server.nodes.transaction, server.described.container, key_owner(server)) {
        case Some(made) => record = made
        case None => {
            keys.current = previous
            return .Failed
        }
    }
    match ask(server, .AddGeneration(container.AddedGeneration.{number = keys.current, record = record})) {
        case Done => {
            log_line.write(server.log, "volume_server: volume % sealing with key generation %", server.described.id, keys.current)
            server.described.record.generation = cast[u32le](keys.current)
            return .Rotated(keys.current)
        }
        case _ => {
            slopfs.drop_generation(keys, previous)
            return .Failed
        }
    }
}

/**
 * List every key generation record the volume's key records hold, oldest first, across the gaps deleting old ones
 * leaves.
 *
 * @param server The server, whose container service is asked, one generation at a time.
 * @param found Where they're added, with context's allocator; the caller's to free either way.
 * @return Whether they were all listed; false if one couldn't be read or kept.
 */
listed_generations :: fn(server: ptr[mut Server], found: ptr[mut slopfs.NumberedGeneration[..]]) -> bool {
    number : u32 = 1
    loop {
        match ask(server, .GenerationFrom(number)) {
            case NumberedGeneration(each) => {
                if runtime.array_try_add(found, each) != null || each.number == 0xffffffff {
                    return false
                }
                number = each.number + 1
            }
            case NoMore => return true
            case _ => return false
        }
    }
}

/**
 * Give the volume a new volume key, wrapped by a new passphrase (decisions/0181's F5): what's changed committed first,
 * every generation's key wrapped again and a new generation made here, kept by the container service in place of the
 * key records there were, and committed before it's answered, so the old passphrase opens it no more once it says so.
 * Then what was written before is sealed again with the new generation, a step at a time (reseal_some).
 *
 * @param server The server, whose volume is served: what's dirty is committed, its keys take the new volume key and
 *     generation, and it starts sealing again.
 * @param passphrase The new passphrase's bytes, as Rekey gave them; read, not kept.
 * @return Rotated with the new generation, the floor; NotEncrypted for a plain volume; Failed for a snapshot, a
 *     clone, a commit that failed, or keys that couldn't be made again or kept, the old ones still opening it.
 */
rekey :: fn(server: ptr[mut Server], passphrase: u8[]) -> volume_protocol.Response {
    keys :: server.volume.tree.keys or_return .NotEncrypted
    if server.described.read_only || key_owner(server) != server.described.id {
        return .Failed
    }
    if server.volume.dirty && !commit(server) {
        return .Failed
    }
    generations : slopfs.NumberedGeneration[..]
    defer runtime.array_free(&generations)
    if !listed_generations(server, &generations) {
        return .Failed
    }
    made := slopfs.Rekeyed.{}
    defer slopfs.free_rekeyed(&made)
    if !slopfs.rekey(keys, generations, passphrase, slopfs.MADE_PASSPHRASE, server.nodes.transaction, server.described.container,
        server.described.id, &made) {
        log_line.write(server.log, "volume_server: volume %'s keys couldn't be made again", server.described.id)
        return .Failed
    }
    out := os.Outgoing.{}
    request :: os.begin[container.Request](&out)
    request^ = .Rekey(container.Rekeying.{wrap = made.wrap, generations = os.append(&out, made.generations[0..<made.generations.count]),
        number = made.added.number, added = made.record})
    into := os.Incoming.{}
    match ask_built(&server.own, &out, &into) {
        case Done => {}
        case _ => return .Failed
    }
    slopfs.apply_rekey(keys, &made)
    // Committed now, the new records with it, so the old passphrase opens nothing once this is answered
    server.volume.dirty = true
    if !commit(server) {
        return .Failed
    }
    // Its record names the new generation now, which a passphrase checked again is checked against
    server.described.record.generation = cast[u32le](made.added.number)
    server.resealing = made.added.number
    server.reseal_from = slopfs.Key.{}
    log_line.write(server.log, "volume_server: volume % given a new volume key, sealing with key generation %", server.described.id, made.added.number)
    return .Rotated(made.added.number)
}

/**
 * Go on with a new volume key's work on starting: sealing again, if its floor is still Sealing, from the start, which
 * only reads what's done already; or deleting the generations before it, if it's Sealed and nothing needs them now.
 *
 * @param server The server, whose volume is served, writable and unlocked; its resealing is set from its floor.
 */
resume_floor :: fn(server: ptr[mut Server]) {
    match ask(server, .KeyFloor) {
        case Floor(floor) => {
            if cast[u32](floor.state) == cast[u32](slopfs.FloorState.Sealing) {
                server.resealing = cast[u32](floor.floor)
                server.reseal_from = slopfs.Key.{}
                log_line.write(server.log, "volume_server: volume % goes on sealing again with key generation %", server.described.id, server.resealing)
            }
            else {
                drop_old(server)
            }
        }
        case _ => {}
    }
}

/**
 * Take a step of sealing the volume again with its floor, RESEAL_BLOCKS blocks, and commit it. Once the walk is done,
 * the floor is Sealed, and the generations before it deleted if nothing needs them.
 *
 * @param server The server, sealing again: its reseal_from advances, and its resealing is 0 once it's done or failed,
 *     which is logged.
 */
reseal_some :: fn(server: ptr[mut Server]) {
    floor :: server.resealing
    match slopfs.reseal_step(server.volume, floor, server.reseal_from, RESEAL_BLOCKS) {
        case Ok(next) => {
            if server.volume.dirty && !commit(server) {
                server.resealing = 0
                return void
            }
            match next {
                case Some(key) => server.reseal_from = key
                case None => {
                    server.resealing = 0
                    match ask(server, .SealedAgain(floor)) {
                        case Done => {
                            log_line.write(server.log, "volume_server: volume % sealed again with key generation %", server.described.id, floor)
                            drop_old(server)
                        }
                        case _ => log_line.write(server.log, "volume_server: volume % sealed again, but its floor wasn't kept", server.described.id)
                    }
                }
            }
        }
        case Error(error) => {
            server.resealing = 0
            log_line.write(server.log, "volume_server: volume % couldn't be sealed again: %", server.described.id, error)
        }
    }
}

/**
 * Delete the key generations before the volume's floor, if nothing needs them now, and have its keys forget them;
 * committed. Snapshots from before keep them until they're deleted, which deletes them then (the container service).
 *
 * @param server The server, whose volume is served, unlocked.
 */
drop_old :: fn(server: ptr[mut Server]) {
    match ask(server, .DropOldGenerations) {
        case Dropped(floor) => {
            match server.volume.tree.keys {
                case Some(keys) => _ = slopfs.forget_generations_below(keys, floor)
                case None => {}
            }
            server.volume.dirty = true
            _ = commit(server)
            log_line.write(server.log, "volume_server: volume % deleted its key generations before %", server.described.id, floor)
        }
        case _ => log_line.write(server.log, "volume_server: volume % keeps its key generations before its floor while a snapshot from before may need them",
            server.described.id)
    }
}

/**
 * Find whose key records the volume uses.
 *
 * @param server The server, read for its volume's ID and record.
 * @return The volume's ID, or a clone's origin's.
 */
key_owner :: fn(server: ptr[Server]) -> u64 {
    record := server.described.record
    return slopfs.key_owner_of(server.described.id, &record)
}
