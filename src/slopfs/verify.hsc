package slopfs

import runtime from "base"
import maps from "std"

/*
 * A container checked whole, as fsck checks a filesystem: every node of every tree read and checked, every extent a
 * node or a file's chunk takes collected, and those, with the free ones, found to cover the data blocks exactly once
 * each, and to be what the owners tree says, owner and all. An encrypted volume that isn't open can't be read
 * without its keys, so its extents are taken from the owners tree as they are. Snapshots' trees are walked too, and
 * what a snapshot or a clone shares with its volume or origin is counted once. The crash-state tester and the fuzzer
 * check each image they mount with it.
 */

/** What's wrong with a container, as verify finds it. */
Problem :: enum {
    /** A node or a record couldn't be read, or didn't check out. */
    Unreadable,
    /** Two extents in use overlap, or one in use is also free. */
    Overlap,
    /** Blocks neither in use nor free. */
    Leak,
    /** An extent in use, or a free one, outside the data blocks. */
    OutOfRange,
    /** The owners tree doesn't say what's in use, or by whom. */
    Owners,
    /** No memory to keep what the walk found (decisions/0104), so nothing's known either way. */
    OutOfMemory,
}

/** What a check found, in a container that checks out. */
Report :: struct {
    /** The nodes walked, each counted once however many trees share it. */
    nodes : u64,
    /** The files' chunks in blocks walked, each counted once. */
    chunks : u64,
    /** The blocks in use: nodes, their second copies, chunks, and locked volumes' extents. */
    used_blocks : u64,
    /** The blocks free, as the space in memory has them. */
    free_blocks : u64,
    /** The volumes in the container, clones included. */
    volumes : u64,
    /** Encrypted volumes that weren't open, whose trees weren't read; their extents are taken from the owners tree. */
    locked : u64,
}

/** An extent in use, and its owner. */
Used :: struct {
    /** Its first block. */
    start : u64,
    /** Its length in blocks. */
    blocks : u64,
    /** The volume whose it is, or 0, the container. */
    owner : u64,
}

/** A check's walk: what it's found so far. */
Walk :: struct {
    /** The extents in use found, in the order found, from context's allocator. */
    used : Used[..],
    /** What's counted so far. */
    report : Report,
    /** Every node and chunk found so far, by its first block, since snapshots and clones share them. */
    seen : maps.HashMap[u64, bool, maps.hash_integer[u64]],
    /** Out of memory: the walk stopped short, and what it found says nothing. */
    short : bool,
}

/**
 * Say why a walk stopped.
 *
 * @param walk The walk that stopped.
 * @return OutOfMemory if it ran out of memory; Unreadable for anything else, what it couldn't read.
 */
stopped :: fn(walk: ptr[Walk]) -> Problem {
    return if walk.short { Problem.OutOfMemory } else { Problem.Unreadable }
}

/**
 * Keep an extent in use.
 *
 * @param walk The walk, its used list added to.
 * @param used The extent in use, with its owner.
 * @return True if it was kept; false, the walk marked short, without the memory for it.
 */
add_used :: fn(walk: ptr[mut Walk], used: Used) -> bool {
    if runtime.array_try_add(&walk.used, used) != null {
        walk.short = true
        return false
    }
    return true
}

/**
 * Check a container whole, as fsck checks a filesystem.
 *
 * Every node of every tree, each volume's as it is in memory where it's open and from its record where it isn't,
 * and every snapshot's, is read and checked. The extents they and their chunks take, with the free ones, have to
 * cover the data blocks exactly once each, and be what the owners tree says. Nothing is written. It's for a
 * container with nothing waiting to commit, as one just mounted or just committed is: changes the space map and
 * owners haven't taken yet look like problems.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @return What it found, if the container checks out.
 * @error Unreadable A node or a record couldn't be read, or didn't check out.
 * @error Overlap Two extents in use overlap, or one in use is also free.
 * @error Leak Blocks are neither in use nor free.
 * @error OutOfRange An extent in use starts before the data blocks, or the free and used ones run past the last.
 * @error Owners The owners tree doesn't list exactly the extents in use, with their lengths and owners.
 * @error OutOfMemory There wasn't the memory to keep what the walk found.
 */
verify :: fn(container: ptr[mut Container]) -> Result[Report, Problem] {
    walk := Walk.{}
    defer runtime.array_free(&walk.used)
    defer maps.map_free(&walk.seen)
    if !walk_tree(container, &walk, &container.space_map) {
        return .Error(stopped(&walk))
    }
    if !walk_tree(container, &walk, &container.owners) {
        return .Error(stopped(&walk))
    }
    if !walk_tree(container, &walk, &container.volumes) {
        return .Error(stopped(&walk))
    }
    // Each volume's tree, from its record, or as it is in memory where it's open
    value : u8[224]
    at : u64 = 0
    loop {
        found := Found.{}
        match tree_next(&container.nodes, &container.volumes, key_of(at, .VolumeEntry, 0), value) {
            case Ok(next) => found = next or_break
            case Error(error) => return .Error(stopped(&walk))
        }
        if found.key.kind != cast[u8](RecordKind.VolumeEntry) || found.bytes != size_of(VolumeRecord) {
            return .Error(stopped(&walk))
        }
        record := cast[ptr[VolumeRecord]](&value[0])^
        id :: found.key.object
        tree := Tree.{root = record.root, kind = .Volume, owner = id}
        match lineage_of(container, &record) {
            case Ok(lineage) => tree.lineage = lineage
            case Error(error) => return .Error(stopped(&walk))
        }
        open := false
        for volume in container.open {
            if volume.id == id {
                tree = volume.tree
                open = true
            }
        }
        if !open && record.cipher != cast[u8](Cipher.None) {
            if !add_owned(container, &walk, id) {
                return .Error(stopped(&walk))
            }
            walk.report.locked += 1
        }
        else {
            if !walk_tree(container, &walk, &tree) {
                return .Error(stopped(&walk))
            }
            // Its snapshots, whose trees share what hasn't changed since
            snapshots : NumberedSnapshot[..]
            listed :: snapshot_records(container, id, &snapshots)
            walked := match listed {
                case Ok => true
                case Error(error) => false
            }
            for each in snapshots {
                pinned := tree
                pinned.root = each.record.root
                if walked && !walk_tree(container, &walk, &pinned) {
                    walked = false
                }
            }
            runtime.array_free(&snapshots)
            if !walked {
                return .Error(stopped(&walk))
            }
        }
        walk.report.volumes += 1
        if found.key.object == 0xffffffffffffffff {
            break
        }
        at = found.key.object + 1
    }
    // A walk that stopped short found less than there is, which would look like a leak
    if walk.short {
        return .Error(.OutOfMemory)
    }
    sort_used(walk.used)
    // In use, and free, each block once, from the first data block to the last
    next := FIRST_DATA
    free_index : usize = 0
    for extent in walk.used {
        loop {
            free :: extent_at(container.space.free, free_index)
            if free_index >= container.space.free.count || free.start >= extent.start {
                break
            }
            if free.start != next {
                return .Error(if free.start < next { .Overlap } else { .Leak })
            }
            next = free.start + free.blocks
            free_index += 1
        }
        if extent.start < next {
            return .Error(if extent.start < FIRST_DATA { .OutOfRange } else { .Overlap })
        }
        if extent.start > next {
            return .Error(.Leak)
        }
        next = extent.start + extent.blocks
        walk.report.used_blocks += extent.blocks
    }
    for i in free_index..<container.space.free.count {
        free :: extent_at(container.space.free, i)
        if free.start != next {
            return .Error(if free.start < next { .Overlap } else { .Leak })
        }
        next = free.start + free.blocks
    }
    if next != last_block(container.device) {
        return .Error(if next > last_block(container.device) { .OutOfRange } else { .Leak })
    }
    walk.report.free_blocks = container.space.free_blocks
    // The owners tree: one record for each extent in use, with its owner
    owner_value := OwnerValue.{}
    owner_at := Key.{}
    index : usize = 0
    loop {
        found := Found.{}
        match tree_next(&container.nodes, &container.owners, owner_at, view_of(cast[ptr[mut u8]](&owner_value), size_of(OwnerValue))) {
            case Ok(next_owner) => found = next_owner or_break
            case Error(error) => return .Error(stopped(&walk))
        }
        if index >= walk.used.count {
            return .Error(.Owners)
        }
        used :: walk.used[index]
        if found.key.object != used.start || cast[u64](owner_value.blocks) != used.blocks || cast[u64](owner_value.volume) != used.owner {
            return .Error(.Owners)
        }
        index += 1
        owner_at = key_after(found.key) or_break
    }
    if index != walk.used.count {
        return .Error(.Owners)
    }
    return .Ok(walk.report)
}

/**
 * Keep the extents the owners tree says are an owner's, as in use, those not found already.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param walk The walk, its used list and seen set added to.
 * @param owner The volume, a locked one whose tree can't be read.
 * @return True if they were kept; false if the owners tree couldn't be read, or there wasn't the memory.
 */
add_owned :: fn(container: ptr[mut Container], walk: ptr[mut Walk], owner: u64) -> bool {
    value := OwnerValue.{}
    at := Key.{}
    loop {
        found := Found.{}
        match tree_next(&container.nodes, &container.owners, at, view_of(cast[ptr[mut u8]](&value), size_of(OwnerValue))) {
            case Ok(next) => found = next or_break
            case Error(error) => return false
        }
        if cast[u64](value.volume) == owner && first_time(walk, found.key.object) {
            if !add_used(walk, Used.{start = found.key.object, blocks = cast[u64](value.blocks), owner = owner}) {
                return false
            }
        }
        at = key_after(found.key) or_break
    }
    return true
}

/**
 * Walk every node of a tree, and every chunk a volume's leaves name, keeping the extents in use.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param walk The walk, its counts, used list and seen set added to.
 * @param tree The tree; an empty one has nothing to walk.
 * @return True if it was walked; false if a node couldn't be read or didn't check out, or there wasn't the memory.
 */
walk_tree :: fn(container: ptr[mut Container], walk: ptr[mut Walk], tree: ptr[Tree]) -> bool {
    if cast[u64](tree.root.address) == 0 {
        return true
    }
    return walk_node(container, walk, tree, &tree.root, NO_PARENT)
}

/**
 * Tell whether the extent starting at a block is found for the first time, noting that it has been.
 *
 * @param walk The walk, its seen set added to.
 * @param start The extent's first block.
 * @return True the first time; false after, or without the memory to note it, which marks the walk short.
 */
first_time :: fn(walk: ptr[mut Walk], start: u64) -> bool {
    if maps.map_get(&walk.seen, start) is_some {
        return false
    }
    if maps.map_try_put(&walk.seen, start, true) != null {
        walk.short = true
        return false
    }
    return true
}

/**
 * Walk a node and what's beneath it, once: a node another tree shares is the same below, copy-on-write.
 *
 * @param container The container, mounted: what it reads includes its transaction's changes not yet committed.
 * @param walk The walk, its counts, used list and seen set added to.
 * @param tree The tree it's in.
 * @param pointer Its pointer, from its parent or the tree's root.
 * @param above Its parent's level, so its own has to be one less; NO_PARENT for a root.
 * @return True if it and everything beneath it was walked; false if a node couldn't be read or didn't check out, or
 *     there wasn't the memory.
 */
walk_node :: fn(container: ptr[mut Container], walk: ptr[mut Walk], tree: ptr[Tree], pointer: ptr[BlockPointer], above: u16) -> bool {
    // A node another tree has is the same below, copy-on-write: walked once
    if !first_time(walk, cast[u64](pointer.address)) {
        return true
    }
    node :: load(&container.nodes, tree, pointer) or_return false
    defer done(node)
    if !level_fits(node, above) {
        return false
    }
    walk.report.nodes += 1
    owner :: owner_at(tree, cast[u64](pointer.birth))
    if !add_used(walk, Used.{start = cast[u64](pointer.address), blocks = NODE_BLOCKS, owner = owner}) {
        return false
    }
    if cast[u64](pointer.copy) != 0 && !add_used(walk, Used.{start = cast[u64](pointer.copy), blocks = NODE_BLOCKS, owner = owner}) {
        return false
    }
    if level_of(node) > 0 {
        for i in 0..<count_of(node) {
            child :: entry_at(node, i).child
            if !walk_node(container, walk, tree, &child, level_of(node)) {
                return false
            }
        }
        return true
    }
    if tree.kind != .Volume {
        return true
    }
    for i in 0..<count_of(node) {
        key :: item_key(node, i)
        value :: value_of(node, i)
        if key.kind != cast[u8](RecordKind.Extent) || value.count < size_of(ExtentRecord) || value.count == 0 {
            continue
        }
        extent :: cast[ptr[ExtentRecord]](&value[0])
        if cast[u32](extent.kind) == cast[u32](ExtentKind.Blocks) && first_time(walk, cast[u64](extent.pointer.address)) {
            walk.report.chunks += 1
            if !add_used(walk, Used.{start = cast[u64](extent.pointer.address), blocks = cast[u64](cast[u32](extent.pointer.blocks)),
                owner = owner_at(tree, cast[u64](extent.pointer.birth))}) {
                return false
            }
        }
    }
    return true
}

/**
 * Sort extents in use by their start: a shell sort, as there are a few thousand at most in a test.
 *
 * @param used The extents, sorted in place.
 */
sort_used :: fn(used: mut Used[]) {
    gap := used.count / 2
    loop {
        for i in gap..<used.count {
            moving :: used[i]
            j := i
            loop {
                k :: j - gap
                if k >= used.count || used[k].start <= moving.start {
                    break
                }
                if j < used.count {
                    used[j] = used[k]
                }
                j = k
            }
            while j >= gap
            if j < used.count {
                used[j] = moving
            }
        }
        gap = gap / 2
    }
    while gap > 0
}
