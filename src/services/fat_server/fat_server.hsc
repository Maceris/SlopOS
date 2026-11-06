/**
 * A FAT server (roadmap 8b, decisions/0085, 0087): one per FAT32 partition, started by the storage manager with a
 * block connection narrowed to it and nothing else, so a crafted volume reaches only this process. It mounts the
 * volume (src/fat) and serves the file protocols: dir and read_only_dir connections for directories, file and
 * read_only_file for files, and file_set for a directory and a pattern. Each connection is its own capability, and
 * nothing leads above the directory it was opened at. A file connection reads and writes through a buffer its client
 * gives it, mapped here; every connection to one file sees what the others write, as each reads its entry afresh.
 *
 * Every request is done before the next is read, and every write goes straight to the disk, so a Sync is a Flush.
 * What's made or written to has the wall clock's time, from the clock page the storage manager passes on, and
 * FSInfo's free count is written back after each pass of requests that changed it (decisions/0101).
 */
package fat_server

import runtime from "base"
import os from "std"
import time from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import file_set from "std/os/slop_os"
import files from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"
import read_only_file from "std/os/slop_os"
import fat from "../../fat"
import log_line from "../../log_line"
import block from "../../protocols/block"

/** The most connections at once, of every kind; one past them is closed at once, and an open answered NoSpace. */
MAX_CONNECTIONS :: 64
/** The most bytes of a client's buffer mapped here; a bigger one is refused with NoBuffer. */
MAX_BUFFER_BYTES : u64 : 16 << 20

/** What a connection is, and so which protocol it speaks. */
Kind :: enum {
    /** A slot no connection has. */
    Free,
    /** A directory, speaking dir: the listener's, and those opened beneath it. */
    Dir,
    /** A directory narrowed to read only, speaking read_only_dir. */
    ReadOnlyDir,
    /** A file, speaking file, to read and write. */
    File,
    /** A file, speaking read_only_file. */
    ReadOnlyFile,
    /** A directory's files matching a pattern, speaking file_set. */
    FileSet,
}

/**
 * A connection: what it's to (a directory's first cluster, or a file's place), its informational name (a set's
 * pattern), and a file's buffer, mapped here.
 */
Connection :: struct {
    /** What it is; Free for a slot no connection has. */
    kind : Kind,
    /** The client's end, the server's own, bound to the port under the connection's slot; closed by drop. */
    end : slop_os.Channel,
    /** A directory's or a file set's directory: its first cluster; 0 for a file's. */
    directory : u32,
    /** A file's place: where its directory entry is, which it's read from afresh for each request. */
    place : fat.Place,
    /** Whether it may change nothing: a read-only directory, file or set, and what's opened through one. */
    read_only : bool,
    /** Its name: the path it was opened at, a file's used to find its entry again, or a set's pattern. */
    name : u8[files.PATH_BYTES],
    /** How many of name's bytes are its. */
    name_length : u32,
    /** Where a file's buffer, its client's memory, is mapped here; 0 before UseBuffer. */
    buffer : u64,
    /** The buffer's size in bytes, at most MAX_BUFFER_BYTES. */
    buffer_bytes : u64,
    /** The buffer's memory, the server's handle to it, closed when it's let go of. */
    buffer_memory : slop_os.Memory,
}

/** The FAT server's state, made once in main, on the heap, and kept for as long as it runs. */
Server :: struct {
    /** The debug log it says what it's doing in; NO_HANDLE for none. */
    log : slop_os.DebugLog,
    /** The port every connection is bound to, under its slot. */
    port : slop_os.Port,
    /** The block connection narrowed to the FAT32 partition. */
    disk : slop_os.Channel,
    /** A port bound to disk, waited on for its answers. */
    disk_port : slop_os.Port,
    /** Where disk's buffer is mapped, readable and writable, in the process's address space. */
    disk_buffer : u64,
    /** The disk's buffer's size in bytes. */
    disk_buffer_bytes : u64,
    /** Whether the partition is read only, as its block connection says: nothing's made or written. */
    read_only : bool,
    /** The connections, by slot. */
    connections : Connection[MAX_CONNECTIONS],
    /** How many slots of connections have ever been used: one past the highest. */
    count : usize,
    /** Whether a connection was added during this pass, which may have taken a free slot it's already past. */
    added : bool,
}

/**
 * Serve a FAT32 partition's files: mount it, and serve directories, files and file sets on it, each connection its own
 * capability, reaching nothing above where it was opened.
 *
 * Started by the storage manager, one per FAT32 partition, with nothing but the partition, so a crafted volume
 * reaches only this process. FSInfo's free count is checked against the FAT's at mount, and the FAT's kept if they
 * differ. Runs until it's stopped.
 *
 * @param log The debug log it says what it's doing in; without one, it says nothing.
 * @param partition A block connection narrowed to the FAT32 partition, which it takes the buffer of.
 * @param clients The listener for connections to the volume's root directory.
 * @return 99 without the memory for its state, 1 if its ports couldn't be made, 2 if the partition didn't describe
 *     itself, 3 if it didn't give its buffer, 4 if the buffer couldn't be mapped, 5 if there's no FAT32 volume on it,
 *     and 6 if clients couldn't be added. It doesn't return otherwise.
 */
main :: fn(log: slop_os.DebugLog?, partition: os.Channel[block.Block], clients: os.Listener[dir.Dir]) -> int {
    startup :: slop_os.startup_block()
    // Its state; without the memory for it, it ends with 99 (decisions/0104)
    server_made, server_error :: runtime.new_aligned(Server, align_of(Server))
    if server_error != null {
        return 99
    }
    server :: server_made
    server.log = log or_else cast[slop_os.DebugLog](slop_os.NO_HANDLE)
    server.disk = partition.end
    server.disk_port = os.port_for(startup.budget, partition.end) or_return 1
    server.port = slop_os.port_create(startup.budget) or_return 1
    info := block.Info.{}
    match call(server, .Describe) {
        case Described(described) => info = described
        case _ => return 2
    }
    window := cast[slop_os.Memory](slop_os.NO_HANDLE)
    match call(server, .GetBuffer) {
        case Buffer(memory) => window = memory
        case _ => return 3
    }
    server.disk_buffer_bytes = info.buffer_bytes
    server.read_only = info.read_only
    server.disk_buffer = runtime.reserve_addresses(cast[usize](info.buffer_bytes)) or_return 4
    slop_os.memory_map(window, startup.space, server.disk_buffer, 0, info.buffer_bytes, read_write()) or_return 4
    device :: fat.Device.{context = cast[rawptr](server), sector_count = info.block_count, read = read_sectors, write = write_sectors,
        read_only = info.read_only}
    volume := fat.Volume.{}
    match fat.mount(device) {
        case Ok(mounted) => volume = mounted
        case Error(failure) => {
            log_line.write(server.log, "fat_server: no FAT32 volume on a partition of % blocks: %", info.block_count, failure)
            return 5
        }
    }
    log_line.write(server.log, "fat_server: serving a FAT32 volume of % clusters of % bytes%", volume.cluster_count, volume.cluster_bytes,
        if info.read_only { ", read-only" } else { "" })
    // FSInfo's free count checked against the FAT's, and the FAT's kept if they differ, as after another system's writes
    match fat.count_free(&volume) {
        case Ok(counted) => {
            if counted == volume.free_count {
                log_line.write(server.log, "fat_server: FSInfo's free count is the FAT's")
            }
            else {
                log_line.write(server.log, "fat_server: FSInfo's free count was %, and the FAT has %, which it is now",
                    volume.free_count, counted)
                volume.free_count = counted
                volume.info_changed = true
            }
        }
        case Error(failure) => {}
    }
    // The listener is a connection to the root, as any client's Connect on it gives another
    if add(server, .Dir, clients.end, volume.root_cluster, fat.Place.{}, false, "") is_none {
        return 6
    }
    into := os.Incoming.{}
    loop {
        // Connections made meanwhile are read in another pass, as a channel wakes its reader only once it's found empty
        // What's made or written to now has the wall clock's time, if there's a wall clock
        volume.stamp = stamp_now()
        loop #at_least_once {
            server.added = false
            with {
                i : usize = 0
            }
            loop {
                serve(server, &volume, i, &into)
                i += 1
            }
            while i < server.count
        }
        while server.added
        // FSInfo's free count kept as the FAT is: written once the requests that changed it are done
        match fat.write_info(&volume) {
            case Some(failure) => log_line.write(server.log, "fat_server: FSInfo not written: %", failure)
            case None => {}
        }
        packets : slop_os.Packet[8]
        _ = slop_os.port_wait(server.port, packets, slop_os.NO_DEADLINE)
    }
}

/**
 * Read the wall clock's time, as FAT stamps what's made or written.
 *
 * @return The time in UTC as FAT holds it, to two seconds; fat.EPOCH_STAMP without a wall clock.
 */
stamp_now :: fn() -> u32 {
    match time.now() {
        case Ok(now) => {
            at :: time.utc(now)
            return fat.stamp_of(at.year, at.month, at.day, at.hour, at.minute, at.second)
        }
        case Error(error) => return fat.EPOCH_STAMP
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

// The disk, a request at a time

/**
 * Send one request to the partition, and wait for its answer.
 *
 * @param server The FAT server's state, whose disk connection the request goes on, waiting on disk_port for the answer;
 *     the disk must have no other request in flight.
 * @param request The request, copied whole into the message; a Read or Write moves bytes through the disk's buffer, not
 *     the message.
 * @return The answer, a copy, whose handles the caller owns; Unsupported if it couldn't be sent or the connection
 *     failed.
 */
call :: fn(server: ptr[mut Server], request: block.Request) -> block.Response {
    out := os.Outgoing.{}
    made :: os.begin[block.Request](&out)
    made^ = request
    if block.send_request(server.disk, server.disk_port, &out) is_some {
        return .Unsupported
    }
    into := os.Incoming.{}
    loop {
        match block.receive_response(server.disk, server.disk_port, &into, true) {
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
 * Read sectors of the partition through its buffer, as many at a time as it holds, for fat's Device.
 *
 * @param context The Server main gave the Device, cast back; its disk is read through its mapped buffer, which is
 *     overwritten.
 * @param first The first 512-byte sector in the partition.
 * @param count How many 512-byte sectors, read in pieces of as many as the buffer holds.
 * @param into Where they go, at least count sectors long.
 * @return Whether they were all read; false if into is too short, the buffer holds no sector, or a read failed.
 */
read_sectors :: fn(context: rawptr, first: u64, count: u64, into: mut u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    per :: server.disk_buffer_bytes / block.BLOCK_BYTES
    if per == 0 || count * block.BLOCK_BYTES > cast[u64](into.count) {
        return false
    }
    moved := cast[u64](0)
    loop {
        if moved >= count {
            return true
        }
        now :: if count - moved < per { count - moved } else { per }
        if !done(call(server, .Read(block.Transfer.{tag = 1, first = first + moved, count = cast[u32](now), offset = 0}))) {
            return false
        }
        for byte, i in view_of(cast[ptr[u8]](server.disk_buffer), cast[usize](now * block.BLOCK_BYTES)) {
            at :: cast[usize](moved * block.BLOCK_BYTES) + i
            if at < into.count {
                into[at] = byte
            }
        }
        moved += now
    }
}

/**
 * Write sectors of the partition through its buffer, as many at a time as it holds, for fat's Device; each write
 * goes to the disk at once, durable once a Flush is.
 *
 * @param context The Server main gave the Device, cast back; its mapped disk buffer is overwritten and written to the
 *     disk.
 * @param first The first 512-byte sector in the partition.
 * @param count How many 512-byte sectors, written in pieces of as many as the buffer holds.
 * @param from What's written, at least count sectors long.
 * @return Whether they were all written; false if from is too short, the buffer holds no sector, or a write failed,
 *     what was written before it written.
 */
write_sectors :: fn(context: rawptr, first: u64, count: u64, from: u8[]) -> bool {
    server :: cast[ptr[mut Server]](context)
    per :: server.disk_buffer_bytes / block.BLOCK_BYTES
    if per == 0 || count * block.BLOCK_BYTES > cast[u64](from.count) {
        return false
    }
    moved := cast[u64](0)
    loop {
        if moved >= count {
            return true
        }
        now :: if count - moved < per { count - moved } else { per }
        for &byte, i in view_of(cast[ptr[mut u8]](server.disk_buffer), cast[usize](now * block.BLOCK_BYTES)) {
            at :: cast[usize](moved * block.BLOCK_BYTES) + i
            if at < from.count {
                byte^ = from[at]
            }
        }
        if !done(call(server, .Write(block.Transfer.{tag = 2, first = first + moved, count = cast[u32](now), offset = 0}))) {
            return false
        }
        moved += now
    }
}

// Connections

/**
 * Add a connection, in the first free slot, bound to the port under its slot; it's read in the main loop's next pass.
 *
 * @param server The server, whose added is set.
 * @param kind The protocol the connection speaks, kept in its slot: Dir or ReadOnlyDir, File or ReadOnlyFile, or
 *     FileSet; never Free.
 * @param end The client's end, which the server takes over: closed here if it can't be added.
 * @param directory A directory's or a set's first cluster; 0 for a file.
 * @param place A file's place; empty for another kind.
 * @param read_only Whether it may change nothing.
 * @param name The path it was opened at, or a set's pattern; cut to files.PATH_BYTES.
 * @return Its slot; null, with end closed, if there are MAX_CONNECTIONS already or it couldn't be bound.
 */
add :: fn(server: ptr[mut Server], kind: Kind, end: slop_os.Channel, directory: u32, place: fat.Place, read_only: bool, name: string) -> usize? {
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
    connection := Connection.{kind = kind, end = end, directory = directory, place = place, read_only = read_only}
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
 * @tparam P The protocol: dir, read_only_dir, file, read_only_file or file_set's.
 * @param server The FAT server's state, given the new slot, whose added is set.
 * @param kind What it is, which must speak P.
 * @param directory A directory's or a set's first cluster; 0 for a file.
 * @param place A file's place; empty for another kind.
 * @param read_only Whether it may change nothing.
 * @param name The path it was opened at, or a set's pattern.
 * @return The other end, the client's, which the caller sends; null if a channel or a slot couldn't be had.
 */
open_connection :: fn[P](server: ptr[mut Server], kind: Kind, directory: u32, place: fat.Place, read_only: bool, name: string) -> os.Channel[P]? {
    startup :: slop_os.startup_block()
    pair :: os.channel_for[P](startup.budget, 0) or_return null
    if add(server, kind, pair.a, directory, place, read_only, name) is_none {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return os.Channel[P].{end = pair.b}
}

/**
 * Drop a connection whose client went: unbind it, close its end, let go of its buffer, and free its slot.
 *
 * @param server The FAT server's state: the slot is unbound from its port, its end closed and buffer let go of, and
 *     left Free for add to reuse; count isn't lowered.
 * @param index The connection's slot; one past them is ignored.
 */
drop :: fn(server: ptr[mut Server], index: usize) {
    if index >= server.connections.count {
        return void
    }
    connection :: &server.connections[index]
    _ = slop_os.port_unbind(server.port, cast[u64](index))
    _ = slop_os.handle_close(cast[slop_os.Handle](connection.end))
    release_buffer(connection)
    connection.kind = .Free
}

/**
 * Let go of a file connection's buffer: unmap it and close its memory, if it has one.
 *
 * @param connection A connection's slot; its buffer, if mapped, is unmapped from this process and its memory handle
 *     closed, and buffer and buffer_bytes set to 0. One without a buffer is left as it is.
 */
release_buffer :: fn(connection: ptr[mut Connection]) {
    if connection.buffer != 0 {
        startup :: slop_os.startup_block()
        _ = slop_os.memory_unmap(startup.space, connection.buffer)
        _ = slop_os.handle_close(cast[slop_os.Handle](connection.buffer_memory))
        connection.buffer = 0
        connection.buffer_bytes = 0
    }
}

/**
 * Give a connection's name: the path it was opened at, or a set's pattern.
 *
 * @param connection A connection's slot, whose name and name_length are read; a length past files.PATH_BYTES is cut to
 *     it.
 * @return A view of its name's bytes, good while the connection is unchanged.
 */
name_of :: fn(connection: ptr[Connection]) -> string {
    return string_of(&connection.name[0], cast[usize](if connection.name_length > files.PATH_BYTES { cast[u32](files.PATH_BYTES) } else { connection.name_length }))
}

/**
 * Answer a connection's requests, as its kind says, until it has none.
 *
 * @param server The FAT server's state, whose slot is served by its kind; slots may be added or dropped.
 * @param volume The mounted volume, main's, which the slot's requests read or change.
 * @param index The connection's slot; a free one, or one past them, is left alone.
 * @param into Where each request is read into, reused.
 */
serve :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    kind :: server.connections[index].kind
    if kind == .Dir {
        serve_dir(server, volume, index, into)
    }
    else if kind == .ReadOnlyDir {
        serve_read_only_dir(server, volume, index, into)
    }
    else if kind == .File {
        serve_file(server, volume, index, into)
    }
    else if kind == .ReadOnlyFile {
        serve_read_only_file(server, volume, index, into)
    }
    else if kind == .FileSet {
        serve_file_set(server, volume, index, into)
    }
}

// Paths

/**
 * Read a path from a message.
 *
 * @param into The message the request was read into, which the path is in; only read.
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

/** Where a path's last component goes: the directory that holds it, and its name. */
Leaf :: struct {
    /** The directory's first cluster. */
    directory : u32,
    /** The last component, a view into the path. */
    name : string,
}

/**
 * Find where a path's last component goes.
 *
 * @param volume The mounted volume, main's, whose directories on the way are read; nothing on it is written, though its
 *     walk of a directory's chain moves.
 * @param directory The first cluster of the directory the path is beneath.
 * @param path The path, components separated by '/'.
 * @return The directory that holds its last component, which must exist, and the component, a view into path.
 * @error NotADirectory What's before the last component isn't a directory.
 * @error NotFound A directory on the way isn't there.
 * @error DeviceError The disk refused a read.
 * @error Corrupt A directory on the way couldn't be read as one.
 */
leaf_of :: fn(volume: ptr[mut fat.Volume], directory: u32, path: string) -> Result[Leaf, fat.FatError] {
    last := path.count
    for character, i in path {
        if character == '/' {
            last = i
        }
    }
    if last == path.count {
        return .Ok(Leaf.{directory = directory, name = path})
    }
    parent :: fat.resolve(volume, directory, string_of(cast[ptr[u8]](path.data), last))?
    if parent.attributes & fat.DIRECTORY == 0 {
        return .Error(.NotADirectory)
    }
    return .Ok(Leaf.{directory = fat.directory_cluster(volume, &parent), name = string_of(cast[ptr[u8]](cast[u64](path.data) + cast[u64](last + 1)), path.count - last - 1)})
}

/**
 * Give the file protocols' error for a FAT error.
 *
 * @param error Any FAT error, as fat's functions return it.
 * @return The same error, but NotFat as Corrupt and InvalidName as InvalidPath.
 */
file_error :: fn(error: fat.FatError) -> files.FileError {
    return match error {
        case .NotFat => files.FileError.Corrupt
        case .NotFound => files.FileError.NotFound
        case .NotADirectory => files.FileError.NotADirectory
        case .IsADirectory => files.FileError.IsADirectory
        case .AlreadyExists => files.FileError.AlreadyExists
        case .DirectoryNotEmpty => files.FileError.DirectoryNotEmpty
        case .InvalidName => files.FileError.InvalidPath
        case .NoSpace => files.FileError.NoSpace
        case .DeviceError => files.FileError.DeviceError
        case .Corrupt => files.FileError.Corrupt
        case .ReadOnly => files.FileError.ReadOnly
    }
}

/**
 * Find or make a file's entry, as creation says.
 *
 * @param volume The mounted volume, main's; making the file or cutting it writes the volume's structures to the disk.
 * @param directory The first cluster of the directory the path is beneath.
 * @param path The file's path beneath directory, components separated by '/'; not empty, as path_of gives it.
 * @param creation New makes it, refusing one there; Existing finds it, refusing none; Truncate finds or makes it, cut
 *     to nothing, written to the disk at once; and any other finds or makes it as it is.
 * @return The file's entry, a copy: one found, cut to size 0 if creation is Truncate, or one just made, empty and
 *     with no cluster.
 * @error AlreadyExists It's there, and creation is New.
 * @error NotFound It isn't there, and creation is Existing; or a directory on the way isn't.
 * @error IsADirectory What's at path is a directory.
 * @error NotADirectory What's on the way to it isn't a directory.
 * @error InvalidName Its name can't be a FAT name.
 * @error NoSpace Making it, or its directory's growing, needed a cluster the volume hasn't.
 * @error ReadOnly The partition is read only, and it had to be made or cut.
 * @error DeviceError The disk refused a read or a write.
 * @error Corrupt The volume's structures couldn't be followed.
 */
open_file_entry :: fn(volume: ptr[mut fat.Volume], directory: u32, path: string, creation: files.Creation) -> Result[fat.Entry, fat.FatError] {
    leaf :: leaf_of(volume, directory, path)?
    existing := fat.Entry.{}
    found := false
    match fat.lookup(volume, leaf.directory, leaf.name) {
        case Ok(entry) => {
            existing = entry
            found = true
        }
        case Error(error) => {
            if error != .NotFound {
                return .Error(error)
            }
        }
    }
    if found {
        if existing.attributes & fat.DIRECTORY != 0 {
            return .Error(.IsADirectory)
        }
        if creation == .New {
            return .Error(.AlreadyExists)
        }
        if creation == .Truncate && existing.size != 0 {
            fat.set_size(volume, &existing, 0)?
        }
        return .Ok(existing)
    }
    if creation == .Existing {
        return .Error(.NotFound)
    }
    return fat.create(volume, leaf.directory, leaf.name, false)
}

/**
 * Find a directory, or make it, with any missing on the way to it.
 *
 * @param volume The mounted volume, main's; with create, making directories writes the volume's structures to the disk.
 * @param directory The first cluster of the directory the path is beneath.
 * @param path The directory's path beneath directory, components separated by '/'.
 * @param create Whether it, and each directory missing on the way, is made, written to the disk at once.
 * @return Its first cluster.
 * @error NotADirectory What's at path, or on the way to it, isn't a directory.
 * @error NotFound It isn't there, and create is false.
 * @error InvalidName Making it, a component is empty, "." or "..", or can't be a FAT name.
 * @error NoSpace Making it needed a cluster the volume hasn't.
 * @error ReadOnly The partition is read only.
 * @error DeviceError The disk refused a read or a write.
 * @error Corrupt The volume's structures couldn't be followed.
 */
open_directory_entry :: fn(volume: ptr[mut fat.Volume], directory: u32, path: string, create: bool) -> Result[u32, fat.FatError] {
    if !create {
        found :: fat.resolve(volume, directory, path)?
        if found.attributes & fat.DIRECTORY == 0 {
            return .Error(.NotADirectory)
        }
        return .Ok(fat.directory_cluster(volume, &found))
    }
    current := directory
    start : usize = 0
    for i in 0..<path.count + 1 {
        if i < path.count && path[i] != '/' {
            continue
        }
        component :: string_of(cast[ptr[u8]](cast[u64](path.data) + cast[u64](start)), i - start)
        start = i + 1
        if component.count == 0 || component == "." || component == ".." {
            return .Error(.InvalidName)
        }
        match fat.lookup(volume, current, component) {
            case Ok(found) => {
                if found.attributes & fat.DIRECTORY == 0 {
                    return .Error(.NotADirectory)
                }
                existing := found
                current = fat.directory_cluster(volume, &existing)
            }
            case Error(error) => {
                if error != .NotFound {
                    return .Error(error)
                }
                made := fat.create(volume, current, component, true)?
                current = fat.directory_cluster(volume, &made)
            }
        }
    }
    return .Ok(current)
}

/**
 * List a directory's entry at or after a cursor, the first that matches a pattern.
 *
 * @param volume The mounted volume, main's, whose directory is read; nothing on it is written, though its walk of the
 *     chain moves.
 * @param directory The directory's first cluster.
 * @param cursor Where to start: 0 for the first entry, or what the last listing's next said.
 * @param pattern The pattern the name must match, ignoring case; "" for every entry.
 * @param out The answer being built, which the entry's name is appended to.
 * @return The entry: its name, kind, size in bytes and the cursor after it; null past the last.
 * @error Corrupt The directory couldn't be read as one.
 * @error DeviceError The disk refused a read.
 */
listing_of :: fn(volume: ptr[mut fat.Volume], directory: u32, cursor: u64, pattern: string, out: ptr[mut os.Outgoing]) -> Result[files.Listing?, fat.FatError] {
    slot := cast[u32](cursor)
    loop {
        listed :: fat.next_entry(volume, directory, slot)? or_return .Ok(null)
        name :: fat.name_of(&listed.entry)
        slot = listed.next
        if pattern.count != 0 && !file_set.matches(pattern, name, same_byte) {
            continue
        }
        kind :: if listed.entry.attributes & fat.DIRECTORY != 0 { files.Kind.Directory } else { files.Kind.File }
        return .Ok(files.Listing.{name = os.append(out, string_bytes(name)), kind = kind,
            size = cast[u64](listed.entry.size), next = cast[u64](slot)})
    }
}

/**
 * Tell whether two bytes of a name are the same, as FAT compares them, ignoring case.
 *
 * @param a A byte of the pattern, or of the name, as file_set.matches gives it.
 * @param b The byte it's compared with, from the other.
 * @return Whether they're the same in upper case.
 */
same_byte :: fn(a: u8, b: u8) -> bool {
    return fat.upper(a) == fat.upper(b)
}

/**
 * Tell whether a schema hash asks for no type, as FAT keeps none (decisions/0108).
 *
 * @param schema The schema hash an OpenFile asked for, 32 bytes.
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
 * Describe a connection's directory or file.
 *
 * @param out The answer being built, which the name is appended to.
 * @param kind Directory or File.
 * @param size A file's size in bytes; 0 for a directory.
 * @param name The name described, a connection's path or a set's pattern, appended to out as bytes.
 * @return The Info: kind and size as given, and name as the bytes appended to out, so it's good in out's answer only.
 */
info_of :: fn(out: ptr[mut os.Outgoing], kind: files.Kind, size: u64, name: string) -> files.Info {
    return files.Info.{kind = kind, size = size, name = os.append(out, string_bytes(name))}
}

/**
 * Say what FAT's file system does: it ignores case.
 *
 * @return Always ignores_case true, and the rest false: no atomic Replace, transactions, snapshots or change
 *     cursors.
 */
features :: fn() -> files.Features {
    return files.Features.{ignores_case = true}
}

// Directories

/**
 * Answer a directory connection's requests, until it has none, or it's gone.
 *
 * Every request is done before the next is read, and every write goes to the disk at once, so Sync is a Flush; after
 * a failed write, every Sync fails, not only the first (decisions/0112). On a read-only partition, files are opened
 * only to read, and directories aren't made. Transactions, Replace and change cursors are the native file system's,
 * answered Unsupported (decisions/0089). Connect adds a connection to the same directory, with no answer. A
 * connection whose end fails is dropped.
 *
 * @param server The FAT server's state: answers go on the slot's end, opens and Connect add slots, setting added, Sync
 *     flushes its disk, and a failed end drops the slot.
 * @param volume The mounted volume, main's: Open, Remove and Rename may change it, written to the disk at once, and a
 *     failed write sets its failed, so every Sync fails after.
 * @param index The connection's slot among server's connections; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_dir :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match dir.receive_request(end, server.port, into, false) {
            case Received => {}
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
        directory :: server.connections[index].directory
        out := os.Outgoing.{}
        response :: os.begin[dir.Response](&out)
        response^ = .Unsupported
        match os.message_of[dir.Request](into)^ {
            case OpenFile(open) => {
                path :: path_of(into, open.path) or_else ""
                if path.count == 0 {
                    response^ = .Failed(.InvalidPath)
                }
                // FAT keeps no types (decisions/0108)
                else if !untyped(open.schema) {
                    response^ = .Failed(.WrongType)
                }
                else if server.read_only && open.creation != .Existing {
                    response^ = .Failed(.ReadOnly)
                }
                else {
                    match open_file_entry(volume, directory, path, open.creation) {
                        case Ok(entry) => {
                            match open_connection[file.File](server, .File, 0, entry.place, false, path) {
                                case Some(made) => response^ = .OpenedFile(made)
                                case None => response^ = .Failed(.NoSpace)
                            }
                        }
                        case Error(error) => response^ = .Failed(file_error(error))
                    }
                }
            }
            case OpenReadOnlyFile(at) => response^ = read_only_open(server, volume, directory, path_of(into, at) or_else "", &out)
            case OpenDirectory(open) => {
                path :: path_of(into, open.path) or_else ""
                match open_directory_entry(volume, directory, path, open.create && !server.read_only) {
                    case Ok(cluster) => {
                        match open_connection[dir.Dir](server, .Dir, cluster, fat.Place.{}, false, path) {
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
                match fat.resolve(volume, directory, path) {
                    case Ok(entry) => {
                        found := entry
                        match fat.remove(volume, &found) {
                            case Ok => {}
                            case Error(error) => response^ = .Failed(file_error(error))
                        }
                    }
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case Rename(rename) => {
                from :: path_of(into, rename.from) or_else ""
                to :: path_of(into, rename.to) or_else ""
                response^ = .Done
                match moved(volume, directory, from, to) {
                    case Some(error) => response^ = .Failed(file_error(error))
                    case None => {}
                }
            }
            case Narrow => {
                match open_connection[read_only_dir.ReadOnlyDir](server, .ReadOnlyDir, directory, fat.Place.{}, true, name_of(&server.connections[index])) {
                    case Some(made) => response^ = .Narrowed(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            case Select(pattern) => {
                text :: path_of(into, pattern) or_else ""
                match open_connection[file_set.FileSet](server, .FileSet, directory, fat.Place.{}, false, text) {
                    case Some(made) => response^ = .Selected(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            // After a failed write, every Sync fails, not only the first (decisions/0112)
            case Sync => response^ = if !volume.failed && done(call(server, .Flush(3))) { dir.Response.Done } else { dir.Response.Failed(.DeviceError) }
            case Features => response^ = .Supports(features())
            case Room => {
                match fat.free_clusters(volume) {
                    case Ok(free) => response^ = .Room(files.Room.{free = cast[u64](free) * volume.cluster_bytes,
                        size = cast[u64](volume.cluster_count) * volume.cluster_bytes})
                    case Error(failure) => response^ = .Failed(file_error(failure))
                }
            }
            case Connect(connection) => {
                _ = add(server, .Dir, connection.end, directory, fat.Place.{}, false, name_of(&server.connections[index]))
                continue
            }
            // Transactions, Replace and change cursors are the native filesystem's (decisions/0089)
            case _ => {}
        }
        _ = dir.send_response(end, server.port, &out)
    }
}

/**
 * Move a file or a directory, written to the disk at once.
 *
 * @param volume The mounted volume, main's; the move writes its directories to the disk at once.
 * @param directory The first cluster of the directory both paths are beneath.
 * @param from Its path beneath directory, components separated by '/'.
 * @param to Where it goes; the directory that holds it must exist.
 * @return Null once it's moved; why not, otherwise, as fat.rename and the paths' lookups say.
 */
moved :: fn(volume: ptr[mut fat.Volume], directory: u32, from: string, to: string) -> fat.FatError? {
    entry := fat.Entry.{}
    match fat.resolve(volume, directory, from) {
        case Ok(found) => entry = found
        case Error(error) => return error
    }
    match leaf_of(volume, directory, to) {
        case Ok(leaf) => {
            match fat.rename(volume, &entry, leaf.directory, leaf.name) {
                case Ok(made) => return null
                case Error(error) => return error
            }
        }
        case Error(error) => return error
    }
}

/**
 * Open a file read only, for a dir, a read_only_dir or a file set.
 *
 * @param server The FAT server's state, given a ReadOnlyFile slot for the file.
 * @param volume The mounted volume, main's, whose directories are read; nothing on it is written.
 * @param directory The first cluster of the directory the path is beneath.
 * @param path The file's path; "" is refused with InvalidPath.
 * @param out The answer being built; unused.
 * @return OpenedReadOnlyFile with the connection's other end, which the caller sends; Failed with IsADirectory for a
 *     directory, NoSpace without a slot, or why it couldn't be found.
 */
read_only_open :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], directory: u32, path: string, out: ptr[mut os.Outgoing]) -> dir.Response {
    if path.count == 0 {
        return .Failed(.InvalidPath)
    }
    match fat.resolve(volume, directory, path) {
        case Ok(entry) => {
            if entry.attributes & fat.DIRECTORY != 0 {
                return .Failed(.IsADirectory)
            }
            match open_connection[read_only_file.ReadOnlyFile](server, .ReadOnlyFile, 0, entry.place, true, path) {
                case Some(made) => return .OpenedReadOnlyFile(made)
                case None => return .Failed(.NoSpace)
            }
        }
        case Error(error) => return .Failed(file_error(error))
    }
}

/**
 * Answer a read-only directory connection's requests, until it has none, or it's gone: files opened read only,
 * directories opened read only, never made, listings, sets, and Connect, which adds a connection to the same
 * directory with no answer. A connection whose end fails is dropped.
 *
 * @param server The FAT server's state: answers go on the slot's end, opens and Connect add read-only slots, setting
 *     added, and a failed end drops the slot.
 * @param volume The mounted volume, main's, only read: nothing on it is written through a read-only directory.
 * @param index The connection's slot among server's connections; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_read_only_dir :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match read_only_dir.receive_request(end, server.port, into, false) {
            case Received => {}
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
        directory :: server.connections[index].directory
        out := os.Outgoing.{}
        response :: os.begin[read_only_dir.Response](&out)
        response^ = .Unsupported
        match os.message_of[read_only_dir.Request](into)^ {
            case OpenReadOnlyFile(at) => {
                match read_only_open(server, volume, directory, path_of(into, at) or_else "", &out) {
                    case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
                    case Failed(error) => response^ = .Failed(error)
                    case _ => {}
                }
            }
            case OpenDirectory(at) => {
                path :: path_of(into, at) or_else ""
                match open_directory_entry(volume, directory, path, false) {
                    case Ok(cluster) => {
                        match open_connection[read_only_dir.ReadOnlyDir](server, .ReadOnlyDir, cluster, fat.Place.{}, true, path) {
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
                match open_connection[file_set.FileSet](server, .FileSet, directory, fat.Place.{}, true, text) {
                    case Some(made) => response^ = .Selected(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            case Features => response^ = .Supports(features())
            case Connect(connection) => {
                _ = add(server, .ReadOnlyDir, connection.end, directory, fat.Place.{}, true, name_of(&server.connections[index]))
                continue
            }
            case _ => {}
        }
        _ = read_only_dir.send_response(end, server.port, &out)
    }
}

/**
 * Answer a file set's requests, until it has none, or it's gone: its files listed, and opened by a name of one
 * component matching its pattern, NotFound for another, and ReadOnly for a read-only set's OpenFile. Connect adds a
 * connection to the same set, with no answer. A connection whose end fails is dropped.
 *
 * @param server The FAT server's state: answers go on the slot's end, opens and Connect add slots, setting added, and a
 *     failed end drops the slot.
 * @param volume The mounted volume, main's; an OpenFile through a set that may write may make or cut a file, written to
 *     the disk at once.
 * @param index The connection's slot among server's connections; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_file_set :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], index: usize, into: ptr[mut os.Incoming]) {
    if index >= server.connections.count {
        return void
    }
    end :: server.connections[index].end
    loop {
        match file_set.receive_request(end, server.port, into, false) {
            case Received => {}
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
        out := os.Outgoing.{}
        response :: os.begin[file_set.Response](&out)
        response^ = .Unsupported
        match os.message_of[file_set.Request](into)^ {
            case List(cursor) => {
                match listing_of(volume, connection.directory, cursor, pattern, &out) {
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
                if connection.read_only || server.read_only {
                    response^ = .Failed(.ReadOnly)
                }
                else if !in_set(pattern, name) {
                    response^ = .Failed(.NotFound)
                }
                else {
                    match open_file_entry(volume, connection.directory, name, open.creation) {
                        case Ok(entry) => {
                            match open_connection[file.File](server, .File, 0, entry.place, false, name) {
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
                    match read_only_open(server, volume, connection.directory, name, &out) {
                        case OpenedReadOnlyFile(made) => response^ = .OpenedReadOnlyFile(made)
                        case Failed(error) => response^ = .Failed(error)
                        case _ => {}
                    }
                }
            }
            case Info => response^ = .Described(info_of(&out, .Directory, 0, pattern))
            case Connect(other) => {
                _ = add(server, .FileSet, other.end, connection.directory, fat.Place.{}, connection.read_only, pattern)
                continue
            }
        }
        _ = file_set.send_response(end, server.port, &out)
    }
}

/**
 * Tell whether a name is one of a set's.
 *
 * @param pattern The set's pattern, as file_set.matches takes it, compared ignoring case.
 * @param name The name asked for, as the request gave it, not yet checked; "" or one with a "/" is never in a set.
 * @return Whether it's one component, not empty, matching the pattern, ignoring case.
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
 * Take a file connection's buffer: its client's memory, mapped here, readable and writable, in place of any before.
 *
 * @param connection A file connection's slot: its buffer before is let go of first, whether or not the new one's taken;
 *     once mapped, buffer, buffer_bytes and buffer_memory are set.
 * @param memory The memory, which the server takes over: kept, or closed when it's refused; but if addresses
 *     can't be reserved for it, it isn't closed.
 * @return Null once it's mapped; NoBuffer if it's empty, larger than MAX_BUFFER_BYTES, or couldn't be mapped.
 */
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

/**
 * Tell whether a transfer's bytes are all in a connection's buffer.
 *
 * @param connection A file connection's slot, whose buffer and buffer_bytes are read.
 * @param transfer The Read or Write asked for; its buffer_offset and count, in bytes, are checked, and its offset in
 *     the file isn't.
 * @return Whether it has a buffer and the transfer's offset and count, in bytes, are inside it.
 */
fits :: fn(connection: ptr[Connection], transfer: files.Transfer) -> bool {
    return connection.buffer != 0 && cast[u64](transfer.buffer_offset) + cast[u64](transfer.count) <= connection.buffer_bytes
}

/**
 * Give where a transfer's bytes are in a connection's buffer.
 *
 * @param connection A file connection's slot, with a buffer mapped.
 * @param transfer The transfer, which fits.
 * @return A view of the buffer, good while it's mapped; the client may change it meanwhile.
 */
buffer_of :: fn(connection: ptr[Connection], transfer: files.Transfer) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](connection.buffer + cast[u64](transfer.buffer_offset)), cast[usize](transfer.count))
}

/**
 * Read a file into its connection's buffer, from its entry as it is now, so what other connections wrote is seen.
 *
 * @param server Unused.
 * @param volume The mounted volume, main's, only read: nothing on it is written.
 * @param connection A file or read-only file connection's slot: its place and name find the entry afresh, and its
 *     buffer is read into.
 * @param transfer Where to read from in the file and to in the buffer, and how many bytes.
 * @return How many bytes were read: fewer than asked only at the file's end, 0 past it.
 * @error NoBuffer The connection has no buffer, or the transfer doesn't fit in it.
 * @error NotFound The file's entry isn't there any more.
 * @error DeviceError The disk refused a read.
 * @error Corrupt The file's clusters couldn't be followed.
 */
read_file :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], connection: ptr[Connection], transfer: files.Transfer) -> Result[u32, files.FileError] {
    if !fits(connection, transfer) {
        return .Error(.NoBuffer)
    }
    into :: buffer_of(connection, transfer)
    entry := fat.entry_at(volume, connection.place, name_of(connection)) or_return .Error(.NotFound)
    match fat.read(volume, &entry, transfer.offset, into) {
        case Ok(count) => return .Ok(cast[u32](count))
        case Error(error) => return .Error(file_error(error))
    }
}

/**
 * Answer a file connection's requests, until it has none, or it's gone.
 *
 * Every write goes to the disk at once; Sync is a Flush, and after a failed write every Sync fails. Connect adds a
 * connection to the same file, and Narrow makes a read-only one. A connection whose end fails is dropped.
 *
 * @param server The FAT server's state: answers go on the slot's end, Narrow and Connect add slots, setting added, Sync
 *     flushes its disk, and a failed end drops the slot.
 * @param volume The mounted volume, main's: Write and SetSize change the file, written to the disk at once, and a
 *     failed write sets its failed, so every Sync fails after.
 * @param index The connection's slot among server's connections; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_file :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], index: usize, into: ptr[mut os.Incoming]) {
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
            case _ => {
                drop(server, index)
                return void
            }
        }
        connection :: &server.connections[index]
        out := os.Outgoing.{}
        response :: os.begin[file.Response](&out)
        response^ = .Unsupported
        match os.message_of[file.Request](into)^ {
            case UseBuffer(memory) => response^ = if use_buffer(connection, memory) is_none { file.Response.Done } else { file.Response.Failed(.NoBuffer) }
            case Read(transfer) => {
                match read_file(server, volume, connection, transfer) {
                    case Ok(count) => response^ = .Transferred(count)
                    case Error(error) => response^ = .Failed(error)
                }
            }
            case Write(transfer) => {
                if !fits(connection, transfer) {
                    response^ = .Failed(.NoBuffer)
                }
                else {
                    match fat.entry_at(volume, connection.place, name_of(connection)) {
                        case Ok(found) => {
                            entry := found
                            match fat.write(volume, &entry, transfer.offset, buffer_of(connection, transfer)) {
                                case Ok(count) => response^ = .Transferred(cast[u32](count))
                                case Error(error) => response^ = .Failed(file_error(error))
                            }
                        }
                        case Error(error) => response^ = .Failed(file_error(error))
                    }
                }
            }
            case SetSize(size) => {
                match fat.entry_at(volume, connection.place, name_of(connection)) {
                    case Ok(found) => {
                        entry := found
                        match fat.set_size(volume, &entry, size) {
                            case Ok => response^ = .Done
                            case Error(error) => response^ = .Failed(file_error(error))
                        }
                    }
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case Info => {
                match fat.entry_at(volume, connection.place, name_of(connection)) {
                    case Ok(entry) => response^ = .Described(info_of(&out, .File, cast[u64](entry.size), name_of(connection)))
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case Sync => response^ = if !volume.failed && done(call(server, .Flush(4))) { file.Response.Done } else { file.Response.Failed(.DeviceError) }
            case Narrow => {
                match open_connection[read_only_file.ReadOnlyFile](server, .ReadOnlyFile, 0, connection.place, true, name_of(connection)) {
                    case Some(made) => response^ = .Narrowed(made)
                    case None => response^ = .Failed(.NoSpace)
                }
            }
            case Connect(other) => {
                _ = add(server, .File, other.end, 0, connection.place, false, name_of(connection))
                continue
            }
            case _ => {}
        }
        _ = file.send_response(end, server.port, &out)
    }
}

/**
 * Answer a read-only file connection's requests, until it has none, or it's gone: UseBuffer, Read, Info, and
 * Connect, which adds a connection to the same file with no answer. A connection whose end fails is dropped.
 *
 * @param server The FAT server's state: answers go on the slot's end, Connect adds a read-only slot, setting added, and
 *     a failed end drops the slot.
 * @param volume The mounted volume, main's, only read: nothing on it is written through a read-only file.
 * @param index The connection's slot among server's connections; one past them is left alone.
 * @param into Where each request is read into, reused.
 */
serve_read_only_file :: fn(server: ptr[mut Server], volume: ptr[mut fat.Volume], index: usize, into: ptr[mut os.Incoming]) {
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
            case _ => {
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
                match read_file(server, volume, connection, transfer) {
                    case Ok(count) => response^ = .Transferred(count)
                    case Error(error) => response^ = .Failed(error)
                }
            }
            case Info => {
                match fat.entry_at(volume, connection.place, name_of(connection)) {
                    case Ok(entry) => response^ = .Described(info_of(&out, .File, cast[u64](entry.size), name_of(connection)))
                    case Error(error) => response^ = .Failed(file_error(error))
                }
            }
            case Connect(other) => {
                _ = add(server, .ReadOnlyFile, other.end, 0, connection.place, true, name_of(connection))
                continue
            }
        }
        _ = read_only_file.send_response(end, server.port, &out)
    }
}
