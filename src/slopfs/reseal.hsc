package slopfs

import runtime from "base"

/*
 * Sealing a volume again after it's given a new volume key (decisions/0181's F5, keys.hsc): its live tree walked in key
 * order, a few blocks at a time, each leaf sealed before the floor made writable, so it's sealed again with every
 * branch above it at the next commit, and each file chunk sealed before it read and written anew. Every step is its
 * own commit's, so it can stop at any point, a crash included, and go on from where it was, or from the start, which
 * only reads what's done already; it needs room for no more than a step's blocks.
 */

/**
 * Seal again up to so many of a volume's blocks sealed with a generation before a floor, walking its tree from a key.
 *
 * What's changed is the volume's, dirty, durable with its next commit; the caller commits each step.
 *
 * @param volume The volume, open and unlocked, its keys' current generation the floor or later.
 * @param floor The generation every block is to be sealed with, or a later one.
 * @param from The key to walk from: Key.{} at first, then what the step before gave.
 * @param most How many blocks to seal again in this step, at least 1: each leaf, with the branches above it, and each
 *     chunk, counts as one.
 * @return The key to go on from in the next step; null once the walk reached the tree's end, every block before it
 *     sealed with the floor or later once this step is committed.
 * @error Locked The volume isn't encrypted.
 * @error NotFound Its keys' current generation is before the floor.
 * @error DeviceError A chunk couldn't be read or written.
 * @error Corrupt A node or a chunk didn't check out, or couldn't be sealed.
 * @error OutOfMemory No memory for a buffer or a node.
 * @error NoSpace No free extent for a node or a chunk.
 */
reseal_step :: fn(volume: ptr[mut Volume], floor: u32, from: Key, most: u64) -> Result[Key?, Error] {
    keys :: volume.tree.keys or_return .Error(.Locked)
    if keys.current < floor {
        return .Error(.NotFound)
    }
    value :: make(ValueBuffer)?
    defer runtime.free(value)
    chunk :: make(ChunkBuffer)?
    defer runtime.free(chunk)
    sealed := cast[u64](0)
    at := from
    loop {
        if sealed >= most {
            return .Ok(at)
        }
        item :: tree_next(volume.nodes, &volume.tree, at, value.bytes)? or_break
        if tree_touch_older(volume.nodes, &volume.tree, item.key, floor)? {
            volume.dirty = true
            sealed += 1
        }
        if item.key.kind == cast[u8](RecordKind.Extent) && item.bytes == size_of(ExtentRecord) {
            extent :: cast[ptr[ExtentRecord]](&value.bytes[0])^
            if cast[u32](extent.kind) == cast[u32](ExtentKind.Blocks) && cast[u32](extent.pointer.generation) < floor
                && cast[u64](extent.pointer.birth) != volume.nodes.transaction {
                index :: item.key.offset / CHUNK_BYTES
                used :: read_chunk(volume, item.key.object, index, chunk.bytes)?
                write_chunk(volume, item.key.object, index, chunk.bytes, used, false)?
                sealed += 1
            }
        }
        at = key_after(item.key) or_break
    }
    return .Ok(null)
}
