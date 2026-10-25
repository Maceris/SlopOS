# 0086: Partitions as Built

Status: accepted
Date: 2026-10-25
Related: `0085` (the plan for M8), `0076` (the block protocol), `0077` (connectors), `0084` (drivers out of the TCB),
`../design/storage.md` §2, `../../docs/specs/programs.md`, `../roadmap.md` M8

## Context
M8's first stage (8a, `0085`): the storage manager, GPT, the partition server, and `block` connections narrowed to a
range. `../design/storage.md` §2 has the storage manager hold every disk and start a partition server per disk, which
is untrusted, parses the GPT, and hands out connections narrowed to one partition. Left to this stage: how the
storage manager gets the disks, how it starts the partition servers, how a narrowed connection moves data, and what
tests it.

## Decision
Built:
- **`src/gpt`**, a portable package: reading a disk's table through a function that reads its blocks, the primary
  header and entries, or the backup's at the disk's end where either fails its CRC32 or its bounds; and writing one,
  with the protective MBR and both copies, for the tests and 8c's image builder. Up to 16 partitions are read, names
  as UTF-8 from GPT's UTF-16. Its tests run hosted over a buffer standing in for a disk (`tools/unit_tests.py`).
- **The storage manager** (`src/services/storage_manager`), which the supervisor starts once the drivers have, if
  there's a disk, with
  connectors to the first four disks' drivers, a connection of its own to the process manager and the partition
  server's module. For each disk it dials the driver and starts a partition server through the process manager, with
  that block connection and a listener, nothing else; then lists its partitions. It serves the `storage` protocol:
  every disk's partitions by one index (`Describe`), and block connections narrowed to one (`Open`), which it asks
  that disk's partition server for.
- **The partition server** (`src/services/partition_server`) reads its disk's GPT through its own connection to the
  driver and serves the `partitions` protocol. A narrowed connection is a connection of its own to the driver, made
  through its own with `block`'s `Connect`, which it stands between: `GetBuffer` is answered by the driver, so the
  client maps the driver's DMA buffer and data moves between the device and the client with no copies; `Read` and
  `Write` are checked against the partition's blocks and moved by its first, and one outside it is answered
  `OutOfRange` without reaching the driver; `Describe` is answered with the partition's size; everything the driver
  answers goes back as it is. A client's `Connect` on a narrowed connection gets another, to the same partition.
- **The disk check** now dials the storage manager, opens the partition named `SlopOS check`, runs its checks inside
  it, and is refused the block past its end. The supervisor says everything has started only once it has ended,
  since the storage stack's startup took longer than the root task's settling second.
- **Tests**: `boot.py`'s test disk is a 4 MiB GPT disk with two 1 MiB partitions, its marks in the checked one; QEMU
  boots the CD first (`-boot order=d`), as the disk's protective MBR now looks bootable to the BIOS. The disk boot test
  checks the partition server, the storage manager's list and the disk check's line, and that the guest's mark is in
  the disk's block 2049, the partition's block 1.
- **Found on the way, fixed**:
  - Hemera: a `for` loop over an untyped string constant was refused, though a `string` worked.
  - Hemera: `==` on fixed arrays, structs and tagged unions passed the checker and failed in code generation. Chosen
    with the project's owner: arrays element by element, structs member by member, tagged unions by variant and its
    values; views, dynamic arrays, `any` and `#union` structs refused when checked.
  - Hemera: a typed literal at the start of an expression ended it, so `Point.{1, 2} == p` didn't parse.
  - The supervisor's budget, 16 MiB, couldn't take the storage manager's; it's 32 MiB.

## Alternatives considered
- **The supervisor starting partition servers**: it would hold every disk's partitions' servers, where `storage.md`
  has the storage manager own the storage stack's processes.
- **Copying through the partition server**: a buffer of its own per client, and every block copied; the driver's
  buffer is already per connection, so handing it out costs nothing and narrows nothing it shouldn't.
- **A `block` right or window that narrows a connection in the driver**: every block driver would carry partition
  logic, and the driver is the less trusted of the two.
- **The root task waiting longer to settle**: a guess at a time, where waiting for the check to end is exact.

## Consequences
- 8b's FAT server takes a narrowed connection to the EFI system partition from the storage manager, as the disk check
  does to its partition; 8d's container services take theirs to SlopOS partitions.
- A partition server holds only its disk, so a malicious GPT reaches only that process.
- The storage manager restarting a partition server that crashes waits for 8d, when volumes depend on them.
