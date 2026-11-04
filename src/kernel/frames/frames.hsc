/*
 * The physical frame allocator (roadmap M2, knowledge/design/kernel.md §2, Physical memory): a
 * buddy allocator over the RAM BootInfo's memory map gives the kernel, safe to use from every CPU.
 *
 * Memory comes in blocks of 2^order frames, aligned to their size, from one frame (order 0) to
 * 1 GiB (MAX_ORDER). A block's buddy is the other half of the block twice its size; freeing a
 * block whose buddy is free merges them, so free memory stays in the largest blocks it can.
 *
 * Each frame has a state byte, in an array the allocator carves from the memory it's given, that
 * says whether it starts a free or allocated block, and of which order. Only the first frame of a
 * block says anything; the rest of a block's bytes are left as they are. Free blocks are linked
 * into one list per order through their own first bytes, reached through the direct map, so a
 * buddy is taken off its list in constant time.
 *
 * In front of it, each CPU can keep a FrameCache of single frames, which it takes from and gives
 * to without the lock, refilled or emptied half a cache at a time under it, like the slab
 * allocator's magazines. Frames in a cache count as allocated.
 */
/**
 * The physical frame allocator: a buddy allocator, with a per-CPU cache of single frames in front of it.
 *
 * SPEC: Knuth, The Art of Computer Programming Vol. 1, §2.5 (the buddy system).
 * SPEC: Bonwick and Adams, "Magazines and Vmem" (USENIX 2001), §3 (the magazine layer, here for frames).
 */
package frames

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import boot_info from "../../boot_info"
import robustness from "../../robustness"

/** A frame's size in bytes: 4 KiB, x86-64's smallest page. */
FRAME_SIZE : u64 : 4096
/** The most single frames a FrameCache holds. */
FRAME_CACHE_SIZE :: 32
/** How many frames a FrameCache takes from the allocator when it's empty, or gives back when it's full. */
FRAME_CACHE_BATCH :: 16
/** log2 of FRAME_SIZE: a physical address shifted right by it is its frame number. */
FRAME_SHIFT : u64 : 12
/** The largest block's order: 2^18 frames, 1 GiB, the largest page x86-64 maps. */
MAX_ORDER : u64 : 18
/** How many orders there are, 0 to MAX_ORDER, and so how many free lists. */
ORDER_COUNT :: 19

// What a frame's state byte says, for the first frame of a block. The order is in the low bits.
/** The first frame of a free block, on its order's list; the block's order is ORed into the low bits. */
STATE_FREE : u8 : 0x40
/**
 * The first frame of an allocated block, its order ORed into the low bits; with order 0, also each frame of a block
 * from allocate_frames, and a single frame handed out by take_frame.
 */
STATE_ALLOCATED : u8 : 0x80
/**
 * A single frame in a CPU's FrameCache: neither free nor handed out, so a frame given back twice, to a cache or to the
 * allocator, fails an assertion where it's given rather than being handed out twice later (decisions/0145).
 */
STATE_CACHED : u8 : 0x20
/** Not the first frame of a block: inside one, or memory the allocator doesn't own. */
STATE_NONE : u8 : 0

/** Why a block of frames couldn't be had. */
FrameError :: enum {
    /**
     * No free block of that order or larger (for allocate_below, none ending low enough), or fault injection failed
     * this pass. Nothing was taken.
     */
    OutOfMemory,
}

/** Why a frame allocator couldn't be made. */
MakeError :: enum {
    /** No usable region has room for the state array, one byte per frame up to the end of RAM. */
    NoRoomForState,
}

/**
 * A free block's first bytes, linking it into its order's list, written into the free memory itself through the direct
 * map. 0 is no block: frame 0 is never usable.
 */
FreeBlock :: struct {
    /** The physical address of the next free block of the same order, 0 at the list's end. */
    next : u64,
    /** The physical address of the previous free block of the same order, 0 for the list's first. */
    previous : u64,
}

/** The free blocks of one order, a doubly linked list through the blocks' FreeBlock headers. */
FreeList :: struct {
    /** The physical address of the first block, 0 when the list is empty. */
    first : u64,
    /** How many blocks are on the list. */
    count : u64,
}

/** One CPU's stack of single free frames, by physical address. Used only by its CPU, so it needs no lock. */
FrameCache :: struct {
    /** How many frames it holds, 0 to FRAME_CACHE_SIZE: frames[0] to frames[count - 1], the last on top. */
    count : u64,
    /** The frames' physical addresses, each in STATE_CACHED, which the allocator counts as allocated. */
    frames : u64[FRAME_CACHE_SIZE],
}

/** The buddy allocator of physical frames, shared by every CPU under its lock. */
FrameAllocator :: struct {
    /** Guards the lists, the states of blocks on them, and the counts; FrameCaches are used without it. */
    lock : concurrency.SpinLock,
    /** The free blocks of each order, 0 to MAX_ORDER. */
    lists : FreeList[ORDER_COUNT],
    /** One state byte per frame, for frames 0 to frame_count, in the direct map, carved from usable memory by make. */
    states : mut u8[],
    /** How many frames there are states for: every frame below the end of RAM the allocator may ever own. */
    frame_count : u64,
    /** Where physical address 0 is in the direct map. */
    direct_map_offset : u64,
    /** Frames given to the allocator by add_range, in all; the state array's frames aren't counted. */
    total_frames : u64,
    /** Frames free now, on the lists; frames in FrameCaches count as allocated. */
    free_frames : u64,
    /**
     * Fault injection's state, with robustness=on (decisions/0096): here because everything in the kernel that can run
     * out reaches the frame allocator, so one place counts the passes through every failure point.
     */
    faults : robustness.Faults,
}

/**
 * Make an allocator for the Usable regions of a memory map.
 *
 * The state array, one byte for each frame below the end of any RAM the allocator may ever own (is_reclaimable_ram),
 * is carved from the start of the first Usable region with room, and zeroed; the rest of every Usable region is free.
 * Regions of other kinds can be added later with add_range, like boot memory once it's reclaimed. It runs before any
 * other CPU uses the allocator, so it takes no lock.
 *
 * @param memory_map BootInfo's memory map, its regions on frame boundaries. Only Usable regions are given to the
 *     allocator; every kind is_reclaimable_ram accepts counts toward how many frames there are states for.
 * @param direct_map_offset Where physical address 0 is in the kernel's direct map, which must already map all of RAM:
 *     the state array and the free lists are written through it.
 * @return The allocator, its free_frames every Usable frame but the state array's. Its lock and lists are used in
 *     place, so it's moved to where it lives before any CPU uses it, and not copied after.
 * @error NoRoomForState No Usable region is big enough for the state array.
 */
make :: fn(memory_map: boot_info.MemoryRegion[], direct_map_offset: u64) -> Result[FrameAllocator, MakeError] {
    // States for every frame up to the end of the last region that's RAM the kernel may ever get
    end : u64 = 0
    for region in memory_map {
        if is_reclaimable_ram(region.kind) {
            end = max_of(end, cast[u64](region.range.base) + region.range.size)
        }
    }
    frame_count :: end >> FRAME_SHIFT
    state_size :: round_up(frame_count, FRAME_SIZE)
    state_base : u64 = 0
    for region in memory_map {
        if region.kind == .Usable && region.range.size >= state_size {
            state_base = cast[u64](region.range.base)
            break
        }
    }
    if state_base == 0 {
        return .Error(.NoRoomForState)
    }

    allocator : FrameAllocator
    allocator.direct_map_offset = direct_map_offset
    allocator.frame_count = frame_count
    allocator.states = view_of(cast[ptr[mut u8]](direct_map_offset + state_base), cast[usize](frame_count))
    intrinsics.mem_zero(cast[mut rawptr](direct_map_offset + state_base), cast[usize](frame_count))
    for region in memory_map {
        if region.kind != .Usable {
            continue
        }
        start := cast[u64](region.range.base)
        region_end :: start + region.range.size
        if start == state_base {
            start += state_size
        }
        add_range(&allocator, start, region_end)
    }
    return .Ok(allocator)
}

/**
 * Tell whether memory of a kind is RAM the frame allocator may own, now or once it's reclaimed or given back.
 *
 * @param kind A memory map region's kind.
 * @return True for Usable, BootReclaimable, FirmwareTables and BootModule; false for every other kind, which the
 *     allocator never owns.
 */
is_reclaimable_ram :: fn(kind: boot_info.MemoryKind) -> bool {
    return kind == .Usable || kind == .BootReclaimable || kind == .FirmwareTables || kind == .BootModule
}

/**
 * Give the allocator a range of physical frames, which become free.
 *
 * The range is split into the largest blocks, aligned to their size, that fit, each freed as release frees one, so
 * they join whatever free blocks next to them they can. Takes the allocator's lock. Frames given twice, or memory that
 * isn't RAM, corrupt the allocator; that isn't checked.
 *
 * @param allocator The frame allocator, whose states must cover the range; its lock is taken, so the caller mustn't
 *     hold it, and its total_frames and free_frames grow by the range's frames.
 * @param start The physical address of the range's first byte, on a frame boundary.
 * @param end The physical address just past the range's last byte, on a frame boundary, and at most frame_count
 *     frames; one off a boundary or past the states stops the kernel with an assertion. At or below start, nothing is
 *     added.
 */
add_range :: fn(allocator: ptr[mut FrameAllocator], start: u64, end: u64) {
    runtime.assert(start % FRAME_SIZE == 0 && end % FRAME_SIZE == 0, "add_range takes frame boundaries")
    runtime.assert(end >> FRAME_SHIFT <= allocator.frame_count, "add_range is past the frames the allocator has states for")
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    with {
        frame := start >> FRAME_SHIFT
    }
    loop {
        // The largest block that starts here, aligned to its size, and fits
        order : u64 = 0
        loop {
            order += 1
        }
        while order < MAX_ORDER && frame % (cast[u64](1) << (order + 1)) == 0
            && frame + (cast[u64](1) << (order + 1)) <= end >> FRAME_SHIFT
        allocator.total_frames += cast[u64](1) << order
        release(allocator, frame, order)
        frame += cast[u64](1) << order
    }
    while frame < end >> FRAME_SHIFT
}

/**
 * Allocate a block of 2^order frames, aligned to its size.
 *
 * Takes the allocator's lock. The smallest free block at least that big is split down to size.
 *
 * @param allocator The frame allocator; its lock is taken, so the caller mustn't hold it, and a pass through its Frame
 *     fault point is counted.
 * @param order The block's order, 0 to MAX_ORDER; larger stops the kernel with an assertion.
 * @return The physical address of the block's first frame. The caller owns the block until it frees it with free and
 *     the same order. Its contents are whatever was there before.
 * @error OutOfMemory No free block of that order or larger, or fault injection failed the Frame point.
 */
allocate :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    if robustness.fails(&allocator.faults, .Frame) {
        return .Error(.OutOfMemory)
    }
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    return take_block(allocator, order)
}

/**
 * Allocate a block as allocate does, with the allocator's lock already held, and without fault injection.
 *
 * @param allocator The allocator, its lock held by the caller.
 * @param order The block's order, 0 to MAX_ORDER; larger stops the kernel with an assertion.
 * @return The physical address of the block's first frame, which the caller owns; its contents are what was there.
 * @error OutOfMemory No free block of that order or larger.
 */
take_block :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    runtime.assert(order <= MAX_ORDER, "allocate takes an order up to MAX_ORDER")
    // The smallest free block at least that big, split down to size
    found := order
    loop {
        found += 1
    }
    while found <= MAX_ORDER && allocator.lists[found].count == 0
    if found > MAX_ORDER {
        return .Error(.OutOfMemory)
    }
    return .Ok(split_down(allocator, take_first(allocator, found), found, order))
}

/**
 * Allocate a block of 2^order frames that ends at or below a physical address, for a device that reaches only that far.
 *
 * Like allocate, but each order's list, from order up, is walked for a block that ends at or below limit; a split
 * keeps the lower half, so any free block that starts low enough will do. Takes the allocator's lock, and walks whole
 * lists under it, so it's slower than allocate.
 *
 * @param allocator The frame allocator; its lock is taken, so the caller mustn't hold it, and a pass through its Frame
 *     fault point is counted.
 * @param order The block's order, 0 to MAX_ORDER; larger stops the kernel with an assertion.
 * @param limit The physical address the block may end at, at most (one past its last byte), or 0 for no limit, which
 *     is allocate.
 * @return The physical address of the block's first frame, aligned to the block's size. The caller owns the block until
 *     it frees it with free and the same order. Its contents are whatever was there before.
 * @error OutOfMemory No free block that big ends low enough, or fault injection failed the Frame point.
 */
allocate_below :: fn(allocator: ptr[mut FrameAllocator], order: u64, limit: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    runtime.assert(order <= MAX_ORDER, "allocate_below takes an order up to MAX_ORDER")
    if limit == 0 {
        return allocate(allocator, order)
    }
    if robustness.fails(&allocator.faults, .Frame) {
        return .Error(.OutOfMemory)
    }
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    size :: FRAME_SIZE << order
    for found in order..=MAX_ORDER {
        with {
            address := allocator.lists[found].first
        }
        loop {
            if address <= limit && size <= limit - address {
                frame :: address >> FRAME_SHIFT
                unlink(allocator, frame, found)
                return .Ok(split_down(allocator, frame, found, order))
            }
            address = block_of(allocator, address >> FRAME_SHIFT).next
        }
        while address != 0
    }
    return .Error(.OutOfMemory)
}

/**
 * Split a free block, already taken off its list, down to an order, and mark what's left allocated.
 *
 * The upper half of each split goes back on its order's list. The caller holds the allocator's lock.
 *
 * @param allocator The allocator, its lock held.
 * @param block The block's first frame number (not its address), off every list.
 * @param found The block's order now, at least order.
 * @param order The order wanted. With found equal to order, nothing is split.
 * @return The physical address of the block of 2^order frames at block's start, now allocated and counted out of
 *     free_frames.
 */
split_down :: fn(allocator: ptr[mut FrameAllocator], block: u64, found: u64, order: u64) -> boot_info.PhysicalAddress {
    with {
        size := found
    }
    loop {
        size -= 1
        // The upper half goes back on the list a size down
        push(allocator, block + (cast[u64](1) << size), size)
    }
    while size > order
    states :: allocator.states
    runtime.assert(block < cast[u64](states.count), "a free list held a frame the allocator has no state for")
    states[block] = STATE_ALLOCATED | cast[u8](order)
    allocator.free_frames -= cast[u64](1) << order
    return cast[boot_info.PhysicalAddress](block << FRAME_SHIFT)
}

/**
 * Allocate a block of 2^order frames, each frame marked allocated on its own, as take_frame's are.
 *
 * Each frame is then freed alone (give_frame, or free with order 0), and the block merges again once they all are: for
 * memory mapped with a large page, whose frames are given back one at a time (decisions/0127, 0129). Takes the
 * allocator's lock.
 *
 * @param allocator The frame allocator; its lock is taken, so the caller mustn't hold it, and a pass through its Frame
 *     fault point is counted.
 * @param order The block's order, 0 to MAX_ORDER; larger stops the kernel with an assertion.
 * @return The physical address of the block's first frame, aligned to the block's size. The caller owns each frame;
 *     their contents are whatever was there before.
 * @error OutOfMemory No free block of that order or larger, or fault injection failed the Frame point.
 */
allocate_frames :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    if robustness.fails(&allocator.faults, .Frame) {
        return .Error(.OutOfMemory)
    }
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    block :: take_block(allocator, order)?
    first :: cast[u64](block) >> FRAME_SHIFT
    states :: allocator.states
    for i in cast[u64](0)..<(cast[u64](1) << order) {
        if first + i < cast[u64](states.count) {
            states[first + i] = STATE_ALLOCATED
        }
    }
    return .Ok(block)
}

/**
 * Allocate a block of 2^order frames as allocate does, with its bytes zeroed.
 *
 * @param allocator The frame allocator; as for allocate, its lock is taken, so the caller mustn't hold it, and the
 *     block is zeroed through its direct map.
 * @param order The block's order, 0 to MAX_ORDER; larger stops the kernel with an assertion.
 * @return The physical address of the block's first frame, which the caller owns until it frees it with free and the
 *     same order. It's zeroed through the direct map, after the lock is let go.
 * @error OutOfMemory No free block of that order or larger, or fault injection failed the Frame point.
 */
allocate_zeroed :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    address :: allocate(allocator, order)?
    intrinsics.mem_zero(cast[mut rawptr](virtual_of(allocator, address)), cast[usize](FRAME_SIZE << order))
    return .Ok(address)
}

/**
 * Free a block that allocate, allocate_below or allocate_zeroed gave, merging it with its free buddies.
 *
 * Takes the allocator's lock. Freeing anything else (an address off a frame boundary or past the allocator's frames,
 * one that isn't the first frame of an allocated block, or another order) is a bug in the kernel, which an assertion
 * stops.
 *
 * @param allocator The frame allocator the block came from; its lock is taken, so the caller mustn't hold it.
 * @param address The block's physical address, as the allocation returned it; the caller gives up the block.
 * @param order The order it was allocated with; 0 for a single frame of allocate_frames' or take_frame's.
 */
free :: fn(allocator: ptr[mut FrameAllocator], address: boot_info.PhysicalAddress, order: u64) {
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    give_block(allocator, address, order)
}

/**
 * Free a block as free does, with the allocator's lock already held.
 *
 * @param allocator The allocator, its lock held by the caller.
 * @param address The block's physical address, the first frame of an allocated block; anything else stops the kernel
 *     with an assertion.
 * @param order The order it was allocated with, which its state byte must say.
 */
give_block :: fn(allocator: ptr[mut FrameAllocator], address: boot_info.PhysicalAddress, order: u64) {
    frame :: cast[u64](address) >> FRAME_SHIFT
    // One state per frame: states.count is frame_count
    states :: allocator.states
    runtime.assert(cast[u64](address) % FRAME_SIZE == 0 && frame < cast[u64](states.count), "free takes a frame the allocator owns")
    runtime.assert(order <= MAX_ORDER && states[frame] == STATE_ALLOCATED | cast[u8](order),
        "free takes an allocated block, with the order it was allocated with")
    release(allocator, frame, order)
}

/**
 * Take a single frame from the calling CPU's cache, refilling the cache from the allocator if it's empty.
 *
 * Takes no lock unless the cache is empty: then up to FRAME_CACHE_BATCH single frames are taken under the allocator's.
 *
 * @param cache The calling CPU's own FrameCache, which nothing else uses meanwhile: the caller doesn't move to another
 *     CPU, or reenter it from an interrupt, while this runs.
 * @param allocator The allocator the cache's frames belong to.
 * @return The frame's physical address, a single frame in STATE_ALLOCATED. The caller owns it until it gives it back
 *     with give_frame, or free with order 0. Its contents are whatever was there before.
 * @error OutOfMemory The cache was empty and the allocator had no free frame, or fault injection failed the Frame
 *     point.
 */
take_frame :: fn(cache: ptr[mut FrameCache], allocator: ptr[mut FrameAllocator]) -> Result[boot_info.PhysicalAddress, FrameError] {
    if robustness.fails(&allocator.faults, .Frame) {
        return .Error(.OutOfMemory)
    }
    if cache.count == 0 {
        concurrency.lock(&allocator.lock)
        defer concurrency.unlock(&allocator.lock)
        for i in 0..<FRAME_CACHE_BATCH {
            match take_block(allocator, 0) {
                case Ok(address) => {
                    cache.frames[i] = cast[u64](address)
                    set_state(allocator, cast[u64](address), STATE_CACHED)
                }
                case Error(error) => break
            }
            cache.count += 1
        }
        if cache.count == 0 {
            return .Error(.OutOfMemory)
        }
    }
    count :: cache.count
    runtime.assert(count >= 1 && count <= FRAME_CACHE_SIZE, "a frame cache holds up to FRAME_CACHE_SIZE frames")
    cache.count = count - 1
    taken :: cache.frames[count - 1]
    runtime.assert(state_of(allocator, taken) == STATE_CACHED, "a frame cache holds only frames it was given")
    set_state(allocator, taken, STATE_ALLOCATED)
    return .Ok(cast[boot_info.PhysicalAddress](taken))
}

/**
 * Give a single frame back to the calling CPU's cache, emptying FRAME_CACHE_BATCH frames of it into the allocator if
 * it's full.
 *
 * Takes no lock unless the cache is full: then its top FRAME_CACHE_BATCH frames are freed under the allocator's.
 *
 * @param cache The calling CPU's own FrameCache, which nothing else uses meanwhile.
 * @param allocator The allocator the frame belongs to.
 * @param address The frame's physical address: a single allocated frame, from take_frame, allocate_frames, or allocate
 *     with order 0. One that isn't in STATE_ALLOCATED, like one given back twice, stops the kernel with an assertion.
 *     The caller gives it up.
 */
give_frame :: fn(cache: ptr[mut FrameCache], allocator: ptr[mut FrameAllocator], address: boot_info.PhysicalAddress) {
    runtime.assert(state_of(allocator, cast[u64](address)) == STATE_ALLOCATED, "give_frame takes a single frame that's allocated")
    if cache.count == FRAME_CACHE_SIZE {
        concurrency.lock(&allocator.lock)
        defer concurrency.unlock(&allocator.lock)
        for i in FRAME_CACHE_SIZE - FRAME_CACHE_BATCH..<FRAME_CACHE_SIZE {
            set_state(allocator, cache.frames[i], STATE_ALLOCATED)
            give_block(allocator, cast[boot_info.PhysicalAddress](cache.frames[i]), 0)
        }
        cache.count = FRAME_CACHE_SIZE - FRAME_CACHE_BATCH
    }
    count :: cache.count
    runtime.assert(count < FRAME_CACHE_SIZE, "a frame cache that isn't full has room")
    cache.frames[count] = cast[u64](address)
    set_state(allocator, cast[u64](address), STATE_CACHED)
    cache.count = count + 1
}

/**
 * Give every frame in a cache back to the allocator, emptying it.
 *
 * Takes the allocator's lock.
 *
 * @param cache The cache, which nothing else uses meanwhile; empty afterwards.
 * @param allocator The allocator its frames belong to.
 */
drain_frames :: fn(cache: ptr[mut FrameCache], allocator: ptr[mut FrameAllocator]) {
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    count :: cache.count
    runtime.assert(count <= FRAME_CACHE_SIZE, "a frame cache holds up to FRAME_CACHE_SIZE frames")
    for i in 0..<count {
        set_state(allocator, cache.frames[i], STATE_ALLOCATED)
        give_block(allocator, cast[boot_info.PhysicalAddress](cache.frames[i]), 0)
    }
    cache.count = 0
}

/**
 * Read a single frame's state byte, without the lock.
 *
 * That's safe for the frames it's used on: a cached frame's byte is its CPU's alone, as only a frame given back twice
 * could be in two places, which the assertions catch.
 *
 * @param allocator The frame allocator, whose state array is read without its lock.
 * @param address The frame's physical address, on a frame boundary and below frame_count frames; anything else stops
 *     the kernel with an assertion.
 * @return Its state byte: STATE_FREE or STATE_ALLOCATED ORed with an order for a block's first frame, STATE_CACHED for
 *     a frame in a FrameCache, or STATE_NONE inside a block or for memory the allocator doesn't own.
 */
state_of :: fn(allocator: ptr[FrameAllocator], address: u64) -> u8 {
    frame :: address >> FRAME_SHIFT
    states :: allocator.states
    runtime.assert(address % FRAME_SIZE == 0 && frame < cast[u64](states.count), "a frame the allocator owns")
    return states[frame]
}

/**
 * Set a single frame's state byte, as state_of reads it, without the lock.
 *
 * @param allocator The frame allocator, whose state array is written without its lock, so the frame must be one only
 *     the caller can reach: one it's taking or giving back, or one in its own CPU's cache.
 * @param address The frame's physical address; one past the allocator's frames is ignored.
 * @param state The state byte to write.
 */
set_state :: fn(allocator: ptr[mut FrameAllocator], address: u64, state: u8) {
    frame :: address >> FRAME_SHIFT
    states :: allocator.states
    if frame < cast[u64](states.count) {
        states[frame] = state
    }
}

/**
 * Find the order of the smallest block that holds a number of bytes.
 *
 * @param size A size in bytes; 0 to FRAME_SIZE give order 0.
 * @return The order, 0 or more; above MAX_ORDER for a size bigger than the largest block, which callers check.
 */
order_for :: fn(size: u64) -> u64 {
    order : u64 = 0
    loop {
        order += 1
    }
    while FRAME_SIZE << order < size
    return order
}

/**
 * Find where physical memory is in the kernel's direct map.
 *
 * @param allocator The allocator, for its direct_map_offset.
 * @param address A physical address, which needn't be on a frame boundary.
 * @return The kernel virtual address the direct map has it at.
 */
virtual_of :: fn(allocator: ptr[FrameAllocator], address: boot_info.PhysicalAddress) -> u64 {
    return allocator.direct_map_offset + cast[u64](address)
}

/**
 * Put a block on its free list, merged with its buddy and its buddy's buddy and so on while they're free.
 *
 * Counts the block's frames into free_frames. The caller holds the allocator's lock.
 *
 * @param allocator The allocator, its lock held.
 * @param first_frame The block's first frame number (not its address), below frame_count; one past it stops the kernel
 *     with an assertion.
 * @param first_order The block's order, 0 to MAX_ORDER.
 */
release :: fn(allocator: ptr[mut FrameAllocator], first_frame: u64, first_order: u64) {
    states :: allocator.states
    runtime.assert(first_frame < cast[u64](states.count), "release takes a frame the allocator owns")
    allocator.free_frames += cast[u64](1) << first_order
    frame := first_frame
    order := first_order
    loop {
        buddy :: frame ~ (cast[u64](1) << order)
        if buddy >= cast[u64](states.count) || states[buddy] != STATE_FREE | cast[u8](order) {
            break
        }
        unlink(allocator, buddy, order)
        // The higher of the two is inside the merged block now, which starts at the lower
        if buddy > frame {
            states[buddy] = STATE_NONE
        }
        else {
            states[frame] = STATE_NONE
            frame = buddy
        }
        order += 1
    }
    while order < MAX_ORDER
    push(allocator, frame, order)
}

/**
 * Find a free block's FreeBlock header, in the block's own first bytes, through the direct map.
 *
 * @param allocator The allocator, for its direct_map_offset.
 * @param frame The block's first frame number (not its address).
 * @return A pointer to the header, meaningful while the block is free.
 */
block_of :: fn(allocator: ptr[FrameAllocator], frame: u64) -> ptr[mut FreeBlock] {
    return cast[ptr[mut FreeBlock]](allocator.direct_map_offset + (frame << FRAME_SHIFT))
}

/**
 * Put a free block first on its order's list, and mark it free.
 *
 * The caller holds the allocator's lock. It doesn't count free_frames; release does.
 *
 * @param allocator The allocator, its lock held.
 * @param frame The block's first frame number, below frame_count; its first bytes are overwritten with its header.
 * @param order The block's order, 0 to MAX_ORDER.
 */
push :: fn(allocator: ptr[mut FrameAllocator], frame: u64, order: u64) {
    states :: allocator.states
    runtime.assert(order <= MAX_ORDER && frame < cast[u64](states.count), "push takes a frame the allocator owns, and an order")
    list :: &allocator.lists[order]
    block :: block_of(allocator, frame)
    block.next = list.first
    block.previous = 0
    if list.first != 0 {
        block_of(allocator, list.first >> FRAME_SHIFT).previous = frame << FRAME_SHIFT
    }
    list.first = frame << FRAME_SHIFT
    list.count += 1
    states[frame] = STATE_FREE | cast[u8](order)
}

/**
 * Take a free block off its order's list, and mark its first frame STATE_NONE.
 *
 * The caller holds the allocator's lock. It doesn't count free_frames.
 *
 * @param allocator The allocator, its lock held.
 * @param frame The block's first frame number, which must be on that list.
 * @param order The block's order, 0 to MAX_ORDER.
 */
unlink :: fn(allocator: ptr[mut FrameAllocator], frame: u64, order: u64) {
    states :: allocator.states
    runtime.assert(order <= MAX_ORDER && frame < cast[u64](states.count), "unlink takes a frame the allocator owns, and an order")
    list :: &allocator.lists[order]
    block :: block_of(allocator, frame)
    if block.previous != 0 {
        block_of(allocator, block.previous >> FRAME_SHIFT).next = block.next
    }
    else {
        list.first = block.next
    }
    if block.next != 0 {
        block_of(allocator, block.next >> FRAME_SHIFT).previous = block.previous
    }
    list.count -= 1
    states[frame] = STATE_NONE
}

/**
 * Take the first block off an order's list.
 *
 * @param allocator The allocator, its lock held.
 * @param order The list's order, 0 to MAX_ORDER; the list mustn't be empty.
 * @return The block's first frame number (not its address), now off every list.
 */
take_first :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> u64 {
    runtime.assert(order <= MAX_ORDER, "take_first takes an order up to MAX_ORDER")
    frame :: allocator.lists[order].first >> FRAME_SHIFT
    unlink(allocator, frame, order)
    return frame
}

/**
 * Round a value up to a multiple of an alignment.
 *
 * @param value The value; within alignment of u64's top, it wraps.
 * @param alignment The alignment, a power of two.
 * @return The smallest multiple of alignment at least value.
 */
round_up :: fn(value: u64, alignment: u64) -> u64 {
    return (value + alignment - 1) & ~(alignment - 1)
}

/**
 * Find the larger of two values.
 *
 * @param a One value, any u64.
 * @param b The other value, any u64.
 * @return The larger, or either when they're equal.
 */
max_of :: fn(a, b: u64) -> u64 {
    return if a > b { a } else { b }
}

/**
 * Find the smaller of two values.
 *
 * @param a One value, any u64.
 * @param b The other value, any u64.
 * @return The smaller, or either when they're equal.
 */
min_of :: fn(a, b: u64) -> u64 {
    return if a < b { a } else { b }
}
