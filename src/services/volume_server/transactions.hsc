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

MAX_TRANSACTIONS :: 16
MAX_VERSIONS :: 64

Op :: enum #backed_by(u32) {
    OpenFile = 1,
    Write = 2,
    SetSize = 3,
    Remove = 4,
    Rename = 5,
}

// A logged change: what, a number (a write's offset, a size, a file's creation), its data's bytes, and its paths' bytes.
LogHead :: struct #packed {
    op : u32le,
    creation : u32le,
    number : u64le,
    data_bytes : u32le,
    path_bytes : u16le,
    to_bytes : u16le,
}

#assert size_of(LogHead) == 24

Version :: struct {
    object : u64,
    changed : u64,
}

Transaction :: struct {
    active : bool,
    // The directory it's beneath
    directory : u64,
    memory : slop_os.Memory,
    log : u64,
    log_bytes : u64,
    used : u64,
    versions : Version[MAX_VERSIONS],
    version_count : usize,
    // Too many versions to check, so its commit is refused as a conflict
    overflowed : bool,
}

// A transaction begun beneath directory, its log in memory, mapped here: its index, or null.
begin :: fn(server: ptr[mut Server], directory: u64, memory: slop_os.Memory) -> usize? {
    for transaction, i in server.transactions {
        if transaction.active {
            continue
        }
        size :: slop_os.memory_size(memory) or_else 0
        if size < cast[u64](size_of(LogHead)) || size > MAX_BUFFER_BYTES {
            return null
        }
        startup :: slop_os.startup_block()
        address :: runtime.reserve_addresses(cast[usize](size)) or_return null
        if slop_os.memory_map(memory, startup.space, address, 0, size, read_write()) is_error {
            return null
        }
        if i < server.transactions.count {
            server.transactions[i] = Transaction.{active = true, directory = directory, memory = memory, log = address, log_bytes = size}
        }
        return i
    }
    return null
}

// A transaction ended, its log given back.
end_transaction :: fn(server: ptr[mut Server], index: usize) {
    if index >= server.transactions.count || !server.transactions[index].active {
        return void
    }
    transaction :: server.transactions[index]
    startup :: slop_os.startup_block()
    _ = slop_os.memory_unmap(startup.space, transaction.log)
    _ = slop_os.handle_close(cast[slop_os.Handle](transaction.memory))
    server.transactions[index] = Transaction.{}
}

// A transaction's log emptied, to begin again after a commit or an abort.
reset :: fn(server: ptr[mut Server], index: usize) {
    if index < server.transactions.count {
        server.transactions[index].used = 0
        server.transactions[index].version_count = 0
        server.transactions[index].overflowed = false
    }
}

// A change logged: false if the log is full.
log_op :: fn(server: ptr[mut Server], index: usize, op: Op, creation: u32, number: u64, path: string, to: string, data: u8[]) -> bool {
    if index >= server.transactions.count {
        return false
    }
    transaction :: &server.transactions[index]
    length :: cast[u64](size_of(LogHead) + path.count + to.count + data.count)
    if transaction.used + length > transaction.log_bytes || path.count > 0xffff || to.count > 0xffff {
        return false
    }
    log :: view_of(cast[ptr[mut u8]](transaction.log), cast[usize](transaction.log_bytes))
    head := LogHead.{op = cast[u32le](cast[u32](op)), creation = cast[u32le](creation), number = cast[u64le](number),
        data_bytes = cast[u32le](cast[u32](data.count)), path_bytes = cast[u16le](cast[u16](path.count)), to_bytes = cast[u16le](cast[u16](to.count))}
    at := cast[usize](transaction.used)
    at = put_bytes(log, at, view_of(cast[ptr[u8]](&head), size_of(LogHead)))
    at = put_bytes(log, at, view_of(cast[ptr[u8]](path.data), path.count))
    at = put_bytes(log, at, view_of(cast[ptr[u8]](to.data), to.count))
    at = put_bytes(log, at, data)
    transaction.used += length
    return true
}

// bytes put in log at at, as far as they fit: where the next go.
put_bytes :: fn(log: mut u8[], at: usize, bytes: u8[]) -> usize {
    for byte, i in bytes {
        j :: at + i
        if j < log.count {
            log[j] = byte
        }
    }
    return at + bytes.count
}

// No bytes, for a logged change with no data.
nothing :: fn() -> u8[] {
    empty :: ""
    return view_of(cast[ptr[u8]](empty.data), 0)
}

/*
 * The version of what's at path beneath a transaction's directory recorded, and of the directory it's in: committed
 * first if either has changes not yet committed, so a later change is a newer version. False if the volume can't
 * commit.
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

// A logged change, read back from the log, which its client could have changed, so it's checked as it's read.
Logged :: struct {
    op : u32,
    creation : u32,
    number : u64,
    path : string,
    to : string,
    data : u8[],
    next : u64,
}

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

creation_of :: fn(number: u32) -> files.Creation {
    return if number == 2 { .New } else if number == 3 { .Either } else if number == 4 { .Truncate } else { .Existing }
}

/*
 * A transaction committed: checked, applied whole and made durable, or Failed with why. Its log is emptied either way,
 * to begin again.
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
    committed :: slopfs.record_of(volume)
    log :: view_of(cast[ptr[u8]](transaction.log), cast[usize](transaction.log_bytes))
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

// One logged change applied beneath directory: what went wrong, or null.
apply :: fn(server: ptr[mut Server], directory: u64, logged: ptr[Logged]) -> files.FileError? {
    volume :: server.volume
    if logged.op == cast[u32](Op.OpenFile) {
        match open_file_object(volume, directory, logged.path, creation_of(logged.creation)) {
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

// The volume back at its last commit, record: its dirty nodes forgotten, and the container service's changes for it undone.
undo :: fn(server: ptr[mut Server], committed: slopfs.VolumeRecord) {
    _ = ask(server, .Abandon)
    slopfs.forget(server.volume, committed)
    server.commit_at = 0
}

// Replace and orphans

// Whether a connection other than skip has object open.
has_open :: fn(server: ptr[Server], object: u64, skip: usize) -> bool {
    for connection, i in server.connections {
        if i < server.count && i != skip && connection.object == object
            && (connection.kind == .File || connection.kind == .ReadOnlyFile || connection.kind == .Replacement) {
            return true
        }
    }
    return false
}

// An orphan given back once nothing has it open.
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

/*
 * What's at path beneath directory removed: a file someone has open is orphaned, so they go on reading it, and given
 * back when the last of them is done.
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

// A Replace: a new orphan to be the file at path beneath directory once it's installed.
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

// A replacement installed at its name, the file it replaced given back once nothing has it, and made durable.
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

/*
 * A Changes answer for a directory: the first change beneath it at or after cursor, its name the path from the
 * directory as it now is (as far as each directory on the way can still be found), or UpToDate, or Resync.
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

/*
 * The path from directory to object, through each object's parent, into path: its length, or 0 if object isn't
 * beneath it any more or a name on the way can't be found.
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

// The name object has in directory, found by listing it: its length in name.
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

// A Begin: a transaction beneath directory, its log in memory, on a connection of its own.
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

/*
 * A file opened in a transaction: the open logged, as creation says, and a connection whose writes are logged too and
 * whose reads see the file as it is, if it's there yet.
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
