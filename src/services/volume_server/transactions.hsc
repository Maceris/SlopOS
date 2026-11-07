package volume_server

import runtime from "base"
import os from "std"
import slop_os from "std/os"
import dir from "std/os/slop_os"
import file from "std/os/slop_os"
import files from "std/os/slop_os"
import slopfs from "../../slopfs"
import container from "../../protocols/container"

/*
 * Transactions under a directory (decisions/0046, 0089). A transaction's changes are logged, as they're asked for, in
 * memory its client gives with Begin, so they're charged to the client and capped by what it gives; each records the
 * version of what it reads or changes on the way (the transaction its object last changed in). Commit checks none of
 * them changed meanwhile (Conflict if one did), then applies the log in order and commits, all in one transaction of
 * the volume, which is atomic; if applying fails partway, the volume goes back to its last commit, the container
 * service undoing its allocations (Abandon), so nothing of it is left.
 *
 * Reads on a transaction see the volume as it is. An object with changes not yet committed is committed before a
 * transaction records its version, so a change anyone makes after that is a newer version.
 */

/** The most transactions open at once; a Begin past them is refused with NoBuffer. */
MAX_TRANSACTIONS :: 16
/** The most objects a transaction records the versions of; past them, its commit is refused as a conflict. */
MAX_VERSIONS :: 64

/** What a logged change is, as LogHead's op holds it. */
Op :: enum #backed_by(u32) {
    /** A file opened, as its creation says. */
    OpenFile = 1,
    /** A file's bytes written, at an offset. */
    Write = 2,
    /** A file's size set. */
    SetSize = 3,
    /** What's at a path removed. */
    Remove = 4,
    /** What's at a path moved to another. */
    Rename = 5,
}

/**
 * A logged change: what, a number (a write's offset, a size, a file's creation), its data's bytes, and its paths'
 * bytes. Its path's, its to's and its data's bytes follow it in the log, in that order.
 */
LogHead :: struct #packed {
    /** Op's value. */
    op : u32le,
    /** An OpenFile's files.Creation's value; 0 for another op. */
    creation : u32le,
    /** A write's offset or a size, in bytes; 0 for another op. */
    number : u64le,
    /** How many data bytes follow the paths: a write's. */
    data_bytes : u32le,
    /** How many bytes the path is, relative to the transaction's directory. */
    path_bytes : u16le,
    /** How many bytes a rename's to path is; 0 for another op. */
    to_bytes : u16le,
}

#assert size_of(LogHead) == 24

/** The version of an object a transaction read or changed: the transaction of the volume it last changed in. */
Version :: struct {
    /** The object. */
    object : u64,
    /** The volume's transaction it last changed in, which must be the same at commit. */
    changed : u64,
}

/** A transaction under a directory: its log, in its client's memory, and the versions it recorded. */
Transaction :: struct {
    /** Whether the slot holds a transaction. */
    active : bool,
    /** The directory object it's beneath, which its paths are relative to. */
    directory : u64,
    /**
     * The log's memory, its client's, the server's handle to it, closed when the transaction ends. Written and read
     * through memory_write and memory_read, never mapped, so its client ending fails the transaction rather than the
     * server (decisions/0098, 0181's F6).
     */
    memory : slop_os.Memory,
    /** The log's size in bytes, at most MAX_BUFFER_BYTES. */
    log_bytes : u64,
    /** How many of the log's bytes are logged changes. */
    used : u64,
    /** The versions recorded, version_count of them. */
    versions : Version[MAX_VERSIONS],
    /** How many of versions are recorded. */
    version_count : usize,
    /** Whether there were too many versions to record, so its commit is refused as a conflict. */
    overflowed : bool,
}

/**
 * Begin a transaction beneath a directory, its log in memory its client gives, kept to copy through, so the log is
 * charged to the client and capped by what it gives.
 *
 * @param server The server, whose first free transaction slot is taken; directory isn't checked here.
 * @param directory The directory object it's beneath.
 * @param memory The log's memory, kept by the transaction once it's begun; the caller closes it when it isn't.
 * @return The transaction's index; null if MAX_TRANSACTIONS are open, or the memory's size can't be had, or is smaller
 *     than a LogHead or larger than MAX_BUFFER_BYTES.
 */
begin :: fn(server: ptr[mut Server], directory: u64, memory: slop_os.Memory) -> usize? {
    for transaction, i in server.transactions {
        if transaction.active {
            continue
        }
        size :: slop_os.memory_size(memory) or_else 0
        if size < cast[u64](size_of(LogHead)) || size > MAX_BUFFER_BYTES {
            return null
        }
        if i < server.transactions.count {
            server.transactions[i] = Transaction.{active = true, directory = directory, memory = memory, log_bytes = size}
        }
        return i
    }
    return null
}

/**
 * End a transaction, aborting what it logged: close its log's memory, freeing its slot.
 *
 * @param server The server, whose transaction slot is emptied: its log's memory closed, nothing logged applied.
 * @param index The transaction's index; one not open is left alone.
 */
end_transaction :: fn(server: ptr[mut Server], index: usize) {
    if index >= server.transactions.count || !server.transactions[index].active {
        return void
    }
    transaction :: server.transactions[index]
    _ = slop_os.handle_close(cast[slop_os.Handle](transaction.memory))
    server.transactions[index] = Transaction.{}
}

/**
 * Empty a transaction's log and versions, to begin again after a commit or an abort.
 *
 * @param server The server, whose transaction's used, version_count and overflowed are cleared; its log's memory is
 *     kept.
 * @param index The transaction's index; one past them is ignored.
 */
reset :: fn(server: ptr[mut Server], index: usize) {
    if index < server.transactions.count {
        server.transactions[index].used = 0
        server.transactions[index].version_count = 0
        server.transactions[index].overflowed = false
    }
}

/**
 * Log a change at the end of a transaction's log.
 *
 * @param server The server, whose transaction's log, in its client's memory, is written at its end through
 *     memory_write and its used counted up.
 * @param index The transaction's slot in server's transactions, as begin gave it; one past them logs nothing. An
 *     inactive slot has no log, so it has no room.
 * @param op What change it is, written as its value.
 * @param creation An OpenFile's files.Creation's value; 0 otherwise.
 * @param number A write's offset or a size, in bytes; 0 otherwise.
 * @param path Its path, relative to the transaction's directory, at most 0xffff bytes.
 * @param to A rename's to path, at most 0xffff bytes; "" otherwise.
 * @param data A write's bytes; none otherwise.
 * @return Whether it was logged; false if the log hasn't the room, a path is too long, there's no such transaction, or
 *     the log couldn't be written: its client ended, or the memory's gone. What failed to be written isn't counted.
 */
log_op :: fn(server: ptr[mut Server], index: usize, op: Op, creation: u32, number: u64, path: string, to: string, data: u8[]) -> bool {
    if index >= server.transactions.count {
        return false
    }
    transaction :: &server.transactions[index]
    length :: cast[u64](size_of(LogHead) + path.count + to.count + data.count)
    if transaction.used + length > transaction.log_bytes || path.count > 0xffff || to.count > 0xffff {
        return false
    }
    head := LogHead.{op = cast[u32le](cast[u32](op)), creation = cast[u32le](creation), number = cast[u64le](number),
        data_bytes = cast[u32le](cast[u32](data.count)), path_bytes = cast[u16le](cast[u16](path.count)), to_bytes = cast[u16le](cast[u16](to.count))}
    at := transaction.used
    if !log_part(transaction.memory, &at, view_of(cast[ptr[u8]](&head), size_of(LogHead))) || !log_part(transaction.memory, &at, string_bytes(path))
        || !log_part(transaction.memory, &at, string_bytes(to)) || !log_part(transaction.memory, &at, data) {
        return false
    }
    transaction.used += length
    return true
}

/**
 * Write part of a logged change into a transaction's log, its client's memory, through memory_write.
 *
 * @param memory The log's memory.
 * @param at Where in the log it goes, in bytes; moved past it once it's written.
 * @param part The bytes; none writes nothing.
 * @return Whether it was written; false if the memory couldn't be: its client ended, or it's gone.
 */
log_part :: fn(memory: slop_os.Memory, at: ptr[mut u64], part: u8[]) -> bool {
    if part.count > 0 && (slop_os.memory_write(memory, at^, part) is_error) {
        return false
    }
    at^ += cast[u64](part.count)
    return true
}

/**
 * Give no bytes, for a logged change with no data.
 *
 * @return An empty view.
 */
nothing :: fn() -> u8[] {
    empty :: ""
    return view_of(cast[ptr[u8]](empty.data), 0)
}

/**
 * Record the version of what's at a path beneath a transaction's directory, and of the directory it's in, each once.
 *
 * Either with changes not yet committed is committed first, so a change anyone makes after is a newer version. What
 * isn't there yet isn't recorded; past MAX_VERSIONS, the transaction is marked overflowed.
 *
 * @param server The server, whose volume is committed if an object recorded has changes not yet committed, and whose
 *     transaction's versions are added to.
 * @param index The transaction's slot in server's transactions, as begin gave it; one past them gives false. Whether
 *     it's active isn't checked.
 * @param path The path, relative to the transaction's directory.
 * @return Whether they were recorded; false if there's no such transaction or the volume couldn't commit.
 */
note_versions :: fn(server: ptr[mut Server], index: usize, path: string) -> bool {
    if index >= server.transactions.count {
        return false
    }
    volume :: server.volume
    directory :: server.transactions[index].directory
    objects : u64[2]
    objects[0] = directory
    match slopfs.leaf_of(volume, directory, path) {
        case Ok(leaf) => {
            objects[0] = leaf.directory
            match slopfs.lookup(volume, leaf.directory, leaf.name) {
                case Ok(found) => objects[1] = found or_else 0
                case Error(error) => {}
            }
        }
        case Error(error) => {}
    }
    for object in objects {
        if object == 0 {
            continue
        }
        info := slopfs.info(volume, object) or_continue
        if info.changed == server.nodes.transaction {
            if !commit(server) {
                return false
            }
            info = slopfs.info(volume, object) or_continue
        }
        transaction :: &server.transactions[index]
        recorded := false
        for version, i in transaction.versions {
            if i < transaction.version_count && version.object == object {
                recorded = true
            }
        }
        if recorded {
            continue
        }
        if transaction.version_count >= transaction.versions.count {
            transaction.overflowed = true
            continue
        }
        transaction.versions[transaction.version_count] = Version.{object = object, changed = info.changed}
        transaction.version_count += 1
    }
    return true
}

/** A logged change, read back from a copy of the log, which its client wrote, so it's checked as it's read. */
Logged :: struct {
    /** Op's value, unchecked; apply refuses one that isn't an Op. */
    op : u32,
    /** An OpenFile's files.Creation's value. */
    creation : u32,
    /** A write's offset or a size, in bytes. */
    number : u64,
    /** Its path, a view into the log's copy. */
    path : string,
    /** A rename's to path, a view into the log's copy. */
    to : string,
    /** A write's bytes, a view into the log's copy. */
    data : u8[],
    /** Where the next change starts in the log, in bytes. */
    next : u64,
}

/**
 * Read a logged change back from the log, checked to lie within what's used.
 *
 * @param log The log's bytes, copied from its client's memory, whatever it wrote; read, and the change's views point
 *     into them.
 * @param at Where it starts, in bytes.
 * @param used How many of the log's bytes are logged changes.
 * @return The change, its paths and data views into the log; null if its head or its bytes reach past what's used.
 */
logged_at :: fn(log: u8[], at: u64, used: u64) -> Logged? {
    start :: cast[usize](at)
    if at + cast[u64](size_of(LogHead)) > used || start + size_of(LogHead) > log.count || start >= log.count {
        return null
    }
    head :: cast[ptr[LogHead]](&log[start])^
    path_start :: start + size_of(LogHead)
    path_end :: path_start + cast[usize](cast[u16](head.path_bytes))
    to_end :: path_end + cast[usize](cast[u16](head.to_bytes))
    data_end :: to_end + cast[usize](cast[u32](head.data_bytes))
    if cast[u64](data_end) > used || data_end > log.count {
        return null
    }
    path :: slopfs.part(log, path_start, path_end)
    to :: slopfs.part(log, path_end, to_end)
    return Logged.{op = cast[u32](head.op), creation = cast[u32](head.creation), number = cast[u64](head.number),
        path = string_of(cast[ptr[u8]](path.data), path.count), to = string_of(cast[ptr[u8]](to.data), to.count),
        data = slopfs.part(log, to_end, data_end), next = cast[u64](data_end)}
}

/**
 * Give the files.Creation a logged value is.
 *
 * @param number A logged OpenFile's creation value, which its client may have written anything to.
 * @return New for 2, Either for 3, Truncate for 4, and Existing for anything else.
 */
creation_of :: fn(number: u32) -> files.Creation {
    return if number == 2 { .New } else if number == 3 { .Either } else if number == 4 { .Truncate } else { .Existing }
}

/**
 * Commit a transaction: check none of the versions it recorded changed meanwhile, apply its log in order, and commit,
 * all in one transaction of the volume.
 *
 * What's waiting is committed first, so applying starts from a commit to go back to; if applying fails partway, the
 * volume goes back to that commit, the container service undoing its allocations, so nothing of it is left. What's
 * logged is copied out of its client's memory first, so the client can't change it while it's applied. Its log is
 * emptied either way, to begin again.
 *
 * @param server The server, whose volume is committed before and after the log is applied, or put back at its last
 *     commit if applying fails.
 * @param index The transaction's slot in server's transactions, as begin gave it; one past them gives InvalidPath.
 *     Its log and versions are reset afterwards whatever happens.
 * @return Done once it's durable; Failed with Conflict if a version changed, an object's gone or it overflowed,
 *     DeviceError if a commit failed, NoMemory if there wasn't the memory to copy the log, NoBuffer if it couldn't be
 *     read (its client ended, or the memory's gone), InvalidPath for a log that doesn't hold together or no such
 *     transaction, or why a change couldn't be applied.
 */
commit_transaction :: fn(server: ptr[mut Server], index: usize) -> dir.Response {
    defer reset(server, index)
    if index >= server.transactions.count {
        return .Failed(.InvalidPath)
    }
    // What's waiting committed first, so applying starts from a commit to go back to
    if server.volume.dirty && !commit(server) {
        return .Failed(.DeviceError)
    }
    volume :: server.volume
    transaction :: server.transactions[index]
    if transaction.overflowed {
        return .Failed(.Conflict)
    }
    for version, i in transaction.versions {
        if i >= transaction.version_count {
            break
        }
        info := slopfs.Info.{}
        match slopfs.info(volume, version.object) {
            case Ok(now) => info = now
            case Error(error) => return .Failed(.Conflict)
        }
        if info.changed != version.changed {
            return .Failed(.Conflict)
        }
    }
    // What's logged, copied out of the client's memory, as it is now
    if transaction.used > transaction.log_bytes {
        return .Failed(.InvalidPath)
    }
    log, error :: runtime.new_array(u8, cast[usize](transaction.used))
    if error != null {
        return .Failed(.NoMemory)
    }
    defer runtime.free_array(log)
    if log.count > 0 && (slop_os.memory_read(transaction.memory, 0, log) is_error) {
        return .Failed(.NoBuffer)
    }
    committed :: slopfs.record_of(volume)
    at : u64 = 0
    loop {
        if at >= transaction.used {
            break
        }
        failure : files.FileError? = files.FileError.InvalidPath
        match logged_at(log, at, transaction.used) {
            case Some(found) => {
                logged := found
                failure = apply(server, transaction.directory, &logged)
                at = logged.next
            }
            case None => {}
        }
        match failure {
            case Some(error) => {
                undo(server, committed)
                return .Failed(error)
            }
            case None => {}
        }
    }
    if !commit(server) {
        return .Failed(.DeviceError)
    }
    return .Done
}

/**
 * Apply one logged change beneath a directory.
 *
 * @param server The server, whose volume the change is made to, durable only with its next commit.
 * @param directory The transaction's directory object.
 * @param logged The change, as logged_at read it; its paths and data are views into the copy of the client's log.
 * @return Null once it's applied; why not, otherwise, InvalidPath for an op that isn't one.
 */
apply :: fn(server: ptr[mut Server], directory: u64, logged: ptr[Logged]) -> files.FileError? {
    volume :: server.volume
    if logged.op == cast[u32](Op.OpenFile) {
        match open_file_object(volume, directory, logged.path, creation_of(logged.creation), no_schema()) {
            case Ok(object) => return null
            case Error(error) => return file_error(error)
        }
    }
    if logged.op == cast[u32](Op.Write) || logged.op == cast[u32](Op.SetSize) {
        object := cast[u64](0)
        match slopfs.resolve(volume, directory, logged.path) {
            case Ok(found) => object = found
            case Error(error) => return file_error(error)
        }
        result :: if logged.op == cast[u32](Op.Write) { slopfs.write(volume, object, logged.number, logged.data) }
            else { slopfs.set_size(volume, object, logged.number) }
        match result {
            case Ok => return null
            case Error(error) => return file_error(error)
        }
    }
    if logged.op == cast[u32](Op.Remove) {
        return removed(server, directory, logged.path)
    }
    if logged.op == cast[u32](Op.Rename) {
        match moved(volume, directory, logged.path, logged.to) {
            case Some(error) => return file_error(error)
            case None => return null
        }
    }
    return files.FileError.InvalidPath
}

/**
 * Put the volume back at its last commit: its dirty nodes forgotten, and the container service's changes for it
 * since undone (Abandon).
 *
 * @param server The server: its container service is asked to Abandon, waited for, its volume's dirty nodes forgotten
 *     and its commit_at cleared.
 * @param committed The volume's record as last committed.
 */
undo :: fn(server: ptr[mut Server], committed: slopfs.VolumeRecord) {
    _ = ask(server, .Abandon)
    slopfs.forget(server.volume, committed)
    server.commit_at = 0
}

// Replace and orphans

/**
 * Tell whether a file connection, read-only or not, or a replacement, other than one, has an object open.
 *
 * @param server The server, whose connections are read; nothing's changed.
 * @param object The object, by its number in the volume's tree.
 * @param skip The slot of a connection not counted; one past them for none.
 * @return Whether any connection but skip's, a file's, a read-only file's or a replacement's, is to object.
 */
has_open :: fn(server: ptr[Server], object: u64, skip: usize) -> bool {
    for connection, i in server.connections {
        if i < server.count && i != skip && connection.object == object
            && (connection.kind == .File || connection.kind == .ReadOnlyFile || connection.kind == .Replacement) {
            return true
        }
    }
    return false
}

/**
 * Give an orphan back once nothing has it open; an object that isn't one, or is open, is left.
 *
 * @param server The server; an orphan given back changes its volume, durable with its next commit.
 * @param object The object; 0 for none.
 * @param skip The slot of a connection not counted, as the one closing; one past them for none.
 */
release_if_unused :: fn(server: ptr[mut Server], object: u64, skip: usize) {
    if object == 0 || has_open(server, object, skip) {
        return void
    }
    match slopfs.is_orphan(server.volume, object) {
        case Ok(orphaned) => {
            if orphaned {
                _ = slopfs.release_orphan(server.volume, object)
            }
        }
        case Error(error) => {}
    }
}

/**
 * Remove what's at a path: a file someone has open is orphaned, so they go on reading it, and given back when the last
 * of them is done.
 *
 * @param server The server, whose volume is changed, and whose connections are checked for what was removed.
 * @param directory The directory object the path is beneath.
 * @param path The path of what's removed, relative to directory.
 * @return Null once it's removed, durable with the volume's next commit; why not, otherwise.
 */
removed :: fn(server: ptr[mut Server], directory: u64, path: string) -> files.FileError? {
    volume :: server.volume
    match slopfs.leaf_of(volume, directory, path) {
        case Ok(leaf) => {
            match slopfs.unlink(volume, leaf.directory, leaf.name) {
                case Ok(object) => {
                    release_if_unused(server, object, server.connections.count)
                    return null
                }
                case Error(error) => return file_error(error)
            }
        }
        case Error(error) => return file_error(error)
    }
}

/**
 * Answer a Replace: make a new orphan to be the file at a path once it's installed, on a connection of its own.
 *
 * @param server The server; an orphan is made in its volume, and a Replacement connection added.
 * @param directory The directory object the path is beneath.
 * @param path The path; its directory must exist.
 * @return OpenedFile with the replacement's connection, which the caller sends; Failed with NoSpace without a channel
 *     or a slot, the orphan given back, or why the path couldn't be followed or the orphan made.
 */
replacement_of :: fn(server: ptr[mut Server], directory: u64, path: string) -> dir.Response {
    volume :: server.volume
    leaf := slopfs.Leaf.{}
    match slopfs.leaf_of(volume, directory, path) {
        case Ok(found) => leaf = found
        case Error(error) => return .Failed(file_error(error))
    }
    object := cast[u64](0)
    match slopfs.create_orphan(volume, leaf.directory) {
        case Ok(made) => object = made
        case Error(error) => return .Failed(file_error(error))
    }
    startup :: slop_os.startup_block()
    pair :: os.channel_for[file.File](startup.budget, 0) or_return .Failed(.NoSpace)
    match add(server, .Replacement, pair.a, object, false, leaf.name) {
        case Some(slot) => {
            if slot < server.connections.count {
                server.connections[slot].target = leaf.directory
            }
            return .OpenedFile(os.Channel[file.File].{end = pair.b})
        }
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            _ = slopfs.release_orphan(volume, object)
            return .Failed(.NoSpace)
        }
    }
}

/**
 * Install a replacement at its name, give the file it replaced back once nothing has it open, and commit, so it's
 * durable before it's answered. The connection is a file's from then on.
 *
 * @param server The server, whose volume is changed and committed, waited for; the connection becomes a File's.
 * @param index The replacement's connection's slot.
 * @return Null once it's installed and committed; DeviceError if the commit failed, or why it couldn't be installed.
 */
installed :: fn(server: ptr[mut Server], index: usize) -> files.FileError? {
    if index >= server.connections.count {
        return files.FileError.InvalidPath
    }
    connection :: server.connections[index]
    match slopfs.install(server.volume, connection.target, name_of(&connection), connection.object) {
        case Ok(replaced) => {
            server.connections[index].kind = .File
            release_if_unused(server, replaced or_else 0, index)
        }
        case Error(error) => return file_error(error)
    }
    return if commit(server) { cast[files.FileError?](null) } else { files.FileError.DeviceError }
}

// Change cursors

/**
 * Answer Changes for a directory: the first change beneath it at or after a cursor.
 *
 * @param server The server, whose volume's change history is read.
 * @param directory The directory object whose changes, its own and beneath it, are answered, their paths from it.
 * @param cursor Where to start: what the last answer's next said.
 * @param out The answer being built, which the change's name is appended to.
 * @return Changed, its name the path from the directory as it now is, or the name alone if its directory can't be
 *     walked back to; UpToDate past the last; Resync for a cursor older than the history kept; each with the next
 *     cursor. Failed if the history couldn't be read.
 */
changes_of :: fn(server: ptr[mut Server], directory: u64, cursor: u64, out: ptr[mut os.Outgoing]) -> dir.Response {
    volume :: server.volume
    name : u8[slopfs.NAME_BYTES]
    found := slopfs.ChangesFound.{}
    match slopfs.changes_since(volume, directory, cursor, name) {
        case Ok(made) => found = made
        case Error(error) => return .Failed(file_error(error))
    }
    if found.are == .UpToDate {
        return .UpToDate(found.next)
    }
    if found.are == .Resync {
        return .Resync(found.next)
    }
    path : u8[files.PATH_BYTES]
    length := path_to(server, directory, found.object, path)
    // A name whose directory can't be walked back to is given as the name alone
    if length == 0 && found.name_bytes <= name.count {
        for i in 0..<found.name_bytes {
            if i < path.count && i < name.count {
                path[i] = name[i]
            }
        }
        length = found.name_bytes
    }
    kind :: cast[files.ChangeKind](cast[u32](found.kind))
    shown :: if length < path.count { length } else { path.count }
    return .Changed(files.Change.{kind = kind, name = os.append(out, path[0..<shown]), next = found.next})
}

/**
 * Make the path from a directory to an object, through each object's parent.
 *
 * @param server The server, whose volume is read.
 * @param directory The directory object the path starts from.
 * @param object The object, at most 16 levels beneath it.
 * @param path Where the path's bytes go, its components separated by '/'; its count is the most written.
 * @return Its length in bytes; 0 if object isn't beneath directory any more, is deeper than 16, a name on the way
 *     can't be found, the path doesn't fit, or object is directory.
 */
path_to :: fn(server: ptr[mut Server], directory: u64, object: u64, path: mut u8[]) -> usize {
    volume :: server.volume
    names : u64[16]
    depth : usize = 0
    at := object
    loop {
        if at == directory {
            break
        }
        if depth >= names.count {
            return 0
        }
        names[depth] = at
        depth += 1
        info :: slopfs.info(volume, at) or_return 0
        if info.parent == at {
            return 0
        }
        at = info.parent
    }
    length : usize = 0
    with {
        i := depth
    }
    loop {
        i -= 1
        if i >= names.count {
            return 0
        }
        child :: names[i]
        info :: slopfs.info(volume, child) or_return 0
        name : u8[slopfs.NAME_BYTES]
        count :: name_in(volume, info.parent, child, name) or_return 0
        if length > 0 {
            if length >= path.count {
                return 0
            }
            path[length] = cast[u8]('/')
            length += 1
        }
        for j in 0..<count {
            if length >= path.count || j >= name.count {
                return 0
            }
            path[length] = name[j]
            length += 1
        }
    }
    while i > 0
    return length
}

/**
 * Find the name an object has in a directory, by listing it.
 *
 * @param volume The volume, read only.
 * @param directory The directory object, listed from its first entry.
 * @param object The object whose entry is looked for.
 * @param name Where the name goes, slopfs.NAME_BYTES long.
 * @return Its length in bytes in name; null if it isn't in the directory, or the directory couldn't be listed.
 */
name_in :: fn(volume: ptr[mut slopfs.Volume], directory: u64, object: u64, name: mut u8[]) -> usize? {
    cursor : u64 = 0
    loop {
        listed :: slopfs.list(volume, directory, cursor, name) or_return null
        entry :: listed or_return null
        if entry.object == object {
            return entry.name_bytes
        }
        cursor = entry.next
    }
}

/**
 * Answer a Begin: a transaction beneath a directory, its log in memory its client gives, on a connection of its own.
 *
 * @param server The server; a transaction slot and a Transaction connection are taken, neither kept if the other can't
 *     be had.
 * @param directory The directory object it's beneath.
 * @param memory The log's memory, which the server takes over: kept, or closed when it's refused.
 * @param name The directory connection's name, the transaction's.
 * @return Began with the transaction's connection, which the caller sends; Failed with NoBuffer if it couldn't be
 *     begun, or NoSpace without a channel or a slot.
 */
transaction_connection :: fn(server: ptr[mut Server], directory: u64, memory: slop_os.Memory, name: string) -> dir.Response {
    began := begin(server, directory, memory) or_else MAX_TRANSACTIONS
    if began >= MAX_TRANSACTIONS {
        _ = slop_os.handle_close(cast[slop_os.Handle](memory))
        return .Failed(.NoBuffer)
    }
    startup :: slop_os.startup_block()
    pair :: os.channel_for[dir.Dir](startup.budget, 0) or_return .Failed(.NoSpace)
    match add(server, .Transaction, pair.a, directory, false, name) {
        case Some(slot) => {
            if slot < server.connections.count {
                server.connections[slot].transaction = began
            }
            return .Began(os.Channel[dir.Dir].{end = pair.b})
        }
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            end_transaction(server, began)
            return .Failed(.NoSpace)
        }
    }
}

/**
 * Open a file in a transaction: log the open, as creation says, and make a connection whose writes and sizes are
 * logged too and whose reads see the file as it is now, if it's there yet.
 *
 * @param server The server, whose volume may be committed, as note_versions does; the open is logged, and a
 *     TransactionFile connection added.
 * @param index The transaction's slot in server's transactions, as begin gave it, which the new connection keeps; one
 *     past them gives InvalidPath.
 * @param path The file's path, relative to the transaction's directory.
 * @param creation How it's opened when the transaction commits.
 * @return OpenedFile with the connection, which the caller sends; Failed with InvalidPath for an empty path or no such
 *     transaction, or NoSpace if the log is full, the volume couldn't commit, or there's no channel or slot.
 */
open_in_transaction :: fn(server: ptr[mut Server], index: usize, path: string, creation: files.Creation) -> dir.Response {
    if index >= server.transactions.count {
        return .Failed(.InvalidPath)
    }
    if path.count == 0 {
        return .Failed(.InvalidPath)
    }
    if !note_versions(server, index, path) || !log_op(server, index, .OpenFile, cast[u32](creation), 0, path, "", nothing()) {
        return .Failed(.NoSpace)
    }
    object :: slopfs.resolve(server.volume, server.transactions[index].directory, path) or_else 0
    startup :: slop_os.startup_block()
    pair :: os.channel_for[file.File](startup.budget, 0) or_return .Failed(.NoSpace)
    match add(server, .TransactionFile, pair.a, object, false, path) {
        case Some(slot) => {
            if slot < server.connections.count {
                server.connections[slot].transaction = index
            }
            return .OpenedFile(os.Channel[file.File].{end = pair.b})
        }
        case None => {
            _ = slop_os.handle_close(cast[slop_os.Handle](pair.b))
            return .Failed(.NoSpace)
        }
    }
}
