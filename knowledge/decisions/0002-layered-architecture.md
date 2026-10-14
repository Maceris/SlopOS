# 0002: Layered Architecture With Two Hardware Boundaries

Status: accepted (2026-10-13)
Date: 2026-09-30, revised 2026-10-13

## Context
We want the lowest layer to standardize hardware and expose a common interface, and we
want a microkernel. These pull in different directions if "hardware" is treated as one
thing: CPU control must be privileged, device drivers should not be.

## Decision
Seven layers (L0 boot → L6 applications, detailed in `../design/layers.md`) with two
hardware abstraction boundaries:

1. **Arch interface** (L1 ↔ L2): a compile-time-selected Hemera package per architecture
   covering CPU, paging, interrupts, timers, context switching and syscall entry. Portable
   types only cross it.
2. **Device-class protocols** (L3 ↔ L4): typed IPC protocols (`block`, `net`, `display`,
   `input`, ...) implemented by user-space drivers. Nothing above L3 knows what hardware exists.

Revised 2026-10-13, after Hemera gained platform intrinsics, interrupt functions, freestanding
builds and the carrier block's `program_data`:
- **L0 is per boot protocol, not per architecture**, and owns the kernel's entry point. It turns
  the bootloader's handoff into `BootInfo`; L1 never sees bootloader structures.
- **Per-CPU state, time conversion and thread switching are not in the arch interface.** The
  kernel reaches its `PerCpu` portably through the carrier register
  (`intrinsics.carrier().program_data`); L1 only finds the carrier block at kernel entry.
- **Five interfaces, each with its own stability rules:** `BootInfo` and the arch interface
  (internal to the kernel image), the system ABI (stable, `0025`), and device-class and
  service protocols (versioned).
- L0–L2 build as the kernel target (`os = .None`, `Freestanding` and `Allocating` `std` tiers);
  L3–L6 as the user-space target (`os = .SlopOS`, every tier).

## Alternatives considered
- **Single in-kernel HAL** (Windows NT style): one boundary, but puts drivers back in the kernel.
- **Exokernel**: kernel only multiplexes raw hardware, libraries do everything else. Maximally
  flexible, but every application inherits hardware complexity and portability suffers.
- **No arch interface, `#if` scattered through the kernel**: fastest to start, worst to port.

## Consequences
- Porting = new L0 loader + new `arch/` package + a platform parser (ACPI vs devicetree).
- Each `arch/` package is checked against the `arch_interface` package by a house-rule check
  the build registers (`0029`).
- Kernel entry and return to user mode need code Hemera can't express yet outside x86-64 IDT
  entries (`../hemera-feedback.md`).
- Driver ↔ service traffic is IPC, so IPC performance matters from day one.
