# 0133: B2, SlopOS's Bootloader Boots a Disk, as Built

Status: accepted
Date: 2026-10-31
Related: `0131` (B's plan), `0132` (Hemera's UEFI target), `0031` (BootInfo), `0113`, `0114` (generations),
`../../docs/specs/boot_info.md`

## Context
`0131`: the bootloader reads the ESP's generations, loads the kernel at a random place with a direct map, the boot set
as modules, fills SlopOS's own `BootInfo` through an entry of the kernel's own, and leaves the boot services; boot disks
boot through it, Limine kept for ISOs until B4. Limine also started the other CPUs, through its MP protocol.

## Decision
- **The handoff** (`src/boot_protocol`): the bootloader is a program of its own, so it hands the kernel fixed-size plain
  data, physical addresses and counts, checked by its magic and size: the command line, the memory map already in
  `BootInfo`'s form (sorted, merged, page 0 never usable), the kernel image and its segments, the modules, each CPU and
  its mailbox, the framebuffer, entropy and the firmware tables' addresses, and room for `BootInfo`'s arrays, which the
  kernel's adapter fills in place, pointing into the handoff, so it needs no memory of its own.
- **The kernel's adapter** (`src/boot/slopos`), beside `src/boot/limine`, with its own linker scripts, chosen by the
  build's setting `boot=slopos`: its `kernel_entry` takes the handoff's address in the direct map, sets up the carrier
  block and boot context, and calls `kernel.boot` as Limine's does.
- **The bootloader** (`src/uefi/bootloader`, `BOOTX64.EFI` or `BOOTAA64.EFI`):
  - the ESP through the firmware's file system protocol; the newest generation but the recovery one, its record
    checked by `generations.check`; the kernel and each boot-set file read whole and checked against their hashes; the
    command line as Limine's entry for it was (`generation=`, `recovery`, `store_root=`);
  - the kernel's `PT_LOAD` segments copied into pages of a memory kind of its own, moved by a random multiple of 2 MiB
    under 1 GiB, its relative relocations applied; the modules in pages of another kind, so the memory map says
    which are the kernel's and the modules'; its own pages boot-reclaimable;
  - page tables, the largest pages that fit: the kernel image; every range but reserved and defective memory at a
    random direct map offset and identity-mapped, for the bootloader's last instructions; on x86-64 the first 4 GiB
    whole as well, firmware tables and device registers among them; on AArch64 only memory, as normal memory, TTBR1's
    and TTBR0's, since the kernel maps the device registers it needs itself;
  - the firmware's RNG for KASLR and the kernel's pool, its framebuffer (a linear one of 32-bit pixels), its tables by
    their GUIDs; the memory map read and converted with nothing allocated after, and the boot services left;
  - x86-64's new intrinsic `enter` (CR3, the stack, a jump with the argument in rdi), AArch64's (MAIR, TCR, both
    TTBRs, the stack, a branch with the argument in x0), the kernel's code cleaned from the data cache there first.
- **The other CPUs**, parked as Limine's MP protocol parks them, on mailboxes in the handoff that the kernel's
  `start_cpu` writes, the argument and then the goto address:
  - **x86-64**: listed by the firmware's MP services (no ACPI parsed), each given a stack, then after the boot services
    are left started one at a time by INIT and two SIPIs, timed by the TSC as calibrated against the firmware's `Stall`,
    to a trampoline below 1 MiB that goes from real mode straight to long mode on the bootloader's tables (whose root
    is below 4 GiB for it) and says it's there;
  - **AArch64**: listed by the device tree's cpu nodes (`devicetree.cpus`), started by PSCI's `CPU_ON` through the
    psci node's conduit (Hemera's new `hvc` and `smc` intrinsics), at a trampoline that turns the MMU on with the boot
    CPU's settings, what it reads with its MMU off cleaned to the point of coherency first.
  Hemera has no assembler, so each trampoline is its machine code, the few addresses it needs written in.
- **Tests**: `boot.py --bootloader` boots a disk through it, the kernel built with `boot=slopos`, by UEFI; the test
  boots the whole system on two CPUs, on both architectures. `boot_tests.py` builds the kernel both ways.

## Alternatives considered
- **Starting the other CPUs in the kernel's adapter**: the same trampolines, later, in code that can't call the
  firmware for the list of CPUs.
- **Building `BootInfo` itself in the bootloader**: its pointers and layout are the kernel's own, compiled with it.

## Consequences
- Booting counts, falls back and recovers in B3; ISOs boot through it, and Limine and BIOS boot go, in B4.
- The memory map's framebuffer is added by the bootloader, as the firmware's map leaves it out and the kernel's direct
  map wants it.
