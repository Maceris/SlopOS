# 0078: A Device Turns Its DMA Off When It's Destroyed

Status: accepted
Date: 2026-10-25
Related: `0073` (Devices and DMA), `0077` (driver restarts), `../../docs/specs/system_calls.md`

## Context
7f's restart test showed it (`0077`): QEMU warned "Guest moved used index from 5 to 0" when a killed virtio-console
driver's device was reissued. A driver's DMA memory, its queues among it, goes with the driver, but its device kept bus
mastering on and went on reading and writing that memory, freed and soon someone else's, until the next driver reset it.
Nothing stopped the device: the kernel's Device held its address and MSIs, not its configuration space, which only the
platform service and the driver had mapped. The IOMMU stage (`0072`'s D) would confine it to its domain; until then
it's the kernel's to stop.

## Decision
- `device_create` (call 51) takes the physical address of the function's 4 KiB of configuration space, page-aligned
  and not RAM (`BadAddress` otherwise). The kernel maps it in its window for the Device's life.
- Destroying a Device clears the function's Bus Master Enable (the command register's bit 2) first. Its driver's DMA
  memory is freed only once a grace period has passed, and none passes while the destroy that reaches the Device runs,
  so the device stops before any of that memory is used again. Each driver turns Bus Master Enable on as it starts, as
  they all did already.
- `slop_os.ABI_VERSION` and base's `SLOP_OS_ABI_VERSION` are 4.
- `test_msi_dma` no longer clears edu's Bus Master Enable itself: it checks closing the Device did, and that a
  configuration space off a page is refused.

## Alternatives considered
- **The supervisor clearing it** before reissuing: too late, since the driver's memory is freed as it ends.
- **Keeping a dead driver's DMA memory** until its device is reset: memory held for every driver that ends, and the
  device still writing into it.

## Consequences
- A device that's mid-transfer when its Device goes sees its transfer fail, as when a driver resets it.
- The IOMMU stage adds detaching the domain to the same destroy.
