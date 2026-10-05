# 0022: Target Architectures: x86-64 First, Then AArch64 and RISC-V, 64-Bit Only

Status: accepted (order and timing of the later architectures: proposed)
Date: 2026-10-04 (revised the same day: "ARM" meant AArch64; 64-bit only)

## Context
`0001` made x86-64 the first and only architecture for now, and left the second open. The
project's goal is to show how Hemera scales, and supporting several architectures is a large
part of that: it tests the arch interface (`../design/layers.md` L1), the compile-time
`TARGET_ARCH` branching and the compiler backend.

## Decision
- **Targets:** x86-64, AArch64 and RISC-V (riscv64). **64-bit only**, no 32-bit
  architectures. x86-64 is still first (`0001` unchanged).
- **Proposed order:** AArch64 second (QEMU `virt`, Limine support, common real hardware),
  RISC-V third.
- **Proposed timing:** start AArch64 right after M3 (interrupts, time and SMP work on x86-64),
  not after userland. At that point the arch interface is complete but small, so a second
  implementation can still reshape it cheaply. The longer x86-64 is the only implementation,
  the more x86 assumptions settle into L2.
- **Every target uses Limine and virtio under QEMU first** (`0020`, `../design/layers.md` L3),
  so drivers and the boot path carry over unchanged.

## Alternatives considered
- **Second architecture after userland (M9), as the roadmap had it:** less early work, but
  the arch interface would be validated only after a lot of code depends on it.
- **RISC-V second:** a cleaner ISA, but its hypervisor, IOMMU and interrupt-controller
  (AIA) specs are younger and QEMU/firmware support moves faster.
- **32-bit ARM as well:** rejected. A 32-bit address space can't hold a direct map of all
  physical memory, gives ASLR little entropy, and needs special handling for 64-bit atomics.

## Consequences
- **The kernel may assume a 64-bit address space everywhere:** a direct map of all physical
  memory, 64-bit atomics, pointer-sized `u64`. Every arch interface type can rely on it.
- Hemera's `Architecture` enum needs `riscv64` (already in `../hemera-feedback.md`).
- Per-architecture notes like `../design/arch-x86-64.md` are needed for each target.
- Features that exist on only some architectures (port I/O, AES instructions, AVX-512) stay
  behind portable types (`CpuFeatures`, `0019`) or in L1 and L3.
