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
//SPEC: Knuth, The Art of Computer Programming Vol. 1, §2.5 (the buddy system)
//SPEC: Bonwick and Adams, "Magazines and Vmem" (USENIX 2001), §3 (the magazine layer, here for frames)
package frames

import intrinsics from "base"
import runtime from "base"
import concurrency from "std"
import boot_info from "../../boot_info"

FRAME_SIZE : u64 : 4096
// Single frames a FrameCache holds, and what it takes or gives back at once.
FRAME_CACHE_SIZE :: 32
FRAME_CACHE_BATCH :: 16
FRAME_SHIFT : u64 : 12
// Blocks go up to 2^18 frames, 1 GiB, the largest page x86-64 maps.
MAX_ORDER : u64 : 18
ORDER_COUNT :: 19

// What a frame's state byte says, for the first frame of a block. The order is in the low bits.
STATE_FREE : u8 : 0x40
STATE_ALLOCATED : u8 : 0x80
// Not the first frame of a block: inside one, or memory the allocator doesn't own.
STATE_NONE : u8 : 0

FrameError :: enum {
    // No free block of that order or larger.
    OutOfMemory,
}

MakeError :: enum {
    // No usable region has room for the state array.
    NoRoomForState,
}

// A free block's first bytes, linking it into its order's list. 0 is no block: frame 0 is never usable.
FreeBlock :: struct {
    next : u64,
    previous : u64,
}

FreeList :: struct {
    // The physical address of the first block, 0 when the list is empty.
    first : u64,
    count : u64,
}

// One CPU's stack of single free frames, by physical address. Used only by its CPU, so it needs no lock.
FrameCache :: struct {
    count : u64,
    frames : u64[FRAME_CACHE_SIZE],
}

FrameAllocator :: struct {
    lock : concurrency.SpinLock,
    lists : FreeList[ORDER_COUNT],
    // One byte per frame, for frames 0 to frame_count, in the direct map.
    states : mut u8[],
    frame_count : u64,
    // Where physical address 0 is in the direct map.
    direct_map_offset : u64,
    // Frames given to the allocator, and those free now.
    total_frames : u64,
    free_frames : u64,
}

/*
 * An allocator for the Usable regions of memory_map, reached through the direct map at
 * direct_map_offset. The state array is carved from the first usable region with room; the rest
 * is free. Regions of other kinds can be added later with add_range, like boot memory once it's
 * reclaimed, if they're below the highest address of any RAM in the map.
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

// Whether memory of this kind is RAM the frame allocator may own, now or once it's reclaimed or given back, like a boot module's.
is_reclaimable_ram :: fn(kind: boot_info.MemoryKind) -> bool {
    return kind == .Usable || kind == .BootReclaimable || kind == .FirmwareTables || kind == .BootModule
}

/*
 * Give the allocator the frames from start to end, physical addresses on frame boundaries, which
 * must be below its frame_count and not given to it before. They join whatever free blocks next
 * to them they can.
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

/*
 * A block of 2^order frames, aligned to its size: the physical address of its first frame. Its
 * contents are whatever was there before.
 */
allocate :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    return take_block(allocator, order)
}

// allocate, with the lock held.
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
    block :: take_first(allocator, found)
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
    return .Ok(cast[boot_info.PhysicalAddress](block << FRAME_SHIFT))
}

// Like allocate, with the block's bytes zeroed.
allocate_zeroed :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> Result[boot_info.PhysicalAddress, FrameError] {
    address :: allocate(allocator, order)?
    intrinsics.mem_zero(cast[mut rawptr](virtual_of(allocator, address)), cast[usize](FRAME_SIZE << order))
    return .Ok(address)
}

/*
 * Free a block that allocate gave, with the same order. Freeing anything else is a bug in the
 * kernel, which stops it.
 */
free :: fn(allocator: ptr[mut FrameAllocator], address: boot_info.PhysicalAddress, order: u64) {
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    give_block(allocator, address, order)
}

// free, with the lock held.
give_block :: fn(allocator: ptr[mut FrameAllocator], address: boot_info.PhysicalAddress, order: u64) {
    frame :: cast[u64](address) >> FRAME_SHIFT
    // One state per frame: states.count is frame_count
    states :: allocator.states
    runtime.assert(cast[u64](address) % FRAME_SIZE == 0 && frame < cast[u64](states.count), "free takes a frame the allocator owns")
    runtime.assert(order <= MAX_ORDER && states[frame] == STATE_ALLOCATED | cast[u8](order),
        "free takes an allocated block, with the order it was allocated with")
    release(allocator, frame, order)
}

// A single frame from the calling CPU's cache, refilled from the allocator if it's empty.
take_frame :: fn(cache: ptr[mut FrameCache], allocator: ptr[mut FrameAllocator]) -> Result[boot_info.PhysicalAddress, FrameError] {
    if cache.count == 0 {
        concurrency.lock(&allocator.lock)
        defer concurrency.unlock(&allocator.lock)
        for i in 0..<FRAME_CACHE_BATCH {
            match take_block(allocator, 0) {
                case Ok(address) => cache.frames[i] = cast[u64](address)
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
    return .Ok(cast[boot_info.PhysicalAddress](cache.frames[count - 1]))
}

// Give a single frame to the calling CPU's cache, emptying half of it into the allocator if it's full.
give_frame :: fn(cache: ptr[mut FrameCache], allocator: ptr[mut FrameAllocator], address: boot_info.PhysicalAddress) {
    if cache.count == FRAME_CACHE_SIZE {
        concurrency.lock(&allocator.lock)
        defer concurrency.unlock(&allocator.lock)
        for i in FRAME_CACHE_SIZE - FRAME_CACHE_BATCH..<FRAME_CACHE_SIZE {
            give_block(allocator, cast[boot_info.PhysicalAddress](cache.frames[i]), 0)
        }
        cache.count = FRAME_CACHE_SIZE - FRAME_CACHE_BATCH
    }
    count :: cache.count
    runtime.assert(count < FRAME_CACHE_SIZE, "a frame cache that isn't full has room")
    cache.frames[count] = cast[u64](address)
    cache.count = count + 1
}

// Give every frame in a cache back to the allocator.
drain_frames :: fn(cache: ptr[mut FrameCache], allocator: ptr[mut FrameAllocator]) {
    concurrency.lock(&allocator.lock)
    defer concurrency.unlock(&allocator.lock)
    count :: cache.count
    runtime.assert(count <= FRAME_CACHE_SIZE, "a frame cache holds up to FRAME_CACHE_SIZE frames")
    for i in 0..<count {
        give_block(allocator, cast[boot_info.PhysicalAddress](cache.frames[i]), 0)
    }
    cache.count = 0
}

// The order of the smallest block that holds size bytes.
order_for :: fn(size: u64) -> u64 {
    order : u64 = 0
    loop {
        order += 1
    }
    while FRAME_SIZE << order < size
    return order
}

// Where a frame's memory is in the direct map.
virtual_of :: fn(allocator: ptr[FrameAllocator], address: boot_info.PhysicalAddress) -> u64 {
    return allocator.direct_map_offset + cast[u64](address)
}

/*
 * Put a block on its free list, merged with its buddy and its buddy's buddy and so on while they're
 * free. Takes the lock as held.
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

block_of :: fn(allocator: ptr[FrameAllocator], frame: u64) -> ptr[mut FreeBlock] {
    return cast[ptr[mut FreeBlock]](allocator.direct_map_offset + (frame << FRAME_SHIFT))
}

// Put a free block first on its order's list.
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

// Take a free block off its order's list.
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

// The first block on a non-empty list, taken off it: its frame.
take_first :: fn(allocator: ptr[mut FrameAllocator], order: u64) -> u64 {
    runtime.assert(order <= MAX_ORDER, "take_first takes an order up to MAX_ORDER")
    frame :: allocator.lists[order].first >> FRAME_SHIFT
    unlink(allocator, frame, order)
    return frame
}

round_up :: fn(value: u64, alignment: u64) -> u64 {
    return (value + alignment - 1) & ~(alignment - 1)
}

max_of :: fn(a, b: u64) -> u64 {
    return if a > b { a } else { b }
}

min_of :: fn(a, b: u64) -> u64 {
    return if a < b { a } else { b }
}
