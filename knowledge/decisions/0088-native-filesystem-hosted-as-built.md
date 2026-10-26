# 0088: The Native Filesystem, Hosted, as Built

Status: accepted
Date: 2026-10-25
Related: `0085` (the plan for M8), `0087` (FAT32 and the file protocols), `0046` (the storage model),
`../design/storage.md` §3, §4, §9, `../roadmap.md` M8

## Context
M8's third stage (8c, `0085`): the on-disk format, the container's space map and checkpoints, the B+tree, volume
trees and seals; the crash-state tester, the fuzzer and the image builder, all hosted. Chosen with the project's
owner: built in three parts, each committed as it passes, with one report at the end: 8c1 the filesystem itself,
8c2 the crash-state tester and the fuzzer, 8c3 the image builder and booting from the disk image. This record grows
with each part.

## Decision
### 8c1: the filesystem
Built as `src/slopfs`, a portable package over a device of 4 KiB blocks (read, write, flush):
- **On disk** (`format.hsc`): explicit-endian structs with size asserts. Superblocks in the first and last blocks,
  sealed; a ring of 16 checkpoints after the first, the one for transaction `t` at `1 + t % 16`. Block pointers are
  64 bytes: address, a second copy's address, birth transaction, length, key generation and a BLAKE3-256 seal. Nodes
  are 16 KiB with a 64-byte header naming their tree, owner, transaction, level and address. Data blocks have no
  header: their seal in the pointer to them catches a misdirected write as well as damage.
- **Copy-on-write B+trees** (`tree.hsc`): keys `(object, kind, offset)`; leaves of items with values up to 4 KiB,
  branches of up to 185 entries. A node changed in a transaction is copied to a new place first and changed in
  memory from then on; committing writes dirty nodes children first, each parent taking its child's seal, so the tree
  under a checkpoint is a Merkle tree. Reading checks each node's seal, header and structure, the second copy where
  the first fails, and that each child is one level below its parent, so a forged tree can't lead back into itself.
  Emptied nodes are dropped, and one left under a quarter full is merged with a neighbour where both fit; a root leaf
  that empties stays.
- **The container** (`container.hsc`, `space.hsc`): its space map holds free extents, and extents freed in the last
  commit as pending; the owners tree holds every allocated extent's volume; the volumes tree holds each volume's
  record. All three are written twice (ZFS's ditto blocks). The free extents are kept in memory from mount, where
  pending ones count as free, since the checkpoint that freed them is durable. An extent born and freed in one
  transaction is free at once; one born earlier only after this transaction's checkpoint. Committing writes each open
  volume's tree and record, brings the space map and owners up to date with every allocation and free, including
  their own, round after round until a round changes nothing, writes their nodes, flushes, writes the checkpoint and
  flushes again. A failed write fails that commit and every later one (`Failed`) until the container is mounted
  again. Mounting takes the newest checkpoint whose seal holds.
- **Volumes** (`volume.hsc`): objects (kind, parent, size, times, the transaction last changed in, a schema hash),
  directory entries keyed by a 56-bit keyed BLAKE3 hash of the name, those hashing alike sharing a record, and file
  chunks of 64 KiB, each an extent of up to 16 blocks written anew when it changes, the first held in its record while
  the file is at most 2 KiB. A `List` cursor is a hash and a place among those alike, so it survives changes. Names
  are UTF-8 bytes without `/` or NUL, not `.` or `..`, compared exactly. Each object has one parent, so renaming a
  directory beneath itself is refused by walking up.
- **Tests** (`src/slopfs/test`, in `tools/unit_tests.py`): the tree against a model through 20000 puts and deletes
  with commits between; a container formatted, filled, renamed into, removed from and mounted again; space coming
  back after everything's removed; a broken newest checkpoint giving the one before and what it named; a broken data
  block read as `Corrupt`; 600 random writes and resizes of six files against a model, committed and mounted again
  every so often; and a directory of 1500 entries listed whole.
- **Found on the way**:
  - Hemera, fixed: `match f()? { ... }` didn't parse, though `?` unwraps a result anywhere else.
  - Hemera, recorded (`../hemera-feedback.md`): `f()?.member`, and indexing through a pointer to a fixed array.
  - A device's context and a container are kept on the heap by whoever makes them, since the package keeps them
    (`#escaping`), and Hemera rightly refuses keeping what may be on the caller's stack.
  - The commit's rounds didn't settle while a tree with one record lost and regained it in every round, dropping
    and making its root each time; a root leaf now stays when it empties.

Left for later stages: quotas and the reserve, snapshots and encryption (8e); the container service and volume
servers (8d).

### 8c2: the crash-state tester and the fuzzer
- **A whole-container check** (`src/slopfs/verify.hsc`), as fsck checks a filesystem: every node of every tree read
  and checked, every extent nodes and chunks take collected, and those with the free ones found to cover the data
  blocks exactly once, each in the owners tree with its owner. The tests run it after every commit; it finds a leak
  made on purpose.
- **The crash-state tester** (`src/slopfs/test/crash_test.hsc`, after CrashMonkey): a workload of 14 commits on a disk
  that records each write and flush; then every image a crash could leave: each prefix of the writes, six random
  subsets of the writes between each two flushes, and each write torn halfway after those before it. Each of the 529
  must mount, check out whole, hold the state of the last acknowledged commit or of the one being made (64 held the
  latter), and take another commit. With the flush before the checkpoint taken out, it finds the checkpoint reaching
  the disk before what it names.
- **The fuzzer**, through both mount paths, hosted, deterministic, and longer with `SLOPOS_FUZZ_ROUNDS`:
  - slopfs (`src/slopfs/test/fuzz_test.hsc`): an image with a volume of files damaged by flipped bytes, blocks copied
    over others or zeroed, and nodes changed somewhere down a tree with every seal above them and the checkpoint's
    made again, as someone who can compute BLAKE3 could, so what's behind the seals is fuzzed too. Each is mounted,
    checked, read, written and committed. 600 rounds in the unit tests; 20000 run once, without a crash or a hang.
  - FAT (`src/fat/test/fuzz_test.hsc`): the boot sector, the start of each FAT and the first data clusters damaged,
    each round put back after from an undo log of the sectors it changed. 400 rounds in the unit tests; 100000 run
    once.
  - `tools/unit_tests.py` gives each test 900 seconds, so one that hangs fails.
- **Found by fuzzing, fixed**:
  - FAT: a directory whose chain loops was read for up to 2 million slots, each found by walking the chain from its
    start: hours on one directory. A directory now ends at FAT's 65536 slots, and the volume keeps where the last walk
    along a chain was, so reading one forward follows it once. Finding a free alias tried up to a million `~N` tails,
    scanning the directory for each; it's one scan for the tails taken.
  - slopfs, found while making the fuzzer, before it ran: walking up a damaged volume's parents could take as many
    steps as its next object's ID (now at most 4096); a chunk a search found but deleting didn't would loop; a key at
    the largest offset stepped back to the start; a name hash past 56 bits broke `List`'s cursor.

## Alternatives considered
- **A log for the space map (ZFS's space maps)**: cheaper to append to, but `storage.md` has a tree, and the tree
  answers "what's free near here" without replaying.
- **Per-block extents**: simplest, but a record for every 4 KiB; whole-file extents need splitting on every partial
  write, each split rewriting what's left since a seal covers the whole extent. 64 KiB chunks sit between.
- **A header on data blocks**: what `storage.md` first said of every block, but it would misalign file data, and
  the seal already tells a misdirected write.

## Consequences
- 8d's volume servers hold a volume's tree and ask the container service for extents, as `Nodes` already asks
  through functions; the container's commit is what they'll ask to make durable.
- The crash-state tester and the fuzzer take 8d's services as they come: the same image, mounted through them.
