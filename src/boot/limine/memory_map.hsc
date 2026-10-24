package limine_boot

import boot_info from "../../boot_info"
import runtime from "base"

/*
 * BootInfo's memory map from Limine's (docs/specs/boot_info.md, Memory Map): sorted, not
 * overlapping, on 4 KiB boundaries, adjacent regions of the same kind merged, and page 0 never
 * Usable. Limine's own entries are sorted, and its usable and bootloader-reclaimable ones are
 * page-aligned and overlap nothing; any other entry may be unaligned and overlap others.
 */

PAGE_SIZE : u64 : 4096

align_down :: fn(value: u64) -> u64 {
    return value & ~(PAGE_SIZE - 1)
}

align_up :: fn(value: u64) -> u64 {
    return align_down(value + PAGE_SIZE - 1)
}

// How many regions the map can need for count Limine entries: page 0 and the carved range each add up to two.
memory_map_capacity :: fn(count: usize) -> usize {
    return count + 3
}

memory_kind :: fn(entry: ptr[MemoryMapEntry], executable_physical: u64) -> boot_info.MemoryKind {
    if entry.kind == MEMORY_USABLE {
        return .Usable
    }
    if entry.kind == MEMORY_BOOTLOADER_RECLAIMABLE {
        return .BootReclaimable
    }
    if entry.kind == MEMORY_EXECUTABLE_AND_MODULES {
        if executable_physical >= entry.base && executable_physical - entry.base < entry.length {
            return .KernelImage
        }
        return .BootModule
    }
    if entry.kind == MEMORY_FRAMEBUFFER {
        return .Framebuffer
    }
    if entry.kind == MEMORY_ACPI_RECLAIMABLE {
        return .FirmwareTables
    }
    if entry.kind == MEMORY_ACPI_NVS {
        return .FirmwareReserved
    }
    if entry.kind == MEMORY_BAD_MEMORY {
        return .Defective
    }
    // RESERVED, RESERVED_MAPPED, and anything newer than this code
    return .Reserved
}

/*
 * Fill regions from Limine's entries, with carved (physical memory taken from a usable entry for
 * BootInfo's arrays) as BootReclaimable. Returns how many regions there are.
 */
build_memory_map :: fn(
    response: ptr[MemoryMapResponse],
    executable_physical: u64,
    carved: boot_info.PhysicalRange,
    regions: mut boot_info.MemoryRegion[],
) -> usize {
    count : usize = 0
    for entry in pointers(response.entries, response.entry_count) {
        kind :: memory_kind(entry, executable_physical)
        start := align_down(entry.base)
        end := align_up(entry.base + entry.length)
        // Usable regions shrink to page boundaries, others grow to them
        if kind == .Usable {
            start = align_up(entry.base)
            end = align_down(entry.base + entry.length)
        }
        if kind == .Usable && start < PAGE_SIZE && end > start {
            count = add_region(regions, count, 0, PAGE_SIZE, .Reserved)
            start = PAGE_SIZE
        }
        count = add_region(regions, count, start, end, kind)
    }
    count = carve_out(regions, count, carved)
    return merge_adjacent(regions, count)
}

/*
 * Add [start, end) of kind after the regions so far, which end at or after start only where
 * growing made them overlap. Where they do, a non-Usable region keeps the overlap from a Usable
 * one, the same kinds merge, and of two other kinds, the earlier keeps it.
 */
add_region :: fn(regions: mut boot_info.MemoryRegion[], count: usize, start, end: u64, kind: boot_info.MemoryKind) -> usize {
    // memory_map_capacity leaves room for one more each time
    runtime.assert(count < regions.count, "add_region needs room for another region")
    first := start
    last := end
    total := count
    loop {
        previous :: &regions[total - 1]
        previous_end :: cast[u64](previous.range.base) + previous.range.size
        if previous.kind == kind {
            // Merge by taking the previous region out and adding the combined one
            first = cast[u64](previous.range.base)
            if previous_end > last {
                last = previous_end
            }
            total -= 1
            continue
        }
        if previous.kind == .Usable {
            // The new region isn't Usable, so it keeps the overlap
            previous.range.size = first - cast[u64](previous.range.base)
            if previous.range.size == 0 {
                total -= 1
            }
            continue
        }
        first = previous_end
        break
    }
    while total > 0 && cast[u64](regions[total - 1].range.base) + regions[total - 1].range.size > first
    if first >= last {
        return total
    }
    regions[total] = region(first, last, kind)
    return total + 1
}

region :: fn(start, end: u64, kind: boot_info.MemoryKind) -> boot_info.MemoryRegion {
    return boot_info.MemoryRegion.{
        range = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](start), end - start},
        kind = kind,
    }
}

/*
 * Mark carved as BootReclaimable, splitting the Usable region it was taken from.
 * Returns the new count.
 */
carve_out :: fn(regions: mut boot_info.MemoryRegion[], count: usize, carved: boot_info.PhysicalRange) -> usize {
    // memory_map_capacity leaves room for the two more a split makes
    runtime.assert(count < regions.count && count + 2 <= regions.count, "carve_out needs room for two more regions")
    carved_start :: cast[u64](carved.base)
    carved_end :: carved_start + carved.size
    for i in 0..<count {
        current :: regions[i]
        start :: cast[u64](current.range.base)
        end :: start + current.range.size
        if current.kind != .Usable || carved_start < start || carved_end > end {
            continue
        }
        // Up to three regions in place of one: what's left before, the carved range, what's left after
        parts : boot_info.MemoryRegion[3]
        part_count : usize = 0
        if carved_start > start {
            parts[part_count] = region(start, carved_start, .Usable)
            part_count += 1
        }
        parts[part_count] = region(carved_start, carved_end, .BootReclaimable)
        part_count += 1
        if end > carved_end {
            parts[part_count] = region(carved_end, end, .Usable)
            part_count += 1
        }
        // Move the regions after this one up, from the end, to make room
        added :: part_count - 1
        with {
            j := count
        }
        loop {
            j -= 1
            regions[j + added] = regions[j]
        }
        while j > i + 1
        for k in 0..<part_count {
            regions[i + k] = parts[k]
        }
        return count + added
    }
    return count
}

// Merge regions of the same kind that touch. Returns the new count.
merge_adjacent :: fn(regions: mut boot_info.MemoryRegion[], count: usize) -> usize {
    runtime.assert(count <= regions.count, "merge_adjacent's count is more than there are regions")
    if count == 0 {
        return 0
    }
    kept : usize = 1
    for i in 1..<count {
        // Each region is kept at most once, so kept never passes i
        runtime.assert(kept <= i, "merge_adjacent kept more regions than it's seen")
        previous :: &regions[kept - 1]
        current :: regions[i]
        if previous.kind == current.kind && cast[u64](previous.range.base) + previous.range.size == cast[u64](current.range.base) {
            previous.range.size += current.range.size
            continue
        }
        regions[kept] = current
        kept += 1
    }
    return kept
}

// The usable memory BootInfo's arrays go in: the first usable entry with room, past page 0.
find_carve :: fn(response: ptr[MemoryMapResponse], size: u64) -> boot_info.PhysicalRange? {
    for entry in pointers(response.entries, response.entry_count) {
        if entry.kind != MEMORY_USABLE {
            continue
        }
        start := align_up(entry.base)
        end :: align_down(entry.base + entry.length)
        if start < PAGE_SIZE {
            start = PAGE_SIZE
        }
        if end > start && end - start >= size {
            return boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](start), size}
        }
    }
    return null
}
