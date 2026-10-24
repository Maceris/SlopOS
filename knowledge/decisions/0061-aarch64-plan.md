# 0061: The Plan for AArch64

Status: accepted
Date: 2026-10-23
Related: `0022` (target architectures), `0003` (x86-64-v3), `0020` (Limine), `0026` (the carrier register),
`../hemera-proposals/kernel-entry.md`, `../design/layers.md` (L1), `../../docs/specs/arch_interface.md`,
`../roadmap.md`

## Context
`0022` put AArch64 second, to start right after M3, while the arch interface is small enough to reshape
cheaply. It didn't start then: M4, M5 and half of M6 were built on x86-64 alone. SlopOS's kernel core reaches
the hardware only through the arch interface (`#if TARGET_ARCH == .x86_64` imports, nothing x86 called
directly), and its x86-64 layer is about 2,300 lines. The tools are there: QEMU's `virt` machine for AArch64
with edk2's UEFI firmware, and Limine's `BOOTAA64.EFI`.

Hemera's side is mostly unbuilt. Its AArch64 design is documented (the carrier register `x28`, fibers,
frame records), and its LLVM has the AArch64 backend, but no Hemera code has been generated for it yet: the
code generation pipeline is LLVM's new one, which only X86 implements here; the prologue stack check is a
Hemera patch to LLVM for X86 only, and LLVM has no segmented-stack prologue for AArch64 at all; `morestack`,
fiber switching, and entry and interrupt functions are x86-64 assembly; and `base/intrinsics` has nothing for
AArch64's system registers, barriers or TLB maintenance. RISC-V needs LLVM rebuilt with its backend first.

## Decision
Chosen with the project's owner:
- **AArch64 first**, as `0022` planned; RISC-V third, after LLVM is rebuilt with its backend.
- **Now, with M6 paused after 6b**, so the arch interface is reshaped before user space adds more to it (the
  startup block, the loader's relocations, system call registers), and M6's last two stages are built for
  both architectures.
- **The baseline is ARMv8.2-A with LSE atomics**, like x86-64-v3 for x86 (`0003`): what nearly every 64-bit ARM
  core of recent years has. Pointer authentication, BTI and `RNDR` are used where the CPU has them, found by
  feature checks.
- **Hemera's AArch64 output is tested hosted too**: its Linux tests run as AArch64 programs through
  user-mode QEMU on the Linux machine, as well as SlopOS booting in `qemu-system-aarch64`.

In five stages:
- **A1, Hemera on AArch64, hosted**: code generation through LLVM's legacy pipeline where the new one isn't
  there; the carrier register `x28`, reserved; the prologue stack check, as an LLVM patch for AArch64 (trap and
  `morestack`); `morestack`, fibers and stack traces in AArch64; Linux on AArch64 in `base` (its startup, system
  calls, threads); the baseline as default target features. Hemera's Linux tests run as AArch64 programs.
- **A2, Hemera for an AArch64 kernel**: entry functions (exceptions taken to EL1, the 2 KiB-aligned vector
  table, `eret` to EL0), system-register intrinsics (`mrs`, `msr`, with the register as a compile-time
  argument), barriers, TLB maintenance, `wfi`, `rndr`, in `base/intrinsics/aarch64`; a freestanding test.
- **A3, SlopOS boots on AArch64**: `arch_aarch64` behind the arch interface; Limine on QEMU `virt` through UEFI;
  the PL011 UART as the early console; exception vectors; the MMU (4 KiB pages, four levels, `TTBR0`/`TTBR1`,
  `MAIR`); the build package and `boot.py` taking an architecture; the first boot tests on AArch64.
- **A4, interrupts, time and SMP**: GICv3, the generic timer, starting the other CPUs, TLB shootdown (with
  AArch64's broadcast TLB invalidation), device interrupts and the kernel window.
- **A5, threads and user mode**: EL0 threads, `svc` system calls, FP and SIMD state, the scheduler, M5's
  objects and calls, and every boot test on both architectures. Then M6 resumes, for both.

## Alternatives considered
- **RISC-V first**: a cleaner ISA, with SBI for timers and starting CPUs, but LLVM needs rebuilding first, and
  its interrupt controllers (PLIC, AIA) and QEMU support move faster.
- **Both together**: the most work before either boots.
- **After M6**: user space would be written for one architecture and then ported.
- **ARMv8.0-A**: the widest reach, at the cost of load/store-exclusive loops for every atomic; **ARMv8.5-A**:
  PAC, BTI and `RNDR` assumed, leaving out much hardware still in use.
- **Testing only through QEMU boots**: the runtime, fibers and `morestack` would be tested only inside the kernel.

## Consequences
- Each stage gets an "as built" record, as M5's and M6's did; `design/arch-aarch64.md` is written with A3.
- The arch interface may change as the second implementation shows what's x86 in it; L2 follows.
- The Linux machine needs user-mode QEMU for AArch64 (`qemu-user-static` and `binfmt`), and Hemera's Linux tests
  take an architecture.
- `../hemera-proposals/kernel-entry.md`'s AArch64 half is A2; its RISC-V half waits for the third architecture.
