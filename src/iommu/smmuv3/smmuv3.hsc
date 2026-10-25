package iommu_smmuv3

import intrinsics from "base"
import iommu_interface from "../../iommu_interface"

/*
 * Arm SMMUv3 (iommu_interface, roadmap D): one SMMU, which the platform service finds through the device tree's
 * iommu-map and registers (decisions/0039, 0079). Its domains use stage 2 only, with 4 KiB pages; their width is its
 * output address size, at most 48 bits. It remaps no interrupts: the GICv3's ITS already takes a device's MSIs only
 * as the events its device ID was given.
 */
//SPEC: Arm System Memory Management Unit Architecture Specification, SMMU architecture version 3 (IHI 0070), §6.3.1 (SMMU_IDR0), §6.3.6 (SMMU_IDR5), §6.3.7 (SMMU_AIDR)

IDR0 : u64 : 0x00
IDR5 : u64 : 0x14
AIDR : u64 : 0x1c
// Page 0's registers and page 1's, 64 KiB each, which every SMMUv3 has
REGISTER_BYTES : u64 : 0x20000
IDR0_S2P : u32 : 1 << 0
// TTF: the translation tables it walks, 2 for AArch64's, 3 for both AArch32's and AArch64's
IDR0_TTF_AARCH64 : u32 : 2 << 2
IDR5_GRAN4K : u32 : 1 << 4

// One SMMU (iommu_interface.Iommu).
Iommu :: struct {
    // Its registers, mapped by L2 as device memory.
    registers : u64,
    // Its domains' width: at most 48 bits, with 4 KiB pages.
    address_bits : u32,
}

// One domain on an SMMU (iommu_interface.Domain): its stage-2 tables, with roadmap Dd.
Domain :: struct {
    root : u64,
    id : u32,
}

// OAS, the output address sizes, by its value
OUTPUT_BITS :: u32.[32, 36, 40, 42, 44, 48, 52]

/*
 * An SMMUv3 at registers: its AIDR says it's version 3, it has both pages of registers, and it does stage 2, with
 * AArch64's tables and 4 KiB pages.
 */
identify :: fn(iommu: ptr[mut Iommu], kind: iommu_interface.IommuKind, registers: iommu_interface.VirtualAddress, size: u64)
    -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    if kind != .Smmuv3 {
        return .Error(.UnsupportedKind)
    }
    if size < REGISTER_BYTES {
        return .Error(.NotFound)
    }
    base :: cast[u64](registers)
    features :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + IDR0))
    sizes :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + IDR5))
    version :: intrinsics.volatile_load_u32(cast[ptr[u32]](base + AIDR))
    // ArchMajorRev 0 is SMMUv3; the bits above AIDR's eight are reserved
    if features == 0xffffffff || (version >> 4) & 0xf != 0 || version >> 8 != 0 {
        return .Error(.NotFound)
    }
    output :: cast[usize](sizes & 7)
    if features & IDR0_S2P == 0 || features & IDR0_TTF_AARCH64 == 0 || sizes & IDR5_GRAN4K == 0 || output >= OUTPUT_BITS.count
        || OUTPUT_BITS[output] < 39 {
        return .Error(.Unsupported)
    }
    iommu.registers = base
    iommu.address_bits = if OUTPUT_BITS[output] < 48 { OUTPUT_BITS[output] } else { 48 }
    return .Ok(iommu_interface.IommuInfo.{address_bits = iommu.address_bits, major = 3, minor = version & 0xf, memory = 0, domain_ids = 0,
        interrupts = 0})
}

// It remaps none (info.interrupts is 0), so the kernel never asks.
remap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32, stream: u32, cpu_hardware_id: u64, vector: u32) -> iommu_interface.MsiMessage {
    return iommu_interface.MsiMessage.{}
}

unmap_interrupt :: fn(iommu: ptr[mut Iommu], index: u32) {
}
