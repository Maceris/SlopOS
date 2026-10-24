# 0062: Hemera on AArch64, Hosted, as Built

Status: accepted
Date: 2026-10-23
Related: `0061` (the plan for AArch64), `0022` (target architectures), `0026` (the carrier register), `0047`
(compiler fixes), `../roadmap.md` A

## Context
AArch64's first stage (A1, `0061`): Hemera generating AArch64 code for Linux, with its runtime, fibers and
growing stacks, tested as AArch64 programs through user-mode QEMU on the Linux machine. Nothing new needed
choosing beyond `0061`'s choices, so this records what was built and what it found.

## Decision
As built, in Hemera:
- **Code generation** through LLVM's legacy pipeline for targets other than X86, after the same optimizations.
  The default target features are ARMv8.2-A with LSE (`+v8.2a,+lse`) when no CPU is given, and `x28`, the
  carrier register, is reserved (`+reserve-x28`).
- **The prologue stack check** as a third LLVM patch (`third-party/patches/llvm/0003`), with an `llc` test:
  `ldr x16, [x28]`, `sub x17, sp, #FRAME`, `cmp`, `b.ls`, then `brk #1`, or `morestack` with Hemera's protocol
  (a frame record, the sizes in `x9` and `x10`, the body in `x11`).
- **`morestack`, the fiber switches and the resume loop** in AArch64 assembly, the same algorithms as x86-64's.
  The loop re-enters frames with `bl` and stores its return address in each frame record; since nothing is
  pushed, the stack pointer stays at the fiber's saved state or the frame that just returned. A suspended
  fiber keeps 112 bytes on its stack, 176 with floating point. Stack walks read `x28` for running fibers.
- **Linux on AArch64 in `base` and `std/os`**: the generic system call table through `svc #0`, threads through
  `clone`, `_start` with and without the C library, and `fork`, `dup2`, `poll` and `renameat` replaced by
  `clone`, `dup3`, `ppoll` and `renameat2`. `base/intrinsics/aarch64` has `syscall` and `clone_thread`.
- **Foreign calls and callbacks** on AArch64, so programs that link C work, against a sysroot made from the
  Linux machine's `libc6-arm64-cross`.
- **Tests**: Hemera's Linux tests take `HEMERA_LINUX_ARCH=aarch64`; all 40 pass as AArch64 programs under
  `qemu-aarch64`, besides the two that run under Valgrind, which are x86-64's only. All 42 still pass on x86-64.
- **Found on the way, fixed (`0047`):** AArch64 shrink-wraps a function's prologue into the block that needs
  it, which put the stack check after the function's early returns and skipped the code before it (a fiber's
  yield lost its checks and suspended with the wrong argument). Functions with the check aren't shrink-wrapped
  now, as on X86. The `vectors` test scenario used x86-64's AES instructions on every target; they're x86-64's
  only now.

## Alternatives considered
None beyond `0061`'s: this stage only built what it chose.

## Consequences
- Pointer authentication, BTI and the Guarded Control Stack aren't used yet: the baseline doesn't have them,
  and the fiber switches will need the signing and the `GCSPOPM` loop that Hemera's calling convention
  describes when they are.
- A2 builds on this: entry functions, system-register intrinsics, barriers and TLB maintenance for an AArch64
  kernel, and a freestanding test.
