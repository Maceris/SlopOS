package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import slop_os from "std/os"
import frames from "frames"
import slab from "slab"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}

/*
 * Memory objects (roadmap M5, knowledge/design/kernel.md §2, decisions/0011, 0054): anonymous memory,
 * charged to its budget for its whole size when it's made, and filled with zeroed frames only as it's
 * touched, through the page-fault handler. Budgets never overcommit, so a touch can only fail if the
 * machine is out of frames, not because someone else spent them.
 *
 * MemoryMap puts a range of it in an address space, and maps nothing yet: a fault in the range maps the
 * page, with the frame it has or a new one. Two spaces mapping the same memory share its frames.
 *
 * Each mapping is on its space's list and its memory's. Whoever claims a mapping takes it down: unmapping
 * it, the memory being destroyed, or the space. Taking it down unlinks it from its space (under the
 * space's lock, which faults hold while they map, so none maps a page of it after), unmaps the range,
 * then unlinks it from its memory. A fault maps a page only while the mapping is on its space's list, so
 * nothing stays mapped of memory that's been destroyed, and its frames go once no CPU can use them.
 *
 * Lock order: a memory's lock, then a space's.
 */

// A leaf of a memory object's page array holds this many frames' addresses.
PAGES_PER_LEAF :: 512

Memory :: struct #align(16) {
    header : ObjectHeader,
    // Held for its list of mappings.
    lock : concurrency.SpinLock,
    size : u64,
    /*
     * Its frames: a directory frame of leaf frames' addresses in the direct map, each holding
     * PAGES_PER_LEAF frames' physical addresses, 0 until the page is touched. All made with it.
     */
    directory : u64,
    first_mapping : u64,
}

// A range of a memory object, mapped in an address space.
MemoryMapping :: struct {
    // The slab allocator's, while the slot is free.
    free_link : u64,
    space : u64,
    // The space's generation when it was charged for this.
    space_generation : u32,
    // 1 once someone is taking it down.
    claimed : u32,
    memory : u64,
    address : u64,
    size : u64,
    offset : u64,
    protection : u32,
    // Its neighbors on its space's list and its memory's.
    space_next : u64,
    space_previous : u64,
    memory_next : u64,
    memory_previous : u64,
}

// The frames a memory object of size bytes keeps its frames' addresses in: the directory, and its leaves.
page_array_bytes :: fn(size: u64) -> u64 {
    pages :: size / frames.FRAME_SIZE
    leaves :: (pages + PAGES_PER_LEAF - 1) / PAGES_PER_LEAF
    return (1 + leaves) * frames.FRAME_SIZE
}

/*
 * A memory object of size bytes, owned by owner (a Process's address, 0 for the kernel), charged to
 * budget for all of it, with its page array.
 */
create_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, size: u64) -> Result[ptr[mut Memory], slop_os.MemoryError] {
    if size == 0 || size & (frames.FRAME_SIZE - 1) != 0 || size > slop_os.MAX_MEMORY_SIZE {
        return .Error(.InvalidSize)
    }
    object := cast[u64](0)
    match new_object(kernel, .Memory, budget, size + page_array_bytes(size)) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.MemoryError.BudgetExceeded } else { slop_os.MemoryError.OutOfMemory })
    }
    memory :: cast[ptr[mut Memory]](object)
    memory.size = size
    directory :: zeroed_frame(kernel) or_else 0
    memory.directory = directory
    if directory == 0 {
        release_object(kernel, object)
        return .Error(.OutOfMemory)
    }
    leaves :: cast[usize]((size / frames.FRAME_SIZE + PAGES_PER_LEAF - 1) / PAGES_PER_LEAF)
    for leaf in 0..<leaves {
        made :: zeroed_frame(kernel) or_else 0
        if made == 0 {
            release_object(kernel, object)
            return .Error(.OutOfMemory)
        }
        cast[ptr[mut u64]](directory + cast[u64](leaf % PAGES_PER_LEAF) * 8)^ = made
    }
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(memory)
}

// Where page's frame's address is kept.
page_slot :: fn(memory: ptr[Memory], page: u64) -> ptr[mut u64] {
    leaf :: cast[ptr[u64]](memory.directory + (page / PAGES_PER_LEAF % PAGES_PER_LEAF) * 8)^
    return cast[ptr[mut u64]](leaf + page % PAGES_PER_LEAF * 8)
}

// page's frame, a zeroed one if it had none yet: its physical address, 0 if there are no frames.
frame_for :: fn(kernel: ptr[mut Kernel], memory: ptr[Memory], page: u64) -> u64 {
    slot :: page_slot(memory, page)
    held :: intrinsics.atomic_load_u64_acquire(slot)
    if held != 0 {
        return held
    }
    frame :: frames.take_frame(&per_cpu().frame_cache, &kernel.frames) or_return 0
    intrinsics.mem_zero(cast[rawptr](frames.virtual_of(&kernel.frames, frame)), cast[usize](frames.FRAME_SIZE))
    // Another fault on the same page may have given it one first
    other, given :: intrinsics.interlocked_compare_exchange_u64(slot, cast[u64](frame), 0)
    if !given {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, frame)
        return other
    }
    return cast[u64](frame)
}

// Destroying a memory object takes down every mapping of it.
destroy_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    loop {
        concurrency.lock(&memory.lock)
        claimed := cast[u64](0)
        with {
            mapping := memory.first_mapping
        }
        loop {
            if mapping == 0 {
                break
            }
            if claim(cast[ptr[mut MemoryMapping]](mapping)) {
                claimed = mapping
                break
            }
            mapping = cast[ptr[MemoryMapping]](mapping).memory_next
        }
        concurrency.unlock(&memory.lock)
        // One claimed elsewhere is being taken down there, and is gone before this is released
        if claimed == 0 {
            break
        }
        take_down(kernel, cast[ptr[mut MemoryMapping]](claimed))
    }
}

// Once no CPU can use it: its frames, and its page array.
release_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    if memory.directory == 0 {
        return void
    }
    for leaf_index in 0..<PAGES_PER_LEAF {
        leaf :: cast[ptr[u64]](memory.directory + cast[u64](leaf_index) * 8)^
        if leaf != 0 {
            for page in 0..<PAGES_PER_LEAF {
                frame :: cast[ptr[u64]](leaf + cast[u64](page) * 8)^
                if frame != 0 {
                    frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](frame))
                }
            }
            give_frame_at(kernel, leaf)
        }
    }
    give_frame_at(kernel, memory.directory)
    memory.directory = 0
}

/*
 * Map size bytes of memory from offset at address in space, with protection (slop_os.PROTECTION_*):
 * nothing is mapped until it's touched. The mapping is charged to the space.
 */
memory_map :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory], space: ptr[mut AddressSpace], address: u64, offset: u64,
    size: u64, protection: u32) -> slop_os.MemoryError? {
    writable :: protection & cast[u32](slop_os.PROTECTION_WRITE) != 0
    executable :: protection & cast[u32](slop_os.PROTECTION_EXECUTE) != 0
    if protection == 0 || protection & ~cast[u32](7) != 0 || (writable && executable) {
        return slop_os.MemoryError.BadProtection
    }
    if size == 0 || size & (frames.FRAME_SIZE - 1) != 0 || offset & (frames.FRAME_SIZE - 1) != 0 || offset > memory.size
        || size > memory.size - offset {
        return slop_os.MemoryError.InvalidSize
    }
    low, high :: arch.user_address_range()
    if address & (frames.FRAME_SIZE - 1) != 0 || address < cast[u64](low) || address >= cast[u64](high) || size > cast[u64](high) - address {
        return slop_os.MemoryError.BadAddress
    }
    slot_size :: kernel.pools.mappings.object_size
    if !charge_more(cast[u64](space), slot_size) {
        return slop_os.MemoryError.BudgetExceeded
    }
    generation :: space.header.generation
    address_of_mapping :: slab.allocate(&kernel.pools.mappings, &kernel.frames) or_else 0
    if address_of_mapping == 0 {
        uncharge(cast[u64](space), generation, slot_size)
        return slop_os.MemoryError.OutOfMemory
    }
    mapping :: cast[ptr[mut MemoryMapping]](address_of_mapping)
    mapping^ = MemoryMapping.{
        space = cast[u64](space), space_generation = generation, memory = cast[u64](memory), address = address,
        size = size, offset = offset, protection = protection,
    }
    failure := cast[u32](0)
    concurrency.lock(&memory.lock)
    concurrency.lock(&space.lock)
    if is_dying(cast[u64](memory)) || is_dying(cast[u64](space)) {
        failure = cast[u32](slop_os.MemoryError.ObjectGone)
    }
    else if !range_free(kernel, space, address, size) {
        failure = cast[u32](slop_os.MemoryError.BadAddress)
    }
    else {
        link_to_space(space, mapping)
        link_to_memory(memory, mapping)
    }
    concurrency.unlock(&space.lock)
    concurrency.unlock(&memory.lock)
    if failure != 0 {
        slab.free(&kernel.pools.mappings, &kernel.frames, address_of_mapping)
        uncharge(cast[u64](space), generation, slot_size)
        return cast[slop_os.MemoryError](failure)
    }
    return null
}

// Unmap the mapping that starts at address in space.
memory_unmap :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64) -> slop_os.MemoryError? {
    concurrency.lock(&space.lock)
    found := cast[u64](0)
    with {
        mapping := space.first_mapping
    }
    loop {
        if mapping == 0 {
            break
        }
        if cast[ptr[MemoryMapping]](mapping).address == address {
            found = mapping
            break
        }
        mapping = cast[ptr[MemoryMapping]](mapping).space_next
    }
    claimed :: found != 0 && claim(cast[ptr[mut MemoryMapping]](found))
    concurrency.unlock(&space.lock)
    if found == 0 {
        return slop_os.MemoryError.NotMapped
    }
    // Claimed already: it's being taken down anyway
    if claimed {
        take_down(kernel, cast[ptr[mut MemoryMapping]](found))
    }
    return null
}

// Destroying a space takes down the memory mapped in it, so no memory object reaches it once it's released.
take_down_space_mappings :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) {
    loop {
        concurrency.lock(&space.lock)
        claimed := cast[u64](0)
        with {
            mapping := space.first_mapping
        }
        loop {
            if mapping == 0 {
                break
            }
            if claim(cast[ptr[mut MemoryMapping]](mapping)) {
                claimed = mapping
                break
            }
            mapping = cast[ptr[MemoryMapping]](mapping).space_next
        }
        concurrency.unlock(&space.lock)
        if claimed == 0 {
            break
        }
        take_down(kernel, cast[ptr[mut MemoryMapping]](claimed))
    }
}

// Whether this caller is the one to take mapping down.
claim :: fn(mapping: ptr[mut MemoryMapping]) -> bool {
    _, first :: intrinsics.interlocked_compare_exchange_u32(&mapping.claimed, 1, 0)
    return first
}

/*
 * Take down a mapping this caller claimed: off its space's list, so no fault maps more of it, its range
 * unmapped, off its memory's list, then freed.
 */
take_down :: fn(kernel: ptr[mut Kernel], mapping: ptr[mut MemoryMapping]) {
    space :: cast[ptr[mut AddressSpace]](mapping.space)
    memory :: cast[ptr[mut Memory]](mapping.memory)
    concurrency.lock(&space.lock)
    unlink_from_space(space, mapping)
    concurrency.unlock(&space.lock)
    unmap_user(kernel, space, mapping.address, mapping.size)
    concurrency.lock(&memory.lock)
    unlink_from_memory(memory, mapping)
    concurrency.unlock(&memory.lock)
    generation :: mapping.space_generation
    slab.free(&kernel.pools.mappings, &kernel.frames, cast[u64](mapping))
    uncharge(cast[u64](space), generation, kernel.pools.mappings.object_size)
}

/*
 * A page fault in user mode: if it's in memory mapped in the thread's space, and the access is one the
 * mapping allows, the page is mapped, with a frame filled with zeros if it hadn't been touched. False if
 * it isn't, and the thread can't go on.
 */
resolve_fault :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], fault: arch_interface.PageFault) -> bool {
    space :: thread.space
    address :: cast[u64](fault.address) & ~(frames.FRAME_SIZE - 1)
    concurrency.lock(&space.lock)
    defer concurrency.unlock(&space.lock)
    found := cast[ptr[mut MemoryMapping]](0)
    with {
        mapping := space.first_mapping
    }
    loop {
        if mapping == 0 {
            break
        }
        candidate :: cast[ptr[mut MemoryMapping]](mapping)
        if address >= candidate.address && address - candidate.address < candidate.size {
            found = candidate
            break
        }
        mapping = candidate.space_next
    }
    if cast[u64](found) == 0 {
        return false
    }
    protection :: found.protection
    allowed :: match fault.access {
        case .Read => true
        case .Write => protection & cast[u32](slop_os.PROTECTION_WRITE) != 0
        case .Execute => protection & cast[u32](slop_os.PROTECTION_EXECUTE) != 0
    }
    // Pages are mapped with the mapping's protection, so a fault on one that's there broke it
    if !allowed || fault.present {
        return false
    }
    memory :: cast[ptr[Memory]](found.memory)
    page :: (address - found.address + found.offset) / frames.FRAME_SIZE
    frame :: frame_for(kernel, memory, page)
    if frame == 0 {
        return false
    }
    mapped, error :: map_pages_locked(kernel, space, address, frame, frames.FRAME_SIZE, mapping_for(protection))
    // Another CPU may have mapped it meanwhile, for a fault of its own
    return match error {
        case Some(failure) => failure == .AlreadyMapped
        case None => true
    }
}

// How a mapping with protection is mapped.
mapping_for :: fn(protection: u32) -> arch_interface.Mapping {
    kind := arch_interface.Protection.Read
    if protection & cast[u32](slop_os.PROTECTION_WRITE) != 0 {
        kind = .ReadWrite
    }
    else if protection & cast[u32](slop_os.PROTECTION_EXECUTE) != 0 {
        kind = .ReadExecute
    }
    return arch_interface.Mapping.{protection = kind, cache = .WriteBack, user = true, global = false}
}

/*
 * Whether nothing is mapped in size bytes at address in space: no memory mapping, and no channel's
 * rings. Takes the space's lock as held.
 */
range_free :: fn(kernel: ptr[Kernel], space: ptr[AddressSpace], address: u64, size: u64) -> bool {
    with {
        mapping := space.first_mapping
    }
    loop {
        if mapping == 0 {
            break
        }
        other :: cast[ptr[MemoryMapping]](mapping)
        if overlaps(address, size, other.address, other.size) {
            return false
        }
        mapping = other.space_next
    }
    with {
        ring := space.first_ring
    }
    loop {
        if ring == 0 {
            break
        }
        other :: cast[ptr[RingMapping]](ring)
        ring_size :: slop_os.channel_memory_size(cast[ptr[ChannelCore]](other.core).ring_bytes)
        if overlaps(address, size, other.address, ring_size) {
            return false
        }
        ring = other.next
    }
    return true
}

overlaps :: fn(address: u64, size: u64, other: u64, other_size: u64) -> bool {
    return address < other + other_size && other < address + size
}

// Takes the space's lock as held.
link_to_space :: fn(space: ptr[mut AddressSpace], mapping: ptr[mut MemoryMapping]) {
    mapping.space_previous = 0
    mapping.space_next = space.first_mapping
    if space.first_mapping != 0 {
        cast[ptr[mut MemoryMapping]](space.first_mapping).space_previous = cast[u64](mapping)
    }
    space.first_mapping = cast[u64](mapping)
}

unlink_from_space :: fn(space: ptr[mut AddressSpace], mapping: ptr[mut MemoryMapping]) {
    if mapping.space_previous != 0 {
        cast[ptr[mut MemoryMapping]](mapping.space_previous).space_next = mapping.space_next
    }
    else {
        space.first_mapping = mapping.space_next
    }
    if mapping.space_next != 0 {
        cast[ptr[mut MemoryMapping]](mapping.space_next).space_previous = mapping.space_previous
    }
}

// Takes the memory's lock as held.
link_to_memory :: fn(memory: ptr[mut Memory], mapping: ptr[mut MemoryMapping]) {
    mapping.memory_previous = 0
    mapping.memory_next = memory.first_mapping
    if memory.first_mapping != 0 {
        cast[ptr[mut MemoryMapping]](memory.first_mapping).memory_previous = cast[u64](mapping)
    }
    memory.first_mapping = cast[u64](mapping)
}

unlink_from_memory :: fn(memory: ptr[mut Memory], mapping: ptr[mut MemoryMapping]) {
    if mapping.memory_previous != 0 {
        cast[ptr[mut MemoryMapping]](mapping.memory_previous).memory_next = mapping.memory_next
    }
    else {
        memory.first_mapping = mapping.memory_next
    }
    if mapping.memory_next != 0 {
        cast[ptr[mut MemoryMapping]](mapping.memory_next).memory_previous = mapping.memory_previous
    }
}
