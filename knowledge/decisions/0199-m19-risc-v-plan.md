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

## As Built: R1 (2026-11-25)
- **LLVM** builds its RISC-V backend. Three patches of Hemera's: the prologue stack check (0007, a trap or `morestack`),
  quoted symbols in RISC-V assembly's `call` and `la` (0008), and a fix for instruction selection looping forever on
  an AND mask with Zba or Zbs (0009), found compiling `std/ntp`.
- **The carrier register is `s11`.** RVA23U64's features are the default, with the LP64D ABI.
- **`morestack`, fibers and stack traces** are RISC-V assembly. A suspended fiber keeps 112 bytes, or 224 with
  floating point. Assembly in the module that uses D or V turns them on itself, since LLVM reads module assembly with
  no features.
- **Linux on riscv64 in `base` and `std/os`:** startup, the generic system call table, threads through `clone`, and
  linking C (LP64D's foreign calls, `ld-linux-riscv64-lp64d.so.1`). The thread carrier is local-exec thread-local
  storage in an executable, since RISC-V's linker doesn't relax general-dynamic as the others' do.
- **Tests:** Hemera's Linux tests run as riscv64 programs through user-mode QEMU on the Linux VM, 83 of 83, `libc`
  against a sysroot from Debian's `libc6-riscv64-cross`.

## As Built: R2 (2026-11-25)
- **Trap entry:** `#calling_convention(.entry)` on RISC-V is what `stvec` points at, in direct mode. `sscratch` is the
  hart's `riscv64.TrapScratch` in U-mode and 0 in S-mode; the entry swaps it with `tp`, so a trap from U-mode runs on
  `TrapScratch.kernel_stack` with `tp` pointing at the `TrapScratch`. A trap from S-mode builds its frame on the stack
  it was on. `riscv64.RegisterFrame` is `x0`–`x31`, `sepc`, `sstatus`, `scause` and `stval`, 288 bytes. The entry
  clears `SUM`. `return_to_user(frame, scratch)` sets `sscratch` and returns with `sret`. So SlopOS's per-hart data
  can start with its `TrapScratch`, and `tp` finds it.
- **`base/intrinsics/riscv64`:**
  - `csrr`, `csrw`, `csrrw`, `csrrs` and `csrrc`, the CSR a compile-time `riscv64.Csr`;
  - `fence` with its access kinds as compile-time arguments, `fence_i`, and `sfence_vma` in four forms;
  - `wfi`, `pause`, `ebreak` and `seed`;
  - `read_tp` and `write_tp`;
  - `sbi_call`, `enter` for the bootloader, `semihosting`, and `system_call` answering in a0–a2;
  - `sstatus`'s bits and `scause`'s codes as constants.
- **The ELF-to-PE writer:** a RISC-V UEFI application is linked by `ld.lld` as a position-independent ELF, each
  segment on pages of its own from 0x1000. Hemera makes the PE32+ image from it: a section per segment, with the
  segment's protection; base 0; relative relocations as DIR64 base relocations. edk2 applies each section's
  protection. Debug info isn't kept, so a bootloader's stack traces can't be symbolized yet.
- **A kernel's features** are `-f,-d,-zve32x,-zvl32b`, which takes out every vector extension RVA23 implies. Without
  D or F the ABI is LP64. A kernel above 2 GiB needs `--code-model=medium` (`medany`).
- **Tests:**
  - Hemera's `freestanding_tests.py` boots a RISC-V kernel under OpenSBI on QEMU's `virt` (`rva23s64`). It turns on
    Sv39, takes an S-mode breakpoint, runs three U-mode `ecall`s (returned by `sret` and through `return_to_user`),
    reads a U page with `SUM` set, calls the SBI, and ends at the stack check's trap.
  - Every function in `base` and `std` generates for that target.
  - A UEFI application runs under edk2 (`edk2-riscv-code.fd`), finds its image base, and turns the machine off.
  - HemeraTest reads the image back as a PE.

## As Built: R3 (2026-11-25)
- **`src/arch/riscv64`** (`../design/arch-riscv64.md`; the arch interface spec has its table): features from the
  device tree and RVA23's baseline, `init_system` and `init_cpu`, one `.entry` function in `stvec`, Sv48 paging with
  Svpbmt's memory types, the device tree's 16550 as the early console, the SBI's system reset, semihosting for
  `test_exit`, and Zkr's `seed` for entropy. What R4 to R6 bring is listed in `NOT_YET_IMPLEMENTED`, 47 stubs that stop
  the hart, and `TAKES_INTERRUPTS` is back, as A3 had it: false on RISC-V, so the kernel stops once its own address
  space, heap and console are up, after the tests that need only those. `src/iommu/riscv` drives no IOMMU kind until
  R6, so the platform service's registration of one fails.
- **The arch interface's one change: `detect_features` takes the firmware's tables.** Supervisor mode can't read
  `misa` or probe an extension, so a hart's features are the device tree's (`riscv,isa-extensions` or `riscv,isa`, and
  `mmu-type`). x86-64 and AArch64 ignore them. RISC-V's `CpuFeature`s are 128 to 191 in `std/os/slop_os`.
- **Exceptions in the kernel run on the DoubleFault critical stack.** A trap's frame goes on the stack it came from, so
  the stack check's `ebreak` on a full stack would trap again in the handler. The entry instead rewrites the frame and
  returns, its `sret` landing in `kernel_trap` on the critical stack; the interrupted `s0` and `ra` stay, so the stack
  trace goes through the faulting code. Each stack's limit leaves room below it for the 288-byte frame as well as the
  guard. The kernel never faults on purpose, as it reaches user memory through the direct map.
- **Paging:** one root for both halves, the kernel half shared by copying its 256 top-level entries, as on x86-64. A
  non-leaf entry has no spare bits, so `unmap` looks for a second valid entry rather than keeping a count. A and D are
  always set (Svade); `take_accessed` is false. `map` fences each new entry on the calling hart.
- **The bootloader on RISC-V:** `BOOTRISCV64.EFI`, built without vector extensions, which edk2 leaves off; Sv48 tables
  for the identity map and the direct map; `riscv64.enter`; the boot hart alone, by `RISCV_EFI_BOOT_PROTOCOL`'s ID (in
  `std/os/uefi`), until R4 starts the others; and it refuses a device tree whose `mmu-type` has no Sv48.
- **Found on the way:** edk2 installs the device tree's configuration table in its pool, whose memory its own
  allocations reuse while the bootloader reads files, so the tree was zeros by the time it was read. The bootloader
  now copies the tree into its own pages before anything else, on every architecture.
- **Sv48 isn't in RVA23S64**, which mandates only Sv39, and QEMU's `rva23s64` has only Sv39. The baseline keeps Sv48,
  decided with this plan; the tests run `rva23s64,sv48=on,zkr=on`, Zkr being optional in RVA23 too, and needed for the
  kernel window's randomness.
- **`boot.py --arch riscv64`** boots on `virt` through edk2 (`edk2-riscv-code.fd`, a copy of the variables), the
  kernel alone, as RISC-V has no user space yet; `boot_tests.py` builds the RISC-V kernel and bootloader and runs 8
  tests: boots and stops before interrupts; a kernel fault; a failed assertion; read-only code; the heap; a CPU without
  V refused by the kernel's check; and KASLR on and off. The bootloader's refusal of a CPU without Sv48 was checked by
  hand: the firmware then goes on to its next boot option, so a test could only wait out its timeout.
- **Left for R4:** another hart may fault on a kernel mapping just made, before Svvptc's bounded time; R4 retries such
  a fault rather than stopping.

## As Built: R4 (2026-11-25)
- **Both controllers, found in the device tree:** the AIA where there's an IMSIC with supervisor files (`riscv,imsics`
  taking external interrupt 9) and the APLIC whose `msi-parent` it is; else a PLIC. Each hart is found by its interrupt
  controller's cpu node (the device tree package's new `parent_reg_of`).
  - **With the AIA every interrupt is a message**, as on x86-64: the kernel's device interrupt IDs are each hart's IMSIC
    identities (16 up), claimed through `stopei`; MSIs are the hart's file and the ID, with nothing kept per device; the
    APLIC delivers its lines by message, its target the hart's IMSIC index and the ID; and IPIs are identities 1 to 3
    written to the target's file.
  - **With the PLIC** the IDs are the kernel's own (32 to 255), routed from lines as AArch64 routes SPIs; the claimed
    line is completed at `end_of_interrupt`; there are no MSIs; and IPIs are the SBI's `sbi_send_ipi`, their kinds kept
    in the target's `ArchCpu`, each taken as an interrupt of its own.
- **The arch interface's one change: `init_cpu` takes the CPU's hardware ID.** Supervisor mode can't read its hart's
  ID, which the PLIC's contexts and the IMSIC's files are by. x86-64 and AArch64 read theirs and ignore it.
- **Timer:** Sstc's `stimecmp`, at `/cpus`' `timebase-frequency`.
- **Idle:** `sstatus.SIE` and `wfi`. An interrupt in supervisor mode only comes while idle, and its entry, like an
  exception's, rewrites the frame and returns, its `sret` landing in `idle_interrupt` on the kernel stack's top, as an
  entry from idle starts on x86-64's IST.
- **The other harts:** the bootloader starts every cpu node's hart by the SBI's HSM at a trampoline, which loads
  `satp`, takes its stack, clears `tp` and waits on its mailbox, as the other two park their CPUs.
- **Stale page faults** (R3's leftover): a kernel page fault on an address the tables now allow is fenced and retried,
  as another hart may have made the mapping after this one walked it. The check runs in the entry, before there's a
  context.
- **The test device:** with the AIA, the APLIC's last source, pended through `setipnum`; with the PLIC, which can't pend
  a line in software, the UART's transmitter interrupt, armed at each tick and taken back at `end_of_interrupt`.
- **Tests:** `boot.py --aia` boots `virt,aia=aplic-imsic`. `boot_tests.py` runs 21 RISC-V tests: on the PLIC and again
  on the AIA, booting and halting with boot memory reclaimed, every hart started (4), the clock, idle harts' ticks
  stopping, TLB shootdown, a binding slot read while it's remade, an object's ownership raced, and the test device's
  interrupts routed through the wired controller; and R3's five (a kernel fault, a failed assertion, read-only code, the
  heap, a CPU without V) once.
- **Left for R5:** device interrupts reach drivers through user space, so MSIs and wired lines from real devices are
  first used there; and the stale-fault retry for user pages, which return through `return_to_user`.
