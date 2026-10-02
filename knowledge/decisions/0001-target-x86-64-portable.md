# 0001: Target x86-64 First, Stay Portable

Status: accepted
Date: 2026-09-30

## Context
We need one concrete architecture to make progress, but the project is also meant to
show how Hemera scales, and portability is a large part of that.

## Decision
- x86-64 is the first and, for now, only supported architecture.
- Development happens on QEMU (`q35`, OVMF/UEFI, virtio devices) before real hardware.
- All architecture-specific code is confined to the boot layer (L0), the arch layer (L1),
  and platform discovery/drivers in L3 (see `../design/layers.md`).
- On-disk and wire formats use explicit-endian types.

## Alternatives considered
- **AArch64 or RISC-V first:** cleaner ISAs, but less familiar tooling and hardware is
  less likely to be at hand.
- **Multiple architectures from day one:** keeps us honest, but doubles the early work
  before anything boots. A second arch is a later milestone instead.

## Consequences
- The arch interface will be shaped by x86-64 first; we must deliberately keep x86
  concepts (port I/O, segmentation, APIC) out of its types.
- Using virtio and Limine keeps the door open: both work the same on AArch64 and RISC-V.
- Hemera's `base/compiler/target.hsc` needs at least a freestanding OS value; `riscv64`
  is missing from its `Architecture` enum if we go there later.
