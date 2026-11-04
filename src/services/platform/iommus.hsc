package platform

import slop_os from "std/os"
import devicetree from "../../devicetree"
import log_line from "../../log_line"
import pci from "../../pci"

/*
 * The IOMMUs the firmware tables describe, registered with the kernel with the requester IDs each covers (roadmap Da,
 * decisions/0079), before any device is attached to a domain, and once the buses are numbered, since a DMAR device
 * scope is a path through bridges.
 *
 * On x86-64 they're ACPI's DMAR's DMA remapping hardware units (DRHDs): one for all of a segment's devices but those
 * another covers (INCLUDE_PCI_ALL), or for its device scopes, each an endpoint or a bridge with everything behind it.
 * Scopes of I/O APICs and HPETs are for interrupt remapping (roadmap Dc). On AArch64 they're the SMMUv3s the host
 * bridge's iommu-map refers to: each entry a range of requester IDs, and the stream IDs they are to its SMMU.
 */
//SPEC: Intel Virtualization Technology for Directed I/O, Architecture Specification 4.1, §8.1 (DMAR), §8.3 (DRHD), §8.3.1 (device scope)
//SPEC: Linux's pci-iommu binding (iommu-map); its arm,smmu-v3 binding

/** The byte offset of the DMAR's first remapping structure, past its header. */
DMAR_STRUCTURES : u64 : 48
/** A remapping structure's type for a DMA remapping hardware unit (DRHD). */
DRHD : u16 : 0
/** A DRHD's flag that it covers every device of its segment but those another DRHD's scopes name. */
DRHD_INCLUDE_PCI_ALL : u8 : 1 << 0
/** A device scope's type for a PCI endpoint. */
SCOPE_ENDPOINT : u8 : 1
/** A device scope's type for a PCI bridge, which covers everything behind it too. */
SCOPE_BRIDGE : u8 : 2
/** An iommu-map entry's cells: requester ID base, the IOMMU's phandle, stream ID base, length. */
IOMMU_MAP_CELLS : u64 : 4

/**
 * Register every IOMMU the firmware tables describe with the kernel, each with the ranges of requester IDs it covers.
 *
 * ACPI's DMAR is used if there is one, and otherwise the device tree's iommu-map; it's called once the buses are
 * numbered, and before any device is attached to a DMA domain.
 *
 * @param to The debug log the platform service writes to, NO_HANDLE for none; each IOMMU or range not taken is logged.
 * @param platform The platform capability, which the IOMMUs' registers are made and registered with.
 * @param state The platform service's state, its host bridge and configuration space mapped; bridges' secondary
 *     buses are read through it, not changed.
 * @param tables Where the firmware tables' copy is mapped, readable, in the platform service's address space.
 * @param size The firmware tables' copy's size in bytes.
 * @return How many ranges the kernel took, 0 if there's no IOMMU or it took none.
 */
register_iommus :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], tables: u64, size: u64) -> u32 {
    match pci.firmware_table(tables, size, "DMAR") {
        case Some(dmar) => return from_dmar(to, platform, state, dmar)
        case None => {}
    }
    match pci.firmware_table(tables, size, "DTB ") {
        case Some(blob) => return from_iommu_map(to, platform, state, blob.address)
        case None => {}
    }
    return 0
}

/**
 * Register the DMAR's DRHDs: one with INCLUDE_PCI_ALL as its whole segment, any other by its device scopes.
 *
 * Structures are read until one is malformed or runs past the DMAR's end; types other than DRHD are skipped.
 *
 * @param to The debug log, NO_HANDLE for none; each unit or range the kernel didn't take is logged.
 * @param platform The platform capability, which each unit's registers are made and registered with.
 * @param state The platform service's state, for the host bridge and its configuration space.
 * @param dmar The DMAR, where it's mapped in the firmware tables' copy and its size in bytes.
 * @return How many ranges of requester IDs the kernel took.
 */
from_dmar :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], dmar: devicetree.Region) -> u32 {
    registered := cast[u32](0)
    at := DMAR_STRUCTURES
    loop {
        if at + 4 > dmar.size {
            break
        }
        kind :: pci.read_u16(dmar.address, at)
        length :: cast[u64](pci.read_u16(dmar.address, at + 2))
        if length < 4 || at + length > dmar.size {
            break
        }
        if kind == DRHD && length >= 16 {
            unit :: dmar.address + at
            flags :: pci.read_u8(unit, 4)
            pages :: cast[u64](1) << cast[u64](pci.read_u8(unit, 5) & 0xf)
            segment :: pci.read_u16(unit, 6)
            registers :: pci.read_u64(unit + 8)
            if flags & DRHD_INCLUDE_PCI_ALL != 0 {
                registered += register(to, platform, .VtD, registers, pages * PAGE, slop_os.device_address(segment, 0, 0, 0), 0x10000, 0)
            }
            else {
                registered += register_scopes(to, platform, state, registers, pages * PAGE, segment, unit, length)
            }
        }
        at += length
    }
    return registered
}

/**
 * Register a DRHD's endpoints and bridges, each found by its path from its start bus: each step but the last a bridge,
 * whose secondary bus the next step is on.
 *
 * A requester ID is its own stream on VT-d. A bridge is registered with its own ID and with every bus from its
 * secondary to its subordinate. Only scopes on the host bridge's segment are registered; a path through a bus outside
 * the host's is given up, as are scopes of other types (I/O APICs and HPETs, for interrupt remapping).
 *
 * @param to The debug log, NO_HANDLE for none; each range the kernel didn't take is logged.
 * @param platform The platform capability, which the unit's registers are made and registered with.
 * @param state The platform service's state: bridges' bus numbers are read through its configuration space.
 * @param registers The unit's registers' physical address.
 * @param size The unit's registers' size in bytes, a whole number of pages.
 * @param segment The PCI segment the unit is for.
 * @param unit Where the DRHD is mapped, in the firmware tables' copy.
 * @param length The DRHD's length in bytes, scopes included, as its header says.
 * @return How many ranges of requester IDs the kernel took.
 */
register_scopes :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], registers: u64, size: u64, segment: u16,
    unit: u64, length: u64) -> u32 {
    registered := cast[u32](0)
    host :: &state.host
    at := cast[u64](16)
    loop {
        if at + 6 > length {
            break
        }
        kind :: pci.read_u8(unit, at)
        scope_length :: cast[u64](pci.read_u8(unit, at + 1))
        if scope_length < 6 || at + scope_length > length {
            break
        }
        if (kind == SCOPE_ENDPOINT || kind == SCOPE_BRIDGE) && scope_length >= 8 && segment == host.segment {
            bus := pci.read_u8(unit, at + 5)
            steps :: (scope_length - 6) / 2
            found := true
            for step in 0..<steps {
                device :: pci.read_u8(unit, at + 6 + step * 2)
                function :: pci.read_u8(unit, at + 7 + step * 2)
                if step + 1 == steps {
                    address :: slop_os.device_address(segment, bus, device, function)
                    registered += register(to, platform, .VtD, registers, size, address, 1, address & 0xffff)
                    if kind == SCOPE_BRIDGE && on_host(host, bus) {
                        config :: state.ecam + pci.function_offset(host, bus, device, function)
                        secondary :: pci.read_u8(config, pci.SECONDARY_BUS)
                        subordinate :: pci.read_u8(config, pci.SUBORDINATE_BUS)
                        if secondary != 0 && subordinate >= secondary {
                            first :: slop_os.device_address(segment, secondary, 0, 0)
                            count :: (cast[u32](subordinate) - cast[u32](secondary) + 1) * 256
                            registered += register(to, platform, .VtD, registers, size, first, count, first & 0xffff)
                        }
                    }
                }
                else if on_host(host, bus) {
                    bus = pci.read_u8(state.ecam + pci.function_offset(host, bus, device, function), pci.SECONDARY_BUS)
                }
                else {
                    break
                }
            }
        }
        at += scope_length
    }
    return registered
}

/**
 * Tell whether a bus is one of the host bridge's, so its configuration space is mapped.
 *
 * @param host The host bridge whose buses, first_bus to last_bus, are the ones its ECAM mapping covers; only read.
 * @param bus A bus number, 0 to 255, such as a DMAR device scope's start bus or a bridge's secondary bus.
 * @return True if bus is from the host's first bus to its last, both included.
 */
on_host :: fn(host: ptr[pci.Host], bus: u8) -> bool {
    return bus >= host.first_bus && bus <= host.last_bus
}

/**
 * Register the SMMUv3s the host bridge's iommu-map refers to, each entry's requester IDs as streams from its base.
 *
 * @param to The debug log, NO_HANDLE for none; an entry referring to no SMMUv3, and a range the kernel didn't take,
 *     are logged.
 * @param platform The platform capability, which each SMMU's registers are made and registered with.
 * @param state The platform service's state, for the host bridge's segment.
 * @param blob Where the device tree blob is mapped, in the firmware tables' copy.
 * @return How many ranges of requester IDs the kernel took; 0 if the tree, a pci-host-ecam-generic bridge or its
 *     iommu-map can't be found.
 */
from_iommu_map :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, state: ptr[mut Platform], blob: u64) -> u32 {
    tree := devicetree.open(blob) or_return 0
    bridge := devicetree.find_compatible(&tree, "pci-host-ecam-generic") or_return 0
    map :: devicetree.property(&tree, &bridge, "iommu-map") or_return 0
    registered := cast[u32](0)
    for entry in 0..<map.size / (IOMMU_MAP_CELLS * 4) {
        start :: entry * IOMMU_MAP_CELLS
        rid :: devicetree.cell(map, start) or_else 0
        stream :: devicetree.cell(map, start + 2) or_else 0
        count :: devicetree.cell(map, start + 3) or_else 0
        smmu := devicetree.find_phandle(&tree, devicetree.cell(map, start + 1) or_else 0) or_else devicetree.Node.{}
        compatible :: devicetree.property(&tree, &smmu, "compatible") or_else devicetree.Property.{}
        if smmu.offset == 0 || !devicetree.lists(compatible, "arm,smmu-v3") {
            log_line.write(to, "platform: iommu-map entry % refers to no SMMUv3", entry)
            continue
        }
        region :: devicetree.reg(&tree, &smmu, 0) or_else devicetree.Region.{}
        first :: cast[u32](state.host.segment) << 16 | (rid & 0xffff)
        registered += register(to, platform, .Smmuv3, region.address, region.size, first, count, stream)
    }
    return registered
}

/**
 * Register one range of requester IDs with an IOMMU.
 *
 * The registers' memory is made for the call and closed after it, whether the kernel took the range or not.
 *
 * @param to The debug log, NO_HANDLE for none; registers that aren't device memory, or a range not taken, are logged.
 * @param platform The platform capability, which the registers' memory is made and registered with.
 * @param kind Which kind of IOMMU it is: VT-d or SMMUv3.
 * @param registers The IOMMU's registers' physical address.
 * @param size The IOMMU's registers' size in bytes.
 * @param first The range's first requester ID, its segment in the top 16 bits (slop_os.device_address).
 * @param count How many requester IDs the range has, from first.
 * @param stream The stream ID first is to the IOMMU, the rest following it in order.
 * @return 1 if the kernel took the range, 0 if not.
 */
register :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, kind: slop_os.IommuKind, registers: u64, size: u64, first: u32, count: u32,
    stream: u32) -> u32 {
    block :: slop_os.startup_block()
    memory :: slop_os.memory_create_physical(platform, block.budget, registers, size, .Device) or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        log_line.write(to, "platform: an IOMMU's registers at %{#018x} aren't device memory", registers)
        return 0
    }
    taken := cast[u32](0)
    match slop_os.iommu_register(platform, kind, memory, first, count, stream) {
        case Ok => taken = 1
        case Error(error) => log_line.write(to, "platform: the kernel took no IOMMU at %{#018x}: %", registers, error)
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
    return taken
}
