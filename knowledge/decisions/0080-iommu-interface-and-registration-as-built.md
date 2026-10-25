# 0080: The IOMMU Interface and Registration as Built

Status: accepted
Date: 2026-10-25
Related: `0039` (IOMMUs in the kernel behind `iommu_interface`), `0079` (the plan for D), `0073` (Devices and DMA
domains), `0074` (the platform service), `../../docs/specs/iommu_interface.md`, `../../docs/specs/system_calls.md`,
`../roadmap.md` D

## Context
D's first stage (Da, `0079`): `iommu_interface`, checked at compile time like `arch_interface`; the kernel's IOMMUs; a
registration call behind the platform capability; and the platform service finding the IOMMUs in the firmware tables
and registering them, so each device's domain is attached through its IOMMU. Nothing translates yet: that's Db (VT-d)
and Dd (SMMUv3). Left to this stage: how far the interface goes before an IOMMU translates, how the kernel imports
several IOMMU packages, what a registration covers, and what "attached through its IOMMU" means before translation.

## Decision
Built:
- **`iommu_interface`** (`src/iommu_interface`, specified in `docs/specs/iommu_interface.md`): the per-implementation
  `Iommu` type, `IommuKind` (VT-d, AMD-Vi, SMMUv3, the RISC-V IOMMU), and `identify`, which checks that registers are an
  IOMMU of that kind with the translation domains will use, and gives its I/O address width and version, changing
  nothing. Only what Da uses is declared: Db and Dd add attaching, mapping, invalidation and faults, with signatures
  from building them rather than guessed now.
- **Two implementations**: `src/iommu/vtd` (`VER_REG` 1.0 or later, its IOTLB and fault recording registers inside its
  size, 4-level or 3-level second-level tables from `CAP_REG.SAGAW`, no wider than `MGAW`) and `src/iommu/smmuv3`
  (`SMMU_AIDR` version 3, both register pages, stage 2 with AArch64's tables and 4 KiB pages, its width the output
  address size, at most 48 bits). On QEMU 11.1: VT-d 1.0 with 48-bit addresses; SMMUv3.1 with 44.
- **The check**: every package imported under an alias starting `iommu_` (`iommu_vtd`, `iommu_smmuv3`) implements
  `iommu_interface`, by the arch interface's rules, through the same code in `src/checks`, its messages naming the
  interface checked. One alias per package rather than one `iommu` for all, since an architecture may build several
  (`0039`: VT-d and AMD-Vi on x86-64); for now each architecture builds one, and the kernel's `IommuUnit` is its type.
- **The kernel's IOMMUs** (`src/kernel/iommus.hsc`): a table of 8, each with its registers mapped uncached in the
  kernel window, and up to 32 ranges of requester IDs among them. A table rather than handle objects, as interrupt
  controllers are: they're registered once and never go.
- **`iommu_register`** (58): platform, kind, registers as device memory (not a window, uncached), and one range: count
  requester IDs from first, in `device_address` form, within one segment, which the IOMMU knows as stream IDs from
  stream. Registering the same IOMMU again, the same kind at the same physical address, gives its number and adds the
  range. New errors: `NoIommu` (42), `TooManyIommus` (43), `WrongIommu` (44). ABI 5.
- **Which IOMMU a device is behind**: the one whose range covers its requester ID most narrowly, so a DMAR unit with
  `INCLUDE_PCI_ALL` (a whole segment) gives way to one listing the device. `device_attach` finds it, records it and the
  device's stream on the Device, and binds the domain to it when it's the domain's first device; a device behind
  another IOMMU, or behind none where the domain's is behind one, is refused with `WrongIommu`, so each domain will
  have one IOMMU's page tables.
- **The platform service** (`src/services/platform/iommus.hsc`) registers the IOMMUs once the buses are numbered,
  before any device is given out: on x86-64 from DMAR's DRHDs, a unit with `INCLUDE_PCI_ALL` for its whole segment,
  otherwise each endpoint and bridge in its device scopes, by its path from its start bus (a bridge with the buses
  behind it as one more range); I/O APIC and HPET scopes wait for Dc. On AArch64, each entry of the host bridge's
  `iommu-map` whose phandle is an `arm,smmu-v3` (`devicetree.find_phandle`, new). It logs how many ranges were
  registered, or that the firmware tables describe no IOMMU. QEMU 11.1's DMAR lists each endpoint rather than using
  `INCLUDE_PCI_ALL`, so on q35 that's 7 ranges; on virt, one of 65536.
- **virtio**: every driver takes `VIRTIO_F_ACCESS_PLATFORM` where it's offered, as QEMU refuses `FEATURES_OK` without
  it once a device has `iommu_platform=on`.
- **Tests**: `boot.py` gives q35 VT-d (`-device intel-iommu,intremap=on`, first among the PCI devices) and virt an
  SMMUv3 (`iommu=smmuv3`, with `-global arm-smmuv3.stage=2`, as QEMU's default is stage 1), unless `--no-iommu`, and
  its virtio devices `iommu_platform=on`, as the boot tests' are. A boot test checks the kernel identified the IOMMU on
  each architecture, and another drives virtio-rng with `--no-iommu`. `test_devices` checks registration is refused for
  an unknown kind, memory that isn't device memory, no requester IDs, and another device's registers (the HPET, the
  PL011).
- **Found on the way**: `base` is built into Hemera's compiler, so changing it (here the ABI version) takes a rebuilt
  compiler; and Hemera's `docs/operators.md` had `is_none` false both ways, fixed.

## Alternatives considered
- **The interface's whole shape now**, with stubs: commits Db's and Dd's signatures (frames for context tables, the
  invalidation queue's memory) before either is built.
- **One `iommu` alias per architecture**: simpler today, and wrong the day x86-64 builds AMD-Vi beside VT-d.
- **Handle objects for IOMMUs**: nothing would hold or close them.
- **Ranges as a list in one call**: one range per call keeps the call's arguments in registers; units with several
  ranges are registered again.
- **The platform service resolving `INCLUDE_PCI_ALL` into what other units leave**: the kernel's narrowest-range rule
  does it with no subtraction, and holds for units registered in any order.
- **Testing `WrongIommu` from a test program**: the test programs run without the platform service, so nothing is
  registered when they attach a device; it's reached once De's test driver attaches through a real IOMMU.

## Consequences
- Db and Dd extend `iommu_interface` and their packages, with each IOMMU's translation turned on; `identify`'s width
  bounds their domains' IOVA allocators.
- An IOMMU registered after a device was attached doesn't cover that device: the platform service registers first.
- Requester IDs come from the bus numbers as the platform service leaves them, so a device scope's path is followed
  after bridges are numbered.
