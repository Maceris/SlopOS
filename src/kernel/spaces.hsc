package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Address spaces (roadmap M4, M5, knowledge/design/kernel.md §2): objects with page tables for user
 * mode, sharing the kernel's half (decisions/0048), each with its own address-space tag where the CPU
 * has them, so switching between them keeps the TLB.
 *
 * Destroying one destroys the threads that run in it. Its tables, its root and its tag go once no CPU
 * can be using them: every CPU switches its page tables away from one it won't run again before its
 * next quiescent point (scheduler.hsc). The tag's entries are flushed from every CPU before it's reused.
 *
 * Channel rings mapped in it are on its list of rings (channels.hsc), each holding its channel's memory
 * until it's unmapped or the space is released, so no thread still running in a dying space can reach
 * memory that's been freed.
 */

// Tags: 0 is the kernel's own table's (address_space.hsc).
MAX_TAGS :: 4096

AddressSpace :: struct #align(16) {
    header : ObjectHeader,
    // Held while its table changes (docs/specs/arch_interface.md, Rules for L2).
    lock : concurrency.SpinLock,
    table : arch.PageTable,
    // The threads that run in it, and the lock for that list.
    threads_lock : concurrency.SpinLock,
    first_thread : u64,
    // The channel rings mapped in it (RingMapping), under lock.
    first_ring : u64,
    // The memory objects mapped in it (MemoryMapping), by address, under lock (memory.hsc).
    first_mapping : u64,
}

SpaceError :: enum {
    OutOfMemory,
    // Every address-space tag is in use.
    OutOfTags,
    // Not user addresses, or not aligned.
    InvalidAddress,
    AlreadyMapped,
    // Its owner is being destroyed.
    OwnerGone,
    // Its budget can't pay for it, or for the page tables a mapping needs.
    BudgetExceeded,
}

// The tags in use, one bit each.
TagSet :: struct {
    lock : concurrency.SpinLock,
    used : u64[MAX_TAGS / 64],
}

/*
 * An empty address space, owned by owner (a Process's address, 0 for the kernel), charged to budget with
 * its root table, and with the tables its mappings need as they're made.
 */
create_address_space :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64) -> (made #unrestricted : Result[ptr[mut AddressSpace], SpaceError]) {
    object := cast[u64](0)
    match new_object(kernel, .AddressSpace, budget, frames.FRAME_SIZE) {
        case Ok(address) => object = address
        case Error(error) => return .Error(if error == .BudgetExceeded { SpaceError.BudgetExceeded } else { SpaceError.OutOfMemory })
    }
    space :: cast[ptr[mut AddressSpace]](object)
    tag := cast[arch_interface.AddressSpaceTag](0)
    match allocate_tag(kernel) {
        case Some(given) => tag = given
        case None => {
            release_object(kernel, object)
            return .Error(.OutOfTags)
        }
    }
    root := cast[boot_info.PhysicalAddress](0)
    match frames.take_frame(&per_cpu().frame_cache, &kernel.frames) {
        case Ok(frame) => root = frame
        case Error(error) => {
            free_tag(kernel, tag)
            release_object(kernel, object)
            return .Error(.OutOfMemory)
        }
    }
    intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, root)), cast[usize](frames.FRAME_SIZE))
    arch.init_page_table(&space.table, root, tag, &kernel.page_table)
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.OwnerGone)
        }
    }
    return .Ok(space)
}

// Destroying an address space destroys the threads that run in it, and takes down the memory mapped in it.
destroy_address_space :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) {
    take_down_space_mappings(kernel, space)
    loop {
        concurrency.lock(&space.threads_lock)
        first :: space.first_thread
        concurrency.unlock(&space.threads_lock)
        if first == 0 {
            break
        }
        // A thread being destroyed elsewhere takes itself off the list
        if !destroy_object(kernel, first) {
            leave_space(cast[ptr[mut Thread]](first))
        }
    }
}

// Once no CPU can use it: the rings mapped in it, its tables, its root, and its tag, flushed from every CPU first.
release_address_space :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) {
    if cast[u64](space.table.root) == 0 {
        return void
    }
    loop {
        concurrency.lock(&space.lock)
        ring :: take_ring(space)
        concurrency.unlock(&space.lock)
        if ring == 0 {
            break
        }
        drop_core(kernel, cast[ptr[mut RingMapping]](ring).core)
    }
    freed : arch_interface.FreedTables
    loop {
        freed.count = 0
        done :: arch.release_user_tables(&space.table, &freed)
        free_tables(kernel, &freed)
        if done {
            break
        }
    }
    frames.give_frame(&per_cpu().frame_cache, &kernel.frames, space.table.root)
    tag :: space.table.tag
    if cast[u16](tag) != 0 {
        flush := arch_interface.TlbBatch.{tag = tag, all = true}
        shootdown(kernel, &flush)
        free_tag(kernel, tag)
    }
    space.table.root = cast[arch_interface.PhysicalAddress](0)
}

// Add a thread to the ones that run in space, unless space is being destroyed.
join_space :: fn(space: ptr[mut AddressSpace], thread: ptr[mut Thread]) -> bool {
    concurrency.lock(&space.threads_lock)
    defer concurrency.unlock(&space.threads_lock)
    if intrinsics.atomic_load_u32_acquire(&space.header.dying) != 0 {
        return false
    }
    thread.space_previous = 0
    thread.space_next = space.first_thread
    if space.first_thread != 0 {
        cast[ptr[mut Thread]](space.first_thread).space_previous = cast[u64](thread)
    }
    space.first_thread = cast[u64](thread)
    thread.in_space = true
    return true
}

leave_space :: fn(thread: ptr[mut Thread]) {
    space :: thread.space
    concurrency.lock(&space.threads_lock)
    defer concurrency.unlock(&space.threads_lock)
    if !thread.in_space {
        return void
    }
    if thread.space_previous != 0 {
        cast[ptr[mut Thread]](thread.space_previous).space_next = thread.space_next
    }
    else {
        space.first_thread = thread.space_next
    }
    if thread.space_next != 0 {
        cast[ptr[mut Thread]](thread.space_next).space_previous = thread.space_previous
    }
    thread.in_space = false
}

/*
 * A free tag, or with only one tag (no PCIDs), that one: every switch flushes the TLB then anyway.
 */
allocate_tag :: fn(kernel: ptr[mut Kernel]) -> arch_interface.AddressSpaceTag? {
    count :: cast[usize](arch.address_space_tag_count())
    if count <= 1 {
        return cast[arch_interface.AddressSpaceTag](0)
    }
    tags :: &kernel.tags
    concurrency.lock(&tags.lock)
    defer concurrency.unlock(&tags.lock)
    for tag in 1..<count {
        word :: tag / 64 % (MAX_TAGS / 64)
        bit :: cast[u64](1) << cast[u64](tag % 64)
        if tags.used[word] & bit == 0 {
            tags.used[word] |= bit
            return cast[arch_interface.AddressSpaceTag](cast[u16](tag))
        }
    }
    return null
}

free_tag :: fn(kernel: ptr[mut Kernel], tag: arch_interface.AddressSpaceTag) {
    index :: cast[usize](cast[u16](tag))
    tags :: &kernel.tags
    concurrency.lock(&tags.lock)
    tags.used[index / 64 % (MAX_TAGS / 64)] &= ~(cast[u64](1) << cast[u64](index % 64))
    concurrency.unlock(&tags.lock)
}

/*
 * Map size bytes from physical on at address in a user address space, 4 KiB pages, with mapping, which
 * is a user mapping. If it fails, what it mapped is unmapped again.
 */
map_user :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> Result[void, SpaceError] {
    mapped, error :: map_pages(kernel, space, address, physical, size, mapping)
    match error {
        case Some(failure) => {
            unmap_user(kernel, space, address, mapped * frames.FRAME_SIZE)
            return .Error(failure)
        }
        case None => return .Ok
    }
}

// How many pages it mapped, and why it stopped if it didn't map them all.
map_pages :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> (mapped: u64, error: SpaceError?) {
    concurrency.lock(&space.lock)
    defer concurrency.unlock(&space.lock)
    return map_pages_locked(kernel, space, address, physical, size, mapping)
}

// As map_pages, taking the space's lock as held.
map_pages_locked :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> (mapped: u64, error: SpaceError?) {
    tables : arch_interface.TableFrames
    defer give_back_user_tables(kernel, space, &tables)
    for page in 0..<size / frames.FRAME_SIZE {
        offset :: page * frames.FRAME_SIZE
        loop {
            result :: arch.map(&space.table, cast[arch_interface.VirtualAddress](address + offset),
                cast[arch_interface.PhysicalAddress](physical + offset), .Size4K, mapping, &tables)
            match result {
                case Ok => break
                case Error(error) => {
                    if error == .AlreadyMapped {
                        return page, SpaceError.AlreadyMapped
                    }
                    if error != .NeedTableFrames {
                        return page, SpaceError.InvalidAddress
                    }
                    match refill_user_tables(kernel, space, &tables) {
                        case Some(error) => return page, error
                        case None => {}
                    }
                }
            }
        }
    }
    return size / frames.FRAME_SIZE, null
}

/*
 * Unmap size bytes at address in a user address space, what of it is mapped, then shoot down the TLB
 * entries, and only then free the tables it emptied. The space must not be released meanwhile.
 */
unmap_user :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, size: u64) {
    pages :: size / frames.FRAME_SIZE
    generation :: intrinsics.atomic_load_u32_acquire(&space.header.generation)
    flush : arch_interface.TlbBatch
    freed : arch_interface.FreedTables
    page : u64 = 0
    loop {
        if page >= pages {
            break
        }
        concurrency.lock(&space.lock)
        page = unmap_some(&space.table, address, page, pages, &freed, &flush)
        concurrency.unlock(&space.lock)
        // Every CPU forgets the old entries before an emptied table can be reused
        shootdown(kernel, &flush)
        flush = arch_interface.TlbBatch.{}
        uncharge(cast[u64](space), generation, cast[u64](freed.count) * frames.FRAME_SIZE)
        free_tables(kernel, &freed)
    }
}

/*
 * Unmap pages from page on, until pages or until freed is full: the page it got to. Pages that aren't
 * mapped are passed over. Takes the space's lock as held.
 */
unmap_some :: fn(table: ptr[mut arch.PageTable], address: u64, first: u64, pages: u64, freed: ptr[mut arch_interface.FreedTables],
    flush: ptr[mut arch_interface.TlbBatch]) -> u64 {
    page := first
    loop {
        if page >= pages {
            break
        }
        result :: arch.unmap(table, cast[arch_interface.VirtualAddress](address + page * frames.FRAME_SIZE), .Size4K, freed, flush)
        match result {
            case Ok(physical) => page += 1
            case Error(error) => {
                if error == .NeedFreedSpace {
                    break
                }
                page += 1
            }
        }
    }
    return page
}

/*
 * Zeroed frames for new tables from this CPU's frame cache, each charged to space: why not, if it
 * couldn't. The ones no mapping takes are given back with give_back_user_tables.
 */
refill_user_tables :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], tables: ptr[mut arch_interface.TableFrames]) -> SpaceError? {
    cache :: &per_cpu().frame_cache
    for i in cast[usize](tables.count)..<4 {
        if !charge_more(cast[u64](space), frames.FRAME_SIZE) {
            return SpaceError.BudgetExceeded
        }
        match frames.take_frame(cache, &kernel.frames) {
            case Ok(frame) => {
                intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, frame)), cast[usize](frames.FRAME_SIZE))
                tables.frames[i] = frame
                tables.count += 1
            }
            case Error(error) => {
                uncharge(cast[u64](space), space.header.generation, frames.FRAME_SIZE)
                return SpaceError.OutOfMemory
            }
        }
    }
    return null
}

// The table frames no mapping took, back to this CPU's frame cache, and their charge back to space.
give_back_user_tables :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], tables: ptr[mut arch_interface.TableFrames]) {
    uncharge(cast[u64](space), space.header.generation, cast[u64](tables.count) * frames.FRAME_SIZE)
    give_back_tables(kernel, tables)
}
