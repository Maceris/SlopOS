# 0074: The Platform Service and virtio-rng as Built

Status: accepted
Date: 2026-10-24
Related: `0070` (the plan for M7), `0073` (7b, the kernel for drivers), `0039` (the platform service), `0071` (generated
protocols), `0072` (D, the IOMMUs), `../../docs/specs/programs.md`, `../roadmap.md` M7

## Context
M7's third stage (7c). `0070` planned the platform service, which reads the firmware tables and enumerates PCIe through
ECAM, a virtio-pci transport, virtio-rng, and a device-class protocol the entropy service reseeds from. Asked here: who
starts drivers (the supervisor, claiming devices from the platform service, rather than the platform service itself);
what a driver starts with (its whole device as entry parameters, rather than asking the platform service for its BARs);
how the entropy service, which starts before any driver, gets hardware bytes (drivers offer themselves, rather than
the entropy service waiting for a source); and how much of PCIe to set up (bus numbers and BARs assigned where
firmware didn't, rather than only what firmware did). For assigning on x86-64, whose real windows are in ACPI's _CRS,
which is AML: the memory map's gaps (rather than firmware's own ranges, or nothing until an ACPI service); and
firmware's work kept where it holds, only the gaps filled (rather than everything redone).

## Decision
As asked, built:
- **The firmware tables' copy** ends with a `RAM ` table of the kernel's own: a `slop_os.PhysicalRange` for each range
  of RAM it owns, at physical address 0, so the platform service knows what's taken.
- **`src/pci`** finds the host bridge in the copy: on x86-64 the MCFG's first allocation, with windows from the memory
  map's gaps (below 4 GiB, on each side of the ECAM, up to the I/O APICs at 0xFEC00000; and 64 GiB above RAM, the
  ECAM and 4 GiB); on AArch64 the device tree's `pci-host-ecam-generic`, its `reg`, `bus-range`, `ranges` (32- and
  64-bit memory) and `msi-map`. It reads and writes configuration space and finds capabilities.
- **The platform service** (`src/services/platform`), started by the root task through the manager with the platform
  capability, the copy and the command line, walks every bus depth first. A bridge without bus numbers gets the next
  free ones. Each memory BAR is sized by writing ones with decoding off, and kept if it's inside a window it may be in
  (its bridge's, or the host's, a 32-bit one never in a 64-bit window) and overlaps no other BAR, RAM, the ECAM or a
  window of a bridge it isn't behind; otherwise it's placed first-fit, aligned to its size. I/O BARs aren't placed.
  `test_reassign` on the command line takes every virtio device's BARs and every bridge's bus numbers as unset.
- **The `platform` protocol**: `Claim(DeviceMatch)` gives the next unclaimed match, never given again, as a
  `PciDevice`: its address, IDs and class, its Device, a window onto its configuration space, each BAR as device memory
  at its CPU address, and a DMA domain it's attached to; or `NoDevice`. The bundle is made when it's claimed.
- **Drivers** are services in `system_config` with `devices`, a `DeviceMatch` (all zeros for a service that isn't a
  driver). The supervisor, given a connection to the platform service and the entropy service and each driver's
  module, claims every device each driver takes and launches one driver per device with its bundle as the entry's
  parameters, then tells the root task `AllStarted` with how many it started. `test_services` ends a second after that.
- **`src/virtio`**: the modern virtio-pci transport, its common, notify, ISR and device configuration through its vendor
  capabilities, `VERSION_1` required, MSI-X with one vector per queue programmed into its table in a BAR, and split
  virtqueues of up to 16 descriptors in one page of DMA memory, laid out in `u16le`, `u32le` and `u64le`, with fences
  between filling a ring and telling the device.
- **`virtio_rng`** (`src/drivers/virtio_rng`) sets up its device's one queue and vector, offers itself to the entropy
  service with `AddSource` on a channel of the new `rng` protocol (`Read(count)`, answered with `Bytes`), and answers
  each Read by offering a buffer, waiting for its MSI, and sending what the device wrote.
- **The entropy service** reads 32 bytes from each source when it's added and again each time 64 KiB more have been
  handed out, and reseeds its stream with its own next 32 bytes XORed with the source's, so a source can add to what's
  unpredictable but not take from it.
- **Boot tests**: virtio-rng claimed, driven and reseeding the entropy service, on both architectures; and behind a PCIe
  root port with `test_reassign`, its bus numbered and its BARs placed in the port's window.
- `test_msi_dma` finds the ECAM and MSI sources through `src/pci`; the root task's command-line words moved to
  `service_kit`, for the platform service too.
- **Found on the way, fixed**: base's runtime knew no grant kinds for `Device` and `DmaDomain`, new in 7b, so an entry
  parameter of either ended the process with `EXIT_MISSING_GRANT`. And from the survey of Hemera's docs (`0047`):
  `match` and `switch` on strings, and `#union` struct literals, which couldn't be generated, now are; and a dynamic
  array of a `#scoped` struct anywhere, not only in a field, is an error, since its elements are on the heap.

## Alternatives considered
- **The platform service starting drivers**: simpler wiring, but restarts (7f) would be the platform service's, not the
  supervisor's, and it would hold every driver as well as all the hardware.
- **Drivers asking for their BARs**: more flexible, but every driver would depend on the platform service while it ran.
- **The entropy service waiting for a source**: hardware-seeded from the start, but the process manager, which needs
  entropy, would wait on the drivers.
- **Only firmware's assignment**: nothing to get wrong on QEMU, but a device firmware didn't place, or hot-plugged
  later, would be lost.
- **Firmware's ranges as x86-64's windows**: safe where firmware placed anything, no help where it didn't.

## Consequences
- A driver holds its device and nothing else; with no IOMMU yet it can still DMA anywhere (`0072`'s D confines it).
- Each driver's launch is written out in the supervisor, since `os.launch` is typed by the entry; one per device class.
- Bridges' own windows are kept as firmware set them: a device behind a bridge without a window, or without room in
  it, is logged and left unplaced, and so is an I/O BAR.
- x86-64's windows are a guess from the memory map until an ACPI service reads _CRS.
