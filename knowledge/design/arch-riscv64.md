# Arch Notes: RISC-V

What L0 and L1 (see `layers.md`) need to deal with on 64-bit RISC-V, as `arch-x86-64.md` does for x86-64. The plan is
`../decisions/0199` (M19); this note says what's built (R3 and R4) and what each later stage adds.

## Target Environment

- **Development target:** QEMU's `virt` machine with the device tree (`acpi=off`), edk2's RISC-V firmware over
  OpenSBI, virtio devices; the PLIC by default, the AIA with `virt,aia=aplic-imsic`. `tools/boot.py --arch riscv64`,
  with `--aia` for the second.
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
- **The other harts** are the device tree's cpu nodes, started after the boot services are left by the SBI's HSM
  `hart_start` at a trampoline (machine code, as on the other two), translation off and the mailbox in `a1`: it loads
  the bootloader's `satp`, takes its stack, clears `tp` and waits on its mailbox.
- The panic record's page is at `0x80400000`, past OpenSBI's 2 MiB at the start of RAM.

## What `arch/riscv64` Implements

- **Per-hart state:** `tp` is the `ArchCpu` in the kernel; in user mode `sscratch` is, so a trap swaps them (Hemera's
  `riscv64.TrapScratch`, which the `ArchCpu` starts with). Before `init_cpu`, `tp` holds the early console's word,
  which is odd, so the two are told apart. Supervisor mode can't read its hart ID, so `init_cpu` takes it from L2.
- **Interrupts:** the AIA where the device tree has an IMSIC with supervisor files, else the PLIC. With the AIA every
  interrupt is a message, as x86-64's are: the kernel's device IDs are the IMSIC's identities, MSIs and the APLIC's
  lines name them directly, and IPIs are identities written to a hart's file. With the PLIC the IDs are the kernel's
  own, routed from lines as AArch64 routes SPIs, there are no MSIs, and IPIs are the SBI's, their kinds kept in the
  target's `ArchCpu`. An interrupt only comes while idle, and its entry is moved to the kernel stack's top, as x86-64's
  IST does. The test device is the APLIC's last source, pended in software, or with a PLIC the UART's transmitter
  interrupt, armed again a hundred times a second.
- **Timer:** Sstc's `stimecmp`, holding the earlier of the hart's two deadlines: the kernel's and, on the hart that
  started the test device, the test device's own, as the kernel's stop while the hart's idle. A timer interrupt for
  the test device's alone is Spurious to the kernel.
- **Stale page faults:** a hart may keep an invalid entry it walked before another hart made it valid, until Svvptc's
  bounded time; a kernel page fault on an address the tables now allow is fenced and retried.
- **Traps:** one `.entry` function in `stvec`, direct mode. From user mode the frame is on the kernel stack's top.
  From the kernel it's on whatever stack the kernel was on, which may be the one the stack check (`ebreak`) found
  full, so the entry only rewrites the frame and returns: its `sret` lands in `kernel_trap` on the hart's DoubleFault
  critical stack, which reports the fault. Every stack's limit leaves room for a frame (288 bytes) below it as well as
  the guard. The kernel never faults on purpose (it reaches user memory through the direct map), so every kernel
  exception is fatal.
- **Paging:** Sv48 with Svpbmt (`WriteBack` PMA, `WriteCombining` NC, `Device` IO); the kernel half shared by copying
  its 256 top-level entries, as on x86-64. Non-leaf entries have no spare bits for a count, so `unmap` scans for a
  second valid entry. D is always set. A is kept by software under Svade: a kernel leaf's is always set, a user
  leaf's is cleared by `take_accessed`, and the next access through it faults, which the trap entry answers by setting
  it and making the access again, as for a stale entry. `map` fences each new entry on the calling hart, since a hart
  may keep an invalid entry it walked.
- **Console:** the device tree's 16550, mapped through the direct map as an I/O page, as AArch64 maps its PL011.
- **Reset and power:** the SBI's SRST. `test_exit` is semihosting, as on AArch64. `virt` has no power button.
- **User mode:** `ecall` with the number in `a7`, arguments in `a0` to `a5` and results in `a0` to `a2`; the entry
  moves `sepc` past the `ecall` (4 bytes) before the call, and `restart_syscall` moves it back. A thread's registers,
  for a debugger, are `x0` to `x31` by number, then `pc`.
- **Floating-point and vector state:** switched eagerly with the thread, by Hemera's `riscv64.save_floating`,
  `restore_floating`, `save_vector` and `restore_vector`: `f0` to `f31` and `fcsr`, then the vector registers in groups
  of eight and `vstart`, `vtype`, `vl` and `vcsr`, the area's size from `vlenb`. `sstatus.FS` and `VS` are off in the
  kernel and Initial when a thread first enters user mode.
- **Counters:** `scounteren.TM` gives user mode `rdtime`; with it clear, for recording and replay, the read traps as an
  illegal instruction whose `stval` is the instruction, which the entry decodes as a Protection fault for the kernel to
  emulate.
- **Debugging:** none in hardware yet. The triggers are the SBI's debug triggers extension's, not driven, so
  `set_debug` takes no slots and no stepping.
- **Frame records:** `s0` points past the saved `ra` and `s0`, so a record is 16 bytes below it
  (`crash_reports.FRAME_RECORD_BELOW`), and a suspended fiber's continuation is at 104.
- **Devices:** virtio over PCI, the ECAM from the device tree, as on AArch64; their MSIs go to the IMSIC, so programs
  need the AIA. The RTC is Goldfish's, which the platform service finds and the clock service drives.
- **The IOMMU:** the RISC-V IOMMU (`src/iommu/riscv`), first-stage Sv48 domains. MSIs are remapped through MRIFs
  (R7): each device's own MSI page table, an entry for each of its remapped interrupts, whose notice is the interrupt
  itself, sent to its hart's file, so a device raises only its own interrupts, never another's nor an IPI; the window
  its messages write to is what L2 maps into each domain. An IOMMU without MRIFs falls back to translating MSIs as other
  DMA to the harts' interrupt files (`msi_doorbell`). On QEMU it's the PCI one, as `virt`'s platform one goes missing
  from the device tree beside `ramfb`; QEMU 11.1's walk wants U on table entries too, and its translation cache is
  turned off, for a bug in its permissions (decisions/0199's R6).
- **Control-flow integrity:** Zicfilp's landing pads and Zicfiss's shadow stacks, supervisor mode's by the SBI's FWFT
  (landing pads at `init_cpu`, shadow stacks at the hart's first idle or return to user mode, in those functions' own
  bodies) and user mode's by `senvcfg` for each thread. One `ssp` serves every mode, so the trap entry swaps it through
  the `TrapScratch`. Every RISC-V target with shadow stacks branches to each `sspopchk` (`branch-to-sspopchk`), as
  QEMU 11.1 loses the pc after one that passes. Threads get shadow stacks only where every hart's firmware has them.
  The programs' property note needs an lld that knows RISC-V's, not lld 19: Hemera's own, which is beside it
  (decisions/0200).

## Later Stages

- **Later than M19:** the SBI's debug triggers, for hardware breakpoints, steps and watchpoints; an IMSIC in groups,
  with more than one `reg` range, whose harts past the first range aren't brought up yet.
