/*
 * The IOMMU interface: what every IOMMU package implements and the kernel core (L2) calls, for the IOMMUs the
 * platform service registers (decisions/0039, 0079). Specified in docs/specs/iommu_interface.md.
 *
 * IOMMUs differ per platform rather than per architecture (Intel VT-d, AMD-Vi, Arm SMMUv3, the RISC-V IOMMU), and an
 * architecture may build several, so the kernel imports each one its architecture builds under an alias starting
 * iommu_, like iommu_vtd. Functions here are declarations only (---); each package defines them with the same
 * signature, and the per-implementation types (the empty structs) under the same names.
 */
package iommu_interface

import boot_info from "../boot_info"

PhysicalAddress :: boot_info.PhysicalAddress
VirtualAddress :: boot_info.VirtualAddress

// One IOMMU the platform service registered: what the implementation keeps of it, like its registers' address.
Iommu :: struct {}

// Kinds of IOMMU. An implementation drives one, and an architecture builds only some.
IommuKind :: enum #backed_by(u8) {
    // x86-64
    VtD,
    AmdVi,
    // AArch64
    Smmuv3,
    // RISC-V
    RiscV,
}

IommuError :: enum #backed_by(u8) {
    // This implementation doesn't drive the kind.
    UnsupportedKind,
    // The registers don't identify an IOMMU of that kind, or there are fewer of them than it has.
    NotFound,
    // It lacks what the kernel needs of one: the translation its domains use (VT-d's second-level tables, SMMUv3's
    // stage 2), with 4 KiB pages and at least 39-bit I/O virtual addresses.
    Unsupported,
}

// What identify finds out about an IOMMU.
IommuInfo :: struct {
    // The I/O virtual addresses its domains can have: below 1 << address_bits.
    address_bits : u32,
    // Its version, as its registers give it: major, then minor.
    major : u32,
    minor : u32,
}

/*
 * Identify an IOMMU of kind whose registers, size bytes of them, L2 mapped uncached at registers, and keep what's
 * needed of it in iommu, changing nothing: DMA through it goes on as before, translated or not.
 */
identify : fn(iommu: ptr[mut Iommu], kind: IommuKind, registers: VirtualAddress, size: u64) -> Result[IommuInfo, IommuError] : ---
