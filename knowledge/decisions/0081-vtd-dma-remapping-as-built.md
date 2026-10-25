# 0081: VT-d DMA Remapping as Built

Status: accepted
Date: 2026-10-25
Related: `0079` (the plan for D), `0080` (the IOMMU interface and registration), `0073` (Devices, DMA domains and DMA
memory), `0078` (a destroyed Device turns its DMA off), `../../docs/specs/iommu_interface.md`, `../roadmap.md` D

## Context
D's second stage (Db, `0079`): VT-d translating each DMA domain, in legacy mode with second-level tables, with the
invalidation queue and fault reporting, so a device behind it reaches only its domain's DMA memory, at I/O virtual
addresses of the domain's own. Left to this stage: what the interface's translation functions are, where the
kernel's part ends and VT-d's begins, how a domain's addresses are given out, who pays for tables, what happens to a
domain's devices and memory as each goes, and how a fault is reported until De gives it to the supervisor.

## Decision
Built:
- **`iommu_interface` for translation**: a per-implementation `Domain`; `enable` (translation on, every stream blocked
  until attached, with `info.memory` bytes of zeroed memory from L2, tables reached through the direct map);
  `init_domain`, `attach` and `detach` a stream; `map` and `unmap` a 4 KiB page; `invalidate`, after unmapping or,
  where the IOMMU caches what isn't present, mapping; `release_domain`, its tables a few frames a call; and
  `route_faults` and `next_fault`. As the arch interface's paging, a call short of frames returns `NeedFrames` having
  changed nothing, and L2 refills them. SMMUv3 lists all of it in `NOT_YET_IMPLEMENTED` until Dd, its `enable`
  `Unsupported`, so the kernel leaves it as it is.
- **The kernel imports each architecture's IOMMU package as `iommu_unit`** (`import iommu_vtd as iommu_unit`), which
  the interface check covers by its `iommu_` prefix, so the kernel's code calls one name on both architectures.
- **VT-d** (`src/iommu/vtd`): the invalidation queue on (one page), then the root table (one page), a global
  context-cache and IOTLB invalidation, and translation on, each command waiting for its status bit; a context table
  for each bus with an attached device; a context entry per device with translation type 0, the domain's root, width
  and ID, made not present and invalidated before it changes; second-level tables of 3 or 4 levels, 4 KiB pages
  only. Every batch of invalidations ends with a wait descriptor writing a status word. Invalidation is global for the
  context cache and domain-selective for the IOTLB, which is simple and always right; page-selective invalidation
  waits for a need. QEMU's unit says its table walks don't snoop (`ECAP_REG.C` clear), so every entry and descriptor
  written is flushed with `clflush` and `mfence`, new x86-64 intrinsics in Hemera's `base`. Queued invalidation is
  required.
- **Domains** (`src/kernel/translation.hsc`): a domain's first device behind a translating IOMMU gives it an ID there
  (up to 255 per IOMMU) and a root table; tables mapping its memory are charged to its budget, and context tables to
  nothing, being the IOMMU's own, at most 256. A domain no device is attached to when its first DMA memory is made is
  bound to no IOMMU (`0080`), so its memory is never left unmapped by a later binding.
- **I/O virtual addresses**: each domain's from 1 MiB, so a device given nothing reaches nothing at 0, the lowest free
  range below the memory's limit, from up to 16 freed ranges or past the highest taken; a range freed where none is
  kept isn't reused. `dma_memory_create`'s limit is the device addresses' in a translating domain, its frames anywhere;
  `memory_device_address` gives the domain's address.
- **Teardown**: destroying DMA memory unmaps it and invalidates before its frames can go; destroying a Device clears
  its Bus Master Enable and detaches it; destroying a domain detaches each device still in it, and stops its
  translation, so later destroys of its memory have nothing to unmap; its tables, root and ID go at its release, once
  no CPU can be using them.
- **Faults**: each translating IOMMU's fault events are an MSI the kernel routes for itself to CPU 0 (a route whose
  controller is `IOMMU_CONTROLLER`), at which the kernel takes up to 16 recorded faults and logs each, with the device
  and the address it was refused. The device's driver and the supervisor aren't told until De.
- **Tests**: every boot test with the platform service runs its virtio devices through VT-d, which they reach only
  through their domains; the IOMMU test checks the kernel reports it translating on x86-64, and not yet on AArch64.
  A kernel built to give drivers device addresses 64 MiB off showed the fault reported (reason 6, an entry not
  present) and QEMU's own report of it, then was put back; a test that does this on purpose is De's.

## Alternatives considered
- **Register-based invalidation**: no queue, but Dc's interrupt remapping needs the queue anyway.
- **Page-selective IOTLB invalidation**: fewer entries dropped, at the cost of address masks and `CAP_REG.PSI`; a
  domain is one driver's, so dropping all of its entries costs little.
- **Identity or physical addresses in a domain**: no allocator, but physical addresses reach drivers (`0079`).
- **A free list of any length**: unbounded kernel memory per domain for a case (memory made and destroyed in a
  pattern that fragments) no driver has.
- **Tables charged to the IOMMU's registrant**: the platform service would pay for every driver's tables.
- **Polling for faults**: no interrupt, but a fault would wait for a timer and the kernel would read the IOMMU's
  registers on every tick.

## Consequences
- Drivers behind VT-d no longer reach memory outside their domains; Dc stops them forging interrupts, and De moves
  them out of the trusted computing base, with the supervisor acting on faults.
- Dd implements the same functions for SMMUv3, and the kernel's part is shared.
- The same domain's memory can't move between IOMMUs; a device behind another is refused (`WrongIommu`).
