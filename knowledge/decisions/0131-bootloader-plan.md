# 0131: The Plan for B, a Hemera Bootloader

Status: accepted
Date: 2026-10-31
Related: `0020` (Limine for now), `0092` (B after M9), `0097` (the boot items), `0113` to `0118` (generations),
`0123` (before M10), `../design/lessons.md` §1, `../roadmap.md` B

## Context
B replaces Limine with a bootloader written in Hemera, on both architectures: it reads the ESP's generations, counts
boot attempts and falls back to the previous generation when a new one doesn't report healthy, and reaches the recovery
generation by a key or once every normal generation's counter has run out (`lessons.md` §1.3, §1.5). From `0097`: the
command line a field of the generation, editable only for development generations; a panic record kept across the
reset; a seed file on the ESP mixed into the boot seed; nothing parsed but FAT, generation records and ELF. Hemera can
link PE/COFF (Windows), through `lld-link`, which also makes UEFI applications.

## Decision
Chosen with the project's owner:
- **Hemera gains `OS == .UEFI`**: `base`'s runtime on UEFI's boot services (memory from `AllocatePool`, output on
  `ConOut`, the end through `Exit`), and the compiler linking PE32+ EFI applications, x86-64 and AArch64, so the
  bootloader is ordinary Hemera, with a context, logging and `std`'s freestanding parts.
- **The kernel takes SlopOS's own `BootInfo`**: the bootloader fills `src/boot_info`'s `BootInfo` and enters the kernel
  through a small entry of its own beside `src/boot/limine`'s, which leaves with Limine.
- **Boot attempts are counted in the generation record**: a tries-left field the bootloader decrements, on the ESP,
  before it boots a tentative generation, which the update service clears when it makes it permanent.
- **The bootloader replaces Limine everywhere**: boot disks, and ISOs as an El Torito EFI image; Limine leaves the
  tree, and BIOS boot with it, so every boot is UEFI.
- **The panic record survives in reserved RAM**: the bootloader keeps a small region out of the memory map and tells
  the kernel where it is; the kernel writes its record there at a panic, and the next boot finds it (a warm reset
  keeps RAM) and the root task copies it to the ESP.
- **Sealing the system volume's key to a measured boot set is left for H**, with the hardening it belongs with.

Decided here:
- **What it reads**: the ESP through the firmware's file system protocol (FAT, which UEFI reads anyway), generation
  records checked with `generations.check`, each boot-set file and the kernel checked against its hash, and the
  kernel's ELF. No configuration language, no images, no fonts.
- **In four stages**, each with an as-built record, on both architectures:
  - **B1, Hemera's UEFI target**: `OS == .UEFI`, PE32+ EFI applications, `base`'s runtime there; tested by a program
    run under QEMU's UEFI firmware on both architectures, and Hemera's own tests.
  - **B2, the bootloader boots a disk**: generations read, the kernel loaded and laid out (KASLR from the firmware's
    RNG, the direct map), the boot set loaded as modules, `BootInfo` filled, boot services left; boot disks boot
    through it, Limine kept for ISOs meanwhile.
  - **B3, boot counting and recovery**: tries left, automatic fallback, the recovery generation by a key or when every
    counter's out; the command line only from the generation, editable for development ones; the panic record in
    reserved RAM; the seed file.
  - **B4, ISOs**: an El Torito EFI image with the bootloader and the boot set; Limine and BIOS boot removed, and the
    tests that booted by BIOS boot by UEFI.

## Alternatives considered
- **Freestanding**, no new OS in Hemera: less in `base`, every UEFI call hand-made in the bootloader.
- **Speaking Limine's protocol**: the kernel unchanged, a foreign protocol kept forever.
- **Counting in UEFI variables**: no FAT writes from the bootloader, but variables differ across firmware.
- **Keeping Limine for ISOs**: two boot paths to test.

## Consequences
- `../roadmap.md`'s B gains its four stages; with B, everything planned before M10 is done.
- The x86-64 tests that boot by BIOS (the "BIOS" boot test among them) move to UEFI in B4.
