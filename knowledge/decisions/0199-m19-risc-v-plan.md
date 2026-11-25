# 0199: M19, RISC-V, Planned

Status: accepted
Date: 2026-11-24
Related: `0022` (RISC-V third), `0061` (A's plan, the pattern), `0135` (SlopOS's bootloader), `0026` (the carrier
register), `0081` (VT-d), `0197` (RISC-V chosen next), `../hemera-proposals/kernel-entry.md`, `../roadmap.md`
M19

## Context
`0022` made RISC-V the third architecture, and `0197` made it M19, planned with the owner on A's pattern once the
bounds checker was built. The system is much bigger than when A was planned. Back then the x86-64 layer was 2,300
lines with M6 half built. Now the AArch64 layer is about 4,700 lines, 53 files outside it name AArch64, and there are
user space, drivers, the IOMMU, shadow stacks, graphics and audio.

What's there:
- **QEMU 11.1** has RISC-V's `virt` machine, edk2's RISC-V firmware (over OpenSBI), the AIA (APLIC and IMSIC) as well
  as the PLIC, the RISC-V IOMMU (`riscv-iommu-pci`, and a platform one), virtio-gpu and virtio-sound. Its CPUs take
  Sv48, Sv57, Sstc, Svpbmt, Zkr, Zicfilp, and Zicfiss with Zimop.
- **Hemera's LLVM (24)** has the RISC-V backend, which lowers both CFI extensions. It isn't built: only X86, AArch64
  and ARM are.
- **The Linux machine** has `qemu-riscv64` user mode with binfmt already.
- **Limine** has `BOOTRISCV64.EFI`.

What isn't:
- **No Hemera code is generated for RISC-V yet.** Its `Architecture` enum names `riscv64` and nothing more.
- **The prologue stack check** is a Hemera patch to LLVM for X86 and AArch64 only.
- **`morestack`, fibers, and entry and interrupt functions** are assembly for the other two.
- **SlopOS's bootloader** (`0135`) is a UEFI program, a PE file, which Hemera links with lld. LLVM has no RISC-V COFF
  writer and lld no RISC-V PE, so it can't be built for RISC-V as it is for the others.

## Decision
Chosen with the owner (2026-11-24):
- **The baseline is RVA23** (RVA23U64 and RVA23S64), like x86-64-v3 and ARMv8.2-A with LSE: vectors, Zicond, Sstc's
  S-mode timer, Svpbmt and Zimop are assumed. Shadow stacks (Zicfiss) and landing pads (Zicfilp) are optional in it,
  so they're used where the CPU has them, found by feature checks, as PAC and BTI are.
- **Hemera writes the UEFI program's PE itself.** lld links a position-independent ELF whose only relocations are
  relative, and Hemera turns it into a PE32+ EFI application, its relocations as base relocations, as edk2's GenFw
  does. The bootloader is then the same on all three architectures, generations and randomization included.
- **Both interrupt controllers, the AIA and the PLIC.** The AIA takes interrupts as messages, as GICv3's ITS does, and
  the IOMMU remaps them. The PLIC is what most boards shipped so far have. Each is a configuration of QEMU's `virt`
  that's tested.
- **The IOMMU and CFI are M19's last stage**, so RISC-V matches the other two before M20.

In seven stages:
- **R1, Hemera on RISC-V, hosted.**
  - LLVM rebuilt with the RISC-V backend.
  - The carrier register, a callee-saved one reserved, chosen and documented in R1.
  - The prologue stack check, as an LLVM patch for RISC-V (a trap and `morestack`, as for AArch64).
  - `morestack`, fibers and stack traces in RISC-V assembly.
  - Linux on riscv64 in `base`: its startup, system calls and threads.
  - RVA23U64 as the default target features.
  - Hemera's Linux tests run as riscv64 programs through user-mode QEMU, a third architecture in `linux_tests.py`.
- **R2, Hemera for a RISC-V kernel.**
  - Trap entry functions: `stvec` direct, the trap frame, `sret` to U-mode.
  - CSR intrinsics, the CSR a compile-time argument (`csrr`, `csrw`, `csrrs`, `csrrc`).
  - Fences, `sfence.vma`, `wfi`, and `ecall` to SBI, in `base/intrinsics/riscv64`.
  - The ELF-to-PE writer, with UEFI on riscv64 in `base`.
  - A freestanding test, and a UEFI program built and run under edk2.
- **R3, SlopOS boots on RISC-V.**
  - `arch_riscv64` behind the arch interface.
  - SlopOS's bootloader on QEMU `virt` through edk2 and OpenSBI.
  - The 16550 UART, found in the device tree, as the early console.
  - Traps, and Sv48 paging with Svpbmt's memory types.
  - The build package and `boot.py` taking `riscv64`, and the first boot tests.
- **R4, interrupts, time and SMP.**
  - The AIA (APLIC and IMSIC) and the PLIC, each found in the device tree, each boot-tested.
  - Sstc's `stimecmp` as the timer.
  - The other harts started through SBI's HSM.
  - IPIs through the IMSIC, or SBI's on a PLIC machine.
  - TLB shootdown by IPI and `sfence.vma`, since RISC-V has no broadcast invalidation.
  - Device interrupts and the kernel window.
- **R5, threads and user mode.**
  - U-mode threads and `ecall` system calls.
  - FP and vector state, saved as the other two save theirs.
  - The scheduler and M5's objects.
  - virtio over PCI (ECAM, from the device tree).
  - Every boot test that applies, on all three architectures.
- **R6, the IOMMU and CFI.**
  - The RISC-V IOMMU's DMA and MSI remapping, as `0081` did for VT-d and D did for SMMUv3.
  - Zicfiss shadow stacks for user and kernel, enabled through SBI.
  - Zicfilp landing pads in Hemera's code.
  - Boot tests that each catches what it should, testable under TCG.
- **R7, a review**, as M16 to M18 had.

## Alternatives considered
- **RVA22**: reaches more of the boards sold so far. Without assured vectors or Sstc, the kernel needs SBI's timer
  as a fallback, and CFI can't count on Zimop.
- **Limine on RISC-V**: works already, but RISC-V would boot differently from the others, without generations or
  randomization until the bootloader was ported.
- **Booting through OpenSBI alone** (QEMU's `-kernel`, no UEFI): the simplest start, but nothing like how the other
  two boot, nor real RVA23 boards with UEFI.
- **The AIA only**: one interrupt driver and one QEMU configuration, but most boards shipped so far couldn't run it.
- **The IOMMU and CFI later**: M19 ends sooner, and RISC-V trails the other two in what they guard against.

## Consequences
- Each stage gets an "as built"; `design/arch-riscv64.md` is written with R3.
- LLVM's build grows by its RISC-V backend. The next LLVM build takes longer, and so does every one after.
- The arch interface may change again where it still assumes x86 or ARM: interrupts that are messages only, a
  broadcast TLB invalidation.
- The device tree package reads RISC-V's nodes: harts, the AIA, the PLIC, the 16550.
- `../hemera-proposals/kernel-entry.md`'s RISC-V half is R2.
- The boot tests run three times over. A full run is about half as long again.
