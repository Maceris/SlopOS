# 0083: SMMUv3 Stage 2 as Built

Status: accepted
Date: 2026-10-25
Related: `0079` (the plan for D), `0081` (VT-d DMA remapping, whose kernel part this shares), `0073` (MSIs through the
ITS), `../../docs/specs/iommu_interface.md`, `../roadmap.md` D

## Context
D's fourth stage (Dd, `0079`): SMMUv3 on AArch64, stage 2 only, with the stream table and the command and event
queues, behind the same interface and kernel code as VT-d (`0081`). Two things differ from VT-d: a device's MSIs are
writes to the GICv3's ITS, which the SMMU translates like any DMA, so they need a mapping in each domain; and QEMU's
SMMU signals its events only through wired interrupts, which the kernel routes only for controllers the platform
service registers, which it doesn't yet. Left to this stage: the stream table's shape, the doorbell, how faults reach
the kernel, and what the SMMU must offer.

## Decision
Built:
- **SMMUv3** (`src/iommu/smmuv3`), `NOT_YET_IMPLEMENTED` gone:
  - A two-level stream table, split at 6 bits, so a second-level table is one page of 64 entries, made from the
    kernel's table frames as streams are attached; at most 16 stream ID bits (1024 first-level descriptors). Every
    stream not attached aborts.
  - Command and event queues of 256 entries. A batch of commands ends with `CMD_SYNC`, done once the consumer
    reaches the producer, with a `dsb` before the producer moves.
  - Each attached stream's entry is stage 2 only, its domain's VMID (the domain's ID), its tables' root and width
    (3 or 4 levels from the output address size, at most 48 bits; 44 on QEMU, so 4), faults recorded. An entry in
    use is made to abort and invalidated before it changes.
  - Stage-2 pages are normal write-back inner shareable, or Device-nGnRE for device memory, with their access flag
    set; after unmapping, `CMD_TLBI_S12_VMALL` for the domain's VMID.
  - Required: stage 2, AArch64 tables, 4 KiB pages, two-level stream tables and coherent access, so no cache
    maintenance; QEMU 11.1's has them, given `-global arm-smmuv3.stage=2` (`0080`).
- **The doorbell**: a new `arch_interface.msi_doorbell`, the page devices write MSIs to as memory (AArch64: the ITS's
  `GITS_TRANSLATER`; x86-64: none, as VT-d takes the interrupt range as interrupts). Each new domain on an IOMMU maps
  it at its own address, writable device memory, and the domain's other addresses skip its page, so `irq_message`'s
  message is unchanged. The ITS goes on isolating MSIs by device ID, so the SMMU remaps no interrupts.
- **The interface**: `map` takes whether the page is device memory (VT-d's entries have no memory type, so it maps
  both alike); `info.fault_messages` says whether an IOMMU signals faults by a message.
- **Faults read at ticks**: an IOMMU that doesn't signal faults (SMMUv3 here) has its event queue read at CPU 0's
  ticks, 100 a second, and each fault logged as VT-d's are: translation, address size, access flag and permission
  faults with the address and whether it was a read, other events by their type.
- **Tests**: every boot test with the platform service on AArch64 runs its virtio devices through the SMMU, their
  MSIs through the doorbell's mapping; the IOMMU test checks the kernel reports it translating. A kernel built to give
  drivers device addresses 64 MiB off showed the fault read and logged (`F_TRANSLATION`), then was put back.
- **Hemera**: binary `^` isn't XOR (`~` is; `^` dereferences), and the parse error it made was followed by a page of
  errors about the file's later declarations being undeclared, which parser recovery, dropped earlier, would spare.

## Alternatives considered
- **A linear stream table**: 4 MiB contiguous for 16-bit stream IDs, or fewer stream IDs than the bus numbers use.
- **Wired event interrupts**: the platform service would register the GIC distributor and pass the SMMU's line from
  the device tree, for an interrupt that should never come; a tick's read of one register costs less than routing it.
- **MSIs for its events** (`SMMU_IDR0.MSI`): QEMU's SMMU has none, and they'd need the SMMU as a device of the ITS.
- **The doorbell at a reserved address of the domain's own**: `irq_message` would have to rewrite every message's
  address per domain; at its own address it's the same in every domain and without an IOMMU.
- **Nested or stage-1 translation**: stage 2 is the simplest for one domain per device (`0079`).

## Consequences
- Both architectures' drivers reach only their domains' DMA memory, and their own interrupts; De takes drivers out of
  the trusted computing base.
- A device whose DMA aborts before its domain exists (firmware's, like the UEFI boot disk's virtio-scsi) stops at the
  SMMU once the kernel has it; nothing the kernel runs uses them.
- When the platform service registers interrupt controllers, the SMMU's events can move to their wired line.
