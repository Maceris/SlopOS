# 0114: 9d1, Generations on the ESP, as Built

Status: accepted
Date: 2026-10-30
Related: `0113` (9d's plan), `0094` (the bundle store, BLAKE3 names), `0110` (the system records), `0088` (the image
builder), `../design/software.md` §5

## Context
`0113` made a generation a record on the ESP naming its kernel, its boot set by hash, the bundle store's root and its
command line, with Limine choosing one by `limine.conf`'s entries. Until now `boot.py` copied the boot set to
`boot/modules` by name and wrote one fixed entry, and the kernel named each module by its file's name.

## Decision
- **The record** (`src/generations`): fixed-size plain data, checked wherever it's read (`check`), since a hosted
  tool, the root task and the update service all read it.
  - It holds the generation's number, its state (tentative, permanent or recovery), whether it boots with KASLR,
    the kernel's hash and the bundle store's root, up to 32 boot-set files, each the name the kernel gives its
    module and its hash, and a command line of up to 511 bytes.
  - A record is refused unless its first file is `root_task.elf`.
- **The ESP's layout**: every kernel and boot-set file an object, `boot/objects/<hex of its BLAKE3-256>`, shared by the
  generations that have it; each record at `boot/generations/<number>`; and `boot/limine/limine.conf`, an entry per
  record, newest first and the default, the recovery generation last.
  - Each entry loads its kernel and modules by their objects, and names each module for the kernel with
    `module_cmdline`.
  - Each entry adds `generation=<number>` to the command line.
  - `generations.limine_conf` writes the file, and the update service (9d3) will use the same code.
- **The kernel names a module by its command line** when it has one, and by its file's name otherwise, as an ISO's
  modules are still loaded.
- **The generation builder** (`src/tools/generation_builder`, hosted) writes a generation into an ESP folder on the
  host: its objects, its record (permanent, as what's built on the host is known to boot), and `limine.conf` for every
  record the folder has.
  - `boot.py` runs it for a disk image, with the store builder's root, after the store builder.
  - Programs are still copied to `boot/modules` too, where the disk check compares one with the system volume's.
- **The root task** says which generation it booted, from `generation=` on its command line.
- **Tests**: a hosted test of the record's check, reading one back, and `limine.conf`'s entries and order; every boot
  from the image builder's disk boots generation 1 by its objects.

## Alternatives considered
- **Hashing in `boot.py`**: Python's `hashlib` has no BLAKE3, and the device's update service needs the same code.
- **Records in `std`'s schema encoding**: `std` writes it but can't read it back yet; a fixed record is checked in a
  few lines, as the system records are (`0110`).

## Consequences
- 9d2 next: dependency kinds, degraded boots and the supervisor's report of healthy.
- The ESP holds the boot set twice in the test image (objects and `boot/modules`); 9d3's ESP budget counts objects.
