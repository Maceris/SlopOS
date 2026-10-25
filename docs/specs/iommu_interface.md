# IOMMU Interface

The IOMMU interface is the boundary between the kernel core (L2) and the IOMMU packages that drive each kind of
IOMMU (`../../knowledge/decisions/0039-platform-discovery.md`, `0079`). IOMMUs differ per platform rather than per
architecture (Intel VT-d, AMD-Vi, Arm SMMUv3, the RISC-V IOMMU), and an architecture may need several, so they're
behind an interface of their own, beside the arch interface (`arch_interface.md`), with the same rules.

Status: **specified for DMA remapping**, and implemented for VT-d (`src/iommu/vtd`, on x86-64, roadmap Da and Db):
identifying an IOMMU, translating DMA domains with invalidation, and recording faults. SMMUv3 (`src/iommu/smmuv3`, on
AArch64) is identified, and the rest comes with roadmap Dd; interrupt remapping with Dc. Four-digit numbers like
`0079` refer to decision records in `../../knowledge/decisions/`.

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
  in. IOMMU packages never allocate: tables and queues come from L2, as an architecture's page tables do, zeroed,
  and reached through the direct map. A call short of frames says so (`NeedFrames`) having changed nothing.
- **L2 picks domain IDs and device addresses.** Each domain on an IOMMU has an ID from 1 below `info.domain_ids`, and
  L2 allocates its I/O virtual addresses, below `1 << info.address_bits`.
- **L2 invalidates.** `map` and `unmap` change tables only; L2 calls `invalidate` once a batch of them is done, and
  frees a frame of a domain's tables only once nothing is attached to it and it's been invalidated.
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

// One DMA domain's translation on an IOMMU: its tables' root, its ID there, and how deep its tables are.
Domain :: struct {}
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
    // It didn't do what it was told in time, like turning translation on.
    Timeout,
}

// What identify finds out about an IOMMU.
IommuInfo :: struct {
    // The I/O virtual addresses its domains can have: below 1 << address_bits.
    address_bits : u32,
    // Its version, as its registers give it: major, then minor.
    major : u32,
    minor : u32,
    // The bytes of zeroed, contiguous memory enable takes, for its tables and queues.
    memory : u64,
    // Domain IDs from 1 up to this, one per domain on it.
    domain_ids : u32,
}

/*
 * Identify an IOMMU of kind whose registers, size bytes of them, L2 mapped uncached at registers, and keep what's
 * needed of it in iommu, changing nothing: DMA through it goes on as before, translated or not.
 */
identify : fn(iommu: ptr[mut Iommu], kind: IommuKind, registers: VirtualAddress, size: u64) -> Result[IommuInfo, IommuError] : ---
```

### Translating

```
MapError :: enum #backed_by(u8) {
    // frames ran out. Refill them and call again; nothing was changed.
    NeedFrames,
    // Something is mapped there already.
    AlreadyMapped,
    // Not page-aligned, or outside the domain's addresses.
    InvalidAddress,
}

// Zeroed frames L2 gives for new tables. Calls take them from the end.
TableFrames :: struct {
    count : u32,
    frames : PhysicalAddress[4],
}

// Table frames a call let go of. L2 frees them once the IOMMU can no longer reach them.
FreedFrames :: struct {
    count : u32,
    frames : PhysicalAddress[4],
}

/*
 * Turn translation on, with memory, info.memory bytes of zeroed, contiguous memory, for its tables and queues, which
 * it keeps, and the rest of what it reaches, like domains' tables, through the direct map at direct_map_offset. Every
 * stream is blocked until it's attached to a domain; its faults are recorded, not yet signalled (route_faults).
 */
enable : fn(iommu: ptr[mut Iommu], memory: PhysicalAddress, direct_map_offset: u64) -> Result[void, IommuError] : ---

// Make domain an empty one on the IOMMU, with ID id and root, a zeroed frame, for its top-level table.
init_domain : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], id: u32, root: PhysicalAddress) : ---

// stream's DMA translated through domain from now on, instead of what it was before; it takes frames for its own tables.
attach : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32, frames: ptr[mut TableFrames]) -> Result[void, MapError] : ---

// stream's DMA blocked again, and nothing the IOMMU cached of domain's for it left, when this returns.
detach : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], stream: u32) : ---

/*
 * The 4 KiB page at address in domain mapped to physical, readable, and writable if writable. Until invalidate, the
 * IOMMU may not see it.
 */
map : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64, physical: PhysicalAddress, writable: bool,
    frames: ptr[mut TableFrames]) -> Result[void, MapError] : ---

// The 4 KiB page at address in domain unmapped, if it's mapped; until invalidate, the IOMMU may still reach it.
unmap : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], address: u64) : ---

/*
 * Nothing the IOMMU cached of domain's tables left, when this returns: after unmapping, so it no longer reaches what
 * was mapped; after mapping (mapped), where it may cache what isn't mapped, like VT-d's caching mode.
 */
invalidate : fn(iommu: ptr[mut Iommu], domain: ptr[Domain], mapped: bool) : ---

/*
 * Let go of domain's tables, all but its root, as many as freed has room for each call: true once only the root is
 * left. Nothing is attached to it any more.
 */
release_domain : fn(iommu: ptr[Iommu], domain: ptr[mut Domain], freed: ptr[mut FreedFrames]) -> bool : ---
```

### Faults

```
// What an IOMMU writes, and where, to raise a message-signaled interrupt for its faults: arch_interface's MsiMessage.
FaultMessage :: struct {
    address : u64,
    data : u32,
}

// A DMA access an IOMMU blocked.
DmaFault :: struct {
    stream : u32,
    // The page it was to, as the device addressed it.
    address : u64,
    write : bool,
    // Why, as the IOMMU numbers its reasons.
    reason : u32,
}

// Signal its faults by writing message.
route_faults : fn(iommu: ptr[mut Iommu], message: FaultMessage) : ---

// The oldest fault it recorded and hasn't given yet, taken from its records, or null.
next_fault : fn(iommu: ptr[mut Iommu]) -> DmaFault? : ---
```

## VT-d

`src/iommu/vtd`: one DMA remapping hardware unit, from a DRHD in ACPI's DMAR.

| Interface | VT-d |
|---|---|
| `Iommu` | Its registers' address, its widest domain, and where its IOTLB registers and fault recording registers are |
| `identify` | `VER_REG` 1.0 or later; the registers `ECAP_REG.IRO` and `CAP_REG.FRO`/`NFR` place inside its size. Its domains are 4-level (48-bit) where `CAP_REG.SAGAW` has them, otherwise 3-level (39-bit), at most `CAP_REG.MGAW`'s width; neither, or no queued invalidation (`ECAP_REG.QI`), is `Unsupported`. Domain IDs from `CAP_REG.ND`, 0 left alone; 3 pages of memory for `enable` |
| `enable` | Legacy mode. The invalidation queue (one page, 256 descriptors) on, then the root table (one page, 256 buses), then a global context-cache and IOTLB invalidation, faults masked, and translation on. Each command waits for its status bit; each batch of invalidations ends with an invalidation wait descriptor writing a status word in the third page |
| `Domain` | Its second-level tables' root and its domain ID |
| `attach` | A context table for the stream's bus where it has none (from `frames`), and its context entry: translation type 0, the domain's root, its width (`AW`) and ID. A present entry is made not present and invalidated first. Each change is followed by a global context-cache and a domain-selective IOTLB invalidation |
| `detach` | The context entry not present, invalidated as `attach`'s are |
| `map` | Second-level entries readable and writable for tables, readable and writable as asked for the 4 KiB page; tables from `frames`, counted before anything changes |
| `invalidate` | A domain-selective IOTLB invalidation, waited for; after mapping, only in caching mode (`CAP_REG.CM`), or a write buffer flush where `CAP_REG.RWBF` asks for one |
| `release_domain` | The deepest tables first, each cleared from its parent |
| Faults | `route_faults` programs `FEDATA`, `FEADDR` and `FEUADDR` and unmasks `FECTL`; `next_fault` takes the next fault recording register with its F bit set, from where the last was found, and clears it |
| Caches | Where `ECAP_REG.C` is clear, as QEMU's is, every table entry and descriptor written is flushed with `clflush`, then `mfence` |
| Streams | A device's requester ID |

## SMMUv3

`src/iommu/smmuv3`: one SMMU, which the device tree's `iommu-map` refers to.

| Interface | SMMUv3 |
|---|---|
| `Iommu` | Its registers' address and its domains' width |
| `identify` | `SMMU_AIDR` says SMMUv3; both 64 KiB register pages fit in its size. Stage 2 (`SMMU_IDR0.S2P`), AArch64's tables (`TTF`) and 4 KiB pages (`SMMU_IDR5.GRAN4K`), or `Unsupported`; its domains' width is its output address size (`SMMU_IDR5.OAS`), at most 48 bits, and at least 39 |
| Not yet | Everything else, in `NOT_YET_IMPLEMENTED` until roadmap Dd: `enable` is `Unsupported`, so the kernel leaves the SMMU as it is and reaches none of the rest |
| Streams | The stream ID `iommu-map` gives a requester ID |

## Not Covered

- **AMD-Vi and the RISC-V IOMMU**: kinds the interface names, with no implementation yet.
- **Several IOMMU kinds on one architecture**: the kernel imports one IOMMU package for each architecture so far; one
  with VT-d and AMD-Vi both would choose by the registered kind.
