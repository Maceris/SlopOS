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
 * frames of their own, single frames through the calling CPU's frame cache. A block is the smallest of either that holds the size and is aligned to the
 * alignment: a class's objects are aligned to its size, and frame blocks to theirs. Memory comes
 * zeroed.
 *
 * Freeing and resizing pass the size and alignment a block was allocated with (Hemera's
 * docs/memory.md, Allocators), which say which block it is.
 */

// Classes of 16, 32, ... 2048 bytes.
SMALLEST_CLASS : u64 : 16
SIZE_CLASSES :: 8
LARGEST_SMALL : u64 : SMALLEST_CLASS << (SIZE_CLASSES - 1)
// The frame allocator's largest block.
LARGEST_BLOCK : u64 : frames.FRAME_SIZE << frames.MAX_ORDER

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

// The size of the block size bytes aligned to alignment get: a size class, or a block of frames.
block_bytes :: fn(size: u64, alignment: u64) -> u64 {
    wanted :: if alignment > size { alignment } else { size }
    if wanted > LARGEST_SMALL {
        return frames.FRAME_SIZE << frames.order_for(wanted)
    }
    return SMALLEST_CLASS << class_of(wanted)
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

// A block of bytes from block_bytes, in the direct map. Its contents are whatever was there.
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
    slab.give(&cpu.heap.magazines[class], &kernel.heap.caches[class], &kernel.frames, address)
}
