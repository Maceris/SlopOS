package slopfs

import runtime from "base"

/*
 * Snapshots and clones (roadmap 8e, design/storage.md §3), as ZFS has them, by birth times and dead lists. A snapshot
 * pins a volume's root as its last commit left it, with the transaction that commit made durable: every block in its
 * tree was born then or before. A block the volume gives back that was born at or before its newest snapshot's
 * transaction is held by that snapshot, or an older one, so it isn't freed but goes on the volume's dead list, with
 * when it was born and when it was given back; a snapshot taken at t holds a dead block born at b and given back at f
 * when b <= t < f. Deleting a snapshot frees the dead blocks no other snapshot holds. There are no reference counts.
 *
 * A clone is a new volume whose tree starts as a snapshot's: its blocks up to that snapshot's transaction are its
 * origin's, which it reads but never frees, and the snapshot can't be deleted while the clone is there. A clone's tree
 * knows whose its older blocks are (its lineage), since a block's header and an encrypted one's associated data name
 * the volume that wrote it. A clone of an encrypted volume uses its origin's keys: the same volume key, and its key
 * records, which new generations are added to whichever of them starts one.
 */

// A snapshot's record, and its number among its volume's, from 1.
NumberedSnapshot :: struct {
    number : u64,
    record : SnapshotRecord,
}

// An extent on a volume's dead list.
DeadExtent :: struct {
    start : u64,
    value : DeadValue,
}

// Whose key records a volume uses: its own, or for a clone, its origin's.
key_owner_of :: fn(id: u64, record: ptr[VolumeRecord]) -> u64 {
    owner :: cast[u64](record.key_owner)
    return if owner != 0 { owner } else { id }
}

// A volume's snapshots, oldest first, added to found, which is the caller's to free.
snapshot_records :: fn(container: ptr[mut Container], id: u64, found: ptr[mut NumberedSnapshot[..]]) -> Result[void, Error] {
    record := SnapshotRecord.{}
    at := key_of(id, .Snapshot, 0)
    loop {
        item :: tree_next(&container.nodes, &container.volumes, at, view_of(cast[ptr[mut u8]](&record), size_of(SnapshotRecord)))? or_break
        if item.key.object != id || item.key.kind != cast[u8](RecordKind.Snapshot) {
            break
        }
        if item.bytes != size_of(SnapshotRecord) {
            return .Error(.Corrupt)
        }
        runtime.array_add(found, NumberedSnapshot.{number = item.key.offset, record = record})
        at = key_after(item.key) or_break
    }
    return .Ok
}

name_of_snapshot :: fn(record: ptr[SnapshotRecord]) -> u8[] {
    length :: cast[usize](cast[u16](record.name_bytes))
    if length > record.name.count {
        return record.name[0..<0]
    }
    return record.name[0..<length]
}

// A volume's snapshot named name, or null.
find_snapshot :: fn(container: ptr[mut Container], id: u64, name: u8[]) -> Result[NumberedSnapshot?, Error] {
    snapshots : NumberedSnapshot[..]
    defer runtime.array_free(&snapshots)
    snapshot_records(container, id, &snapshots)?
    for each in snapshots {
        record := each.record
        if equal_bytes(name_of_snapshot(&record), name) {
            return .Ok(each)
        }
    }
    return .Ok(null)
}

// Whether name is a volume's or snapshot's name: not empty, not too long, without '/', '@' or NUL.
volume_name_holds :: fn(name: u8[]) -> bool {
    if name.count == 0 || name.count > VOLUME_NAME_BYTES {
        return false
    }
    for byte in name {
        if byte == cast[u8]('/') || byte == cast[u8]('@') || byte == 0 {
            return false
        }
    }
    return true
}

/*
 * A snapshot of the volume id named name: its root and next object as its last commit left them, durable with the
 * next commit. Its number. From now on, what the volume gives back that the snapshot holds goes on its dead list.
 */
take_snapshot :: fn(container: ptr[mut Container], id: u64, name: u8[], now: u64) -> Result[u64, Error] {
    if !volume_name_holds(name) {
        return .Error(.InvalidName)
    }
    record :: volume_record(container, id)?
    snapshots : NumberedSnapshot[..]
    defer runtime.array_free(&snapshots)
    snapshot_records(container, id, &snapshots)?
    number : u64 = 1
    for each in snapshots {
        candidate := each.record
        if equal_bytes(name_of_snapshot(&candidate), name) {
            return .Error(.AlreadyExists)
        }
        if each.number >= number {
            number = each.number + 1
        }
    }
    transaction :: durable_transaction(container)
    snapshot := SnapshotRecord.{root = record.root, transaction = cast[u64le](transaction), next_object = record.next_object,
        created = cast[u64le](now), name_bytes = cast[u16le](cast[u16](name.count))}
    for byte, i in name {
        if i < snapshot.name.count {
            snapshot.name[i] = byte
        }
    }
    tree_put(&container.nodes, &container.volumes, key_of(id, .Snapshot, number), view_of(cast[ptr[u8]](&snapshot), size_of(SnapshotRecord)))?
    set_floor(&container.space, id, transaction, null)
    return .Ok(number)
}

// A volume's dead list, added to found, which is the caller's to free.
dead_extents :: fn(container: ptr[mut Container], id: u64, found: ptr[mut DeadExtent[..]]) -> Result[void, Error] {
    value := DeadValue.{}
    at := key_of(id, .Dead, 0)
    loop {
        item :: tree_next(&container.nodes, &container.volumes, at, view_of(cast[ptr[mut u8]](&value), size_of(DeadValue)))? or_break
        if item.key.object != id || item.key.kind != cast[u8](RecordKind.Dead) {
            break
        }
        if item.bytes != size_of(DeadValue) {
            return .Error(.Corrupt)
        }
        runtime.array_add(found, DeadExtent.{start = item.key.offset, value = value})
        at = key_after(item.key) or_break
    }
    return .Ok
}

// Whether any of snapshots holds a block born in birth and given back in freed.
held_by :: fn(snapshots: NumberedSnapshot[], birth: u64, freed: u64) -> bool {
    for each in snapshots {
        taken :: cast[u64](each.record.transaction)
        if birth <= taken && taken < freed {
            return true
        }
    }
    return false
}

/*
 * The volume id's snapshot named name deleted, and what only it held freed: durable with the next commit, and added
 * to freed, if it's given, for whoever keeps who owns what. InUse while a clone was made from it.
 */
delete_snapshot :: fn(container: ptr[mut Container], id: u64, name: u8[], freed: ptr[mut Extent[..]]?) -> Result[void, Error] {
    found :: find_snapshot(container, id, name)? or_return .Error(.NotFound)
    // Not while a clone's tree starts as it
    at : u64 = 0
    loop {
        other :: next_volume_id(container, at)? or_break
        record :: volume_record(container, other)?
        if cast[u64](record.origin) == id && cast[u64](record.origin_snapshot) == found.number {
            return .Error(.InUse)
        }
        if other == 0xffffffffffffffff {
            break
        }
        at = other + 1
    }
    tree_delete(&container.nodes, &container.volumes, key_of(id, .Snapshot, found.number))?
    remaining : NumberedSnapshot[..]
    defer runtime.array_free(&remaining)
    snapshot_records(container, id, &remaining)?
    dead : DeadExtent[..]
    defer runtime.array_free(&dead)
    dead_extents(container, id, &dead)?
    for each in dead {
        if !held_by(remaining, cast[u64](each.value.birth), cast[u64](each.value.freed)) {
            tree_delete(&container.nodes, &container.volumes, key_of(id, .Dead, each.start))?
            space_free_held(&container.space, each.start, cast[u64](each.value.blocks))
            match freed {
                case Some(list) => runtime.array_add(list, Extent.{start = each.start, blocks = cast[u64](each.value.blocks)})
                case None => {}
            }
        }
    }
    // What's waiting to go on the dead list this transaction, freed in it
    space :: &container.space
    for &change in space.changes {
        if change.change == .Dead && change.owner == id && !held_by(remaining, change.birth, container.nodes.transaction) {
            change.change = .FreedLater
            change.owner = 0
            runtime.array_add(&space.later, Later.{start = change.start, blocks = change.blocks, owner = 0})
            match freed {
                case Some(list) => runtime.array_add(list, Extent.{start = change.start, blocks = change.blocks})
                case None => {}
            }
        }
    }
    newest : u64 = 0
    for each in remaining {
        if cast[u64](each.record.transaction) > newest {
            newest = cast[u64](each.record.transaction)
        }
    }
    set_floor(space, id, newest, null)
    return .Ok
}

/*
 * Who wrote the older blocks of the volume whose record is given: its origin up to its snapshot's transaction, the
 * origin's origin before that, and so on. TooLarge past MAX_LINEAGE.
 */
lineage_of :: fn(container: ptr[mut Container], record: ptr[VolumeRecord]) -> Result[Lineage, Error] {
    lineage := Lineage.{}
    origin := cast[u64](record.origin)
    up_to := cast[u64](record.origin_transaction)
    loop {
        if origin == 0 {
            return .Ok(lineage)
        }
        if lineage.count >= MAX_LINEAGE {
            return .Error(.TooLarge)
        }
        index :: lineage.count
        if index < lineage.owners.count && index < lineage.up_to.count {
            lineage.owners[index] = origin
            lineage.up_to[index] = up_to
        }
        lineage.count = index + 1
        above :: volume_record(container, origin)?
        origin = cast[u64](above.origin)
        up_to = cast[u64](above.origin_transaction)
    }
}

/*
 * A new volume named name, cloned from the volume id's snapshot named snapshot: its tree starts as the snapshot's, its
 * names hash as the origin's do, and an encrypted one uses the origin's keys. Its ID; it's on the disk once it's
 * committed.
 */
clone_snapshot :: fn(container: ptr[mut Container], id: u64, snapshot: u8[], name: u8[], now: u64) -> Result[u64, Error] {
    if !volume_name_holds(name) {
        return .Error(.InvalidName)
    }
    if find_volume_named(container, name)? is_some {
        return .Error(.AlreadyExists)
    }
    origin := volume_record(container, id)?
    found :: find_snapshot(container, id, snapshot)? or_return .Error(.NotFound)
    lineage :: lineage_of(container, &origin)?
    if lineage.count + 1 > MAX_LINEAGE {
        return .Error(.TooLarge)
    }
    clone := VolumeRecord.{root = found.record.root, next_object = found.record.next_object, hash_key = origin.hash_key,
        created = cast[u64le](now), name_bytes = cast[u16le](cast[u16](name.count)), cipher = origin.cipher, generation = origin.generation,
        origin = cast[u64le](id), origin_snapshot = cast[u64le](found.number), origin_transaction = found.record.transaction,
        key_owner = cast[u64le](key_owner_of(id, &origin))}
    for byte, i in name {
        if i < clone.name.count {
            clone.name[i] = byte
        }
    }
    made :: container.next_volume
    container.next_volume += 1
    put_volume_record(container, made, &clone)?
    set_floor(&container.space, made, null, cast[u64](found.record.transaction))
    return .Ok(made)
}

/*
 * Every volume's floors, from their records and snapshots, when a container is mounted: a clone's origin's transaction,
 * and each volume's newest snapshot's.
 */
load_floors :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    at : u64 = 0
    loop {
        id :: next_volume_id(container, at)? or_return .Ok
        record :: volume_record(container, id)?
        if cast[u64](record.origin) != 0 {
            set_floor(&container.space, id, null, cast[u64](record.origin_transaction))
        }
        snapshots : NumberedSnapshot[..]
        listed :: snapshot_records(container, id, &snapshots)
        newest : u64 = 0
        for each in snapshots {
            if cast[u64](each.record.transaction) > newest {
                newest = cast[u64](each.record.transaction)
            }
        }
        runtime.array_free(&snapshots)
        listed?
        if newest != 0 {
            set_floor(&container.space, id, newest, null)
        }
        if id == 0xffffffffffffffff {
            return .Ok
        }
        at = id + 1
    }
}

/*
 * The record a volume server serves a snapshot as: the volume's, with the snapshot's root and next object, read only
 * (its server commits nothing).
 */
snapshot_volume_record :: fn(volume: ptr[VolumeRecord], snapshot: ptr[SnapshotRecord]) -> VolumeRecord {
    record := volume^
    record.root = snapshot.root
    record.next_object = snapshot.next_object
    return record
}

/*
 * The volume id's snapshot named name, opened read only in the container's own process with keys, if it's encrypted,
 * which it then owns: not among the open volumes, so nothing commits it. For free_volume.
 */
open_snapshot :: fn(container #escaping : ptr[mut Container], id: u64, name: u8[], keys #escaping : ptr[mut Keys]?) -> Result[ptr[mut Volume], Error] {
    record := volume_record(container, id)?
    found :: find_snapshot(container, id, name)? or_return .Error(.NotFound)
    if record.cipher != cast[u8](Cipher.None) && (keys is_none) {
        return .Error(.Locked)
    }
    snapshot := found.record
    volume :: attach_volume(&container.nodes, container.device, id, snapshot_volume_record(&record, &snapshot), keys)
    match lineage_of(container, &record) {
        case Ok(lineage) => volume.tree.lineage = lineage
        case Error(error) => {
            free_volume(volume)
            return .Error(error)
        }
    }
    return .Ok(volume)
}

equal_bytes :: fn(a: u8[], b: u8[]) -> bool {
    if a.count != b.count {
        return false
    }
    for byte, i in a {
        if i < b.count && b[i] != byte {
            return false
        }
    }
    return true
}

// The volume named name in the container, its name as bytes: its ID, or null.
find_volume_named :: fn(container: ptr[mut Container], name: u8[]) -> Result[u64?, Error] {
    at : u64 = 0
    loop {
        id :: next_volume_id(container, at)? or_return .Ok(null)
        record :: volume_record(container, id)?
        length :: cast[usize](cast[u16](record.name_bytes))
        if length <= record.name.count && equal_bytes(record.name[0..<length], name) {
            return .Ok(id)
        }
        if id == 0xffffffffffffffff {
            return .Ok(null)
        }
        at = id + 1
    }
}
