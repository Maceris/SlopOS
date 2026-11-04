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
#else_if TARGET_ARCH == .arm64 {
    import arch from "../arch/aarch64"
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
 * Device memory (decisions/0055) is a range of physical addresses that isn't RAM the kernel owns, made
 * with the platform capability: its pages are those addresses, mapped with its cache mode, and nothing
 * is charged but its slot. A window (decisions/0010, 0055) is a range of another memory object, sharing
 * its frames; destroying the memory destroys its windows, unmapping them everywhere, and destroying a
 * window leaves the memory and its other windows. A window can be mapped only as its parent's handle
 * allowed when it was made.
 *
 * Lock order: a memory's lock, then a space's.
 */

/** A leaf of a memory object's page array holds this many frames' addresses. */
PAGES_PER_LEAF :: 512

/**
 * A memory object: anonymous memory, device memory, a window onto another, a boot module's, contiguous (DMA) memory,
 * or paged memory, told apart by which of the fields below are set.
 */
Memory :: struct #align(16) {
    /** The object's header: its kind, generation, owner and charge. */
    header : ObjectHeader,
    /** Held for its lists of mappings and windows: level Memory, or MemoryParent when a window's is taken after it. */
    lock : concurrency.SpinLock,
    /** Its size in bytes, a whole number of pages, at most slop_os.MAX_MEMORY_SIZE except for a boot module's. */
    size : u64,
    /**
     * Its frames, for anonymous and paged memory: a directory frame of leaf frames' addresses in the direct map, each
     * holding PAGES_PER_LEAF frames' physical addresses, 0 until the page is touched. All made with it; 0 for other
     * memory, and once it's released.
     */
    directory : u64,
    /** The first of the mappings of it, linked through memory_next, under lock; 0 for none. */
    first_mapping : u64,
    /** Where its frames start, physically, for device, boot module and contiguous memory; 0 for other memory. */
    physical : u64,
    /** The cache mode its pages are mapped with: device memory's own, a window's parent's, else WriteBack. */
    cache : arch_interface.CacheMode,
    /** How it can be mapped (slop_os.PROTECTION_*): everything, or for a window, what its parent's handle allowed. */
    allowed : u32,
    /** A window's parent memory object, as an address; 0 for memory that isn't a window. */
    parent : u64,
    /** A window's first page in its parent, counted in pages. */
    parent_page : u64,
    /** The next of its parent's windows, under the parent's lock; 0 for the last. */
    window_next : u64,
    /** The previous of its parent's windows, under the parent's lock; 0 for the first. */
    window_previous : u64,
    /** Whether a window is on its parent's list; false once it's been taken off. */
    in_parent : bool,
    /** Its own windows, under lock. */
    first_window : u64,
    /** A boot module's: its frames, at physical, go to the frame allocator once it's released. */
    boot_module : bool,
    /**
     * Contiguous memory's (create_contiguous_memory): the order of the block at physical, plus one; 0 for other memory.
     */
    block_order : u64,
    /** DMA memory's DmaDomain (devices.hsc), as an address; 0 for other memory. */
    domain : u64,
    /** The domain's generation when the memory was made in it, so a destroyed domain's is told apart. */
    domain_generation : u32,
    /** The I/O virtual address its domain mapped it at (translation.hsc); 0 for nowhere. */
    device_address : u64,
    /** Paged memory's pager's wake binding (paging.hsc), as an address; 0 for other memory. */
    pager_binding : u64,
    /** The pager binding's generation when the memory was made, so a binding that's gone is told apart. */
    pager_generation : u32,
    /** Held (level MemoryPages) for its pages' states and its waiting threads. */
    page_lock : concurrency.SpinLock,
    /** The first thread waiting for a page to be supplied, linked through wait_next, under page_lock; 0 for none. */
    fault_waiters : u64,
}

/** A range of a memory object, mapped in an address space. */
MemoryMapping :: struct {
    /** The slab allocator's, while the slot is free. */
    free_link : u64,
    /** The AddressSpace it's mapped in, as an address. */
    space : u64,
    /** The space's generation when it was charged for this. */
    space_generation : u32,
    /** 0, or 1 once someone has claimed it and is taking it down (claim). */
    claimed : u32,
    /** The Memory mapped, as an address. */
    memory : u64,
    /** Its first user virtual address, page aligned. */
    address : u64,
    /** Its size in bytes, a whole number of pages. */
    size : u64,
    /** Where in the memory it starts, in bytes, page aligned. */
    offset : u64,
    /** How it's mapped: slop_os.PROTECTION_* bits, never both writable and executable. */
    protection : u32,
    // Its neighbors on its space's list and its memory's.
    /** The next mapping on its space's list, under the space's lock; 0 for the last. */
    space_next : u64,
    /** The previous mapping on its space's list; 0 for the first. */
    space_previous : u64,
    /** The next mapping on its memory's list, under the memory's lock; 0 for the last. */
    memory_next : u64,
    /** The previous mapping on its memory's list; 0 for the first. */
    memory_previous : u64,
}

/**
 * Count the bytes of frames a memory object's page array takes: the directory, and its leaves.
 *
 * @param size The memory's size in bytes, a whole number of pages.
 * @return The bytes, a whole number of frames: one for the directory, and one per PAGES_PER_LEAF pages or part of it.
 */
page_array_bytes :: fn(size: u64) -> u64 {
    pages :: size / frames.FRAME_SIZE
    leaves :: (pages + PAGES_PER_LEAF - 1) / PAGES_PER_LEAF
    return (1 + leaves) * frames.FRAME_SIZE
}

/**
 * Make anonymous memory, its pages filled with zeroed frames only as they're touched.
 *
 * It's charged for all of its size and its page array when it's made, so a touch can only fail if the machine is out
 * of frames.
 *
 * @param kernel The kernel, whose pools and frames it's made from.
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, as an address; 0 for the kernel's own.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @return The memory, the owner's (or the kernel's) until it's destroyed.
 * @error InvalidSize The size is 0, not a whole number of pages, or more than MAX_MEMORY_SIZE.
 * @error BudgetExceeded The budget can't pay for it; nothing is made.
 * @error OutOfMemory No slot or frames for it or its page array; nothing is left.
 * @error ObjectGone The owner is being destroyed; the memory is destroyed again.
 */
create_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, size: u64) -> Result[ptr[mut Memory], slop_os.MemoryError] {
    return create_memory_charging(kernel, owner, budget, size, size)
}

/**
 * Make anonymous memory as create_memory does, charging a chosen amount for its pages.
 *
 * Its directory and every leaf of its page array are made at once, zeroed, and charged with its slot.
 *
 * @param kernel The kernel, whose pools and frames it's made from.
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, as an address; 0 for the kernel's own.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @param charged The bytes charged for its pages, besides its slot and page array: its size, or for paged memory, 0,
 *     each page being charged as it's supplied.
 * @return The memory, the owner's (or the kernel's) until it's destroyed.
 * @error InvalidSize The size is 0, not a whole number of pages, or more than MAX_MEMORY_SIZE.
 * @error BudgetExceeded The budget can't pay for it; nothing is made.
 * @error OutOfMemory No slot or frames for it or its page array; nothing is left.
 * @error ObjectGone The owner is being destroyed; the memory is destroyed again.
 */
create_memory_charging :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, size: u64, charged: u64)
    -> Result[ptr[mut Memory], slop_os.MemoryError] {
    if size == 0 || size & (frames.FRAME_SIZE - 1) != 0 || size > slop_os.MAX_MEMORY_SIZE {
        return .Error(.InvalidSize)
    }
    object := cast[u64](0)
    match new_object(kernel, .Memory, budget, charged + page_array_bytes(size)) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.MemoryError.BudgetExceeded } else { slop_os.MemoryError.OutOfMemory })
    }
    memory :: cast[ptr[mut Memory]](object)
    memory.size = size
    memory.allowed = 7
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

/**
 * Make device memory: a range of physical addresses that isn't RAM the kernel owns, mapped with its own cache mode.
 *
 * Only its slot is charged. If it covers any of the framebuffer the kernel's console draws on, the console gives the
 * framebuffer up (give_up_framebuffer). The caller checks the platform capability.
 *
 * @param kernel The kernel: its Memory pool gives the slot, its kept RAM ranges are checked, and its framebuffer
 *     console may be turned off.
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget its slot is charged to, as an address; 0 for the kernel's own.
 * @param physical Its first physical address: page aligned, not 0, and not overlapping RAM the kernel owns.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @param cache The cache mode its pages are mapped with.
 * @return The memory, the owner's (or the kernel's) until it's destroyed.
 * @error InvalidSize The size is 0, not a whole number of pages, or more than MAX_MEMORY_SIZE.
 * @error BadAddress The address is 0, not page aligned, wraps past the top, or overlaps RAM the kernel owns.
 * @error BudgetExceeded The budget can't pay for its slot.
 * @error OutOfMemory No slot for it.
 * @error ObjectGone The owner is being destroyed; the memory is destroyed again.
 */
create_device_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, physical: u64, size: u64, cache: arch_interface.CacheMode)
    -> Result[ptr[mut Memory], slop_os.DeviceError] {
    if size == 0 || size & (frames.FRAME_SIZE - 1) != 0 || size > slop_os.MAX_MEMORY_SIZE {
        return .Error(.InvalidSize)
    }
    if physical == 0 || physical & (frames.FRAME_SIZE - 1) != 0 || physical > ~size || overlaps_kernel_ram(kernel, physical, size) {
        return .Error(.BadAddress)
    }
    object := cast[u64](0)
    match new_object(kernel, .Memory, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    memory :: cast[ptr[mut Memory]](object)
    memory.size = size
    memory.physical = physical
    memory.cache = cache
    memory.allowed = 7
    give_up_framebuffer(kernel, physical, size)
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(memory)
}

/**
 * Give up the framebuffer the kernel's console draws on, if a range of device memory covers any of it.
 *
 * Once device memory over it is made for user space, the terminal service draws there from then on (decisions/0138),
 * and the log stays on the serial console. Takes the console's lock (level Console); logs the first time.
 *
 * @param kernel The kernel, whose framebuffer console is turned off.
 * @param physical The device memory's first physical address.
 * @param size Its size in bytes.
 */
give_up_framebuffer :: fn(kernel: ptr[mut Kernel], physical: u64, size: u64) {
    if kernel.framebuffer_size == 0 || physical >= kernel.framebuffer_physical + kernel.framebuffer_size
        || physical + size <= kernel.framebuffer_physical {
        return void
    }
    lock_at(&kernel.console_lock, .Console)
    given_up :: kernel.has_framebuffer_console
    kernel.has_framebuffer_console = false
    unlock_at(&kernel.console_lock, .Console)
    if given_up {
        runtime.log_info("the framebuffer is user space's now: the log stays on the serial console")
    }
}

/**
 * Make a window: a range of another memory object, sharing its frames.
 *
 * It's on the parent's list before anyone can have it, so destroying the parent destroys it too. Only its slot is
 * charged. Takes the parent's lock (level MemoryParent).
 *
 * @param kernel The kernel, whose Memory pool gives the window's slot (charged to budget).
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget its slot is charged to, as an address; 0 for the kernel's own.
 * @param parent The memory it's a window onto; a window may be made onto a window.
 * @param offset Where in the parent it starts, in bytes, page aligned.
 * @param size Its size in bytes, a whole number of pages, at least one, within the parent from offset.
 * @param allowed How it may be mapped, slop_os.PROTECTION_* bits: what the parent's handle allowed. It's narrowed to
 *     what the parent allows.
 * @return The window, the owner's (or the kernel's) until it or its parent is destroyed.
 * @error InvalidSize The size is 0, or the size or offset isn't page aligned, or the range passes the parent's end.
 * @error BudgetExceeded The budget can't pay for its slot.
 * @error OutOfMemory No slot for it.
 * @error ObjectGone The parent or the owner is being destroyed; nothing is left.
 */
create_window :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, parent: ptr[mut Memory], offset: u64, size: u64, allowed: u32)
    -> Result[ptr[mut Memory], slop_os.MemoryError] {
    if size == 0 || size & (frames.FRAME_SIZE - 1) != 0 || offset & (frames.FRAME_SIZE - 1) != 0 || offset > parent.size
        || size > parent.size - offset {
        return .Error(.InvalidSize)
    }
    object := cast[u64](0)
    match new_object(kernel, .Memory, budget, 0) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.MemoryError.BudgetExceeded } else { slop_os.MemoryError.OutOfMemory })
    }
    window :: cast[ptr[mut Memory]](object)
    window.size = size
    window.parent = cast[u64](parent)
    window.parent_page = offset / frames.FRAME_SIZE
    window.cache = parent.cache
    window.allowed = parent.allowed & allowed
    // On the parent's list before anyone can have it, so destroying the parent reaches it
    lock_at(&parent.lock, .MemoryParent)
    gone :: is_dying(cast[u64](parent))
    if !gone {
        window.window_previous = 0
        window.window_next = parent.first_window
        if parent.first_window != 0 {
            cast[ptr[mut Memory]](parent.first_window).window_previous = object
        }
        parent.first_window = object
        window.in_parent = true
    }
    unlock_at(&parent.lock, .MemoryParent)
    if gone {
        release_object(kernel, object)
        return .Error(.ObjectGone)
    }
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(window)
}

/**
 * Find where a page's frame's address is kept in a memory object's page array.
 *
 * @param memory Anonymous or paged memory, which has a page array.
 * @param page The page's index, below the memory's size in pages.
 * @return The slot, a pointer into a leaf in the direct map, valid until the memory is released. It holds 0, a frame's
 *     physical address, or for paged memory PAGE_WANTED or PAGE_REPORTED; read and written atomically.
 */
page_slot :: fn(memory: ptr[Memory], page: u64) -> ptr[mut u64] {
    leaf :: cast[ptr[u64]](memory.directory + (page / PAGES_PER_LEAF % PAGES_PER_LEAF) * 8)^
    return cast[ptr[mut u64]](leaf + page % PAGES_PER_LEAF * 8)
}

/**
 * Find a page's frame, giving anonymous memory a zeroed one if it had none yet.
 *
 * Takes no lock: two callers giving the same page a frame at once agree on one, and the other's goes back.
 *
 * @param kernel The kernel, whose frames a new one comes from.
 * @param memory The memory object, of any kind.
 * @param page The page's index, below the memory's size in pages.
 * @return The frame's physical address: device, boot module and contiguous memory's from their physical address; a
 *     window's, its parent's; paged memory's, 0 if it hasn't been supplied. 0 when anonymous memory needs a frame and
 *     there are none.
 */
frame_for :: fn(kernel: ptr[mut Kernel], memory: ptr[Memory], page: u64) -> u64 {
    if memory.physical != 0 {
        return memory.physical + page * frames.FRAME_SIZE
    }
    if memory.parent != 0 {
        return frame_for(kernel, cast[ptr[Memory]](memory.parent), memory.parent_page + page)
    }
    slot :: page_slot(memory, page)
    held :: intrinsics.atomic_load_u64_acquire(slot)
    // Paged memory's pages are its pager's to supply, and none is a frame until it is
    if memory.pager_binding != 0 {
        return if held >= frames.FRAME_SIZE { held } else { cast[u64](0) }
    }
    if held != 0 {
        return held
    }
    frame :: frames.take_frame(&per_cpu().frame_cache, &kernel.frames) or_return 0
    intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, frame)), cast[usize](frames.FRAME_SIZE))
    // Another fault on the same page may have given it one first
    other, given :: intrinsics.interlocked_compare_exchange_u64(slot, cast[u64](frame), 0)
    if !given {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, frame)
        return other
    }
    return cast[u64](frame)
}

/**
 * Copy bytes between anonymous memory and a user buffer, without mapping the memory (decisions/0098).
 *
 * A page at a time through the direct map, giving pages nothing touched yet zeroed frames. Not device memory, DMA
 * memory, paged memory or a window, whose pages aren't the kernel's to fill. A failure partway leaves what was copied
 * before it.
 *
 * @param kernel The kernel: pages nothing touched yet get zeroed frames from this CPU's frame cache, and the user
 *     buffer is reached through the direct map.
 * @param memory Plain anonymous memory, not device, DMA, paged, contiguous or boot module memory, nor a window; the
 *     caller keeps it alive (a handle or a reference) for the call.
 * @param offset Where in the memory to start, in bytes, any alignment.
 * @param space The address space the user buffer is in; its lock is taken for each page.
 * @param address The user buffer's virtual address, any alignment.
 * @param count How many bytes; offset plus count is at most the memory's size.
 * @param to_user True to copy from the memory to the buffer, which has to be writable; false the other way.
 * @return Null once every byte is copied; WrongKind for memory that isn't plain anonymous memory, InvalidSize for a
 *     range past its end, OutOfMemory if a page needed a frame and there were none, BadAddress if the user buffer
 *     isn't mapped for user mode (or, copying to it, writable) all the way.
 */
copy_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[Memory], offset: u64, space: ptr[mut AddressSpace], address: u64, count: u64,
    to_user: bool) -> slop_os.MemoryError? {
    if memory.physical != 0 || memory.pager_binding != 0 || memory.domain != 0 || memory.parent != 0 {
        return .WrongKind
    }
    if offset > memory.size || count > memory.size - offset {
        return .InvalidSize
    }
    done : u64 = 0
    loop {
        if done >= count {
            break
        }
        at :: offset + done
        within :: at % frames.FRAME_SIZE
        part :: min_u64(frames.FRAME_SIZE - within, count - done)
        frame :: frame_for(kernel, memory, at / frames.FRAME_SIZE)
        if frame == 0 {
            return .OutOfMemory
        }
        page :: cast[u64](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](frame))) + within
        copied :: if to_user { copy_to_user(kernel, space, address + done, page, part) } else { copy_from_user(kernel, space, address + done, page, part) }
        if !copied {
            return .BadAddress
        }
        done += part
    }
    return null
}

/**
 * Destroy a memory object: take down every mapping of it, and destroy its windows; a window leaves its parent's list.
 *
 * DMA memory is unmapped from its domain first, so no device reaches it, and paged memory's waiting threads are woken
 * to touch their pages again, which then fail. Its frames aren't freed here, but by release_memory once no CPU can use
 * them. Called once per object, with no lock held, since taking a mapping down shoots down TLB entries.
 *
 * @param kernel The kernel: its mapping pool gets each mapping's slot back, TLB entries are shot down on every CPU, and
 *     the windows are queued on this CPU's list to destroy later.
 * @param memory The memory being destroyed, already marked dying.
 */
destroy_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    // DMA memory's devices reach it no more, before its frames can go
    unmap_dma_memory(kernel, memory)
    // Paged memory's waiting threads touch their pages again, which are no longer mapped
    if memory.pager_binding != 0 {
        lock_at(&memory.page_lock, .MemoryPages)
        wake_fault_waiters(kernel, memory)
        unlock_at(&memory.page_lock, .MemoryPages)
    }
    destroy_windows(kernel, memory)
    if memory.parent != 0 {
        parent :: cast[ptr[mut Memory]](memory.parent)
        lock_at(&parent.lock, .MemoryParent)
        unlink_window(parent, memory)
        unlock_at(&parent.lock, .MemoryParent)
    }
    loop {
        lock_at(&memory.lock, .Memory)
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
        unlock_at(&memory.lock, .Memory)
        // One claimed elsewhere is being taken down there, and is gone before this is released
        if claimed == 0 {
            break
        }
        take_down(kernel, cast[ptr[mut MemoryMapping]](claimed))
    }
}

/**
 * Destroy a memory object's windows, each once the destroy running on this CPU is done (destroy_later).
 *
 * Each is taken off the list first, so none is reached twice. Takes the memory's lock for each.
 *
 * @param kernel The kernel, on whose calling CPU's list each window is queued (destroy_later).
 * @param memory The memory whose windows are destroyed; its list is empty after.
 */
destroy_windows :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    loop {
        lock_at(&memory.lock, .Memory)
        window :: memory.first_window
        if window != 0 {
            unlink_window(memory, cast[ptr[mut Memory]](window))
        }
        unlock_at(&memory.lock, .Memory)
        if window == 0 {
            break
        }
        destroy_later(kernel, window, cast[ptr[ObjectHeader]](window).generation)
    }
}

/**
 * Take a window off its parent's list, if it's on it.
 *
 * @param parent The window's parent, whose lock the caller holds.
 * @param window The window; its in_parent is false after.
 */
unlink_window :: fn(parent: ptr[mut Memory], window: ptr[mut Memory]) {
    if !window.in_parent {
        return void
    }
    if window.window_previous != 0 {
        cast[ptr[mut Memory]](window.window_previous).window_next = window.window_next
    }
    else {
        parent.first_window = window.window_next
    }
    if window.window_next != 0 {
        cast[ptr[mut Memory]](window.window_next).window_previous = window.window_previous
    }
    window.in_parent = false
}

/**
 * Make a boot module's memory (root_task.hsc), read-only, over the frames the bootloader loaded it into.
 *
 * Only its slot is charged. Its frames go to the frame allocator once it's released. It may be mapped to run, never
 * written: a typed library's text is mapped from it, shared (decisions/0120), as a handle with RIGHT_MEMORY_EXECUTE
 * allows. Nothing is checked of the range: it's the bootloader's.
 *
 * @param kernel The kernel, whose Memory pool gives the slot.
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget its slot is charged to, as an address; 0 for the kernel's own.
 * @param physical The module's first physical address, page aligned.
 * @param size Its size in bytes, a whole number of pages; the frames are owned by the memory from now on.
 * @return The memory, the owner's (or the kernel's).
 * @error OutOfMemory No slot for it.
 * @error BudgetExceeded The budget can't pay for its slot.
 * @error OwnerGone The owner is being destroyed; the memory is destroyed again, and its frames go to the allocator.
 */
create_module_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, physical: u64, size: u64) -> Result[ptr[mut Memory], ObjectError] {
    object :: new_object(kernel, .Memory, budget, 0)?
    memory :: cast[ptr[mut Memory]](object)
    memory.size = size
    memory.physical = physical
    memory.cache = .WriteBack
    memory.allowed = cast[u32](slop_os.PROTECTION_READ) | cast[u32](slop_os.PROTECTION_EXECUTE)
    memory.boot_module = true
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(error)
        }
    }
    return .Ok(memory)
}

/**
 * Make memory in one block of physically contiguous frames, pinned and zeroed: for DMA (devices.hsc) and the firmware
 * tables' copy.
 *
 * The whole block, a power-of-two number of frames that can be more than size, is charged with the slot.
 *
 * @param kernel The kernel: its Memory pool gives the slot, and its frame allocator the block.
 * @param owner The Process that owns it, as an address; 0 for the kernel.
 * @param budget The MemoryBudget it's charged to, as an address; 0 for the kernel's own.
 * @param size Its size in bytes: a whole number of pages, at least one, at most slop_os.MAX_MEMORY_SIZE.
 * @param limit The physical address the block has to end at or below, for devices that reach only so far; 0 for none.
 * @param allowed How it can be mapped, slop_os.PROTECTION_* bits.
 * @return The memory, the owner's (or the kernel's) until it's destroyed.
 * @error InvalidSize The size is 0, not a whole number of pages, more than MAX_MEMORY_SIZE, or more than limit.
 * @error BudgetExceeded The budget can't pay for the block.
 * @error OutOfMemory No slot, or no free block of that order below limit.
 * @error ObjectGone The owner is being destroyed; the memory is destroyed again.
 */
create_contiguous_memory :: fn(kernel: ptr[mut Kernel], owner: u64, budget: u64, size: u64, limit: u64, allowed: u32)
    -> Result[ptr[mut Memory], slop_os.DeviceError] {
    if size == 0 || size & (frames.FRAME_SIZE - 1) != 0 || size > slop_os.MAX_MEMORY_SIZE || (limit != 0 && limit < size) {
        return .Error(.InvalidSize)
    }
    order :: frames.order_for(size)
    object := cast[u64](0)
    match new_object(kernel, .Memory, budget, frames.FRAME_SIZE << order) {
        case Ok(made) => object = made
        case Error(error) => return .Error(if error == .BudgetExceeded { slop_os.DeviceError.BudgetExceeded } else { slop_os.DeviceError.OutOfMemory })
    }
    memory :: cast[ptr[mut Memory]](object)
    block := cast[u64](0)
    match frames.allocate_below(&kernel.frames, order, limit) {
        case Ok(address) => block = cast[u64](address)
        case Error(error) => {
            release_object(kernel, object)
            return .Error(.OutOfMemory)
        }
    }
    intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](block))), cast[usize](frames.FRAME_SIZE << order))
    memory.size = size
    memory.physical = block
    memory.cache = .WriteBack
    memory.allowed = allowed
    memory.block_order = order + 1
    match adopt(owner, object) {
        case Ok => {}
        case Error(error) => {
            _ = destroy_object(kernel, object)
            return .Error(.ObjectGone)
        }
    }
    return .Ok(memory)
}

/**
 * Release a memory object's frames once no CPU can use them: a contiguous block, a boot module's frames, or anonymous
 * and paged memory's frames and page array. Device memory and windows have neither.
 *
 * Called once the memory is destroyed and every CPU has passed a point it couldn't be reached from (or when making it
 * failed); calling it again does nothing.
 *
 * @param kernel The kernel, whose frame allocator the frames go back to.
 * @param memory The memory, no longer mapped anywhere.
 */
release_memory :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory]) {
    if memory.block_order != 0 {
        frames.free(&kernel.frames, cast[boot_info.PhysicalAddress](memory.physical), memory.block_order - 1)
        memory.block_order = 0
        return void
    }
    if memory.boot_module {
        memory.boot_module = false
        frames.add_range(&kernel.frames, memory.physical, memory.physical + memory.size)
        return void
    }
    if memory.directory == 0 {
        return void
    }
    for leaf_index in 0..<PAGES_PER_LEAF {
        leaf :: cast[ptr[u64]](memory.directory + cast[u64](leaf_index) * 8)^
        if leaf != 0 {
            for page in 0..<PAGES_PER_LEAF {
                frame :: cast[ptr[u64]](leaf + cast[u64](page) * 8)^
                // Paged memory's wanted pages hold a mark, not a frame
                if frame >= frames.FRAME_SIZE {
                    frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](frame))
                }
            }
            give_frame_at(kernel, leaf)
        }
    }
    give_frame_at(kernel, memory.directory)
    memory.directory = 0
}

/**
 * Map a range of a memory object into a user address space: nothing is mapped until it's touched.
 *
 * The mapping's slot is charged to the space. Takes the memory's lock, then the space's.
 *
 * @param kernel The kernel, whose mapping pool gives the mapping's slot, charged to the space's budget.
 * @param memory The memory to map.
 * @param space The user address space to map it into.
 * @param address The user virtual address it goes at, page aligned, the whole range in the user half and free of
 *     other mappings and channel rings.
 * @param offset Where in the memory it starts, in bytes, page aligned.
 * @param size Its size in bytes, a whole number of pages, at least one, within the memory from offset.
 * @param protection slop_os.PROTECTION_* bits: at least one, not writable and executable at once, and only what the
 *     memory allows.
 * @return Null once it's mapped; BadProtection or MissingRight for a protection that isn't allowed, InvalidSize for a
 *     bad range of the memory, BadAddress for a bad or taken user range, BudgetExceeded if the space's budget can't
 *     pay for the mapping, OutOfMemory if there's no slot, ObjectGone if the memory or space is being destroyed.
 */
memory_map :: fn(kernel: ptr[mut Kernel], memory: ptr[mut Memory], space: ptr[mut AddressSpace], address: u64, offset: u64,
    size: u64, protection: u32) -> slop_os.MemoryError? {
    writable :: protection & cast[u32](slop_os.PROTECTION_WRITE) != 0
    executable :: protection & cast[u32](slop_os.PROTECTION_EXECUTE) != 0
    if protection == 0 || protection & ~cast[u32](7) != 0 || (writable && executable) {
        return slop_os.MemoryError.BadProtection
    }
    // A window, only as its parent's handle allowed
    if protection & ~memory.allowed != 0 {
        return slop_os.MemoryError.MissingRight
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
    lock_at(&memory.lock, .Memory)
    lock_at(&space.lock, .Space)
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
    unlock_at(&space.lock, .Space)
    unlock_at(&memory.lock, .Memory)
    if failure != 0 {
        slab.free(&kernel.pools.mappings, &kernel.frames, address_of_mapping)
        uncharge(cast[u64](space), generation, slot_size)
        return cast[slop_os.MemoryError](failure)
    }
    return null
}

/**
 * Unmap the mapping that starts at an address in an address space, and free it.
 *
 * Called with no lock held: taking it down shoots down TLB entries. If someone else is taking it down already, this
 * returns before that's done.
 *
 * @param kernel The kernel: the mapping's slot goes back to its pool, and the range's TLB entries are shot down on
 *     every CPU.
 * @param space The user address space.
 * @param address The user virtual address a mapping starts at, as memory_map was given it.
 * @return Null if a mapping starts there; NotMapped if none does.
 */
memory_unmap :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace], address: u64) -> slop_os.MemoryError? {
    lock_at(&space.lock, .Space)
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
    unlock_at(&space.lock, .Space)
    if found == 0 {
        return slop_os.MemoryError.NotMapped
    }
    // Claimed already: it's being taken down anyway
    if claimed {
        take_down(kernel, cast[ptr[mut MemoryMapping]](found))
    }
    return null
}

/**
 * Take down every memory mapping of an address space being destroyed, so no memory object reaches it once it's
 * released.
 *
 * Called with no lock held. Mappings claimed elsewhere are left to whoever claimed them.
 *
 * @param kernel The kernel: each mapping's slot goes back to its pool, and TLB entries are shot down on every CPU.
 * @param space The address space being destroyed.
 */
take_down_space_mappings :: fn(kernel: ptr[mut Kernel], space: ptr[mut AddressSpace]) {
    loop {
        lock_at(&space.lock, .Space)
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
        unlock_at(&space.lock, .Space)
        if claimed == 0 {
            break
        }
        take_down(kernel, cast[ptr[mut MemoryMapping]](claimed))
    }
}

/**
 * Claim a mapping, to take it down: only one caller ever does.
 *
 * Atomic, with no lock needed, though callers hold the space's or the memory's lock so the mapping stays.
 *
 * @param mapping A mapping on its space's and memory's lists, which stays allocated while the caller holds either's
 *     lock.
 * @return True if this caller claimed it, and has to take it down; false if someone else did first.
 */
claim :: fn(mapping: ptr[mut MemoryMapping]) -> bool {
    _, first :: intrinsics.interlocked_compare_exchange_u32(&mapping.claimed, 1, 0)
    return first
}

/**
 * Take down a mapping this caller claimed: off its space's list, so no fault maps more of it, its range unmapped, off
 * its memory's list, then freed and uncharged from its space.
 *
 * Called with no lock held, since unmapping shoots down TLB entries; takes the space's and the memory's locks in turn.
 *
 * @param kernel The kernel: the range's TLB entries are shot down on every CPU, the tables it emptied go to this CPU's
 *     frame cache, and the slot goes back to the mapping pool.
 * @param mapping The mapping, claimed by this caller; it's freed, and can't be used after.
 */
take_down :: fn(kernel: ptr[mut Kernel], mapping: ptr[mut MemoryMapping]) {
    space :: cast[ptr[mut AddressSpace]](mapping.space)
    memory :: cast[ptr[mut Memory]](mapping.memory)
    lock_at(&space.lock, .Space)
    unlink_from_space(space, mapping)
    unlock_at(&space.lock, .Space)
    unmap_user(kernel, space, mapping.address, mapping.size)
    lock_at(&memory.lock, .Memory)
    unlink_from_memory(memory, mapping)
    unlock_at(&memory.lock, .Memory)
    generation :: mapping.space_generation
    slab.free(&kernel.pools.mappings, &kernel.frames, cast[u64](mapping))
    uncharge(cast[u64](space), generation, kernel.pools.mappings.object_size)
}

/**
 * Resolve a page fault in user mode.
 *
 * If it's in memory mapped in the thread's space, and the access is one the mapping allows, the page is mapped, with a
 * frame filled with zeros if it hadn't been touched, or for paged memory, the one its pager supplied, the thread
 * waiting for it if it hasn't yet (paging.hsc). Anonymous memory where the mapping lines up gets a whole 2 MiB page
 * (large_frame). Takes the space's lock for the whole of it.
 *
 * @param kernel The kernel: new frames come from this CPU's frame cache; it runs in the faulting thread's page-fault
 *     handler, on the CPU that took the fault.
 * @param thread The faulting thread, whose space the fault is in.
 * @param fault The fault: its address, the access, and whether the page was present.
 * @return Mapped when the thread can touch it again, including when another CPU mapped it first; Blocked when the
 *     thread waits for the pager, and has to be switched away from; Failed when the address isn't mapped, the access
 *     isn't allowed, the page was present already, or no frame could be had, and the thread can't go on.
 */
resolve_fault :: fn(kernel: ptr[mut Kernel], thread: ptr[mut Thread], fault: arch_interface.PageFault) -> FaultOutcome {
    space :: thread.space
    address :: cast[u64](fault.address) & ~(frames.FRAME_SIZE - 1)
    lock_at(&space.lock, .Space)
    defer unlock_at(&space.lock, .Space)
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
        return .Failed
    }
    protection :: found.protection
    allowed :: match fault.access {
        case .Read => true
        case .Write => protection & cast[u32](slop_os.PROTECTION_WRITE) != 0
        case .Execute => protection & cast[u32](slop_os.PROTECTION_EXECUTE) != 0
    }
    // Pages are mapped with the mapping's protection, so a fault on one that's there broke it
    if !allowed || fault.present {
        return .Failed
    }
    memory :: cast[ptr[Memory]](found.memory)
    page :: (address - found.address + found.offset) / frames.FRAME_SIZE
    root, root_page :: paged_root(memory, page)
    if root.pager_binding != 0 {
        return resolve_paged_fault(kernel, thread, space, address, root, root_page, mapping_for(protection, memory.cache))
    }
    // A whole 2 MiB of anonymous memory, where the mapping lines it up with a large page (decisions/0129)
    match large_frame(kernel, memory, found, address, page) {
        case Some(large) => {
            start :: address & ~(LARGE_PAGE - 1)
            if map_large_locked(kernel, space, start, large, mapping_for(protection, memory.cache)) {
                return .Mapped
            }
        }
        case None => {}
    }
    frame :: frame_for(kernel, memory, page)
    if frame == 0 {
        return .Failed
    }
    mapped, error :: map_pages_locked(kernel, space, address, frame, frames.FRAME_SIZE, mapping_for(protection, memory.cache))
    // Another CPU may have mapped it meanwhile, for a fault of its own
    return match error {
        case Some(failure) => if failure == .AlreadyMapped { FaultOutcome.Mapped } else { FaultOutcome.Failed }
        case None => FaultOutcome.Mapped
    }
}

// A large page's bytes, and pages: a leaf of a memory object's page array.
/** A large page's size in bytes: 2 MiB, the pages one leaf of a page array holds. */
LARGE_PAGE : u64 : 2 * 1024 * 1024
/** A large page's order in the frame allocator: 2 to the 9th, 512 frames. */
LARGE_ORDER : u64 : 9

/**
 * Find the 2 MiB block a large page can map for a fault in anonymous memory (decisions/0127, 0129).
 *
 * A large page can map it when the memory is anonymous memory, not paged, a window or device memory, of 2 MiB or more,
 * whose 2 MiB around the page is whole, the mapping holds all of it at a 2 MiB-aligned address, and its leaf holds a
 * 2 MiB block, given now, zeroed, if the leaf's first page held nothing (with a block of the frame allocator's, frames
 * each allocated on its own, so they're freed one at a time as any others are). A page another fault gave a frame first
 * keeps it, and the block's frame for it goes back. Takes no lock of the memory's.
 *
 * @param kernel The kernel, whose frames a block comes from.
 * @param memory The faulting mapping's memory.
 * @param mapping The faulting mapping, in memory, which the 2 MiB has to lie inside; the caller holds its space's lock,
 *     so it stays.
 * @param address The faulting page's user virtual address, page aligned.
 * @param page The faulting page's index in the memory.
 * @return The block's physical address, 2 MiB aligned; null if a large page can't map it, and the fault maps a page as
 *     before.
 */
large_frame :: fn(kernel: ptr[mut Kernel], memory: ptr[Memory], mapping: ptr[MemoryMapping], address: u64, page: u64) -> u64? {
    if memory.physical != 0 || memory.parent != 0 || memory.pager_binding != 0 || memory.domain != 0 || memory.size < LARGE_PAGE {
        return null
    }
    first :: page / PAGES_PER_LEAF * PAGES_PER_LEAF
    start :: address - (page - first) * frames.FRAME_SIZE
    if (first + PAGES_PER_LEAF) * frames.FRAME_SIZE > memory.size || start & (LARGE_PAGE - 1) != 0 || start < mapping.address
        || start + LARGE_PAGE > mapping.address + mapping.size {
        return null
    }
    held :: intrinsics.atomic_load_u64_acquire(page_slot(memory, first))
    if held == 0 {
        block :: cast[u64](frames.allocate_frames(&kernel.frames, LARGE_ORDER) or_return null)
        intrinsics.mem_zero(cast[mut rawptr](frames.virtual_of(&kernel.frames, cast[boot_info.PhysicalAddress](block))), cast[usize](LARGE_PAGE))
        // Each page claimed for the block; one a fault on the same page gave a frame first keeps it, and the block's
        // frames that weren't claimed go back
        whole := true
        for i in cast[u64](0)..<PAGES_PER_LEAF {
            frame :: block + i * frames.FRAME_SIZE
            other, given :: intrinsics.interlocked_compare_exchange_u64(page_slot(memory, first + i), frame, 0)
            if !given {
                whole = false
                frames.give_frame(&per_cpu().frame_cache, &kernel.frames, cast[boot_info.PhysicalAddress](frame))
            }
        }
        if !whole {
            return null
        }
        return block
    }
    // Given already, by a fault in another mapping: a large page maps it only if it's one block
    if held & (LARGE_PAGE - 1) != 0 {
        return null
    }
    for i in cast[u64](1)..<PAGES_PER_LEAF {
        if intrinsics.atomic_load_u64_acquire(page_slot(memory, first + i)) != held + i * frames.FRAME_SIZE {
            return null
        }
    }
    return held
}

/**
 * Choose how a user mapping's pages are mapped.
 *
 * @param protection slop_os.PROTECTION_* bits, never writable and executable at once.
 * @param cache The memory's cache mode.
 * @return A user, non-global mapping: ReadWrite if writable, else ReadExecute if executable, else Read.
 */
mapping_for :: fn(protection: u32, cache: arch_interface.CacheMode) -> arch_interface.Mapping {
    kind := arch_interface.Protection.Read
    if protection & cast[u32](slop_os.PROTECTION_WRITE) != 0 {
        kind = .ReadWrite
    }
    else if protection & cast[u32](slop_os.PROTECTION_EXECUTE) != 0 {
        kind = .ReadExecute
    }
    return arch_interface.Mapping.{protection = kind, cache = cache, user = true, global = false}
}

/**
 * Tell whether nothing is mapped in a user range of an address space: no memory mapping, and no channel's rings.
 *
 * @param kernel Unused; the space's own lists are all that's read.
 * @param space The address space, whose lock the caller holds.
 * @param address The range's first user virtual address.
 * @param size Its size in bytes.
 * @return True if no mapping or ring overlaps the range.
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

/**
 * Tell whether two address ranges overlap.
 *
 * @param address One range's start.
 * @param size Its size in bytes; 0 overlaps nothing.
 * @param other The other range's start.
 * @param other_size Its size in bytes.
 * @return True if they share any address.
 */
overlaps :: fn(address: u64, size: u64, other: u64, other_size: u64) -> bool {
    return address < other + other_size && other < address + size
}

/**
 * Put a mapping first on its space's list.
 *
 * @param space The space, whose lock the caller holds.
 * @param mapping The mapping, on no space's list.
 */
link_to_space :: fn(space: ptr[mut AddressSpace], mapping: ptr[mut MemoryMapping]) {
    mapping.space_previous = 0
    mapping.space_next = space.first_mapping
    if space.first_mapping != 0 {
        cast[ptr[mut MemoryMapping]](space.first_mapping).space_previous = cast[u64](mapping)
    }
    space.first_mapping = cast[u64](mapping)
}

/**
 * Take a mapping off its space's list.
 *
 * @param space The space, whose lock the caller holds.
 * @param mapping The mapping, on the space's list.
 */
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

/**
 * Put a mapping first on its memory's list.
 *
 * @param memory The memory, whose lock the caller holds.
 * @param mapping The mapping, on no memory's list.
 */
link_to_memory :: fn(memory: ptr[mut Memory], mapping: ptr[mut MemoryMapping]) {
    mapping.memory_previous = 0
    mapping.memory_next = memory.first_mapping
    if memory.first_mapping != 0 {
        cast[ptr[mut MemoryMapping]](memory.first_mapping).memory_previous = cast[u64](mapping)
    }
    memory.first_mapping = cast[u64](mapping)
}

/**
 * Take a mapping off its memory's list.
 *
 * @param memory The memory, whose lock the caller holds.
 * @param mapping The mapping, on the memory's list.
 */
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
