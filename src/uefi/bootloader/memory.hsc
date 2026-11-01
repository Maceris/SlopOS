package bootloader

import uefi from "std/os"
import boot_info from "../../boot_info"
import boot_protocol from "../../boot_protocol"

/*
 * The firmware's memory map: mapped for the kernel, then converted into the handoff's, sorted, merged and page 0 never
 * usable (docs/specs/boot_info.md, Memory Map), just before the boot services are left, with nothing allocated between.
 */

FOUR_GIGABYTES : u64 : 1 << 32

// What a UEFI memory kind is to the kernel; the bootloader's own kinds say what's the kernel's and the modules'.
memory_kind :: fn(kind: u32) -> boot_info.MemoryKind {
    if kind == KERNEL_MEMORY {
        return .KernelImage
    }
    if kind == MODULE_MEMORY {
        return .BootModule
    }
    conventional :: kind == cast[u32](uefi.MemoryKind.Conventional) || kind == cast[u32](uefi.MemoryKind.BootServicesCode)
        || kind == cast[u32](uefi.MemoryKind.BootServicesData)
    if conventional {
        return .Usable
    }
    if kind == cast[u32](uefi.MemoryKind.LoaderCode) || kind == cast[u32](uefi.MemoryKind.LoaderData) {
        return .BootReclaimable
    }
    if kind == cast[u32](uefi.MemoryKind.AcpiReclaim) {
        return .FirmwareTables
    }
    firmware :: kind == cast[u32](uefi.MemoryKind.AcpiNvs) || kind == cast[u32](uefi.MemoryKind.RuntimeServicesCode)
        || kind == cast[u32](uefi.MemoryKind.RuntimeServicesData) || kind == cast[u32](uefi.MemoryKind.PalCode)
    if firmware {
        return .FirmwareReserved
    }
    if kind == cast[u32](uefi.MemoryKind.Unusable) {
        return .Defective
    }
    return .Reserved
}

// The firmware's memory map, into buffer: its descriptors' count and size, and the key ExitBootServices needs; or null.
MemoryMap :: struct {
    buffer : u64,
    capacity : usize,
    size : usize,
    key : usize,
    descriptor_size : usize,
}

// Room for the memory map, with some to spare for what allocating it, and anything after, adds; or null.
memory_map_buffer :: fn() -> MemoryMap? {
    services :: uefi.boot_services() or_return null
    size := cast[usize](0)
    key := cast[usize](0)
    descriptor_size := cast[usize](0)
    version := cast[u32](0)
    _ = services.get_memory_map(&size, null, &key, &descriptor_size, &version)
    capacity :: size + 32 * (if descriptor_size == 0 { cast[usize](48) } else { descriptor_size })
    buffer :: allocate_pages(LOADER_DATA, cast[u64](capacity)) or_return null
    return MemoryMap.{buffer = buffer, capacity = capacity}
}

// The map read into its buffer now: whether it was.
read_memory_map :: fn(map: ptr[mut MemoryMap]) -> bool {
    services :: uefi.boot_services() or_return false
    map.size = map.capacity
    version := cast[u32](0)
    return services.get_memory_map(&map.size, cast[rawptr](map.buffer), &map.key, &map.descriptor_size, &version) == uefi.SUCCESS
        && map.descriptor_size >= size_of(uefi.MemoryDescriptor)
}

descriptor_at :: fn(map: ptr[MemoryMap], index: usize) -> ptr[uefi.MemoryDescriptor] {
    return cast[ptr[uefi.MemoryDescriptor]](cast[rawptr](map.buffer + cast[u64](index * map.descriptor_size)))
}

/*
 * The direct map and the identity map: the first 4 GiB whole, where the firmware's tables and devices' registers are
 * too, and every other range but reserved and defective memory, at offset and where it is.
 */
map_memory :: fn(tables: ptr[PageTables], offset: u64) -> bool {
    if !map(tables, offset, 0, FOUR_GIGABYTES) || !map(tables, 0, 0, FOUR_GIGABYTES) {
        return false
    }
    memory := memory_map_buffer() or_return false
    if !read_memory_map(&memory) {
        return false
    }
    for i in cast[usize](0)..<memory.size / memory.descriptor_size {
        descriptor :: descriptor_at(&memory, i)
        kind :: memory_kind(descriptor.kind)
        start := descriptor.physical_start
        end :: start + descriptor.pages * 4096
        if kind == .Reserved || kind == .Defective || end <= FOUR_GIGABYTES {
            continue
        }
        start = if start < FOUR_GIGABYTES { FOUR_GIGABYTES } else { start }
        if !map(tables, offset + start, start, end - start) || !map(tables, start, start, end - start) {
            return false
        }
    }
    return true
}

/*
 * The boot services left, with the memory map at that moment in the handoff: read, converted and ExitBootServices
 * called with its key, again if the map changed meanwhile. Whether they were left; nothing of the firmware's is
 * called after.
 */
leave_boot_services :: fn(handoff: ptr[mut boot_protocol.Handoff]) -> bool? {
    services :: uefi.boot_services() or_return null
    memory := memory_map_buffer() or_return null
    for attempt in 0..<4 {
        if !read_memory_map(&memory) {
            return null
        }
        convert_memory_map(&memory, handoff)
        if services.exit_boot_services(uefi.image(), memory.key) == uefi.SUCCESS {
            return true
        }
    }
    return null
}

// A region put among the count before it, in order by base: how many there are now.
insert_region :: fn(handoff: ptr[mut boot_protocol.Handoff], count: usize, region: boot_info.MemoryRegion) -> usize {
    if count >= handoff.regions.count {
        return count
    }
    at := count
    loop {
        if at == 0 || at > handoff.regions.count || cast[u64](handoff.regions[at - 1].range.base) <= cast[u64](region.range.base) {
            break
        }
        if at < handoff.regions.count {
            handoff.regions[at] = handoff.regions[at - 1]
        }
        at -= 1
    }
    if at < handoff.regions.count {
        handoff.regions[at] = region
    }
    return count + 1
}

// The firmware's map as BootInfo's: sorted by base, adjacent regions of a kind merged, and page 0 never usable.
convert_memory_map :: fn(map: ptr[MemoryMap], handoff: ptr[mut boot_protocol.Handoff]) {
    count := cast[usize](0)
    for i in cast[usize](0)..<map.size / map.descriptor_size {
        descriptor :: descriptor_at(map, i)
        if count >= handoff.regions.count || descriptor.pages == 0 {
            continue
        }
        count = insert_region(handoff, count, boot_info.MemoryRegion.{range = boot_info.PhysicalRange.{
            cast[boot_info.PhysicalAddress](descriptor.physical_start), descriptor.pages * 4096}, kind = memory_kind(descriptor.kind)})
    }
    // The framebuffer's memory, which the firmware's map leaves out, as a device's, for the kernel's direct map
    if handoff.has_framebuffer != 0 {
        frame :: handoff.framebuffer
        count = insert_region(handoff, count, boot_info.MemoryRegion.{range = boot_info.PhysicalRange.{
            cast[boot_info.PhysicalAddress](frame.base & ~cast[u64](4095)), (frame.size + (frame.base & 4095) + 4095) & ~cast[u64](4095)},
            kind = .Framebuffer})
    }
    // Page 0 never usable
    if count > 0 && count < handoff.regions.count && cast[u64](handoff.regions[0].range.base) == 0 && handoff.regions[0].kind == .Usable {
        first :: if handoff.regions.count > 0 { handoff.regions[0] } else { boot_info.MemoryRegion.{} }
        for j in 0..<count {
            back :: count - j
            if back < handoff.regions.count && back >= 1 {
                handoff.regions[back] = handoff.regions[back - 1]
            }
        }
        handoff.regions[0] = boot_info.MemoryRegion.{range = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](0), 4096},
            kind = .Reserved}
        if 1 < handoff.regions.count {
            handoff.regions[1] = boot_info.MemoryRegion.{range = boot_info.PhysicalRange.{cast[boot_info.PhysicalAddress](4096),
                first.range.size - 4096}, kind = .Usable}
        }
        count += 1
    }
    // Neighbors of a kind merged
    merged := cast[usize](0)
    for i in 0..<count {
        if i >= handoff.regions.count {
            break
        }
        region :: handoff.regions[i]
        if merged > 0 && merged <= handoff.regions.count {
            last :: &handoff.regions[merged - 1]
            if last.kind == region.kind && cast[u64](last.range.base) + last.range.size == cast[u64](region.range.base) {
                last.range.size += region.range.size
                continue
            }
        }
        if merged < handoff.regions.count {
            handoff.regions[merged] = region
        }
        merged += 1
    }
    handoff.region_count = cast[u64](merged)
}
