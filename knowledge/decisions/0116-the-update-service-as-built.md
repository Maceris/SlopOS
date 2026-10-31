# 0116: 9d3, the Update Service, as Built

Status: accepted
Date: 2026-10-31
Related: `0113` (9d's plan), `0114` (generations on the ESP), `0115` (boot assessment), `0094` (the bundle store),
`../design/software.md` §5

## Context
`0113` gave the ESP to a new update service, which installs updates staged on the system volume, makes a tentative
generation permanent once the supervisor reports it healthy, rolls back, keeps the current, previous and recovery
generations, and checks the ESP's room first. There's no reboot, so a test boots the same disk again.

## Decision
- **An update is staged** as a generation's record at the system volume's `updates/pending`, tentative, its kernel and
  boot set as objects in the bundle store. `generation_builder --stage` writes one on the host, and `boot.py
  --stage-generation=<command line>` stages generation 2 of the same programs with that command line.
- **The update service** (`src/services/update_service`), not in the boot set, is started by the supervisor once
  there's an ESP and the bundle store. It's given the ESP's root, the `updates` directory, a connection of its own to
  the store, and a listener whose other end the supervisor keeps.
- **Once each boot is assessed**, the supervisor tells it the generation booted and whether it's healthy (the `update`
  protocol's `Booted`), and waits for it to act, before telling the root task everything has started. It then:
  - makes the generation permanent if it was tentative and booted healthy, or removes its record if it booted degraded,
    so the generation before is the default again: rollback;
  - installs `updates/pending`, if there's one:
    - every object the ESP lacks is read from the store and checked against its hash, and the total checked against
      the ESP's room before anything is written;
    - then the objects are written, then the record, tentative;
  - collects: it keeps the generation booted and any newer one, the newest permanent generation before it, and the
    recovery generation, removes every other record and every object none of the kept ones names, and writes
    `limine.conf` from what's kept.
- **A generation's store root reaches the supervisor**: `limine.conf` adds `store_root=<hex>` to the command line beside
  `generation=<number>`, and the supervisor loads programs by that root rather than the store's own.
- **The ESP's room**: `std`'s dir protocol has `Room`, which the FAT server answers from its free clusters; the volume
  server answers `Unsupported`, not knowing its container's.
- **The disk check is late** (`0115`): its checks expect a disk as the image builder made it, and fail on one a boot
  before changed, which the system doesn't need.
- **Booting again**: `boot.py --boots=N` boots the same disk image N times, each after the last stopped, with
  `--expect-boot-line=<boot>:<line>` for the boots after the first.
- **Tests**:
  - Generation 2 staged, installed in the first boot, booted in the second, and made permanent.
  - Generation 2 staged with `test_degraded`, booted degraded in the second boot and rolled back, and generation 1
    booted, healthy, in the third.

## Alternatives considered
- **Installing as soon as the update service starts**: the generation booted, which collection keeps, is known only once
  the boot is assessed, so installing waits for it too.
- **Rollback by marking the record failed**: removing it is enough with Limine, which boots whatever entries are left;
  B's boot counting will want the count kept instead.

## Consequences
- Updates without new code (`0110`'s overrides) need generations made on the device, still open.
- 9d4 next: installations, with `AppData` and `Config[T]`.
