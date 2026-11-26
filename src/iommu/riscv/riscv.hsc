package iommu_riscv

import iommu_interface from "../../iommu_interface"

/*
 * The RISC-V IOMMU (iommu_interface, decisions/0199): driven from M19's R6, when its device directory, its domains'
 * second-stage tables and its MSI remapping are built. Until then identify drives no kind, so the platform service's
 * registration of one fails with UnsupportedKind and nothing else here is reached (not_yet_implemented.hsc).
 *
 * SPEC: The RISC-V IOMMU Architecture Specification, version 1.0.
 */

/** One IOMMU the platform service registered (iommu_interface.Iommu): where its registers are. */
Iommu :: struct {
    /** The virtual address L2 mapped its registers at, uncached; 0 until identify keeps one, which it doesn't yet. */
    registers : u64,
}

/** One DMA domain on an IOMMU (iommu_interface.Domain): its second-stage tables' root, and its ID. */
Domain :: struct {
    /** The physical address of its top-level table, a 4 KiB frame. */
    root : u64,
    /** Its ID on the IOMMU, its GSCID. */
    id : u32,
}

/**
 * Identify an IOMMU (iommu_interface.identify): none yet, until R6 drives the RISC-V IOMMU.
 *
 * @param iommu Left as it was.
 * @param kind The kind the platform service registered it as; none is driven yet, RiscV included.
 * @param registers Unused.
 * @param size Unused.
 * @return Never a result.
 * @error UnsupportedKind Always: this implementation drives no kind yet.
 */
identify :: fn(
    iommu : ptr[mut Iommu],
    kind : iommu_interface.IommuKind,
    registers : iommu_interface.VirtualAddress,
    size : u64
) -> Result[iommu_interface.IommuInfo, iommu_interface.IommuError] {
    return .Error(.UnsupportedKind)
}
