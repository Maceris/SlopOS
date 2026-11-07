/**
 * What the file tools share (decisions/0179): list, copy, move, remove and recover, programs each, which take the
 * shell's directory as here. Snapshots asked for on a dir connection, and a tree copied, from a directory or from one as
 * a snapshot has it, into a directory, its files' bytes read and written through std/os's files.
 */
package file_tools

import runtime from "base"
import os from "std"
import strings from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import files from "std/os/slop_os"
import lifecycle from "std/os/slop_os"
import read_only_dir from "std/os/slop_os"

/** How many bytes are read and written at a time when a file's copied: 64 KiB, a File's buffer. */
COPY_BYTES :: 64 * 1024

/** What's at a path: nothing, a file, or a directory. */
Kind :: enum {
    /** Nothing, or what can't be told. */
    Missing,
    /** A file, of bytes or a typed value. */
    File,
    /** A directory. */
    Directory,
}

/** A snapshot of the volume, as a dir's Snapshots lists them. */
Seen :: struct {
    /** Its name, on the heap, freed with free_seen. */
    name : string,
    /** When it was taken, in nanoseconds since 1970. */
    taken : u64,
}

/**
 * Where a tree's copied from: a directory, through std/os, or a directory as a snapshot has it, read only, through its
 * read_only_dir connection.
 */
Source :: struct {
    /** The directory, for the live one; its handle 0 for a snapshot's. */
    live : os.Directory,
    /** A snapshot's directory's connection, speaking read_only_dir, the Source's; NO_HANDLE for the live one. */
    past : slop_os.Channel,
    /** A port bound to past. */
    port : slop_os.Port,
}

/** What a copy did: how many files it copied and how many of their bytes, and the directories it made. */
Copied :: struct {
    /** The files copied. */
    files : u64,
    /** Their bytes. */
    bytes : u64,
    /** The directories made. */
    directories : u64,
}

/** Where a copy stopped, and why. */
Stopped :: struct {
    /** The path it stopped at, beneath the copy's destination's directory, on the heap. */
    path : string,
    /** Why. */
    why : os.OsError,
}

// ---- A dir connection's requests

/**
 * Send one request on a dir connection and wait for its answer.
 *
 * @param end The connection, speaking dir.
 * @param port A port bound to end.
 * @param out The request, built with os.begin[dir.Request]; its handles move out when it's sent.
 * @param into Where the answer goes, for os.message_of[dir.Response].
 * @return Whether the answer came; false if it couldn't be sent or the connection's gone.
 */
ask_dir :: fn(end: slop_os.Channel, port: slop_os.Port, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> bool {
    if dir.send_request(end, port, out) is_some {
        return false
    }
    return match dir.receive_response(end, port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Take a snapshot of the whole volume a directory's on, through its dir connection (Snapshot), holding everything done
 * before it.
 *
 * @param end The directory's connection, speaking dir; kept.
 * @return The snapshot's name, on the heap, the caller's; why not, as the server said: Unsupported, as from a file
 *     system without snapshots, is Unavailable.
 */
take_snapshot :: fn(end: slop_os.Channel) -> Result[string, files.FileError] {
    port :: os.port_for(slop_os.startup_block().budget, end) or_return .Error(.NoMemory)
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    os.begin[dir.Request](&out)^ = .Snapshot
    into := os.Incoming.{}
    if !ask_dir(end, port, &out, &into) {
        return .Error(.Unavailable)
    }
    return match os.message_of[dir.Response](&into)^ {
        case Snapshotted(taken) => .Ok(copy_of(os.items(&into, taken.name)) or_return .Error(.NoMemory))
        case Failed(error) => .Error(error)
        case _ => .Error(.Unavailable)
    }
}

/**
 * List the volume's snapshots, newest first, through a directory's dir connection (Snapshots).
 *
 * @param end The directory's connection, speaking dir; kept.
 * @param into Where they're added, newest first; each name on the heap, freed with free_seen.
 * @return Null once they're all listed; why not, as the server said.
 */
snapshots_of :: fn(end: slop_os.Channel, into: ptr[mut Seen[..]]) -> files.FileError? {
    port :: os.port_for(slop_os.startup_block().budget, end) or_return files.FileError.NoMemory
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    oldest_first : Seen[..]
    defer runtime.array_free(&oldest_first)
    cursor := cast[u64](0)
    loop {
        out := os.Outgoing.{}
        os.begin[dir.Request](&out)^ = .Snapshots(cursor)
        answer := os.Incoming.{}
        if !ask_dir(end, port, &out, &answer) {
            return files.FileError.Unavailable
        }
        match os.message_of[dir.Response](&answer)^ {
            case SnapshotListed(listed) => {
                name :: copy_of(os.items(&answer, listed.name)) or_return files.FileError.NoMemory
                runtime.array_add(&oldest_first, Seen.{name = name, taken = listed.taken})
                cursor = listed.next
            }
            case End => break
            case Failed(error) => return error
            case _ => return files.FileError.Unavailable
        }
    }
    with {
        i := oldest_first.count
    }
    loop {
        i -= 1
        if i < oldest_first.count {
            runtime.array_add(into, oldest_first[i])
        }
    }
    while i > 0
    return null
}

/**
 * Free the names of snapshots listed, and the list.
 *
 * @param seen The list, from snapshots_of; left empty.
 */
free_seen :: fn(seen: ptr[mut Seen[..]]) {
    for each in seen^ {
        strings.free_string(each.name)
    }
    runtime.array_free(seen)
}

/**
 * Open a directory as a snapshot has it, read only, through its dir connection (OpenSnapshot).
 *
 * @param end The directory's connection, speaking dir; kept.
 * @param name The snapshot's name, as snapshots_of gives it.
 * @return The directory in the snapshot, as a Source the caller closes with close_source; NotFound if the snapshot, or
 *     the directory in it, isn't there; why not otherwise, as the server said.
 */
open_snapshot :: fn(end: slop_os.Channel, name: string) -> Result[Source, files.FileError] {
    port :: os.port_for(slop_os.startup_block().budget, end) or_return .Error(.NoMemory)
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    out := os.Outgoing.{}
    // begin's pointer first: the append on the right would otherwise land before the message
    request :: os.begin[dir.Request](&out)
    request^ = .OpenSnapshot(os.append(&out, string_bytes(name)))
    into := os.Incoming.{}
    if !ask_dir(end, port, &out, &into) {
        return .Error(.Unavailable)
    }
    match os.message_of[dir.Response](&into)^ {
        case Narrowed(made) => {
            past_port :: os.port_for(slop_os.startup_block().budget, made.end) or_else cast[slop_os.Port](slop_os.NO_HANDLE)
            if cast[slop_os.Handle](past_port) == slop_os.NO_HANDLE {
                _ = slop_os.handle_close(cast[slop_os.Handle](made.end))
                return .Error(.NoMemory)
            }
            return .Ok(Source.{live = os.Directory.{0}, past = made.end, port = past_port})
        }
        case Failed(error) => return .Error(error)
        case _ => return .Error(.Unavailable)
    }
}

/**
 * Make a Source of a live directory.
 *
 * @param directory The directory, kept by the caller; close_source doesn't close it.
 * @return The Source.
 */
live_source :: fn(directory: os.Directory) -> Source {
    return Source.{live = directory, past = cast[slop_os.Channel](slop_os.NO_HANDLE), port = cast[slop_os.Port](slop_os.NO_HANDLE)}
}

/**
 * Close a snapshot's Source; a live one's directory is left to its owner.
 *
 * @param source The Source; a snapshot's connection and port are closed.
 */
close_source :: fn(source: Source) {
    if cast[slop_os.Handle](source.past) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](source.port))
        _ = slop_os.handle_close(cast[slop_os.Handle](source.past))
    }
}

// ---- Reading a Source

/**
 * Ask a snapshot's directory something, and wait for its answer.
 *
 * @param source A snapshot's Source.
 * @param out The request, built with os.begin[read_only_dir.Request].
 * @param into Where the answer goes, for os.message_of[read_only_dir.Response].
 * @return Whether the answer came.
 */
ask_past :: fn(source: Source, out: ptr[mut os.Outgoing], into: ptr[mut os.Incoming]) -> bool {
    if read_only_dir.send_request(source.past, source.port, out) is_some {
        return false
    }
    return match read_only_dir.receive_response(source.past, source.port, into, true) {
        case Received => true
        case _ => false
    }
}

/**
 * Tell what's at a path beneath a Source's directory.
 *
 * @param source The Source.
 * @param path The path, relative, its parts separated by /.
 * @return File, Directory, or Missing for nothing there or what can't be told.
 */
kind_at :: fn(source: Source, path: string) -> Kind {
    if cast[slop_os.Handle](source.past) == slop_os.NO_HANDLE {
        return match os.path_kind_in(source.live, path) {
            case .FILE => Kind.File
            case .DIRECTORY => Kind.Directory
            case _ => Kind.Missing
        }
    }
    opened :: past_directory(source, path) or_else cast[slop_os.Channel](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](opened) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](opened))
        return .Directory
    }
    file :: past_file(source, path) or_else cast[slop_os.Channel](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](file) != slop_os.NO_HANDLE {
        _ = slop_os.handle_close(cast[slop_os.Handle](file))
        return .File
    }
    return .Missing
}

/**
 * Open a directory beneath a snapshot's.
 *
 * @param source A snapshot's Source.
 * @param path Its path.
 * @return Its connection, speaking read_only_dir, the caller's; null if it isn't a directory there.
 */
past_directory :: fn(source: Source, path: string) -> slop_os.Channel? {
    out := os.Outgoing.{}
    request :: os.begin[read_only_dir.Request](&out)
    request^ = .OpenDirectory(os.append(&out, string_bytes(path)))
    into := os.Incoming.{}
    if !ask_past(source, &out, &into) {
        return null
    }
    return match os.message_of[read_only_dir.Response](&into)^ {
        case OpenedDirectory(made) => made.end
        case _ => null
    }
}

/**
 * Open a file beneath a snapshot's directory, to read.
 *
 * @param source A snapshot's Source.
 * @param path Its path.
 * @return Its connection, speaking read_only_file, the caller's; null if it isn't a file there.
 */
past_file :: fn(source: Source, path: string) -> slop_os.Channel? {
    out := os.Outgoing.{}
    request :: os.begin[read_only_dir.Request](&out)
    request^ = .OpenReadOnlyFile(os.append(&out, string_bytes(path)))
    into := os.Incoming.{}
    if !ask_past(source, &out, &into) {
        return null
    }
    return match os.message_of[read_only_dir.Response](&into)^ {
        case OpenedReadOnlyFile(made) => made.end
        case _ => null
    }
}

/**
 * List the names in a directory beneath a Source's, or in it.
 *
 * @param source The Source.
 * @param path The directory's path; "" for the Source's own.
 * @param names Where its entries' names go, each on the heap, freed with free_names, and whether each is a directory.
 * @return Null once they're listed; why not otherwise.
 */
names_at :: fn(source: Source, path: string, names: ptr[mut os.DirectoryEntry[..]]) -> os.OsError? {
    if cast[slop_os.Handle](source.past) == slop_os.NO_HANDLE {
        match os.list_directory_in(source.live, if path.count == 0 { "." } else { path }) {
            case Ok(listed) => {
                for each in listed {
                    runtime.array_add(names, os.DirectoryEntry.{name = strings.clone(each.name) or_continue, is_directory = each.is_directory})
                }
                os.free_directory_listing(listed)
                return null
            }
            case Error(error) => return error
        }
    }
    opened := source.past
    if path.count > 0 {
        opened = past_directory(source, path) or_return os.OsError.NotFound
    }
    defer if path.count > 0 {
        _ = slop_os.handle_close(cast[slop_os.Handle](opened))
    }
    port :: os.port_for(slop_os.startup_block().budget, opened) or_return os.OsError.OutOfMemory
    defer slop_os.handle_close(cast[slop_os.Handle](port))
    listing :: Source.{live = os.Directory.{0}, past = opened, port = port}
    cursor := cast[u64](0)
    loop {
        out := os.Outgoing.{}
        os.begin[read_only_dir.Request](&out)^ = .List(cursor)
        into := os.Incoming.{}
        if !ask_past(listing, &out, &into) {
            return os.OsError.Other
        }
        match os.message_of[read_only_dir.Response](&into)^ {
            case Listed(entry) => {
                name :: copy_of(os.items(&into, entry.name)) or_return os.OsError.OutOfMemory
                runtime.array_add(names, os.DirectoryEntry.{name = name, is_directory = entry.kind == .Directory})
                cursor = entry.next
            }
            case End => return null
            case _ => return os.OsError.Other
        }
    }
}

/**
 * Free names listed, and the list.
 *
 * @param names The list, from names_at; left empty.
 */
free_names :: fn(names: ptr[mut os.DirectoryEntry[..]]) {
    for each in names^ {
        strings.free_string(each.name)
    }
    runtime.array_free(names)
}

/**
 * Open a file beneath a Source's directory, to read.
 *
 * @param source The Source.
 * @param path The file's path.
 * @return The File, which the caller closes with os.close; why not otherwise.
 */
open_to_read :: fn(source: Source, path: string) -> Result[os.File, os.OsError] {
    if cast[slop_os.Handle](source.past) == slop_os.NO_HANDLE {
        return os.open_in(source.live, path, .READ)
    }
    end :: past_file(source, path) or_return .Error(.NotFound)
    file, error :: os.file_on(end, false)
    match error {
        case Some(failed) => return .Error(failed)
        case None => return .Ok(file)
    }
}

// ---- Copying

/**
 * Count the files beneath a path of a Source, or 1 for a file, for a copy's progress.
 *
 * @param source The Source.
 * @param path The path.
 * @return How many files; 0 for nothing there, and what can't be listed counts as nothing.
 */
count_files :: fn(source: Source, path: string) -> u64 {
    match kind_at(source, path) {
        case .File => return 1
        case .Missing => return 0
        case .Directory => {}
    }
    names : os.DirectoryEntry[..]
    defer free_names(&names)
    if names_at(source, path, &names) is_some {
        return 0
    }
    counted := cast[u64](0)
    for each in names {
        inner :: joined(path, each.name) or_continue
        counted += count_files(source, inner)
        strings.free_string(inner)
    }
    return counted
}

/**
 * Copy what's at a path of a Source, a file or a whole directory, to a path beneath a directory: a file's bytes written
 * to a file there, made or emptied; a directory made there, and what's in it copied into it. Its progress is reported
 * on the lifecycle channel after each file, out of total.
 *
 * @param source Where it's copied from.
 * @param from Its path beneath the Source's directory.
 * @param into The directory it's copied into.
 * @param to Its path beneath into; a directory on the way has to be there.
 * @param total How many files there are in all, for its progress (count_files); 0 reports none.
 * @param copied What's been copied, which this adds to.
 * @return Null once it's copied; where it stopped, and why, otherwise, with what was copied before it left.
 */
copy_tree :: fn(source: Source, from: string, into: os.Directory, to: string, total: u64, copied: ptr[mut Copied]) -> Stopped? {
    match kind_at(source, from) {
        case .Missing => return stopped(to, .NotFound)
        case .File => return copy_file(source, from, into, to, total, copied)
        case .Directory => {}
    }
    match os.make_directory_in(into, to) {
        case Some(error) => {
            if error != .AlreadyExists {
                return stopped(to, error)
            }
        }
        case None => copied.directories += 1
    }
    names : os.DirectoryEntry[..]
    defer free_names(&names)
    match names_at(source, from, &names) {
        case Some(error) => return stopped(to, error)
        case None => {}
    }
    for each in names {
        inner_from :: joined(from, each.name) or_return stopped(to, .OutOfMemory)
        defer strings.free_string(inner_from)
        inner_to :: joined(to, each.name) or_return stopped(to, .OutOfMemory)
        defer strings.free_string(inner_to)
        match copy_tree(source, inner_from, into, inner_to, total, copied) {
            case Some(stop) => return stop
            case None => {}
        }
    }
    return null
}

/**
 * Copy a file's bytes from a Source to a file beneath a directory, made or emptied, and report its progress.
 *
 * @param source Where it's read from.
 * @param from Its path beneath the Source's directory.
 * @param into The directory it's written beneath.
 * @param to Its path there.
 * @param total How many files the copy has in all; 0 reports none.
 * @param copied What's been copied, to which its bytes and the file are added once it's written.
 * @return Null once it's written; where it stopped, and why, otherwise.
 */
copy_file :: fn(source: Source, from: string, into: os.Directory, to: string, total: u64, copied: ptr[mut Copied]) -> Stopped? {
    reading :: match open_to_read(source, from) {
        case Ok(file) => file
        case Error(error) => return stopped(to, error)
    }
    defer os.close(reading)
    writing :: match os.open_in(into, to, .WRITE) {
        case Ok(file) => file
        case Error(error) => return stopped(to, error)
    }
    defer os.close(writing)
    chunk : u8[COPY_BYTES]
    loop {
        count :: match os.read(reading, chunk) {
            case Ok(read) => read
            case Error(error) => return stopped(to, error)
        }
        if count == 0 {
            break
        }
        match os.write(writing, string_of(&chunk[0], count)) {
            case Some(error) => return stopped(to, error)
            case None => {}
        }
        copied.bytes += cast[u64](count)
    }
    copied.files += 1
    if total > 0 {
        _ = lifecycle.report_progress(copied.files, total)
    }
    return null
}

/**
 * Say where a copy stopped, and why.
 *
 * @param path Where, copied to the heap; "" if it couldn't be.
 * @param why Why.
 * @return The Stopped.
 */
stopped :: fn(path: string, why: os.OsError) -> Stopped {
    return Stopped.{path = strings.clone(path) or_else "", why = why}
}

// ---- Paths

/**
 * Join a directory's path and a name in it.
 *
 * @param path The directory's path; "" or "." for the directory itself.
 * @param name The name.
 * @return path/name, or name alone for "" or ".", on the heap, the caller's; null without the memory.
 */
joined :: fn(path: string, name: string) -> string? {
    if path.count == 0 || path == "." {
        return strings.clone(name) or_return null
    }
    return strings.format("%1/%2", path, name) or_return null
}

/**
 * Give a path's last name.
 *
 * @param path The path, its parts separated by /; one ending in / has it dropped first.
 * @return A view of its last part.
 */
last_name :: fn(path: string) -> string {
    // Where the last part starts and ends: after the last / that isn't the path's last byte
    start : usize = 0
    end : usize = 0
    for byte, i in string_bytes(path) {
        if byte == cast[u8]('/') {
            if i + 1 < path.count {
                start = i + 1
            }
        }
        else {
            end = i + 1
        }
    }
    return string_of_view(path, start, end)
}

/**
 * Give a view of part of a string.
 *
 * @param text The string.
 * @param start Where it starts, at most end.
 * @param end Where it ends, at most text's count.
 * @return The view; empty if start or end is out of order or past text.
 */
string_of_view :: fn(text: string, start: usize, end: usize) -> string {
    bytes :: string_bytes(text)
    if start >= end || end > bytes.count || start >= bytes.count {
        return ""
    }
    return string_of(&bytes[start], end - start)
}

/**
 * Copy bytes to the heap, as a string.
 *
 * @param bytes UTF-8, as a message holds a name.
 * @return The copy, the caller's, freed with strings.free_string; "" for none; null without the memory.
 */
copy_of :: fn(bytes: u8[]) -> string? {
    if bytes.count == 0 {
        return ""
    }
    return strings.clone(string_of(&bytes[0], bytes.count)) or_return null
}
