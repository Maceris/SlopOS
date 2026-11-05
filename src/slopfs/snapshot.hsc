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

/** A snapshot's record, and its number among its volume's. */
NumberedSnapshot :: struct {
    /** Its number among its volume's, from 1, the offset of its record's key. */
    number : u64,
    /** Its record, as read. */
    record : SnapshotRecord,
}

/** An extent on a volume's dead list. */
DeadExtent :: struct {
    /** Its first block, the offset of its record's key. */
    start : u64,
    /** Its record: its length, and when it was born and given back. */
    value : DeadValue,
}

/**
 * Get whose key records a volume uses: its own, or for a clone, its origin's.
 *
 * @param id The volume the record is of; it's what's returned when the record names no other owner.
 * @param record The volume's record, only read: its key_owner, nonzero for a clone, names the volume whose key
 *     records it uses.
 * @return The record's key_owner, or id when that's 0.
 */
key_owner_of :: fn(id: u64, record: ptr[VolumeRecord]) -> u64 {
    owner :: cast[u64](record.key_owner)
    return if owner != 0 { owner } else { id }
}

/**
 * List a volume's snapshots, by number, so oldest first.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume whose Snapshot records are listed; not checked, so a volume that isn't there lists none.
 * @param found Where they're added, with context's allocator; the caller's to free, even on an error, when it may
 *     hold some.
 * @error Corrupt A record isn't a SnapshotRecord, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for the list or a node.
 */
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
        if runtime.array_try_add(found, NumberedSnapshot.{number = item.key.offset, record = record}) != null {
            return .Error(.OutOfMemory)
        }
        at = key_after(item.key) or_break
    }
    return .Ok
}

/**
 * Get a snapshot's name.
 *
 * @param record The snapshot's record: name_bytes says how much of its name field is the name.
 * @return Its name's bytes, a view into the record, good as long as it is; empty if name_bytes is past the field.
 */
name_of_snapshot :: fn(record: ptr[SnapshotRecord]) -> u8[] {
    length :: cast[usize](cast[u16](record.name_bytes))
    if length > record.name.count {
        return record.name[0..<0]
    }
    return record.name[0..<length]
}

/**
 * Find a volume's snapshot by its name.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume whose snapshots are searched; not checked, so a volume that isn't there has none.
 * @param name The snapshot's name, compared byte for byte.
 * @return The snapshot; null if the volume has none of the name.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for the list or a node.
 */
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

/**
 * Tell whether bytes can be a volume's or a snapshot's name.
 *
 * @param name The name's bytes, as given; not checked as UTF-8.
 * @return True if they're 1 to VOLUME_NAME_BYTES long, without '/', '@' or NUL; they aren't checked as UTF-8.
 */
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

/**
 * Take a snapshot of a volume: its root and next object as its last commit left them, not as they are in memory now.
 *
 * It's durable with the next commit (commit_own makes it so at once). From now on, what the volume gives back that the
 * snapshot holds goes on its dead list, charged to it.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume to snapshot, which has to be there; its record's root and next object as committed are
 *     pinned, and its floor is raised to the durable transaction.
 * @param name The snapshot's name, which volume_name_holds, and none of the volume's other snapshots has.
 * @param now When it's taken, as its taker says, kept in its record.
 * @return Its number, one more than the volume's highest now.
 * @error InvalidName The name can't be a snapshot's.
 * @error NotFound The volume isn't there.
 * @error AlreadyExists The volume has a snapshot of the name.
 * @error OutOfMemory No memory for the floor, the list or a node; nothing was changed.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
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
    // The floor's room, before the snapshot's record is put
    if !space_room(&container.space, 0, 0, 0, 1) {
        return .Error(.OutOfMemory)
    }
    snapshot := SnapshotRecord.{root = record.root, transaction = cast[u64le](transaction), next_object = record.next_object,
        created = cast[u64le](now), name_bytes = cast[u16le](cast[u16](name.count))}
    for byte, i in name {
        if i < snapshot.name.count {
            snapshot.name[i] = byte
        }
    }
    tree_put(&container.nodes, &container.volumes, key_of(id, .Snapshot, number), view_of(cast[ptr[u8]](&snapshot), size_of(SnapshotRecord)))?
    set_floor(&container.space, id, transaction, null)
    // What this transaction already freed of the volume's, which the snapshot's root may still name
    hold_freed(&container.space, id, transaction)
    return .Ok(number)
}

/**
 * List a volume's dead list, by first block, as its last durable state and this transaction's changes to the volumes
 * tree have it; extents waiting to go on it this transaction aren't listed.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume whose Dead records are listed; not checked, so a volume that isn't there lists none.
 * @param found Where they're added, with context's allocator; the caller's to free, even on an error.
 * @error Corrupt A record isn't a DeadValue, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for the list or a node.
 */
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
        if runtime.array_try_add(found, DeadExtent.{start = item.key.offset, value = value}) != null {
            return .Error(.OutOfMemory)
        }
        at = key_after(item.key) or_break
    }
    return .Ok
}

/**
 * Tell whether any of a volume's snapshots holds a block: one taken at t holds it when birth <= t < freed.
 *
 * @param snapshots The volume's snapshots that remain, any order.
 * @param birth The transaction the block was born in.
 * @param freed The transaction it was given back in.
 * @return True if one holds it.
 */
held_by :: fn(snapshots: NumberedSnapshot[], birth: u64, freed: u64) -> bool {
    for each in snapshots {
        taken :: cast[u64](each.record.transaction)
        if birth <= taken && taken < freed {
            return true
        }
    }
    return false
}

/**
 * Delete a volume's snapshot, and free what only it held: dead extents no other snapshot holds, and those waiting to
 * go on the dead list this transaction.
 *
 * It's durable with the next commit; what it frees is free once that commit is. The snapshot's record is deleted
 * before memory for the rest is reserved, so OutOfMemory can leave it deleted with its dead extents still listed, to
 * be freed when another snapshot is deleted.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume the snapshot is of; its dead extents are freed, uncharged, and its floor set to its newest
 *     remaining snapshot's transaction, or 0.
 * @param name The snapshot's name, compared byte for byte with the volume's snapshots'.
 * @param freed Where the extents freed are added, for whoever keeps who owns what, with context's allocator; null
 *     when no one does.
 * @error NotFound The volume has no snapshot of the name.
 * @error InUse A clone was made from the snapshot and is still there.
 * @error OutOfMemory No memory for a list, the space's records or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
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
    // The snapshots left once it's gone, read before anything changes
    listed : NumberedSnapshot[..]
    defer runtime.array_free(&listed)
    snapshot_records(container, id, &listed)?
    remaining : NumberedSnapshot[..]
    defer runtime.array_free(&remaining)
    for each in listed {
        if each.number != found.number && runtime.array_try_add(&remaining, each) != null {
            return .Error(.OutOfMemory)
        }
    }
    dead : DeadExtent[..]
    defer runtime.array_free(&dead)
    dead_extents(container, id, &dead)?
    // Room for each dead extent freed, and each waiting to be, before any is
    space :: &container.space
    count :: dead.count + space.changes.count
    if !space_room(space, count, count, 0, 1) {
        return .Error(.OutOfMemory)
    }
    match freed {
        case Some(list) => {
            if runtime.array_try_reserve(list, list.count + count) != null {
                return .Error(.OutOfMemory)
            }
        }
        case None => {}
    }
    // Only now, with every reservation made, is its record taken out: a failure before here changes nothing
    tree_delete(&container.nodes, &container.volumes, key_of(id, .Snapshot, found.number))?
    for each in dead {
        if !held_by(remaining, cast[u64](each.value.birth), cast[u64](each.value.freed)) {
            tree_delete(&container.nodes, &container.volumes, key_of(id, .Dead, each.start))?
            space_free_held(&container.space, each.start, cast[u64](each.value.blocks), id)
            match freed {
                case Some(list) => runtime.array_add(list, Extent.{start = each.start, blocks = cast[u64](each.value.blocks)})
                case None => {}
            }
        }
    }
    // What's waiting to go on the dead list this transaction, freed in it
    for &change in space.changes {
        if change.change == .Dead && change.owner == id && !held_by(remaining, change.birth, container.nodes.transaction) {
            change.change = .FreedLater
            change.owner = 0
            runtime.array_add(&space.later, Later.{start = change.start, blocks = change.blocks, owner = 0})
            charge(space, id, change.blocks, false)
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

/**
 * Work out who wrote the older blocks of a volume: its origin up to its snapshot's transaction, the origin's origin
 * before that, and so on.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param record The volume's record, only read: its origin (0 for none) and the transaction its blocks are the
 *     origin's up to; each origin's own record is then read from the container.
 * @return Its lineage, nearest first; empty for a volume that isn't a clone.
 * @error TooLarge The lineage is longer than MAX_LINEAGE.
 * @error NotFound An origin isn't there.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
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

/**
 * Make a new volume, cloned from a volume's snapshot: its tree starts as the snapshot's, its names hash as the
 * origin's do, and an encrypted one uses the origin's keys.
 *
 * It's on the disk once it's committed (commit_own makes it so at once). Its blocks up to the snapshot's transaction
 * are the origin's, and the snapshot can't be deleted while the clone is there. It has no quota.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume to clone, which has to be there: its hash key, cipher, generation and key owner go to the
 *     clone, and it becomes the clone's origin.
 * @param snapshot The name of the origin's snapshot to clone, compared byte for byte; its root, next object and
 *     transaction start the clone.
 * @param name The clone's name, which volume_name_holds and no volume in the container has.
 * @param now When it's made, as its maker says, kept in its record.
 * @return The clone's ID, a new one.
 * @error InvalidName The name can't be a volume's.
 * @error AlreadyExists A volume of the name is in the container.
 * @error NotFound The origin, or its snapshot of the name, or an origin of its, isn't there.
 * @error TooLarge The clone's lineage would be longer than MAX_LINEAGE.
 * @error OutOfMemory No memory for the floor, a list or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
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
    // The floor's room, before the clone's record is put
    if !space_room(&container.space, 0, 0, 0, 1) {
        return .Error(.OutOfMemory)
    }
    made :: container.next_volume
    container.next_volume += 1
    put_volume_record(container, made, &clone)?
    set_floor(&container.space, made, null, cast[u64](found.record.transaction))
    return .Ok(made)
}

/**
 * Load every volume's floors and accounts when a container is mounted: a clone's origin's transaction, each volume's
 * newest snapshot's, every block each owns from the owners tree, and their quotas; and the container's reserve.
 *
 * @param container The container, just mounted.
 * @error OutOfMemory No memory for an account, a floor, a list or a node.
 * @error NotFound A volume found isn't there to read.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
load_floors :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    container.space.reserve = reserve_of(container.device.block_count)
    owner := OwnerValue.{}
    owner_at := Key.{}
    loop {
        found :: tree_next(&container.nodes, &container.owners, owner_at, view_of(cast[ptr[mut u8]](&owner), size_of(OwnerValue)))? or_break
        if !space_room(&container.space, 0, 0, 0, 1) {
            return .Error(.OutOfMemory)
        }
        charge(&container.space, cast[u64](owner.volume), cast[u64](owner.blocks), true)
        owner_at = key_after(found.key) or_break
    }
    at : u64 = 0
    loop {
        id :: next_volume_id(container, at)? or_return .Ok
        record :: volume_record(container, id)?
        if !space_room(&container.space, 0, 0, 0, 1) {
            return .Error(.OutOfMemory)
        }
        if cast[u64](record.quota) != 0 {
            set_quota_of(&container.space, id, cast[u64](record.quota))
        }
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

/**
 * Make the record a volume server serves a snapshot as: the volume's, with the snapshot's root and next object.
 *
 * It's to be served read only: its server commits nothing.
 *
 * @param volume The record of the volume the snapshot is of, copied, not changed: everything but its root and
 *     next object is kept.
 * @param snapshot The snapshot's record, only read: its root and next object replace the volume's.
 * @return The record, a copy.
 */
snapshot_volume_record :: fn(volume: ptr[VolumeRecord], snapshot: ptr[SnapshotRecord]) -> VolumeRecord {
    record := volume^
    record.root = snapshot.root
    record.next_object = snapshot.next_object
    return record
}

/**
 * Open a volume's snapshot read only, in the container's own process.
 *
 * It isn't among the open volumes, so nothing commits it or frees it with the container.
 *
 * @param container The container, which has to outlive the volume.
 * @param id The volume the snapshot is of, which has to be there; the snapshot is served under this ID, with its
 *     lineage.
 * @param name The snapshot's name, compared byte for byte with the volume's snapshots'.
 * @param keys For an encrypted volume, its keys, which the volume then owns, freed with it even when opening fails
 *     after the snapshot is found; null for one that isn't encrypted.
 * @return The snapshot's volume, the caller's to free with free_volume.
 * @error NotFound The volume, or its snapshot of the name, isn't there.
 * @error Locked The volume is encrypted, and no keys were given.
 * @error TooLarge The volume's lineage is longer than MAX_LINEAGE.
 * @error OutOfMemory No memory for the volume or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
open_snapshot :: fn(container #escaping : ptr[mut Container], id: u64, name: u8[], keys #escaping : ptr[mut Keys]?) -> Result[ptr[mut Volume], Error] {
    record := volume_record(container, id)?
    found :: find_snapshot(container, id, name)? or_return .Error(.NotFound)
    if record.cipher != cast[u8](Cipher.None) && (keys is_none) {
        return .Error(.Locked)
    }
    snapshot := found.record
    volume :: match attach_volume(&container.nodes, container.device, id, snapshot_volume_record(&record, &snapshot), keys) {
        case Ok(made) => made
        case Error(error) => {
            match keys {
                case Some(given) => free_keys(given)
                case None => {}
            }
            return .Error(error)
        }
    }
    match lineage_of(container, &record) {
        case Ok(lineage) => volume.tree.lineage = lineage
        case Error(error) => {
            free_volume(volume)
            return .Error(error)
        }
    }
    return .Ok(volume)
}

/**
 * Tell whether two byte strings are the same.
 *
 * @param a A byte string, of any length.
 * @param b The other byte string, of any length.
 * @return True if they're the same length and byte for byte alike.
 */
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

/**
 * Find a volume in the container by its name, as bytes.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param name The name, compared byte for byte.
 * @return The volume's ID; null if no volume has the name.
 * @error NotFound A volume found isn't there to read.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
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

// Quotas (space.hsc)

/**
 * Set a volume's quota.
 *
 * It's durable with the next commit; a file's bytes past it are refused from now on, but what the volume has already
 * past it is kept.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume to limit, which has to be there; its record is changed, and its open volume's copy and the
 *     space's account with it.
 * @param blocks The most blocks it may have, its snapshots' included; 0 for no limit.
 * @error NotFound The volume isn't there.
 * @error OutOfMemory No memory for the account or a node.
 * @error Corrupt A record or a node couldn't be read or didn't check out.
 */
set_quota :: fn(container: ptr[mut Container], id: u64, blocks: u64) -> Result[void, Error] {
    record := volume_record(container, id)?
    if !space_room(&container.space, 0, 0, 0, 1) {
        return .Error(.OutOfMemory)
    }
    record.quota = cast[u64le](blocks)
    put_volume_record(container, id, &record)?
    for volume in container.open {
        if volume.id == id {
            volume.opened.quota = cast[u64le](blocks)
        }
    }
    set_quota_of(&container.space, id, blocks)
    return .Ok
}

/** A volume's blocks, its quota, and what's free in its container, past the reserve, all in blocks. */
Usage :: struct {
    /** The blocks the volume owns, its dead list's included. */
    used : u64,
    /** Its quota; 0 for no limit. */
    quota : u64,
    /** The container's free blocks past the reserve, which a file's bytes may take; 0 when the reserve isn't met. */
    free : u64,
    /** The container's reserve. */
    reserve : u64,
}

/**
 * Get a volume's usage, as the space in memory has it now.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume's ID; one with no account uses nothing and has no quota.
 * @return The volume's usage now, in blocks; nothing is read from the disk.
 */
usage_of :: fn(container: ptr[Container], id: u64) -> Usage {
    account :: account_of(&container.space, id)
    space :: &container.space
    return Usage.{used = account.used, quota = account.quota,
        free = if space.free_blocks > space.reserve { space.free_blocks - space.reserve } else { 0 }, reserve = space.reserve}
}
