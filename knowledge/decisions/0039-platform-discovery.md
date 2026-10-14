# 0039: Platform Discovery, and Hardware the Kernel Drives

Status: accepted
Date: 2026-10-13
Related: `0002` (layers), `0012` (root task), `0013` (threat model), `0031` (the kernel parses no
firmware tables), `0032` (arch interface), `0034` (`Irq`, `IommuDomain`)

## Context
The platform service (L3) discovers hardware. Two kinds of hardware still have to be driven by the
kernel itself: interrupt controllers, since routing interrupts is privileged, and IOMMUs, since
they are what confines drivers. `0031` keeps every firmware table out of the kernel, so something
has to tell the kernel about them. The arch interface covered only message-signaled interrupts.

## Decision
- **One platform service** reads the static firmware tables (ACPI's MADT, MCFG, DMAR or IVRS, or the
  devicetree), enumerates PCIe through ECAM, and starts drivers with only their own device's
  capabilities. It's in the trusted computing base, so it stays small.
- **AML gets its own service later.** ACPI's bytecode (legacy interrupt routing through `_PRT`,
  power management, batteries, the embedded controller) is large and runs firmware-supplied code,
  so it goes in a separate, restartable, less-trusted service once something needs it.
- **The platform service registers hardware with the kernel**, using a capability the root task
  gives it:
  - **Interrupt controllers** (an I/O APIC, a GIC distributor, a PLIC): kind, registers as a device
    `Memory` handle, and the range of lines. It then creates `Irq` objects for individual lines,
    with trigger mode and polarity from the firmware tables, and hands them to drivers. The kernel
    allocates vectors, programs the routing, and masks a level-triggered line until its driver
    acknowledges it.
  - **IOMMUs** (Intel VT-d, AMD-Vi, Arm SMMU, the RISC-V IOMMU): kind, registers, and which devices
    each covers.
- **Message-signaled interrupts:** creating such an `Irq` returns the `MsiMessage` its driver
  programs into the device.
- **IOMMU drivers are in the kernel**, behind a second compile-time interface, `iommu_interface`.
  An architecture may build several implementations (x86-64: VT-d and AMD-Vi), and registration
  picks one at boot. An `IommuDomain` attaches devices by PCIe requester ID, maps `Memory` objects
  at I/O virtual addresses, and unmaps them with IOTLB invalidation. Mapped memory is pinned.
- **Without an IOMMU**, only drivers the boot configuration marks as trusted get DMA.

## Alternatives considered
- **The kernel parses the MADT for interrupt controllers** (seL4): simpler, but reverses `0031`, and
  doesn't cover devicetree platforms.
- **A user-space IOMMU service:** it would be trusted anyway, and the kernel would still have to stop
  memory being freed while a device can DMA into it.
- **PCIe enumeration in its own process** (Redox's `pcid`): PCIe needs the ECAM base from MCFG, so
  the split buys little while both are small.

## Consequences
- The arch interface gains wired-interrupt functions (`../../docs/specs/arch_interface.md`).
- `iommu_interface` gets its own specification before M7.
- The registration syscalls join the syscall table in `slop_os`, behind the platform capability.
- Fuchsia's Zircon does the same for IOMMUs: user space parses DMAR and creates kernel IOMMU
  objects from it.
