/**
 * The slab allocator's tests, as a hosted program (tools/unit_tests.py): main returns 0 if
 * everything worked, or the number of the first check that failed.
 *
 * As in the frame allocator's tests, a buffer stands in for physical memory from 256 KiB to 512 KiB,
 * which leaves 63 frames for slabs once the frame allocator has its state.
 */
package slab_test

import slab from ".."
import frames from "../../frames"
import boot_info from "../../../boot_info"
import hosted_faults from "../../../robustness/hosted"

/** The physical address the stand-in memory starts at: 256 KiB, frame 64. */
MEMORY_BASE : u64 : 0x40000
/** The stand-in memory's size in bytes: 256 KiB, 64 frames, the size of checks' buffer. */
MEMORY_SIZE : u64 : 0x40000
/** The frames the frame allocator has free once it has made: 64, less the one its state bytes take. */
FREE_FRAMES : u64 : 63

/**
 * The memory map the tests' frame allocator is made from: reserved memory below MEMORY_BASE, then MEMORY_SIZE bytes
 * usable. A constant, not on the stack, so the allocator made from it isn't held to a stack frame.
 */
REGIONS :: boot_info.MemoryRegion.[
    .{range = .{base = cast[boot_info.PhysicalAddress](0), size = MEMORY_BASE}, kind = .Reserved},
    .{range = .{base = cast[boot_info.PhysicalAddress](MEMORY_BASE), size = MEMORY_SIZE}, kind = .Usable},
]

/**
 * Run the slab allocator's checks, in order, stopping at the first that fails.
 *
 * Its buffer, on the stack, is the stand-in memory, so everything it makes is gone when it returns.
 *
 * @return 0 if every check passed, or the number of the first that failed (1 to 16, not in order of running).
 */
checks :: fn() -> int {
    memory : u64[32768]
    direct_map_offset :: cast[u64](&memory[0]) - MEMORY_BASE
    allocator := match frames.make(REGIONS, direct_map_offset) {
        case Ok(made) => made
        case Error(error) => return 1
    }
    allocator.faults.spec = hosted_faults.point_spec()
    defer hosted_faults.report_points(&allocator.faults)

    // 64-byte objects, 63 to a one-frame slab with its header at the end
    cache := slab.make_cache(64, 8)
    if cache.object_size != 64 || cache.slab_order != 0 || cache.capacity != 63 {
        return 2
    }
    objects : u64[64]
    for i in 0..<64 {
        objects[i] = slab.allocate(&cache, &allocator) or_else 0
        if objects[i] == 0 || (objects[i] - direct_map_offset) % 64 != 0 {
            return 3
        }
    }
    // The first slab's objects in order from its base, then a second slab
    if objects[1] != objects[0] + 64 || objects[62] != objects[0] + 62 * 64 || cache.slab_count != 2 || cache.allocated != 64 {
        return 4
    }
    if allocator.free_frames != FREE_FRAMES - 2 || cache.partial.count != 1 {
        return 5
    }

    // The last object freed is the next one handed out
    slab.free(&cache, &allocator, objects[10])
    if cache.partial.count != 2 || (slab.allocate(&cache, &allocator) or_else 0) != objects[10] {
        return 6
    }

    // Emptying the second slab keeps it; emptying the first too gives one back to the frame allocator
    slab.free(&cache, &allocator, objects[63])
    if cache.empty.count != 1 || cache.slab_count != 2 || allocator.free_frames != FREE_FRAMES - 2 {
        return 7
    }
    for i in 0..<63 {
        slab.free(&cache, &allocator, objects[i])
    }
    if cache.empty.count != 1 || cache.partial.count != 0 || cache.slab_count != 1 || cache.allocated != 0
        || allocator.free_frames != FREE_FRAMES - 1 {
        return 8
    }

    // A magazine takes half its size at once, and gives half back once full
    objects[0] = slab.allocate(&cache, &allocator) or_else 0
    if objects[0] == 0 {
        return 15
    }
    magazine : slab.Magazine
    first :: slab.take(&magazine, &cache, &allocator) or_else 0
    if first == 0 || magazine.count != slab.MAGAZINE_BATCH - 1 || cache.allocated != slab.MAGAZINE_BATCH + 1 {
        return 9
    }
    for i in 0..<slab.MAGAZINE_SIZE - slab.MAGAZINE_BATCH + 1 {
        slab.give_back(&magazine, &cache, &allocator, objects[0])
        objects[0] = slab.allocate(&cache, &allocator) or_else 0
        if objects[0] == 0 {
            return 16
        }
    }
    if magazine.count != slab.MAGAZINE_SIZE {
        return 10
    }
    slab.give_back(&magazine, &cache, &allocator, first)
    if magazine.count != slab.MAGAZINE_SIZE - slab.MAGAZINE_BATCH + 1 {
        return 11
    }
    slab.drain(&magazine, &cache, &allocator)
    slab.free(&cache, &allocator, objects[0])
    if magazine.count != 0 || cache.allocated != 0 || cache.slab_count != 1 {
        return 12
    }

    // Big objects get slabs of several frames, and running out of frames is an error
    big := slab.make_cache(2000, 16)
    if big.object_size != 2000 || big.slab_order != 2 || big.capacity != 8 {
        return 13
    }
    count : u64 = 0
    loop {
        count += 1
    }
    while succeeded(slab.allocate(&big, &allocator))
    // Every block of 4 frames left became a slab
    if count != big.slab_count * big.capacity || big.slab_count < 10 || succeeded_frames(frames.allocate(&allocator, 2)) {
        return 14
    }
    return 0
}

/**
 * Tell whether a frame allocation succeeded.
 *
 * @param result The frame allocator's result; a block it holds isn't freed.
 * @return True if it's Ok, false if it's an Error.
 */
succeeded_frames :: fn(result: Result[boot_info.PhysicalAddress, frames.FrameError]) -> bool {
    return result is_ok
}

/**
 * Tell whether a slab allocation succeeded.
 *
 * @param result The slab allocator's result; an object it holds isn't freed.
 * @return True if it's Ok, false if it's an Error.
 */
succeeded :: fn(result: Result[u64, frames.FrameError]) -> bool {
    return result is_ok
}

/**
 * Run the checks, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return The program's exit status: 0 if every check passed, or the number of the first that failed.
 */
main :: fn() -> int {
    return hosted_faults.run(checks)
}
