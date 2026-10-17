package kernel

import intrinsics from "base"
import runtime from "base"
import boot_info from "../boot_info"
import frames from "frames"

/*
 * An Allocator over the frame allocator, which is safe on any CPU: each allocation is a block of
 * frames of its own, zeroed, so it suits things of a few KiB that every CPU shares, like fiber
 * pools and fibers. Alignment up to a frame.
 */
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
    if cast[u64](alignment) > frames.FRAME_SIZE {
        return empty, runtime.AllocatorError.InvalidArgument
    }
    result := empty
    if size > 0 {
        match frames.allocate_zeroed(&kernel.frames, frames.order_for(cast[u64](size))) {
            case Ok(address) => result = view_of(cast[ptr[mut u8]](frames.virtual_of(&kernel.frames, address)), size)
            case Error(error) => return empty, runtime.AllocatorError.OutOfMemory
        }
    }
    if old_memory != null {
        if size > 0 {
            intrinsics.mem_copy(cast[rawptr](result.data), old_memory, if old_size < size { old_size } else { size })
        }
        // Blocks are in the direct map, at their physical address plus its offset
        physical :: cast[boot_info.PhysicalAddress](cast[u64](old_memory) - kernel.frames.direct_map_offset)
        frames.free(&kernel.frames, physical, frames.order_for(cast[u64](old_size)))
    }
    return result, null
}
