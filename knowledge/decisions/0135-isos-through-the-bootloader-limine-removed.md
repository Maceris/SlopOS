# 0135: B4, ISOs Boot Through SlopOS's Bootloader; Limine and BIOS Boot Removed

Status: accepted
Date: 2026-10-31
Related: `0131` (B's plan), `0133` (the bootloader), `0134` (boot counting and recovery), `0020` (Limine, superseded),
`0088` (the image builder), `0113` (generations), `../../docs/specs/boot_info.md`

## Context
`0131`: once the bootloader boots disks, ISOs boot through it too, as an El Torito EFI image, and Limine leaves the
tree, with BIOS boot, so every boot is UEFI. After B3 only boot disks went through the bootloader: every ISO, which
most boot tests use, still went through Limine, and the kernel was built twice, once for each boot protocol.

## Decision
- **The ISO**: its El Torito EFI image is a FAT32 volume, the ESP an ISO boots from, holding the bootloader as
  `EFI/BOOT/BOOTX64.EFI` (and `BOOTAA64.EFI`) and generation 1, permanent, written by the generation builder: the
  kernel and every program as objects, every program in the boot set, root task first. The image builder makes the
  volume alone (`image_builder --fat`); xorriso makes the ISO around it, the image also a partition of its own. The
  bootloader reads it through the firmware's file system protocol as it reads a disk's ESP. It can't be written, so an
  ISO boot has no seed file and counts no tries; its generation is permanent, so there are none to count.
- **Room for every program**: a generation's boot set holds 64 files (was 32) and the handoff 72 modules, the boot set
  and the bootloader's `last_panic`, since an ISO's boot set is every program.
- **A kernel alone**: a generation with no boot set checks, for the tests that boot the kernel without programs
  (`boot.py --kernel-alone`); `generations.check` asks for the root task first only when there are files.
- **Limine leaves**: `src/boot/limine` and its linker scripts, the build's `boot` setting (the kernel is always built for
  `src/boot/slopos`), `limine.conf` and `generations.limine_conf`, the update service writing it (the bootloader boots
  the newest record), the generation builder's menu timeout and `--boot-recovery` (the recovery key does that, `0134`),
  `boot.py`'s `LIMINE`, `--uefi` and `--bootloader`, and the image builder's `bios` partition, so a boot disk's ESP is
  partition 2 and its container partition 3.
- **BIOS boot leaves**: every boot is UEFI, OVMF on x86-64 as AAVMF already was on AArch64. The bootloader runs on any
  x86-64 or ARMv8-A CPU, using RDRAND only where CPUID has it and RNDR only where `ID_AA64ISAR0_EL1` has FEAT_RNG, so
  the kernel is still the one to refuse a CPU below its baseline (and now names AArch64's baseline on AArch64).
- **The disk check** leaves the bootloader's own files in `EFI/SlopOS` (`SEED`, `LAST_PANIC`) out of what it counts.
- **Tests the new timing showed racing**: the TLB shootdown test waits for each CPU's own reading rather than a count
  of answers, which a CPU woken twice filled for another; the test of restarting the storage stack and the config
  service no longer expects lines its kills may come before.

## Alternatives considered
- **Writing ISO 9660 and El Torito ourselves**: xorriso is a build tool like QEMU, and nothing on the device reads
  an ISO but the firmware.
- **A FAT16 EFI image, under El Torito's 32 MiB**: the FAT package formats FAT32 only, and edk2 boots the larger image
  through the partition xorriso adds for it.
- **Booting tests from a disk image instead of an ISO**: ISOs are the install media, so they're what's tested.

## Consequences
- One kernel build per architecture and stack-check mode; every boot test goes through the bootloader.
- An x86-64 boot through OVMF takes about a second more than BIOS through Limine did.
- B is done: the next stage is M10.
