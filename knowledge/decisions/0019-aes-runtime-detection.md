# 0019: AES Instructions Detected at Boot, With a Software Fallback

Status: accepted
Date: 2026-10-04

## Context
Per-user encryption at rest (`0016`) puts symmetric encryption on the storage path, and
`0013` keeps it in scope partly because it's cheap on CPUs with AES instructions. The x86-64
baseline (`0003`) is x86-64-v3, which doesn't formally include AES-NI or PCLMULQDQ, although
in practice almost every CPU with AVX2 has both. Other planned architectures (`0022`) make
the instructions optional as well: the ARMv8 Cryptography Extension and the RISC-V
scalar/vector crypto extensions are all optional.

## Decision
- **AES instructions aren't part of the CPU baseline.** `0003` stays unchanged.
- **The kernel detects CPU features once at boot** and reports them to user space as a
  portable `CpuFeatures` value in the startup grants (`0009`). On x86-64 it reads `CPUID`;
  on AArch64 the ID registers, which aren't readable from user mode. Programs don't
  probe the hardware themselves.
- **Crypto code picks its implementation at startup** from `CpuFeatures`: AES-NI +
  PCLMULQDQ (and VAES where present) on x86-64, the Cryptography Extension on AArch64, the
  crypto extensions on RISC-V, otherwise a portable software implementation.
- **The software fallback is constant-time** (bitsliced AES, no lookup tables indexed by
  secret data). Timing channels are out of scope (`0013`), but table-based AES is a
  textbook cache-timing leak of key material between users, and the bitsliced version is
  only moderately slower.
- **A volume's cipher is recorded in its header**, so a volume can use a cipher that is fast
  without AES instructions (for example Adiantum, as Android uses on low-end CPUs). Every
  supported cipher has a software implementation on every architecture, so a disk moved to
  another machine stays readable there, if more slowly. The default cipher and mode are
  chosen when the storage service is designed.

## Alternatives considered
- **Require AES-NI in the x86-64 baseline:** excludes few real machines, but QEMU's
  software CPU models must expose it, and it doesn't carry over to the other architectures,
  where the extensions really are optional.
- **Each program runs `CPUID` itself:** works on x86 but not on AArch64, and `CPUID` is one
  of the hardware side doors `0009` asks programs to avoid.

## Consequences
- The storage service (in user space) owns the choice of cipher. The kernel only reports
  features.
- On CPUs without AES instructions, encrypted storage costs noticeably more CPU. Accepted.
- `CpuFeatures` is a portable type and is also where AVX-512 support is reported for the
  per-process opt-in (`0023`).
