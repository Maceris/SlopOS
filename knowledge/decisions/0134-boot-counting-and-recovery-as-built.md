# 0134: B3, Boot Counting, Recovery, the Seed and the Panic Record, as Built

Status: accepted
Date: 2026-10-31
Related: `0131` (B's plan), `0133` (the bootloader), `0113`, `0116` (generations and their updates), `0118` (the
recovery generation), `../../docs/specs/boot_info.md`

## Context
`0131`: the bootloader counts a tentative generation's boots in its record, falls back to the one before when it never
reports healthy, reaches the recovery generation by a key or once nothing else is left, mixes a seed file on the ESP
into the boot's entropy, and keeps a panic record in reserved RAM across a reset. B2 (`0133`) boots the newest
generation and writes nothing.

## Decision
- **Tries left** (`generations.Generation.tries_left`, a padding byte before): the update service installs a tentative
  generation with `TRIES`, 3, and the generation builder stages one with them; `generations.check` refuses more. Each
  boot of a tentative generation, the bootloader takes one and writes the record back to the ESP before it boots it,
  so a boot that hangs or resets is counted too; one it can't write back isn't booted.
- **Fallback**: generations are tried newest first, the recovery generation aside; a tentative one with no tries left
  is passed over for the one before. The update service, told a boot's assessment, removes the records of tentative
  generations newer than the one booted that have none left, as it removes one that booted degraded.
- **Recovery**: the key `r` (or `R`) typed on the firmware's console input as the bootloader starts boots the
  recovery generation, every waiting key taken; the bootloader looks for up to 100 ms, ending at the first key, since
  AArch64's firmware took a moment to see one the x86-64 firmware had already. No generation left to boot normally
  boots it too. On QEMU the
  serial console is the firmware's input too, so a test holds the key by sending it until the bootloader says what it
  boots (`boot.py --recovery-key`).
- **The seed file** (`EFI/SlopOS/SEED`, 32 bytes): the firmware's RNG's bytes, the seed's and the CPU's counter are
  hashed together (BLAKE3, the bundle hash); the kernel's entropy is one hash of that, the next seed another, written
  before the kernel boots, so neither tells the other and no two boots start from the same seed.
- **The panic record** (`boot_info.PanicRecord`, a page): the bootloader allocates it at a fixed low address, the same
  every boot, as memory the firmware's map and the kernel's call `FirmwareReserved`, so the direct map covers it and
  nothing uses it, and hands its address to the kernel (`BootInfo.panic_record`). The kernel adds every fatal line to it
  and seals it, with its stop reason and an FNV-1a check, when it stops for a fault (not a halt or the root task's end);
  with `panic_reset` on the command line it then resets the machine warm (x86-64's reset control register, AArch64's
  PSCI `SYSTEM_RESET` through the device tree's conduit), which keeps RAM. The next boot's bootloader finds the record
  sealed, keeps its text on the ESP as `EFI/SlopOS/LAST_PANIC`, hands it to the root task as the module `last_panic`,
  which logs its first line, and empties the page.
- **The command line** is the generation's alone, as B2 had it; editing it for development generations is left for
  when there's a console to edit it on before boot (B4 or later).
- **Tests**: a staged generation that never reports how it booted (the supervisor's `test_unassessed`), booted three
  times and passed over on the fifth boot and rolled back, the seed written and replaced along the way; the recovery
  generation by the held key; a panic's record across a warm reset in one QEMU (`boot.py --allow-reboot`, the kernel's
  `test_panic_once`), on the ESP and logged by the root task.

## Alternatives considered
- **The root task copying the panic record to the ESP**, as `0131` had it: the bootloader already writes the ESP for
  the tries and the seed, and does it before anything else can fail.
- **Finding the panic record through a UEFI variable or a file naming its address**: a fixed address needs neither,
  and a record the firmware overwrote fails its check.
- **A boot menu for recovery**: one key is enough to reach the recovery generation, which has the console.

## Consequences
- A generation that hangs or crashes before it's assessed costs at most three boots before the one before boots again.
- ISOs boot through the bootloader, and Limine and BIOS boot go, in B4.
- The fixed address of the panic record's page is a guess about where firmware doesn't allocate; when it's taken, the
  page is somewhere else for that boot and the next finds no record.
