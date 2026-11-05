package slopfs

import runtime from "base"

/*
 * The container's space in memory: the free extents, loaded from the space map at mount and kept as the transaction
 * allocates and frees, and the changes its trees still have to take. An extent born in this transaction and freed in
 * it is free at once, since no durable checkpoint names it; one born before is free only once this transaction's
 * checkpoint is durable, since the last one still names it (design/storage.md §3). One a snapshot holds isn't free at
 * all: it goes on its volume's dead list until no snapshot holds it, and one a clone shares with its origin is the
 * origin's, which a clone giving it back doesn't touch (snapshot.hsc).
 *
 * Quotas and the reserve (roadmap 8e, design/storage.md §3): each volume's blocks are counted, every one it owns, its
 * dead list's too, so its snapshots are charged to it, as ZFS's quota charges them; a clone's blocks from its origin
 * are the origin's. A file's bytes are refused past its volume's quota, and past the reserve, a part of the container
 * kept free for what only changes a tree. A tree's nodes are refused only when nothing is free: deleting needs new
 * nodes too, so a volume at its quota, or a container full to its reserve, can always be emptied.
 */

/** A run of blocks. */
Extent :: struct {
    /** Its first block. */
    start : u64,
    /** Its length in blocks. */
    blocks : u64,
}

/** What happened to an extent, for the space map and the owners to take. */
SpaceChange :: enum {
    /** Allocated in this transaction. */
    Allocated,
    /** Freed, born in this transaction: free at once. */
    FreedNow,
    /** Freed, born before it: pending until its checkpoint is durable. */
    FreedLater,
    /** Given back, but a snapshot of its owner's holds it: on the owner's dead list, still the owner's. */
    Dead,
}

/**
 * A change the space map and the owners still have to take, in the order they happened, and when what it's of was
 * born.
 */
Change :: struct {
    /** What happened. */
    change : SpaceChange,
    /** The extent's first block. */
    start : u64,
    /** The extent's length in blocks. */
    blocks : u64,
    /** The volume whose it is, or 0, the container, whose changes go into every commit. */
    owner : u64,
    /** The transaction the extent was written in; 0 for FreedNow, and for an extent a snapshot held freed at last. */
    birth : u64,
}

/**
 * What holds an owner's older blocks. A block born at or before snapshot is kept on the dead list when it's given
 * back; one born at or before origin is the origin's.
 */
Floor :: struct {
    /** The volume it's of. */
    owner : u64,
    /** The transaction the volume's newest snapshot holds; 0 for no snapshot. */
    snapshot : u64,
    /** For a clone, the transaction its origin's snapshot holds; 0 for a volume that isn't a clone. */
    origin : u64,
}

/** A volume's blocks, every one it owns, and the most it may have. */
Account :: struct {
    /** The volume it's of. */
    owner : u64,
    /** The blocks it owns, its dead list's included, so its snapshots are charged to it. */
    used : u64,
    /** The most blocks its files' bytes may take it to; 0 for no limit. */
    quota : u64,
}

/** The reserve's part of a container's blocks, in hundredths. */
RESERVE_PERCENT : u64 : 3
/** The fewest blocks the reserve is. */
RESERVE_FLOOR : u64 : 128

/**
 * Work out the reserve of a container, the blocks a file's bytes may not take, kept free for what only changes a
 * tree.
 *
 * @param block_count The container's size in blocks.
 * @return RESERVE_PERCENT hundredths of it, or RESERVE_FLOOR if that's more.
 */
reserve_of :: fn(block_count: u64) -> u64 {
    part :: block_count * RESERVE_PERCENT / 100
    return if part > RESERVE_FLOOR { part } else { RESERVE_FLOOR }
}

/**
 * An extent freed, born before this transaction, by its owner: free once a commit that takes its owner's changes is
 * durable.
 */
Later :: struct {
    /** Its first block. */
    start : u64,
    /** Its length in blocks. */
    blocks : u64,
    /** The volume that freed it, or 0, the container. */
    owner : u64,
}

/**
 * The container's space in memory.
 *
 * Every owner's changes wait in one list: the container's own (owner 0) go into every commit, and a volume's into the
 * commit that takes its changes, so a volume server's are made durable only with its own tree (decisions/0089). Its
 * lists are from context's allocator, freed by space_free.
 */
Space :: struct {
    /** The free extents, sorted by start, never two touching. */
    free : Extent[..],
    /** The extents freed that a durable checkpoint may still name, free once their owner's commit is durable. */
    later : Later[..],
    /** The changes the space map and owners have still to take, in the order they happened. */
    changes : Change[..],
    /** The transaction being made, which extents allocated now are born in. */
    transaction : u64,
    /** Where the next search for a free extent starts, so allocations move along rather than crowding the start. */
    rotor : u64,
    /** The blocks in free, so in the free extents now. */
    free_blocks : u64,
    /** Each volume's floor that has one; a volume with none has no snapshot and no origin. */
    floors : Floor[..],
    /** Each volume's account that has one; a volume with none uses nothing and has no quota. */
    accounts : Account[..],
    /** The blocks a file's bytes may not take (reserve_of). */
    reserve : u64,
}

/**
 * Get an owner's account.
 *
 * @param space The container's space in memory, not changed.
 * @param owner The volume's ID; 0, the container, has no account.
 * @return A copy of its account; one of nothing used and no quota if it has none.
 */
account_of :: fn(space: ptr[Space], owner: u64) -> Account {
    for account in space.accounts {
        if account.owner == owner {
            return account
        }
    }
    return Account.{owner = owner}
}

/**
 * Make room in the space's lists for more entries in each, so recording a change can't fail halfway for want of
 * memory (decisions/0104).
 *
 * It's reserved before anything changes. What the functions below add to a list fits in the room their callers made
 * for it.
 *
 * @param space The container's space in memory, whose lists' capacity may grow.
 * @param changes More entries for its changes.
 * @param later More entries for its later list.
 * @param free More entries for its free list.
 * @param owners More entries for its accounts, and as many for its floors.
 * @return True if there's room in every list; false if there wasn't the memory, with nothing changed but some lists'
 *     capacity.
 */
space_room :: fn(space: ptr[mut Space], changes: usize, later: usize, free: usize, owners: usize) -> bool {
    return runtime.array_try_reserve(&space.changes, space.changes.count + changes) == null
        && runtime.array_try_reserve(&space.later, space.later.count + later) == null
        && runtime.array_try_reserve(&space.free, space.free.count + free) == null
        && runtime.array_try_reserve(&space.accounts, space.accounts.count + owners) == null
        && runtime.array_try_reserve(&space.floors, space.floors.count + owners) == null
}

/**
 * Count an owner's blocks up or down.
 *
 * @param space The space; a new account is added for an owner without one being counted up, in room space_room made.
 * @param owner The volume; 0, the container, isn't counted.
 * @param blocks How many blocks.
 * @param adding True to count them up, false to count them down, never below 0.
 */
charge :: fn(space: ptr[mut Space], owner: u64, blocks: u64, adding: bool) {
    if owner == 0 {
        return void
    }
    for &account in space.accounts {
        if account.owner == owner {
            account.used = if adding { account.used + blocks } else if account.used > blocks { account.used - blocks } else { 0 }
            return void
        }
    }
    if adding {
        runtime.array_add(&space.accounts, Account.{owner = owner, used = blocks})
    }
}

/**
 * Set an owner's quota, in memory only; its volume record holds it on disk.
 *
 * @param space The space; a new account is added for an owner without one, with context's allocator.
 * @param owner The volume's ID, never 0.
 * @param quota The most blocks it may have, its snapshots' included; 0 for no limit.
 */
set_quota_of :: fn(space: ptr[mut Space], owner: u64, quota: u64) {
    for &account in space.accounts {
        if account.owner == owner {
            account.quota = quota
            return void
        }
    }
    runtime.array_add(&space.accounts, Account.{owner = owner, quota = quota})
}

/**
 * Get an owner's floor.
 *
 * @param space The container's space in memory, not changed.
 * @param owner The volume's ID; 0, the container, has no floor.
 * @return A copy of its floor; one of 0s, holding nothing, if it has none.
 */
floor_of :: fn(space: ptr[Space], owner: u64) -> Floor {
    for floor in space.floors {
        if floor.owner == owner {
            return floor
        }
    }
    return Floor.{owner = owner}
}

/**
 * Set an owner's floor: its newest snapshot's transaction, or its origin's, whichever is given, the other kept.
 *
 * @param space The space; a new floor is added for an owner without one, with context's allocator.
 * @param owner The volume's ID, never 0.
 * @param snapshot The transaction its newest snapshot holds, 0 for none; null to keep what it was.
 * @param origin The transaction its origin's snapshot holds, 0 for none; null to keep what it was.
 */
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

/**
 * Find where an extent is, or would go, in a list sorted by start.
 *
 * @param extents The list, sorted by start.
 * @param start The extent's first block.
 * @return The index of the first extent starting at or after start; the list's count if there's none.
 */
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

/**
 * Get an extent in a list.
 *
 * @param extents The list, as a rule the free list.
 * @param index The extent's index in the list; past the end gives an empty extent, not an error.
 * @return The extent; an empty one, at block 0, if index is past the end.
 */
extent_at :: fn(extents: Extent[], index: usize) -> Extent {
    return if index < extents.count { extents[index] } else { Extent.{} }
}

/**
 * Set an extent in a list, if index is within it.
 *
 * @param extents The list, as a rule the free list; its order is the caller's to keep.
 * @param index Its index; past the end, nothing changes.
 * @param extent The extent to put there, replacing what was.
 */
set_extent :: fn(extents: mut Extent[], index: usize, extent: Extent) {
    if index < extents.count {
        extents[index] = extent
    }
}

/**
 * Put an extent in the free list, joined to those it touches, and count it free.
 *
 * @param space The space; its free list may grow by one, in room the caller made.
 * @param start The extent's first block.
 * @param blocks Its length in blocks, at least 1; it shouldn't overlap a free extent.
 */
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

/**
 * Insert an extent into a list, those from index on moved up one.
 *
 * @param extents The list; it grows by one.
 * @param index Where it goes, at most the list's count.
 * @param extent The extent to insert, which should keep the list sorted and not touching.
 */
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

/**
 * Allocate blocks in one extent for an owner, as a Nodes' allocate does: from the first free extent big enough from
 * the rotor on, then from the start.
 *
 * The change is kept for the trees, and charged to the owner. Nothing is written.
 *
 * @param context The Space, as a rawptr.
 * @param blocks How many blocks, at least 1.
 * @param owner The volume they're for, or 0, the container.
 * @param data True for a file's bytes, which may not take the owner past its quota nor the container into its
 *     reserve; false for a tree's nodes, refused only when nothing is free.
 * @return The extent's first block; null if no free extent is big enough, a quota or the reserve refuses it, or there
 *     isn't the memory to record it.
 */
space_allocate :: fn(context: rawptr, blocks: u64, owner: u64, data: bool) -> u64? {
    space :: cast[ptr[mut Space]](context)
    /*
     * Room for this change and the two releases a copy made with it brings (writable's of the old node and its
     * copy), and for the free extents they split and join; without it, as without the blocks, there are none
     */
    if !space_room(space, 3, 2, 3, 1) {
        return null
    }
    if data {
        account :: account_of(space, owner)
        if account.quota != 0 && account.used + blocks > account.quota {
            return null
        }
        if space.free_blocks < space.reserve + blocks {
            return null
        }
    }
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
    charge(space, owner, blocks, true)
    return start
}

/**
 * Tell whether an allocation may start at a block inside an extent, after its start, with room after it.
 *
 * @param extent The free extent being allocated from.
 * @param at The block, as the rotor has it.
 * @param blocks How many blocks are being allocated, at least 1.
 * @return True if at is after the extent's start and the blocks from it fit in the extent.
 */
pass_inside :: fn(extent: Extent, at: u64, blocks: u64) -> bool {
    return at > extent.start && at + blocks <= extent.start + extent.blocks
}

/**
 * Take blocks out of the free extent that holds them, leaving what's before and after it free, and count them
 * taken.
 *
 * @param space The space; its free list may grow by one, in room the caller made.
 * @param index The free extent's index; past the end, nothing changes.
 * @param start The first block taken, inside the extent.
 * @param blocks How many, all inside the extent.
 */
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

/**
 * Give an extent back, as a Nodes' release does.
 *
 * One whose allocation no commit has taken yet is simply free again, nothing ever naming it; one this commit's own
 * rounds made is free at once in the space map too; one a clone's origin owns is left alone; one a snapshot holds
 * goes on its owner's dead list; and one a durable checkpoint may name is free once a commit taking its owner's
 * changes is durable. Without the memory to record it, the extent stays allocated: lost to the space until it's
 * checked, but never given out while something may still name it (decisions/0104).
 *
 * @param context The Space, as a rawptr.
 * @param start The extent's first block.
 * @param blocks Its length in blocks, as it was allocated.
 * @param owner The volume whose it is, or 0, the container.
 * @param birth The transaction it was written in.
 */
space_release :: fn(context: rawptr, start: u64, blocks: u64, owner: u64, birth: u64) {
    space :: cast[ptr[mut Space]](context)
    /*
     * Without the memory to record it, the extent stays allocated: lost to the space until it's checked, but never
     * given out while something may still name it (decisions/0104)
     */
    if !space_room(space, 1, 1, 1, 0) {
        return void
    }
    for change, i in space.changes {
        if change.change == .Allocated && change.start == start && change.blocks == blocks && change.owner == owner {
            runtime.array_remove(&space.changes, i)
            add_free(space, start, blocks)
            charge(space, owner, blocks, false)
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
    charge(space, owner, blocks, false)
    if birth == space.transaction && owner == 0 {
        add_free(space, start, blocks)
        runtime.array_add(&space.changes, Change.{change = .FreedNow, start = start, blocks = blocks, owner = owner})
    }
    else {
        runtime.array_add(&space.later, Later.{start = start, blocks = blocks, owner = owner})
        runtime.array_add(&space.changes, Change.{change = .FreedLater, start = start, blocks = blocks, owner = owner, birth = birth})
    }
}

/**
 * Keep what this transaction already gave back of an owner's that a new snapshot holds: a snapshot taken in a
 * transaction holds the volume as its last commit left it, which can name blocks freed earlier in the same
 * transaction, while no snapshot held them. Each such extent, born at or before floor, goes on the dead list, still
 * its owner's, rather than being freed at the commit.
 *
 * @param space The container's space in memory; its changes and later list are changed in place.
 * @param owner The volume the snapshot is of.
 * @param floor The snapshot's transaction, its new floor: extents born in it or before are held.
 */
hold_freed :: fn(space: ptr[mut Space], owner: u64, floor: u64) {
    for &change in space.changes {
        if change.change != .FreedLater || change.owner != owner || change.birth > floor {
            continue
        }
        change.change = .Dead
        charge(space, owner, change.blocks, true)
        // No longer freed at the commit
        for extent, i in space.later {
            if extent.start == change.start && extent.blocks == change.blocks && extent.owner == owner {
                runtime.array_remove(&space.later, i)
                break
            }
        }
    }
}

/** The owner to give a commit that takes every owner's changes, for a commit of the whole container in one process. */
ALL_OWNERS : u64 : 0xffffffffffffffff

/**
 * Tell whether a commit takes an owner's changes: the container's own are in every one.
 *
 * @param only The volume the commit takes the changes of, or ALL_OWNERS for every owner's.
 * @param owner The owner of a change.
 * @return True if only is ALL_OWNERS or owner, or owner is 0.
 */
takes :: fn(only: u64, owner: u64) -> bool {
    return only == ALL_OWNERS || owner == 0 || owner == only
}

/**
 * Note that a commit is durable: what its changes freed is free, and the next transaction starts.
 *
 * Without the memory to sort them, every extent freed waits for a later commit, still not free.
 *
 * @param space The container's space in memory; its later list shrinks, and its transaction advances.
 * @param only The volume the commit took the changes of, as takes has it.
 */
space_committed :: fn(space: ptr[mut Space], only: u64) {
    kept : Later[..]
    // Without the memory to sort them, every extent waits for a later commit, still not free
    if runtime.array_try_reserve(&kept, space.later.count) != null || !space_room(space, 0, 0, space.later.count, 0) {
        space.transaction += 1
        return void
    }
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

/**
 * Give back an extent a snapshot held, once none does: free once this commit is durable, whoever commits it, and no
 * longer charged to its owner.
 *
 * Without the memory to record it, it stays held, lost to the space until it's checked.
 *
 * @param space The container's space in memory; the extent goes on its later list, owned by the container.
 * @param start The extent's first block.
 * @param blocks Its length in blocks.
 * @param owner The volume whose dead list it was on.
 */
space_free_held :: fn(space: ptr[mut Space], start: u64, blocks: u64, owner: u64) {
    // As a release: without the memory to record it, held still
    if !space_room(space, 1, 1, 0, 0) {
        return void
    }
    charge(space, owner, blocks, false)
    runtime.array_add(&space.later, Later.{start = start, blocks = blocks, owner = 0})
    runtime.array_add(&space.changes, Change.{change = .FreedLater, start = start, blocks = blocks, owner = 0})
}

/**
 * Free the space's lists.
 *
 * @param space The space; it may not be used again.
 */
space_free :: fn(space: ptr[mut Space]) {
    runtime.array_free(&space.floors)
    runtime.array_free(&space.accounts)
    runtime.array_free(&space.free)
    runtime.array_free(&space.later)
    runtime.array_free(&space.changes)
}
