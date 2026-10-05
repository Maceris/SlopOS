# 0020: Limine as the First Bootloader; a Hemera UEFI Loader Is an Optional Extension

Status: accepted
Date: 2026-10-04

## Context
L0 has to get the CPU into long mode, load the kernel and boot modules, and hand over a
memory map (`../design/layers.md`). Writing that first would delay everything else.
`design/layers.md` proposed Limine for now and a Hemera UEFI loader later.

## Decision
- **SlopOS boots through the Limine boot protocol.** Limine is treated like firmware
  (CLAUDE.md, hard rule 6): it isn't linked into SlopOS, and no SlopOS code depends on its
  internals beyond the documented protocol.
- **Limine's structures stop at the arch entry point.** `arch/x86_64` converts Limine's
  responses into the portable `BootInfo`, and nothing past that point sees Limine types.
  Limine also supports AArch64 and RISC-V, so this holds for the other architectures
  (`0022`).
- **A Hemera UEFI loader is an optional later extension**, valued as a compiler test (COFF
  output, `OS == .UEFI`). It must produce the same `BootInfo` and boot modules, so the kernel
  can't tell which loader started it.

## Alternatives considered
- **Our own UEFI loader first:** a good language test, but it delays the first kernel by a
  milestone and duplicates what Limine does well.
- **Multiboot2 / GRUB:** starts in 32-bit protected mode on x86, so the kernel would need its
  own long-mode setup, and it doesn't cover the other architectures.

## Consequences
- The project depends on the Limine protocol's continued compatibility. Its revisions are
  versioned, so the `BootInfo` conversion can check them.
- KASLR is provided by Limine for the kernel image (`0021`).
- A loader written in Hemera needs `OperatingSystem.UEFI` on the Hemera side
  (`../hemera-feedback.md`, "Target enums").
