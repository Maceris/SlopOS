# 0142: 10b2, Volumes Made at Run Time, as Built

Status: accepted
Date: 2026-11-01
Related: `0141` (10b's plan), `0089` and `0090` (the container service and volume servers, sealed volumes), `0042`
(unlocking, key generations), `../../docs/specs/programs.md`

## Context
`0141`'s 10b2: the storage manager gains `CreateVolume`, so the account service can have its volume made at first boot
and a home volume made for each account. A plain volume is made by the container service; a sealed one's key must be
made where the passphrase is, the volume server, so the container service never holds what opens it (`0089`).

## Decision
- **Registered empty**: the container service registers the volume (`slopfs.register_volume`): its record, with a new
  name-hash key, its cipher, no root, and for a sealed one its first key generation's number, 1; then commits. Its
  protocol's `CreateVolume` answers `Created` with its ID, or `AlreadyExists`.
- **Filled by its volume server**: the storage manager opens it as `OpenVolume` does. A volume server finding the
  record unfilled (no root, no objects) makes a sealed one's keys on its first `Unlock` (`slopfs.first_keys`): the
  volume key, wrapped by the passphrase, and the first generation's key, wrapped by the volume key; it sends the
  container service the two wrapped records (`AddWrap`, refused once the volume has a root, and `AddGeneration`), then
  writes the root directory, dated when the volume was registered, and commits.
- **Run-time wraps** use Argon2id at 4 MiB and 3 passes (`slopfs.MADE_PASSPHRASE`), inside the 8 MiB a sealed volume
  server's budget has for it: the passphrase of a volume made at run time is a random secret the account service keeps
  (10b3), which hashes the password it's kept by at RFC 9106's 64 MiB itself.
- **Room**: the storage manager's budget goes from 64 MiB to 96 MiB, for three sealed volume servers beside the plain
  ones, and the supervisor's from 128 MiB to 160 MiB to hold it.
- **Tests**: slopfs's `made_test` registers a plain and a sealed volume, refuses the name again, makes the sealed one's
  keys apart from the container and fills both, and reads them back after a mount, the sealed one only with its
  passphrase; the disk boot test's `disk_check` makes both through the storage manager, writes and reads a file on
  each, is refused either again and the sealed one with the wrong passphrase, and opens it with its own.

## Alternatives considered
- **The container service making the key and forgetting it**: it would hold what opens the volume, for a moment.
- **The volume server registering the volume**: it has a connection for one volume only, as `0089` keeps it.
- **64 MiB Argon2id in the volume server**: a sealed volume server's budget would be 70 MiB, for a passphrase that's
  already a random secret.

## Consequences
- 10b3's account service asks for its volume, and a sealed home volume per account, with `CreateVolume`.
- A volume registered but never filled (its volume server ended first) is filled the next time it's opened; a sealed
  one whose records were added but not its root makes new keys then, replacing them.
