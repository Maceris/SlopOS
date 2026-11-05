package kernel

import runtime from "base"
import testing from "std"

/** How many blocks test_heap allocates at once. */
HEAP_TEST_BLOCKS :: 200

/**
 * Run test_heap: the kernel heap, through the context's allocator, with blocks of many sizes, small and large, and
 * small blocks aligned beyond their size; reported to the kernel's log.
 */
test_heap :: fn() {
    _ = run_tests("test_heap", testing.Test.[
        .{name = "heap_blocks_keep_their_contents_grown_shrunk_and_freed", run = heap_blocks_keep_their_contents_grown_shrunk_and_freed},
        .{name = "over_aligned_heap_blocks_come_aligned", run = over_aligned_heap_blocks_come_aligned}])
}

/**
 * Check the kernel heap with HEAP_TEST_BLOCKS blocks of many sizes, each filled with its own bytes: every block has to
 * come zeroed and aligned to 16 bytes, keep its contents while the others are allocated, and keep them when it grows
 * or shrinks, with what it grows by zeroed.
 *
 * @param t The test's state.
 * @return Ok once it's run, every block freed; Error if a block couldn't be allocated or resized, when what was
 *     allocated is left unfreed.
 */
heap_blocks_keep_their_contents_grown_shrunk_and_freed #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    addresses : u64[HEAP_TEST_BLOCKS]
    sizes : u64[HEAP_TEST_BLOCKS]
    for i in 0..<HEAP_TEST_BLOCKS {
        size :: heap_test_size(cast[u64](i), 0)
        bytes, error :: runtime.new_array(u8, cast[usize](size))
        testing.require(t, error == null, "the heap has room for every block, a few hundred KiB in all")?
        address :: cast[u64](bytes.data)
        testing.expect(t, is_zeroed(address, 0, size), "the heap gives every block zeroed")
        testing.expect_eq(t, address % 16, 0, "the heap aligns every block to 16 bytes")
        fill(address, size, cast[u64](i))
        addresses[i] = address
        sizes[i] = size
    }
    lost :: first_changed(addresses, sizes)
    testing.expect_none(t, lost, "no block's bytes change while the others are allocated, as no two blocks overlap")
    // Every other block changes size: what it kept is the same, and what it grew by is zeroed
    for i in 0..<HEAP_TEST_BLOCKS {
        if i % 2 == 1 {
            continue
        }
        old_size :: sizes[i]
        size :: heap_test_size(cast[u64](i), 1)
        bytes, error :: context.allocator.function(context.allocator.data, cast[usize](size), 1, cast[rawptr](addresses[i]),
            cast[usize](old_size))
        testing.require(t, error == null, "the heap has room to resize every block, freeing each one's old space")?
        address :: cast[u64](bytes.data)
        kept :: if size < old_size { size } else { old_size }
        testing.expect(t, holds(address, kept, cast[u64](i)), "a block resized keeps the bytes it had, up to its new size")
        testing.expect(t, is_zeroed(address, kept, size), "what a block grows by comes zeroed")
        fill(address, size, cast[u64](i))
        addresses[i] = address
        sizes[i] = size
    }
    lost_after :: first_changed(addresses, sizes)
    testing.expect_none(t, lost_after, "no block's bytes change when others are resized, as no two blocks overlap after either")
    for i in 0..<HEAP_TEST_BLOCKS {
        _, freed :: context.allocator.function(context.allocator.data, 0, 1, cast[rawptr](addresses[i]), cast[usize](sizes[i]))
    }
    return .Ok
}

/**
 * Check blocks of 24 bytes aligned to each power of two from 32 bytes to 64 KiB, each from the class or frame block
 * that's aligned enough, freeing each before the next.
 *
 * @param t The test's state.
 * @return Ok once it's run; Error at the first alignment with no block, when nothing is left allocated.
 */
over_aligned_heap_blocks_come_aligned #test :: fn(t: ptr[mut testing.T]) -> testing.Outcome {
    with {
        alignment : usize = 32
    }
    loop {
        bytes, error :: runtime.new_array_aligned(u8, 24, alignment)
        testing.require(t, error == null, "the heap has a block aligned to every power of two up to 64 KiB")?
        address :: cast[usize](bytes.data)
        testing.expect_eq(t, address % alignment, 0, "a block asked for aligned beyond its size comes aligned so")
        runtime.free_array_aligned(bytes, alignment)
        alignment *= 2
    }
    while alignment <= 65536
    return .Ok
}

/**
 * Find the first test block that no longer holds the bytes fill wrote in it.
 *
 * @param addresses Each block's address, readable for its size.
 * @param sizes Each block's size in bytes, in the same order; only as many blocks as both have are checked.
 * @return The first block's index whose bytes aren't heap_test_byte's for it; none if every block holds its own.
 */
first_changed :: fn(addresses: u64[], sizes: u64[]) -> usize? {
    for address, i in addresses {
        if i < sizes.count && !holds(address, sizes[i], cast[u64](i)) {
            return i
        }
    }
    return null
}

/**
 * Choose a test block's size: from 1 byte to a few KiB, and every 25th block bigger, in frames of its own.
 *
 * @param i The block's index, 0 to HEAP_TEST_BLOCKS - 1.
 * @param round 0 for the first allocation, 1 for the resize, which gives most blocks another size.
 * @return The size in bytes: 1 to 3000, or 20000 or 29000 for the big ones.
 */
heap_test_size :: fn(i: u64, round: u64) -> u64 {
    if (i + round) % 25 == 0 {
        return 20000 + round * 9000
    }
    return 1 + (i * 37 + round * 1500) % 3000
}

/**
 * Choose the byte a test block holds at an offset, so blocks differ and a shifted copy shows.
 *
 * @param block The block's index, any value; it only shifts the pattern, as (block * 7 + offset) % 251.
 * @param offset The byte's offset in the block.
 * @return The byte, 0 to 250.
 */
heap_test_byte :: fn(block: u64, offset: u64) -> u8 {
    return cast[u8]((block * 7 + offset) % 251)
}

/**
 * Fill a block with its test bytes, as heap_test_byte gives them.
 *
 * @param address The block's address, writable for size bytes.
 * @param size How many bytes to fill.
 * @param block The block's index, which picks its pattern; holds has to be given the same one.
 */
fill :: fn(address: u64, size: u64, block: u64) {
    for offset in 0..<size {
        cast[ptr[mut u8]](address + offset)^ = heap_test_byte(block, offset)
    }
}

/**
 * Tell whether a block still holds its test bytes, as fill wrote them.
 *
 * @param address The block's address, readable for size bytes.
 * @param size How many bytes to check, from the start.
 * @param block The block's index, the same one fill was given for it.
 * @return True if every byte is as heap_test_byte gives it.
 */
holds :: fn(address: u64, size: u64, block: u64) -> bool {
    for offset in 0..<size {
        if cast[ptr[u8]](address + offset)^ != heap_test_byte(block, offset) {
            return false
        }
    }
    return true
}

/**
 * Tell whether part of a block is all zeroes.
 *
 * @param address The block's address, readable from start to end; only read.
 * @param start The offset of the first byte to check.
 * @param end The offset just past the last byte to check; at or below start, nothing is checked.
 * @return True if every byte from start to end is 0.
 */
is_zeroed :: fn(address: u64, start: u64, end: u64) -> bool {
    for offset in start..<end {
        if cast[ptr[u8]](address + offset)^ != 0 {
            return false
        }
    }
    return true
}
