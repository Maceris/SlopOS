# 0115: 9d2, Dependency Kinds and Boot Assessment, as Built

Status: accepted
Date: 2026-10-31
Related: `0113` (9d's plan), `0110` (the system records), `0093` (restarts), `../design/lessons.md` §1.1,
`../design/software.md` §5

## Context
`0113` gave a dependency its kind from its type, `Channel[P]` required and `Channel[P]?` optional, with a `late` list in
`system_config` for what the system needn't have to be healthy, and deadlines. `lessons.md` §1.1 asked for degraded
boots with a record instead of hangs, and for boot assessment to count only what the generation needs. The supervisor
said only that it had started all it would.

## Decision
- **The records** (`system_records`):
  - Each service has `late` and a deadline in milliseconds, its own or the configuration's default (`DEFAULT_DEADLINE_MS`,
    two minutes, as a disk check under QEMU can take most of one).
  - Each parameter already said whether it's optional.
  - The one check refuses a required channel served only by late services when what requires it isn't late: what the
    system needs can't wait on what it doesn't.
- **What's late**: `system_config.LATE`, for now the test device's driver (`edu_dma`) and the input device's
  (`virtio_input`), which no service requires.
- **The supervisor's assessment**, once everything it starts at boot has started, sent to the root task just before
  `AllStarted`: `Healthy`, or `Degraded(count)`. A service the system needs, any that isn't late, is missing when:
  - it ended for good with a code that isn't 0, as after too many restarts;
  - it didn't start;
  - it was skipped for want of what it requires (the bundle store and the config store when the storage manager gave no
    system volume);
  - it wasn't done by its deadline (the disk check, which the supervisor waited for without one before).
  A service never attempted, a disk's when there's no disk, isn't missing.
- **A degraded boot's record**: each missing service, a line of its name and why, logged, and written to the system
  volume as `boot/degraded` when there's one. The root task says which the boot was.
- **Tests**: a hosted check that a late-only requirement is refused; every boot from the root task and from the image
  builder's disk is healthy; `test_degraded` kills hello until it isn't started again, and the boot is degraded, with
  its record on the system volume.

## Alternatives considered
- **A deadline on every wait**: the supervisor's waits are its start order, written service by service; the disk
  check's is the one that waits on something outside it, and the rest gain deadlines as they're found to hang.
- **Health from a `Ping` on every listener** (`lessons.md` §3.1): there's no common ping yet; a running process is the
  sign until there is.

## Consequences
- 9d3's update service makes a tentative generation permanent on `Healthy`.
- Late dependencies at the level of single parameters, as `lessons.md` §1.1 has them, wait until a service needs one.
