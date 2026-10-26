# Storage: Volume Servers, the Native Filesystem, FAT32

Status: **proposed** 2026-10-24, for roadmap M8; its open questions decided 2026-10-25 (`../decisions/0085`). Builds on `../decisions/0015` (`Dir`, `ReadOnlyDir`), `0016`
(per-user volumes), `0018` (`FileSet`, informational names), `0042` (unlocking, key generations), `0046` (typed bytes,
handle-relative trees, transactions in the filesystem) and `security.md` §8 (stored links). The choices still to
make are listed at the end and in `../open-questions.md`, *Storage*.

## 1. What Goes Wrong Elsewhere

| Problem | Where | SlopOS answer |
|---|---|---|
| Filesystem images are parsed in the kernel, so a crafted USB stick is a kernel exploit; fuzzers find mount-path bugs in every major filesystem | Linux, Windows, macOS | Every filesystem is a user process; a foreign filesystem's server holds only its own partition (§2) |
| Crash consistency is whatever the filesystem happens to do; applications must write a temporary file, `fsync`, rename, `fsync` the directory, and still get it wrong (Pillai et al., OSDI 2014, found bugs in every application studied; ext4's zero-length files, 2009) | POSIX | The state after a crash is always the state after a prefix of the operations committed; atomic replacement and transactions are operations of their own (§4) |
| A failed write-back is reported once, or not at all, and the dirty data is dropped (PostgreSQL's "fsyncgate", 2018) | Linux | An error goes to the operation that caused it; after a failed write a volume refuses further commits and says why, rather than drop data (§4) |
| Silent corruption: no checksums, or metadata only | ext4, NTFS, FAT | Every block is checked through the pointer to it (§3) |
| Disk encryption without integrity: XTS lets someone with the disk change or replay blocks undetected | dm-crypt, BitLocker, FileVault 2 | Authenticated encryption per block, with the tag in the parent's pointer, so the volume is a Merkle tree (§5) |
| Encrypted home directories are fixed-size partitions, or file-by-file encryption that leaves names and sizes visible | LUKS per user, eCryptfs, fscrypt | Volumes share a container's space and encrypt their whole tree, metadata included (§3, §5) |
| Full disk: copy-on-write filesystems can fail to *delete* because deleting needs space | Btrfs | A reserve no quota can use, kept for commits and deletion (§3) |
| Change notification loses events when its queue overflows, and is racy to set up over a tree | inotify, FSEvents, `ReadDirectoryChangesW` | A watch is a cursor over the volume's committed changes; falling behind is a `Resync`, never a silent loss (§6) |
| Writable `mmap` of files: errors arrive as `SIGBUS`, durability is unclear, and databases that rely on it regret it (Crotty et al., CIDR 2022) | POSIX | No writable file mappings; read-only mappings of immutable content only (§7) |
| Hard links make "where is this file", quotas and deletion hard; symlinks make every path check racy | POSIX | Neither on the native filesystem (`0046`) |
| `atime` turns reads into writes | POSIX | No access times |

## 2. Processes and Authority

```
 clients ──── Dir / File / FileSet ───► volume server        one per unlocked volume; holds its key
                                            │ extents, commits
                                            ▼
                                        container service    one per SlopOS partition; sees ciphertext only
                                            │ block (a range)
 clients ── Dir ──► FAT server ──┐          ▼
                                 └────► partition server     one per disk; GPT
                                            │ block
                                            ▼
                                        block driver
```

- **The storage manager** is `services.md`'s storage service, now the one that holds every disk's `block`
  capability and starts the servers below through the process manager, each given only its own piece. The session
  manager asks it to unlock a volume (`0016`); the administrator asks it to create, delete, move or resize one.
- **A partition server per disk** parses the GPT and hands out `block` connections narrowed to one partition's range
  of blocks. It's untrusted: a disk from outside is parsed by a process holding nothing else.
- **A container service per SlopOS partition** owns the space map, the volume list, quotas and checkpoints. It
  records which volume owns each extent and lets a volume server read and write only its own. It never holds a
  volume key, so volume management works on an encrypted volume as an opaque unit, exactly as `0016` wants: the
  administrator's requests go here, and nothing here can read a user's data.
- **A volume server per unlocked volume** holds that volume's keys (`0042`: until shutdown), its tree, its cache, and
  every client connection to it. A bug exploited through one user's files exposes that user's volume, not everyone's.
- **A FAT server per FAT partition**, untrusted, holding only its partition.

What's in the TCB: the storage manager, the container services (for availability and isolation between volumes, not
for confidentiality) and each volume server for its own volume.

## 3. The Native Filesystem

Working name `slopfs`. Prior art: ZFS (block pointers carrying checksums, birth times and dead lists), Btrfs and
Rodeh's "B-trees, Shadowing, and Clones" (TOS 2008: copy-on-write B+trees), APFS (containers of volumes sharing
space, per-volume encryption), WAFL (consistency points).

**On disk.** Every structure is a Hemera struct of explicit-endian fields with a size assert (`../conventions.md`).
Every block begins with a header: its kind, the volume that owns it, the transaction it was written in, its level in
its tree. A block that reads back with the wrong header was written somewhere else (a misdirected write) and is an
error.

**Block pointers** are 64 bytes: address, length, the transaction it was born in, the key generation (§5), and a
32-byte **seal**: BLAKE3-256 of the block on an unencrypted volume, or the AEAD's nonce counter and tag on an
encrypted one. Reading a block checks its seal against its parent's pointer, so the tree from the checkpoint down
is a Merkle tree.

**The container:**
- Two superblocks, at the start and the end of the partition, naming the container and its checkpoint area.
- A **checkpoint ring**: each commit writes a checkpoint record with the next transaction number, the roots of the
  container's trees (space map, volume list, extent owners) and each volume's root pointer. Mounting picks the newest
  checkpoint whose seal verifies. Container metadata is written twice (ZFS's ditto blocks), since losing it loses
  every volume.
- **The space map**, a B+tree of free extents, and the **extent-owner tree** mapping allocated extents to volumes.
  Blocks freed in transaction `T` are reused only after `T`'s checkpoint is durable.
- **Quotas** per volume, and a **reserve** (a percentage of the container, with a floor) that only commits and
  deletions may draw on, so a full disk can always be emptied.

**A volume** is one copy-on-write B+tree keyed by `(object, kind, key)`, as Btrfs and APFS key theirs:

| Record | Key | Value |
|---|---|---|
| Object | `(id, .Object, 0)` | Kind (file, directory, link), size, schema hash (`0046`), creation and modification times, the transaction last changed in |
| Directory entry | `(directory id, .Entry, name hash)` | Name, object id (a short list on a hash collision) |
| Extent | `(file id, .Extent, offset)` | A block pointer, or the data itself for a small file (inline) |
| Stored link | `(directory id, .Entry, name hash)` → an object of kind link | Target volume, object, rights (§6, `security.md` §8) |

Names are UTF-8 without `/` or NUL, compared byte for byte (`0046`); the hash is keyed per volume, so a directory
can't be filled with collisions chosen in advance. There are no hard links and no symlinks.

**Snapshots and clones**, as ZFS does them. A snapshot pins a volume's root at a transaction. A block freed in
transaction `T` with birth time `b` is free at once if `b` is after the latest snapshot, and otherwise goes on that
snapshot's **dead list**; deleting a snapshot merges dead lists and frees what no other snapshot holds. No reference
counts per block, no back-references. A clone is a writable volume whose tree starts as a snapshot's.

**Transactions and commits** (§4) are the volume's transaction groups: every change goes into the open group, which
is committed every few seconds, when it grows past a size, or when a client asks for durability.

## 4. Semantics Clients Can Rely On

- **Ordering:** a volume's operations are applied in one order, and after a crash the volume is in the state after
  some prefix of the operations that were acknowledged. Nothing later survives without everything earlier.
- **Durability is explicit:** `Sync` on a `Dir` or `File` answers once everything before it is on stable storage
  (a flush, or FUA writes). Without it, a crash may lose the last few seconds, never reorder them.
- **Atomic replacement:** `File.Replace` writes new contents and swaps them in at commit; readers holding the old
  file keep reading the old contents until they reopen.
- **Transactions under a `Dir`** (`0046`): `Begin` returns a connection speaking the same `Dir` protocol plus
  `Commit` and `Abort`. Its changes are kept in the volume server, charged to the client's connection, and applied
  atomically. Concurrency is optimistic: the transaction records the version of each object it read or changed, and
  `Commit` fails with `Conflict` if any of them changed meanwhile.
- **Errors:** a failed read is a `Result` on that read. A failed write found at commit fails the commit and every
  later one on that volume with the same error, until it's remounted; nothing is dropped and reported as success.
- **Foreign filesystems** say what they support through `Features` (`0040`) and answer the rest `.Unsupported`.

## 5. Encryption

- **Keys:** each volume has a random 256-bit volume key, stored only wrapped (`0016`, `0042`: by the user's
  credentials, by each public key, for FIDO2). Each **key generation** has its own random key, wrapped by the volume
  key; a member's removal starts a new generation for everything written afterwards (`0042`). A block's pointer names
  the generation it was sealed with.
- **Sealing:** every block of the volume's tree, metadata included, is sealed with an AEAD. Each transaction group
  derives a subkey from the generation's key and a random salt, and numbers its blocks for nonces; the salt and the
  number are in each block's pointer with its tag (`../decisions/0090`), since a checkpoint is overwritten while what
  it sealed lives on. A crash that reuses a transaction number reuses no nonce, because the salt is new. A block's
  address, transaction and owner are its associated data.
- **The cipher** is chosen per volume when it's made: ChaCha20-Poly1305 by default (fast in software, constant-time,
  in `std/crypto`), AES-256-GCM on request where the CPU has AES instructions (`0019`); either can be read anywhere,
  more slowly without hardware AES.
- **What isn't protected:** the container's metadata (how many volumes, their sizes and quotas; `0013` leaves
  metadata out), and rolling a whole volume back to an older consistent checkpoint by someone with the disk, which
  needs trusted storage (a TPM) to detect; out of scope with `0013`.
- **Unencrypted volumes** (the system volume, the account service's, `0042`) are sealed with BLAKE3 only.

## 6. Protocols

Sketches; each is a protocol package (`../decisions/0071`), with bulk data through a buffer each connection shares
(4 KiB messages can't carry it): a client registers a memory object once and requests name offsets into it, as
io_uring's fixed buffers do.

- **`Dir`**: `Open(path, mode, create)`, `List(cursor)`, `Info`, `MakeDirectory`, `Remove`, `Rename` (both names
  beneath this handle), `Narrow(rights)` (a `ReadOnlyDir`), `Begin` (a transaction), `Snapshot`, `Snapshots`,
  `OpenSnapshot` (a `ReadOnlyDir` onto the past), `Changes(since)`, `Sync`, `Features`. Paths are resolved beneath
  the handle (`0046`). `ReadOnlyDir` is the subset that changes nothing.
- **`File`**: `Read(offset, count, buffer offset)`, `Write`, `Replace`, `SetSize`, `Info`, `Sync`, and `Map` later
  (§7). `ReadOnlyFile` is the reading subset.
- **`FileSet`** (`0018`): a directory and a filter, which `List` and `Open` apply; files created while a program runs
  match too.
- **Informational names** (`0018`): `Info` answers with the name the handle was opened as, beneath the handle it was
  opened from, for display only.
- **Change cursors**: `Changes(since: Transaction)` answers with what changed beneath the handle since then, from
  the volume's recent transactions; a cursor older than what's kept answers `Resync`, and the client lists again.
- **Stored links** (8f): the storage manager resolves a link to (volume, object, rights) and returns a fresh
  connection if that volume is unlocked; the target volume keeps the links issued from it, so the granter can list
  and revoke them (`security.md` §8).

## 7. Caching and Mapping

- A volume server caches decrypted blocks in its own memory budget, sized by configuration; reads copy once, into
  the client's shared buffer. Its CPU time is lent per connection (`0037`).
- **No writable file mappings.** Read-only mappings of content that can't change, a snapshot's file or a bundle
  (`software.md`), come with pager-backed memory objects in M9: the kernel turns a fault on such an object into a
  packet to its pager, the volume server, which supplies the page. Until then programs are read whole.

## 8. FAT32

- Microsoft's FAT32 specification v1.03 (2000) with long names (UTF-16, converted to UTF-8), case-insensitive
  matching as FAT defines it, 8.3 aliases generated as Windows does.
- **The EFI system partition is FAT32** (UEFI 2.10 requires it), which is why FAT comes first: the update service
  writes boot generations there (`software.md`).
- Atomic replacement is best effort (write a new file, then rename over), and `Features` says so (`0046`).
- exFAT later, for large removable media.

## 9. Testing

- **Hosted, over a buffer standing in for a disk**, as the frame allocator is tested: the B+tree, the space map,
  checkpoints, snapshots, FAT.
- **Crash states:** a test `block` server records every write between flushes; the tester replays every prefix, and
  reorderings within each flush interval, mounts each result and checks it is a prefix of the acknowledged operations
  (CrashMonkey, Mohan et al., OSDI 2018; Linux's `dm-log-writes`).
- **Fuzzing:** mutated images through the FAT server's and the container's mount paths, hosted.
- **A hosted image builder**, a Hemera program run by `tools/`, using the same packages to write the GPT, the ESP
  (Limine, the kernel, the boot set) and a container with the system volume, so SlopOS boots from a disk image.

## 10. Open Questions

Decided 2026-10-25 (`../decisions/0085`): the split below, ChaCha20-Poly1305, no intent log to begin with, and 4 KiB
blocks with 16 KiB nodes. What was asked:

- Volume servers as separate processes (§2), or one storage service holding every volume, as `services.md` had it:
  the split costs a process per unlocked volume and a hop for allocation, and buys isolation between users' plaintext.
- The default cipher (§5).
- Whether an intent log (ZFS's ZIL) is needed for programs that `Sync` often, or commits are cheap enough.
- Directory sizes and `List` cursors that survive concurrent changes (a cursor is a name hash, so it does).
