# 0073: The Kernel for Drivers as Built

Status: accepted
Date: 2026-10-24
Related: `0070` (the plan for M7), `0039` and `0055` (the platform capability, IRQs, device memory), `0013` (drivers
and the IOMMU), `0071` (7a), `0072` (D, the IOMMUs, right after M7), `../../docs/specs/system_calls.md`, `../../docs/specs/arch_interface.md`, `../roadmap.md`
M7

## Context
M7's second stage (7b). `0070` planned the kernel's part of drivers: message-signaled interrupts through the local
APIC and the GICv3's ITS, without INTx; DMA memory, pinned and physically contiguous, whose physical address a driver
can have, with no IOMMU yet; and the firmware tables given to the root task, for the platform service of 7c. Asked
here: what a driver gets an MSI through (a Device object first, which an IOMMU domain will later attach to, rather
than one call per vector on the platform capability); what DMA hangs off (a DMA domain, the place an IOMMU domain
will take); how the tables reach the root task (the kernel copies them, rather than keeping and mapping them); and
how to test it before real drivers (QEMU's `edu` device, rather than only kernel-side tests).

## Decision
As asked, built:
- **Devices** (`device_create`, call 51): a kernel object for one PCIe function, made with the platform capability:
  its address (`slop_os.device_address`: segment, bus, device, function) and its MSI source, what the interrupt
  controller knows its MSIs by (the ITS's device ID, which the device tree's `msi-map` gives; unused on x86-64). No
  two devices share an address, nor, where the controller uses sources, a source (`DeviceExists`). Kinds `Device` (15) and `DmaDomain` (11, where the
  reserved `IommuDomain` was).
- **MSIs** (`irq_create_msi`, `irq_message`): an IRQ for one of the device's events, up to `MAX_DEVICE_MSIS` (32),
  routed to the next CPU in turn through the per-CPU device interrupt IDs wired lines use, so packets and bindings
  are as for any IRQ; `irq_message` gives the address and data for its MSI or MSI-X entry. Closing the device
  destroys its IRQs, as closing memory destroys its windows.
- **The arch interface** loses `msi_message` and gains `msi_device_memory`, `msi_controller_memory`, `init_msi`,
  `add_msi_device`, `remove_msi_device`, `route_msi` and `unroute_msi`. x86-64's are the local APIC's message and
  otherwise nothing. AArch64's drive the **ITS**, found in the device tree: L2 gives it one block of memory once every
  CPU has started, for flat device and collection tables, a 64 KiB command queue, one LPI property table and a pending
  table per redistributor; each redistributor is a collection; each routed event is given its own LPI (8192, from
  8192), translated back to the kernel's ID as an SPI is. A device's translation table is a block of its own.
- **DMA** (`dma_domain_create`, `device_attach`, `dma_memory_create`, `memory_device_address`): a domain holds nothing
  yet, and a device address is a physical address. DMA memory is a memory object over one block of frames from the
  buddy allocator's new `allocate_below`, pinned, zeroed, ending at or below a limit, charged for its whole block and
  given back whole; its device address is gone once its domain is (`NotDmaMemory`). `device_attach` records the
  domain, for an IOMMU to confine the device to later.
- **The firmware tables**: before the other CPUs start, the kernel copies them into one read-only block (the same
  kind of memory object), the root task's `firmware` grant: a `slop_os.FirmwareTables` header and an entry per table
  (signature, size, offset, physical address), then the tables. On x86-64, ACPI's: the RSDP, what the XSDT or RSDT
  lists, and the FADT's DSDT and FACS, read through the kernel window, since firmware may keep them in reserved
  memory the direct map leaves out. On AArch64, the device tree's blob. The kernel reads nothing in them.
- **`test_msi_dma`**, given the platform capability and the copy as the platform service will be: it checks the
  copy, finds ECAM (the MCFG, or the device tree's host bridge and `msi-map`), finds `edu` on bus 0, makes its
  Device, takes its MSI, fills 32 MSIs and is refused a 33rd, has `edu` DMA a page into its buffer and back into DMA
  memory below 4 GiB, with an MSI when it's done, and sees the IRQs go with the device. Every test's entry takes a
  `firmware` grant now. QEMU runs `edu` with `dma_mask` widened, since virt's RAM starts at 1 GiB.
- `ABI_VERSION` 3.
- **Found in Hemera on the way, fixed (`0047`)**: a name used unqualified that a package's own pending `#insert`
  and one of its imports both declare was bound to the import or the insert's, whichever the compiler reached first,
  and in the first case reported as an error: `test_protocols` failed to build about one time in three. Now such a
  name waits for the package's own insert, whose declaration wins, unless it's a builtin or base's, which code an
  `#insert` runs needs (Hemera's `docs/compilation.md`, The Top Level). With a test.

## Alternatives considered
- **One call per vector on the platform capability**, `irq_create_msi(platform, budget, device_id)`: no new object,
  but nothing for an IOMMU's domain or interrupt remapping to attach to, and every driver would need the platform
  capability.
- **DMA on the platform capability**, or **pinning any memory object** and listing its pages: the first gives every
  driver the whole machine, the second has nothing contiguous for a device (like `edu`) that needs it.
- **Keeping the firmware tables' memory and mapping it read-only**: the device tree is in the bootloader's memory
  anyway, and the platform service would chase physical pointers through device memory.
- **Testing in the kernel only**: the ITS's tables and commands, and the copy, without a device writing a real MSI
  or doing real DMA until 7c.

## Consequences
- A driver holds a Device, its MSI IRQs, a DMA domain and DMA memory, and device memory for its BARs; the platform
  service of 7c makes them from the firmware tables' copy.
- Without an IOMMU any driver can DMA anywhere, and forge MSIs, so drivers are trusted until D's VT-d and SMMUv3
  (`0072`), which translate DMA domains and remap interrupts; a Device is what a domain and a remapping entry attach to.
- An event's LPI on AArch64 is fixed while it's routed: moving an IRQ to another CPU (`MOVI`) comes when affinity does.
- MSI-X tables live in a device's BAR; a driver programs them through its device memory, as `test_msi_dma` programs
  `edu`'s MSI capability through ECAM.
