package kernel

import intrinsics from "base"
import runtime from "base"
import boot_info from "../boot_info"
import frames from "frames"
import slab from "slab"

/*
 * The kernel heap (roadmap M2): Hemera's Allocator for the kernel, which every CPU's context has.
 *
 * Blocks up to 2 KiB come from slab caches of power-of-two size classes, through the calling CPU's
 * magazine for the class, so most allocations and frees take no lock. Larger ones are blocks of
 * frames of their own, single frames through the calling CPU's frame cache. A block is the smallest
 * of either that holds the size and is aligned to the alignment: a class's objects are aligned to
 * its size, and frame blocks to theirs. Memory comes zeroed.
 *
 * Freeing and resizing pass the size and alignment a block was allocated with (Hemera's
 * docs/memory.md, Allocators), which say which block it is.
 */

// Classes of 16, 32, ... 2048 bytes.
/** The smallest size class, in bytes; each class after it is twice the one before. */
SMALLEST_CLASS : u64 : 16
/** How many size classes there are: 16 to 2048 bytes. */
SIZE_CLASSES :: 8
/** The largest size class, 2048 bytes; bigger blocks are blocks of frames. */
LARGEST_SMALL : u64 : SMALLEST_CLASS << (SIZE_CLASSES - 1)
/** The frame allocator's largest block, 1 GiB, and so the largest the heap allocates. */
LARGEST_BLOCK : u64 : frames.FRAME_SIZE << frames.MAX_ORDER

/** The slab caches every CPU shares. */
Heap :: struct {
    /** One cache per size class, smallest first, each class's objects aligned to their size. */
    caches : slab.SlabCache[SIZE_CLASSES],
}

/** One CPU's magazines, one per class. */
CpuHeap :: struct {
    /** The CPU's magazine in front of each of the Heap's caches, in the same order. */
    magazines : slab.Magazine[SIZE_CLASSES],
}

/**
 * Make the heap's slab caches, one per size class, each aligned to its size.
 *
 * Runs once, at boot, before anything allocates from the heap.
 *
 * @param heap The kernel's Heap, where it lives; its caches are overwritten.
 */
init_heap :: fn(heap: ptr[mut Heap]) {
    for i in 0..<SIZE_CLASSES {
        size :: SMALLEST_CLASS << cast[u64](i)
        heap.caches[i] = slab.make_cache(size, size)
    }
}

/**
 * Make the kernel heap's Allocator, for a CPU's context.
 *
 * @param kernel The kernel, whose heap and frame allocator the Allocator uses; it's kept in the Allocator, so it lives
 *     as long as the kernel runs.
 * @return An Allocator whose function is heap_function, for any CPU's context: each call works on the calling CPU's
 *     magazines and frame cache.
 */
heap_allocator :: fn(kernel #escaping : ptr[mut Kernel]) -> runtime.Allocator {
    return runtime.Allocator.{heap_function, cast[rawptr](kernel)}
}

/**
 * Allocate, resize or free a block of the kernel heap, as Hemera's AllocatorFn does.
 *
 * With old_memory null, allocates; with size 0, frees; with both, resizes, staying in place when the new size and
 * alignment need a block of the same size, and otherwise allocating a new block, copying what fits, and freeing the
 * old one. Runs on the calling CPU, with interrupts off as all kernel code is, using its magazines and frame cache
 * without a lock, and takes a slab cache's or the frame allocator's lock only to refill or empty them.
 *
 * @param allocator_data The kernel, as heap_allocator put it.
 * @param size The size wanted in bytes, 0 to free; one that with the alignment needs more than LARGEST_BLOCK fails.
 * @param alignment The alignment wanted in bytes, a power of two (or 0, taken as none); up to LARGEST_BLOCK.
 * @param old_memory The block to resize or free, as this function gave it, or null to allocate.
 * @param old_size old_memory's size in bytes, as it was allocated or last resized; with the alignment, it says which
 *     block it is, so a wrong one corrupts the heap.
 * @param location Where the call was made from; unused.
 * @return The block's bytes, size of them, the new part zeroed; empty when size is 0 or on an error. Blocks up to
 *     LARGEST_SMALL are slab objects; bigger ones are blocks of frames in the direct map. The caller owns the block
 *     until it frees it here.
 * @return InvalidArgument if the alignment isn't a power of two; OutOfMemory if the block would be too big, or no
 *     memory could be had, or fault injection failed the Heap point, with old_memory left as it was; null on success.
 */
heap_function : runtime.AllocatorFn : fn(
    allocator_data: rawptr,
    size: usize,
    alignment: usize,
    old_memory: rawptr,
    old_size: usize,
    location := #caller_location,
) -> (mut u8[], runtime.AllocatorError?) {
    kernel :: cast[ptr[mut Kernel]](allocator_data)
    empty : mut u8[]
    if cast[u64](alignment) & (cast[u64](alignment) - 1) != 0 {
        return empty, runtime.AllocatorError.InvalidArgument
    }
    if size > 0 && block_bytes(cast[u64](size), cast[u64](alignment)) > LARGEST_BLOCK {
        return empty, runtime.AllocatorError.OutOfMemory
    }
    // Growing or shrinking within the same block stays where it is
    if old_memory != null && size > 0
        && block_bytes(cast[u64](size), cast[u64](alignment)) == block_bytes(cast[u64](old_size), cast[u64](alignment)) {
        if size > old_size {
            intrinsics.mem_zero(cast[mut rawptr](cast[u64](old_memory) + cast[u64](old_size)), size - old_size)
        }
        return view_of(cast[ptr[mut u8]](old_memory), size), null
    }
    result := empty
    if size > 0 && fails(.Heap) {
        return empty, runtime.AllocatorError.OutOfMemory
    }
    if size > 0 {
        match allocate_block(kernel, block_bytes(cast[u64](size), cast[u64](alignment))) {
            case Ok(address) => result = view_of(cast[ptr[mut u8]](address), size)
            case Error(error) => return empty, runtime.AllocatorError.OutOfMemory
        }
        intrinsics.mem_zero(cast[mut rawptr](result.data), size)
    }
    if old_memory != null {
        if size > 0 {
            intrinsics.mem_copy(cast[mut rawptr](result.data), old_memory, if old_size < size { old_size } else { size })
        }
        free_block(kernel, cast[u64](old_memory), block_bytes(cast[u64](old_size), cast[u64](alignment)))
    }
    return result, null
}

/**
 * Find the size of the block a size and alignment get: a size class, or a block of frames.
 *
 * @param size The size in bytes.
 * @param alignment The alignment in bytes, a power of two or 0; a block is as big as the larger of the two, so its
 *     natural alignment covers it.
 * @return The block's size in bytes: a class from SMALLEST_CLASS to LARGEST_SMALL, or FRAME_SIZE times a power of two,
 *     which can be more than LARGEST_BLOCK when the size is.
 */
block_bytes :: fn(size: u64, alignment: u64) -> u64 {
    wanted :: if alignment > size { alignment } else { size }
    if wanted > LARGEST_SMALL {
        return frames.FRAME_SIZE << frames.order_for(wanted)
    }
    return SMALLEST_CLASS << class_of(wanted)
}

/**
 * Find the smallest size class that holds a size.
 *
 * @param size The size in bytes; 0 to SMALLEST_CLASS give class 0.
 * @return The class's index, 0 for SMALLEST_CLASS; SIZE_CLASSES or more for a size above LARGEST_SMALL, which callers
 *     don't pass.
 */
class_of :: fn(size: u64) -> u64 {
    class : u64 = 0
    loop {
        class += 1
    }
    while SMALLEST_CLASS << class < size
    return class
}

/**
 * Allocate a block of a size block_bytes gave, from the calling CPU's magazine or frame cache, or the frame allocator.
 *
 * @param kernel The kernel, for its heap's caches and its frame allocator.
 * @param size The block's size in bytes, as block_bytes gave it: a size class, one frame, or a larger block of frames.
 * @return The block's address in the direct map, aligned to its size. Its contents are whatever was there.
 * @error OutOfMemory No memory for the block, or fault injection failed the Slab or Frame point.
 */
allocate_block :: fn(kernel: ptr[mut Kernel], size: u64) -> Result[u64, frames.FrameError] {
    if size == frames.FRAME_SIZE {
        address :: frames.take_frame(&per_cpu().frame_cache, &kernel.frames)?
        return .Ok(frames.virtual_of(&kernel.frames, address))
    }
    if size > LARGEST_SMALL {
        address :: frames.allocate(&kernel.frames, frames.order_for(size))?
        return .Ok(frames.virtual_of(&kernel.frames, address))
    }
    class :: class_of(size)
    runtime.assert(class < SIZE_CLASSES, "sizes up to LARGEST_SMALL have a class")
    cpu :: per_cpu()
    return slab.take(&cpu.heap.magazines[class], &kernel.heap.caches[class], &kernel.frames)
}

/**
 * Free a block allocate_block gave, to the calling CPU's magazine or frame cache, or the frame allocator.
 *
 * @param kernel The kernel, for its heap's caches and its frame allocator.
 * @param address The block's direct-map address; the caller gives it up.
 * @param size The block's size in bytes, as block_bytes gave it when it was allocated.
 */
free_block :: fn(kernel: ptr[mut Kernel], address: u64, size: u64) {
    if size > LARGEST_SMALL {
        // Blocks are in the direct map, at their physical address plus its offset
        physical :: cast[boot_info.PhysicalAddress](address - kernel.frames.direct_map_offset)
        if size == frames.FRAME_SIZE {
            frames.give_frame(&per_cpu().frame_cache, &kernel.frames, physical)
        }
        else {
            frames.free(&kernel.frames, physical, frames.order_for(size))
        }
        return void
    }
    class :: class_of(size)
    runtime.assert(class < SIZE_CLASSES, "sizes up to LARGEST_SMALL have a class")
    cpu :: per_cpu()
    slab.give_back(&cpu.heap.magazines[class], &kernel.heap.caches[class], &kernel.frames, address)
}
