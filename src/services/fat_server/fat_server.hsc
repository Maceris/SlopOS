/*
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

MAX_CONNECTIONS :: 64
// The most bytes of a client's buffer mapped here
MAX_BUFFER_BYTES : u64 : 16 << 20

Kind :: enum {
    Free,
    Dir,
    ReadOnlyDir,
    File,
    ReadOnlyFile,
    FileSet,
}

/*
 * A connection: what it's to (a directory's first cluster, or a file's place), its informational name (a set's
 * pattern), and a file's buffer, mapped here.
 */
Connection :: struct {
    kind : Kind,
    end : slop_os.Channel,
    directory : u32,
    place : fat.Place,
    read_only : bool,
    name : u8[files.PATH_BYTES],
    name_length : u32,
    buffer : u64,
    buffer_bytes : u64,
    buffer_memory : slop_os.Memory,
}

Server :: struct {
    log : slop_os.DebugLog,
    port : slop_os.Port,
    disk : slop_os.Channel,
    disk_port : slop_os.Port,
    disk_buffer : u64,
    disk_buffer_bytes : u64,
    read_only : bool,
    connections : Connection[MAX_CONNECTIONS],
    count : usize,
    // Whether a connection was added during this pass, which may have taken a free slot it's already past
    added : bool,
}

main :: fn(log: slop_os.DebugLog?, partition: os.Channel[block.Block], clients: os.Listener[dir.Dir]) -> int {
    startup :: slop_os.startup_block()
    server := runtime.new(Server)
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

// The wall clock's time as FAT holds it, or the epoch without a wall clock.
stamp_now :: fn() -> u32 {
    match time.now() {
        case Ok(now) => {
            at :: time.utc(now)
            return fat.stamp_of(at.year, at.month, at.day, at.hour, at.minute, at.second)
        }
        case Error(error) => return fat.EPOCH_STAMP
    }
}

read_write :: fn() -> slop_os.Protection {
    return cast[slop_os.Protection](cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_WRITE))
}

// The disk, a request at a time

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

/*
 * A connection on end, bound to the port under its index, and read until it's empty: its index, or null with end
 * closed if there's no room.
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

// A new connection of kind P's protocol: the other end, for the client, or null.
open_connection :: fn[P](server: ptr[mut Server], kind: Kind, directory: u32, place: fat.Place, read_only: bool, name: string) -> os.Channel[P]? {
    startup :: slop_os.startup_block()
    pair :: os.channel_for[P](startup.budget, 0) or_return null
    if add(server, kind, pair.a, directory, place, read_only, name) is_none {
        _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
        return null
    }
    return os.Channel[P].{end = pair.b}
}

// A connection whose client went: its end closed, its buffer unmapped.
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

// A path's text from a message, if it's no longer than a path may be.
path_of :: fn(into: ptr[os.Incoming], path: slop_os.Relative[u8]) -> string? {
    bytes :: os.items(into, path)
    if bytes.count == 0 || bytes.count > files.PATH_BYTES {
        return null
    }
    return string_of(&bytes[0], bytes.count)
}

// Where a path's last component goes: the directory that holds it, and its name.
Leaf :: struct {
    directory : u32,
    name : string,
}

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

// The file at path beneath directory, opened as creation says.
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

// The directory at path beneath directory, made, with any missing on the way to it, if create.
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

// A listing's entry at or after cursor, matching pattern unless it's "".
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
        return .Ok(files.Listing.{name = os.append(out, view_of(cast[ptr[u8]](name.data), name.count)), kind = kind,
            size = cast[u64](listed.entry.size), next = cast[u64](slot)})
    }
}

same_byte :: fn(a: u8, b: u8) -> bool {
    return fat.upper(a) == fat.upper(b)
}

info_of :: fn(out: ptr[mut os.Outgoing], kind: files.Kind, size: u64, name: string) -> files.Info {
    return files.Info.{kind = kind, size = size, name = os.append(out, view_of(cast[ptr[u8]](name.data), name.count))}
}

features :: fn() -> files.Features {
    return files.Features.{ignores_case = true}
}

// Directories

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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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
            case Sync => response^ = if done(call(server, .Flush(3))) { dir.Response.Done } else { dir.Response.Failed(.DeviceError) }
            case Features => response^ = .Supports(features())
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

// What's at from moved to to, both beneath directory.
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

// A read-only file at path beneath directory, for a dir or a read_only_dir.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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

// Whether a name is one of a set's: one component, matching its pattern.
in_set :: fn(pattern: string, name: string) -> bool {
    for character in name {
        if character == '/' {
            return false
        }
    }
    return name.count != 0 && file_set.matches(pattern, name, same_byte)
}

// Files

// A file connection's buffer: its client's memory, mapped here.
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

// Whether a transfer's bytes are all in a connection's buffer.
fits :: fn(connection: ptr[Connection], transfer: files.Transfer) -> bool {
    return connection.buffer != 0 && cast[u64](transfer.buffer_offset) + cast[u64](transfer.count) <= connection.buffer_bytes
}

// Where a transfer's bytes are in a connection's buffer, which they fit in.
buffer_of :: fn(connection: ptr[Connection], transfer: files.Transfer) -> mut u8[] {
    return view_of(cast[ptr[mut u8]](connection.buffer + cast[u64](transfer.buffer_offset)), cast[usize](transfer.count))
}

// A file's read, from its entry as it is now.
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
            case Invalid => continue
            case WrongProtocol => continue
            case Failed(error) => {
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
            case Sync => response^ = if done(call(server, .Flush(4))) { file.Response.Done } else { file.Response.Failed(.DeviceError) }
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
