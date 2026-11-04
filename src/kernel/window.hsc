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
 * The kernel window (roadmap M3, decisions/0048's amendment): kernel virtual addresses for what the
 * kernel maps besides the direct map and its image, like device registers. It's WINDOW_SIZE bytes at
 * a random 1 GiB boundary in the kernel half, away from the direct map and the image (KASLR,
 * decisions/0021), or the lowest such boundary with no_kaslr.
 *
 * Its addresses are handed out first fit, in pages, from a sorted list of free extents. Unmapping
 * shoots down the TLB entries on every CPU before the addresses, and any tables it emptied, are used
 * again.
 */

/** The window's size in bytes: 64 GiB of kernel virtual addresses. */
WINDOW_SIZE : u64 : 64 << 30
/** The alignment of the window's start, in bytes: 1 GiB. */
WINDOW_ALIGNMENT : u64 : 1 << 30
// The kernel half on 4-level paging: its lowest address, and the top 2 GiB, where kernels are loaded.
/** The lowest virtual address of the kernel half on 4-level paging. */
KERNEL_HALF_LOW : u64 : 0xffff800000000000
/** The start of the top 2 GiB of virtual addresses, where kernels are loaded; the window stays below it. */
KERNEL_IMAGE_REGION : u64 : 0xffffffff80000000
/** The most free extents the window keeps track of: more fragmentation than that is a bug, and asserts. */
MAX_WINDOW_EXTENTS :: 64

/** How device registers are mapped in the window: kernel only, readable and writable, uncached, and global. */
DEVICE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = true}

/** Why the window couldn't map something. */
WindowError :: enum {
    /** No free range of the window is that big. */
    OutOfAddresses,
    /** No frames for its page tables. Not returned yet: the window's mappings stop the kernel when frames run out. */
    OutOfMemory,
}

/** A free range of the window's virtual addresses. */
Extent :: struct {
    /** Its first kernel virtual address, page aligned. */
    start : u64,
    /** Its size in bytes, a multiple of a page, never 0 while it's in the list. */
    size : u64,
}

/** The kernel window: where it is, and which of its addresses are free. */
Window :: struct {
    /** Held (level Window) while the free list is read or changed; not while anything is mapped. */
    lock : concurrency.SpinLock,
    /** Its first kernel virtual address, WINDOW_ALIGNMENT aligned, set once by start_window. */
    base : u64,
    /** How many of free's extents are in use, at most MAX_WINDOW_EXTENTS. */
    count : usize,
    /** The free ranges, sorted by start, none touching another; the first count are in use. */
    free : Extent[MAX_WINDOW_EXTENTS],
}

/**
 * Place the window, once the direct map's size is known.
 *
 * It goes at a random 1 GiB boundary in the kernel half, below or above the direct map, and below the region kernels
 * are loaded in. Every such boundary is as likely; with no_kaslr it's the lowest. The whole window starts free.
 * Called once, on the boot CPU, before anything is mapped in the window. Stops the kernel (an assertion) if the kernel
 * half has no room for it.
 *
 * @param kernel The kernel, whose window is set and whose options say whether no_kaslr is on.
 * @param info The boot information: the direct map's offset, and the bootloader's entropy for the choice.
 * @param direct_bytes How many bytes the direct map covers from its offset, which the window stays clear of.
 */
start_window :: fn(kernel: ptr[mut Kernel], info: ptr[boot_info.BootInfo], direct_bytes: u64) {
    direct_start :: info.direct_map_offset & ~(WINDOW_ALIGNMENT - 1)
    direct_end :: frames.round_up(info.direct_map_offset + direct_bytes, WINDOW_ALIGNMENT)
    below :: if direct_start >= KERNEL_HALF_LOW + WINDOW_SIZE { (direct_start - KERNEL_HALF_LOW - WINDOW_SIZE) / WINDOW_ALIGNMENT + 1 } else { cast[u64](0) }
    above :: if KERNEL_IMAGE_REGION >= direct_end + WINDOW_SIZE { (KERNEL_IMAGE_REGION - direct_end - WINDOW_SIZE) / WINDOW_ALIGNMENT + 1 } else { cast[u64](0) }
    runtime.assert(below + above > 0, "the kernel half has room for the window beside the direct map")
    choice :: if kernel.options.no_kaslr { cast[u64](0) } else { random_seed(info) % (below + above) }
    base :: if choice < below { KERNEL_HALF_LOW + choice * WINDOW_ALIGNMENT } else { direct_end + (choice - below) * WINDOW_ALIGNMENT }
    kernel.window.base = base
    kernel.window.count = 1
    kernel.window.free[0] = Extent.{base, WINDOW_SIZE}
    runtime.log_info("kernel window at %{#018x}", base)
}

/**
 * Make 64 random bits for laying out the kernel's own regions.
 *
 * The CPU's random source is tried up to ten times; the bootloader's entropy, if it gave any, is mixed in by
 * exclusive or, a byte at a time over the eight byte positions. Logs a warning when the result is 0.
 *
 * @param info The boot information, whose bootloader_entropy is used if it's there.
 * @return The bits; 0 when neither source had any, which places the window the same way every boot.
 */
random_seed :: fn(info: ptr[boot_info.BootInfo]) -> u64 {
    seed : u64 = 0
    for i in 0..<10 {
        match arch.hardware_entropy() {
            case Some(value) => {
                seed = value
                break
            }
            case None => {}
        }
    }
    match info.bootloader_entropy {
        case Some(bytes) => {
            for byte, i in bytes {
                seed = seed ~ (cast[u64](byte) << ((cast[u64](i) % 8) * 8))
            }
        }
        case None => {}
    }
    if seed == 0 {
        runtime.log_warn("no random source: the kernel window is at the same address on every boot")
    }
    return seed
}

/**
 * Map device registers into the kernel window, uncached, for the kernel's own use.
 *
 * The whole pages around the range are mapped, so what's beside it in those pages is reachable too. The mapping stays
 * until unmap_device. Takes the window's lock and the kernel's page-table lock (level PageTable), so it's called with
 * neither held. Stops the kernel if no frames are left for page tables.
 *
 * @param kernel The kernel, whose window and page table are used.
 * @param physical The registers' physical address, which needn't be page aligned.
 * @param size How many bytes of registers from physical, more than 0.
 * @return The kernel virtual address physical is mapped at, with the same offset into its page.
 * @error OutOfAddresses No free range of the window is big enough for the pages; nothing is mapped.
 */
map_device :: fn(kernel: ptr[mut Kernel], physical: boot_info.PhysicalAddress, size: u64) -> Result[u64, WindowError] {
    start :: cast[u64](physical) & ~(frames.FRAME_SIZE - 1)
    end :: frames.round_up(cast[u64](physical) + size, frames.FRAME_SIZE)
    address :: map_in_window(kernel, start, end - start, DEVICE_MAPPING)?
    return .Ok(address + (cast[u64](physical) - start))
}

/**
 * Unmap device registers map_device mapped, and give back their window addresses.
 *
 * Every CPU has forgotten the mapping (a TLB shootdown) before the addresses can be used again, so this is called with
 * no lock held.
 *
 * @param kernel The kernel, whose window and page table are used.
 * @param address The kernel virtual address map_device returned.
 * @param size The size in bytes map_device was given.
 */
unmap_device :: fn(kernel: ptr[mut Kernel], address: u64, size: u64) {
    start :: address & ~(frames.FRAME_SIZE - 1)
    unmap_from_window(kernel, start, frames.round_up(address + size, frames.FRAME_SIZE) - start)
}

/**
 * Map a physical range into the kernel window, a 4 KiB page at a time.
 *
 * Takes the window's lock, then the kernel's page-table lock (level PageTable) for each page. Table frames come from
 * this CPU's frame cache, and running out of them stops the kernel; what's left of them goes back to the cache.
 *
 * @param kernel The kernel, whose window and page table are used.
 * @param physical The range's physical address, page aligned.
 * @param size Its size in bytes, a multiple of a page.
 * @param mapping How every page is mapped: protection, cache mode, kernel only, global.
 * @return The kernel virtual address the range starts at in the window, page aligned.
 * @error OutOfAddresses No free range of the window is big enough; nothing is mapped.
 */
map_in_window :: fn(kernel: ptr[mut Kernel], physical: u64, size: u64, mapping: arch_interface.Mapping) -> Result[u64, WindowError] {
    address :: take_addresses(&kernel.window, size) or_return .Error(.OutOfAddresses)
    mapper : Mapper
    mapper.pages_1g = arch.supports_page_size(.Size1G)
    // Page by page: a window's mappings are small, and unmapping takes them page by page too
    for offset in 0..<size / frames.FRAME_SIZE {
        map_page(kernel, address + offset * frames.FRAME_SIZE, physical + offset * frames.FRAME_SIZE, .Size4K, mapping, &mapper)
    }
    give_back_tables(kernel, &mapper.tables)
    return .Ok(address)
}

/**
 * Unmap a range of the kernel window and give its addresses back.
 *
 * The pages are unmapped under the kernel's page-table lock, in turns that end when the freed-tables batch fills;
 * after each, the TLB entries are shot down from every CPU, and only then are the tables it emptied freed. The
 * addresses go back to the window last. Called with no lock held, since a shootdown is. Asserts that every page in
 * the range was mapped by the window.
 *
 * @param kernel The kernel, whose window and page table are used.
 * @param address The range's first kernel virtual address, page aligned, as map_in_window returned it.
 * @param size Its size in bytes, a multiple of a page, as it was mapped.
 */
unmap_from_window :: fn(kernel: ptr[mut Kernel], address: u64, size: u64) {
    flush : arch_interface.TlbBatch
    freed : arch_interface.FreedTables
    pages :: size / frames.FRAME_SIZE
    with {
        page : u64 = 0
    }
    loop {
        lock_at(&kernel.page_table_lock, .PageTable)
        loop {
            result :: arch.unmap(&kernel.page_table, cast[arch_interface.VirtualAddress](address + page * frames.FRAME_SIZE), .Size4K,
                &freed, &flush)
            match result {
                case Ok(physical) => page += 1
                case Error(error) => {
                    runtime.assert(error == .NeedFreedSpace, "the window unmaps only what it mapped, a page at a time")
                    break
                }
            }
        }
        while page < pages
        unlock_at(&kernel.page_table_lock, .PageTable)
        // Every CPU forgets the old entries before an emptied table can be reused
        shootdown(kernel, &flush)
        flush = arch_interface.TlbBatch.{}
        free_tables(kernel, &freed)
    }
    while page < pages
    give_addresses(&kernel.window, address, size)
}

/**
 * Give back page-table frames an unmapping emptied, to this CPU's frame cache.
 *
 * Only once every CPU has forgotten the entries that led to them (after a shootdown), since a CPU's walker may still
 * read them until then. Asserts there are at most four.
 *
 * @param kernel The kernel, whose frame allocator they go back to.
 * @param freed The emptied tables' physical frames, which this takes; its count is 0 after.
 */
free_tables :: fn(kernel: ptr[mut Kernel], freed: ptr[mut arch_interface.FreedTables]) {
    count :: cast[usize](freed.count)
    runtime.assert(count <= 4, "FreedTables holds 4 frames")
    for i in 0..<count {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, freed.frames[i])
    }
    freed.count = 0
}

/**
 * Give back the table frames no mapping took, to this CPU's frame cache.
 *
 * They were never in a table, so they can go at once. Asserts there are at most four.
 *
 * @param kernel The kernel, whose frame allocator they go back to.
 * @param tables The unused zeroed frames, which this takes; its count is 0 after.
 */
give_back_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[mut arch_interface.TableFrames]) {
    count :: cast[usize](tables.count)
    runtime.assert(count <= 4, "TableFrames holds 4 frames")
    for i in 0..<count {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, tables.frames[i])
    }
    tables.count = 0
}

/**
 * Take addresses of the window, first fit: from the lowest free range that's big enough.
 *
 * Takes the window's lock (level Window).
 *
 * @param window The window, its free list sorted by address.
 * @param size How many bytes of addresses, a multiple of a page.
 * @return The addresses' start, a kernel virtual address that's page aligned when size is; null when no free range is
 *     that big, and nothing is taken.
 */
take_addresses :: fn(window: ptr[mut Window], size: u64) -> u64? {
    lock_at(&window.lock, .Window)
    defer unlock_at(&window.lock, .Window)
    count :: window.count
    runtime.assert(count <= MAX_WINDOW_EXTENTS, "the window keeps up to MAX_WINDOW_EXTENTS free ranges")
    for i in 0..<count {
        extent :: &window.free[i]
        if extent.size >= size {
            start :: extent.start
            extent.start += size
            extent.size -= size
            if extent.size == 0 {
                remove_extent(window, i)
            }
            return start
        }
    }
    return null
}

/**
 * Give back addresses take_addresses gave, merged with the free ranges on either side.
 *
 * Takes the window's lock (level Window). A range that touches no free range takes a slot of its own, and asserts if
 * all MAX_WINDOW_EXTENTS are in use.
 *
 * @param window The window; its lock is taken (level Window), so the caller doesn't hold it.
 * @param start The addresses' start, as take_addresses returned it.
 * @param size Their size in bytes, as take_addresses was given; none of them may be free already.
 */
give_addresses :: fn(window: ptr[mut Window], start: u64, size: u64) {
    lock_at(&window.lock, .Window)
    defer unlock_at(&window.lock, .Window)
    count :: window.count
    runtime.assert(count <= MAX_WINDOW_EXTENTS, "the window keeps up to MAX_WINDOW_EXTENTS free ranges")
    // The first free range after it
    found := count
    for i in 0..<count {
        if window.free[i].start > start {
            found = i
            break
        }
    }
    after :: found
    runtime.assert(after <= count, "the free range after it is one of them, or none")
    if after > 0 && extent_end(window, after - 1) == start {
        // Joins the range before it, and the one after it too if it reaches it
        grow_extent(window, after - 1, size)
        if after < count && start + size == window.free[after].start {
            grow_extent(window, after - 1, window.free[after].size)
            remove_extent(window, after)
        }
        return void
    }
    if after < count && start + size == window.free[after].start {
        window.free[after].start = start
        window.free[after].size += size
        return void
    }
    runtime.assert(count < MAX_WINDOW_EXTENTS, "the window's free ranges fit in MAX_WINDOW_EXTENTS")
    for i in after..<count #reverse {
        window.free[i + 1] = window.free[i]
    }
    window.free[after] = Extent.{start, size}
    window.count = count + 1
}

/**
 * Find where a free range of the window ends.
 *
 * @param window The window, its lock held by the caller.
 * @param index The free range's index, below the window's count; asserts it's below MAX_WINDOW_EXTENTS.
 * @return The kernel virtual address just past the range.
 */
extent_end :: fn(window: ptr[Window], index: usize) -> u64 {
    runtime.assert(index < MAX_WINDOW_EXTENTS, "extent_end takes one of the free ranges")
    return window.free[index].start + window.free[index].size
}

/**
 * Grow a free range of the window at its end.
 *
 * @param window The window, its lock held by the caller.
 * @param index The free range's index, below the window's count; asserts it's below MAX_WINDOW_EXTENTS.
 * @param size How many bytes to add; the addresses after the range have to be free.
 */
grow_extent :: fn(window: ptr[mut Window], index: usize, size: u64) {
    runtime.assert(index < MAX_WINDOW_EXTENTS, "grow_extent takes one of the free ranges")
    window.free[index].size += size
}

/**
 * Take a free range out of the window's list, moving the later ones down so it stays sorted.
 *
 * @param window The window, its lock held by the caller.
 * @param index The free range's index, below the window's count, which asserts.
 */
remove_extent :: fn(window: ptr[mut Window], index: usize) {
    count :: window.count
    runtime.assert(count >= 1 && count <= MAX_WINDOW_EXTENTS && index < count, "remove_extent takes one of the free ranges")
    for i in index + 1..<count {
        window.free[i - 1] = window.free[i]
    }
    window.count = count - 1
}
