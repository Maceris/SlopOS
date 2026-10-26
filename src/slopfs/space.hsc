package slopfs

import runtime from "base"

/*
 * The container's space in memory: the free extents, loaded from the space map at mount and kept as the transaction
 * allocates and frees, and the changes its trees still have to take. An extent born in this transaction and freed in
 * it is free at once, since no durable checkpoint names it; one born before is free only once this transaction's
 * checkpoint is durable, since the last one still names it (design/storage.md §3). One a snapshot holds isn't free at
 * all: it goes on its volume's dead list until no snapshot holds it, and one a clone shares with its origin is the
 * origin's, which a clone giving it back doesn't touch (snapshot.hsc).
 */

Extent :: struct {
    start : u64,
    blocks : u64,
}

SpaceChange :: enum {
    Allocated,
    // Freed, born in this transaction
    FreedNow,
    // Freed, born before it: pending until its checkpoint is durable
    FreedLater,
    // Given back, but a snapshot of its owner's holds it: on the owner's dead list, still the owner's
    Dead,
}

// A change the space map and the owners still have to take, in the order they happened, and when what it's of was born.
Change :: struct {
    change : SpaceChange,
    start : u64,
    blocks : u64,
    owner : u64,
    birth : u64,
}

/*
 * What holds an owner's older blocks: the transaction its newest snapshot holds, and for a clone, the one its origin's
 * snapshot holds, 0 for none. A block born at or before the first is kept on the dead list when it's given back; one
 * born at or before the second is the origin's.
 */
Floor :: struct {
    owner : u64,
    snapshot : u64,
    origin : u64,
}

// An extent freed, born before this transaction, by its owner: free once a commit that takes its owner's changes is durable.
Later :: struct {
    start : u64,
    blocks : u64,
    owner : u64,
}

/*
 * Every owner's changes wait in one list: the container's own (owner 0) go into every commit, and a volume's into the
 * commit that takes its changes, so a volume server's are made durable only with its own tree (decisions/0089).
 */
Space :: struct {
    // Sorted by start, never two touching
    free : Extent[..],
    later : Later[..],
    changes : Change[..],
    transaction : u64,
    // Where the next search for a free extent starts, so allocations move along rather than crowding the start
    rotor : u64,
    free_blocks : u64,
    floors : Floor[..],
}

floor_of :: fn(space: ptr[Space], owner: u64) -> Floor {
    for floor in space.floors {
        if floor.owner == owner {
            return floor
        }
    }
    return Floor.{owner = owner}
}

// An owner's floor set: its newest snapshot's transaction, or its origin's, whichever is given, the other kept.
set_floor :: fn(space: ptr[mut Space], owner: u64, snapshot: u64?, origin: u64?) {
    for &floor in space.floors {
        if floor.owner == owner {
            floor.snapshot = snapshot or_else floor.snapshot
            floor.origin = origin or_else floor.origin
            return void
        }
    }
    runtime.array_add(&space.floors, Floor.{owner = owner, snapshot = snapshot or_else 0, origin = origin or_else 0})
}

// Where an extent starting at start is, or would go, in a sorted list.
extent_index :: fn(extents: Extent[], start: u64) -> usize {
    low : usize = 0
    high := extents.count
    loop {
        middle :: low + (high - low) / 2
        if middle < extents.count && extents[middle].start < start {
            low = middle + 1
        }
        else {
            high = middle
        }
    }
    while low < high
    return low
}

// The extent at index, or an empty one past the end.
extent_at :: fn(extents: Extent[], index: usize) -> Extent {
    return if index < extents.count { extents[index] } else { Extent.{} }
}

set_extent :: fn(extents: mut Extent[], index: usize, extent: Extent) {
    if index < extents.count {
        extents[index] = extent
    }
}

// An extent put in the free list, joined to those it touches.
add_free :: fn(space: ptr[mut Space], start: u64, blocks: u64) {
    space.free_blocks += blocks
    index :: extent_index(space.free, start)
    before :: if index > 0 { extent_at(space.free, index - 1) } else { Extent.{} }
    after :: extent_at(space.free, index)
    joins_before :: index > 0 && before.start + before.blocks == start
    joins_after :: index < space.free.count && start + blocks == after.start
    if joins_before && joins_after {
        set_extent(space.free, index - 1, Extent.{start = before.start, blocks = before.blocks + blocks + after.blocks})
        runtime.array_remove(&space.free, index)
    }
    else if joins_before {
        set_extent(space.free, index - 1, Extent.{start = before.start, blocks = before.blocks + blocks})
    }
    else if joins_after {
        set_extent(space.free, index, Extent.{start = start, blocks = blocks + after.blocks})
    }
    else {
        insert_extent(&space.free, index, Extent.{start = start, blocks = blocks})
    }
}

insert_extent :: fn(extents: ptr[mut Extent[..]], index: usize, extent: Extent) {
    runtime.array_add(extents, extent)
    with {
        i := extents.count - 1
    }
    loop {
        set_extent(extents^, i, extent_at(extents^, i - 1))
        i -= 1
    }
    while i > index
    set_extent(extents^, index, extent)
}

/*
 * count blocks in one extent for owner: the first free extent big enough from the rotor on, then from the start.
 * The change is kept for the trees.
 */
space_allocate :: fn(context: rawptr, blocks: u64, owner: u64) -> u64? {
    space :: cast[ptr[mut Space]](context)
    found := space.free.count
    for pass in 0..<2 {
        for extent, i in space.free {
            if extent.blocks >= blocks && (pass == 1 || extent.start + extent.blocks > space.rotor) {
                found = i
                break
            }
        }
        if found < space.free.count {
            break
        }
    }
    if found >= space.free.count {
        return null
    }
    extent :: extent_at(space.free, found)
    start := extent.start
    // From the rotor, where it's inside the extent and there's room after it
    if pass_inside(extent, space.rotor, blocks) {
        start = space.rotor
    }
    take_free(space, found, start, blocks)
    space.rotor = start + blocks
    runtime.array_add(&space.changes, Change.{change = .Allocated, start = start, blocks = blocks, owner = owner, birth = space.transaction})
    return start
}

pass_inside :: fn(extent: Extent, at: u64, blocks: u64) -> bool {
    return at > extent.start && at + blocks <= extent.start + extent.blocks
}

// blocks from start taken out of the free extent at index, which holds them.
take_free :: fn(space: ptr[mut Space], index: usize, start: u64, blocks: u64) {
    if index >= space.free.count {
        return void
    }
    extent :: extent_at(space.free, index)
    space.free_blocks -= blocks
    before :: start - extent.start
    after :: extent.start + extent.blocks - (start + blocks)
    if before == 0 && after == 0 {
        runtime.array_remove(&space.free, index)
    }
    else if before == 0 {
        set_extent(space.free, index, Extent.{start = start + blocks, blocks = after})
    }
    else if after == 0 {
        set_extent(space.free, index, Extent.{start = extent.start, blocks = before})
    }
    else {
        set_extent(space.free, index, Extent.{start = extent.start, blocks = before})
        insert_extent(&space.free, index + 1, Extent.{start = start + blocks, blocks = after})
    }
}

/*
 * An extent given back: one whose allocation no commit has taken yet is simply free again, nothing ever naming it;
 * one this commit's own rounds made is free at once in the space map too; and one a durable checkpoint may name is
 * free once a commit taking its owner's changes is durable.
 */
space_release :: fn(context: rawptr, start: u64, blocks: u64, owner: u64, birth: u64) {
    space :: cast[ptr[mut Space]](context)
    for change, i in space.changes {
        if change.change == .Allocated && change.start == start && change.blocks == blocks && change.owner == owner {
            runtime.array_remove(&space.changes, i)
            add_free(space, start, blocks)
            return void
        }
    }
    floor :: floor_of(space, owner)
    // A clone's block from its origin is the origin's, which its snapshot holds
    if birth <= floor.origin {
        return void
    }
    // One a snapshot holds goes on the dead list, still its owner's
    if birth <= floor.snapshot {
        runtime.array_add(&space.changes, Change.{change = .Dead, start = start, blocks = blocks, owner = owner, birth = birth})
        return void
    }
    if birth == space.transaction && owner == 0 {
        add_free(space, start, blocks)
        runtime.array_add(&space.changes, Change.{change = .FreedNow, start = start, blocks = blocks, owner = owner})
    }
    else {
        runtime.array_add(&space.later, Later.{start = start, blocks = blocks, owner = owner})
        runtime.array_add(&space.changes, Change.{change = .FreedLater, start = start, blocks = blocks, owner = owner, birth = birth})
    }
}

// Every owner's changes, for a commit of the whole container in one process.
ALL_OWNERS : u64 : 0xffffffffffffffff

// Whether a commit taking only's changes (or ALL_OWNERS's) takes owner's: the container's own are in every one.
takes :: fn(only: u64, owner: u64) -> bool {
    return only == ALL_OWNERS || owner == 0 || owner == only
}

// A commit that took only's changes is durable: what they freed is free, and the next transaction starts.
space_committed :: fn(space: ptr[mut Space], only: u64) {
    kept : Later[..]
    for extent in space.later {
        if takes(only, extent.owner) {
            add_free(space, extent.start, extent.blocks)
        }
        else {
            runtime.array_add(&kept, extent)
        }
    }
    runtime.array_free(&space.later)
    space.later = kept
    space.transaction += 1
}

// An extent a snapshot held, given back once none does: free once this commit is durable, whoever commits it.
space_free_held :: fn(space: ptr[mut Space], start: u64, blocks: u64) {
    runtime.array_add(&space.later, Later.{start = start, blocks = blocks, owner = 0})
    runtime.array_add(&space.changes, Change.{change = .FreedLater, start = start, blocks = blocks, owner = 0})
}

space_free :: fn(space: ptr[mut Space]) {
    runtime.array_free(&space.floors)
    runtime.array_free(&space.free)
    runtime.array_free(&space.later)
    runtime.array_free(&space.changes)
}
