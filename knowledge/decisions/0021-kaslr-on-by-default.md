# 0021: KASLR On by Default, Disabled by a Boot Option

Status: accepted
Date: 2026-10-04

## Context
`0004` made the kernel a position-independent ELF so it can be loaded at a random address,
and left open when to turn randomization on.

## Decision
- **KASLR is on by default.**
  - Limine randomizes the base of the kernel image. KASLR is Limine's default for relocatable
    kernels.
  - The kernel randomizes the regions it lays out itself (object pools, per-CPU areas,
    stacks) using the boot entropy seed.
- **It can be turned off for kernel development and debugging** through a boot option in
  the boot configuration: Limine's `kaslr: no` for the image, plus a kernel command-line flag
  for the kernel's own regions. With it off, every address is the same on every boot.
- **Debugging stays workable when it's on:**
  - The kernel logs its load offset at boot.
  - Panic stack traces print addresses relative to the image base, so they can be
    symbolized without knowing the offset.

## Alternatives considered
- **Off by default, on for releases:** development would rarely run the configuration users
  get, so bugs that only show with randomization (stray absolute addresses, a missing
  relocation) would be found late.
- **Always on:** makes reproducing address-dependent kernel bugs needlessly hard.

## Consequences
- Every kernel address that crosses the user boundary is a security leak (pointers in
  errors, logs, debug info handed to user space). Kernel code must never hand out raw
  kernel addresses. This is a candidate house-rule check (`0007`): no `rawptr` or
  `ptr[...]` fields in syscall result types.
- KASLR doesn't defend against transient-execution attacks, which are out of scope (`0013`).
  It defends against ordinary memory-corruption exploits that need kernel addresses.
- The kernel needs its entropy seed (RDSEED, or Limine's) before laying out its regions,
  which ties into the early-boot context (`../hemera-feedback.md`, item 9).
