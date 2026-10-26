/*
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
 */
package volume_server

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import file_set from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import slopfs from "../../slopfs"
import log_line from "../../log_line"
import block from "../../protocols/block"
import container from "../../protocols/container"
import volume_protocol from "../../protocols/volume"

MAX_CONNECTIONS :: 64
// The most bytes of a client's buffer mapped here
MAX_BUFFER_BYTES : u64 : 16 << 20
SECTORS_PER_BLOCK : u64 : 8
// How long after a change it's committed without a Sync
COMMIT_NANOSECONDS : u64 : 1000000000

Kind :: enum {
    Free,
    Dir,
    ReadOnlyDir,
    File,
    ReadOnlyFile,
    FileSet,
    // A dir connection in a transaction, its changes logged until Commit
    Transaction,
    // A file opened in a transaction, its writes logged too
    TransactionFile,
    // A new file from Replace, until it's installed
    Replacement,
    // The storage manager's, on the volume protocol
    Control,
}

// A connection: the object it's to, its informational name (a set's pattern), and a file's buffer, mapped here.
Connection :: struct {
    kind : Kind,
    end : slop_os.Channel,
    object : u64,
    read_only : bool,
    name : u8[files.PATH_BYTES],
    name_length : u32,
    buffer : u64,
    buffer_bytes : u64,
    buffer_memory : slop_os.Memory,
    // A transaction's index, for one in a transaction
    transaction : usize,
    // A replacement's directory, where it's installed under its name
    target : u64,
}

Server :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    // Its connection to the container service, for its volume
    container : slop_os.Channel,
    container_port : slop_os.Port,
    // Its block connection, through the container service, and its buffer
    blocks : slop_os.Channel,
    blocks_port : slop_os.Port,
    buffer : u64,
    buffer_bytes : u64,
    nodes : slopfs.Nodes,
    volume : ptr[mut slopfs.Volume],
    // What the volume server was told of its volume and container
    described : container.Described,
    // When what's changed is committed, without a Sync, or 0 when nothing has
    commit_at : u64,
    connections : Connection[MAX_CONNECTIONS],
    count : usize,
    added : bool,
    transactions : Transaction[MAX_TRANSACTIONS],
}

main :: fn(log: slop_os.DebugLog?, volume: os.Channel[container.Container], clients: os.Listener[dir.Dir],
    control: os.Listener[volume_protocol.Volume]) -> int {
    startup :: slop_os.startup_block()
    server := runtime.new(Server)
    server^ = Server.{log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE), container = volume.end}
    server.container_port = os.port_for(startup.budget, volume.end) or_return 1
    server.port = slop_os.port_create(startup.budget) or_return 1
    described := container.Described.{}
    match ask(server, .Describe) {
        case Described(made) => described = made
        case _ => return 2
    }
    match ask(server, .OpenBlocks) {
        case Blocks(made) => server.blocks = made.end
        case _ => return 3
    }
    server.blocks_port = os.port_for(startup.budget, server.blocks) or_return 3
    info := block.Info.{}
    match call(server, .Describe) {
        case Described(made) => info = made
        case _ => return 4
    }
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match call(server, .GetBuffer) {
        case Buffer(memory) => window = memory
        case _ => return 4
    }
    server.buffer_bytes = info.buffer_bytes
    server.buffer = runtime.reserve_addresses(cast[usize](info.buffer_bytes)) or_return 4
    slop_os.memory_map(window, startup.space, server.buffer, 0, info.buffer_bytes, read_write()) or_return 4
    device :: slopfs.Device.{context = cast[rawptr](server), block_count = info.block_count / SECTORS_PER_BLOCK, read = read_blocks,
        write = write_blocks, flush = no_flush}
    server.nodes = slopfs.Nodes.{device = device, transaction = described.transaction, space = cast[rawptr](server), allocate = allocate,
        release = release}
    server.described = described
    // An encrypted volume is served once it's unlocked
    keys : ptr[mut slopfs.Keys]? = null
    if described.record.cipher != cast[u8](slopfs.Cipher.None) {
        keys = wait_for_unlock(server, control.end) or_return 6
    }
    server.volume = slopfs.attach_volume(&server.nodes, device, described.id, described.record, keys)
    server.volume.tree.lineage = described.lineage
    if !described.read_only {
        server.volume.history_bytes = slopfs.HISTORY_BYTES
        // Nothing has anything open yet, so every orphan a crash left is given back
        swept :: slopfs.sweep_orphans(server.volume) or_else 0
        if swept > 0 {
            _ = commit(server)
        }
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
        now :: slop_os.clock_monotonic() or_else 0
        if server.volume.dirty && server.commit_at == 0 {
            server.commit_at = now + COMMIT_NANOSECONDS
        }
        if server.commit_at != 0 && now >= server.commit_at {
            _ = commit(server)
            continue
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(server.port, packets, if server.commit_at != 0 { server.commit_at } else { slop_os.NO_DEADLINE })
    }
}

read_write :: fn() -> slop_os.Protection {
    return cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
}

// The container service, a request at a time

ask :: fn(server: ptr[mut Server], request: container.Request) -> container.Response {
    out := os.Outgoing.{}
    made :: os.begin[container.Request](&out)
    made^ = request
    if container.send_request(server.container, server.container_port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match container.receive_response(server.container, server.container_port, &into, true) {
            case Received => return os.message_of[container.Response](&into)^
            case Failed(error) => return .Unsupported
            case _ => continue
        }
    }
}

// An extent for the volume's tree or a file's chunk, from the container service.
allocate :: fn(context: rawptr, blocks: u64, owner: u64) -> u64? {
    server :: cast[ptr[mut Server]](context)
    return match ask(server, .Allocate(blocks)) {
        case Allocated(first) => first
        case _ => null
    }
}

release :: fn(context: rawptr, address: u64, blocks: u64, owner: u64, birth: u64) {
    server :: cast[ptr[mut Server]](context)
    _ = ask(server, .Release(container.Released.{first = address, blocks = blocks, birth = birth}))
}

/*
 * What's changed made durable: the volume's dirty nodes written, every write done, then its record committed by the
 * container service. Whether it was; a failure is the volume's, and every later commit fails too.
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

call :: fn(server: ptr[mut Server], request: block.Request) -> block.Response {
    out := os.Outgoing.{}
    made :: os.begin[block.Request](&out)
    made^ = request
    if block.send_request(server.blocks, server.blocks_port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match block.receive_response(server.blocks, server.blocks_port, &into, true) {
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
    return move(server, first, count, into, false)
}

write_blocks :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    return move(server, first, count, view_of(cast[ptr[mut u8]](from.data), from.count), true)
}

// The container service flushes when it commits; a volume server never does itself.
no_flush :: fn(context: rawptr) -> bool {
    return true
}

/*
 * 4 KiB blocks from first moved through the buffer, as much of one extent at a time as it holds: into bytes, or from
 * them. Each is a whole extent's blocks, or part of one, as the container service checks.
 */
move :: fn(server: ptr[mut Server], first: u64, count: u64, bytes: mut u8[], writing: bool) -> bool {
    per :: server.buffer_bytes / slopfs.BLOCK_BYTES
    if per == 0 || count * slopfs.BLOCK_BYTES > cast[u64](bytes.count) {
        return false
    }
    moved := cast[u64](0)
    loop {
        if moved >= count {
            return true
        }
        now :: if count - moved < per { count - moved } else { per }
        window :: view_of(cast[ptr[mut u8]](server.buffer), cast[usize](now * slopfs.BLOCK_BYTES))
        base :: cast[usize](moved * slopfs.BLOCK_BYTES)
        if writing {
            for &byte, i in window {
                at :: base + i
                if at < bytes.count {
                    byte^ = bytes[at]
                }
            }
        }
        transfer :: block.Transfer.{tag = 1, first = (first + moved) * SECTORS_PER_BLOCK, count = cast[u32](now * SECTORS_PER_BLOCK), offset = 0}
        if !done(call(server, if writing { block.Request.Write(transfer) } else { block.Request.Read(transfer) })) {
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

// Connections

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
    connection := Connection.{kind = kind, end = end, object = object, read_only = read_only}
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

open_connection :: fn[P](server: ptr[mut Server], kind: Kind, object: u64, read_only: bool, name: string) -> os.Channel[P]? {
    startup :: slop_os.startup_block()
    pair :: os.channel_for[P](startup.budget, 0) or_return null
    if add(server, kind, pair.a, object, read_only, name) is_none {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return os.Channel[P].{end = pair.b}
}

drop :: fn(server: ptr[mut Server], index: usize) {
    if index >= server.connections.count {
        return void
    }
    connection :: &server.connections[index]
    _ = slop_os.port_unbind(server.port, cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
    release_buffer(connection)
    kind :: connection.kind
    object :: connection.object
    connection.kind = .Free
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

release_buffer :: fn(connection: ptr[mut Connection]) {
    if connection.buffer != 0 {
        startup :: slop_os.startup_block()
        _ = slop_os.memory_unmap(startup.space, connection.buffer)
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.buffer_memory))
        connection.buffer = 0
        connection.buffer_bytes = 0
    }
}

name_of :: fn(connection: ptr[Connection]) -> string {
    return string_of(&connection.name[0], cast[usize](if connection.name_length > files.PATH_BYTES { cast[u32](files.PATH_BYTES) } else { connection.name_length }))
}

serve :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    kind :: server.connections[index].kind
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
}

// Paths and answers

path_of :: fn(into: ptr[os.Incoming], path: slop_os.Relative[u8]) -> string? {
    bytes :: os.items(into, path)
    if bytes.count == 0 || bytes.count > files.PATH_BYTES {
        return null
    }
    return string_of(&bytes[0], bytes.count)
}

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
    }
}

// The file at path beneath directory, opened as creation says.
open_file_object :: fn(volume: ptr[mut slopfs.Volume], directory: u64, path: string, creation: files.Creation) -> Result[u64, slopfs.Error] {
    leaf :: slopfs.leaf_of(volume, directory, path)?
    existing :: slopfs.lookup(volume, leaf.directory, leaf.name)?
    match existing {
        case Some(object) => {
            info :: slopfs.info(volume, object)?
            if info.kind == .Directory {
                return .Error(.IsADirectory)
            }
            if creation == .New {
                return .Error(.AlreadyExists)
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
            return slopfs.create(volume, leaf.directory, leaf.name, .File)
        }
    }
}

// The directory at path beneath directory, made, with any missing on the way to it, if create.
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

// A listing's entry at or after cursor, matching pattern unless it's "".
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
        kind :: if listed.kind == .Directory { files.Kind.Directory } else { files.Kind.File }
        return .Ok(files.Listing.{name = os.append(out, name[0..<listed.name_bytes]), kind = kind, size = info.size, next = at})
    }
}

// Names are compared exactly, as slopfs compares them.
same_byte :: fn(a: u8, b: u8) -> bool {
    return a == b
}

info_of :: fn(out: ptr[mut os.Outgoing], kind: files.Kind, size: u64, name: string) -> files.Info {
    return files.Info.{kind = kind, size = size, name = os.append(out, view_of(cast[ptr[u8]](name.data), name.count))}
}

features :: fn() -> files.Features {
    return files.Features.{atomic_replace = true, transactions = true, change_cursors = true}
}

// A Sync's answer: committed, and durable.
synced :: fn(server: ptr[mut Server]) -> bool {
    return commit(server)
}

// Directories

serve_dir :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    volume :: server.volume
    loop {
        match dir.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = dir.answer_unsupported(end, server.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                drop(server, index)
                return void
            }
        }
        directory :: server.connections[index].object
        in_transaction :: server.connections[index].kind == .Transaction
        transaction :: server.connections[index].transaction
        out := os.Outgoing.{}
        response :: os.begin[dir.Response](&out)
        response^ = .Unsupported
        match os.message_of[dir.Request](into)^ {
            case OpenFile(open) => {
                path :: path_of(into, open.path) or_else ""
                if in_transaction {
                    response^ = open_in_transaction(server, transaction, path, open.creation)
                }
                else {
                    match open_file_object(volume, directory, path, open.creation) {
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
            case OpenReadOnlyFile(at) => response^ = read_only_open(server, directory, path_of(into, at) or_else "")
            case OpenDirectory(open) => {
                path :: path_of(into, open.path) or_else ""
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
        }
        _ = dir.send_response(end, server.port, &out)
    }
}

// What's at from moved to to, both beneath directory.
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

// A read-only file at path beneath directory, for a dir or a read_only_dir.
read_only_open :: fn(server: ptr[mut Server], directory: u64, path: string) -> dir.Response {
    if path.count == 0 {
        return .Failed(.InvalidPath)
    }
    match slopfs.resolve(server.volume, directory, path) {
        case Ok(object) => {
            match slopfs.info(server.volume, object) {
                case Ok(info) => {
                    if info.kind == .Directory {
                        return .Failed(.IsADirectory)
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

serve_read_only_dir :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    volume :: server.volume
    loop {
        match read_only_dir.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = read_only_dir.answer_unsupported(end, server.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                drop(server, index)
                return void
            }
        }
        directory :: server.connections[index].object
        out := os.Outgoing.{}
        response :: os.begin[read_only_dir.Response](&out)
        response^ = .Unsupported
        match os.message_of[read_only_dir.Request](into)^ {
            case OpenReadOnlyFile(at) => {
                match read_only_open(server, directory, path_of(into, at) or_else "") {
                    case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
                    case Failed(error) => response^ = .Failed(error)
                    case _ => {}
                }
            }
            case OpenDirectory(at) => {
                path :: path_of(into, at) or_else ""
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

serve_file_set :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    volume :: server.volume
    loop {
        match file_set.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = file_set.answer_unsupported(end, server.port)
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
        pattern :: name_of(&connection)
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
                    match open_file_object(volume, connection.object, name, open.creation) {
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

in_set :: fn(pattern: string, name: string) -> bool {
    for character in name {
        if character == '/' {
            return false
        }
    }
    return name.count != 0 && file_set.matches(pattern, name, same_byte)
}

// Files

use_buffer :: fn(connection: ptr[mut Connection], memory: slop_os.Memory) -> files.FileError? {
    release_buffer(connection)
    size :: slop_os.memory_size(memory) or_else 0
    if size == 0 || size > MAX_BUFFER_BYTES {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return files.FileError.NoBuffer
    }
    startup :: slop_os.startup_block()
    address :: runtime.reserve_addresses(cast[usize](size)) or_return files.FileError.NoBuffer
    match slop_os.memory_map(memory, startup.space, address, 0, size, read_write()) {
        case Ok => {}
        case Error(error) => {
            _ = slop_os.handle_close(cast[slop_os.Handle](memory))
            return files.FileError.NoBuffer
        }
    }
    connection.buffer = address
    connection.buffer_bytes = size
    connection.buffer_memory = memory
    return null
}

fits :: fn(connection: ptr[Connection], transfer: files.Transfer) -> bool {
    return connection.buffer != 0 && cast[u64](transfer.buffer_offset) + cast[u64](transfer.count) <= connection.buffer_bytes
}

buffer_of :: fn(connection: ptr[Connection], transfer: files.Transfer) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](connection.buffer + cast[u64](transfer.buffer_offset)), cast[usize](transfer.count))
}

read_file :: fn(server: ptr[mut Server], connection: ptr[Connection], transfer: files.Transfer) -> Result[u32, files.FileError] {
    if !fits(connection, transfer) {
        return .Error(.NoBuffer)
    }
    match slopfs.read(server.volume, connection.object, transfer.offset, buffer_of(connection, transfer)) {
        case Ok(count) => return .Ok(cast[u32](count))
        case Error(error) => return .Error(file_error(error))
    }
}

file_info :: fn(server: ptr[mut Server], connection: ptr[Connection], out: ptr[mut os.Outgoing]) -> Result[files.Info, files.FileError] {
    match slopfs.info(server.volume, connection.object) {
        case Ok(info) => return .Ok(info_of(out, .File, info.size, name_of(connection)))
        case Error(error) => return .Error(file_error(error))
    }
}

serve_file :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match file.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = file.answer_unsupported(end, server.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                drop(server, index)
                return void
            }
        }
        connection :: &server.connections[index]
        logged :: connection.kind == .TransactionFile
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
                else if logged {
                    response^ = if log_op(server, connection.transaction, .Write, 0, transfer.offset, name_of(connection), "",
                        buffer_of(connection, transfer)) { file.Response.Transferred(transfer.count) } else { file.Response.Failed(.NoSpace) }
                }
                else {
                    match slopfs.write(server.volume, connection.object, transfer.offset, buffer_of(connection, transfer)) {
                        case Ok => response^ = .Transferred(transfer.count)
                        case Error(error) => response^ = .Failed(file_error(error))
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

serve_read_only_file :: fn(server: ptr[mut Server], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match read_only_file.receive_request(end, server.port, into, false) {
            case Received => {}
            case Empty => return void
            case Unsupported => {
                _ = read_only_file.answer_unsupported(end, server.port)
                continue
            }
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                drop(server, index)
                return void
            }
        }
        connection :: &server.connections[index]
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

/*
 * An encrypted volume's keys, once the storage manager's Unlock gives a passphrase that unwraps them; each that doesn't
 * is answered WrongKey, and the next waited for. Null if the storage manager goes, or the keys can't be read.
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
            case _ => continue
        }
        response : volume_protocol.Response = .Failed
        keys :: slopfs.new_keys(.None)
        unlocked := false
        match os.message_of[volume_protocol.Request](&into)^ {
            case Unlock(given) => {
                unlocked = unlock_keys(server, os.items(&into, given), keys)
                response = if unlocked { .Unlocked } else { .WrongKey }
            }
            case Rotate => response = .Failed
            case Commit => response = .Failed
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

/*
 * The volume's keys, into keys, new: unwrapped with passphrase from the wrap and generation records the container
 * service keeps. False if it isn't the passphrase or they can't be read; keys are for free_keys either way.
 */
unlock_keys :: fn(server: ptr[mut Server], passphrase: u8[], keys: ptr[mut slopfs.Keys]) -> bool {
    wraps : slopfs.WrapRecord[..]
    defer runtime.array_free(&wraps)
    for index in 0..<cast[u64](16) {
        match ask(server, .WrapAt(index)) {
            case Wrap(record) => runtime.array_add(&wraps, record)
            case NoMore => break
            case _ => return false
        }
    }
    generations : slopfs.NumberedGeneration[..]
    defer runtime.array_free(&generations)
    number : u32 = 1
    loop {
        match ask(server, .GenerationAt(number)) {
            case Generation(record) => runtime.array_add(&generations, slopfs.NumberedGeneration.{number = number, record = record})
            case NoMore => break
            case _ => return false
        }
        number += 1
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

// The storage manager's requests on the volume protocol, once the volume is served.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
                drop(server, index)
                return void
            }
        }
        response : volume_protocol.Response = .NotEncrypted
        match os.message_of[volume_protocol.Request](into)^ {
            case Unlock(given) => {
                if server.volume.tree.keys is_some {
                    // Unlocked already: the passphrase checked, for whoever asks the storage manager for the volume again
                    checked :: slopfs.new_keys(.None)
                    response = if unlock_keys(server, os.items(into, given), checked) { .Unlocked } else { .WrongKey }
                    slopfs.free_keys(checked)
                }
            }
            case Rotate => response = rotate(server)
            case Commit => {
                response = if server.described.read_only || !server.volume.dirty || commit(server) { .Committed } else { .Failed }
            }
        }
        out := os.Outgoing.{}
        made :: os.begin[volume_protocol.Response](&out)
        made^ = response
        _ = volume_protocol.send_response(end, server.port, &out)
    }
}

/*
 * A new key generation: made and wrapped here, its record kept by the container service, and what's written from now
 * on sealed with it. What's changed is committed first, so the generation begins with a transaction of its own.
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
    newest : u32 = 0
    loop {
        match ask(server, .GenerationAt(newest + 1)) {
            case Generation(record) => newest += 1
            case _ => break
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
            return .Rotated(keys.current)
        }
        case _ => {
            slopfs.drop_generation(keys, previous)
            return .Failed
        }
    }
}

// Whose key records the volume uses: its own, or a clone's origin's.
key_owner :: fn(server: ptr[Server]) -> u64 {
    record := server.described.record
    return slopfs.key_owner_of(server.described.id, &record)
}
