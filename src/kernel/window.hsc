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

WINDOW_SIZE : u64 : 64 << 30
WINDOW_ALIGNMENT : u64 : 1 << 30
// The kernel half on 4-level paging: its lowest address, and the top 2 GiB, where kernels are loaded.
KERNEL_HALF_LOW : u64 : 0xffff800000000000
KERNEL_IMAGE_REGION : u64 : 0xffffffff80000000
// Free extents the window keeps track of: more fragmentation than that is a bug.
MAX_WINDOW_EXTENTS :: 64

DEVICE_MAPPING :: arch_interface.Mapping.{protection = .ReadWrite, cache = .Device, user = false, global = true}

WindowError :: enum {
    // No free range of the window is that big.
    OutOfAddresses,
    // No frames for its page tables.
    OutOfMemory,
}

// A free range of the window, in bytes.
Extent :: struct {
    start : u64,
    size : u64,
}

Window :: struct {
    lock : concurrency.SpinLock,
    base : u64,
    count : usize,
    free : Extent[MAX_WINDOW_EXTENTS],
}

/*
 * Place the window, once the direct map's size is known: a random 1 GiB boundary in the kernel half,
 * below or above the direct map, and below the region kernels are loaded in. Every such boundary is
 * as likely; with no_kaslr it's the lowest.
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

/*
 * 64 random bits for laying out the kernel's own regions: the CPU's random source, mixed with the
 * bootloader's, if either has any. 0 without either.
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

/*
 * Map size bytes of device registers from physical on, uncached: where they are. physical needn't be
 * page aligned; what's around it in its pages is mapped too.
 */
map_device :: fn(kernel: ptr[mut Kernel], physical: boot_info.PhysicalAddress, size: u64) -> Result[u64, WindowError] {
    start :: cast[u64](physical) & ~(frames.FRAME_SIZE - 1)
    end :: frames.round_up(cast[u64](physical) + size, frames.FRAME_SIZE)
    address :: map_in_window(kernel, start, end - start, DEVICE_MAPPING)?
    return .Ok(address + (cast[u64](physical) - start))
}

// Unmap what map_device mapped: its address and size, as map_device was given and gave.
unmap_device :: fn(kernel: ptr[mut Kernel], address: u64, size: u64) {
    start :: address & ~(frames.FRAME_SIZE - 1)
    unmap_from_window(kernel, start, frames.round_up(address + size, frames.FRAME_SIZE) - start)
}

// Map size bytes, a multiple of a page, from physical on, with mapping: where.
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

/*
 * Unmap size bytes at address, a multiple of a page, then shoot down the TLB entries, and only then
 * free the tables it emptied and the addresses.
 */
unmap_from_window :: fn(kernel: ptr[mut Kernel], address: u64, size: u64) {
    flush : arch_interface.TlbBatch
    freed : arch_interface.FreedTables
    pages :: size / frames.FRAME_SIZE
    with {
        page : u64 = 0
    }
    loop {
        concurrency.lock(&kernel.page_table_lock)
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
        concurrency.unlock(&kernel.page_table_lock)
        // Every CPU forgets the old entries before an emptied table can be reused
        shootdown(kernel, &flush)
        flush = arch_interface.TlbBatch.{}
        free_tables(kernel, &freed)
    }
    while page < pages
    give_addresses(&kernel.window, address, size)
}

free_tables :: fn(kernel: ptr[mut Kernel], freed: ptr[mut arch_interface.FreedTables]) {
    count :: cast[usize](freed.count)
    runtime.assert(count <= 4, "FreedTables holds 4 frames")
    for i in 0..<count {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, freed.frames[i])
    }
    freed.count = 0
}

// The table frames no mapping took, back to this CPU's frame cache.
give_back_tables :: fn(kernel: ptr[mut Kernel], tables: ptr[mut arch_interface.TableFrames]) {
    count :: cast[usize](tables.count)
    runtime.assert(count <= 4, "TableFrames holds 4 frames")
    for i in 0..<count {
        frames.give_frame(&per_cpu().frame_cache, &kernel.frames, tables.frames[i])
    }
    tables.count = 0
}

// size bytes of the window's addresses, the first free range that's big enough: their start.
take_addresses :: fn(window: ptr[mut Window], size: u64) -> u64? {
    concurrency.lock(&window.lock)
    defer concurrency.unlock(&window.lock)
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

// Give back addresses take_addresses gave, merged with the free ranges on either side.
give_addresses :: fn(window: ptr[mut Window], start: u64, size: u64) {
    concurrency.lock(&window.lock)
    defer concurrency.unlock(&window.lock)
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

// Where a free range ends.
extent_end :: fn(window: ptr[Window], index: usize) -> u64 {
    runtime.assert(index < MAX_WINDOW_EXTENTS, "extent_end takes one of the free ranges")
    return window.free[index].start + window.free[index].size
}

grow_extent :: fn(window: ptr[mut Window], index: usize, size: u64) {
    runtime.assert(index < MAX_WINDOW_EXTENTS, "grow_extent takes one of the free ranges")
    window.free[index].size += size
}

remove_extent :: fn(window: ptr[mut Window], index: usize) {
    count :: window.count
    runtime.assert(count >= 1 && count <= MAX_WINDOW_EXTENTS && index < count, "remove_extent takes one of the free ranges")
    for i in index + 1..<count {
        window.free[i - 1] = window.free[i]
    }
    window.count = count - 1
}
