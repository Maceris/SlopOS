package slopfs

import runtime from "base"
import maps from "std"

/*
 * What a volume server needs beyond the volume itself (decisions/0089): the history change cursors read, objects kept
 * while they're open after nothing names them (Replace, and removing a file someone has open), and forgetting
 * everything changed since the last commit, when a transaction can't be applied whole.
 */

// History

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

// A change, in the history if the volume keeps one, the oldest dropped while it's over its budget.
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

ChangesAre :: enum {
    // A change beneath the directory
    Found,
    // None since the cursor: next is where to ask from
    UpToDate,
    // The cursor is older than the history keeps: list again, and ask from next
    Resync,
}

// What a cursor finds: a change's kind, its object and name in the caller's buffer, and the cursor after it.
ChangesFound :: struct {
    are : ChangesAre,
    kind : ChangeKind,
    object : u64,
    name_bytes : usize,
    transaction : u64,
    next : u64,
}

/*
 * The first change at or after a cursor whose name is beneath directory, as it now is, its name copied into name;
 * changes beneath a directory that's gone since aren't found.
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

kind_of_change :: fn(kind: u32) -> ChangeKind {
    return if kind == 1 { .Created } else if kind == 3 { .Removed } else if kind == 4 { .MovedOut } else if kind == 5 { .MovedIn }
        else if kind == 6 { .Replaced } else { .Written }
}

// Orphans

orphan_key :: fn(object: u64) -> Key {
    return key_of(0, .Orphan, object)
}

is_orphan :: fn(volume: ptr[mut Volume], object: u64) -> Result[bool, Error] {
    return tree_has(volume.nodes, &volume.tree, orphan_key(object))
}

/*
 * A new file no name leads to yet, to become directory's once it's installed (Replace): kept as an orphan meanwhile, so
 * a crash leaves nothing behind once it's swept.
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

/*
 * A file named name in directory swapped for an orphan, whole, in one change: the orphan named so, and the file it
 * replaces (if any, a file) orphaned in turn, which comes back for whoever has it to give back with release_orphan.
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

// What's named name in directory, a file or an empty directory, taken out of it and orphaned; its ID.
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

// An orphan nothing has open any more, destroyed.
release_orphan :: fn(volume: ptr[mut Volume], object: u64) -> Result[void, Error] {
    if !(tree_delete(volume.nodes, &volume.tree, orphan_key(object))?) {
        return .Ok
    }
    return destroy(volume, object)
}

// Every orphan destroyed, as when a volume server starts and nothing has anything open.
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

/*
 * Everything changed in a volume since its last commit forgotten, its tree and next object as record has them: its
 * dirty nodes dropped without giving their blocks back, which the container reverts (abandon_volume) instead.
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
}
