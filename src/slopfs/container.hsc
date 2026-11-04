package slopfs

import runtime from "base"
import crypto from "std"
import maps from "std"

/*
 * A container (design/storage.md §3): its space, its three trees, the volumes open on it, and the transaction they're
 * all changing. Changes stay in memory until commit, which writes them and a checkpoint naming them, each after a
 * flush, so the checkpoint is only on the disk once everything it names is: after a crash, mounting finds the last
 * checkpoint written whole, and the state it names. A write that fails stops every later commit (Failed), rather
 * than let a later one name what wasn't written.
 */

/** The most times a commit goes round bringing the space map and owners up to date with what changing them changed. */
MAX_ROUNDS :: 64

/**
 * A container, mounted or being made: its space, its three trees, the volumes open on it, and the transaction they're
 * all changing.
 *
 * It's from make, the caller's until unmount frees it. Its fields are this package's to keep.
 */
Container :: struct {
    /** The device it's on, the whole of it. */
    device : Device,
    /** Its ID, from the superblock, which every checkpoint names. */
    id : u8[16],
    /** The transaction being made, and its dirty nodes, shared by its trees and its open volumes'. */
    nodes : Nodes,
    /** Its free extents and the changes its space map and owners have still to take. */
    space : Space,
    /** The space map: its free extents, and those freed in the last commit. */
    space_map : Tree,
    /** The owner of every allocated extent. */
    owners : Tree,
    /** Its volumes, their keys, snapshots and dead lists. */
    volumes : Tree,
    /** The ID the next volume made gets, from 1. */
    next_volume : u64,
    /** Whether a write has failed since it was mounted, so every later commit is refused with Failed. */
    failed : bool,
    /** The volumes open on it, which commit writes and unmount frees; the container's own. */
    open : ptr[mut Volume][..],
}

/**
 * Get a device's last block, where the second superblock is.
 *
 * @param device The device, of at least 1 block.
 * @return The last block's number, block_count - 1.
 */
last_block :: fn(device: Device) -> u64 {
    return device.block_count - 1
}

/**
 * Make a container in memory, before anything is read or written: no trees, and the transaction after another.
 *
 * @param device The device, which the container keeps; its context has to outlive the container.
 * @param transaction The last durable transaction, 0 for a new container; the container makes the one after it.
 * @return The container, from make, the caller's to free with unmount; its ID all zero until the caller sets it.
 * @error OutOfMemory No memory for it.
 */
new_container :: fn(device #escaping : Device, transaction: u64) -> Result[ptr[mut Container], Error] {
    container :: make(Container)?
    container^ = Container.{device = device}
    container.space.transaction = transaction + 1
    container.nodes = Nodes.{device = device, transaction = transaction + 1, space = cast[rawptr](&container.space),
        allocate = space_allocate, release = space_release}
    container.space_map = Tree.{kind = .SpaceMap, ditto = true}
    container.owners = Tree.{kind = .Owners, ditto = true}
    container.volumes = Tree.{kind = .Volumes, ditto = true}
    container.next_volume = 1
    return .Ok(container)
}

/**
 * Make a new container on a whole device: its superblocks, and a first checkpoint whose space map frees everything
 * but itself.
 *
 * The superblocks are written first, then the first commit: its nodes, a flush, the checkpoint, a flush. A crash
 * before the checkpoint is written leaves superblocks with no checkpoint, which doesn't mount (NotSlopfs). Nothing is
 * left in memory.
 *
 * @param device The device, all of whose blocks the container takes; its context has to outlive the call.
 * @param id The container's ID, which every checkpoint names.
 * @error NoSpace The device has fewer than MIN_BLOCKS blocks.
 * @error OutOfMemory No memory for the container or a node.
 * @error DeviceError The device couldn't be written or flushed.
 * @error Corrupt The first commit went round more than MAX_ROUNDS times.
 */
format :: fn(device #escaping : Device, id: u8[16]) -> Result[void, Error] {
    if device.block_count < MIN_BLOCKS {
        return .Error(.NoSpace)
    }
    container :: new_container(device, 0)?
    defer unmount(container)
    container.id = id
    add_free(&container.space, FIRST_DATA, last_block(device) - FIRST_DATA)
    space_map_put_free(container, FIRST_DATA, last_block(device) - FIRST_DATA)?
    superblock := Superblock.{version = cast[u32le](FORMAT_VERSION), block_bytes = cast[u32le](cast[u32](BLOCK_BYTES)),
        node_bytes = cast[u32le](cast[u32](NODE_BYTES)), ring_blocks = cast[u32le](cast[u32](RING_BLOCKS)), container = id,
        block_count = cast[u64le](device.block_count), ring_first = cast[u64le](1)}
    copy_text(superblock.magic, SUPERBLOCK_MAGIC)
    seal_record(view_of(cast[ptr[mut u8]](&superblock), size_of(Superblock)), &superblock.seal)
    block :: make(BlockBuffer)?
    defer runtime.free(block)
    copy_bytes(block.bytes, 0, view_of(cast[ptr[mut u8]](&superblock), size_of(Superblock)))
    if !device.write(device.context, 0, 1, block.bytes) || !device.write(device.context, last_block(device), 1, block.bytes) {
        return .Error(.DeviceError)
    }
    return commit(container)
}

/** The bytes in a block, as an integer for an array's size: BLOCK_BYTES. */
BLOCK_SIZE :: 4096

/** A block's bytes, in memory of their own, from make, so a block isn't on the stack. */
BlockBuffer :: struct {
    /** The block's bytes. */
    bytes : u8[BLOCK_SIZE],
}

/**
 * Copy text's bytes into a buffer, as much as fits.
 *
 * @param into The buffer, from its start; its bytes past the text are left as they were.
 * @param text The text, copied byte for byte, not terminated.
 */
copy_text :: fn(into: mut u8[], text: string) {
    for character, i in text {
        if i < into.count {
            into[i] = cast[u8](character)
        }
    }
}

/**
 * Tell whether bytes start with text.
 *
 * @param bytes The bytes, as a magic field holds them.
 * @param text The text the bytes should start with, as a magic is.
 * @return True if the bytes start with all of text's; false if they differ or are too few.
 */
has_text :: fn(bytes: u8[], text: string) -> bool {
    for character, i in text {
        if i >= bytes.count || bytes[i] != cast[u8](character) {
            return false
        }
    }
    return true
}

/**
 * Get a checkpoint's size, for those who write one into a block themselves, as the fuzzer does.
 *
 * @return The bytes of a Checkpoint, 344.
 */
size_of_checkpoint :: fn() -> usize {
    return size_of(Checkpoint)
}

/**
 * Compute a record's seal: BLAKE3-256 of its bytes before the seal, which is its last 32.
 *
 * @param record The record's bytes, its seal last; fewer than 32 seals nothing.
 * @param seal Where the seal goes, as a rule the record's own last 32 bytes.
 */
seal_record :: fn(record: u8[], seal: ptr[mut Seal]) {
    if record.count < 32 {
        return void
    }
    crypto.blake3(record[0..<record.count - 32], seal^)
}

/**
 * Tell whether a record's seal holds.
 *
 * @param record The record's bytes, its seal last, at least 32 of them.
 * @param seal The seal it says it has.
 * @return True if the seal is BLAKE3-256 of the bytes before the record's last 32.
 */
record_sealed :: fn(record: u8[], seal: ptr[Seal]) -> bool {
    found : Seal
    seal_record(record, &found)
    return found == seal^
}

/**
 * Mount the container on a device: its superblock, the first's or else the last's, and the newest checkpoint in its
 * ring that checks out.
 *
 * Nothing is written. A superblock checks out with its magic, version, seal and block count the device's; a
 * checkpoint with its magic, version, seal and the superblock's container ID. The space in memory is loaded from the
 * space map, the pending extents of the last commit free now that it's durable, and the snapshots' and clones'
 * floors from the volumes.
 *
 * @param device The device, which the container keeps; its context has to outlive the container.
 * @return The container, from make, the caller's to free with unmount, making the transaction after its checkpoint's.
 * @error NotSlopfs The device has fewer than MIN_BLOCKS blocks, neither superblock checks out, or no checkpoint does.
 * @error OutOfMemory No memory for the container, a node or a buffer.
 * @error Corrupt The space map or the volumes tree doesn't check out.
 */
mount :: fn(device #escaping : Device) -> Result[ptr[mut Container], Error] {
    if device.block_count < MIN_BLOCKS {
        return .Error(.NotSlopfs)
    }
    block :: make(BlockBuffer)?
    defer runtime.free(block)
    superblock := Superblock.{}
    found_superblock := false
    for at in u64.[0, last_block(device)] {
        if found_superblock || !device.read(device.context, at, 1, block.bytes) {
            continue
        }
        candidate :: cast[ptr[Superblock]](&block.bytes[0])
        if has_text(candidate.magic, SUPERBLOCK_MAGIC) && cast[u32](candidate.version) == FORMAT_VERSION
            && record_sealed(view_of(&block.bytes[0], size_of(Superblock)), &candidate.seal)
            && cast[u64](candidate.block_count) == device.block_count {
            superblock = candidate^
            found_superblock = true
        }
    }
    if !found_superblock {
        return .Error(.NotSlopfs)
    }
    checkpoint := Checkpoint.{}
    found_checkpoint := false
    for slot in 0..<RING_BLOCKS {
        if !device.read(device.context, 1 + slot, 1, block.bytes) {
            continue
        }
        candidate :: cast[ptr[Checkpoint]](&block.bytes[0])
        if has_text(candidate.magic, CHECKPOINT_MAGIC) && cast[u32](candidate.version) == FORMAT_VERSION
            && candidate.container == superblock.container
            && record_sealed(view_of(&block.bytes[0], size_of(Checkpoint)), &candidate.seal)
            && (!found_checkpoint || cast[u64](candidate.transaction) > cast[u64](checkpoint.transaction)) {
            checkpoint = candidate^
            found_checkpoint = true
        }
    }
    if !found_checkpoint {
        return .Error(.NotSlopfs)
    }
    container :: new_container(device, cast[u64](checkpoint.transaction))?
    container.id = superblock.container
    container.space_map.root = checkpoint.space_map
    container.owners.root = checkpoint.owners
    container.volumes.root = checkpoint.volumes
    container.next_volume = cast[u64](checkpoint.next_volume)
    match load_free(container) {
        case Ok => {}
        case Error(error) => {
            unmount(container)
            return .Error(error)
        }
    }
    match load_floors(container) {
        case Ok => {}
        case Error(error) => {
            unmount(container)
            return .Error(error)
        }
    }
    return .Ok(container)
}

/**
 * Load the free list from the space map: its free extents, and those its checkpoint freed, which are free now it's
 * durable.
 *
 * @param container The container, just mounted, its free list empty.
 * @error Corrupt A record's value isn't a SpaceValue, or its extent is empty or outside the data blocks.
 * @error OutOfMemory No memory for a node.
 */
load_free :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    value : u8[16]
    at := Key.{}
    loop {
        found :: tree_next(&container.nodes, &container.space_map, at, value)? or_return .Ok
        extent :: cast[ptr[SpaceValue]](&value[0])
        start :: if found.key.kind == cast[u8](RecordKind.Pending) { found.key.offset } else { found.key.object }
        blocks :: cast[u64](extent.blocks)
        if found.bytes != size_of(SpaceValue) || blocks == 0 || start < FIRST_DATA || start + blocks > last_block(container.device) {
            return .Error(.Corrupt)
        }
        add_free(&container.space, start, blocks)
        at = key_after(found.key) or_return .Ok
    }
}

/**
 * Free a container's memory, its open volumes' with it.
 *
 * Nothing is written: what wasn't committed is lost, and the disk is as the last commit left it.
 *
 * @param container The container, from mount, format's own or new_container; it, and every Volume open on it, may
 *     not be used again.
 */
unmount :: fn(container: ptr[mut Container]) {
    for volume in container.open {
        free_volume(volume)
    }
    runtime.array_free(&container.open)
    for i in 0..<container.nodes.dirty.used.count {
        if i < container.nodes.dirty.used.count && i < container.nodes.dirty.values.count && container.nodes.dirty.used[i] {
            runtime.free(container.nodes.dirty.values[i])
        }
    }
    maps.map_free(&container.nodes.dirty)
    space_free(&container.space)
    runtime.free(container)
}

// The space map's records for an extent: free ones, keyed by their start, and pending ones, after (0, Pending).

/**
 * Put a free extent's record in the space map as it is, not joined to others.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param start The extent's first block.
 * @param blocks Its length in blocks, at least 1.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
space_map_put_free :: fn(container: ptr[mut Container], start: u64, blocks: u64) -> Result[void, Error] {
    value := SpaceValue.{blocks = cast[u64le](blocks)}
    tree_put(&container.nodes, &container.space_map, key_of(start, .Free, 0), view_of(cast[ptr[mut u8]](&value), size_of(SpaceValue)))?
    return .Ok
}

/**
 * Put a free extent in the space map, joined to the free ones it touches.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param start The extent's first block.
 * @param blocks Its length in blocks, at least 1; it shouldn't overlap a free extent.
 * @error OutOfMemory No memory for a node.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
space_map_free :: fn(container: ptr[mut Container], start: u64, blocks: u64) -> Result[void, Error] {
    value : u8[16]
    first := start
    count := blocks
    previous :: tree_previous(&container.nodes, &container.space_map, key_of(start, .Free, 0), value)?
    match previous {
        case Some(before) => {
            extent :: cast[ptr[SpaceValue]](&value[0])
            if before.key.kind == cast[u8](RecordKind.Free) && before.key.object + cast[u64](extent.blocks) == start {
                first = before.key.object
                count += cast[u64](extent.blocks)
                tree_delete(&container.nodes, &container.space_map, before.key)?
            }
        }
        case None => {}
    }
    after_key :: key_of(start + blocks, .Free, 0)
    next :: tree_get(&container.nodes, &container.space_map, after_key, value)?
    match next {
        case Some(bytes) => {
            extent :: cast[ptr[SpaceValue]](&value[0])
            count += cast[u64](extent.blocks)
            tree_delete(&container.nodes, &container.space_map, after_key)?
        }
        case None => {}
    }
    return space_map_put_free(container, first, count)
}

/**
 * Take an allocated extent out of the free extent in the space map that holds it, leaving what's before and after it
 * free.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param start The extent's first block.
 * @param blocks Its length in blocks.
 * @error Corrupt No free extent in the space map holds it all.
 * @error OutOfMemory No memory for a node.
 */
space_map_take :: fn(container: ptr[mut Container], start: u64, blocks: u64) -> Result[void, Error] {
    value : u8[16]
    found :: tree_previous(&container.nodes, &container.space_map, key_of(start, .Free, 0), value)? or_return .Error(.Corrupt)
    extent :: cast[ptr[SpaceValue]](&value[0])
    first :: found.key.object
    count :: cast[u64](extent.blocks)
    if found.key.kind != cast[u8](RecordKind.Free) || first > start || start + blocks > first + count {
        return .Error(.Corrupt)
    }
    // What's left after it put first, so the tree isn't emptied on the way
    if start + blocks < first + count {
        space_map_put_free(container, start + blocks, first + count - start - blocks)?
    }
    if start > first {
        space_map_put_free(container, first, start - first)?
    }
    else {
        tree_delete(&container.nodes, &container.space_map, found.key)?
    }
    return .Ok
}

/**
 * Make the pending extents of the last commit, durable now, free in the space map.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @error OutOfMemory No memory to list them, or for a node; none was settled if it's the list.
 * @error Corrupt A node couldn't be read or didn't check out.
 */
space_map_settle :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    pending : Extent[..]
    defer runtime.array_free(&pending)
    value : u8[16]
    at := key_of(0, .Pending, 0)
    loop {
        found :: tree_next(&container.nodes, &container.space_map, at, value)? or_break
        if found.key.object != 0 || found.key.kind != cast[u8](RecordKind.Pending) {
            break
        }
        extent :: cast[ptr[SpaceValue]](&value[0])
        if runtime.array_try_add(&pending, Extent.{start = found.key.offset, blocks = cast[u64](extent.blocks)}) != null {
            return .Error(.OutOfMemory)
        }
        at = key_after(found.key) or_break
    }
    for extent in pending {
        tree_delete(&container.nodes, &container.space_map, key_of(0, .Pending, extent.start))?
        space_map_free(container, extent.start, extent.blocks)?
    }
    return .Ok
}

/**
 * Make one change to the space in the space map and the owners, or for a Dead extent, the volumes tree.
 *
 * Allocated takes the extent out of the free ones and records its owner; FreedNow frees it at once; FreedLater
 * makes it pending, freed in this transaction; Dead puts it on its owner's dead list.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param change The change, as the space recorded it; its owner says whose dead list a Dead one goes on.
 * @error Corrupt An allocation isn't in a free extent, or a node couldn't be read or didn't check out.
 * @error OutOfMemory No memory for a node.
 */
apply_change :: fn(container: ptr[mut Container], change: Change) -> Result[void, Error] {
    match change.change {
        case .Allocated => {
            space_map_take(container, change.start, change.blocks)?
            owner := OwnerValue.{blocks = cast[u64le](change.blocks), volume = cast[u64le](change.owner), birth = cast[u64le](change.birth)}
            tree_put(&container.nodes, &container.owners, key_of(change.start, .Owner, 0),
                view_of(cast[ptr[mut u8]](&owner), size_of(OwnerValue)))?
        }
        case .FreedNow => {
            space_map_free(container, change.start, change.blocks)?
            tree_delete(&container.nodes, &container.owners, key_of(change.start, .Owner, 0))?
        }
        case .FreedLater => {
            value := SpaceValue.{blocks = cast[u64le](change.blocks), transaction = cast[u64le](container.nodes.transaction)}
            tree_put(&container.nodes, &container.space_map, key_of(0, .Pending, change.start),
                view_of(cast[ptr[mut u8]](&value), size_of(SpaceValue)))?
            tree_delete(&container.nodes, &container.owners, key_of(change.start, .Owner, 0))?
        }
        case .Dead => {
            dead := DeadValue.{blocks = cast[u64le](change.blocks), birth = cast[u64le](change.birth),
                freed = cast[u64le](container.nodes.transaction)}
            tree_put(&container.nodes, &container.volumes, key_of(change.owner, .Dead, change.start),
                view_of(cast[ptr[mut u8]](&dead), size_of(DeadValue)))?
        }
    }
    return .Ok
}

/**
 * Make everything changed since the last commit durable (design/storage.md §3, §4).
 *
 * Each open volume's tree is written and its record updated; the space map and owners are brought up to date with
 * every allocation and free, including their own, until changing them changes nothing more; their nodes are written;
 * a flush; the checkpoint; a flush. A crash before the checkpoint is written leaves the last commit's state; after
 * the second flush, this one's. Extents freed in this commit become free once it's done.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @error Failed A write failed since the container was mounted, here or before, or an open volume failed; nothing is
 *     committed, now or later, until it's mounted again.
 * @error DeviceError A write or a flush failed; the container is failed from now on.
 * @error OutOfMemory No memory for a node or a list; nothing is durable, and the commit may be tried again.
 * @error Corrupt A node couldn't be read or didn't check out, an allocation wasn't in a free extent, or the space
 *     map and owners went round more than MAX_ROUNDS times.
 */
commit :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    if container.failed {
        return .Error(.Failed)
    }
    for volume in container.open {
        if volume.failed {
            container.failed = true
            return .Error(.Failed)
        }
    }
    return failing(container, commit_all(container))
}

/**
 * Make the container's own changes durable, every volume's left waiting for its own commit: a snapshot taken or
 * deleted, or a clone made, at once (snapshot.hsc).
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @error Failed A write failed since the container was mounted.
 * @error DeviceError A write or a flush failed; the container is failed from now on.
 * @error OutOfMemory No memory for a node or a list.
 * @error Corrupt A node couldn't be read or didn't check out, or the space map and owners went round more than
 *     MAX_ROUNDS times.
 */
commit_own :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    if container.failed {
        return .Error(.Failed)
    }
    return failing(container, commit_changes(container, 0))
}

/**
 * Pass a commit's result on, a device error marking the container failed so every later commit is refused.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param result The commit's result.
 * @return The result as it was given, unchanged.
 */
failing :: fn(container: ptr[mut Container], result: Result[void, Error]) -> Result[void, Error] {
    match result {
        case Ok => return .Ok
        case Error(error) => {
            if error == .DeviceError {
                container.failed = true
            }
            return .Error(error)
        }
    }
}

/**
 * Commit every owner's changes: each dirty open volume's tree written and its record put, then commit_changes.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @error DeviceError A write or a flush failed.
 * @error OutOfMemory No memory for a node or a list.
 * @error Corrupt A node didn't check out, or the rounds didn't settle.
 */
commit_all :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    for volume in container.open {
        if volume.dirty {
            record :: write_volume(volume)?
            put_volume_record(container, volume.id, &record)?
        }
    }
    return commit_changes(container, ALL_OWNERS)
}

/**
 * Commit one volume, as its volume server does (decisions/0089): its record put in the volumes tree, and its changes
 * and the container's own made durable, other volumes' left waiting for their own commits.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume's ID.
 * @param record The volume's record, its tree already written, through block connections whose writes have all
 *     finished.
 * @return The transaction committed, durable once this returns.
 * @error Failed A write failed since the container was mounted.
 * @error DeviceError A write or a flush failed; the container is failed from now on.
 * @error OutOfMemory No memory for a node or a list.
 * @error Corrupt A node didn't check out, or the rounds didn't settle.
 */
commit_volume :: fn(container: ptr[mut Container], id: u64, record: ptr[VolumeRecord]) -> Result[u64, Error] {
    if container.failed {
        return .Error(.Failed)
    }
    committed :: container.nodes.transaction
    match put_volume_record(container, id, record) {
        case Ok => {}
        case Error(error) => return .Error(error)
    }
    failing(container, commit_changes(container, id))?
    return .Ok(committed)
}

/**
 * Bring the space map and owners up to date with one owner's changes and the container's own, write the container's
 * trees, and write the checkpoint between two flushes.
 *
 * Once it's done, what the changes freed is free and the next transaction starts.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param only The volume whose changes are taken, besides the container's own; 0 for the container's alone,
 *     ALL_OWNERS for every owner's.
 * @error OutOfMemory No memory for a node or a list.
 * @error DeviceError A write or a flush failed.
 * @error Corrupt A node couldn't be read or didn't check out, an allocation wasn't in a free extent, or the space
 *     map and owners went round more than MAX_ROUNDS times.
 */
commit_changes :: fn(container: ptr[mut Container], only: u64) -> Result[void, Error] {
    space_map_settle(container)?
    // Each round takes the changes so far that this commit takes, and taking them may make more
    changes : Change[..]
    waiting : Change[..]
    defer runtime.array_free(&changes)
    defer runtime.array_free(&waiting)
    round := 0
    loop {
        runtime.array_reset(&changes)
        runtime.array_reset(&waiting)
        // Room for every change in both, so sorting them can't stop halfway
        count :: container.space.changes.count
        if runtime.array_try_reserve(&changes, count) != null || runtime.array_try_reserve(&waiting, count) != null {
            return .Error(.OutOfMemory)
        }
        for change in container.space.changes {
            if takes(only, change.owner) {
                runtime.array_add(&changes, change)
            }
            else {
                runtime.array_add(&waiting, change)
            }
        }
        runtime.array_reset(&container.space.changes)
        runtime.array_copy(waiting, &container.space.changes)
        for change in changes {
            apply_change(container, change)?
        }
        round += 1
        if round > MAX_ROUNDS {
            return .Error(.Corrupt)
        }
    }
    while changes_taken(container, only)
    tree_write(&container.nodes, &container.space_map)?
    tree_write(&container.nodes, &container.owners)?
    tree_write(&container.nodes, &container.volumes)?
    if !container.device.flush(container.device.context) {
        return .Error(.DeviceError)
    }
    write_checkpoint(container)?
    if !container.device.flush(container.device.context) {
        return .Error(.DeviceError)
    }
    space_committed(&container.space, only)
    container.nodes.transaction += 1
    return .Ok
}

/**
 * Undo a volume's waiting changes in the space, as if it had made none since its last commit (forget, on its side):
 * its allocations free again, and the extents it gave back still its own.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param id The volume's ID.
 * @param undone Where the changes undone are added, for whoever keeps who owns what; the caller's to free.
 * @return True if they were undone; false, with nothing changed, if there wasn't the memory to.
 */
abandon_volume :: fn(container: ptr[mut Container], id: u64, undone: ptr[mut Change[..]]) -> bool {
    kept : Change[..]
    space :: &container.space
    // Room for every change in what's kept and what's undone, and for the free extents they make, before any's undone
    count :: space.changes.count
    if runtime.array_try_reserve(&kept, count) != null || runtime.array_try_reserve(undone, undone.count + count) != null
        || !space_room(space, 0, 0, count, 0) {
        runtime.array_free(&kept)
        return false
    }
    for change in space.changes {
        if change.owner != id {
            runtime.array_add(&kept, change)
            continue
        }
        if change.change == .Allocated {
            add_free(space, change.start, change.blocks)
            charge(space, id, change.blocks, false)
        }
        else if change.change == .Dead {}
        else if change.change == .FreedLater {
            charge(space, id, change.blocks, true)
            for later, i in space.later {
                if later.start == change.start && later.blocks == change.blocks && later.owner == id {
                    runtime.array_remove(&space.later, i)
                    break
                }
            }
        }
        runtime.array_add(undone, change)
    }
    runtime.array_free(&space.changes)
    space.changes = kept
    return true
}

/**
 * Tell whether changes a commit takes are still waiting, so it goes round again.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param only The owner the commit takes the changes of, as commit_changes has it.
 * @return True if any waiting change is one the commit takes.
 */
changes_taken :: fn(container: ptr[Container], only: u64) -> bool {
    for change in container.space.changes {
        if takes(only, change.owner) {
            return true
        }
    }
    return false
}

/**
 * Write the checkpoint for the transaction being made into its ring block, 1 + transaction % RING_BLOCKS.
 *
 * It isn't flushed here: commit_changes flushes before and after it.
 *
 * @param container The container, its trees' roots written.
 * @error OutOfMemory No memory for the block.
 * @error DeviceError The block couldn't be written.
 */
write_checkpoint :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    transaction :: container.nodes.transaction
    checkpoint := Checkpoint.{version = cast[u32le](FORMAT_VERSION), transaction = cast[u64le](transaction), container = container.id,
        space_map = container.space_map.root, owners = container.owners.root, volumes = container.volumes.root,
        free_blocks = cast[u64le](container.space.free_blocks), next_volume = cast[u64le](container.next_volume)}
    copy_text(checkpoint.magic, CHECKPOINT_MAGIC)
    seal_record(view_of(cast[ptr[mut u8]](&checkpoint), size_of(Checkpoint)), &checkpoint.seal)
    block :: make(BlockBuffer)?
    defer runtime.free(block)
    for i in 0..<block.bytes.count {
        block.bytes[i] = 0
    }
    copy_bytes(block.bytes, 0, view_of(cast[ptr[mut u8]](&checkpoint), size_of(Checkpoint)))
    if !container.device.write(container.device.context, 1 + transaction % RING_BLOCKS, 1, block.bytes) {
        return .Error(.DeviceError)
    }
    return .Ok
}

/**
 * Get the transaction the container's last commit made durable.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @return The transaction, one before the one being made; 0 before the first commit.
 */
durable_transaction :: fn(container: ptr[Container]) -> u64 {
    return container.nodes.transaction - 1
}

/**
 * Get how many blocks are free now, in memory.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @return The free blocks, of BLOCK_BYTES each: those in the free list now, including those freed at once in this
 *     transaction, but not those that will be free once it's committed.
 */
free_blocks :: fn(container: ptr[Container]) -> u64 {
    return container.space.free_blocks
}
