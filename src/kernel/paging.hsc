package kernel

import intrinsics from "base"
import arch_interface from "../arch_interface"
import boot_info from "../boot_info"
import concurrency from "std"
import slop_os from "std/os"
import frames from "frames"

#if TARGET_ARCH == .x86_64 {
    import arch from "../arch/x86_64"
}
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
}

/*
 * Paged memory (roadmap 9b, decisions/0094, design/storage.md §7): a memory object whose pages its pager supplies,
 * for content that can't change, like the bundle store's objects. It's charged to its budget for its page array, and
 * for each page once it's supplied, so its budget holds what it has in memory (decisions/0111), and can be mapped only
 * to read or execute, by any number of spaces at any addresses.
 *
 * A touch of a page that isn't there marks it wanted, raises the pager's wake binding (which the pager made on its
 * port, and named when it made the memory), and blocks the thread on the memory. The pager asks which pages are wanted
 * (memory_page_wanted, each reported once) and supplies each (memory_supply), copying a page of its own memory in;
 * that wakes every thread waiting on the memory, and each touches its page again, mapping it, or waiting again for
 * another. A touch with the pager's binding gone fails, as a touch of nothing mapped does.
 *
 * A supplied page stays until its pager gives it back (memory_evict, decisions/0111), as it does under pressure on its
 * budget: it's taken out of the page array, unmapped from every space that maps it, and only once every CPU has
 * forgotten it, freed and uncharged; the next touch waits for its pager again. Which pages to give back is the
 * pager's to choose, with memory_page_accessed telling it which were touched since it last asked.
 *
 * A page's slot holds its frame, or PAGE_WANTED or PAGE_REPORTED, which no frame is. Lock order: an address space's
 * lock, then a memory's page_lock, then a port's.
 */

/** A page slot's mark for a page a touch wants that its pager hasn't been told of yet; no frame's address. */
PAGE_WANTED : u64 : 1
/** A page slot's mark for a wanted page memory_page_wanted has reported to its pager; no frame's address. */
PAGE_REPORTED : u64 : 3

/** How a fault on a mapping came out: mapped, failed, or the thread blocked, waiting for its pager. */
FaultOutcome :: enum {
    /** The page is mapped, by this fault or another CPU's; the thread touches it again. */
    Mapped,
    /** The access isn't one a mapping allows, or no frame could be had; the thread can't go on. */
    Failed,
    /** The thread is blocked on the memory, waiting for its pager to supply the page; it's switched away from. */
    Blocked,
}

/**
 * Make paged memory, whose pages its pager supplies.
 *
 * It's charged for its slot and page array now, and for each page once it's supplied. It can be mapped only to read or
 * execute. Takes the port's lock (level Port) to find the binding.
 *
 * @param kernel The kernel: its Memory pool gives the slot and its frames the page array.
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, as an address; 0 for the kernel's own.
 * @param port The pager's port, which has the wake binding.
 * @param key The key of the wake binding on port that's raised when a page is wanted.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @return The memory, the owner's (or the kernel's) until it's destroyed, its pages wanted from its pager as touched.
 * @error NoPager The port has no wake binding with that key, or is being destroyed.
 * @error InvalidSize The size is 0, not a whole number of pages, or more than MAX_MEMORY_SIZE.
 * @error BudgetExceeded The budget can't pay for its slot and page array.
 * @error OutOfMemory No slot or frames for it.
 * @error ObjectGone The owner is being destroyed.
 */
create_paged_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, port: ptr[mut Port], key: u64, size: u64)
    -> Result[ptr[mut Memory], slop_os.MemoryError] {
    lock_at(&port.lock, .Port)
    binding_address := cast[u64](0)
    generation : u32 = 0
    if !is_dying(cast[u64](port)) {
        match binding_of(port, key, .Wake) {
            case Some(found) => {
                binding_address = cast[u64](found)
                generation = found.generation
            }
            case None => {}
        }
    }
    unlock_at(&port.lock, .Port)
    if binding_address == 0 {
        return .Error(.NoPager)
    }
    memory :: create_memory_charging(kernel, owner, budget, size, 0)?
    memory.pager_binding = binding_address
    memory.pager_generation = generation
    memory.allowed = cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_EXECUTE)
    return .Ok(memory)
}

/**
 * Find the memory a window's page is of, through its parents, and the page there.
 *
 * @param memory The memory, a window or not; for one that isn't, it's its own root.
 * @param page The page's index in memory.
 * @return The memory at the root of memory's windows, which isn't a window.
 * @return The page's index in that root.
 */
paged_root :: fn(memory: ptr[Memory], page: u64) -> (ptr[mut Memory], u64) {
    root := cast[ptr[mut Memory]](memory)
    at := page
    loop {
        if root.parent == 0 {
            return root, at
        }
        at += root.parent_page
        root = cast[ptr[mut Memory]](root.parent)
    }
}

/**
 * Resolve a fault on a page of paged memory: map it if it's been supplied, or block the thread on the memory.
 *
 * A page wanted for the first time is marked PAGE_WANTED and the pager's wake binding is raised. The blocked thread is
 * on the memory's waiters until a supply wakes it, and touches the page again then. Takes the memory's page lock, then
 * the pager port's lock; if the thread is running on this CPU, its time is accounted and vector state saved.
 *
 * @param kernel The kernel: a page that's there is mapped with table frames charged to the space, and the pager's
 *     binding is queued on its port.
 * @param thread The faulting thread, running on this CPU or not; when it blocks, its state, fault_memory and wait links
 *     are set, under the memory's page lock.
 * @param space The thread's address space, whose lock the caller holds.
 * @param address The faulting page's user virtual address, page aligned.
 * @param memory The paged memory, the root of any windows the fault went through.
 * @param page The page's index in memory.
 * @param mapping How the page is mapped once it's there.
 * @return Mapped if the page was there and is mapped now (or another CPU mapped it); Blocked if the thread now waits
 *     for the pager; Failed if mapping it failed or the pager's binding is gone.
 */
resolve_paged_fault :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], space: ptr[mut AddressSpace], address: u64,
    memory: ptr[mut Memory], page: u64, mapping: arch_interface.Mapping) -> FaultOutcome {
    lock_at(&memory.page_lock, .MemoryPages)
    slot :: page_slot(memory, page)
    held :: intrinsics.atomic_load_u64_acquire(slot)
    if held >= frames.FRAME_SIZE {
        unlock_at(&memory.page_lock, .MemoryPages)
        mapped, error :: map_pages_locked(kernel, space, address, held, frames.FRAME_SIZE, mapping)
        return match error {
            case Some(failure) => if failure == .AlreadyMapped { FaultOutcome.Mapped } else { FaultOutcome.Failed }
            case None => FaultOutcome.Mapped
        }
    }
    port :: match lock_bound_port(cast[ptr[Binding]](memory.pager_binding), memory.pager_generation) {
        case Some(locked) => locked
        case None => {
            unlock_at(&memory.page_lock, .MemoryPages)
            return .Failed
        }
    }
    if held == 0 {
        intrinsics.atomic_store_u64_release(slot, PAGE_WANTED)
        binding :: cast[ptr[mut Binding]](memory.pager_binding)
        binding.data |= 1
        queue_binding(kernel, port, binding)
    }
    unlock_at(&port.lock, .Port)
    // Saved first, then where supply finds it, as a port's waiter is
    cpu :: per_cpu()
    if cpu.current == cast[u64](thread) {
        account(cpu, thread, arch.counter())
        arch.save_vector_state(cast[ptr[mut arch.VectorState]](thread.vector))
    }
    thread.state = .Blocked
    thread.fault_memory = cast[u64](memory)
    thread.wait_previous = 0
    thread.wait_next = memory.fault_waiters
    if memory.fault_waiters != 0 {
        cast[ptr[mut Thread]](memory.fault_waiters).wait_previous = cast[u64](thread)
    }
    memory.fault_waiters = cast[u64](thread)
    unlock_at(&memory.page_lock, .MemoryPages)
    return .Blocked
}

/**
 * Make every thread waiting on paged memory ready, to touch its page again.
 *
 * @param kernel The kernel, whose scheduler each thread is made ready on, asking for the CPU its cpu field names.
 * @param memory The paged memory, whose page lock the caller holds; it has no waiters after.
 */
wake_fault_waiters :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    loop {
        first :: memory.fault_waiters
        if first == 0 {
            break
        }
        thread :: cast[ptr[mut Thread]](first)
        memory.fault_waiters = thread.wait_next
        thread.wait_next = 0
        thread.wait_previous = 0
        thread.fault_memory = 0
        make_ready(kernel, thread, intrinsics.atomic_load_u32_acquire(&thread.cpu))
    }
    if memory.fault_waiters != 0 {
        cast[ptr[mut Thread]](memory.fault_waiters).wait_previous = 0
    }
}

/**
 * Stop a thread being destroyed from waiting for its page, if it was waiting for one.
 *
 * Takes the memory's page lock.
 *
 * @param thread The thread, no longer running; its fault_memory is 0 after.
 */
cancel_fault_wait :: fn(thread: ptr[mut Thread]) {
    address :: thread.fault_memory
    if address == 0 {
        return void
    }
    memory :: cast[ptr[mut Memory]](address)
    lock_at(&memory.page_lock, .MemoryPages)
    if thread.fault_memory == address {
        if thread.wait_previous != 0 {
            cast[ptr[mut Thread]](thread.wait_previous).wait_next = thread.wait_next
        }
        else {
            memory.fault_waiters = thread.wait_next
        }
        if thread.wait_next != 0 {
            cast[ptr[mut Thread]](thread.wait_next).wait_previous = thread.wait_previous
        }
        thread.fault_memory = 0
    }
    unlock_at(&memory.page_lock, .MemoryPages)
}

/**
 * Report a page of paged memory that's wanted and hasn't been reported yet, the lowest such: memory_page_wanted.
 *
 * Takes the memory's page lock. A page is reported once; it stays wanted until it's supplied.
 *
 * @param memory The paged memory, not a window onto it.
 * @return The page's offset in the memory, in bytes, page aligned.
 * @error NotPaged The memory isn't paged memory, or is a window.
 * @error NothingWanted No page is wanted that hasn't been reported.
 */
page_wanted :: fn(memory: ptr[mut Memory]) -> Result[u64, slop_os.MemoryError] {
    if memory.pager_binding == 0 {
        return .Error(.NotPaged)
    }
    lock_at(&memory.page_lock, .MemoryPages)
    defer unlock_at(&memory.page_lock, .MemoryPages)
    pages :: memory.size / frames.FRAME_SIZE
    for page in cast[u64](0)..<pages {
        slot :: page_slot(memory, page)
        if intrinsics.atomic_load_u64_acquire(slot) == PAGE_WANTED {
            intrinsics.atomic_store_u64_release(slot, PAGE_REPORTED)
            return .Ok(page * frames.FRAME_SIZE)
        }
    }
    return .Error(.NothingWanted)
}

/**
 * Supply a page of paged memory, a copy of a page of another memory object: memory_supply.
 *
 * The page is charged to the memory's budget first, which raises pressure there if it's pressed. If the page was
 * supplied already, the copy is dropped and the charge given back. Either way, every thread waiting on the memory is
 * woken. Takes the memory's page lock.
 *
 * @param kernel The kernel, whose frame for the copy comes from this CPU's frame cache.
 * @param memory The paged memory, not a window onto it.
 * @param offset The page's offset in memory, in bytes, page aligned, below its size.
 * @param source The memory copied from, whose page is given a frame if it's anonymous and had none.
 * @param source_offset The page's offset in source, in bytes, page aligned, below its size.
 * @return Null once the page is there; NotPaged for memory that isn't paged, InvalidSize for an offset that isn't page
 *     aligned or is past either's end, or a source that's device memory or a framebuffer (which can't be copied from), OutOfMemory if source's page has no frame (as an unsupplied page of paged memory
 *     hasn't) or no frame is free for the copy, BudgetExceeded if the budget can't pay for the page.
 */
supply_page :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory], offset: u64, source: ptr[Memory], source_offset: u64)
    -> slop_os.MemoryError? {
    if memory.pager_binding == 0 {
        return .NotPaged
    }
    if offset & (frames.FRAME_SIZE - 1) != 0 || offset >= memory.size || source_offset & (frames.FRAME_SIZE - 1) != 0
        || source_offset >= source.size {
        return .InvalidSize
    }
    from :: frame_for(kernel, source, source_offset / frames.FRAME_SIZE)
    if from == 0 {
        return .OutOfMemory
    }
    // Copied through the direct map, which doesn't reach device memory or a framebuffer
    if !reachable_in_direct_map(kernel, from, source.cache) {
        return .InvalidSize
    }
    // Its page charged first, which pressure on its budget is raised for
    generation :: intrinsics.atomic_load_u32_acquire(&memory.header.generation)
    if !charge_more(cast[u64](memory), frames.FRAME_SIZE) {
        return .BudgetExceeded
    }
    frame :: match frames.take_frame(&per_cpu().frame_cache, &kernel.frames) {
        case Ok(taken) => taken
        case Error(error) => {
            uncharge(cast[u64](memory), generation, frames.FRAME_SIZE)
            return .OutOfMemory
        }
    }
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](frames.virtual_of(&kernel.frames, frame)),
        cast[rawptr](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](from))), cast[usize](frames.FRAME_SIZE))
    lock_at(&memory.page_lock, .MemoryPages)
    slot :: page_slot(memory, offset / frames.FRAME_SIZE)
    supplied_already :: intrinsics.atomic_load_u64_acquire(slot) >= frames.FRAME_SIZE
    if supplied_already {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, frame)
    }
    else {
        intrinsics.atomic_store_u64_release(slot, cast[u64](frame))
    }
    wake_fault_waiters(kernel, memory)
    unlock_at(&memory.page_lock, .MemoryPages)
    if supplied_already {
        uncharge(cast[u64](memory), generation, frames.FRAME_SIZE)
    }
    return null
}

/** A space a page of paged memory was unmapped from, to be flushed from every CPU before its frame goes. */
Unmapped :: struct {
    /** The AddressSpace, as an address. */
    space : u64,
    /** The space's generation then, so the tables' charge isn't given back to a space made since. */
    generation : u32,
    /** The space's address-space tag, for the TLB flush. */
    tag : arch_interface.AddressSpaceTag,
    /** The user virtual address the page was mapped at, page aligned. */
    address : u64,
    /** The page tables the unmapping emptied, freed once every CPU has flushed the address. */
    freed : arch_interface.FreedTables,
}

/**
 * Give back a page of paged memory: memory_evict (decisions/0111).
 *
 * It's taken out of the page array, so the next touch waits for its pager; unmapped from every space that maps it,
 * through its windows too; and once every CPU has forgotten it, freed and uncharged, with the tables the unmapping
 * emptied. Called with no lock held, since it shoots down TLB entries; takes the memory's locks and each space's.
 *
 * @param kernel The kernel: TLB entries are shot down on every CPU, and the frame and emptied tables go to this CPU's
 *     frame cache.
 * @param memory The paged memory, not a window onto it.
 * @param offset The page's offset in memory, in bytes, page aligned, below its size.
 * @return Null once the page is gone; NotPaged for memory that isn't paged or is a window, InvalidSize for a bad
 *     offset, MappedWidely, leaving the page, if more mappings cover it than MAX_EVICT_SPACES, NotSupplied if it isn't
 *     there.
 */
evict_page :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory], offset: u64) -> slop_os.MemoryError? {
    if memory.pager_binding == 0 || memory.parent != 0 {
        return .NotPaged
    }
    if offset & (frames.FRAME_SIZE - 1) != 0 || offset >= memory.size {
        return .InvalidSize
    }
    page :: offset / frames.FRAME_SIZE
    if mappings_of_page(memory, page) > cast[u64](slop_os.MAX_EVICT_SPACES) {
        return .MappedWidely
    }
    lock_at(&memory.page_lock, .MemoryPages)
    slot :: page_slot(memory, page)
    frame :: intrinsics.atomic_load_u64_acquire(slot)
    if frame < frames.FRAME_SIZE {
        unlock_at(&memory.page_lock, .MemoryPages)
        return .NotSupplied
    }
    intrinsics.atomic_store_u64_release(slot, 0)
    unlock_at(&memory.page_lock, .MemoryPages)
    /*
     * Its entries cleared under the locks, in at most MAX_EVICT_SPACES spaces, the most mappings_of_page found; a
     * mapping made since, past them, could only map the frame a supply gives it, not this one, which no slot holds
     */
    unmapped : Unmapped[slop_os.MAX_EVICT_SPACES]
    count := cast[usize](0)
    lock_at(&memory.lock, .MemoryParent)
    count = unmap_page_in(memory, page, frame, &unmapped, count)
    with {
        window_address := memory.first_window
    }
    loop {
        if window_address == 0 {
            break
        }
        window :: cast[ptr[mut Memory]](window_address)
        if page >= window.parent_page && page - window.parent_page < window.size / frames.FRAME_SIZE {
            lock_at(&window.lock, .Memory)
            count = unmap_page_in(window, page - window.parent_page, frame, &unmapped, count)
            unlock_at(&window.lock, .Memory)
        }
        window_address = window.window_next
    }
    unlock_at(&memory.lock, .MemoryParent)
    // Every CPU forgets it, and the tables that emptied, before either is used again
    for i in cast[usize](0)..<unmapped.count {
        if i >= count {
            break
        }
        each :: &unmapped[i]
        flush := arch_interface.TlbBatch.{}
        flush.tag = each.tag
        flush.count = 1
        flush.addresses[0] = cast[arch_interface.VirtualAddress](each.address)
        shootdown(kernel, &flush)
        uncharge(each.space, each.generation, cast[u64](each.freed.count) * frames.FRAME_SIZE)
        free_tables(kernel, &each.freed)
    }
    frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](frame))
    uncharge(cast[u64](memory), intrinsics.atomic_load_u32_acquire(&memory.header.generation), frames.FRAME_SIZE)
    return null
}

/**
 * Unmap a page from each mapping of a memory object that covers it and still maps the frame.
 *
 * Each space's entry is noted in unmapped, its TLB not yet flushed. Takes each mapping's space's lock in turn.
 *
 * @param memory The paged memory or a window onto it, whose lock the caller holds.
 * @param page The page's index in memory.
 * @param frame The page's frame, physical; a mapping of another frame there is left.
 * @param unmapped Where each space unmapped from is noted; mappings past its room are left mapped.
 * @param count How many of unmapped's entries are used already.
 * @return How many of unmapped's entries are used after.
 */
unmap_page_in :: fn(memory: ptr[mut Memory], page: u64, frame: u64, unmapped: ptr[mut Unmapped[slop_os.MAX_EVICT_SPACES]], count: usize)
    -> usize {
    made := count
    with {
        address := memory.first_mapping
    }
    loop {
        if address == 0 {
            break
        }
        mapping :: cast[ptr[mut MemoryMapping]](address)
        address = mapping.memory_next
        first :: mapping.offset / frames.FRAME_SIZE
        if page < first || page - first >= mapping.size / frames.FRAME_SIZE || made >= unmapped.count {
            continue
        }
        space :: cast[ptr[mut AddressSpace]](mapping.space)
        at :: mapping.address + (page - first) * frames.FRAME_SIZE
        lock_at(&space.lock, .Space)
        mapped :: match arch.translate(&space.table, cast[arch_interface.VirtualAddress](at)) {
            case Some(translation) => cast[u64](translation.physical_address) == frame
            case None => false
        }
        if mapped {
            entry :: &unmapped^[made]
            entry^ = Unmapped.{space = cast[u64](space), generation = intrinsics.atomic_load_u32_acquire(&space.header.generation),
                tag = space.table.tag, address = at}
            flush := arch_interface.TlbBatch.{}
            match arch.unmap(&space.table, cast[arch_interface.VirtualAddress](at), .Size4K, &entry.freed, &flush) {
                case Ok(physical) => made += 1
                case Error(error) => {}
            }
        }
        unlock_at(&space.lock, .Space)
    }
    return made
}

/**
 * Count the mappings of a memory object, and of its windows, that cover a page: the spaces evict_page may take it
 * from.
 *
 * Takes the memory's lock, then each window's.
 *
 * @param memory The paged memory, not a window; its lock is taken (level MemoryParent), so the caller holds none of
 *     its.
 * @param page The page's index in memory.
 * @return The number of mappings, which may change once the locks are let go.
 */
mappings_of_page :: fn(memory: ptr[mut Memory], page: u64) -> u64 {
    count := cast[u64](0)
    lock_at(&memory.lock, .MemoryParent)
    count += covering(memory, page)
    with {
        window_address := memory.first_window
    }
    loop {
        if window_address == 0 {
            break
        }
        window :: cast[ptr[mut Memory]](window_address)
        if page >= window.parent_page && page - window.parent_page < window.size / frames.FRAME_SIZE {
            lock_at(&window.lock, .Memory)
            count += covering(window, page - window.parent_page)
            unlock_at(&window.lock, .Memory)
        }
        window_address = window.window_next
    }
    unlock_at(&memory.lock, .MemoryParent)
    return count
}

/**
 * Count a memory object's own mappings that cover a page.
 *
 * @param memory The memory, whose lock the caller holds.
 * @param page The page's index in memory.
 * @return The number of its mappings whose range includes the page.
 */
covering :: fn(memory: ptr[Memory], page: u64) -> u64 {
    count := cast[u64](0)
    with {
        address := memory.first_mapping
    }
    loop {
        if address == 0 {
            break
        }
        mapping :: cast[ptr[MemoryMapping]](address)
        first :: mapping.offset / frames.FRAME_SIZE
        if page >= first && page - first < mapping.size / frames.FRAME_SIZE {
            count += 1
        }
        address = mapping.memory_next
    }
    return count
}

/**
 * Tell whether a page of paged memory was touched through any mapping since this last asked, clearing the marks:
 * memory_page_accessed.
 *
 * The marks are where the hardware keeps them (arch.take_accessed). They're cleared unflushed, so a CPU still holding
 * the page's entry may touch it unmarked, which only makes a page look colder than it is. Takes the memory's lock,
 * each window's and each mapping's space's.
 *
 * @param kernel Unused; the hardware's marks are all that's read.
 * @param memory The paged memory, not a window onto it.
 * @param offset The page's offset in memory, in bytes, page aligned, below its size.
 * @return 1 if it was touched, 0 if not.
 * @error NotPaged The memory isn't paged memory, or is a window.
 * @error InvalidSize The offset isn't page aligned, or is past the memory's end.
 */
page_accessed :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory], offset: u64) -> Result[u64, slop_os.MemoryError] {
    if memory.pager_binding == 0 || memory.parent != 0 {
        return .Error(.NotPaged)
    }
    if offset & (frames.FRAME_SIZE - 1) != 0 || offset >= memory.size {
        return .Error(.InvalidSize)
    }
    page :: offset / frames.FRAME_SIZE
    touched := false
    lock_at(&memory.lock, .MemoryParent)
    touched = take_accessed_in(memory, page) || touched
    with {
        window_address := memory.first_window
    }
    loop {
        if window_address == 0 {
            break
        }
        window :: cast[ptr[mut Memory]](window_address)
        if page >= window.parent_page && page - window.parent_page < window.size / frames.FRAME_SIZE {
            lock_at(&window.lock, .Memory)
            touched = take_accessed_in(window, page - window.parent_page) || touched
            unlock_at(&window.lock, .Memory)
        }
        window_address = window.window_next
    }
    unlock_at(&memory.lock, .MemoryParent)
    return .Ok(if touched { cast[u64](1) } else { cast[u64](0) })
}

/**
 * Tell whether any of a memory object's own mappings of a page was touched, clearing every one's mark.
 *
 * Takes each mapping's space's lock in turn.
 *
 * @param memory The memory, whose lock the caller holds.
 * @param page The page's index in memory.
 * @return True if the hardware marked the page accessed in any of the mappings.
 */
take_accessed_in :: fn(memory: ptr[Memory], page: u64) -> bool {
    touched := false
    with {
        address := memory.first_mapping
    }
    loop {
        if address == 0 {
            break
        }
        mapping :: cast[ptr[MemoryMapping]](address)
        address = mapping.memory_next
        first :: mapping.offset / frames.FRAME_SIZE
        if page < first || page - first >= mapping.size / frames.FRAME_SIZE {
            continue
        }
        space :: cast[ptr[mut AddressSpace]](mapping.space)
        lock_at(&space.lock, .Space)
        touched = arch.take_accessed(&space.table, cast[arch_interface.VirtualAddress](mapping.address + (page - first) * frames.FRAME_SIZE)) || touched
        unlock_at(&space.lock, .Space)
    }
    return touched
}
