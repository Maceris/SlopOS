/**
 * The frame allocator's tests, as a hosted program (tools/unit_tests.py, decisions/0175): main runs them and returns
 * how many failed.
 *
 * A buffer on each test's stack stands in for physical memory from 256 KiB to 512 KiB, reached through a direct map
 * whose offset makes those addresses land in it. The allocator takes the first frame for its state bytes, which leaves
 * frames 65 to 127: free blocks at 65 (order 0), 66 (1), 68 (2), 72 (3), 80 (4) and 96 (5).
 */
package frames_test

import compiler from "base"
import testing from "std"
import frames from ".."
import boot_info from "../../../boot_info"
import hosted_faults from "../../../robustness/hosted"

/** The physical address the stand-in memory starts at: 256 KiB, frame 64. */
MEMORY_BASE : u64 : 0x40000
/** The stand-in memory's size in bytes: 256 KiB, 64 frames, the size of Memory. */
MEMORY_SIZE : u64 : 0x40000
/** The frames the allocator has free once it has made: 64, less the one its state bytes take. */
FREE_FRAMES :: 63

/** The stand-in memory, MEMORY_SIZE bytes, on a test's stack so everything made in it is gone when the test returns. */
Memory :: alias u64[32768]

/**
 * The memory map the tests' allocator is made from: reserved memory below MEMORY_BASE, then MEMORY_SIZE bytes usable.
 *
 * A constant, not on the stack, so the allocator made from it isn't held to a test's stack frame.
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
 * Make an allocator of the stand-in memory, its failure points as SLOPOS_FAIL asks (robustness/hosted).
 *
 * @param t The test's state, which a failure is recorded in.
 * @param memory The stand-in memory, which the allocator's state and blocks are in; it has to outlive the allocator.
 * @return The allocator, whose failure points the caller reports with hosted_faults.report_points; Error if make
 *     refused the memory, the failure recorded.
 */
made_allocator :: fn(t: ptr[mut testing.T], memory: ptr[mut Memory]) -> Result[frames.FrameAllocator, testing.Stopped] {
    made :: frames.make(REGIONS, offset_of(memory))
    allocator := testing.require_ok(t, made, "256 KiB of usable memory makes an allocator")?
    allocator.faults.spec = hosted_faults.point_spec()
    return .Ok(allocator)
}

a_new_allocator_has_every_frame_free_but_its_state_bytes #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    testing.expect_eq(t, allocator.total_frames, FREE_FRAMES, "64 frames, less the one its state bytes take")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES, "and all of them free")
    testing.expect_eq(t, allocator.frame_count, 128, "frames are counted from 0 to the memory's end, 512 KiB")
    testing.expect_eq(t, allocator.lists[0].count, 1, "frame 65 is the one free block of order 0")
    testing.expect_eq(t, allocator.lists[5].count, 1, "frames 96 to 127 are the one free block of order 5")
    testing.expect_eq(t, allocator.lists[6].count, 0, "nothing is aligned to 64 frames and free")
    return .Ok
}

the_smallest_block_that_fits_is_given #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    allocated_single :: frames.allocate(&allocator, 0)
    single :: testing.require_ok(t, allocated_single, "a frame is free")?
    allocated_big :: frames.allocate(&allocator, 5)
    big :: testing.require_ok(t, allocated_big, "a block of 32 frames is free")?
    testing.expect_eq(t, cast[u64](single), 0x41000, "frame 65, the order 0 block, not split from a larger one")
    testing.expect_eq(t, cast[u64](big), 0x60000, "frame 96, the order 5 block")
    testing.expect(t, frames.allocate(&allocator, 5) is_error, "the order 5 block was the only one")
    frames.free(&allocator, big, 5)
    frames.free(&allocator, single, 0)
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES, "freeing them gives every frame back")
    return .Ok
}

frames_freed_merge_back_with_their_buddies #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    // Every frame, one at a time, then freed in an order that merges them back
    addresses : boot_info.PhysicalAddress[FREE_FRAMES]
    for index in 0..<FREE_FRAMES {
        allocated :: frames.allocate(&allocator, 0)
        addresses[index] = testing.require_ok(t, allocated, "each of the free frames can be allocated alone, splitting blocks")?
    }
    testing.expect_eq(t, allocator.free_frames, 0, "every frame is allocated")
    testing.expect(t, frames.allocate(&allocator, 0) is_error, "so there's none to give")
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
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES, "every frame is free again")
    for order in 0..<6 {
        testing.expect_eq(t, allocator.lists[order].count, 1, "buddies merged back into the blocks the allocator started with")
    }
    return .Ok
}

a_block_written_to_comes_back_zeroed #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    allocated :: frames.allocate(&allocator, 1)
    dirty :: testing.require_ok(t, allocated, "a block of two frames is free")?
    bytes :: cast[ptr[mut u64]](frames.virtual_of(&allocator, dirty) + 8)
    bytes^ = 0xdead
    frames.free(&allocator, dirty, 1)
    zeroed :: frames.allocate_zeroed(&allocator, 1)
    clean :: testing.require_ok(t, zeroed, "the block freed is free again")?
    testing.expect_eq(t, cast[u64](clean), cast[u64](dirty), "the block freed is the one given again")
    testing.expect_eq(t, cast[ptr[u64]](frames.virtual_of(&allocator, clean) + 8)^, 0, "what was written to it is zeroed")
    frames.free(&allocator, clean, 1)
    return .Ok
}

a_cpus_cache_takes_and_gives_back_half_its_size_at_once #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    allocator := made_allocator(t, &memory)?
    defer hosted_faults.report_points(&allocator.faults)
    cache : frames.FrameCache
    took :: frames.take_frame(&cache, &allocator)
    first :: testing.require_ok(t, took, "an empty cache fills from the allocator")?
    testing.expect_eq(t, cache.count, frames.FRAME_CACHE_BATCH - 1, "it takes a batch, half its size, and hands one out")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES - frames.FRAME_CACHE_BATCH, "the batch is the allocator's no more")
    taken : boot_info.PhysicalAddress[frames.FRAME_CACHE_SIZE]
    for i in 0..<frames.FRAME_CACHE_SIZE {
        allocated :: frames.allocate(&allocator, 0)
        taken[i] = testing.require_ok(t, allocated, "the allocator has a cache's worth of frames besides")?
    }
    for i in 0..<frames.FRAME_CACHE_SIZE {
        frames.give_frame(&cache, &allocator, taken[i])
    }
    // 15 left and 32 given: full after 17, so the 18th gives 16 back first, leaving 31 once all are in
    testing.expect_eq(t, cache.count, 31, "full after 17, the 18th gives a batch back first, leaving 31 once all are in")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES - frames.FRAME_CACHE_SIZE, "the batch given back is the allocator's")
    frames.give_frame(&cache, &allocator, first)
    frames.drain_frames(&cache, &allocator)
    testing.expect_eq(t, cache.count, 0, "draining empties the cache")
    testing.expect_eq(t, allocator.free_frames, FREE_FRAMES, "into the allocator")
    for order in 0..<6 {
        testing.expect_eq(t, allocator.lists[order].count, 1, "the cache's frames merged into their buddies, every list as it was")
    }
    return .Ok
}

order_for_gives_the_smallest_order_that_holds_a_size #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    testing.expect_eq(t, frames.order_for(1), 0, "a byte takes a frame")
    testing.expect_eq(t, frames.order_for(4096), 0, "a frame's worth takes a frame")
    testing.expect_eq(t, frames.order_for(4097), 1, "a byte more takes two")
    testing.expect_eq(t, frames.order_for(28672), 3, "seven frames take eight")
    return .Ok
}

too_little_memory_for_the_state_bytes_makes_no_allocator #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    memory : Memory
    tiny := boot_info.MemoryRegion.[
        .{range = .{base = cast[boot_info.PhysicalAddress](0x1000000000), size = 0x1000}, kind = .Usable},
    ]
    testing.expect(t, frames.make(tiny, offset_of(&memory)) is_error, "one frame at 64 GiB has no room for its own state bytes")
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
