# 0070: The Plan for Platform and Drivers (M7)

Status: accepted
Date: 2026-10-24
Related: `0039` (the platform capability), `0040` (protocols), `0017` (the supervisor), `0055` (IRQs and device
memory), `0068` (typed entry points), `../design/protocols.md`, `../design/services.md`, `../roadmap.md` M7

## Context
M7 brings the first drivers: a platform service that reads the firmware tables and enumerates PCIe, virtio
devices over PCI, and the device-class protocols clients use to reach them. Several things it needs don't exist
yet: message-signaled interrupts (virtio-pci's way, and the kernel's `msi_message` is still a stub), memory a
device can DMA into, protocols for messages of variable size (`0040` designed them; the first services use
fixed structs), and a way for the platform service to read the firmware tables, which are RAM the kernel owns.

## Decision
Chosen with the project's owner:
- **MSI-X in the kernel first**: a call that gives a driver an IRQ and the address and data to program into its
  device, through the local APIC on x86-64 and the GICv3 ITS on AArch64. No INTx, so no AML is needed.
- **DMA memory now, an IOMMU later**: memory objects can be pinned and physically contiguous, and a driver holding
  the device's capability can ask for their physical address. Without an IOMMU a driver can still DMA anywhere, so
  drivers stay trusted until an IOMMU stage (VT-d, SMMUv3), a known gap until then.
- **Drivers in the order rng, console, blk, input**, with supervisor restarts once there are drivers to restart.
- **`0040`'s generated protocols now**, as the device classes' basis:
  - variable-size data is a `std` type, `slop_os.Relative[T]`: an offset from itself and a count;
  - each protocol package generates its validators and its send and receive functions at its top level, from
    its types, with `#insert` (which generics can't do);
  - the protocol tag is the channel's, as `0040` says: set by `channel_create`, readable by both ends, checked by
    `std` when a `Channel[P]` arrives; the startup grant's tag goes;
  - the first services' protocols move to the generated form, so there's one way to write one.

M7 comes in six stages:
- **7a, protocols**: the generator and `Relative[T]` in `std/os`, channel tags in the kernel, `PROTOCOL` metadata,
  `Unsupported` and `is_idempotent` as `0040` describes, a house-rule check for protocol packages, and the process
  manager's, the entropy service's and the supervisor's protocols moved to it.
- **7b, the kernel for drivers**: MSI-X (local APIC, GICv3 ITS), DMA memory and physical addresses, and the
  firmware tables (ACPI's on x86-64, the device tree on AArch64) given to the root task, for the platform service.
- **7c, the platform service and virtio-rng**: the platform service reads the tables, enumerates PCIe through
  ECAM (MCFG on x86-64, the device tree's host bridge on AArch64), and starts each driver with only its device's
  capabilities; a virtio-pci transport package (modern, MMIO BARs, split virtqueues); virtio-rng, and the `entropy`
  device-class protocol, which the entropy service reseeds from.
- **7d, virtio-console** and the `serial` protocol.
- **7e, virtio-blk** and the `block` protocol, for M8's storage.
- **7f, virtio-input** and the `input` protocol, and the supervisor restarting a driver that crashes.

Each stage gets an "as built" record, and runs on both architectures.

## Alternatives considered
- **Legacy INTx**: little kernel work, but q35's routing needs ACPI's `_PRT`, which is AML, so it would be
  hard-coded for QEMU, and lines are shared.
- **Polling drivers first**: working drivers soonest, but it hides the interrupt path M7 should stress.
- **An IOMMU in M7**: drivers confined from the start, as `services.md` intends, at the cost of two IOMMUs first.
- **Fixed-struct device protocols**: less work now, but bulk data and variable-size replies would each be
  special-cased, and `0040` would be rewritten later anyway.
- **One reflective validator**: no generated code, but slower per message, and a bad protocol type only shows when
  a message arrives.
- **A built-in relative view type**: nicer to use, but a language feature with its own rules.
- **Keeping grant tags**: no kernel change, but channels passed at run time would carry none.

## Consequences
- Drivers are in the TCB until the IOMMU stage, which the roadmap gains after M7.
- `slop_os.ABI_VERSION` changes in 7a (channel tags) and 7b (the new calls).
- The platform service is the first program that reads firmware tables; the kernel's own parsing (the MADT, the
  device tree) stays, for what it needs itself.
