package slopfs

import runtime from "base"
import crypto from "std"

/*
 * A volume (design/storage.md §3): one tree of its objects, each directory's entries and each file's chunks, keyed
 * (object, kind, offset). A directory's entries are found by a hash of their names keyed per volume, so names chosen
 * in advance can't fill one bucket; those that hash alike share a record. Names are UTF-8 bytes without '/' or NUL,
 * compared exactly. There are no hard links, so each object has one parent, and no symbolic links.
 *
 * A file's bytes are in chunks of 64 KiB, each an extent of up to 16 blocks written anew whenever it changes, the
 * first held in its record while the file is at most 2 KiB. Chunks that were never written read as zeros.
 */

/*
 * A volume open: the nodes its tree changes in and the device it's on, the container's own in this process or, in a
 * volume server, its own (decisions/0089), and what its record holds.
 */
Volume :: struct {
    nodes : ptr[mut Nodes],
    device : Device,
    id : u64,
    tree : Tree,
    next_object : u64,
    hash_key : u8[32],
    created : u64,
    name : u8[VOLUME_NAME_BYTES],
    name_bytes : u16,
    // Whether its tree or its record changed since the last commit
    dirty : bool,
    // The time it is, as its user says, for the records it writes
    now : u64,
    // A data write failed, so its commits are refused
    failed : bool,
}

// What an object is.
Info :: struct {
    object : u64,
    kind : ObjectKind,
    parent : u64,
    size : u64,
    created : u64,
    modified : u64,
    changed : u64,
}

// An entry List gives: its name's bytes in the caller's buffer, what it names, and the cursor after it.
Listed :: struct {
    name_bytes : usize,
    object : u64,
    kind : ObjectKind,
    next : u64,
}

VolumeId :: struct {
    id : u64,
}

/*
 * A new volume named name, with its root directory, open; hash_key, random, is what its names hash with. It's on the
 * disk once it's committed.
 */
create_volume :: fn(container #escaping : ptr[mut Container], name: string, hash_key: u8[32], now: u64) -> Result[ptr[mut Volume], Error] {
    if name.count == 0 || name.count > VOLUME_NAME_BYTES {
        return .Error(.InvalidName)
    }
    volume := runtime.new(Volume)
    volume^ = Volume.{nodes = &container.nodes, device = container.device, id = container.next_volume, next_object = ROOT_OBJECT + 1,
        hash_key = hash_key, created = now, name_bytes = cast[u16](name.count), dirty = true, now = now}
    volume.tree = Tree.{kind = .Volume, owner = volume.id}
    for character, i in name {
        if i < volume.name.count {
            volume.name[i] = cast[u8](character)
        }
    }
    container.next_volume += 1
    root := ObjectRecord.{kind = cast[u32le](cast[u32](ObjectKind.Directory)), parent = cast[u64le](ROOT_OBJECT),
        created = cast[u64le](now), modified = cast[u64le](now), changed = cast[u64le](container.nodes.transaction)}
    match put_object(volume, ROOT_OBJECT, &root) {
        case Ok => {}
        case Error(error) => {
            free_volume(volume)
            return .Error(error)
        }
    }
    runtime.array_add(&container.open, volume)
    return .Ok(volume)
}

// The volume id, open: already, or from its record.
open_volume :: fn(container #escaping : ptr[mut Container], id: u64) -> Result[ptr[mut Volume], Error] {
    for volume in container.open {
        if volume.id == id {
            return .Ok(volume)
        }
    }
    value : u8[184]
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .VolumeEntry, 0), value)? or_return .Error(.NotFound)
    if bytes != size_of(VolumeRecord) {
        return .Error(.Corrupt)
    }
    record :: cast[ptr[VolumeRecord]](&value[0])
    volume := runtime.new(Volume)
    volume^ = Volume.{nodes = &container.nodes, device = container.device, id = id, next_object = cast[u64](record.next_object),
        hash_key = record.hash_key, created = cast[u64](record.created), name = record.name, name_bytes = cast[u16](record.name_bytes)}
    volume.tree = Tree.{root = record.root, kind = .Volume, owner = id}
    runtime.array_add(&container.open, volume)
    return .Ok(volume)
}

/*
 * A volume from its record, its tree changing in nodes and read and written on device: as open_volume opens one in
 * the container's own process, and as a volume server opens its own (decisions/0089).
 */
attach_volume :: fn(nodes #escaping : ptr[mut Nodes], device #escaping : Device, id: u64, record: VolumeRecord) -> ptr[mut Volume] {
    volume := runtime.new(Volume)
    volume^ = Volume.{nodes = nodes, device = device, id = id, next_object = cast[u64](record.next_object), hash_key = record.hash_key,
        created = cast[u64](record.created), name = record.name, name_bytes = cast[u16](record.name_bytes)}
    volume.tree = Tree.{root = record.root, kind = .Volume, owner = id}
    return volume
}

// What a volume's record says now: its root as it was last written, and the rest.
record_of :: fn(volume: ptr[Volume]) -> VolumeRecord {
    return VolumeRecord.{root = volume.tree.root, next_object = cast[u64le](volume.next_object), hash_key = volume.hash_key,
        created = cast[u64le](volume.created), name_bytes = cast[u16le](volume.name_bytes), name = volume.name}
}

/*
 * A volume's dirty nodes written, children first, and its record as it then is: what a volume server gives the
 * container service to commit (decisions/0089), once the writes have finished.
 */
write_volume :: fn(volume: ptr[mut Volume]) -> Result[VolumeRecord, Error] {
    if volume.failed {
        return .Error(.Failed)
    }
    tree_write(volume.nodes, &volume.tree)?
    volume.dirty = false
    return .Ok(record_of(volume))
}

// The volumes in the container, by ID, from at: the next one's ID, or null.
next_volume_id :: fn(container: ptr[mut Container], at: u64) -> Result[u64?, Error] {
    value : u8[1]
    found :: tree_next(&container.nodes, &container.volumes, key_of(at, .VolumeEntry, 0), value)? or_return .Ok(null)
    return .Ok(found.key.object)
}

// A volume open in the container's own process closed, what it changed since its last commit lost.
close_volume :: fn(container: ptr[mut Container], id: u64) {
    for volume, i in container.open {
        if volume.id == id {
            runtime.array_remove(&container.open, i)
            free_volume(volume)
            return void
        }
    }
}

free_volume :: fn(volume: ptr[mut Volume]) {
    runtime.free(volume)
}

put_volume_record :: fn(container: ptr[mut Container], id: u64, record: ptr[VolumeRecord]) -> Result[void, Error] {
    tree_put(&container.nodes, &container.volumes, key_of(id, .VolumeEntry, 0), view_of(cast[ptr[u8]](record), size_of(VolumeRecord)))?
    return .Ok
}

// A volume's record, from the container's volumes tree.
volume_record :: fn(container: ptr[mut Container], id: u64) -> Result[VolumeRecord, Error] {
    record := VolumeRecord.{}
    bytes :: tree_get(&container.nodes, &container.volumes, key_of(id, .VolumeEntry, 0),
        view_of(cast[ptr[mut u8]](&record), size_of(VolumeRecord)))? or_return .Error(.NotFound)
    if bytes != size_of(VolumeRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

// The volume named name in the container: its ID, or null.
find_volume :: fn(container: ptr[mut Container], name: string) -> Result[u64?, Error] {
    at : u64 = 0
    loop {
        id :: next_volume_id(container, at)? or_return .Ok(null)
        record :: volume_record(container, id)?
        length :: cast[usize](cast[u16](record.name_bytes))
        if length == name.count && length <= record.name.count && same_bytes(record.name[0..<length], name) {
            return .Ok(id)
        }
        if id == 0xffffffffffffffff {
            return .Ok(null)
        }
        at = id + 1
    }
}

// Objects' records.

get_object :: fn(volume: ptr[mut Volume], object: u64) -> Result[ObjectRecord, Error] {
    record := ObjectRecord.{}
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(object, .Object, 0),
        view_of(cast[ptr[mut u8]](&record), size_of(ObjectRecord)))? or_return .Error(.NotFound)
    if bytes != size_of(ObjectRecord) {
        return .Error(.Corrupt)
    }
    return .Ok(record)
}

put_object :: fn(volume: ptr[mut Volume], object: u64, record: ptr[ObjectRecord]) -> Result[void, Error] {
    volume.dirty = true
    tree_put(volume.nodes, &volume.tree, key_of(object, .Object, 0), view_of(cast[ptr[u8]](record), size_of(ObjectRecord)))?
    return .Ok
}

kind_of_record :: fn(record: ptr[ObjectRecord]) -> ObjectKind {
    return if cast[u32](record.kind) == cast[u32](ObjectKind.Directory) { .Directory } else { .File }
}

info :: fn(volume: ptr[mut Volume], object: u64) -> Result[Info, Error] {
    record :: get_object(volume, object)?
    return .Ok(Info.{object = object, kind = kind_of_record(&record), parent = cast[u64](record.parent), size = cast[u64](record.size),
        created = cast[u64](record.created), modified = cast[u64](record.modified), changed = cast[u64](record.changed)})
}

// The record of an object that's a directory, or NotADirectory.
directory_record :: fn(volume: ptr[mut Volume], object: u64) -> Result[ObjectRecord, Error] {
    record :: get_object(volume, object)?
    if kind_of_record(&record) != .Directory {
        return .Error(.NotADirectory)
    }
    return .Ok(record)
}

touch :: fn(volume: ptr[mut Volume], object: u64, record: ptr[mut ObjectRecord]) -> Result[void, Error] {
    record.modified = cast[u64le](volume.now)
    record.changed = cast[u64le](volume.nodes.transaction)
    return put_object(volume, object, record)
}

// Names.

name_holds :: fn(name: string) -> bool {
    if name.count == 0 || name.count > NAME_BYTES || name == "." || name == ".." {
        return false
    }
    for character in name {
        if character == '/' || character == cast[char](0) {
            return false
        }
    }
    return true
}

HASH_MASK : u64 : 0x00ffffffffffffff

// A name's hash, keyed by the volume's key: 56 bits, so a List cursor holds it and a place among those alike.
hash_name :: fn(volume: ptr[Volume], name: string) -> u64 {
    hasher := crypto.blake3_start_keyed(crypto.as_secret(volume.hash_key)) or_return 0
    crypto.blake3_update(&hasher, view_of(cast[ptr[u8]](name.data), name.count))
    digest : u8[8]
    crypto.blake3_finish(&hasher, digest)
    hash : u64 = 0
    for byte, i in digest {
        if i < 7 {
            hash = hash | cast[u64](byte) << cast[u64](i * 8)
        }
    }
    return hash
}

/*
 * A directory's entries whose names hash alike, as stored: one after another, each a head and its name. The record's
 * value is copied into a buffer of MAX_VALUE_BYTES.
 */
EntryList :: struct {
    bytes : u8[4096],
    count : usize,
}

// The entry named name in a list: where it starts, and its head.
EntryAt :: struct {
    at : usize,
    head : EntryHead,
}

entry_head :: fn(list: ptr[EntryList], at: usize) -> EntryHead? {
    if at + size_of(EntryHead) > list.count || at >= list.bytes.count {
        return null
    }
    return cast[ptr[EntryHead]](&list.bytes[at])^
}

// Where each entry in a list starts, stepping from at; null at its end, or where it doesn't hold together.
next_entry_at :: fn(list: ptr[EntryList], at: usize) -> usize? {
    head :: entry_head(list, at) or_return null
    next :: at + size_of(EntryHead) + cast[usize](cast[u16](head.name_bytes))
    return if next <= list.count { next } else { null }
}

entry_name :: fn(list: ptr[EntryList], at: usize, head: ptr[EntryHead]) -> u8[] {
    start :: at + size_of(EntryHead)
    count :: cast[usize](cast[u16](head.name_bytes))
    if start + count > list.count || start >= list.bytes.count {
        return list.bytes[0..<0]
    }
    return view_of(&list.bytes[start], count)
}

same_bytes :: fn(a: u8[], b: string) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && cast[u8](b[i]) != byte {
            return false
        }
    }
    return true
}

find_in_list :: fn(list: ptr[EntryList], name: string) -> EntryAt? {
    at : usize = 0
    loop {
        head :: entry_head(list, at) or_return null
        if same_bytes(entry_name(list, at, &head), name) {
            return EntryAt.{at = at, head = head}
        }
        at = next_entry_at(list, at) or_return null
    }
    while at < list.count
    return null
}

get_entries :: fn(volume: ptr[mut Volume], directory: u64, hash: u64, list: ptr[mut EntryList]) -> Result[void, Error] {
    list.count = tree_get(volume.nodes, &volume.tree, key_of(directory, .Entry, hash), list.bytes)? or_else 0
    return .Ok
}

put_entries :: fn(volume: ptr[mut Volume], directory: u64, hash: u64, list: ptr[EntryList]) -> Result[void, Error] {
    volume.dirty = true
    key :: key_of(directory, .Entry, hash)
    if list.count == 0 {
        tree_delete(volume.nodes, &volume.tree, key)?
        return .Ok
    }
    if list.count > list.bytes.count {
        return .Error(.TooLarge)
    }
    tree_put(volume.nodes, &volume.tree, key, list.bytes[0..<list.count])?
    return .Ok
}

// The object named name in directory, or null.
lookup :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[u64?, Error] {
    directory_record(volume, directory)?
    if !name_holds(name) {
        return .Error(.InvalidName)
    }
    list := runtime.new(EntryList)
    defer runtime.free(list)
    get_entries(volume, directory, hash_name(volume, name), list)?
    found :: find_in_list(list, name) or_return .Ok(null)
    return .Ok(cast[u64](found.head.object))
}

// A new entry in directory, naming object of kind.
add_entry :: fn(volume: ptr[mut Volume], directory: u64, name: string, object: u64, kind: ObjectKind) -> Result[void, Error] {
    hash :: hash_name(volume, name)
    list := runtime.new(EntryList)
    defer runtime.free(list)
    get_entries(volume, directory, hash, list)?
    if find_in_list(list, name) is_some {
        return .Error(.AlreadyExists)
    }
    if list.count + size_of(EntryHead) + name.count > list.bytes.count {
        return .Error(.TooLarge)
    }
    head := EntryHead.{object = cast[u64le](object), kind = cast[u32le](cast[u32](kind)), name_bytes = cast[u16le](cast[u16](name.count))}
    copy_bytes(list.bytes, list.count, view_of(cast[ptr[mut u8]](&head), size_of(EntryHead)))
    copy_bytes(list.bytes, list.count + size_of(EntryHead), view_of(cast[ptr[u8]](name.data), name.count))
    list.count += size_of(EntryHead) + name.count
    put_entries(volume, directory, hash, list)?
    return .Ok
}

remove_entry :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[void, Error] {
    hash :: hash_name(volume, name)
    list := runtime.new(EntryList)
    defer runtime.free(list)
    get_entries(volume, directory, hash, list)?
    found :: find_in_list(list, name) or_return .Error(.NotFound)
    length :: size_of(EntryHead) + cast[usize](cast[u16](found.head.name_bytes))
    for i in found.at..<list.count - length {
        j :: i + length
        if j < list.bytes.count && i < list.bytes.count {
            list.bytes[i] = list.bytes[j]
        }
    }
    list.count -= length
    put_entries(volume, directory, hash, list)?
    return .Ok
}

// Paths: components with '/' between them, each a name, resolved beneath a directory, so nothing leads above it.

// The object at path beneath directory, each component looked up in the one before.
resolve :: fn(volume: ptr[mut Volume], directory: u64, path: string) -> Result[u64, Error] {
    at := directory
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
        at = lookup(volume, at, component)? or_return .Error(.NotFound)
    }
    return .Ok(at)
}

// Where a path's last component goes: the directory holding it, and its name.
Leaf :: struct {
    directory : u64,
    name : string,
}

leaf_of :: fn(volume: ptr[mut Volume], directory: u64, path: string) -> Result[Leaf, Error] {
    last := path.count
    for character, i in path {
        if character == '/' {
            last = i
        }
    }
    if last == path.count {
        return .Ok(Leaf.{directory = directory, name = path})
    }
    if last + 1 > path.count {
        return .Error(.InvalidName)
    }
    parent :: resolve(volume, directory, path[0..<last])?
    directory_record(volume, parent)?
    return .Ok(Leaf.{directory = parent, name = path[last + 1..<path.count]})
}

/*
 * A new file or directory named name in directory: AlreadyExists if the name's taken.
 */
create :: fn(volume: ptr[mut Volume], directory: u64, name: string, kind: ObjectKind) -> Result[u64, Error] {
    parent := directory_record(volume, directory)?
    if !name_holds(name) {
        return .Error(.InvalidName)
    }
    object :: volume.next_object
    add_entry(volume, directory, name, object, kind)?
    volume.next_object += 1
    record := ObjectRecord.{kind = cast[u32le](cast[u32](kind)), parent = cast[u64le](directory), created = cast[u64le](volume.now),
        modified = cast[u64le](volume.now), changed = cast[u64le](volume.nodes.transaction)}
    put_object(volume, object, &record)?
    touch(volume, directory, &parent)?
    return .Ok(object)
}

// Whether a directory has nothing in it.
is_empty :: fn(volume: ptr[mut Volume], directory: u64) -> Result[bool, Error] {
    value : u8[1]
    found :: tree_next(volume.nodes, &volume.tree, key_of(directory, .Entry, 0), value)? or_return .Ok(true)
    return .Ok(found.key.object != directory || found.key.kind != cast[u8](RecordKind.Entry))
}

// The file or empty directory named name in directory, removed, with everything it held.
remove :: fn(volume: ptr[mut Volume], directory: u64, name: string) -> Result[void, Error] {
    parent := directory_record(volume, directory)?
    object :: lookup(volume, directory, name)? or_return .Error(.NotFound)
    record :: get_object(volume, object)?
    if kind_of_record(&record) == .Directory && !(is_empty(volume, object)?) {
        return .Error(.DirectoryNotEmpty)
    }
    remove_entry(volume, directory, name)?
    destroy(volume, object)?
    touch(volume, directory, &parent)?
    return .Ok
}

// An object's chunks and record gone, its blocks given back.
destroy :: fn(volume: ptr[mut Volume], object: u64) -> Result[void, Error] {
    loop {
        extent := ExtentRecord.{}
        found :: tree_next(volume.nodes, &volume.tree, key_of(object, .Extent, 0),
            view_of(cast[ptr[mut u8]](&extent), size_of(ExtentRecord)))? or_break
        if found.key.object != object || found.key.kind != cast[u8](RecordKind.Extent) {
            break
        }
        drop_chunk(volume, found.key, &extent)?
    }
    tree_delete(volume.nodes, &volume.tree, key_of(object, .Object, 0))?
    volume.dirty = true
    return .Ok
}

/*
 * A chunk's record taken out, and its blocks given back if it had any. One a search found but deleting doesn't is a
 * damaged tree's, and Corrupt, so the loops that drop chunks one by one always end.
 */
drop_chunk :: fn(volume: ptr[mut Volume], key: Key, extent: ptr[ExtentRecord]) -> Result[void, Error] {
    if !(tree_delete(volume.nodes, &volume.tree, key)?) {
        return .Error(.Corrupt)
    }
    release_extent(volume, extent)
    volume.dirty = true
    return .Ok
}

release_extent :: fn(volume: ptr[mut Volume], extent: ptr[ExtentRecord]) {
    if cast[u32](extent.kind) == cast[u32](ExtentKind.Blocks) {
        nodes :: volume.nodes
        nodes.release(nodes.space, cast[u64](extent.pointer.address), cast[u64](cast[u32](extent.pointer.blocks)), volume.id,
            cast[u64](extent.pointer.birth))
    }
}

// The most directories deep a volume goes, so walking up from one ends even where a damaged volume loops.
MAX_DEPTH : u64 : 4096

// Whether directory is ancestor, or beneath it.
is_beneath :: fn(volume: ptr[mut Volume], directory: u64, ancestor: u64) -> Result[bool, Error] {
    at := directory
    for step in 0..<MAX_DEPTH {
        if at == ancestor {
            return .Ok(true)
        }
        if at == ROOT_OBJECT {
            return .Ok(false)
        }
        record :: get_object(volume, at)?
        at = cast[u64](record.parent)
    }
    return .Error(.Corrupt)
}

/*
 * What's named from_name in from moved to to_name in to, replacing a file there; a directory can't be moved beneath
 * itself (InvalidName), and a directory isn't replaced (AlreadyExists).
 */
rename :: fn(volume: ptr[mut Volume], from: u64, from_name: string, to: u64, to_name: string) -> Result[void, Error] {
    from_record := directory_record(volume, from)?
    directory_record(volume, to)?
    if !name_holds(to_name) {
        return .Error(.InvalidName)
    }
    object :: lookup(volume, from, from_name)? or_return .Error(.NotFound)
    record := get_object(volume, object)?
    kind :: kind_of_record(&record)
    if kind == .Directory {
        beneath :: is_beneath(volume, to, object)?
        if beneath {
            return .Error(.InvalidName)
        }
    }
    existing :: lookup(volume, to, to_name)?
    match existing {
        case Some(there) => {
            if there == object {
                return .Ok
            }
            replaced :: get_object(volume, there)?
            if kind_of_record(&replaced) == .Directory || kind == .Directory {
                return .Error(.AlreadyExists)
            }
            remove_entry(volume, to, to_name)?
            destroy(volume, there)?
        }
        case None => {}
    }
    remove_entry(volume, from, from_name)?
    add_entry(volume, to, to_name, object, kind)?
    record.parent = cast[u64le](to)
    touch(volume, object, &record)?
    from_record = get_object(volume, from)?
    touch(volume, from, &from_record)?
    if to != from {
        to_record := get_object(volume, to)?
        touch(volume, to, &to_record)?
    }
    return .Ok
}

/*
 * The entry at or after a cursor in directory, its name copied into name, or null after the last. A cursor is a
 * name's hash and its place among those alike, so it stays good while the directory changes.
 */
list :: fn(volume: ptr[mut Volume], directory: u64, cursor: u64, name: mut u8[]) -> Result[Listed?, Error] {
    directory_record(volume, directory)?
    entries := runtime.new(EntryList)
    defer runtime.free(entries)
    hash := cursor >> 8
    skip := cast[usize](cursor & 0xff)
    loop {
        found :: tree_next(volume.nodes, &volume.tree, key_of(directory, .Entry, hash), entries.bytes)? or_return .Ok(null)
        if found.key.object != directory || found.key.kind != cast[u8](RecordKind.Entry) {
            return .Ok(null)
        }
        // A hash past 56 bits isn't one a name makes, and its cursor wouldn't hold it
        if found.key.offset > HASH_MASK {
            return .Error(.Corrupt)
        }
        if found.key.offset != hash {
            skip = 0
        }
        hash = found.key.offset
        entries.count = found.bytes
        at : usize = 0
        for index in 0..<256 {
            head :: entry_head(entries, at) or_break
            if cast[usize](index) >= skip {
                text :: entry_name(entries, at, &head)
                copy_bytes(name, 0, text)
                kind :: if cast[u32](head.kind) == cast[u32](ObjectKind.Directory) { ObjectKind.Directory } else { ObjectKind.File }
                return .Ok(Listed.{name_bytes = text.count, object = cast[u64](head.object), kind = kind,
                    next = hash << 8 | cast[u64](index + 1)})
            }
            at = next_entry_at(entries, at) or_break
        }
        if hash >= HASH_MASK {
            return .Ok(null)
        }
        hash += 1
        skip = 0
    }
}

// Files' bytes.

// bytes from start up to end, or nothing where that's not inside them.
part :: fn(bytes: u8[], start: usize, end: usize) -> u8[] {
    if start <= end && end <= bytes.count {
        return bytes[start..<end]
    }
    return bytes[0..<0]
}

// A record's value, and a chunk, in memory of their own.
ValueBuffer :: struct {
    bytes : u8[4096],
}

ChunkBuffer :: struct {
    bytes : u8[65536],
}

// A chunk's bytes, into a buffer of CHUNK_BYTES: how many were written, the rest of the buffer zeros.
read_chunk :: fn(volume: ptr[mut Volume], file: u64, index: u64, buffer: mut u8[]) -> Result[usize, Error] {
    for i in 0..<buffer.count {
        buffer[i] = 0
    }
    value := runtime.new(ValueBuffer)
    defer runtime.free(value)
    bytes :: tree_get(volume.nodes, &volume.tree, key_of(file, .Extent, index * CHUNK_BYTES), value.bytes)? or_return .Ok(0)
    if bytes < size_of(ExtentRecord) && bytes < cast[usize](INLINE_HEAD) {
        return .Error(.Corrupt)
    }
    extent :: cast[ptr[ExtentRecord]](&value.bytes[0])
    used :: cast[usize](cast[u32](extent.bytes))
    if used > buffer.count {
        return .Error(.Corrupt)
    }
    if cast[u32](extent.kind) == cast[u32](ExtentKind.Inline) {
        if cast[usize](INLINE_HEAD) + used > bytes {
            return .Error(.Corrupt)
        }
        copy_bytes(buffer, 0, part(value.bytes, cast[usize](INLINE_HEAD), cast[usize](INLINE_HEAD) + used))
        return .Ok(used)
    }
    if bytes != size_of(ExtentRecord) || cast[u32](extent.kind) != cast[u32](ExtentKind.Blocks) {
        return .Error(.Corrupt)
    }
    blocks :: cast[u64](cast[u32](extent.pointer.blocks))
    length :: cast[usize](blocks * BLOCK_BYTES)
    if blocks == 0 || length > buffer.count || cast[u64](used) > blocks * BLOCK_BYTES {
        return .Error(.Corrupt)
    }
    device :: volume.device
    if !device.read(device.context, cast[u64](extent.pointer.address), blocks, buffer) {
        return .Error(.DeviceError)
    }
    seal : Seal
    crypto.blake3(buffer[0..<length], seal)
    if seal != extent.pointer.seal {
        return .Error(.Corrupt)
    }
    return .Ok(used)
}

/*
 * A chunk's first used bytes of buffer, written anew: in its record, or in new blocks, sealed, and the blocks it had
 * given back. buffer is zeros past used.
 */
write_chunk :: fn(volume: ptr[mut Volume], file: u64, index: u64, buffer: mut u8[], used: usize, inline: bool) -> Result[void, Error] {
    key :: key_of(file, .Extent, index * CHUNK_BYTES)
    old := ExtentRecord.{}
    had :: tree_get(volume.nodes, &volume.tree, key, view_of(cast[ptr[mut u8]](&old), size_of(ExtentRecord)))?
    volume.dirty = true
    if inline {
        value := runtime.new(ValueBuffer)
        defer runtime.free(value)
        head :: cast[ptr[mut ExtentRecord]](&value.bytes[0])
        head.kind = cast[u32le](cast[u32](ExtentKind.Inline))
        head.bytes = cast[u32le](cast[u32](used))
        copy_bytes(value.bytes, cast[usize](INLINE_HEAD), part(buffer, 0, used))
        tree_put(volume.nodes, &volume.tree, key, part(value.bytes, 0, cast[usize](INLINE_HEAD) + used))?
    }
    else {
        blocks :: (cast[u64](used) + BLOCK_BYTES - 1) / BLOCK_BYTES
        nodes :: volume.nodes
        address :: nodes.allocate(nodes.space, blocks, volume.id) or_return .Error(.NoSpace)
        length :: cast[usize](blocks * BLOCK_BYTES)
        device :: volume.device
        if length > buffer.count || !device.write(device.context, address, blocks, part(buffer, 0, length)) {
            volume.failed = true
            return .Error(.DeviceError)
        }
        extent := ExtentRecord.{kind = cast[u32le](cast[u32](ExtentKind.Blocks)), bytes = cast[u32le](cast[u32](used))}
        extent.pointer = BlockPointer.{address = cast[u64le](address), birth = cast[u64le](nodes.transaction),
            blocks = cast[u32le](cast[u32](blocks))}
        crypto.blake3(part(buffer, 0, length), extent.pointer.seal)
        tree_put(nodes, &volume.tree, key, view_of(cast[ptr[mut u8]](&extent), size_of(ExtentRecord)))?
    }
    if had is_some {
        release_extent(volume, &old)
    }
    return .Ok
}

// The file record of an object that's a file, or IsADirectory.
file_record :: fn(volume: ptr[mut Volume], object: u64) -> Result[ObjectRecord, Error] {
    record :: get_object(volume, object)?
    if kind_of_record(&record) != .File {
        return .Error(.IsADirectory)
    }
    return .Ok(record)
}

// Bytes of a file from offset into into: how many, fewer at its end.
read :: fn(volume: ptr[mut Volume], file: u64, offset: u64, into: mut u8[]) -> Result[usize, Error] {
    record :: file_record(volume, file)?
    size :: cast[u64](record.size)
    if offset >= size {
        return .Ok(0)
    }
    end :: if size - offset < cast[u64](into.count) { size } else { offset + cast[u64](into.count) }
    chunk := runtime.new(ChunkBuffer)
    defer runtime.free(chunk)
    at := offset
    loop {
        index :: at / CHUNK_BYTES
        read_chunk(volume, file, index, chunk.bytes)?
        start :: at - index * CHUNK_BYTES
        stop :: if end < (index + 1) * CHUNK_BYTES { end - index * CHUNK_BYTES } else { CHUNK_BYTES }
        copy_bytes(into, cast[usize](at - offset), part(chunk.bytes, cast[usize](start), cast[usize](stop)))
        at = index * CHUNK_BYTES + stop
    }
    while at < end
    return .Ok(cast[usize](end - offset))
}

// from written into a file at offset, which grows it if it ends past its size.
write :: fn(volume: ptr[mut Volume], file: u64, offset: u64, from: u8[]) -> Result[void, Error] {
    record := file_record(volume, file)?
    end :: offset + cast[u64](from.count)
    if end < offset {
        return .Error(.TooLarge)
    }
    size :: if end > cast[u64](record.size) { end } else { cast[u64](record.size) }
    inline :: size <= INLINE_BYTES
    chunk := runtime.new(ChunkBuffer)
    defer runtime.free(chunk)
    at := offset
    loop {
        index :: at / CHUNK_BYTES
        used := read_chunk(volume, file, index, chunk.bytes)?
        start :: at - index * CHUNK_BYTES
        stop :: if end < (index + 1) * CHUNK_BYTES { end - index * CHUNK_BYTES } else { CHUNK_BYTES }
        copy_bytes(chunk.bytes, cast[usize](start), part(from, cast[usize](at - offset), cast[usize](at - offset + stop - start)))
        if cast[usize](stop) > used {
            used = cast[usize](stop)
        }
        write_chunk(volume, file, index, chunk.bytes, used, inline && index == 0)?
        at = index * CHUNK_BYTES + stop
    }
    while at < end
    // A first chunk held in the record, moved to blocks once the file's past what a record holds
    if !inline {
        move_inline(volume, file, chunk.bytes)?
    }
    record.size = cast[u64le](size)
    touch(volume, file, &record)?
    return .Ok
}

// A file's first chunk, if it's in its record, moved to blocks.
move_inline :: fn(volume: ptr[mut Volume], file: u64, chunk: mut u8[]) -> Result[void, Error] {
    head := ExtentRecord.{}
    had :: tree_get(volume.nodes, &volume.tree, key_of(file, .Extent, 0), view_of(cast[ptr[mut u8]](&head), size_of(ExtentRecord)))?
    if (had is_none) || cast[u32](head.kind) != cast[u32](ExtentKind.Inline) {
        return .Ok
    }
    used :: read_chunk(volume, file, 0, chunk)?
    return write_chunk(volume, file, 0, chunk, used, false)
}

/*
 * A file made size bytes long: shorter, the chunks past it dropped and the last one cut, so what's past the end reads
 * as zeros if it grows again; longer, zeros after its end, without writing them.
 */
set_size :: fn(volume: ptr[mut Volume], file: u64, size: u64) -> Result[void, Error] {
    record := file_record(volume, file)?
    old :: cast[u64](record.size)
    if size < old {
        loop {
            extent := ExtentRecord.{}
            found :: tree_next(volume.nodes, &volume.tree, key_of(file, .Extent, size),
                view_of(cast[ptr[mut u8]](&extent), size_of(ExtentRecord)))? or_break
            if found.key.object != file || found.key.kind != cast[u8](RecordKind.Extent) {
                break
            }
            drop_chunk(volume, found.key, &extent)?
        }
        if size % CHUNK_BYTES != 0 {
            chunk := runtime.new(ChunkBuffer)
            defer runtime.free(chunk)
            index :: size / CHUNK_BYTES
            used := read_chunk(volume, file, index, chunk.bytes)?
            cut :: cast[usize](size - index * CHUNK_BYTES)
            if used > cut {
                for i in cut..<chunk.bytes.count {
                    chunk.bytes[i] = 0
                }
                inline :: is_inline(volume, file)?
                write_chunk(volume, file, index, chunk.bytes, cut, index == 0 && size <= INLINE_BYTES && inline)?
            }
        }
    }
    record.size = cast[u64le](size)
    touch(volume, file, &record)?
    return .Ok
}

is_inline :: fn(volume: ptr[mut Volume], file: u64) -> Result[bool, Error] {
    head := ExtentRecord.{}
    had :: tree_get(volume.nodes, &volume.tree, key_of(file, .Extent, 0), view_of(cast[ptr[mut u8]](&head), size_of(ExtentRecord)))?
    return .Ok((had is_some) && cast[u32](head.kind) == cast[u32](ExtentKind.Inline))
}
