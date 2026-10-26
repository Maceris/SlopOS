# 0090: Encryption and Snapshots, as Built

Status: accepted
Date: 2026-10-26
Related: `0085` (the plan for M8), `0089` (the native filesystem as services), `0088` (slopfs, hosted), `0042` (unlocking,
key generations), `0016` (users and encryption), `../design/storage.md` §3, §5, `../roadmap.md` M8

## Context
M8's fifth stage (8e, `0085`): sealed volumes, key generations, snapshots and clones, quotas and the reserve. Before
M10 there are no accounts to unwrap a volume's key with. Chosen with the project's owner:
- **Unlocked by a passphrase**: the volume key wrapped by a passphrase through Argon2id, the storage manager given the
  passphrase in a request and passing it on; M10's account service makes the same request with the user's password.
  The image builder makes an encrypted test volume beside the system volume.
- **Snapshots taken by the storage manager**, the administrator's now and M9's update service's later, read through a
  volume server serving the snapshot read-only; a clone is a new writable volume.
- **A snapshot charged to its volume's quota**, as ZFS's `quota` is, not only what the live tree references: deleting
  under a snapshot frees nothing until the snapshot goes, so the reserve lets the deletion commit.
Delivered as 8c and 8d were: in three parts, each committed as it passes, with one report at the end: 8e1 encryption
and key generations, 8e2 snapshots and clones, 8e3 quotas and the reserve. This record grows with each part.

## Decision
### 8e1: encryption and key generations
- **Sealing** (`src/slopfs/keys.hsc`): every block of an encrypted volume, its tree's nodes and its files' chunks, is
  sealed with ChaCha20-Poly1305 by default or AES-256-GCM (the cipher is the volume's, in its record). A block's key is
  keyed BLAKE3 of the transaction it's written in and a salt chosen at random for that transaction, keyed by its
  generation's key; its nonce counts the blocks the transaction has sealed. The 32 bytes a block pointer keeps for its
  seal hold the tag, the salt and the count, so the format didn't change, and a crash that reuses a transaction's
  number reuses no nonce. The design had the salt in the checkpoint; a checkpoint is overwritten in its ring while
  what it sealed lives on, so it's in each block's pointer. The block's address, transaction and owner are its
  associated data. Nodes are opened before their header is checked, so an encrypted tree's structure is its AEAD's to
  vouch for, then the header's.
- **Keys** (`0042`): a volume key, random, kept only wrapped, in the container's volumes tree beside the volume's record:
  a `KeyWrap` record per way it's wrapped, by a passphrase now (Argon2id's parameters and salt, and the key sealed with
  what they derive). A `KeyGeneration` record per generation, its key random and wrapped by the volume key. The
  volume's record names its cipher and newest generation, which seals new blocks; a block's pointer names the
  generation it was sealed with. A new generation re-encrypts nothing. The container service keeps these records and
  never holds what opens them.
- **Unlocking**: `slopfs.unlock` unwraps the volume key with a passphrase and every generation's key with it;
  `open_volume` refuses an encrypted volume (`Locked`), `open_sealed_volume` opens one, `WrongKey` for a passphrase that
  doesn't unwrap. `verify` reads an encrypted volume's tree when it's open, and otherwise takes its extents from the
  owners tree as they are.
- **Services**: the volume server holds an encrypted volume's keys and nothing else does. It waits for the storage
  manager's `Unlock` on a protocol of its own (`src/protocols/volume`) before serving, reads the sealed records through
  the container service (`WrapAt`, `GenerationAt`), and answers `Rotate` by committing what's waiting, making a
  generation and giving its record to the container service (`AddGeneration`), which keeps it and names it in the
  volume's record. The storage manager serves any of a container's volumes by name (`OpenVolume`, with a passphrase
  for an encrypted one: `Locked` without, `WrongKey` for the wrong one), keeps a table of those it serves, and checks
  the passphrase again, through the volume server, each time an encrypted one is opened again. An encrypted volume's
  server is given 8 MiB more for Argon2id's memory, which bounds the parameters a passphrase can be wrapped with for
  now; the storage manager's budget is 32 MiB and the supervisor's 60.
- **Tests**: hosted (`src/slopfs/test/sealed_test.hsc`), an encrypted volume beside one that isn't, nothing of its names
  or bytes found on the disk, refused locked and with the wrong passphrase, read back whole, checked whole locked and
  unlocked, a new generation with old and new blocks both readable, a sealed chunk changed or copied over another
  refused; with both ciphers. The crash-state tester and the fuzzer run on an encrypted volume too. Booted, the image
  builder makes an encrypted volume (`--sealed`) and the disk check is refused it locked and with a wrong passphrase,
  unlocks it, reads it, writes, has a generation started, writes and reads again; what its files hold is nowhere on
  the disk (`boot.py --refuse-disk-text`), so the disk check writes it in capitals made at run time, its own bytes
  being on the disk in the clear.

### 8e2: snapshots and clones
- **The format, version 2**: an owner record keeps the transaction its extent was allocated in; a volume's record
  names a clone's origin, the snapshot and the transaction it's cloned from, and whose key records it uses; snapshots
  and dead lists are records in the volumes tree beside the volume's (`src/slopfs/snapshot.hsc`).
- **Snapshots, by birth times and dead lists** (ZFS's, `design/storage.md` §3): a snapshot is the volume's root and
  next object as its last commit left them, and the transaction that commit made durable. A block given back that was
  born at or before the volume's newest snapshot's transaction stays the volume's, on its dead list with when it was
  born and given back; a snapshot taken at t holds a dead block born at b and given back at f when b <= t < f, and
  deleting a snapshot frees, once the deletion is durable, what no other snapshot holds, including what was waiting to
  go on the list in the transaction open. No reference counts, no back-references; the floors (each volume's newest
  snapshot's transaction, and a clone's origin's) are worked out from the records when a container is mounted.
- **Clones**: a new volume whose tree starts as a snapshot's, its names hashing as its origin's do. Its blocks up to
  that snapshot's transaction are its origin's: it never frees them, the snapshot can't be deleted while it's there
  (`InUse`), and its tree knows its lineage, since a node's header and an encrypted block's associated data name the
  volume that wrote it; a node it copies to change becomes its own. A clone of an encrypted volume uses its origin's
  volume key and key records, and a generation either starts is numbered after the newest of them.
- **`verify`** walks every snapshot's tree too, each node and chunk once however many trees share it.
- **The container service** keeps each extent with when it was allocated, whether since its volume's last commit,
  and whether a snapshot holds it on the dead list. A volume's block connections write only what it allocated since
  its last commit, so nothing a commit made durable or a snapshot holds is ever written again, whatever the volume
  server does; and read only its own live extents, and for a clone, its origins' up to what their snapshots hold. On
  its listener's connections, snapshots are taken (`TakeSnapshot`), deleted, found by their place (`SnapshotAt`), and
  cloned (`Clone`), each durable at once in a commit of the container's own changes (`commit_own`); `OpenVolume` with
  `volume@snapshot` gives a snapshot's connection, read only, whose block connections read what the snapshot holds.
- **The storage manager** takes a snapshot after the volume's server has committed what's waiting (the volume
  protocol's `Commit`), so it holds everything written so far; passes the rest on; and serves `volume@snapshot`
  through a volume server of its own, read only: `OpenVolume` answers `OpenedReadOnlyFiles`, a `read_only_dir`, for
  which Hemera's `std` gained `read_only_dir.connect`. An encrypted volume's snapshot is opened with its passphrase.
  The storage manager's budget is 64 MiB and the supervisor's 96, for a few more volume servers.
- **Tests**: hosted (`src/slopfs/test/snapshot_test.hsc`), a snapshot read as the volume was while the volume changes,
  what it holds on the dead list rather than freed, a second snapshot and a clone of it changed apart from its origin,
  the clone giving back its origin's files with nothing freed, the snapshot refused deletion while cloned, the first
  deleted and what only it held freed, everything across a mount, checked whole at every step; the same for an
  encrypted volume, its clone unlocked with its origin's passphrase and starting a generation of their shared key
  records. The crash-state tester takes a snapshot partway and deletes it later, so every crash state of those commits
  is checked too. Booted, the disk check takes a snapshot of the system volume, writes to the volume, reads the
  snapshot as it was, read only, finds it among the volume's snapshots, clones it and writes to the clone apart from
  the volume, is refused its deletion while cloned, and reads a snapshot of the encrypted volume.

## Alternatives considered
- **The storage manager unwrapping keys**: one process holding every unlocked volume's key, which is what a volume
  server per volume is for (`0085`).
- **A salt per transaction in the checkpoint**, as the design had it: the ring overwrites checkpoints while what they
  sealed lives on, so blocks would outlive what opens them.
- **Encrypting the container's own trees**: their metadata is out of scope (`0013`), and the container service would
  need a key, which it's kept from holding.
- **Reference counts per block** (as Btrfs keeps them): a write to every shared block's count on every change, where
  birth times and dead lists need nothing until a block is given back.
- **A clone's own copy of its origin's key records**: wrapping the volume key for the clone needs the passphrase or the
  key, which the container service never holds; sharing them is what ZFS does with a clone's encryption root too.

## Consequences
- M10's account service unlocks a user's volume with the same `OpenVolume`, its password the passphrase, and wraps the
  volume key for public keys and FIDO2 with more `KeyWrap` records.
- Removing a member from a shared volume (`0042`) is a `Rotate`, plus their wrap record removed.
- Argon2id's memory comes out of the volume server's budget: real passphrases want more than 8 MiB, which the storage
  manager can give when it learns the parameters, or M10 can decide.
