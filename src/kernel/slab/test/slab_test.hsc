/**
 * The slab allocator's tests, as a hosted program (tools/unit_tests.py, decisions/0175): main runs them and returns
 * how many failed.
 *
 * As in the frame allocator's tests, a buffer on each test's stack stands in for physical memory from 256 KiB to
 * 512 KiB, which leaves 63 frames for slabs once the frame allocator has its state.
 */
package slab_test

import compiler from "base"
import testing from "std"
import slab from ".."
import frames from "../../frames"
import boot_info from "../../../boot_info"
import hosted_faults from "../../../robustness/hosted"

/** The physical address the stand-in memory starts at: 256 KiB, frame 64. */
MEMORY_BASE : u64 : 0x40000
/** The stand-in memory's size in bytes: 256 KiB, 64 frames, the size of Memory. */
MEMORY_SIZE : u64 : 0x40000
/** The frames the frame allocator has free once it has made: 64, less the one its state bytes take. */
FREE_FRAMES : u64 : 63

/** The stand-in memory, MEMORY_SIZE bytes, on a test's stack so everything made in it is gone when the test returns. */
Memory :: alias u64[32768]

/**
 * The memory map the tests' frame allocator is made from: reserved memory below MEMORY_BASE, then MEMORY_SIZE bytes
 * usable. A constant, not on the stack, so the allocator made from it isn't held to a stack frame.
 */
REGIONS :: boot_info.MemoryRegion.[
    .{range = .{base = cast[boot_info.PhysicalAddress](0), size = MEMORY_BASE}, kind = .Reserved},
    .{range = .{base = cast[boot_info.PhysicalAddress](MEMORY_BASE), size = MEMORY_SIZE}, kind = .Usable},
]

/**
 * Give the direct map's offset that makes MEMORY_BASE land at the start of the stand-in memory.
 *
 * @param memory The stand-in memory, only its address used.
 * @return What's added to a physical address in it to reach its byte in memory.
 */
offset_of :: fn(memory: ptr[mut Memory]) -> u64 {
    return cast[u64](&memory[0]) - MEMORY_BASE
}

/**
 * Make a frame allocator of the stand-in memory, its failure points as SLOPOS_FAIL asks (robustness/hosted).
 *
 * @param t The test's state, which a failure is recorded in.
 * @param memory The stand-in memory, which the allocator's state and blocks are in; it has to outlive the allocator.
 * @return The allocator, whose failure points the caller reports with hosted_faults.report_points; Error if make
 *     refused the memory, the failure recorded.
 */
made_allocator :: fn(t: ptr[mut testing.T], memory: ptr[mut Memory]) -> Result[frames.FrameAllocator, testing.Stopped] {
    made :: frames.make(REGIONS, offset_of(memory))
    allocator := testing.require_ok(t, made, "256 KiB of usable memory makes a frame allocator")?
    allocator.faults.spec = hosted_faults.point_spec()
    return .Ok(allocator)
}

/**
 * Allocate 64 objects from a new cache of 64-byte objects: a slab's 63, and one from a second slab.
 *
 * @param t The test's state, which a failure is recorded in.
 * @param cache The cache, new, of 64-byte objects aligned to 8.
 * @param allocator The frame allocator its slabs come from.
 * @param offset The direct map's offset, for the objects' physical addresses.
 * @param objects Where the objects' addresses go, in the order allocated.
 * @return Ok once all 64 are allocated, each aligned to its size; Error at the first that isn't, the failure recorded.
 */
fill :: fn(t: ptr[mut testing.T], cache: ptr[mut slab.SlabCache], allocator: ptr[mut frames.FrameAllocator], offset: u64,
        objects: ptr[mut u64[64]]) -> testing.Outcome {
    for i in 0..<64 {
        allocated :: slab.allocate(cache, allocator)
        object :: testing.require_ok(t, allocated, "there are frames for two slabs")?
        testing.require_eq(t, (object - offset) % 64, 0, "64-byte objects are 64 bytes apart from a frame's base")?
        objects^[i] = object
    }
    return .Ok
}

a_cache_of_64_byte_objects_fits_63_to_a_frame #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    cache := slab.make_cache(64, 8)
    testing.expect_eq(t, cache.object_size, 64, "the size asked for, already aligned")
    testing.expect_eq(t, cache.slab_order, 0, "a frame holds enough of them")
    testing.expect_eq(t, cache.capacity, 63, "64 to a frame, less the one the slab's header at its end takes")
    return .Ok
}

objects_come_in_order_from_a_slab_then_from_a_new_one #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    cache := slab.make_cache(64, 8)
    objects : u64[64]
    fill(t, &cache, &allocator, offset_of(&memory), &objects)?
    testing.expect_eq(t, objects[1], objects[0] + 64, "the first slab's objects are in order from its base")
    testing.expect_eq(t, objects[62], objects[0] + 62 * 64, "up to its 63rd")
    testing.expect_eq(t, cache.slab_count, 2, "the 64th is from a second slab")
    testing.expect_eq(t, cache.allocated, 64, "every object is counted")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES - 2, "a frame for each slab")
    testing.expect_eq(t, cache.partial.count, 1, "the second slab is partly used, the first full")
    return .Ok
}

the_last_object_freed_is_the_next_handed_out #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    cache := slab.make_cache(64, 8)
    objects : u64[64]
    fill(t, &cache, &allocator, offset_of(&memory), &objects)?
    slab.free(&cache, &allocator, objects[10])
    testing.expect_eq(t, cache.partial.count, 2, "freeing from the full slab makes it partly used")
    again :: slab.allocate(&cache, &allocator)
    testing.expect_eq(t, testing.require_ok(t, again, "an object was just freed")?, objects[10], "the last object freed is handed out first")
    return .Ok
}

emptied_slabs_go_back_but_one #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    cache := slab.make_cache(64, 8)
    objects : u64[64]
    fill(t, &cache, &allocator, offset_of(&memory), &objects)?
    slab.free(&cache, &allocator, objects[63])
    testing.expect_eq(t, cache.empty.count, 1, "the second slab, emptied, is kept")
    testing.expect_eq(t, cache.slab_count, 2, "so there are still two")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES - 2, "and its frame isn't given back")
    for i in 0..<63 {
        slab.free(&cache, &allocator, objects[i])
    }
    testing.expect_eq(t, cache.empty.count, 1, "with the first emptied too, only one empty slab is kept")
    testing.expect_eq(t, cache.partial.count, 0, "none is partly used")
    testing.expect_eq(t, cache.slab_count, 1, "the other went back")
    testing.expect_eq(t, cache.allocated, 0, "every object is free")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES - 1, "its frame is the frame allocator's again")
    return .Ok
}

a_magazine_takes_and_gives_back_half_its_size_at_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    cache := slab.make_cache(64, 8)
    allocated :: slab.allocate(&cache, &allocator)
    object := testing.require_ok(t, allocated, "there's a frame for a slab")?
    magazine : slab.Magazine
    took :: slab.take(&magazine, &cache, &allocator)
    first :: testing.require_ok(t, took, "an empty magazine fills from the cache")?
    testing.expect_eq(t, magazine.count, slab.MAGAZINE_BATCH - 1, "it takes a batch, half its size, and hands one out")
    testing.expect_eq(t, cache.allocated, slab.MAGAZINE_BATCH + 1, "the batch and the object before it are allocated")
    for i in 0..<slab.MAGAZINE_SIZE - slab.MAGAZINE_BATCH + 1 {
        slab.give_back(&magazine, &cache, &allocator, object)
        again :: slab.allocate(&cache, &allocator)
        object = testing.require_ok(t, again, "the slab has objects to spare")?
    }
    testing.expect_eq(t, magazine.count, slab.MAGAZINE_SIZE, "objects given back fill it")
    slab.give_back(&magazine, &cache, &allocator, first)
    testing.expect_eq(t, magazine.count, slab.MAGAZINE_SIZE - slab.MAGAZINE_BATCH + 1,
        "full, it gives a batch back to the cache before taking one more")
    slab.drain(&magazine, &cache, &allocator)
    slab.free(&cache, &allocator, object)
    testing.expect_eq(t, magazine.count, 0, "draining empties it")
    testing.expect_eq(t, cache.allocated, 0, "into the cache, every object free")
    testing.expect_eq(t, cache.slab_count, 1, "the one slab, empty, is kept")
    return .Ok
}

big_objects_get_slabs_of_several_frames_until_there_are_none #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    big := slab.make_cache(2000, 16)
    testing.expect_eq(t, big.object_size, 2000, "the size asked for, already aligned to 16")
    testing.expect_eq(t, big.slab_order, 2, "four frames hold enough of them")
    testing.expect_eq(t, big.capacity, 8, "16 KiB, less the header, holds 8 of 2000 bytes")
    count : u64 = 0
    loop {
        count += 1
    }
    while slab.allocate(&big, &allocator) is_ok
    // Every block of 4 frames left became a slab
    testing.expect_eq(t, count, big.slab_count * big.capacity, "every slab made was filled before allocation failed")
    testing.expect_ge(t, big.slab_count, 10, "every block of four free frames became a slab")
    testing.expect(t, frames.allocate(&allocator, 2) is_error, "so none is left: running out of frames is an error")
    return .Ok
}

/**
 * Run the tests, reporting to standard output.
 *
 * @return How many failed: 0 when every one passed.
 */
run_tests :: fn() -> int {
    return cast[int](testing.run(#insert testing.tests_of(compiler.load_package(".")), testing.STANDARD_OUTPUT))
}

/**
 * Run the tests, with fault injection as SLOPOS_FAIL asks (robustness/hosted, tools/unit_tests.py --robustness).
 *
 * @return How many tests failed: 0 when every one passed.
 */
main :: fn() -> int {
    return hosted_faults.run(run_tests)
}
