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
//SPEC: PCI Firmware Specification 3.3, §4.1.2 (the MCFG); PCI Express Base Specification 5.0, §7.2.2 (ECAM), §7.5.1 (configuration headers)
//SPEC: Devicetree Specification 0.4; PCI Bus Binding to Open Firmware (ranges' three cells); Linux's pci-host-generic and pci-msi bindings (msi-map)
package pci

import intrinsics from "base"
import slop_os from "std/os"
import devicetree from "../devicetree"

MAX_WINDOWS :: 4
// Each bus's configuration space, through ECAM: 32 devices of 8 functions, 4 KiB each
BUS_BYTES : u64 : 1 << 20
FUNCTION_BYTES : u64 : 4096
// Where the local APIC's and I/O APIC's registers start on x86-64, which no BAR may reach
X86_DEVICE_TOP : u64 : 0xfec00000
// The 64-bit window on x86-64: this much, from above RAM, the ECAM and 4 GiB
X86_WIDE_WINDOW : u64 : 64 << 30

// Configuration space registers (a type 0 header, and a type 1's bus numbers and windows)
VENDOR_ID : u64 : 0x00
DEVICE_ID : u64 : 0x02
COMMAND : u64 : 0x04
STATUS : u64 : 0x06
CLASS_REVISION : u64 : 0x08
HEADER_TYPE : u64 : 0x0e
BAR0 : u64 : 0x10
PRIMARY_BUS : u64 : 0x18
SECONDARY_BUS : u64 : 0x19
SUBORDINATE_BUS : u64 : 0x1a
MEMORY_BASE : u64 : 0x20
MEMORY_LIMIT : u64 : 0x22
CAPABILITIES : u64 : 0x34
COMMAND_MEMORY : u16 : 1 << 1
COMMAND_BUS_MASTER : u16 : 1 << 2
STATUS_CAPABILITIES : u16 : 1 << 4
NO_VENDOR : u16 : 0xffff

// A range of address space a host bridge forwards to PCIe: at cpu for the CPU, at pci for its devices.
Window :: struct {
    cpu : u64,
    pci : u64,
    size : u64,
    // Above 4 GiB, for 64-bit BARs; and for prefetchable ones
    wide : bool,
    prefetchable : bool,
}

// A host bridge: its configuration space, at ecam for first_bus to last_bus, its windows, and its msi-map.
Host :: struct {
    ecam : u64,
    segment : u16,
    first_bus : u8,
    last_bus : u8,
    windows : Window[MAX_WINDOWS],
    window_count : u32,
    // A requester ID from rid_base, for msi_count of them, is MSI source msi_base on; without a map, the ID itself
    rid_base : u32,
    msi_base : u32,
    msi_count : u32,
}

// The bytes of ECAM for the host's buses.
ecam_size :: fn(host: ptr[Host]) -> u64 {
    return (cast[u64](host.last_bus) - cast[u64](host.first_bus) + 1) * BUS_BYTES
}

// Where a function's configuration space is, from the start of the host's ECAM.
function_offset :: fn(host: ptr[Host], bus: u8, device: u8, function: u8) -> u64 {
    return (cast[u64](bus) - cast[u64](host.first_bus)) * BUS_BYTES + cast[u64](device & 0x1f) * 8 * FUNCTION_BYTES
        + cast[u64](function & 7) * FUNCTION_BYTES
}

// The MSI source a function's interrupts come from (slop_os.device_create).
msi_source :: fn(host: ptr[Host], address: u32) -> u32 {
    rid :: address & 0xffff
    if host.msi_count != 0 && rid >= host.rid_base && rid - host.rid_base < host.msi_count {
        return rid - host.rid_base + host.msi_base
    }
    return rid
}

// The first host bridge the firmware tables' copy at tables, size bytes of it, describes.
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

signature_of :: fn(entry: ptr[slop_os.FirmwareTable]) -> string {
    return string_of(&entry.signature[0], 4)
}

// The MCFG's first allocation: base, segment, first bus and last, after its header and 8 reserved bytes.
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

/*
 * The device tree's host bridge, pci-host-ecam-generic: its reg is the ECAM, bus-range its buses, each ranges entry a
 * window (three cells of PCI address, its space in the first, the CPU's address in the parent's cells, two of size),
 * and msi-map how its requester IDs become MSI sources. Null without one.
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

add_window :: fn(host: ptr[mut Host], window: Window) {
    index :: cast[usize](host.window_count)
    if index < host.windows.count {
        host.windows[index] = window
        host.window_count += 1
    }
}

round_up :: fn(value: u64, alignment: u64) -> u64 {
    return (value + alignment - 1) & ~(alignment - 1)
}

// Configuration space, through a mapping of a function's 4 KiB at config.
read_u8 :: fn(config: u64, offset: u64) -> u8 #no_context {
    return intrinsics.volatile_load_u8(cast[ptr[u8]](config + offset))
}

read_u16 :: fn(config: u64, offset: u64) -> u16 #no_context {
    return intrinsics.volatile_load_u16(cast[ptr[u16]](config + offset))
}

read_u32 :: fn(config: u64, offset: u64) -> u32 #no_context {
    return intrinsics.volatile_load_u32(cast[ptr[u32]](config + offset))
}

read_u64 :: fn(at: u64) -> u64 #no_context {
    value : u64 = 0
    intrinsics.mem_copy_non_overlapping(cast[mut rawptr](&value), cast[rawptr](at), 8)
    return value
}

write_u8 :: fn(config: u64, offset: u64, value: u8) #no_context {
    intrinsics.volatile_store_u8(cast[ptr[mut u8]](config + offset), value)
}

write_u16 :: fn(config: u64, offset: u64, value: u16) #no_context {
    intrinsics.volatile_store_u16(cast[ptr[mut u16]](config + offset), value)
}

write_u32 :: fn(config: u64, offset: u64, value: u32) #no_context {
    intrinsics.volatile_store_u32(cast[ptr[mut u32]](config + offset), value)
}

/*
 * A capability's offset in configuration space, the first with id from the list's start, or after a previous one;
 * null if there isn't one.
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
