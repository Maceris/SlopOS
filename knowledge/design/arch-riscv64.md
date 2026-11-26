# Arch Notes: RISC-V

What L0 and L1 (see `layers.md`) need to deal with on 64-bit RISC-V, as `arch-x86-64.md` does for x86-64. The plan is
`../decisions/0199` (M19); this note says what's built (R3) and what each later stage adds.

## Target Environment

- **Development target:** QEMU's `virt` machine with the device tree (`acpi=off`), edk2's RISC-V firmware over
  OpenSBI, virtio devices. `tools/boot.py --arch riscv64`.
- **CPU baseline:** RVA23 (RVA23U64 and RVA23S64), as the kernel and programs are built for it, and **Sv48**, which
  RVA23S64 leaves optional: QEMU's `rva23s64` model has only Sv39, so the tests run `rva23s64,sv48=on,zkr=on`. The
  kernel checks the extensions the code uses (M, A, F, D, C, V, Zba, Zbb, Zbs, Zicond, Zcb, Zfa, Zfhmin, Zicboz,
  Zihintpause, Zawrs, Zimop, Zkt), Sv48, Svpbmt and Sstc, and stops with `CpuUnsupported` without one. The bootloader
  refuses a device tree whose `mmu-type` has no Sv48 itself, since a `satp` write of an unsupported mode does nothing.
- **Where the features come from:** supervisor mode can't read `misa` or probe an extension, so they're the device
  tree's: the first cpu node's `riscv,isa-extensions` (or `riscv,isa`) and `mmu-type`, every hart being alike. That's
  why `arch_interface.detect_features` takes the firmware's tables.
- **Use if present:** Zkr's `seed` (`hardware_entropy`; OpenSBI lets supervisor mode read it where the hart has it),
  Zicfilp and Zicfiss (R6), the AIA (R4), the RISC-V IOMMU (R6).
- **Transient execution:** nothing in the ISA says which issues a hart has, so Spectre v1 and v2 are assumed, and
  nothing is turned on but `sstatus.SUM` kept clear.

## Boot Path

- **SlopOS's bootloader** as `BOOTRISCV64.EFI`, a PE that Hemera makes from an ELF (Hemera's UEFI-on-RISC-V linking,
  `../decisions/0199`, R2). It's built without the vector extensions, which edk2 leaves off (`sstatus.VS`).
- **The device tree is copied first.** edk2 installs its configuration table in its pool's memory, which its own
  allocations then reuse while the bootloader reads files, so the bootloader copies the blob into loader-data pages
  before anything else and hands the kernel the copy.
- **The boot hart's ID** is `RISCV_EFI_BOOT_PROTOCOL`'s, which every RISC-V UEFI firmware gives.
- **Tables:** Sv48, one root for the identity map and the direct map, every page R, W, X, A and D, of the memory type
  the physical memory attributes give (RAM's); devices aren't mapped, as on AArch64. `riscv64.enter` sets `satp`,
  flushes, and jumps to the kernel with the handoff in `a0`, after `fence.i` for the kernel's code and with interrupts
  off (`sstatus.SIE`, `sie`).
- **Only the boot hart** is in the handoff until R4 starts the others through the SBI's HSM; they stay stopped in
  OpenSBI.
- The panic record's page is at `0x80400000`, past OpenSBI's 2 MiB at the start of RAM.

## What `arch/riscv64` Implements

- **Per-hart state:** `tp` is the `ArchCpu` in the kernel; in user mode `sscratch` is, so a trap swaps them (Hemera's
  `riscv64.TrapScratch`, which the `ArchCpu` starts with). Before `init_cpu`, `tp` holds the early console's word,
  which is odd, so the two are told apart.
- **Traps:** one `.entry` function in `stvec`, direct mode. From user mode the frame is on the kernel stack's top.
  From the kernel it's on whatever stack the kernel was on, which may be the one the stack check (`ebreak`) found
  full, so the entry only rewrites the frame and returns: its `sret` lands in `kernel_trap` on the hart's DoubleFault
  critical stack, which reports the fault. Every stack's limit leaves room for a frame (288 bytes) below it as well as
  the guard. The kernel never faults on purpose (it reaches user memory through the direct map), so every kernel
  exception is fatal.
- **Paging:** Sv48 with Svpbmt (`WriteBack` PMA, `WriteCombining` NC, `Device` IO); the kernel half shared by copying
  its 256 top-level entries, as on x86-64. Non-leaf entries have no spare bits for a count, so `unmap` scans for a
  second valid entry. A and D are always set (Svade); `take_accessed` gives false. `map` fences each new entry on the
  calling hart, since a hart may keep an invalid entry it walked.
- **Console:** the device tree's 16550, mapped through the direct map as an I/O page, as AArch64 maps its PL011.
- **Reset and power:** the SBI's SRST. `test_exit` is semihosting, as on AArch64.

## Later Stages

- **R4:** the AIA and the PLIC, Sstc's `stimecmp`, the other harts through HSM, IPIs, TLB shootdown by IPI; then
  `TAKES_INTERRUPTS` is true. Another hart may take a page fault on a kernel mapping `map` just made, before Svvptc's
  bounded time has passed; R4 retries such a fault rather than stopping.
- **R5:** user mode, `ecall` system calls, floating-point and vector state, the debug triggers, virtio over PCI.
- **R6:** the RISC-V IOMMU, Zicfiss shadow stacks and Zicfilp landing pads; QEMU's CPU then needs `zicfilp=on` and
  `zicfiss=on`, which `rva23s64` leaves out.
