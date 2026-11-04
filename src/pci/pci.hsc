/*
 * PCIe from the firmware tables' copy (decisions/0073, 0074): where a host bridge's configuration space is (ECAM),
 * which buses it has, the windows of address space BARs may be placed in, and how its functions' requester IDs
 * become MSI sources; and reading and writing a function's configuration space through a mapping of it.
 *
 * On x86-64 the ECAM is the MCFG's first allocation. Its windows are in ACPI's _CRS, which is AML, so until there's an
 * ACPI service they're the gaps the memory map leaves (as Linux's pci=nocrs does): from the top of RAM below 4 GiB up
 * to the I/O APIC's and local APIC's addresses at 0xFEC00000, and from above everything else up 64 GiB. On AArch64
 * they're the device tree's host bridge: its reg, bus-range, ranges and msi-map.
 */
/**
 * PCIe host bridges from the firmware tables, and reading and writing a function's configuration space.
 *
 * SPEC: PCI Firmware Specification 3.3, §4.1.2 (the MCFG); PCI Express Base Specification 5.0, §7.2.2 (ECAM),
 *     §7.5.1 (configuration headers)
 * SPEC: Devicetree Specification 0.4; PCI Bus Binding to Open Firmware (ranges' three cells); Linux's pci-host-generic
 *     and pci-msi bindings (msi-map)
 */
package pci

import intrinsics from "base"
import slop_os from "std/os"
import devicetree from "../devicetree"

/** The most windows a Host keeps: 4; more are dropped. */
MAX_WINDOWS :: 4
/** The bytes of each bus's configuration space through ECAM, 1 MiB: 32 devices of 8 functions, 4 KiB each. */
BUS_BYTES : u64 : 1 << 20
/** The bytes of one function's configuration space through ECAM: 4 KiB. */
FUNCTION_BYTES : u64 : 4096
/** Where the local APIC's and I/O APIC's registers start on x86-64, which no BAR may reach. */
X86_DEVICE_TOP : u64 : 0xfec00000
/** The 64-bit window's size on x86-64, 64 GiB, from above RAM, the ECAM and 4 GiB. */
X86_WIDE_WINDOW : u64 : 64 << 30

// ---- Configuration space registers, as byte offsets (a type 0 header, and a type 1's bus numbers and windows)

/** The vendor ID, a u16; NO_VENDOR where there's no function. */
VENDOR_ID : u64 : 0x00
/** The device ID, a u16. */
DEVICE_ID : u64 : 0x02
/** The command register, a u16: COMMAND_MEMORY, COMMAND_BUS_MASTER and the rest. */
COMMAND : u64 : 0x04
/** The status register, a u16: STATUS_CAPABILITIES and the rest. */
STATUS : u64 : 0x06
/** The revision ID in the low byte, then the programming interface, subclass and base class, a u32. */
CLASS_REVISION : u64 : 0x08
/** The header type, a u8: 0 for an endpoint, 1 for a bridge, bit 7 set for a multi-function device. */
HEADER_TYPE : u64 : 0x0e
/** The first BAR, a u32; the others follow it, 4 bytes apart, 6 in a type 0 header and 2 in a type 1. */
BAR0 : u64 : 0x10
/** A bridge's primary bus number, a u8. */
PRIMARY_BUS : u64 : 0x18
/** A bridge's secondary bus number, the bus behind it, a u8. */
SECONDARY_BUS : u64 : 0x19
/** A bridge's subordinate bus number, the highest behind it, a u8. */
SUBORDINATE_BUS : u64 : 0x1a
/** A bridge's memory window's base, a u16: bits 31 to 20 of the address in its top 12 bits. */
MEMORY_BASE : u64 : 0x20
/** A bridge's memory window's limit, a u16, as MEMORY_BASE, the window running to the end of that MiB. */
MEMORY_LIMIT : u64 : 0x22
/** The capabilities pointer, a u8: the first capability's offset, its low 2 bits reserved. */
CAPABILITIES : u64 : 0x34
/** The command register's memory space enable: the function answers its memory BARs. */
COMMAND_MEMORY : u16 : 1 << 1
/** The command register's bus master enable: the function may do DMA, and send MSIs. */
COMMAND_BUS_MASTER : u16 : 1 << 2
/** The status register's capabilities list bit: the function has a capabilities list. */
STATUS_CAPABILITIES : u16 : 1 << 4
/** The vendor ID read where there's no function. */
NO_VENDOR : u16 : 0xffff

/** A range of address space a host bridge forwards to PCIe: at cpu for the CPU, at pci for its devices. */
Window :: struct {
    /** Where the range starts as the CPU sees it, a physical address. */
    cpu : u64,
    /** Where the range starts as its devices see it, a PCI bus address, which a BAR is programmed with. */
    pci : u64,
    /** The range's size in bytes. */
    size : u64,
    /** Whether it's above 4 GiB, for 64-bit BARs only. */
    wide : bool,
    /** Whether it's for prefetchable BARs. */
    prefetchable : bool,
}

/** A host bridge: its configuration space, at ecam for first_bus to last_bus, its windows, and its msi-map. */
Host :: struct {
    /** The physical address of first_bus's configuration space through ECAM. */
    ecam : u64,
    /** Its PCI segment group, 0 from a device tree. */
    segment : u16,
    /** The first bus it has. */
    first_bus : u8,
    /** The last bus it has, at least first_bus. */
    last_bus : u8,
    /** The windows BARs may be placed in, the first window_count of them. */
    windows : Window[MAX_WINDOWS],
    /** How many of windows are used, 0 to MAX_WINDOWS. */
    window_count : u32,
    /** The first requester ID msi-map maps, rid_base to rid_base + msi_count - 1 becoming msi_base on. */
    rid_base : u32,
    /** The MSI source the requester ID rid_base becomes. */
    msi_base : u32,
    /** How many requester IDs msi-map maps; 0 without a map, when each ID is its own MSI source. */
    msi_count : u32,
}

/**
 * Give the size of the host's ECAM, for its buses.
 *
 * @param host The host bridge, its first_bus and last_bus.
 * @return Its bytes: BUS_BYTES for each bus from first_bus to last_bus.
 */
ecam_size :: fn(host: ptr[Host]) -> u64 {
    return (cast[u64](host.last_bus) - cast[u64](host.first_bus) + 1) * BUS_BYTES
}

/**
 * Give where a function's configuration space is in the host's ECAM.
 *
 * @param host The host bridge, for its first bus, which the ECAM starts at.
 * @param bus The function's bus, from first_bus to last_bus; not checked.
 * @param device The device number, 0 to 31; higher bits are dropped.
 * @param function The function number, 0 to 7; higher bits are dropped.
 * @return Its offset in bytes from the ECAM's start (ecam), FUNCTION_BYTES of it.
 */
function_offset :: fn(host: ptr[Host], bus: u8, device: u8, function: u8) -> u64 {
    return (cast[u64](bus) - cast[u64](host.first_bus)) * BUS_BYTES + cast[u64](device & 0x1f) * 8 * FUNCTION_BYTES
        + cast[u64](function & 7) * FUNCTION_BYTES
}

/**
 * Give the MSI source a function's interrupts come from, for slop_os.device_create, through the host's msi-map.
 *
 * @param host The host bridge, whose msi-map is used; without one, every ID is its own source.
 * @param address The function's address, as slop_os.device_address makes it; its low 16 bits are its requester ID.
 * @return The requester ID mapped, when msi-map maps it; the requester ID itself otherwise.
 */
msi_source :: fn(host: ptr[Host], address: u32) -> u32 {
    rid :: address & 0xffff
    if host.msi_count != 0 && rid >= host.rid_base && rid - host.rid_base < host.msi_count {
        return rid - host.rid_base + host.msi_base
    }
    return rid
}

/**
 * Find the first host bridge the firmware tables describe: the MCFG's, on x86-64, or the device tree's.
 *
 * @param tables Where the firmware tables' copy (slop_os.FirmwareTables) is mapped, readable.
 * @param size How many bytes of it there are; a table past them is passed over.
 * @return The host bridge, from the first MCFG or DTB table; null if the copy isn't one, or has neither, or a device
 *     tree has no pci-host-ecam-generic.
 */
find_host :: fn(tables: u64, size: u64) -> Host? {
    header :: cast[ptr[slop_os.FirmwareTables]](tables)
    if size < cast[u64](size_of(slop_os.FirmwareTables)) || header.magic != slop_os.FIRMWARE_MAGIC {
        return null
    }
    entries :: view_of(cast[ptr[slop_os.FirmwareTable]](tables + cast[u64](size_of(slop_os.FirmwareTables))), cast[usize](header.count))
    ram := view_of(cast[ptr[slop_os.PhysicalRange]](tables), 0)
    for &entry in entries {
        if signature_of(entry) == "RAM " && entry.offset + cast[u64](entry.size) <= size {
            ram = view_of(cast[ptr[slop_os.PhysicalRange]](tables + entry.offset), cast[usize](entry.size) / size_of(slop_os.PhysicalRange))
        }
    }
    for &entry in entries {
        if entry.offset + cast[u64](entry.size) > size {
            continue
        }
        name :: signature_of(entry)
        if name == "MCFG" && entry.size >= 60 {
            return from_mcfg(tables + entry.offset, ram)
        }
        if name == "DTB " {
            return from_device_tree(tables + entry.offset)
        }
    }
    return null
}

/**
 * Find a table in the firmware tables' copy by its signature.
 *
 * @param tables Where the firmware tables' copy (slop_os.FirmwareTables) is mapped, readable.
 * @param size How many bytes of it there are; a table past them is passed over.
 * @param signature The table's 4-byte signature, as "MCFG" or "DTB ".
 * @return The first such table's address in the mapping and its size in bytes, a view good while the mapping is;
 *     null if there's none, or the copy isn't one.
 */
firmware_table :: fn(tables: u64, size: u64, signature: string) -> devicetree.Region? {
    header :: cast[ptr[slop_os.FirmwareTables]](tables)
    if size < cast[u64](size_of(slop_os.FirmwareTables)) || header.magic != slop_os.FIRMWARE_MAGIC {
        return null
    }
    entries :: view_of(cast[ptr[slop_os.FirmwareTable]](tables + cast[u64](size_of(slop_os.FirmwareTables))), cast[usize](header.count))
    for &entry in entries {
        if entry.offset + cast[u64](entry.size) <= size && signature_of(entry) == signature {
            return devicetree.Region.{address = tables + entry.offset, size = cast[u64](entry.size)}
        }
    }
    return null
}

/**
 * Give a firmware table's signature as text.
 *
 * @param entry The table's entry in the copy's index.
 * @return Its 4 signature bytes, a view into entry.
 */
signature_of :: fn(entry: ptr[slop_os.FirmwareTable]) -> string {
    return string_of(&entry.signature[0], 4)
}

/**
 * Make a host bridge from the MCFG's first allocation, and its windows from the gaps RAM leaves.
 *
 * The allocation is after the MCFG's 36-byte header and 8 reserved bytes: its base, segment, first bus and last. The
 * windows are the gap below 4 GiB, from above RAM to X86_DEVICE_TOP, on each side of the ECAM if it's there, and
 * X86_WIDE_WINDOW bytes from above RAM, the ECAM and 4 GiB, 64-bit and prefetchable.
 *
 * @param mcfg Where the MCFG is mapped, readable, at least 60 bytes of it.
 * @param ram The RAM the kernel owns, from the copy's "RAM " table, which no window covers.
 * @return The host bridge, from the allocation, with its windows.
 */
from_mcfg :: fn(mcfg: u64, ram: slop_os.PhysicalRange[]) -> Host {
    host : Host
    base :: read_u64(mcfg + 44)
    host.segment = read_u16(mcfg, 52)
    host.first_bus = read_u8(mcfg, 54)
    host.last_bus = read_u8(mcfg, 55)
    // The MCFG's base is bus 0's, wherever its buses start
    host.ecam = base + cast[u64](host.first_bus) * BUS_BYTES
    // The gaps: below 4 GiB, above RAM; and above everything
    low := cast[u64](0)
    high := cast[u64](4) << 30
    for range in ram {
        end :: range.base + range.size
        if end <= cast[u64](4) << 30 && end > low {
            low = end
        }
        if end > high {
            high = end
        }
    }
    ecam_end :: host.ecam + ecam_size(&host)
    high = if ecam_end > high { ecam_end } else { high }
    low = round_up(low, 1 << 20)
    high = round_up(high, 1 << 30)
    // The ECAM is usually inside the low gap, which is a window on each side of it
    if host.ecam >= low && ecam_end <= X86_DEVICE_TOP {
        if low < host.ecam {
            add_window(&host, Window.{cpu = low, pci = low, size = host.ecam - low})
        }
        if ecam_end < X86_DEVICE_TOP {
            add_window(&host, Window.{cpu = ecam_end, pci = ecam_end, size = X86_DEVICE_TOP - ecam_end})
        }
    }
    else if low < X86_DEVICE_TOP {
        add_window(&host, Window.{cpu = low, pci = low, size = X86_DEVICE_TOP - low})
    }
    add_window(&host, Window.{cpu = high, pci = high, size = X86_WIDE_WINDOW, wide = true, prefetchable = true})
    return host
}

/**
 * Make a host bridge from the device tree's pci-host-ecam-generic node.
 *
 * Its reg is the ECAM, bus-range its buses (0 to as many as reg holds without one), each ranges entry of memory space
 * a window (three cells of PCI address, its space in the first, the CPU's address in the parent's cells, two of size),
 * and msi-map how its requester IDs become MSI sources. I/O space ranges are passed over.
 *
 * @param blob Where the device tree blob is mapped, readable.
 * @return The host bridge; null if the blob isn't one, or has no such node with a reg.
 */
from_device_tree :: fn(blob: u64) -> Host? {
    tree := devicetree.open(blob) or_return null
    bridge := devicetree.find_compatible(&tree, "pci-host-ecam-generic") or_return null
    region :: devicetree.reg(&tree, &bridge, 0) or_return null
    host : Host
    host.ecam = region.address
    host.first_bus = 0
    host.last_bus = cast[u8](if region.size / BUS_BYTES >= 1 { (region.size / BUS_BYTES - 1) & 0xff } else { 0 })
    match devicetree.property(&tree, &bridge, "bus-range") {
        case Some(range) => {
            host.first_bus = cast[u8]((devicetree.cell(range, 0) or_else 0) & 0xff)
            host.last_bus = cast[u8]((devicetree.cell(range, 1) or_else cast[u32](host.last_bus)) & 0xff)
        }
        case None => {}
    }
    match devicetree.property(&tree, &bridge, "msi-map") {
        case Some(map) => {
            host.rid_base = devicetree.cell(map, 0) or_else 0
            host.msi_base = devicetree.cell(map, 2) or_else 0
            host.msi_count = devicetree.cell(map, 3) or_else 0
        }
        case None => {}
    }
    ranges :: devicetree.property(&tree, &bridge, "ranges") or_return host
    parent_cells :: cast[u64](bridge.address_cells)
    entry_cells :: 3 + parent_cells + 2
    count :: ranges.size / (entry_cells * 4)
    for i in 0..<count {
        start :: i * entry_cells
        space :: (devicetree.cell(ranges, start) or_else 0) >> 24
        // 2 is 32-bit memory, 3 64-bit; 1 is I/O ports, which aren't placed yet
        if space != 2 && space != 3 {
            continue
        }
        pci_address :: devicetree.read_cells(ranges.address + (start + 1) * 4, 2)
        cpu_address :: devicetree.read_cells(ranges.address + (start + 3) * 4, cast[u32](parent_cells))
        size :: devicetree.read_cells(ranges.address + (start + 3 + parent_cells) * 4, 2)
        prefetchable :: ((devicetree.cell(ranges, start) or_else 0) >> 30) & 1 != 0
        add_window(&host, Window.{cpu = cpu_address, pci = pci_address, size = size, wide = space == 3, prefetchable = prefetchable})
    }
    return host
}

/**
 * Add a window to a host bridge, if there's room.
 *
 * @param host The host bridge, whose window_count grows by one.
 * @param window The window; dropped when MAX_WINDOWS are there already.
 */
add_window :: fn(host: ptr[mut Host], window: Window) {
    index :: cast[usize](host.window_count)
    if index < host.windows.count {
        host.windows[index] = window
        host.window_count += 1
    }
}

/**
 * Round a value up to a multiple of an alignment.
 *
 * @param value The value; one within alignment of 2^64 wraps.
 * @param alignment The alignment, a power of two.
 * @return The least multiple of alignment at least value.
 */
round_up :: fn(value: u64, alignment: u64) -> u64 {
    return (value + alignment - 1) & ~(alignment - 1)
}

/**
 * Read a byte of a function's configuration space, with one volatile load.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, or a firmware table, readable.
 * @param offset The byte's offset.
 * @return Its value.
 */
read_u8 :: fn(config: u64, offset: u64) -> u8 #no_context {
    return intrinsics.volatile_load_u8(cast[ptr[u8]](config + offset))
}

/**
 * Read a 16-bit register of a function's configuration space, with one volatile load in the CPU's byte order, which
 * is the little-endian PCI's on every target SlopOS runs on.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, or a firmware table, readable.
 * @param offset The register's offset, 2-byte aligned.
 * @return Its value.
 */
read_u16 :: fn(config: u64, offset: u64) -> u16 #no_context {
    return intrinsics.volatile_load_u16(cast[ptr[u16]](config + offset))
}

/**
 * Read a 32-bit register of a function's configuration space, with one volatile load in the CPU's byte order.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, readable.
 * @param offset The register's offset, 4-byte aligned.
 * @return Its value.
 */
read_u32 :: fn(config: u64, offset: u64) -> u32 #no_context {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](config + offset))
}

/**
 * Read 8 bytes at any alignment, as a firmware table holds a 64-bit field, in the CPU's byte order.
 *
 * @param at Where they are, readable.
 * @return Their value.
 */
read_u64 :: fn(at: u64) -> u64 #no_context {
    value : u64 = 0
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&value), cast[rawptr](at), 8)
    return value
}

/**
 * Write a byte of a function's configuration space, with one volatile store.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, writable.
 * @param offset The byte's offset.
 * @param value What's written.
 */
write_u8 :: fn(config: u64, offset: u64, value: u8) #no_context {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](config + offset), value)
}

/**
 * Write a 16-bit register of a function's configuration space, with one volatile store in the CPU's byte order.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, writable.
 * @param offset The register's offset, 2-byte aligned.
 * @param value What's written.
 */
write_u16 :: fn(config: u64, offset: u64, value: u16) #no_context {
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](config + offset), value)
}

/**
 * Write a 32-bit register of a function's configuration space, with one volatile store in the CPU's byte order.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, writable.
 * @param offset The register's offset, 4-byte aligned.
 * @param value What's written.
 */
write_u32 :: fn(config: u64, offset: u64, value: u32) #no_context {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](config + offset), value)
}

/**
 * Find a capability in a function's capabilities list, by its ID.
 *
 * At most 48 capabilities are followed, so a list that loops ends.
 *
 * @param config Where the function's 4 KiB of configuration space is mapped, readable.
 * @param id The PCI capability ID, as 0x11 for MSI-X.
 * @param after A capability's offset to look after, for the next with id; 0 to look from the list's start.
 * @return The capability's offset in configuration space; null if the function has no list, or none with id.
 */
find_capability :: fn(config: u64, id: u8, after: u64 = 0) -> u64? {
    if read_u16(config, STATUS) & STATUS_CAPABILITIES == 0 {
        return null
    }
    at := if after == 0 { cast[u64](read_u8(config, CAPABILITIES)) & 0xfc } else { cast[u64](read_u8(config, after + 1)) & 0xfc }
    for step in 0..<48 {
        if at == 0 {
            return null
        }
        if read_u8(config, at) == id {
            return at
        }
        at = cast[u64](read_u8(config, at + 1)) & 0xfc
    }
    return null
}
