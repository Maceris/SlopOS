package bootloader

import uefi from "std/os"
import boot_info from "../../boot_info"
import boot_protocol from "../../boot_protocol"

/*
 * The firmware's memory map: mapped for the kernel, then converted into the handoff's, sorted, merged and page 0 never
 * usable (docs/specs/boot_info.md, Memory Map), just before the boot services are left, with nothing allocated between.
 */

/** 4 GiB in bytes: the low range x86-64's page tables map whole, firmware tables and devices' registers with it. */
FOUR_GIGABYTES : u64 : 1 << 32

/**
 * Tell what a UEFI memory kind is to the kernel; the bootloader's own kinds say what's the kernel's and the modules'.
 *
 * @param kind A memory descriptor's type (UEFI specification, EFI_MEMORY_TYPE), or one of the bootloader's own,
 *     KERNEL_MEMORY, MODULE_MEMORY and PANIC_MEMORY.
 * @return Usable for conventional memory and boot services' code and data, which are free once they're left;
 *     BootReclaimable for the bootloader's own (loader code and data); FirmwareTables for ACPI's reclaimable memory;
 *     FirmwareReserved for ACPI's NVS, runtime services', PAL code and the panic record's page; Defective for unusable
 *     memory; KernelImage and BootModule for the bootloader's kinds; Reserved for anything else, memory-mapped I/O
 *     and kinds it doesn't know included.
 */
memory_kind :: fn(kind: u32) -> boot_info.MemoryKind {
    if kind == KERNEL_MEMORY {
        return .KernelImage
    }
    if kind == MODULE_MEMORY {
        return .BootModule
    }
    // Nothing uses or frees it, and the direct map covers it, so the kernel writes it there
    if kind == PANIC_MEMORY {
        return .FirmwareReserved
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

/** The firmware's memory map, read into a buffer, with what GetMemoryMap says of it. */
MemoryMap :: struct {
    /** The buffer's physical address, in loader-data pages, which the map's descriptors are read into. */
    buffer : u64,
    /** The buffer's size in bytes. */
    capacity : usize,
    /** How many bytes of descriptors the last read wrote; size / descriptor_size is their count. */
    size : usize,
    /** The map's key from the last read, which ExitBootServices needs to say the map hasn't changed since. */
    key : usize,
    /**
     * Each descriptor's size in bytes, which the firmware may make bigger than uefi.MemoryDescriptor, so descriptors
     * are stepped through by it.
     */
    descriptor_size : usize,
}

/**
 * Allocate a buffer for the memory map, with room to spare for what allocating it, and anything after, adds.
 *
 * The spare is 32 descriptors' worth. Boot services have to be running.
 *
 * @return The map, with its buffer and capacity and nothing read yet; null if boot services are gone or the pages
 *     can't be had.
 */
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

/**
 * Read the firmware's memory map into the map's buffer now.
 *
 * @param map The map, whose size, key and descriptor_size are written.
 * @return True if the map was read and its descriptors are at least as big as uefi.MemoryDescriptor; false if boot
 *     services are gone, the buffer was too small, or the firmware failed.
 */
read_memory_map :: fn(map: ptr[mut MemoryMap]) -> bool {
    services :: uefi.boot_services() or_return false
    map.size = map.capacity
    version := cast[u32](0)
    return services.get_memory_map(&map.size, cast[rawptr](map.buffer), &map.key, &map.descriptor_size, &version) == uefi.SUCCESS
        && map.descriptor_size >= size_of(uefi.MemoryDescriptor)
}

/**
 * Find a descriptor in a map read into its buffer.
 *
 * @param map The map, read.
 * @param index The descriptor's index, below size / descriptor_size; it isn't checked.
 * @return A pointer into the map's buffer, good while the buffer isn't read into again.
 */
descriptor_at :: fn(map: ptr[MemoryMap], index: usize) -> ptr[uefi.MemoryDescriptor] {
    return cast[ptr[uefi.MemoryDescriptor]](cast[rawptr](map.buffer + cast[u64](index * map.descriptor_size)))
}

/**
 * Map the direct map and the identity map: on x86-64 the first 4 GiB whole, where the firmware's tables and devices'
 * registers are too, and every other range but reserved and defective memory, at offset and where it is.
 *
 * On AArch64 only memory is mapped, as normal memory; the kernel maps devices' registers itself. Free memory is mapped
 * too, so pages allocated after the map is read here, like the page tables this makes, are mapped as well. Boot
 * services have to be running.
 *
 * @param tables The page tables to map into.
 * @param offset The direct map's offset, a virtual address in the higher half, 1 GiB-aligned (direct_map_offset).
 * @return True if everything was mapped; false if the memory map couldn't be read or page tables couldn't be had,
 *     leaving the tables partly filled.
 */
map_memory :: fn(tables: ptr[PageTables], offset: u64) -> bool {
    // On AArch64 only memory, as normal memory: the kernel maps devices' registers itself
    whole_low :: TARGET_ARCH == .x86_64
    if whole_low && (!map(tables, offset, 0, FOUR_GIGABYTES) || !map(tables, 0, 0, FOUR_GIGABYTES)) {
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
        if kind == .Reserved || kind == .Defective || (whole_low && end <= FOUR_GIGABYTES) {
            continue
        }
        if whole_low && start < FOUR_GIGABYTES {
            start = FOUR_GIGABYTES
        }
        if !map(tables, offset + start, start, end - start) || !map(tables, start, start, end - start) {
            return false
        }
    }
    return true
}

/**
 * Leave the boot services, with the memory map at that moment in the handoff.
 *
 * The map is read, converted and ExitBootServices called with its key, up to 4 times while the map changed meanwhile.
 * Nothing is allocated between the last read and leaving. Once it returns true, nothing of the firmware's but its
 * runtime services may be called.
 *
 * @param handoff The handoff, whose memory regions and region_count are written with the map; its framebuffer has to
 *     be set already, as it's put in the map.
 * @return True once the boot services are left; null if boot services were gone already, the map's buffer couldn't
 *     be had or read, or 4 tries failed, leaving the boot services running.
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

/**
 * Insert a region among those before it, keeping them in order by base.
 *
 * @param handoff The handoff, whose regions hold count regions sorted by base.
 * @param count How many regions are in handoff.regions so far.
 * @param region The region to insert; among regions of the same base it goes after them.
 * @return The new count, count + 1; or count unchanged, the region dropped, when handoff.regions is full.
 */
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

/**
 * Convert the firmware's map to BootInfo's: sorted by base, adjacent regions of a kind merged, and page 0 never usable
 * (docs/specs/boot_info.md, Memory Map).
 *
 * The framebuffer's memory, which the firmware's map leaves out, is added as a Framebuffer region, rounded out to whole
 * pages. Descriptors of no pages, and any past what handoff.regions holds, are dropped.
 *
 * @param map The firmware's map, read.
 * @param handoff The handoff, whose regions and region_count are written over; its framebuffer is read.
 */
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
