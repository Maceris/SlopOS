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

DMAR_STRUCTURES : u64 : 48
DRHD : u16 : 0
DRHD_INCLUDE_PCI_ALL : u8 : 1 << 0
SCOPE_ENDPOINT : u8 : 1
SCOPE_BRIDGE : u8 : 2
// An iommu-map entry's cells: requester ID base, the IOMMU's phandle, stream ID base, length
IOMMU_MAP_CELLS : u64 : 4

// Every IOMMU, each registered with the ranges of requester IDs it covers: how many ranges the kernel took.
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

/*
 * A DRHD's endpoints and bridges, each found by its path from its start bus: each step but the last a bridge, whose
 * secondary bus the next step is on. A requester ID is its own stream on VT-d.
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

on_host :: fn(host: ptr[pci.Host], bus: u8) -> bool {
    return bus >= host.first_bus && bus <= host.last_bus
}

// The SMMUv3s the host bridge's iommu-map refers to, each entry's requester IDs as streams from its base.
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

// One range of requester IDs, count from first, registered with an IOMMU: 1 if the kernel took it.
register :: fn(to: slop_os.DebugLog, platform: slop_os.Platform, kind: slop_os.IommuKind, registers: u64, size: u64, first: u32, count: u32,
    stream: u32) -> u32 {
    block :: slop_os.startup_block()
    memory :: slop_os.memory_create_physical(platform, block.budget, registers, size, .Device) or_else cast[slop_os.Memory](slop_os.NO_HANDLE)
    if cast[slop_os.Handle](memory) == slop_os.NO_HANDLE {
        log_line.write(to, "platform: an IOMMU's registers at % aren't device memory", cast[rawptr](registers))
        return 0
    }
    taken := cast[u32](0)
    match slop_os.iommu_register(platform, kind, memory, first, count, stream) {
        case Ok => taken = 1
        case Error(error) => log_line.write(to, "platform: the kernel took no IOMMU at %: %", cast[rawptr](registers), error)
    }
    _ = slop_os.handle_close(cast[slop_os.Handle](memory))
    return taken
}
