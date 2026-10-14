# 0031: The Shape of BootInfo

Status: proposed
Date: 2026-10-13
Related: `0002` (layers, L0 per boot protocol), `0012` (root task), `0020` (Limine), `0021` (KASLR)

## Context
`0002` makes L0 a boot adapter, per boot protocol, that turns the bootloader's handoff into a
portable `BootInfo` for the kernel core. The spec is `../../docs/specs/boot_info.md`. Drafting it
raised choices the protocol itself doesn't settle: where L0 puts converted data with no
allocator, how the kernel starts other CPUs without knowing the bootloader, how the root task
is found, and which addresses are physical.

## Decision
- **Portable kinds of memory, chosen by what the kernel does with them**, not by what the
  firmware called them: `Usable`, `BootReclaimable`, `KernelImage`, `BootModule`,
  `Framebuffer`, `FirmwareTables`, `FirmwareReserved`, `Reserved`, `Defective`. The map is
  sorted, non-overlapping and page-aligned, and physical page 0 is never usable.
- **L0 builds `BootInfo` without an allocator.** Strings point into the bootloader's responses.
  Arrays are carved from a usable region that L0 then lists as `BootReclaimable`, so everything
  `BootInfo` points to has one lifetime rule.
- **Physical addresses for everything that outlives boot** (memory, the kernel image, module
  contents, framebuffers, firmware tables), as a `distinct` `PhysicalAddress`. Virtual addresses,
  valid only in the bootloader's mapping, for `BootInfo`'s own data.
- **CPUs are started through a function pointer L0 supplies** (`start_cpu`). The kernel passes
  the CPU's carrier block and an entry function; L0's secondary entry sets the carrier up for its
  boot stack and calls the entry. The kernel core never sees how the bootloader parks CPUs, and a
  later L0 can start them through firmware instead.
- **The boot CPU is `cpus[0]`, and the root task is `modules[0]`.** Positions, not names or flags.
- **Optional values are optional types:** the bootloader's entropy, the counter frequency, and
  the wall-clock time at boot. Bootloader entropy is only ever mixed in, never relied on.
- **No version field.** L0 and L2 are compiled together (`0002`).

## Alternatives considered
- **Fixed-capacity arrays inside `BootInfo`:** no carving, but a fixed limit on memory-map
  entries and CPUs, and a large struct on a 64 KiB boot stack.
- **Pass Limine's arrays through as views:** no copying, but Limine's memory map is an array of
  pointers to entries, and its types would leak into L2, which `0002` rules out.
- **The kernel starts CPUs itself** (INIT-SIPI, PSCI, SBI HSM): needed eventually without
  Limine, but duplicates what the bootloader already did, and needs ACPI or devicetree parsing
  in the kernel.
- **Find the root task by name:** one more convention to keep in sync between the boot
  configuration and the kernel. Position is what Limine's configuration already orders.

## Consequences
- The kernel must finish reading `BootInfo` before it drops the bootloader's direct map, and
  can reclaim boot memory only once every CPU has left its boot stack. Leaving the boot stack
  needs a stack switch, which is part of the kernel-entry gap (`../hemera-feedback.md`).
- The firmware tables reach user space (the platform service) as memory objects; the kernel
  parses none of them.
- `boot/limine` declares its requests with Hemera's `#externally_initialized` and `#section`
  (`../hemera-proposals/externally-initialized-data.md`, adopted 2026-10-13).
