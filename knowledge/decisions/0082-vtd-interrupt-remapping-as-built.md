# 0082: VT-d Interrupt Remapping as Built

Status: accepted
Date: 2026-10-25
Related: `0079` (the plan for D), `0081` (VT-d DMA remapping), `0073` (message-signaled IRQs),
`../../docs/specs/iommu_interface.md`, `../roadmap.md` D

## Context
D's third stage (Dc, `0079`): VT-d's interrupt remapping table, and `irq_message` giving remappable MSIs, so a device
can only raise the interrupts its Device was given. Without it, a device behind VT-d could still write any message to
the interrupt range, which DMA remapping doesn't stop, and so raise any CPU's interrupts, its vector chosen. SMMUv3
needs no counterpart: the GICv3's ITS already takes a device's MSIs only as events its device ID was given (`0073`).
Left to this stage: the interface's part, how entries are given out, and what becomes of the I/O APIC's lines, whose
interrupts reach VT-d as compatibility-format ones too.

## Decision
Built:
- **The interface**: `info.interrupts`, the entries an IOMMU remaps (0 for none, as SMMUv3's); `remap_interrupt`
  (an index, the stream it may come from, a CPU and a vector, giving the device's message) and `unmap_interrupt`, each
  done, cached copies invalidated, when it returns; `MsiMessage` in place of `FaultMessage`; and a `DmaFault` tells an
  interrupt fault from a DMA one, with the entry's index in place of the address.
- **VT-d**: where `ECAP_REG.IR` is set, `enable` sets up a table of 256 entries in a fourth page, with x2APIC
  destinations where the unit has extended interrupt mode, invalidates the interrupt entry cache, and turns remapping
  on with compatibility format off. An entry is fixed delivery, edge-triggered, to the CPU's APIC ID in physical
  mode, with source validation of the requester ID (`SVT` 1, `SQ` 0); a message is the remappable format with the
  entry's index as its handle.
- **The kernel** (`src/kernel/translation.hsc`): each message-signaled IRQ of a device behind an IOMMU that remaps
  gets an entry there, up to 256 per IOMMU, the message its driver programs the entry's; destroying the IRQ clears the
  entry before the route goes. Which IOMMU is the device's comes from its requester ID, as attaching it does, so an
  IRQ made before the device is attached is remapped too.
- **Wired lines**: with remapping on and compatibility format off, the I/O APIC's interrupts are blocked as a forged
  message would be, and its entries aren't remapped yet, which needs the I/O APIC's source ID from DMAR's I/O APIC
  scopes and the remappable format in `arch/x86_64`'s redirection entries. Until a driver needs a wired line, `irq_create`
  refuses once an IOMMU remaps (`NoController`); the platform service registers no I/O APIC yet, and the tests that
  route the I/O APIC's lines run without the platform service.
- **Faults**: an interrupt remapping fault is logged with its entry and device, as a DMA fault is (`0081`).
- **Tests**: every boot test with the platform service on x86-64 takes its virtio devices' MSI-X interrupts through
  remapped entries, and the IOMMU test checks the kernel says it remaps 256. Kernels built to get it wrong, then put
  back, showed: a handle to an entry that isn't there is blocked and logged (reason 0x22), an entry for another
  requester ID is blocked (QEMU: "invalid IRTE SID"), and a compatibility-format message is let through by QEMU 11.1,
  which doesn't block them as the hardware does with compatibility format off.

## Alternatives considered
- **Compatibility format left on** (`GCMD_REG.CFI`): wired lines would go on working, and any device could forge any
  interrupt in the old format, which is what this stage is for.
- **I/O APIC entries remapped now**: the arch interface's wired routing would take an entry, and the platform service
  would register each I/O APIC's source ID; nothing uses a wired line with the platform service yet.
- **Source validation by bus range** (`SVT` 2): for devices behind a PCIe-to-PCI bridge, which take the bridge's
  requester ID; QEMU's virtio devices are PCIe, and a device's own ID is the narrowest check.
- **Posted interrupts**: for virtual machines, which SlopOS doesn't run.

## Consequences
- A driver behind VT-d can raise only its own device's IRQs; with Db, it reaches only its domain's memory. De moves
  drivers out of the trusted computing base.
- QEMU can't show compatibility-format interrupts blocked; that waits for hardware.
- A driver that needs a wired line behind VT-d brings I/O APIC remapping with it.
