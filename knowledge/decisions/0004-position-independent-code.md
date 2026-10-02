# 0004: Position-Independent Code Everywhere

Status: accepted
Date: 2026-09-30

## Context
Hemera's backend generates position-independent code by default. We want address-space
layout randomization (ASLR), at least for user space.

## Decision
- All SlopOS code, kernel included, is compiled as position-independent.
- User programs and libraries are position-independent executables / shared objects,
  loaded at randomized addresses by the program loader.
- The kernel is a PIE ELF. Limine can relocate it (and randomize its base, i.e. KASLR)
  when loading it. Whether KASLR is turned on is a separate, later choice.

## Alternatives considered
- **Kernel at a fixed address with the `kernel` code model:** slightly smaller and faster
  code, but no KASLR, and a second code-generation mode to support in the compiler.

## Consequences
- No need for a `kernel` code model in Hemera; the existing PIC setting is what we want.
- The program loader must process relocations (or programs must be fully RIP-relative).
- Content-addressed shared libraries (`../problems-and-directions.md` §5) need to be PIC
  anyway, so this keeps one code-generation mode for everything.
- Randomization needs an entropy source early in boot (RDRAND is available on v3-era CPUs,
  though not formally part of v3; Limine also provides randomization itself).
