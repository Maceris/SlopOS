/*
 * The frame allocator's tests, as a hosted program (tools/unit_tests.py): main returns 0 if
 * everything worked, or the number of the first check that failed.
 *
 * A buffer stands in for physical memory from 256 KiB to 512 KiB, reached through a direct map
 * whose offset makes those addresses land in it. The allocator takes the first frame for its state
 * bytes, which leaves frames 65 to 127: free blocks at 65 (order 0), 66 (1), 68 (2), 72 (3),
 * 80 (4) and 96 (5).
 */
package frames_test

import frames from ".."
import boot_info from "../../../boot_info"
import hosted_faults from "../../../robustness/hosted"

MEMORY_BASE : u64 : 0x40000
MEMORY_SIZE : u64 : 0x40000
FREE_FRAMES :: 63
// What a failed allocation gives in these tests: frame 0 is never free.
NO_FRAME :: cast[boot_info.PhysicalAddress](0)

// A constant, not on the stack, so the allocator made from it isn't held to main's stack frame
REGIONS :: boot_info.MemoryRegion.[
    .{range = .{base = cast[boot_info.PhysicalAddress](0), size = MEMORY_BASE}, kind = .Reserved},
    .{range = .{base = cast[boot_info.PhysicalAddress](MEMORY_BASE), size = MEMORY_SIZE}, kind = .Usable},
]

checks :: fn() -> int {
    memory : u64[32768]
    direct_map_offset :: cast[u64](&memory[0]) - MEMORY_BASE
    made :: frames.make(REGIONS, direct_map_offset)
    allocator := match made {
        case Ok(made_allocator) => made_allocator
        case Error(error) => return 1
    }
    allocator.faults.spec = hosted_faults.point_spec()
    defer hosted_faults.report_points(&allocator.faults)
    if allocator.total_frames != FREE_FRAMES || allocator.free_frames != FREE_FRAMES || allocator.frame_count != 128 {
        return 2
    }
    if allocator.lists[0].count != 1 || allocator.lists[5].count != 1 || allocator.lists[6].count != 0 {
        return 3
    }

    // The smallest block that fits, split from a larger one when there's none that size
    single :: frames.allocate(&allocator, 0) or_else NO_FRAME
    big :: frames.allocate(&allocator, 5) or_else NO_FRAME
    if single == NO_FRAME || big == NO_FRAME {
        return 4
    }
    if cast[u64](single) != 0x41000 || cast[u64](big) != 0x60000 {
        return 6
    }
    if succeeded(frames.allocate(&allocator, 5)) {
        return 7
    }
    frames.free(&allocator, big, 5)
    frames.free(&allocator, single, 0)
    if allocator.free_frames != FREE_FRAMES {
        return 8
    }

    // Every frame, one at a time, then freed in an order that merges them back
    addresses : boot_info.PhysicalAddress[FREE_FRAMES]
    for index in 0..<FREE_FRAMES {
        addresses[index] = frames.allocate(&allocator, 0) or_else NO_FRAME
        if addresses[index] == NO_FRAME {
            return 9
        }
    }
    if allocator.free_frames != 0 || succeeded(frames.allocate(&allocator, 0)) {
        return 10
    }
    for index in 0..<FREE_FRAMES {
        if index % 2 == 0 {
            frames.free(&allocator, addresses[index], 0)
        }
    }
    for index in 0..<FREE_FRAMES {
        if index % 2 == 1 {
            frames.free(&allocator, addresses[index], 0)
        }
    }
    if allocator.free_frames != FREE_FRAMES {
        return 11
    }
    for order in 0..<6 {
        if allocator.lists[order].count != 1 {
            return 12
        }
    }

    // A block that was written to comes back zeroed
    dirty :: frames.allocate(&allocator, 1) or_else NO_FRAME
    if dirty == NO_FRAME {
        return 13
    }
    bytes :: cast[ptr[mut u64]](frames.virtual_of(&allocator, dirty) + 8)
    bytes^ = 0xdead
    frames.free(&allocator, dirty, 1)
    clean :: frames.allocate_zeroed(&allocator, 1) or_else NO_FRAME
    if cast[u64](clean) != cast[u64](dirty) || cast[ptr[u64]](frames.virtual_of(&allocator, clean) + 8)^ != 0 {
        return 15
    }
    frames.free(&allocator, clean, 1)

    // A CPU's cache takes half its size at once, hands them out without the allocator, and gives half back once full
    cache : frames.FrameCache
    first :: frames.take_frame(&cache, &allocator) or_else NO_FRAME
    if first == NO_FRAME || cache.count != frames.FRAME_CACHE_BATCH - 1 || allocator.free_frames != FREE_FRAMES - frames.FRAME_CACHE_BATCH {
        return 18
    }
    taken : boot_info.PhysicalAddress[frames.FRAME_CACHE_SIZE]
    for i in 0..<frames.FRAME_CACHE_SIZE {
        taken[i] = frames.allocate(&allocator, 0) or_else NO_FRAME
        if taken[i] == NO_FRAME {
            return 22
        }
    }
    for i in 0..<frames.FRAME_CACHE_SIZE {
        frames.give_frame(&cache, &allocator, taken[i])
    }
    // 15 left and 32 given: full after 17, so the 18th gives 16 back first, leaving 31 once all are in
    if cache.count != 31 || allocator.free_frames != FREE_FRAMES - frames.FRAME_CACHE_SIZE {
        return 19
    }
    frames.give_frame(&cache, &allocator, first)
    frames.drain_frames(&cache, &allocator)
    if cache.count != 0 || allocator.free_frames != FREE_FRAMES {
        return 20
    }
    // Every list is back as it was, the cache's frames merged into their buddies
    for order in 0..<6 {
        if allocator.lists[order].count != 1 {
            return 21
        }
    }

    if frames.order_for(1) != 0 || frames.order_for(4096) != 0 || frames.order_for(4097) != 1 || frames.order_for(28672) != 3 {
        return 16
    }

    // Too little memory for the state bytes
    tiny := boot_info.MemoryRegion.[
        .{range = .{base = cast[boot_info.PhysicalAddress](0x1000000000), size = 0x1000}, kind = .Usable},
    ]
    if succeeded(frames.make(tiny, direct_map_offset)) {
        return 17
    }
    return 0
}

// Whether a result is Ok.
succeeded :: fn[T, E](result: Result[T, E]) -> bool {
    return result is_ok
}

// The checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness)
main :: fn() -> int {
    return hosted_faults.run(checks)
}
