package kernel

import intrinsics from "base"
import runtime from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import frames from "frames"
import robustness from "../robustness"

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

/**
 * How many address-space tags the kernel keeps track of; 0 is the kernel's own table's (address_space.hsc). A CPU with
 * more shares bits between tags MAX_TAGS apart, so fewer than this are ever in use at once.
 */
MAX_TAGS :: 4096

/** An address space: a kernel object with page tables for user mode, sharing the kernel's half. */
AddressSpace :: struct #align(16) {
    /** The kernel object's header. */
    header : ObjectHeader,
    /** Held while its table changes (docs/specs/arch_interface.md, Rules for L2), at LockRank Space. */
    lock : concurrency.SpinLock,
    /** Its page table: the root's physical address, 0 once it's released, and its tag. */
    table : arch.PageTable,
    /** Guards the list of threads that run in it, at LockRank SpaceThreads. */
    threads_lock : concurrency.SpinLock,
    /** The first thread that runs in it, linked through the threads' space_next and space_previous; 0 for none. */
    first_thread : u64,
    /** The channel rings mapped in it (RingMapping), under lock. */
    first_ring : u64,
    /** The memory objects mapped in it (MemoryMapping), by address, under lock (memory.hsc). */
    first_mapping : u64,
}

/** Why something couldn't be done to an address space. */
SpaceError :: enum {
    /** No memory for the space's slot, its root table, or a page table a mapping needs. */
    OutOfMemory,
    /** Every address-space tag is in use. */
    OutOfTags,
    /** Not user addresses, or not aligned. */
    InvalidAddress,
    /** A page of the range is mapped already. */
    AlreadyMapped,
    /** Its owner is being destroyed. */
    OwnerGone,
    /** Its budget can't pay for it, or for the page tables a mapping needs. */
    BudgetExceeded,
}

/** The tags in use, one bit each. */
TagSet :: struct {
    /** Guards used, at LockRank Tags. */
    lock : concurrency.SpinLock,
    /** A bit per tag, set while it's an address space's; tag 0, the kernel's, is never set. */
    used : u64[MAX_TAGS / 64],
}

/**
 * Make an empty address space, its root table zeroed and sharing the kernel's half, with a tag of its own.
 *
 * @param kernel The kernel: the space's slot comes from its object pool, its tag from its TagSet (taking the Tags
 *     lock), its root from the calling CPU's frame cache, and the kernel half from its own page table.
 * @param owner The Process that owns it, as an address, or 0 for the kernel.
 * @param budget The budget its slot and root table are charged to, and the tables its mappings need as they're made,
 *     or 0 for none.
 * @return made The space, owned by owner and destroyed with it. On an error, nothing is left: its slot, tag and root
 *     are given back.
 * @error OutOfMemory No memory for its slot or its root table.
 * @error BudgetExceeded The budget can't pay for its slot and root table.
 * @error OutOfTags Every address-space tag is in use.
 * @error OwnerGone The owner is being destroyed, so the new space is destroyed.
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

/**
 * Destroy an address space: take down the memory mapped in it, and destroy the threads that run in it.
 *
 * Its tables, root and tag stay until it's released, once no CPU can be using them. A thread being destroyed elsewhere
 * is taken off the list here. Takes the space's threads_lock, at LockRank SpaceThreads, briefly for each thread.
 *
 * @param kernel The kernel, which destroys each thread through destroy_object; the caller holds no lock of the space's.
 * @param space The space, being destroyed.
 */
destroy_address_space :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) {
    take_down_space_mappings(kernel, space)
    loop {
        lock_at(&space.threads_lock, .SpaceThreads)
        first :: space.first_thread
        unlock_at(&space.threads_lock, .SpaceThreads)
        if first == 0 {
            break
        }
        // A thread being destroyed elsewhere takes itself off the list
        if !destroy_object(kernel, first) {
            leave_space(cast[ptr[mut Thread]](first))
        }
    }
}

/**
 * Release a destroyed address space once no CPU can use it: let go of the rings mapped in it, and free its tables, its
 * root, and its tag, flushed from every CPU first.
 *
 * Its root is 0 afterwards, so a second release, or one of a space whose making failed before it had a root, does
 * nothing. Shoots down the TLB, so it's called with no other lock held.
 *
 * @param kernel The kernel, whose frames, channel cores and tags they go back to.
 * @param space The space, destroyed, its grace period passed.
 */
release_address_space :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) {
    if cast[u64](space.table.root) == 0 {
        return void
    }
    loop {
        lock_at(&space.lock, .Space)
        ring :: take_ring(space)
        unlock_at(&space.lock, .Space)
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

/**
 * Add a thread to the ones that run in a space, unless the space is being destroyed.
 *
 * Takes the space's threads_lock, at LockRank SpaceThreads.
 *
 * @param space The space the thread will run in, whose threads_lock is taken, so the caller mustn't hold it.
 * @param thread The thread, in no space's list; its space links and in_space are set.
 * @return True if it's on the list, so destroying the space destroys it; false if the space is dying, with the thread
 *     left off.
 */
join_space :: fn(space: ptr[mut AddressSpace], thread: ptr[mut Thread]) -> bool {
    lock_at(&space.threads_lock, .SpaceThreads)
    defer unlock_at(&space.threads_lock, .SpaceThreads)
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

/**
 * Take a thread off its space's list of threads, if it's on it.
 *
 * Takes the space's threads_lock, at LockRank SpaceThreads.
 *
 * @param thread The thread, whose space must still be valid.
 */
leave_space :: fn(thread: ptr[mut Thread]) {
    space :: thread.space
    lock_at(&space.threads_lock, .SpaceThreads)
    defer unlock_at(&space.threads_lock, .SpaceThreads)
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
 * Where the search for a free tag starts, before the top of the range: 0, from the bottom, or with robustness=on 4, so
 * PCIDs and ASIDs at the end of their range are used, and the search wraps (decisions/0096, 0105).
 */
#if robustness.ON {
    /** With robustness=on, the search starts 4 tags before the top, so the highest tags are used first. */
    TAG_SEARCH_FROM : usize : 4
}
#else {
    /** The search starts from the bottom, at tag 1. */
    TAG_SEARCH_FROM : usize : 0
}

/**
 * Take a free address-space tag.
 *
 * Takes the TagSet's lock, at LockRank Tags.
 *
 * @param kernel The kernel, whose tags it takes from.
 * @return A tag from 1 up, marked used, until free_tag; tag 0 with only one tag (no PCIDs), as every switch flushes
 *     the TLB then anyway; or null if every tag is in use.
 */
allocate_tag :: fn(kernel: ptr[mut Kernel]) -> arch_interface.AddressSpaceTag? {
    count :: cast[usize](arch.address_space_tag_count())
    if count <= 1 {
        return cast[arch_interface.AddressSpaceTag](0)
    }
    tags :: &kernel.tags
    lock_at(&tags.lock, .Tags)
    defer unlock_at(&tags.lock, .Tags)
    // From TAG_SEARCH_FROM tags before the top, round to 1: the highest tags are used first in a robustness kernel
    first :: if TAG_SEARCH_FROM != 0 && count > TAG_SEARCH_FROM + 1 { count - TAG_SEARCH_FROM } else { cast[usize](1) }
    for step in 0..<count - 1 {
        tag :: 1 + (first - 1 + step) % (count - 1)
        word :: tag / 64 % (MAX_TAGS / 64)
        bit :: cast[u64](1) << cast[u64](tag % 64)
        if tags.used[word] & bit == 0 {
            tags.used[word] |= bit
            return cast[arch_interface.AddressSpaceTag](cast[u16](tag))
        }
    }
    return null
}

/**
 * Give back an address-space tag allocate_tag gave, whose entries every CPU has flushed.
 *
 * Takes the TagSet's lock, at LockRank Tags.
 *
 * @param kernel The kernel, whose tags it goes back to.
 * @param tag The tag; 0, as allocate_tag gives with only one tag, clears a bit no tag uses.
 */
free_tag :: fn(kernel: ptr[mut Kernel], tag: arch_interface.AddressSpaceTag) {
    index :: cast[usize](cast[u16](tag))
    tags :: &kernel.tags
    lock_at(&tags.lock, .Tags)
    tags.used[index / 64 % (MAX_TAGS / 64)] &= ~(cast[u64](1) << cast[u64](index % 64))
    unlock_at(&tags.lock, .Tags)
}

/**
 * Map a range of physical memory into a user address space, in 4 KiB pages.
 *
 * Takes the space's lock, at LockRank Space, while mapping, and the page tables it needs from this CPU's frame cache,
 * charged to the space's budget. If it fails, what it mapped is unmapped again, with a shootdown, so it's called with
 * no other lock held.
 *
 * @param kernel The kernel, whose frame allocator gives page tables through the calling CPU's frame cache, and which
 *     shoots down every online CPU's TLB if a failure unmaps.
 * @param space The space, which must not be released meanwhile.
 * @param address The user virtual address to map at, 4 KiB-aligned.
 * @param physical The physical address of the memory, 4 KiB-aligned; the caller keeps it alive while it's mapped.
 * @param size The bytes to map, a multiple of 4 KiB; any remainder isn't mapped.
 * @param mapping How the pages are mapped, a user mapping.
 * @return Nothing; every page is mapped.
 * @error AlreadyMapped A page of the range was mapped already.
 * @error InvalidAddress An address isn't a user address, or isn't aligned.
 * @error OutOfMemory No frame for a page table.
 * @error BudgetExceeded The space's budget couldn't pay for a page table.
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

/**
 * Map a range as map_user does, taking the space's lock, without unmapping on failure.
 *
 * @param kernel The kernel, whose frame allocator gives page tables through the calling CPU's frame cache.
 * @param space The space, which must not be released meanwhile.
 * @param address The user virtual address to map at, 4 KiB-aligned.
 * @param physical The physical address of the memory, 4 KiB-aligned.
 * @param size The bytes to map, a multiple of 4 KiB.
 * @param mapping How the pages are mapped.
 * @return mapped How many pages it mapped, from the range's start.
 * @return error Why it stopped if it didn't map them all: AlreadyMapped, InvalidAddress, OutOfMemory or
 *     BudgetExceeded; null if it did.
 */
map_pages :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64, size: u64,
    mapping: arch_interface.Mapping) -> (mapped: u64, error: SpaceError?) {
    lock_at(&space.lock, .Space)
    defer unlock_at(&space.lock, .Space)
    return map_pages_locked(kernel, space, address, physical, size, mapping)
}

/**
 * Map a range as map_pages does, with the space's lock already held.
 *
 * Page tables a mapping didn't take go back, with their charge, before it returns.
 *
 * @param kernel The kernel, whose frame allocator gives page tables through the calling CPU's frame cache.
 * @param space The space, its lock held by the caller.
 * @param address The user virtual address to map at, 4 KiB-aligned.
 * @param physical The physical address of the memory, 4 KiB-aligned.
 * @param size The bytes to map, a multiple of 4 KiB.
 * @param mapping How the pages are mapped.
 * @return mapped How many pages it mapped, from the range's start.
 * @return error Why it stopped if it didn't map them all: AlreadyMapped for a page mapped already, InvalidAddress
 *     for any other refusal from the page table, OutOfMemory or BudgetExceeded for a page table; null if it did.
 */
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

/**
 * Map a 2 MiB large page into a user address space.
 *
 * Page tables a mapping didn't take go back, with their charge, before it returns.
 *
 * @param kernel The kernel, whose frame allocator gives page tables through the calling CPU's frame cache.
 * @param space The space, its lock held by the caller.
 * @param address The user virtual address, 2 MiB-aligned.
 * @param physical The physical address of the 2 MiB, 2 MiB-aligned.
 * @param mapping How the page is mapped.
 * @return True if it's mapped; false if any page of it is mapped already, as a fault in another of its pages may have
 *     done, or the address is refused, or no page table could be had or paid for.
 */
map_large_locked :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64, physical: u64,
    mapping: arch_interface.Mapping) -> bool {
    tables : arch_interface.TableFrames
    defer give_back_user_tables(kernel, space, &tables)
    loop {
        match arch.map(&space.table, cast[arch_interface.VirtualAddress](address), cast[arch_interface.PhysicalAddress](physical), .Size2M,
            mapping, &tables) {
            case Ok => return true
            case Error(error) => {
                if error != .NeedTableFrames || (refill_user_tables(kernel, space, &tables) is_some) {
                    return false
                }
            }
        }
    }
}

/**
 * Unmap a range of a user address space, what of it is mapped, then shoot down the TLB entries, and only then free
 * the tables it emptied.
 *
 * Works a batch at a time, as many pages as the tables it can empty at once allow: each takes the space's lock, at
 * LockRank Space, then lets it go for the shootdown, so it's called with no other lock held. The freed tables' charge
 * goes back to the space's budget, if the space is still the one it was when this started. A large page any of the
 * range touches is unmapped whole.
 *
 * @param kernel The kernel: every online CPU's TLB is shot down for each batch, and the emptied tables go back to its
 *     frame allocator through the calling CPU's frame cache.
 * @param space The space, which must not be released meanwhile.
 * @param address The user virtual address of the range, 4 KiB-aligned.
 * @param size The range's size in bytes, a multiple of 4 KiB; any remainder isn't unmapped.
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
        lock_at(&space.lock, .Space)
        page = unmap_some(&space.table, address, page, pages, &freed, &flush)
        unlock_at(&space.lock, .Space)
        // Every CPU forgets the old entries before an emptied table can be reused
        shootdown(kernel, &flush)
        flush = arch_interface.TlbBatch.{}
        uncharge(cast[u64](space), generation, cast[u64](freed.count) * frames.FRAME_SIZE)
        free_tables(kernel, &freed)
    }
}

/**
 * Unmap pages of a range, from one page on, until the range's end or until freed is full.
 *
 * Pages that aren't mapped are passed over. A page that's part of a large page unmaps the large page whole, and
 * skips to its end. The caller holds the space's lock.
 *
 * @param table The space's page table.
 * @param address The user virtual address of the range's start.
 * @param first The index of the page to start at, in 4 KiB pages from address.
 * @param pages The range's size, in 4 KiB pages.
 * @param freed Where emptied tables go; it stops when it's full, and the caller frees them after a shootdown.
 * @param flush Where the TLB entries to flush go, which the caller shoots down.
 * @return The index of the page it got to: pages, or more after a large page, when it's done; less when freed filled.
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
                // A large page of anonymous memory (decisions/0129): it's unmapped whole, as the mapping holds all of it
                if error == .PartOfLargerPage {
                    large :: (address + page * frames.FRAME_SIZE) & ~(LARGE_PAGE - 1)
                    match arch.unmap(table, cast[arch_interface.VirtualAddress](large), .Size2M, freed, flush) {
                        case Ok(physical) => {}
                        case Error(again) => if again == .NeedFreedSpace {
                            break
                        }
                    }
                    page = (large + LARGE_PAGE - address) / frames.FRAME_SIZE
                    continue
                }
                page += 1
            }
        }
    }
    return page
}

/**
 * Fill a set of table frames up to four, zeroed, from this CPU's frame cache, each charged to a space's budget.
 *
 * The ones no mapping takes are given back with give_back_user_tables. Those taken before a failure stay in tables,
 * charged.
 *
 * @param kernel The kernel, whose frame allocator the frames come from, through the calling CPU's frame cache.
 * @param space The space whose budget pays for them.
 * @param tables The frames to fill, from its count up to four.
 * @return Null once tables holds four; BudgetExceeded if the budget couldn't pay for a frame, or OutOfMemory if
 *     there was no frame, its charge given back.
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

/**
 * Give the table frames no mapping took back to this CPU's frame cache, and their charge back to a space's budget.
 *
 * @param kernel The kernel, whose frame allocator the frames go back to, through the calling CPU's frame cache.
 * @param space The space whose budget paid for them.
 * @param tables The unused frames; its count is 0 after.
 */
give_back_user_tables :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], tables: ptr[mut arch_interface.TableFrames]) {
    uncharge(cast[u64](space), space.header.generation, cast[u64](tables.count) * frames.FRAME_SIZE)
    give_back_tables(kernel, tables)
}
