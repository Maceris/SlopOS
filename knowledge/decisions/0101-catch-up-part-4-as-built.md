# 0101: Catch-up Part 4, as Built: FAT Times and FSInfo, Entropy for Started Programs, the Rest Placed

Status: accepted
Date: 2026-10-30
Related: `0041` (the per-thread page), `0049` (interrupt controllers), `0056` (process control), `0067` (the entropy
service), `0074` (PCI windows), `0087` (the FAT server), `0093` (the events service), `0100` (part 3),
`../roadmap.md` *Catch-up*

## Context
The catch-up's last part: the deferred items it could do now, and a milestone for each of the rest. `0087` left FAT
times and FSInfo's free count for later, and `0067` left programs the supervisor starts without a connection to the
entropy service.

## Decision
- **FAT times** (`src/fat`): a volume has a `stamp`, the date and time as FAT holds them (`stamp_of`). Its user sets
  it; without one, it's 1980-01-01, as every time was before. An entry that's made gets the stamp as its creation,
  write and access times. One written to, or grown or cut, gets it as its write and access times. Reading changes no
  time, so a read never writes. `Entry.written` gives an entry's write time as it's read. The FAT server sets the
  stamp from the wall clock before each pass of requests. The storage manager now passes its clock page on to the
  servers it launches, so they have a wall clock too.
- **FSInfo** (`src/fat`): mount reads FSInfo's free count and next free cluster, if its signatures are there and they
  fit the volume. Taking a cluster and freeing one keep the count. `write_info` writes both copies, the second after
  the backup boot sector, once they've changed. `free_clusters` counts through the FAT (`count_free`, a sector at a
  time) the first time the count isn't known. `format` writes the count (every cluster but the root's) and the next
  free cluster, where it wrote "unknown" before. The image builder writes FSInfo after copying its files. The FAT
  server writes it after each pass of requests that changed it. At mount, the server checks FSInfo's count against
  the FAT's, and if they differ, as after another system's writes, keeps the FAT's and writes that.
- **Entropy for programs the supervisor starts** (`0067`): the entropy service already takes clients through `Connect`,
  so the supervisor gives a program a connection of its own through `entropy_connection`, whose port it
  closes after the `Connect`, as `dial` does since `0098`. virtio-rng uses it, where it used to leave a port behind
  each time. `hello` takes one (`entropy_service`) and asks it for 32 bytes.
- **The rest placed**:
  - In M10's 10a: the root task's services started again when they end, and logging to the events service (`0093`);
    interrupt controllers unregistered when the platform service is started again (`0049`).
  - In M12: a debugger reading pages nothing has touched yet, in 12b (`0056`); the per-thread page, in 12d (`0041`).
  - In P, with the AML interpreter: x86-64's PCI windows from the host bridge's `_CRS` (`0074`).
- **Tests**: `fat_test` checks a stamp's bytes and an entry's write time, the free count after format and after a
  cluster is taken, FSInfo written and read again at mount, and counted through the FAT alike. Booting from the image
  builder's disk, the FAT server says FSInfo's free count is the FAT's, every time it mounts, through disk_check's
  writes and the restart tests; and `hello` says the entropy service gave it 32 bytes.

## Alternatives considered
- **A clock function in `fat.Device`**: the package would call out for the time on every write, and every device,
  hosted tests' too, would need one. A stamp set per pass is enough, at a request's grain.
- **Access dates written on reads**: what FAT allows, but every read would write the directory.
- **Trusting FSInfo without checking it**: the specification calls its count a hint. Counting at mount costs a read
  of the FAT, about a thousand sectors on the test disk, and a volume another system left can't mislead it.

## Consequences
- The catch-up is done: the roadmap's status has it, and 9c is next.
- The FAT server reads the whole FAT once each time it mounts.
