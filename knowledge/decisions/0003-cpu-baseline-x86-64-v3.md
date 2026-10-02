# 0003: Minimum CPU Level x86-64-v3

Status: accepted
Date: 2026-09-30

## Context
We need a minimum CPU feature level so the compiler can generate code without runtime
checks for common instructions, and so the kernel knows what it can rely on.

## Decision
The minimum supported CPU is **x86-64-v3**: everything in v2 (SSE4.2, POPCNT,
CMPXCHG16B, SSSE3) plus AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE and XSAVE.
User-space code is compiled for v3. The kernel is compiled for v3 with vector
registers disabled (see `../design/arch-x86-64.md`).

## Alternatives considered
- **x86-64-v2:** runs on older machines, but loses AVX2/BMI/FMA, which matter for
  string handling, hashing and Hemera's built-in vector and math types.
- **x86-64-v4 (AVX-512):** missing on many current consumer CPUs, and the larger
  vector state makes threads more expensive (`../design/threads.md`).

## Consequences
- Roughly: Intel Haswell (2013) and newer, AMD Excavator / Zen and newer. Some
  low-end Atom/Pentium/Celeron parts without AVX are excluded.
- QEMU must expose v3 features: use `-cpu host` with KVM/WHPX, or a model such as
  `-cpu Haswell`/`-cpu max` under software emulation.
- XSAVE is guaranteed, so context switching can always use it.
- `CMPXCHG16B` is guaranteed, so 128-bit compare-exchange is always available.
- The boot path should check `CPUID` and halt with a clear message on older CPUs.
