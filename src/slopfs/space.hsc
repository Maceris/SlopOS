package slopfs

import runtime from "base"

/*
 * The container's space in memory: the free extents, loaded from the space map at mount and kept as the transaction
 * allocates and frees, and the changes its trees still have to take. An extent born in this transaction and freed in
 * it is free at once, since no durable checkpoint names it; one born before is free only once this transaction's
 * checkpoint is durable, since the last one still names it (design/storage.md §3).
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
}

// A change the space map and the owners still have to take, in the order they happened.
Change :: struct {
    change : SpaceChange,
    start : u64,
    blocks : u64,
    owner : u64,
}

Space :: struct {
    // Sorted by start, never two touching
    free : Extent[..],
    // Freed in this transaction, born before it
    later : Extent[..],
    changes : Change[..],
    transaction : u64,
    // Where the next search for a free extent starts, so allocations move along rather than crowding the start
    rotor : u64,
    free_blocks : u64,
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
    runtime.array_add(&space.changes, Change.{change = .Allocated, start = start, blocks = blocks, owner = owner})
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

// An extent given back: free at once if this transaction made it, after its checkpoint otherwise.
space_release :: fn(context: rawptr, start: u64, blocks: u64, owner: u64, birth: u64) {
    space :: cast[ptr[mut Space]](context)
    if birth == space.transaction {
        add_free(space, start, blocks)
        runtime.array_add(&space.changes, Change.{change = .FreedNow, start = start, blocks = blocks, owner = owner})
    }
    else {
        runtime.array_add(&space.later, Extent.{start = start, blocks = blocks})
        runtime.array_add(&space.changes, Change.{change = .FreedLater, start = start, blocks = blocks, owner = owner})
    }
}

// The transaction's checkpoint is durable: what it freed is free, and the next one starts.
space_committed :: fn(space: ptr[mut Space]) {
    for extent in space.later {
        add_free(space, extent.start, extent.blocks)
    }
    runtime.array_reset(&space.later)
    space.transaction += 1
}

space_free :: fn(space: ptr[mut Space]) {
    runtime.array_free(&space.free)
    runtime.array_free(&space.later)
    runtime.array_free(&space.changes)
}
