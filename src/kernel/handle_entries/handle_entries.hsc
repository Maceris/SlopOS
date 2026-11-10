/*
 * A handle table's entry and its tag (decisions/0008, 0010, 0187): what the kernel's handle tables (handles.hsc) hold,
 * and how an entry is filled, read and emptied. A package of its own, so a hosted test checks its reads under the
 * model checker.
 *
 * An entry is filled and emptied by whoever holds its table's lock, and read without it: a read takes the tag, then the
 * entry's fields, then the tag again, and goes again if the tag changed, so what it gives belongs together. The fields
 * are relaxed atomics, which cost what plain loads and stores do, so what a read races is defined. Filling fences
 * before it writes them: a read that sees a field the fill wrote then sees the tag that emptied the entry before it, or
 * a later one, so never takes one entry's object with another's tag.
 */
package handle_entries

import intrinsics from "base"

// An entry's tag: its rights in the low 32 bits, then its kind, and these, then its generation in the top 16.
/** The tag's bit for an entry that holds a handle. */
TAG_VALID : u64 : 1 << 40
/** The tag's bit for an owning handle, whose closing destroys its object. */
TAG_OWNING : u64 : 1 << 41
/** Where the entry's 16-bit generation starts in its tag. */
TAG_GENERATION_SHIFT : u64 : 48

/** One entry of a handle table, 32 bytes: a handle, or a free slot. */
HandleEntry :: struct #align(32) {
    /**
     * The rights in the low 32 bits, the object's kind in bits 32 to 39, TAG_VALID and TAG_OWNING, and the entry's
     * generation in the top 16. Written with a release store under the table's lock, and read without it.
     */
    tag : u64,
    /** The object's address, while TAG_VALID is set; a relaxed atomic, written under the table's lock. */
    object : u64,
    /** The object's generation when the handle was made, while TAG_VALID is set; as object is. */
    generation : u32,
    /** The next free entry's index, while it's free; 0 at the free list's end. Only touched under the table's lock. */
    next_free : u32,
    /** Unused, so an entry is 32 bytes. */
    reserved : u64,
}

#assert size_of(HandleEntry) == 32

/** What an entry holds, as read or emptied. */
Held :: struct {
    /** The object's address. */
    object : u64,
    /** The object's generation when the handle was made. */
    generation : u32,
    /** The object's kind, as the kernel numbers its kinds; the entry doesn't check it. */
    kind : u8,
    /** The handle's rights, as the kernel's rights bits. */
    rights : u32,
    /** Whether it's the owning handle, whose closing destroys the object. */
    owning : bool,
}

/**
 * Give an entry's generation, by whoever holds its table's lock.
 *
 * @param entry The entry, filled or not.
 * @return Its generation, 0 to 0xffff: what a handle to it has in its high 16 bits.
 */
generation_of :: fn(entry: ptr[HandleEntry]) -> u64 {
    return intrinsics.atomic_load_u64_no_fence(&entry.tag) >> TAG_GENERATION_SHIFT
}

/**
 * Make a fresh entry empty, at a generation, by whoever holds its table's lock, before it's first filled.
 *
 * @param entry The entry, never filled, and not yet reachable by reads: its page was just made.
 * @param generation Its first generation, 0 to 0xffff.
 */
start :: fn(entry: ptr[mut HandleEntry], generation: u64) {
    intrinsics.atomic_store_u64_no_fence(&entry.tag, (generation & 0xffff) << TAG_GENERATION_SHIFT)
}

/**
 * Fill an empty entry with a handle, by whoever holds its table's lock.
 *
 * @param entry The entry: empty, as start or empty left it.
 * @param held What it holds from now on.
 * @return Its generation, which a handle to it has in its high 16 bits.
 */
fill :: fn(entry: ptr[mut HandleEntry], held: Held) -> u64 {
    generation :: generation_of(entry)
    // What emptied it, before the fields: a read seeing a field written here sees that too
    intrinsics.fence_release()
    intrinsics.atomic_store_u64_no_fence(&entry.object, held.object)
    intrinsics.atomic_store_u32_no_fence(&entry.generation, held.generation)
    tag := (generation << TAG_GENERATION_SHIFT) | TAG_VALID | (cast[u64](held.kind) << 32) | cast[u64](held.rights)
    if held.owning {
        tag |= TAG_OWNING
    }
    intrinsics.atomic_store_u64_release(&entry.tag, tag)
    return generation
}

/**
 * Read what an entry holds, without its table's lock.
 *
 * The entry is read until its tag is the same before and after, so what's read belongs together: one filling's object,
 * generation, kind and rights.
 *
 * @param entry The entry, which another CPU may fill or empty meanwhile.
 * @param wanted The generation of the handle being looked up, 0 to 0xffff.
 * @return What it holds; null if it's empty, or its generation isn't wanted, as the handle was closed.
 */
read :: fn(entry: ptr[HandleEntry], wanted: u64) -> Held? {
    loop {
        tag :: intrinsics.atomic_load_u64_acquire(&entry.tag)
        if tag & TAG_VALID == 0 || tag >> TAG_GENERATION_SHIFT != wanted {
            return null
        }
        held :: held_of(tag, intrinsics.atomic_load_u64_no_fence(&entry.object),
            intrinsics.atomic_load_u32_no_fence(&entry.generation))
        intrinsics.fence_acquire()
        // Unchanged while it was read, so what was read belongs together
        if intrinsics.atomic_load_u64_no_fence(&entry.tag) == tag {
            return held
        }
    }
}

/**
 * Empty a filled entry, by whoever holds its table's lock: its generation advances, so its handle fails from now on.
 *
 * @param entry The entry.
 * @param wanted The generation of the handle being closed, 0 to 0xffff.
 * @param next Set to the entry's generation from now on, 0 to 0xffff; 0 when it wrapped, so the entry isn't to be used
 *     again. Untouched when the entry isn't emptied.
 * @return What it held; null if it was empty already, or its generation isn't wanted, as the handle was closed.
 */
empty :: fn(entry: ptr[mut HandleEntry], wanted: u64, next: ptr[mut u64]) -> Held? {
    tag :: intrinsics.atomic_load_u64_no_fence(&entry.tag)
    if tag & TAG_VALID == 0 || tag >> TAG_GENERATION_SHIFT != wanted {
        return null
    }
    held :: held_of(tag, intrinsics.atomic_load_u64_no_fence(&entry.object),
        intrinsics.atomic_load_u32_no_fence(&entry.generation))
    next_generation :: (wanted + 1) & 0xffff
    intrinsics.atomic_store_u64_release(&entry.tag, next_generation << TAG_GENERATION_SHIFT)
    next^ = next_generation
    return held
}

/**
 * Read a filled entry's tag, object and generation by whoever holds its table's lock, or once nothing changes it.
 *
 * @param entry The entry.
 * @return What it holds; null if it's empty.
 */
peek :: fn(entry: ptr[HandleEntry]) -> Held? {
    tag :: intrinsics.atomic_load_u64_no_fence(&entry.tag)
    if tag & TAG_VALID == 0 {
        return null
    }
    return held_of(tag, intrinsics.atomic_load_u64_no_fence(&entry.object), intrinsics.atomic_load_u32_no_fence(&entry.generation))
}

/**
 * Put a tag and the fields read with it together.
 *
 * @param tag The tag, with TAG_VALID.
 * @param object The object field.
 * @param generation The generation field.
 * @return What they say the entry holds.
 */
held_of :: fn(tag: u64, object: u64, generation: u32) -> Held {
    return Held.{object = object, generation = generation, kind = cast[u8](tag >> 32), rights = cast[u32](tag),
        owning = tag & TAG_OWNING != 0}
}
