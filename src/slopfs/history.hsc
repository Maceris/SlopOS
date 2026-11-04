package slopfs

import runtime from "base"
import maps from "std"

/*
 * What a volume server needs beyond the volume itself (decisions/0089): the history change cursors read, objects kept
 * while they're open after nothing names them (Replace, and removing a file someone has open), and forgetting
 * everything changed since the last commit, when a transaction can't be applied whole.
 */

// History

/**
 * Read a volume's history's state.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @return The state; first and next both 1 and no bytes for a volume with no history yet.
 * @error Corrupt The state's record isn't a ChangeState, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
history_state :: fn(volume: ptr[mut Volume]) -> Result[ChangeState, Error] {
    state := ChangeState.{first = cast[u64le](1), next = cast[u64le](1)}
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(0, .Change, 0), view_of(cast[ptr[mut u8]](&state), size_of(ChangeState)))?
    match bytes {
        case Some(count) => {
            if count != size_of(ChangeState) {
                return .Error(.Corrupt)
            }
        }
        case None => {}
    }
    return .Ok(state)
}

/**
 * Note a change in the volume's history, if it keeps one, the oldest changes dropped while it's over its budget.
 *
 * A file written again in the same transaction, with no change between, is one change, so the second isn't noted.
 * The newest change is never dropped, even past the budget. Like every change to the volume, it's durable with the
 * volume's next commit.
 *
 * @param volume The volume; nothing is noted when its history_bytes is 0.
 * @param kind What was done.
 * @param object The object it was done to.
 * @param parent The directory its name is in.
 * @param name Its name, UTF-8; past NAME_BYTES it's cut.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt The history's state or a node couldn't be read or didn't check out.
 */
note_change :: fn(volume: ptr[mut Volume], kind: ChangeKind, object: u64, parent: u64, name: string) -> Result[void, Error] {
    if volume.history_bytes == 0 {
        return .Ok
    }
    state := history_state(volume)?
    first := cast[u64](state.first)
    next := cast[u64](state.next)
    transaction :: volume.nodes.transaction
    value :: make(ValueBuffer)?
    defer runtime.free(value)
    // A file written again in the same transaction is one change
    if kind == .Written && next > first {
        found :: tree_get(volume.nodes, &volume.tree, key_of(0, .Change, next - 1), value.bytes)?
        last :: cast[ptr[ChangeRecord]](&value.bytes[0])
        if (found is_some) && cast[u32](last.kind) == cast[u32](ChangeKind.Written) && cast[u64](last.object) == object
            && cast[u64](last.transaction) == transaction {
            return .Ok
        }
    }
    most :: cast[usize](NAME_BYTES)
    count :: if name.count > most { most } else { name.count }
    record :: cast[ptr[mut ChangeRecord]](&value.bytes[0])
    record^ = ChangeRecord.{transaction = cast[u64le](transaction), object = cast[u64le](object), parent = cast[u64le](parent),
        kind = cast[u32le](cast[u32](kind)), name_bytes = cast[u16le](cast[u16](count))}
    copy_bytes(value.bytes, size_of(ChangeRecord), view_of(cast[ptr[u8]](name.data), count))
    length :: size_of(ChangeRecord) + count
    tree_put(volume.nodes, &volume.tree, key_of(0, .Change, next), part(value.bytes, 0, length))?
    next += 1
    used := cast[u64](state.bytes) + cast[u64](length)
    // The oldest dropped while the history is over its budget
    loop {
        if used <= volume.history_bytes || first >= next - 1 {
            break
        }
        bytes :: tree_get(volume.nodes, &volume.tree, key_of(0, .Change, first), value.bytes)? or_else 0
        _ = tree_delete(volume.nodes, &volume.tree, key_of(0, .Change, first))?
        used = if cast[u64](bytes) > used { 0 } else { used - cast[u64](bytes) }
        first += 1
    }
    state = ChangeState.{first = cast[u64le](first), next = cast[u64le](next), bytes = cast[u64le](used)}
    tree_put(volume.nodes, &volume.tree, key_of(0, .Change, 0), view_of(cast[ptr[u8]](&state), size_of(ChangeState)))?
    volume.dirty = true
    return .Ok
}

/** What a change cursor found. */
ChangesAre :: enum {
    /** A change beneath the directory. */
    Found,
    /** None since the cursor: next is where to ask from. */
    UpToDate,
    /** The cursor is older than the history keeps: list again, and ask from next. */
    Resync,
}

/** What a cursor finds: a change's kind, its object and name in the caller's buffer, and the cursor after it. */
ChangesFound :: struct {
    /** Whether a change was found, or why not. */
    are : ChangesAre,
    /** The change's kind, when one was found. */
    kind : ChangeKind,
    /** The object it was made to, when one was found. */
    object : u64,
    /** How many bytes of its name are in the caller's buffer, cut to the buffer's size. */
    name_bytes : usize,
    /** The transaction it was made in, when one was found. */
    transaction : u64,
    /** The cursor to ask from next: the sequence number after the change found, or the history's next. */
    next : u64,
}

/**
 * Find the first change at or after a cursor whose name is in a directory or beneath it, as the tree now is.
 *
 * Changes beneath a directory that's gone since aren't found. Nothing is changed.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory whose changes are wanted.
 * @param cursor The sequence number to look from: 1 for the oldest there can be, or a ChangesFound's next.
 * @param name Where the change's name is copied, as much as fits.
 * @return What was found: Found with the change; UpToDate if there's none since cursor; Resync if cursor is older
 *     than the oldest kept.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt The history's state or a node couldn't be read or didn't check out.
 */
changes_since :: fn(volume: ptr[mut Volume], directory: u64, cursor: u64, name: mut u8[]) -> Result[ChangesFound, Error] {
    state :: history_state(volume)?
    first :: cast[u64](state.first)
    next :: cast[u64](state.next)
    if cursor < first {
        return .Ok(ChangesFound.{are = .Resync, next = next})
    }
    value :: make(ValueBuffer)?
    defer runtime.free(value)
    for sequence in cursor..<next {
        bytes :: tree_get(volume.nodes, &volume.tree, key_of(0, .Change, sequence), value.bytes)? or_else 0
        if bytes < size_of(ChangeRecord) {
            continue
        }
        record :: cast[ptr[ChangeRecord]](&value.bytes[0])
        parent :: cast[u64](record.parent)
        beneath := false
        match is_beneath(volume, parent, directory) {
            case Ok(is) => beneath = is
            case Error(error) => beneath = false
        }
        if !beneath {
            continue
        }
        count :: cast[usize](cast[u16](record.name_bytes))
        copy_bytes(name, 0, part(value.bytes, size_of(ChangeRecord), size_of(ChangeRecord) + count))
        kind :: cast[u32](record.kind)
        return .Ok(ChangesFound.{are = .Found, kind = kind_of_change(kind), object = cast[u64](record.object),
            name_bytes = if count < name.count { count } else { name.count }, transaction = cast[u64](record.transaction), next = sequence + 1})
    }
    return .Ok(ChangesFound.{are = .UpToDate, next = next})
}

/**
 * Get the ChangeKind a record's kind field holds.
 *
 * @param kind A change record's kind field, as stored; any value is taken.
 * @return Its ChangeKind; Written for any value that isn't another's, 2 included.
 */
kind_of_change :: fn(kind: u32) -> ChangeKind {
    return if kind == 1 { .Created } else if kind == 3 { .Removed } else if kind == 4 { .MovedOut } else if kind == 5 { .MovedIn }
        else if kind == 6 { .Replaced } else { .Written }
}

// Orphans

/**
 * Make the key of an object's orphan record.
 *
 * @param object The orphan's object ID, the key's offset.
 * @return The key (0, Orphan, object).
 */
orphan_key :: fn(object: u64) -> Key {
    return key_of(0, .Orphan, object)
}

/**
 * Tell whether an object is an orphan, kept with no name leading to it.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The object's ID; one that isn't there is simply not an orphan.
 * @return True if it has an orphan record.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
is_orphan :: fn(volume: ptr[mut Volume], object: u64) -> Result[bool, Error] {
    return tree_has(volume.nodes, &volume.tree, orphan_key(object))
}

/**
 * Make a new, empty file no name leads to yet, to become a directory's once it's installed (Replace).
 *
 * It's kept as an orphan meanwhile, so a crash after a commit leaves it only until sweep_orphans destroys it. Its
 * times are the volume's now.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory it's to go in, whose ID its record names as its parent.
 * @return The new file's object ID.
 * @error NotFound The directory isn't there.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
create_orphan :: fn(volume: ptr[mut Volume], directory: u64) -> Result[u64, Error] {
    directory_record(volume, directory)?
    object :: volume.next_object
    volume.next_object += 1
    record := ObjectRecord.{kind = cast[u32le](cast[u32](ObjectKind.File)), parent = cast[u64le](directory), created = cast[u64le](volume.now),
        modified = cast[u64le](volume.now), changed = cast[u64le](volume.nodes.transaction)}
    put_object(volume, object, &record)?
    scratch : u8[1]
    tree_put(volume.nodes, &volume.tree, orphan_key(object), scratch[0..<0])?
    return .Ok(object)
}

/**
 * Swap the file of a name in a directory for an orphan, whole, in one change: the orphan named so, and the file it
 * replaces, if any, orphaned in turn.
 *
 * It's all in the volume's transaction, so a commit makes all of it durable or none. The directory and the orphan
 * are touched, and a Replaced change noted.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory the name is in, and the orphan goes in.
 * @param name The name, which may name nothing yet.
 * @param replacement The orphan, from create_orphan.
 * @return The file replaced, an orphan now, for whoever has it to give back with release_orphan; null if the name
 *     named nothing.
 * @error NotFound The directory isn't there, or replacement isn't an orphan.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error InvalidName The name can't name anything (name_holds).
 * @error IsADirectory The name names a directory, which isn't replaced.
 * @error TooLarge The directory's entries that hash alike have no room for the name.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
install :: fn(volume: ptr[mut Volume], directory: u64, name: string, replacement: u64) -> Result[u64?, Error] {
    parent := directory_record(volume, directory)?
    if !name_holds(name) {
        return .Error(.InvalidName)
    }
    if !(is_orphan(volume, replacement)?) {
        return .Error(.NotFound)
    }
    replaced :: lookup(volume, directory, name)?
    match replaced {
        case Some(old) => {
            record :: get_object(volume, old)?
            if kind_of_record(&record) == .Directory {
                return .Error(.IsADirectory)
            }
            remove_entry(volume, directory, name)?
            scratch : u8[1]
            tree_put(volume.nodes, &volume.tree, orphan_key(old), scratch[0..<0])?
        }
        case None => {}
    }
    add_entry(volume, directory, name, replacement, .File)?
    _ = tree_delete(volume.nodes, &volume.tree, orphan_key(replacement))?
    record := get_object(volume, replacement)?
    record.parent = cast[u64le](directory)
    touch(volume, replacement, &record)?
    touch(volume, directory, &parent)?
    note_change(volume, .Replaced, replacement, directory, name)?
    return .Ok(replaced)
}

/**
 * Take what's named a name in a directory out of it and orphan it, as removing a file someone has open does: it's
 * kept until release_orphan or sweep_orphans destroys it.
 *
 * The directory is touched and a Removed change noted.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param directory The directory the name is in.
 * @param name The name, of a file, a link or an empty directory.
 * @return The ID of the object orphaned.
 * @error NotFound The directory isn't there, or nothing has the name.
 * @error NotADirectory The directory is a file.
 * @error IsALink The directory is a stored link.
 * @error InvalidName The name can't name anything (name_holds).
 * @error DirectoryNotEmpty The name names a directory with something in it.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
unlink :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[u64, Error] {
    parent := directory_record(volume, directory)?
    object :: lookup(volume, directory, name)? or_return .Error(.NotFound)
    record :: get_object(volume, object)?
    if kind_of_record(&record) == .Directory && !(is_empty(volume, object)?) {
        return .Error(.DirectoryNotEmpty)
    }
    remove_entry(volume, directory, name)?
    scratch : u8[1]
    tree_put(volume.nodes, &volume.tree, orphan_key(object), scratch[0..<0])?
    touch(volume, directory, &parent)?
    note_change(volume, .Removed, object, directory, name)?
    return .Ok(object)
}

/**
 * Destroy an orphan nothing has open any more: its chunks and record gone, its blocks given back.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param object The orphan; an object that isn't one is left alone, and that's no error.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A chunk's record or a node couldn't be read or didn't check out.
 */
release_orphan :: fn(volume: ptr[mut Volume], object: u64) -> Result[void, Error] {
    if !(tree_delete(volume.nodes, &volume.tree, orphan_key(object))?) {
        return .Ok
    }
    return destroy(volume, object)
}

/**
 * Destroy every orphan, as when a volume server starts and nothing has anything open.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @return How many were destroyed, 0 or more.
 * @error OutOfMemory No memory for a node; those destroyed before stay destroyed.
 * @error Corrupt A chunk's record or a node couldn't be read or didn't check out.
 */
sweep_orphans :: fn(volume: ptr[mut Volume]) -> Result[u64, Error] {
    swept : u64 = 0
    value : u8[1]
    loop {
        found :: tree_next(volume.nodes, &volume.tree, orphan_key(0), value)? or_break
        if found.key.object != 0 || found.key.kind != cast[u8](RecordKind.Orphan) {
            break
        }
        release_orphan(volume, found.key.offset)?
        swept += 1
    }
    return .Ok(swept)
}

// Forgetting

/**
 * Forget everything changed in a volume since its last commit, its tree and next object as a record has them.
 *
 * Its dirty nodes are dropped without giving their blocks back, which the container reverts (abandon_volume)
 * instead. Without the memory to list them all, some stay dirty, written with the next commit though nothing points
 * at them. The volume is no longer failed.
 *
 * @param volume The volume, open: what it reads includes its transaction's changes not yet committed.
 * @param record The volume's record as its last commit left it.
 */
forget :: fn(volume: ptr[mut Volume], record: VolumeRecord) {
    dropped : u64[..]
    defer runtime.array_free(&dropped)
    dirty :: &volume.nodes.dirty
    used :: dirty.used
    values :: dirty.values
    keys :: dirty.keys
    for i in 0..<used.count {
        if i < values.count && i < keys.count && used[i] {
            node :: values[i]
            // Without the memory to list it, a node stays among the dirty ones, written with the next commit
            if cast[u64](header_of(node).owner) == volume.id && runtime.array_try_add(&dropped, keys[i]) != null {
                break
            }
        }
    }
    for address in dropped {
        match maps.map_get(dirty, address) {
            case Some(node) => {
                _ = maps.map_remove(dirty, address)
                runtime.free(node)
            }
            case None => {}
        }
    }
    volume.tree.root = record.root
    volume.next_object = cast[u64](record.next_object)
    volume.dirty = false
    volume.failed = false
    volume.failed_count = 0
}
