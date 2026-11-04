/*
 * The slab allocator (roadmap M2, knowledge/design/kernel.md §2): caches of same-sized objects, for
 * kernel objects and the kernel heap's small sizes, safe to use from every CPU.
 *
 * A cache carves slabs, blocks of frames from the frame allocator, into objects. Each slab keeps
 * its free objects in a list linked through their first 8 bytes, and the objects it never handed
 * out yet as a count from its start, so a new slab costs nothing to set up. Its header is at its
 * end, so objects start at the slab's base, aligned to the slab, and an object of a power-of-two
 * size is aligned to its size. An object's slab is found by rounding its physical address down to
 * the slab's size, since frame blocks are aligned to their size.
 *
 * Slabs with free objects are on the cache's partial list; full ones are on none; a slab that
 * empties is kept for the next allocation, up to MAX_EMPTY_SLABS, and otherwise goes back to the
 * frame allocator, unless the cache is type-stable. A free object's first 8 bytes are the cache's;
 * the rest is left as it was.
 *
 * In front of each cache, every CPU has a magazine: a stack of free objects it takes from and gives
 * back to without a lock, refilled from the cache or emptied into it half a magazine at a time.
 */
/**
 * The slab allocator: caches of same-sized objects carved from blocks of frames, with a per-CPU magazine in front.
 *
 * SPEC: Bonwick, "The Slab Allocator: An Object-Caching Kernel Memory Allocator" (USENIX 1994);
 *     Bonwick and Adams, "Magazines and Vmem" (USENIX 2001), §3 (the magazine layer).
 */
package slab

import runtime from "base"
import concurrency from "std"
import boot_info from "../../boot_info"
import frames from "../frames"
import robustness from "../../robustness"

/** Objects are at least this big, and their sizes a multiple of it: room for the free list's link. */
OBJECT_GRANULE : u64 : 16
/** The fewest objects a slab is made big enough for, unless that would take more than MAX_SLAB_ORDER. */
MIN_OBJECTS_PER_SLAB : u64 : 8
/** The largest slab's order: 2^4 frames, 64 KiB. */
MAX_SLAB_ORDER : u64 : 4
/** Empty slabs a cache keeps rather than giving back to the frame allocator, unless it's type-stable and keeps all. */
MAX_EMPTY_SLABS : u64 : 1
/** The most free objects a magazine holds. */
MAGAZINE_SIZE :: 32
/** What a magazine takes from its cache when empty, and gives back when full. */
MAGAZINE_BATCH :: 16

/** Which list a slab is on. */
SlabList :: enum #backed_by(u8) {
    /** On no list, as it's full: every object is handed out (or retired), or it's being moved between lists. */
    None,
    /** On the cache's partial list: some objects are handed out and some are free. */
    Partial,
    /** On the cache's empty list: no object is handed out. */
    Empty,
}

/** A slab's bookkeeping, in its last bytes, so its objects start at its base. */
SlabHeader :: struct {
    /** The next slab on its list, by its base's direct-map address; 0 for none. */
    next : u64,
    /** The previous slab on its list, by its base's direct-map address; 0 for none. */
    previous : u64,
    /** The first free object, 0 for none. Each free object's first 8 bytes hold the next one's address. */
    free : u64,
    /** The index of the first object never handed out; objects from it to the cache's capacity are free, unlinked. */
    fresh : u32,
    /** How many of its objects are handed out now, retired ones included. */
    in_use : u32,
    /** Which of the cache's lists it's on. */
    list : SlabList,
}

/** The first slab on a list, and how many there are. */
List :: struct {
    /** The first slab's base, a direct-map address; 0 when the list is empty. */
    first : u64,
    /** How many slabs are on the list. */
    count : u64,
}

/** A cache of objects of one size and alignment, shared by every CPU under its lock. */
SlabCache :: struct {
    /** Guards the lists, the slabs' headers and the counts; magazines are used without it. */
    lock : concurrency.SpinLock,
    /** Each object's size in bytes, rounded up from what make_cache was asked to a multiple of its granule. */
    object_size : u64,
    /** Each slab is 2^slab_order frames. */
    slab_order : u64,
    /** Objects per slab, at least 1. */
    capacity : u64,
    /** Slabs with some objects handed out and some free; allocations come from its first. */
    partial : List,
    /** Slabs with no object handed out, kept for the next allocation. */
    empty : List,
    /** Slabs taken from the frame allocator and not given back. */
    slab_count : u64,
    /** Objects handed out, from the cache or into magazines, and not given back or retired. */
    allocated : u64,
    /**
     * Type-stable: empty slabs are kept rather than freed, so memory that held one of its objects only
     * ever holds its objects. What reaches an object by its address then can't reach anything else
     * there, which kernel objects' generational handles depend on (decisions/0008).
     */
    type_stable : bool,
    /** The byte offset in each object where fresh_value is written when a new slab is made. */
    fresh_offset : u64,
    /**
     * Written as a u32 at fresh_offset in each object of a new slab, when it's not 0: kernel objects' first
     * generation. 0 writes nothing.
     */
    fresh_value : u32,
    /** Objects retired: handed out once and never given back, as a slot whose generation would wrap is. */
    retired : u64,
}

/** One CPU's stack of free objects from one cache. Used only by its CPU, so it needs no lock. */
Magazine :: struct {
    /** How many objects it holds, 0 to MAGAZINE_SIZE: objects[0] to objects[count - 1], the last on top. */
    count : u64,
    /** The objects' direct-map addresses, which the cache counts as allocated. */
    objects : u64[MAGAZINE_SIZE],
}

/**
 * Make a cache of objects of a size and alignment, with no slabs yet.
 *
 * Each object's size is rounded up to a multiple of its granule, the larger of alignment and OBJECT_GRANULE; as a
 * slab's base is aligned to the slab's size, each object is aligned to the granule, and a power-of-two size up to a
 * frame is aligned to itself. Its slabs are the smallest order, up to MAX_SLAB_ORDER, that holds MIN_OBJECTS_PER_SLAB
 * objects. The cache isn't type-stable and writes nothing into new objects; a caller sets type_stable, fresh_offset
 * and fresh_value after, before it's used.
 *
 * @param object_size The objects' size in bytes; 0 is taken as 1. At most what fits in a MAX_SLAB_ORDER slab beside
 *     its header, or an assertion stops the kernel.
 * @param alignment The objects' alignment in bytes, a power of two up to FRAME_SIZE; anything else stops the kernel
 *     with an assertion.
 * @return The cache, empty. Its lock and lists are used in place, so it's put where it lives before it's used, and not
 *     copied after.
 */
make_cache :: fn(object_size: u64, alignment: u64) -> SlabCache {
    runtime.assert(alignment > 0 && alignment & (alignment - 1) == 0 && alignment <= frames.FRAME_SIZE,
        "a cache's alignment is a power of two up to a frame")
    granule :: if alignment > OBJECT_GRANULE { alignment } else { OBJECT_GRANULE }
    size :: frames.round_up(if object_size > 0 { object_size } else { 1 }, granule)
    cache : SlabCache
    cache.object_size = size
    cache.slab_order = 0
    loop {
        cache.slab_order += 1
    }
    while cache.slab_order < MAX_SLAB_ORDER && objects_in(cache.slab_order, size) < MIN_OBJECTS_PER_SLAB
    cache.capacity = objects_in(cache.slab_order, size)
    runtime.assert(cache.capacity >= 1, "a slab holds at least one object")
    return cache
}

/**
 * Count how many objects fit in a slab beside its header.
 *
 * @param order The slab's order: it's 2^order frames.
 * @param size An object's size in bytes, more than 0.
 * @return How many whole objects fit before the header, 0 if none does.
 */
objects_in :: fn(order: u64, size: u64) -> u64 {
    return ((frames.FRAME_SIZE << order) - cast[u64](size_of(SlabHeader))) / size
}

/**
 * Allocate one object from a cache, taking a new slab from the frame allocator when no slab has a free one.
 *
 * Takes the cache's lock, and, for a new slab, the frame allocator's under it.
 *
 * @param cache The cache to take from, shared by every CPU; its lock is taken, so the caller mustn't hold it.
 * @param allocator The frame allocator the cache's slabs come from, always the same one.
 * @return The object's address in the direct map, aligned as make_cache says. The caller owns it until it gives it
 *     back with free (or a magazine), or retires it. Its contents are whatever was there, but for its first 8 bytes,
 *     which may hold a free-list link, and the cache's fresh_value in an object never handed out before.
 * @error OutOfMemory No slab had a free object and the frame allocator had no block for a new one, or fault injection
 *     failed the Slab or Frame point.
 */
allocate :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
    if robustness.fails(&allocator.faults, .Slab) {
        return .Error(.OutOfMemory)
    }
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    return take_object(cache, allocator)
}

/**
 * Retire an object allocate gave, so it's never given back nor counted any more.
 *
 * Its slab keeps it counted as in use, so the slab never empties and is never freed; for a slot whose generation
 * would wrap. Takes the cache's lock.
 *
 * @param cache The cache it came from.
 * @param object The object's direct-map address. It's not looked at; only the cache's counts change.
 */
retire :: fn(cache: ptr[mut SlabCache], object: u64) {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    cache.allocated -= 1
    cache.retired += 1
}

/**
 * Give back an object allocate gave.
 *
 * Takes the cache's lock. Its slab goes on the partial list if it was full; one that empties is kept on the empty
 * list while there are fewer than MAX_EMPTY_SLABS there or the cache is type-stable, and otherwise is given back to
 * the frame allocator, under its lock.
 *
 * @param cache The cache it came from.
 * @param allocator The frame allocator the cache's slabs come from.
 * @param object The object's direct-map address, handed out by this cache and not given back since; its first 8 bytes
 *     are overwritten with the free list's link. One that isn't an object of a slab's handed-out part stops the kernel
 *     with an assertion; one given back twice isn't caught.
 */
free :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], object: u64) {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    give_object(cache, allocator, object)
}

/**
 * Allocate objects into a buffer, as many as fit, under one hold of the cache's lock.
 *
 * Unlike allocate, there's no Slab fault injection point here, though the frame allocator's still applies.
 *
 * @param cache The cache to take from; its lock is held for the whole batch, so the caller mustn't hold it.
 * @param allocator The frame allocator the cache's slabs come from.
 * @param out Where the objects' direct-map addresses go, from its start; the caller owns each object written.
 * @return How many objects were written: out's count, or fewer only when the frame allocator ran out, so 0 means none
 *     could be had.
 */
allocate_batch :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], out: mut u64[]) -> usize {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    for i in 0..<out.count {
        match take_object(cache, allocator) {
            case Ok(object) => out[i] = object
            case Error(error) => return i
        }
    }
    return out.count
}

/**
 * Give back objects, each as free does, under one hold of the cache's lock.
 *
 * @param cache The cache they came from.
 * @param allocator The frame allocator the cache's slabs come from.
 * @param objects The objects' direct-map addresses, each handed out by this cache and not given back since.
 */
free_batch :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], objects: u64[]) {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    for object in objects {
        give_object(cache, allocator, object)
    }
}

/**
 * Take an object from the calling CPU's magazine, refilling it with MAGAZINE_BATCH objects from the cache if it's
 * empty.
 *
 * Takes no lock unless the magazine is empty: then the cache's, as allocate_batch does.
 *
 * @param magazine The calling CPU's own magazine for this cache, which nothing else uses meanwhile: the caller doesn't
 *     move to another CPU, or reenter it from an interrupt, while this runs.
 * @param cache The cache the magazine's objects belong to.
 * @param allocator The frame allocator the cache's slabs come from.
 * @return The object's direct-map address, which the caller owns until it gives it back with give_back or free. Its
 *     contents are as allocate's are.
 * @error OutOfMemory The magazine was empty and the cache could get no object, or fault injection failed the Slab or
 *     Frame point.
 */
take :: fn(magazine: ptr[mut Magazine], cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
    if robustness.fails(&allocator.faults, .Slab) {
        return .Error(.OutOfMemory)
    }
    if magazine.count == 0 {
        magazine.count = cast[u64](allocate_batch(cache, allocator, magazine.objects[0..<MAGAZINE_BATCH]))
        if magazine.count == 0 {
            return .Error(.OutOfMemory)
        }
    }
    count :: magazine.count
    runtime.assert(count >= 1 && count <= MAGAZINE_SIZE, "a magazine holds up to MAGAZINE_SIZE objects")
    magazine.count = count - 1
    return .Ok(magazine.objects[count - 1])
}

/**
 * Give an object back to the calling CPU's magazine, emptying MAGAZINE_BATCH objects of it into the cache if it's
 * full.
 *
 * Takes no lock unless the magazine is full: then the cache's, as free_batch does. The object isn't checked here; a
 * wrong one is caught, if at all, when the magazine empties into the cache.
 *
 * @param magazine The calling CPU's own magazine for this cache, which nothing else uses meanwhile.
 * @param cache The cache the object came from.
 * @param allocator The frame allocator the cache's slabs come from.
 * @param object The object's direct-map address, handed out by this cache and not given back since; the caller gives
 *     it up.
 */
give_back :: fn(magazine: ptr[mut Magazine], cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], object: u64) {
    if magazine.count == MAGAZINE_SIZE {
        free_batch(cache, allocator, magazine.objects[MAGAZINE_SIZE - MAGAZINE_BATCH..<MAGAZINE_SIZE])
        magazine.count = MAGAZINE_SIZE - MAGAZINE_BATCH
    }
    count :: magazine.count
    runtime.assert(count < MAGAZINE_SIZE, "a magazine that isn't full has room")
    magazine.objects[count] = object
    magazine.count = count + 1
}

/**
 * Give every object in a magazine back to its cache, emptying it.
 *
 * Takes the cache's lock, as free_batch does.
 *
 * @param magazine The magazine, which nothing else uses meanwhile; empty afterwards.
 * @param cache The cache its objects came from.
 * @param allocator The frame allocator the cache's slabs come from.
 */
drain :: fn(magazine: ptr[mut Magazine], cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) {
    count :: magazine.count
    runtime.assert(count <= MAGAZINE_SIZE, "a magazine holds up to MAGAZINE_SIZE objects")
    free_batch(cache, allocator, magazine.objects[0..<count])
    magazine.count = 0
}

/**
 * Find a cache's slabs' size.
 *
 * @param cache A cache from make_cache; only its slab_order, fixed once it's made, is read, without the lock.
 * @return Each slab's size in bytes, FRAME_SIZE times 2^slab_order.
 */
slab_bytes :: fn(cache: ptr[SlabCache]) -> u64 {
    return frames.FRAME_SIZE << cache.slab_order
}

/**
 * Find a slab's header, in its last bytes.
 *
 * @param cache The cache it belongs to, for its slabs' size.
 * @param base The slab's base, a direct-map address.
 * @return A pointer to the header, good while the slab is the cache's.
 */
header_of :: fn(cache: ptr[SlabCache], base: u64) -> ptr[mut SlabHeader] {
    return cast[ptr[mut SlabHeader]](base + slab_bytes(cache) - cast[u64](size_of(SlabHeader)))
}

/**
 * Allocate one object as allocate does, with the cache's lock already held, and without the Slab fault point.
 *
 * @param cache The cache, its lock held by the caller.
 * @param allocator The frame allocator the cache's slabs come from.
 * @return The object's direct-map address, which the caller owns; its contents are as allocate's are.
 * @error OutOfMemory No slab had a free object and the frame allocator had no block for a new one.
 */
take_object :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
    if cache.partial.count == 0 {
        base := cache.empty.first
        if base != 0 {
            unlink(cache, base)
        }
        else {
            base = new_slab(cache, allocator)?
        }
        push(cache, base, .Partial)
    }
    base :: cache.partial.first
    header :: header_of(cache, base)
    object := header.free
    if object != 0 {
        header.free = cast[ptr[u64]](object)^
    }
    else {
        runtime.assert(cast[u64](header.fresh) < cache.capacity, "a slab on the partial list has a free object")
        object = base + cast[u64](header.fresh) * cache.object_size
        header.fresh += 1
    }
    header.in_use += 1
    if cast[u64](header.in_use) == cache.capacity {
        unlink(cache, base)
    }
    cache.allocated += 1
    return .Ok(object)
}

/**
 * Give back one object as free does, with the cache's lock already held.
 *
 * @param cache The cache, its lock held by the caller.
 * @param allocator The frame allocator the cache's slabs come from; an emptied slab may go back to it.
 * @param object The object's direct-map address, handed out by this cache and not given back since.
 */
give_object :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], object: u64) {
    // Slabs are aligned physically, to their size
    offset_to_physical :: allocator.direct_map_offset
    base :: ((object - offset_to_physical) & ~(slab_bytes(cache) - 1)) + offset_to_physical
    header :: header_of(cache, base)
    offset :: object - base
    runtime.assert(offset % cache.object_size == 0 && offset < cast[u64](header.fresh) * cache.object_size && header.in_use > 0,
        "free takes an object its cache handed out")
    cast[ptr[mut u64]](object)^ = header.free
    header.free = object
    header.in_use -= 1
    cache.allocated -= 1
    if header.list == .None {
        push(cache, base, .Partial)
    }
    if header.in_use > 0 {
        return void
    }
    unlink(cache, base)
    if cache.empty.count < MAX_EMPTY_SLABS || cache.type_stable {
        push(cache, base, .Empty)
        return void
    }
    frames.free(allocator, cast[boot_info.PhysicalAddress](base - allocator.direct_map_offset), cache.slab_order)
    cache.slab_count -= 1
}

/**
 * Make a slab with nothing handed out yet, from a block of the frame allocator's.
 *
 * Writes fresh_value into each object, when it's not 0, and counts the slab in slab_count; the slab isn't put on a
 * list. The caller holds the cache's lock.
 *
 * @param cache The cache, its lock held.
 * @param allocator The frame allocator, whose lock is taken for the block.
 * @return The slab's base, a direct-map address aligned to the slab's size.
 * @error OutOfMemory The frame allocator had no block of the slab's order, or fault injection failed the Frame point.
 */
new_slab :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
    base :: frames.virtual_of(allocator, frames.allocate(allocator, cache.slab_order)?)
    header :: header_of(cache, base)
    header^ = SlabHeader.{}
    if cache.fresh_value != 0 {
        for i in 0..<cache.capacity {
            at :: base + i * cache.object_size + cache.fresh_offset
            cast[ptr[mut u32]](at)^ = cache.fresh_value
        }
    }
    cache.slab_count += 1
    return .Ok(base)
}

/**
 * Find one of a cache's lists.
 *
 * @param cache The cache whose list is wanted; the caller holds its lock to use the list.
 * @param list Which list: Empty for the empty list, and Partial, or None, for the partial one.
 * @return A pointer to the list, in the cache.
 */
list_of :: fn(cache: ptr[mut SlabCache], list: SlabList) -> ptr[mut List] {
    return if list == .Empty { &cache.empty } else { &cache.partial }
}

/**
 * Put a slab first on one of a cache's lists. The caller holds the cache's lock.
 *
 * @param cache The cache, its lock held.
 * @param base The slab's base, a direct-map address; the slab must be on no list.
 * @param list Partial or Empty, the list it goes on, which its header records.
 */
push :: fn(cache: ptr[mut SlabCache], base: u64, list: SlabList) {
    target :: list_of(cache, list)
    header :: header_of(cache, base)
    header.list = list
    header.previous = 0
    header.next = target.first
    if target.first != 0 {
        header_of(cache, target.first).previous = base
    }
    target.first = base
    target.count += 1
}

/**
 * Take a slab off the list it's on, leaving it on none. The caller holds the cache's lock.
 *
 * @param cache The cache, its lock held.
 * @param base The slab's base, a direct-map address; a slab on no list stops the kernel with an assertion.
 */
unlink :: fn(cache: ptr[mut SlabCache], base: u64) {
    header :: header_of(cache, base)
    runtime.assert(header.list != .None, "unlink takes a slab on a list")
    target :: list_of(cache, header.list)
    if header.previous != 0 {
        header_of(cache, header.previous).next = header.next
    }
    else {
        target.first = header.next
    }
    if header.next != 0 {
        header_of(cache, header.next).previous = header.previous
    }
    target.count -= 1
    header.list = .None
}
