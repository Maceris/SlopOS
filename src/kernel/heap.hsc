package kernel

import intrinsics from "base"
import runtime from "base"
import boot_info from "../boot_info"
import frames from "frames"
import slab from "slab"

/*
 * The kernel heap (roadmap M2): Hemera's Allocator for the kernel, which every CPU's context has.
 *
 * Sizes up to 2 KiB come from slab caches of power-of-two size classes, through the calling CPU's
 * magazine for the class, so most allocations and frees take no lock. Larger ones are blocks of
 * frames of their own. Either way a block is aligned to its class's size or its own, and memory
 * comes zeroed.
 *
 * Freeing passes only the size (base's free and free_array pass no alignment), so which class a
 * block is in depends on its size alone. A block is aligned to its class, so asking for more than
 * that is an error rather than something free couldn't undo.
 */
//HEMERA(friction): Allocator's free passes no alignment, so an allocator that would serve an over-aligned block differently can't tell on free; the heap refuses alignment beyond a block's natural one instead

// Classes of 16, 32, ... 2048 bytes.
SMALLEST_CLASS : u64 : 16
SIZE_CLASSES :: 8
LARGEST_SMALL : u64 : SMALLEST_CLASS << (SIZE_CLASSES - 1)

// The slab caches every CPU shares.
Heap :: struct {
    caches : slab.SlabCache[SIZE_CLASSES],
}

// One CPU's magazines, one per class.
CpuHeap :: struct {
    magazines : slab.Magazine[SIZE_CLASSES],
}

init_heap :: fn(heap: ptr[mut Heap]) {
    for i in 0..<SIZE_CLASSES {
        size :: SMALLEST_CLASS << cast[u64](i)
        heap.caches[i] = slab.make_cache(size, size)
    }
}

heap_allocator :: fn(kernel #escaping : ptr[mut Kernel]) -> runtime.Allocator {
    return runtime.Allocator.{heap_function, cast[rawptr](kernel)}
}

heap_function : runtime.AllocatorFn : fn(
    allocator_data: rawptr,
    size: usize,
    alignment: usize,
    old_memory: rawptr,
    old_size: usize,
    location := #caller_location,
) -> (u8[], runtime.AllocatorError?) {
    kernel :: cast[ptr[mut Kernel]](allocator_data)
    empty : u8[]
    if size > 0 && cast[u64](alignment) > block_bytes(cast[u64](size)) {
        return empty, runtime.AllocatorError.InvalidArgument
    }
    // Growing or shrinking within the same block stays where it is
    if old_memory != null && size > 0 && block_bytes(cast[u64](size)) == block_bytes(cast[u64](old_size)) {
        if size > old_size {
            intrinsics.mem_zero(cast[rawptr](cast[u64](old_memory) + cast[u64](old_size)), size - old_size)
        }
        return view_of(cast[ptr[mut u8]](old_memory), size), null
    }
    result := empty
    if size > 0 {
        match allocate_block(kernel, cast[u64](size)) {
            case Ok(address) => result = view_of(cast[ptr[mut u8]](address), size)
            case Error(error) => return empty, runtime.AllocatorError.OutOfMemory
        }
        intrinsics.mem_zero(cast[rawptr](result.data), size)
    }
    if old_memory != null {
        if size > 0 {
            intrinsics.mem_copy(cast[rawptr](result.data), old_memory, if old_size < size { old_size } else { size })
        }
        free_block(kernel, cast[u64](old_memory), cast[u64](old_size))
    }
    return result, null
}

// The size of the block size bytes get: a size class, or a block of frames.
block_bytes :: fn(size: u64) -> u64 {
    if size > LARGEST_SMALL {
        return frames.FRAME_SIZE << frames.order_for(size)
    }
    return SMALLEST_CLASS << class_of(size)
}

// The smallest class that holds size bytes, up to LARGEST_SMALL.
class_of :: fn(size: u64) -> u64 {
    class : u64 = 0
    loop {
        class += 1
    }
    while SMALLEST_CLASS << class < size
    return class
}

// A block for size bytes, in the direct map. Its contents are whatever was there.
allocate_block :: fn(kernel: ptr[mut Kernel], size: u64) -> Result[u64, frames.FrameError] {
    if size > LARGEST_SMALL {
        address :: frames.allocate(&kernel.frames, frames.order_for(size))?
        return .Ok(frames.virtual_of(&kernel.frames, address))
    }
    class :: class_of(size)
    runtime.assert(class < SIZE_CLASSES, "sizes up to LARGEST_SMALL have a class")
    cpu :: per_cpu()
    return slab.take(&cpu.heap.magazines[class], &kernel.heap.caches[class], &kernel.frames)
}

free_block :: fn(kernel: ptr[mut Kernel], address: u64, size: u64) {
    if size > LARGEST_SMALL {
        // Blocks are in the direct map, at their physical address plus its offset
        physical :: cast[boot_info.PhysicalAddress](address - kernel.frames.direct_map_offset)
        frames.free(&kernel.frames, physical, frames.order_for(size))
        return void
    }
    class :: class_of(size)
    runtime.assert(class < SIZE_CLASSES, "sizes up to LARGEST_SMALL have a class")
    cpu :: per_cpu()
    slab.give(&cpu.heap.magazines[class], &kernel.heap.caches[class], &kernel.frames, address)
}
