package iommu_vtd

import intrinsics from "base"
import iommu_interface from "../../iommu_interface"

/*
 * Intel VT-d (iommu_interface, roadmap D): one DMA remapping hardware unit, which the platform service finds in ACPI's
 * DMAR and registers (decisions/0039, 0079). Its domains use legacy mode's second-level tables, which every unit
 * has; their widths are its CAP_REG's SAGAW.
 */
//SPEC: Intel Virtualization Technology for Directed I/O, Architecture Specification 4.1, §11.4.1 (VER_REG), §11.4.2 (CAP_REG), §11.4.3 (ECAP_REG)

VERSION : u64 : 0x000
CAPABILITY : u64 : 0x008
EXTENDED_CAPABILITY : u64 : 0x010
// The bytes of registers every unit has, from its version register to its last fixed one
FIXED_REGISTERS : u64 : 0x100
// SAGAW's widths: 3-level tables for 39-bit addresses, 4-level for 48
SAGAW_39 : u64 : 1 << 1
SAGAW_48 : u64 : 1 << 2

// One VT-d unit (iommu_interface.Iommu).
Iommu :: struct {
    // Its registers, mapped by L2 as device memory.
    registers : u64,
    // Its widest domain: 39 or 48 bits.
    address_bits : u32,
    // Where its IOTLB's registers and its fault recording registers are, from its registers' start, and how many of the latter.
    iotlb : u64,
    faults : u64,
    fault_count : u32,
}

/*
 * A VT-d unit at registers: its version register is 1.0 or later, and its registers, as far as its capability
 * registers place the IOTLB's and the fault recording registers, fit in size.
 */
identify :: fn(iommu: ptr[mut Iommu], kind: iommu_interface.IommuKind, registers: iommu_interface.VirtualAddress, size: u64)
    -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    if kind != .VtD {
        return .Error(.UnsupportedKind)
    }
    if size < FIXED_REGISTERS {
        return .Error(.NotFound)
    }
    base :: cast[u64](registers)
    version :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + VERSION))
    capability :: intrinsics.volatile_load_u64(cast[ptr[u64]](base + CAPABILITY))
    extended :: intrinsics.volatile_load_u64(cast[ptr[u64]](base + EXTENDED_CAPABILITY))
    major :: (version >> 4) & 0xf
    if version == 0xffffffff || major == 0 {
        return .Error(.NotFound)
    }
    // IRO, FRO and NFR, in 16-byte units: the IOTLB's two registers, and the fault recording registers
    iotlb :: ((extended >> 8) & 0x3ff) * 16
    faults :: ((capability >> 24) & 0x3ff) * 16
    fault_count :: cast[u32]((capability >> 40) & 0xff) + 1
    if iotlb + 16 > size || faults + cast[u64](fault_count) * 16 > size {
        return .Error(.NotFound)
    }
    widths :: (capability >> 8) & 0x1f
    guest_width :: cast[u32]((capability >> 16) & 0x3f) + 1
    widest : u32 = if widths & SAGAW_48 != 0 { 48 } else if widths & SAGAW_39 != 0 { 39 } else { 0 }
    if widest == 0 || guest_width < 39 {
        return .Error(.Unsupported)
    }
    iommu.registers = base
    iommu.address_bits = if guest_width < widest { guest_width } else { widest }
    iommu.iotlb = iotlb
    iommu.faults = faults
    iommu.fault_count = fault_count
    return .Ok(iommu_interface.IommuInfo.{address_bits = iommu.address_bits, major = major, minor = version & 0xf})
}
