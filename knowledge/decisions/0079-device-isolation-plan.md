# 0079: The Plan for Device Isolation (D)

Status: accepted
Date: 2026-10-25
Related: `0039` (IOMMUs in the kernel behind `iommu_interface`), `0072` (D before M8, with VT-d and SMMUv3),
`0073` (Devices, DMA domains and DMA memory), `0078` (a destroyed Device turns its DMA off), `0013` (malicious
drivers and devices are in scope), `../roadmap.md` D

## Context
M7's drivers are in the trusted computing base: a DMA domain is only a name (`0073`), DMA memory's device address
is its physical address, and a driver, or its device, can read and write any memory. `0072` puts D, the IOMMUs, right
after M7 and before M8's storage stack, with Intel VT-d and Arm SMMUv3 themselves and interrupt remapping, and
`0039` puts IOMMU drivers in the kernel behind a second compile-time interface, registered by the platform service
from the firmware tables. What was left to decide here: how D is staged, what address a device sees for DMA memory,
what can be mapped into a domain, and what a DMA fault does.

## Decision
Chosen with the project's owner:
- **Staged by interface, then by IOMMU**, five stages, each with its as-built record:
  - **Da, the interface and registration**: `iommu_interface` (its spec in `docs/specs`, checked at compile time
    like `arch_interface`), kernel IOMMU objects, a registration call behind the platform capability (kind,
    registers as device memory, the requester IDs or stream IDs it covers), and the platform service reading
    ACPI's DMAR on x86-64 and the device tree's `iommu-map` on AArch64 to register them and attach each device's
    domain to its IOMMU.
  - **Db, VT-d DMA remapping**: root and context tables, second-level page tables per domain, the invalidation
    queue, and fault reporting.
  - **Dc, VT-d interrupt remapping**: the interrupt remapping table, and `irq_message` giving remappable MSIs, so a
    device can only raise the interrupts its Device was given.
  - **Dd, SMMUv3**: stream tables and stage-2 translation per domain, the command and event queues; the GICv3 ITS
    already isolates MSIs by device ID, and its doorbell is mapped into each domain so a device's MSIs reach it.
  - **De, drivers out of the TCB**: with an IOMMU, no device has DMA outside its domain; without one, only drivers
    `system_config` marks as trusted get DMA memory (`0039`); and a test driver (QEMU's `edu`) that DMAs outside its
    domain and is stopped and reported.
- **IOVAs are allocated per domain**: each domain has an I/O address space of its own, and `memory_device_address`
  gives an address in it, so a driver never learns a physical address and a domain's addresses say nothing about
  memory outside it.
- **Only DMA memory is mapped**: memory made with `dma_memory_create` in a domain, pinned and contiguous, as now. A
  client's own memory isn't mapped into a device's domain; zero-copy from it waits for a need (M8's partition server
  forwards offsets into its driver's buffers instead).
- **A DMA fault is its driver's owner's to act on**: the access is blocked, the kernel logs it and raises a signal on
  the Device, which the supervisor watches; it kills and restarts the driver as it does one that crashes, within the
  restart limit (`0077`).

Within that, and the as-built records will say how each came out:
- VT-d in legacy mode with second-level tables, and SMMUv3 stage-2 only, the simplest translation each offers for one
  domain per device; QEMU 11.1 has both (`-device intel-iommu,intremap=on` on q35, `-machine virt,iommu=smmuv3`).
- virtio drivers negotiate `VIRTIO_F_ACCESS_PLATFORM`, and QEMU's virtio devices get `iommu_platform=on`, so their
  DMA goes through the IOMMU.
- Every boot test that starts drivers runs with the IOMMUs from Da on (`0072`), and one runs without to keep the
  trusted path tested.

## Alternatives considered
- **Both IOMMUs side by side**: fewer stages, each larger, and harder to tell which IOMMU a failure is in.
- **x86-64 first, then AArch64**: VT-d done sooner, at the cost of the both-architectures rule for stages.
- **Identity IOVAs**: no allocator and simpler tables, but physical addresses keep reaching drivers.
- **Any memory object mappable**: zero-copy from clients now, at the cost of pinning and unmapping arbitrary memory
  before anything needs it.
- **Faults only logged**: a misbehaving driver would carry on; **the kernel killing the driver**: policy in the kernel
  that the supervisor already has.

## Consequences
- M8 starts once De is done: no driver of the storage stack is trusted with DMA.
- `0073`'s DMA calls keep their shapes; what changes is what a domain and a device address mean, so M7's drivers need
  only `VIRTIO_F_ACCESS_PLATFORM`.
- The Device object gains a signal for DMA faults, and the supervisor watches it beside each driver's end.
- Bit-packed descriptor formats (`../hemera-proposals/bitfields.md`) and invalidation fences are where Hemera is
  stressed; the feedback log records what they need.
