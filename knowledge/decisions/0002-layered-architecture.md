# 0002: Layered Architecture With Two Hardware Boundaries

Status: proposed
Date: 2026-09-30

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

## Alternatives considered
- **Single in-kernel HAL** (Windows NT style): one boundary, but puts drivers back in the kernel.
- **Exokernel**: kernel only multiplexes raw hardware, libraries do everything else. Maximally
  flexible, but every application inherits hardware complexity and portability suffers.
- **No arch interface, `#if` scattered through the kernel**: fastest to start, worst to port.

## Consequences
- Porting = new L0 loader + new `arch/` package + a platform parser (ACPI vs devicetree).
- Needs a way to check that each `arch/` package implements the full interface (open
  Hemera question).
- Driver ↔ service traffic is IPC, so IPC performance matters from day one.
