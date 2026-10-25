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
- 8c2's crash-state tester checks that every prefix of a commit's writes mounts to a prefix of the operations.
