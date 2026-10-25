# IOMMU Interface

The IOMMU interface is the boundary between the kernel core (L2) and the IOMMU packages that drive each kind of
IOMMU (`../../knowledge/decisions/0039-platform-discovery.md`, `0079`). IOMMUs differ per platform rather than per
architecture (Intel VT-d, AMD-Vi, Arm SMMUv3, the RISC-V IOMMU), and an architecture may need several, so they're
behind an interface of their own, beside the arch interface (`arch_interface.md`), with the same rules.

Status: **specified as far as roadmap Da needs**, and implemented for VT-d (`src/iommu/vtd`, on x86-64) and SMMUv3
(`src/iommu/smmuv3`, on AArch64): identifying an IOMMU the platform service registered. Translating DMA domains,
invalidation and fault reporting come with roadmap Db (VT-d) and Dd (SMMUv3), which add their functions here;
interrupt remapping with Dc. Four-digit numbers like `0079` refer to decision records in `../../knowledge/decisions/`.

The interface is internal to the kernel image. It changes together with every IOMMU package, in one change, and
carries no version number.

## Conformance

The kernel imports each IOMMU package its architecture builds under an alias starting `iommu_`, like `iommu_vtd`
(`src/kernel/iommus.hsc`). The house-rule check registered by the build (`0029`) verifies each such package as it does
an architecture package against `arch_interface`: every function `iommu_interface` declares, defined with a body and
an identical signature, and every per-implementation type (an empty struct) defined under the same name. What an
implementation doesn't do yet, it lists in `NOT_YET_IMPLEMENTED`, with stubs in its `not_yet_implemented.hsc`.

## Rules for L2

- **L2 registers, maps and allocates.** The platform service registers each IOMMU with `iommu_register`
  (`system_calls.md`), from the firmware tables; L2 maps its registers uncached in the kernel window and passes them
  in. IOMMU packages never allocate: tables and queues come from L2, as an architecture's page tables do.
- **L2 picks the IOMMU.** A device is behind the IOMMU whose registered requester IDs cover it most narrowly, and
  each DMA domain is bound to one IOMMU, or to none, by the first device attached to it (`system_calls.md`, *Devices
  and DMA*).
- **L2 serializes calls on one IOMMU.** An IOMMU's registers and queues are changed by one CPU at a time.

## `iommu_interface`

```
package iommu_interface

import boot_info from "../boot_info"

PhysicalAddress :: boot_info.PhysicalAddress
VirtualAddress :: boot_info.VirtualAddress
```

### Per-Implementation Types

```
// One IOMMU the platform service registered: what the implementation keeps of it, like its registers' address.
Iommu :: struct {}
```

### Identifying

```
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
```

## VT-d

`src/iommu/vtd`: one DMA remapping hardware unit, from a DRHD in ACPI's DMAR.

| Interface | VT-d |
|---|---|
| `Iommu` | Its registers' address, its widest domain, and where its IOTLB registers and fault recording registers are |
| `identify` | `VER_REG` 1.0 or later; the registers `ECAP_REG.IRO` and `CAP_REG.FRO`/`NFR` place inside its size. Its domains are 4-level (48-bit) where `CAP_REG.SAGAW` has them, otherwise 3-level (39-bit), at most `CAP_REG.MGAW`'s width; neither is `Unsupported` |
| Streams | A device's requester ID |

## SMMUv3

`src/iommu/smmuv3`: one SMMU, which the device tree's `iommu-map` refers to.

| Interface | SMMUv3 |
|---|---|
| `Iommu` | Its registers' address and its domains' width |
| `identify` | `SMMU_AIDR` says SMMUv3; both 64 KiB register pages fit in its size. Stage 2 (`SMMU_IDR0.S2P`), AArch64's tables (`TTF`) and 4 KiB pages (`SMMU_IDR5.GRAN4K`), or `Unsupported`; its domains' width is its output address size (`SMMU_IDR5.OAS`), at most 48 bits, and at least 39 |
| Streams | The stream ID `iommu-map` gives a requester ID |

## Not Covered

- **AMD-Vi and the RISC-V IOMMU**: kinds the interface names, with no implementation yet.
- **Several IOMMU kinds on one architecture**: the kernel imports one IOMMU package for each architecture so far; one
  with VT-d and AMD-Vi both would choose by the registered kind.
