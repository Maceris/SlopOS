package libc

/*
 * stdlib.h's memory (decisions/0201, 20l): blocks from the program's Hemera heap, the allocator of the context run
 * called C with. Each block has a header just before it, HEADER_BYTES, saying how big the whole allocation is and how
 * far before the block it starts, which is also the alignment it was made with, so free and realloc find it. Blocks
 * are zeroed, as base's allocator gives them; C mustn't count on that.
 */

import runtime from "base:runtime"

/** A block's header's bytes, and malloc's alignment: 16, as C's max_align_t has. */
HEADER_BYTES : usize : 16

/** A block's header, the HEADER_BYTES just before it. */
Header :: struct {
    /** The whole allocation's bytes, the header and any padding before it included. */
    total : u64,
    /** How far before the block the allocation starts, in bytes, which is the alignment it was made with. */
    offset : u64,
}

#assert size_of(Header) == HEADER_BYTES

/**
 * Allocate a block aligned to alignment, with its header before it.
 *
 * @param size The block's bytes; 0 makes a block of none, still unique and freeable.
 * @param alignment Its alignment in bytes: a power of two, at least HEADER_BYTES.
 * @return The block; null, errno ENOMEM, without the memory or for a size that overflows.
 */
allocate :: fn(size : usize, alignment : usize) -> ptr[mut u8]? {
    total :: size + alignment
    if total < size {
        set_errno(E_NOMEM)
        return null
    }
    made, error :: runtime.new_array_aligned(u8, total, alignment)
    if error != null || made.count == 0 {
        set_errno(E_NOMEM)
        return null
    }
    block :: at_offset(&made[0], alignment)
    header :: cast[ptr[mut Header]](cast[usize](block) - HEADER_BYTES)
    header^ = Header.{total = cast[u64](total), offset = cast[u64](alignment)}
    return block
}

/**
 * Find a block's header.
 *
 * @param block A block malloc, calloc, realloc or aligned_alloc gave, not yet freed.
 * @return Its header.
 */
header_of :: fn(block : ptr[u8]) -> ptr[Header] {
    return cast[ptr[Header]](cast[usize](block) - HEADER_BYTES)
}

/**
 * Allocate a block from the program's heap.
 *
 * @param size The block's bytes; 0 gives a block of none, which free takes.
 * @return The block, 16-byte aligned, the caller's until free; NULL, errno ENOMEM, without the memory.
 */
malloc #export #calling_convention(.c) :: fn(size : usize) -> ptr[mut u8]? {
    return allocate(size, HEADER_BYTES)
}

/**
 * Allocate a zeroed block for count items of size bytes each.
 *
 * @param count How many items.
 * @param size Each one's bytes.
 * @return The block, zeroed, 16-byte aligned, the caller's until free; NULL, errno ENOMEM, without the memory or when
 *     count times size overflows.
 */
calloc #export #calling_convention(.c) :: fn(count : usize, size : usize) -> ptr[mut u8]? {
    if size != 0 && count > ~cast[usize](0) / size {
        set_errno(E_NOMEM)
        return null
    }
    // base's allocator zeroes every block it gives
    return allocate(count * size, HEADER_BYTES)
}

/**
 * Allocate a block aligned to more than malloc's 16 bytes.
 *
 * @param alignment The alignment in bytes: a power of two; below 16 gives 16.
 * @param size The block's bytes.
 * @return The block, the caller's until free; NULL with errno EINVAL for an alignment that isn't a power of two, or
 *     ENOMEM without the memory.
 */
aligned_alloc #export #calling_convention(.c) :: fn(alignment : usize, size : usize) -> ptr[mut u8]? {
    if alignment == 0 || (alignment & (alignment - 1)) != 0 {
        set_errno(E_INVAL)
        return null
    }
    return allocate(size, if alignment < HEADER_BYTES { HEADER_BYTES } else { alignment })
}

/**
 * Allocate an aligned block, POSIX's way.
 *
 * @param made Where the block goes; left as it was on failure.
 * @param alignment As aligned_alloc's, and a multiple of a pointer's size.
 * @param size The block's bytes.
 * @return 0 once made is set; EINVAL for an alignment that isn't a power of two at least 8, ENOMEM without the
 *     memory. errno isn't set, as POSIX says.
 */
posix_memalign #export #calling_convention(.c) :: fn(made : ptr[mut ptr[mut u8]?], alignment : usize, size : usize) -> i32 {
    if alignment < 8 || (alignment & (alignment - 1)) != 0 {
        return E_INVAL
    }
    made^ = allocate(size, if alignment < HEADER_BYTES { HEADER_BYTES } else { alignment }) or_return E_NOMEM
    return 0
}

/**
 * Give a block back to the program's heap.
 *
 * @param block A block malloc, calloc, realloc or aligned_alloc gave, not yet freed, which mustn't be used after; NULL
 *     does nothing.
 */
free #export #calling_convention(.c) :: fn(block : ptr[u8]?) {
    given :: block or_return void
    header :: header_of(given)
    start :: cast[ptr[mut u8]](cast[usize](given) - cast[usize](header.offset))
    runtime.free_array_aligned(view_of(start, cast[usize](header.total)), cast[usize](header.offset))
}

/**
 * Make a block bigger or smaller, keeping what it holds, up to the smaller size.
 *
 * @param block A block as free takes, or NULL for a new one, as malloc.
 * @param size Its new bytes. 0 frees block and gives a new block of none.
 * @return The block, moved, the caller's until free; NULL, errno ENOMEM, without the memory, block left as it was.
 */
realloc #export #calling_convention(.c) :: fn(block : ptr[u8]?, size : usize) -> ptr[mut u8]? {
    given :: block or_return malloc(size)
    header :: header_of(given)
    held :: cast[usize](header.total - header.offset)
    if size <= held && size + 1024 > held {
        // Small changes keep the block where it is
        return cast[ptr[mut u8]](given)
    }
    moved :: allocate(size, cast[usize](header.offset)) or_return null
    kept :: if size < held { size } else { held }
    into :: view_of(moved, kept)
    from :: view_of(given, kept)
    for i in 0..<into.count {
        if i < from.count {
            into[i] = from[i]
        }
    }
    free(given)
    return moved
}
