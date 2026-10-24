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
//SPEC: Bonwick, "The Slab Allocator: An Object-Caching Kernel Memory Allocator" (USENIX 1994);
//      Bonwick and Adams, "Magazines and Vmem" (USENIX 2001), §3 (the magazine layer)
package slab

import runtime from "base"
import concurrency from "std"
import boot_info from "../../boot_info"
import frames from "../frames"

// Objects are at least this big, and their sizes a multiple of it: room for the free list's link.
OBJECT_GRANULE : u64 : 16
// A slab is big enough for at least this many objects, unless that would take more than MAX_SLAB_ORDER.
MIN_OBJECTS_PER_SLAB : u64 : 8
MAX_SLAB_ORDER : u64 : 4
// Empty slabs a cache keeps rather than freeing.
MAX_EMPTY_SLABS : u64 : 1
MAGAZINE_SIZE :: 32
// What a magazine takes from its cache when empty, and gives back when full.
MAGAZINE_BATCH :: 16

// Which list a slab is on.
SlabList :: enum #backed_by(u8) {
    // Full: every object is handed out.
    None,
    Partial,
    Empty,
}

// At the end of each slab.
SlabHeader :: struct {
    // The other slabs on its list, by base address; 0 for none.
    next : u64,
    previous : u64,
    // The first free object, 0 for none. Each free object's first 8 bytes hold the next one's address.
    free : u64,
    // Objects from this index on were never handed out.
    fresh : u32,
    in_use : u32,
    list : SlabList,
}

// The first slab on a list, and how many there are.
List :: struct {
    first : u64,
    count : u64,
}

SlabCache :: struct {
    lock : concurrency.SpinLock,
    object_size : u64,
    // Each slab is 2^slab_order frames.
    slab_order : u64,
    // Objects per slab.
    capacity : u64,
    partial : List,
    empty : List,
    // Slabs taken from the frame allocator, and objects handed out, from the cache or into magazines.
    slab_count : u64,
    allocated : u64,
    /*
     * Type-stable: empty slabs are kept rather than freed, so memory that held one of its objects only
     * ever holds its objects. What reaches an object by its address then can't reach anything else
     * there, which kernel objects' generational handles depend on (decisions/0008).
     */
    type_stable : bool,
}

// One CPU's stack of free objects from one cache. Used only by its CPU, so it needs no lock.
Magazine :: struct {
    count : u64,
    objects : u64[MAGAZINE_SIZE],
}

/*
 * A cache of objects of object_size bytes, rounded up to a multiple of alignment and of
 * OBJECT_GRANULE, which a slab's base is aligned to. alignment is a power of two up to a frame.
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

objects_in :: fn(order: u64, size: u64) -> u64 {
    return ((frames.FRAME_SIZE << order) - cast[u64](size_of(SlabHeader))) / size
}

// One object from the cache: its address in the direct map. Its contents are whatever was there.
allocate :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    return take_object(cache, allocator)
}

// Give back an object allocate gave.
free :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], object: u64) {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    give_object(cache, allocator, object)
}

/*
 * Objects for out, as many as fit, under one lock: how many. Fewer only when memory ran out, so
 * 0 means none was free.
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

// Give back objects, under one lock.
free_batch :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], objects: u64[]) {
    concurrency.lock(&cache.lock)
    defer concurrency.unlock(&cache.lock)
    for object in objects {
        give_object(cache, allocator, object)
    }
}

// An object from the calling CPU's magazine, refilled from cache if it's empty.
take :: fn(magazine: ptr[mut Magazine], cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
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

// Give an object to the calling CPU's magazine, emptying half of it into cache if it's full.
give :: fn(magazine: ptr[mut Magazine], cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator], object: u64) {
    if magazine.count == MAGAZINE_SIZE {
        free_batch(cache, allocator, magazine.objects[MAGAZINE_SIZE - MAGAZINE_BATCH..<MAGAZINE_SIZE])
        magazine.count = MAGAZINE_SIZE - MAGAZINE_BATCH
    }
    count :: magazine.count
    runtime.assert(count < MAGAZINE_SIZE, "a magazine that isn't full has room")
    magazine.objects[count] = object
    magazine.count = count + 1
}

// Give every object in a magazine back to its cache.
drain :: fn(magazine: ptr[mut Magazine], cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) {
    count :: magazine.count
    runtime.assert(count <= MAGAZINE_SIZE, "a magazine holds up to MAGAZINE_SIZE objects")
    free_batch(cache, allocator, magazine.objects[0..<count])
    magazine.count = 0
}

slab_bytes :: fn(cache: ptr[SlabCache]) -> u64 {
    return frames.FRAME_SIZE << cache.slab_order
}

header_of :: fn(cache: ptr[SlabCache], base: u64) -> ptr[mut SlabHeader] {
    return cast[ptr[mut SlabHeader]](base + slab_bytes(cache) - cast[u64](size_of(SlabHeader)))
}

// Takes the lock as held.
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

// Takes the lock as held.
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

// A slab of nothing handed out yet, from the frame allocator: its base.
new_slab :: fn(cache: ptr[mut SlabCache], allocator: ptr[mut frames.FrameAllocator]) -> Result[u64, frames.FrameError] {
    base :: frames.virtual_of(allocator, frames.allocate(allocator, cache.slab_order)?)
    header :: header_of(cache, base)
    header^ = SlabHeader.{}
    cache.slab_count += 1
    return .Ok(base)
}

list_of :: fn(cache: ptr[mut SlabCache], list: SlabList) -> ptr[mut List] {
    return if list == .Empty { &cache.empty } else { &cache.partial }
}

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
