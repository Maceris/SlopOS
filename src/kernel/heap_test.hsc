package kernel

import runtime from "base"

/*
 * test_heap: blocks of many sizes from the context's allocator, the kernel heap, small and large,
 * each filled with its own bytes. Every block has to come zeroed and aligned, keep its contents while
 * the others are allocated, and keep them when it grows or shrinks, with what it grows by zeroed.
 * Small blocks aligned beyond their size have to come aligned too.
 */
HEAP_TEST_BLOCKS :: 200

test_heap :: fn() {
    addresses : u64[HEAP_TEST_BLOCKS]
    sizes : u64[HEAP_TEST_BLOCKS]
    for i in 0..<HEAP_TEST_BLOCKS {
        size :: heap_test_size(cast[u64](i), 0)
        bytes, error :: runtime.new_array(u8, cast[usize](size))
        if error != null {
            runtime.log_error("test_heap: no memory for a block of % bytes", size)
            return void
        }
        address :: cast[u64](bytes.data)
        if !is_zeroed(address, 0, size) || address % 16 != 0 {
            runtime.log_error("test_heap: a block of % bytes came unzeroed or misaligned", size)
            return void
        }
        fill(address, size, cast[u64](i))
        addresses[i] = address
        sizes[i] = size
    }
    for i in 0..<HEAP_TEST_BLOCKS {
        if !holds(addresses[i], sizes[i], cast[u64](i)) {
            runtime.log_error("test_heap: block % lost its contents", i)
            return void
        }
    }
    // Every other block changes size: what it kept is the same, and what it grew by is zeroed
    for i in 0..<HEAP_TEST_BLOCKS {
        if i % 2 == 1 {
            continue
        }
        old_size :: sizes[i]
        size :: heap_test_size(cast[u64](i), 1)
        bytes, error :: context.allocator.function(context.allocator.data, cast[usize](size), 1, cast[rawptr](addresses[i]),
            cast[usize](old_size))
        if error != null {
            runtime.log_error("test_heap: no memory to resize a block to % bytes", size)
            return void
        }
        address :: cast[u64](bytes.data)
        kept :: if size < old_size { size } else { old_size }
        if !holds(address, kept, cast[u64](i)) || !is_zeroed(address, kept, size) {
            runtime.log_error("test_heap: block % changed going from % to % bytes", i, old_size, size)
            return void
        }
        fill(address, size, cast[u64](i))
        addresses[i] = address
        sizes[i] = size
    }
    for i in 0..<HEAP_TEST_BLOCKS {
        if !holds(addresses[i], sizes[i], cast[u64](i)) {
            runtime.log_error("test_heap: block % lost its contents after resizing", i)
            return void
        }
        _, freed :: context.allocator.function(context.allocator.data, 0, 1, cast[rawptr](addresses[i]), cast[usize](sizes[i]))
    }
    if !over_aligned_blocks() {
        return void
    }
    runtime.log_info("test_heap: % blocks kept their contents, grown, shrunk and freed", HEAP_TEST_BLOCKS)
}

// 24 bytes aligned to 32 bytes up to 64 KiB, each from the class or frame block that's aligned enough.
over_aligned_blocks :: fn() -> bool {
    with {
        alignment : usize = 32
    }
    loop {
        bytes, error :: runtime.new_array_aligned(u8, 24, alignment)
        if error != null || cast[usize](bytes.data) % alignment != 0 {
            runtime.log_error("test_heap: no block of 24 bytes aligned to %", alignment)
            return false
        }
        runtime.free_array_aligned(bytes, alignment)
        alignment *= 2
    }
    while alignment <= 65536
    return true
}

// Sizes from 1 byte to a few KiB, and every 25th block bigger, in frames of its own.
heap_test_size :: fn(i: u64, round: u64) -> u64 {
    if (i + round) % 25 == 0 {
        return 20000 + round * 9000
    }
    return 1 + (i * 37 + round * 1500) % 3000
}

heap_test_byte :: fn(block: u64, offset: u64) -> u8 {
    return cast[u8]((block * 7 + offset) % 251)
}

fill :: fn(address: u64, size: u64, block: u64) {
    for offset in 0..<size {
        cast[ptr[mut u8]](address + offset)^ = heap_test_byte(block, offset)
    }
}

holds :: fn(address: u64, size: u64, block: u64) -> bool {
    for offset in 0..<size {
        if cast[ptr[u8]](address + offset)^ != heap_test_byte(block, offset) {
            return false
        }
    }
    return true
}

is_zeroed :: fn(address: u64, start: u64, end: u64) -> bool {
    for offset in start..<end {
        if cast[ptr[u8]](address + offset)^ != 0 {
            return false
        }
    }
    return true
}
