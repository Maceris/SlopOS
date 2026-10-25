# 0085: The Plan for Storage (M8)

Status: accepted
Date: 2026-10-25
Related: `0015`, `0016`, `0018`, `0042`, `0046` (the storage model), `0072` (M8 after D), `0084` (D done),
`../design/storage.md`, `../open-questions.md` *Storage*, `../roadmap.md` M8

## Context
D is done (`0084`): drivers reach only their own domains, so M8's storage stack starts on drivers that aren't
trusted. `../design/storage.md` (proposed 2026-10-24) lays out the processes, the native filesystem, the protocols,
FAT32 and the testing, and left open: whether each unlocked volume gets a process of its own, the default cipher,
the crash semantics promised, writable mappings, an intent log, and how M8 is staged. Also open here: whether
SlopOS boots from the disk image M8's image builder makes, and the native filesystem's block and node sizes.

## Decision
Chosen with the project's owner:
- **A process per unlocked volume** (`storage.md` §2): a volume server holding its volume's keys, its tree and its
  clients, under a container service per SlopOS partition that owns the space map, quotas and checkpoints and never
  sees plaintext; a partition server per disk; a FAT server per FAT partition; the storage manager over them all.
- **ChaCha20-Poly1305 by default** for encrypted volumes, AES-256-GCM on request per volume where the CPU has AES;
  BLAKE3-256 seals on unencrypted ones.
- **Ordered crash semantics**: after a crash, a volume is in the state after a prefix of the acknowledged operations,
  and durability comes only through `Sync`. The crash-state tester checks exactly that.
- **No writable file mappings, ever**: read-only mappings of immutable content through pager-backed memory objects in
  M9; writes always go through `File`.
- **No intent log** to begin with: every `Sync` commits the open transaction group, and a log comes only if a real
  workload shows commits too slow.
- **4 KiB blocks and 16 KiB B+tree nodes**: data in extents of 4 KiB blocks, tree nodes of 16 KiB.
- **The roadmap's six stages**, each with its as-built record:
  - **8a, partitions**: the storage manager, GPT, the partition server, and `block` connections narrowed to a range.
  - **8b, FAT32 and the file protocols**: the FAT server, `Dir`, `ReadOnlyDir`, `File`, `ReadOnlyFile` and
    `FileSet`, informational names, bulk data through a buffer each connection registers, and `std`'s files for
    SlopOS; the ESP readable from a boot test.
  - **8c, the native filesystem, hosted**: the on-disk format, the container's space map and checkpoints, the B+tree,
    volume trees and seals; the crash-state tester, the fuzzer, and the image builder.
  - **8d, the native filesystem as services**: the container service and volume servers, atomic replacement,
    transactions, `Sync`, change cursors.
  - **8e, encryption and snapshots**: sealed volumes, key generations, snapshots and clones, quotas and the reserve.
  - **8f, stored links**: links into another volume, listed and revoked by the granter (`../design/security.md` §8).
- **SlopOS boots from a disk image** once the image builder exists (8c): a GPT disk with the ESP (Limine, the
  kernel, the boot modules) and a container with the system volume, which boot tests boot; the ISO stays for the
  tests that need no disk.

Within that, and the as-built records will say how each came out:
- The filesystems are portable packages, built and unit-tested hosted over a buffer standing in for a disk, on
  Windows and Linux, before they run as SlopOS services; the image builder is a Hemera program `tools/` runs.
- The crash-state tester records every write between flushes through a test `block` server and replays every
  prefix and the reorderings within each flush interval (CrashMonkey); the fuzzer mutates images through the FAT
  server's and the container's mount paths.
- On-disk structures are explicit-endian Hemera structs with size asserts.

## Alternatives considered
- **One storage service for every volume**: fewer processes and no allocation hop, but one bug reaches every
  unlocked volume's plaintext, and volume management would run where plaintext is.
- **AES-256-GCM by default**: faster with AES instructions, slower and harder to make constant-time without them.
- **Per-file crash ordering**: what most filesystems give, and what applications get wrong (`storage.md` §1).
- **Writable mappings later**: errors as faults and unclear durability, which databases that relied on them regret.
- **An intent log now**: a second write path to make crash-consistent before anything needs it.
- **4 KiB nodes**: one size to allocate, but deeper trees and more of each node spent on 64-byte pointers.
- **The native filesystem before FAT32**: FAT32 comes first because the ESP is FAT32 and M9's updates write there,
  and it's the smaller first client of the file protocols.
- **Stored links in M10**, which is what shares through them: they belong with the volumes they point into.
- **Booting only from the disk image, or only from the ISO**: the first makes every test build a disk, the second
  leaves the image builder untested where it matters.

## Consequences
- `../open-questions.md` *Storage* is answered; `../design/storage.md` stands as M8's design, its §10 decided here.
- M8 needs Hemera's explicit-endian structs, bounds proofs over block buffers and generic B+trees at scale, and
  `std/crypto`'s ChaCha20-Poly1305 and BLAKE3 at disk speeds; what they need goes in the feedback log.
- M9's update service writes boot generations to the ESP through 8b's FAT server.
