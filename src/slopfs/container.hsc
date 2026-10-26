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

// The most times a commit goes round bringing the space map and owners up to date with what changing them changed.
MAX_ROUNDS :: 64

Container :: struct {
    device : Device,
    id : u8[16],
    nodes : Nodes,
    space : Space,
    space_map : Tree,
    owners : Tree,
    volumes : Tree,
    next_volume : u64,
    failed : bool,
    // Volumes open on it, which commit writes
    open : ptr[mut Volume][..],
}

// The last block, where the second superblock is.
last_block :: fn(device: Device) -> u64 {
    return device.block_count - 1
}

// A container in memory, before anything is read or written: no trees, and the transaction after `transaction`.
new_container :: fn(device #escaping : Device, transaction: u64) -> ptr[mut Container] {
    container := runtime.new(Container)
    container^ = Container.{device = device}
    container.space.transaction = transaction + 1
    container.nodes = Nodes.{device = device, transaction = transaction + 1, space = cast[rawptr](&container.space),
        allocate = space_allocate, release = space_release}
    container.space_map = Tree.{kind = .SpaceMap, ditto = true}
    container.owners = Tree.{kind = .Owners, ditto = true}
    container.volumes = Tree.{kind = .Volumes, ditto = true}
    container.next_volume = 1
    return container
}

/*
 * A new container on the whole device, named id: its superblocks, and a first checkpoint whose space map frees
 * everything but itself.
 */
format :: fn(device #escaping : Device, id: u8[16]) -> Result[void, Error] {
    if device.block_count < MIN_BLOCKS {
        return .Error(.NoSpace)
    }
    container :: new_container(device, 0)
    defer unmount(container)
    container.id = id
    add_free(&container.space, FIRST_DATA, last_block(device) - FIRST_DATA)
    space_map_put_free(container, FIRST_DATA, last_block(device) - FIRST_DATA)?
    superblock := Superblock.{version = cast[u32le](FORMAT_VERSION), block_bytes = cast[u32le](cast[u32](BLOCK_BYTES)),
        node_bytes = cast[u32le](cast[u32](NODE_BYTES)), ring_blocks = cast[u32le](cast[u32](RING_BLOCKS)), container = id,
        block_count = cast[u64le](device.block_count), ring_first = cast[u64le](1)}
    copy_text(superblock.magic, SUPERBLOCK_MAGIC)
    seal_record(view_of(cast[ptr[mut u8]](&superblock), size_of(Superblock)), &superblock.seal)
    block := runtime.new(BlockBuffer)
    defer runtime.free(block)
    copy_bytes(block.bytes, 0, view_of(cast[ptr[mut u8]](&superblock), size_of(Superblock)))
    if !device.write(device.context, 0, 1, block.bytes) || !device.write(device.context, last_block(device), 1, block.bytes) {
        return .Error(.DeviceError)
    }
    return commit(container)
}

BLOCK_SIZE :: 4096

// A block's bytes, in memory of their own.
BlockBuffer :: struct {
    bytes : u8[BLOCK_SIZE],
}

copy_text :: fn(into: mut u8[], text: string) {
    for character, i in text {
        if i < into.count {
            into[i] = cast[u8](character)
        }
    }
}

has_text :: fn(bytes: u8[], text: string) -> bool {
    for character, i in text {
        if i >= bytes.count || bytes[i] != cast[u8](character) {
            return false
        }
    }
    return true
}

// A checkpoint's bytes, for those who write one into a block themselves, as the fuzzer does.
size_of_checkpoint :: fn() -> usize {
    return size_of(Checkpoint)
}

// A record's seal: BLAKE3-256 of its bytes before the seal, which is its last 32.
seal_record :: fn(record: u8[], seal: ptr[mut Seal]) {
    if record.count < 32 {
        return void
    }
    crypto.blake3(record[0..<record.count - 32], seal^)
}

record_sealed :: fn(record: u8[], seal: ptr[Seal]) -> bool {
    found : Seal
    seal_record(record, &found)
    return found == seal^
}

/*
 * The container on device: its superblock, the first's or else the last's, and the newest checkpoint in its ring
 * that checks out. NotSlopfs if there's neither.
 */
mount :: fn(device #escaping : Device) -> Result[ptr[mut Container], Error] {
    if device.block_count < MIN_BLOCKS {
        return .Error(.NotSlopfs)
    }
    block := runtime.new(BlockBuffer)
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
    container :: new_container(device, cast[u64](checkpoint.transaction))
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
    return .Ok(container)
}

/*
 * The free list from the space map: its free extents, and those its checkpoint freed, which are free now it's durable.
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

// A container's memory given back, its open volumes with it. What wasn't committed is lost.
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

space_map_put_free :: fn(container: ptr[mut Container], start: u64, blocks: u64) -> Result[void, Error] {
    value := SpaceValue.{blocks = cast[u64le](blocks)}
    tree_put(&container.nodes, &container.space_map, key_of(start, .Free, 0), view_of(cast[ptr[mut u8]](&value), size_of(SpaceValue)))?
    return .Ok
}

// A free extent in the space map, joined to the free ones it touches.
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

// An allocated extent taken out of the free extent in the space map that holds it.
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

// The pending extents of the last commit, durable now, made free in the space map.
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
        runtime.array_add(&pending, Extent.{start = found.key.offset, blocks = cast[u64](extent.blocks)})
        at = key_after(found.key) or_break
    }
    for extent in pending {
        tree_delete(&container.nodes, &container.space_map, key_of(0, .Pending, extent.start))?
        space_map_free(container, extent.start, extent.blocks)?
    }
    return .Ok
}

// One change to the space, taken by the space map and the owners.
apply_change :: fn(container: ptr[mut Container], change: Change) -> Result[void, Error] {
    match change.change {
        case .Allocated => {
            space_map_take(container, change.start, change.blocks)?
            owner := OwnerValue.{blocks = cast[u64le](change.blocks), volume = cast[u64le](change.owner)}
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
    }
    return .Ok
}

/*
 * Everything changed since the last commit made durable (design/storage.md §3, §4): each open volume's tree written
 * and its record updated; the space map and owners brought up to date with every allocation and free, including
 * their own, until changing them changes nothing more; their nodes written; a flush; the checkpoint; a flush.
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

// A commit's result, a device error stopping every later one.
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

commit_all :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    for volume in container.open {
        if volume.dirty {
            record :: write_volume(volume)?
            put_volume_record(container, volume.id, &record)?
        }
    }
    return commit_changes(container, ALL_OWNERS)
}

/*
 * A volume server's commit (decisions/0089): its tree already written, through block connections whose writes have all
 * finished; its record put in the volumes tree, and its changes and the container's own made durable, other volumes'
 * left waiting for their own commits. The transaction committed.
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

// The space map and owners brought up to date with only's changes and the container's own, and the checkpoint written.
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

// Whether changes this commit takes are still waiting.
changes_taken :: fn(container: ptr[Container], only: u64) -> bool {
    for change in container.space.changes {
        if takes(only, change.owner) {
            return true
        }
    }
    return false
}

write_checkpoint :: fn(container: ptr[mut Container]) -> Result[void, Error] {
    transaction :: container.nodes.transaction
    checkpoint := Checkpoint.{version = cast[u32le](FORMAT_VERSION), transaction = cast[u64le](transaction), container = container.id,
        space_map = container.space_map.root, owners = container.owners.root, volumes = container.volumes.root,
        free_blocks = cast[u64le](container.space.free_blocks), next_volume = cast[u64le](container.next_volume)}
    copy_text(checkpoint.magic, CHECKPOINT_MAGIC)
    seal_record(view_of(cast[ptr[mut u8]](&checkpoint), size_of(Checkpoint)), &checkpoint.seal)
    block := runtime.new(BlockBuffer)
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

// The transaction the container's last commit made durable.
durable_transaction :: fn(container: ptr[Container]) -> u64 {
    return container.nodes.transaction - 1
}

// The blocks free now, and those that will be once this transaction is committed.
free_blocks :: fn(container: ptr[Container]) -> u64 {
    return container.space.free_blocks
}
