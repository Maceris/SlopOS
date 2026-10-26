# 0089: The Native Filesystem as Services, as Built

Status: accepted
Date: 2026-10-25
Related: `0085` (the plan for M8), `0088` (slopfs, hosted), `0087` (the file protocols), `0046` (transactions and
atomic replacement), `0086` (partitions), `../design/storage.md` §2, §4, §6, `../roadmap.md` M8

## Context
M8's fourth stage (8d, `0085`): the container service and volume servers, atomic replacement, transactions, `Sync`
and change cursors, and, left from 8c, mounting the system volume at boot. Chosen with the project's owner:
- **Programs load from the system volume**, rather than only checking it mounts: a small boot set stays in Limine's
  modules, enough to reach storage, and the rest comes from the volume, Limine's modules standing in where there's no
  system volume, as on the ISO.
- **Change history kept to a size budget** per volume, the oldest dropped first; a cursor older than what's kept is
  answered `Resync`.
- **Transactions held in the volume server's memory**, charged to the client's connection, with a cap.
- **`Replace`, transactions and change cursors on the native filesystem only**: FAT answers them `Unsupported`, and
  `Features` says so.
Delivered as 8b and 8c were: in three parts, each committed as it passes, with one report at the end: 8d1 the
services, 8d2 `Replace`, transactions and change cursors, 8d3 programs from the system volume. This record grows with
each part.

## Decision
### 8d1: the container service and volume servers
- **slopfs apart from its container**: a volume has nodes and a device of its own (`attach_volume`), as a volume server
  holds it, or the container's own in one process, as the hosted tests and the image builder hold it. The space's
  waiting changes are kept by owner: a commit of one volume (`commit_volume`) takes its changes and the container's
  own, and leaves the others' waiting, so a volume's allocations are made durable only with the tree that names them.
  An extent given back before any commit took its allocation is free again at once, nothing having named it; one a
  durable checkpoint may name is free only after the commit taking its owner's changes is durable. The hosted tests
  run two volumes apart and crash between their commits: nothing leaks, and the one that hadn't committed is as it
  was, its freed blocks untouched by the other's writes.
- **The container service** (`src/services/container_service`), one per SlopOS container whose files are asked for,
  given a connection narrowed to its partition and nothing else. It serves the `container` protocol
  (`src/protocols/container`): a connection for each volume (`OpenVolume`), on which its server describes it,
  allocates and gives back extents, and commits; and block connections narrowed to the volume's extents
  (`OpenBlocks`), each a connection of its own to the driver, so data moves with no copies, every read and write
  checked against an in-memory list of every volume's extents, kept from the owners tree and as they're allocated and
  given back. An extent given back that isn't the volume's, or a root that isn't in its extents, is refused
  (`NotYours`). A commit keeps the volume's name and hash key as they were, taking only its root and next object.
- **The volume server** (`src/services/volume_server`), one per volume in use, given its connection to the container
  service and a listener, and nothing else. It holds the volume's tree and dirty nodes and serves `dir`,
  `read_only_dir`, `file`, `read_only_file` and `file_set`, as the FAT server does, names compared exactly. A `Sync`
  commits and answers once that's durable; otherwise a change is committed a second after it's made. Its own writes
  finish before it asks for the commit, so the container service's flush before the checkpoint covers them.
- **The storage manager** starts a container service and a volume server for the system volume the first time a SlopOS
  container's files are asked for, and gives back the volume's root. The supervisor gives the disk check the first
  container's system volume; it reads a module there and compares it with Limine's copy on the ESP, and writes,
  syncs, reads back and moves a file of its own. Budgets: the supervisor 48 MiB, the storage manager 20 MiB, a
  container service 4 MiB and a volume server 6 MiB; the root task now gives 30 grants.

### 8d2: Replace, transactions and change cursors
- **The protocols** (Hemera's `std/os/slop_os`): `dir` gains `Begin` (with a memory object), `Commit`, `Abort`,
  `Replace` and `Changes`, answered `Began`, `Changed`, `UpToDate` and `Resync`; `read_only_dir` gains `Changes`;
  `file` gains `Install`; `FileError` gains `Conflict`. Added as new variants, so the protocols keep their versions,
  and the FAT server answers them `Unsupported`.
- **slopfs** (`history.hsc`): a volume's change history in its own tree, a record per change, trimmed to a budget in
  bytes (1 MiB in a volume server), writes to one file in one transaction kept as one; orphans, objects no name leads
  to, kept while they're open and swept when a volume server starts, which `Replace` installs from (`install`) and a
  removal of an open file leaves (`unlink`); and forgetting a volume's changes since its last commit (`forget`), the
  container undoing its allocations and frees (`abandon_volume`, the container protocol's `Abandon`).
- **Transactions** (`src/services/volume_server/transactions.hsc`): logged in the memory the client gives `Begin`, so
  they're charged to it and capped by it, and read back at commit as the client's own bytes, checked as they're read.
  Each records the versions (the transaction an object last changed in) of what it touches and of the directory each
  name is in; an object with changes not yet committed is committed first, so a later change shows as a newer version.
  Commit commits what's waiting, checks the versions, applies the log and commits; a failure partway forgets
  everything since and abandons it, so nothing is left. Making directories isn't part of a transaction yet: its
  `OpenDirectory` opens them as they are.
- **Replace**: a new orphan, written through a file connection of its own, installed by `Install`, which orphans the
  file it replaces until nothing has that open.
- **Tests**: hosted, the history read beneath a directory and trimmed, a replacement installed with the old contents
  still readable, and everything since a commit forgotten without a leak. Booted, the disk check on the system volume
  replaces a file while it has it open, commits a transaction of two files nothing saw before, is refused one whose
  file was changed outside it, has one that fails partway leave nothing, and follows every change with a cursor.

### 8d3: programs from the system volume
- **The boot set**: `system_config`'s services gain `boot_set`, true for what reaches the system volume: the root task's
  entropy service, process manager, platform service and supervisor, `virtio_blk`, the storage manager, the partition
  server, the container service, the volume server, and the FAT server, since the ESP the boot set comes from is FAT.
- **The supervisor** starts the boot set's drivers and the storage manager first, asks it for the first container's
  system volume, and then every other driver and service, each program outside the boot set read from the volume's
  `modules` folder once, straight into a memory object of its own given to the volume server as the read's buffer, and
  kept for restarts. Where there's no system volume, or the program isn't there, Limine's module stands in, so the ISO
  boots as before. `hello`'s module is optional now, as the others' are.
- **The boot disk** (`tools/boot.py --boot-disk`) has Limine load only the boot set; every program is in the system
  volume. Booted, the console, `hello` and the disk check come from it, on x86-64 through BIOS and UEFI and on AArch64.
- **Found on the way**: an optional starts zeroed, and its zero is `Some` with a zero value, since `Some` is
  `Optional`'s first variant, so a struct's optional field left out of its literal, or a variable declared without a
  value, holds `Some(0)` rather than `None`. The supervisor's table of programs read keeps a flag instead. Recorded in
  `../hemera-feedback.md` for the project's owner, since changing it changes what Hemera code means.

## Alternatives considered
- **The container service copying volumes' data**: simpler checks, but every block copied twice; narrowing the
  driver's connection, as the partition server does, costs nothing more.
- **Trusting volume servers with the whole partition**: a bug in one would reach every volume, which is what a process
  per volume is for (`0085`).
- **Committing every volume together**: one commit would make another volume's half-finished changes durable, or leak
  its allocations after a crash.

- **The supervisor loading programs at boot from the ESP's FAT**: it's already read by Limine, but the system volume
  is what updates write (M9), and checks every block it's read from.

## Consequences
- A volume server's allocations are a round trip each to the container service; batching them waits for a measurement
  that says it's needed.
- The container service keeps every volume's extents in memory, a few dozen bytes each: fine for SlopOS's disks now,
  and a tree of its own when a volume has millions of chunks.
- M9's update service installs programs by writing the system volume, with `Replace` and transactions, and the next
  boot runs them; only the boot set needs the ESP.
- Encryption, snapshots, quotas and the reserve are 8e's.
