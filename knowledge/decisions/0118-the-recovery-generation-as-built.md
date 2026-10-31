# 0118: 9d5, the Recovery Generation, as Built

Status: accepted
Date: 2026-10-31
Related: `0113` (9d's plan), `0114` (generations on the ESP), `0116` (the update service), `0097` (the recovery
generation), `../design/lessons.md` §1.3

## Context
`0113` made the recovery generation written once, pinned and never collected, booting the boot set, the console and
what B and M10 add, its `limine.conf` entry last. `lessons.md` §1.3 has it reached by a key at the bootloader, and
automatically once every normal generation's boot counter runs out, which is B's.

## Decision
- **Its record**: a generation in state recovery, numbered `RECOVERY_NUMBER` (2^32 − 1), which only it may have, and it
  must; the check refuses either without the other.
  - Its `limine.conf` entry is "SlopOS recovery", last.
  - Its command line has the word `recovery` beside `generation=`.
- **Written once**: the generation builder writes it beside the first generation, with `--recovery`, of the same kernel,
  boot set and command line, their objects shared by hash; `boot.py` does so for every disk image. The update service
  keeps it whatever it collects, and refuses an update staged as one.
- **Booted**:
  - The root task says it booted the recovery generation.
  - The supervisor starts the boot set, the drivers and the console, but not hello, the installations, the disk check
    or the update service.
  - The boot's assessment counts only what it started, so a recovery boot can be healthy.
- **Reaching it**: Limine's menu, where its entry is always there; `generation_builder --boot-recovery` makes it the
  default, for the test (`boot.py --boot-recovery`). Holding a key, and falling back to it automatically, are B's.
- **Tests**: a hosted check that only the recovery generation is numbered as it, and of its entry; a boot of the
  recovery generation, healthy, with the console serving.

## Alternatives considered
- **Number 0 for it**: 0 already means no generation (an ISO's boot, and `Booted`'s), so a recovery boot would be told
  apart from neither.
- **A recovery generation with a shell and the administrator's login**: there's no shell or accounts yet (M10, M11);
  it grows them then, as `0113` says.

## Consequences
- 9d is done. B reads these records for boot counting and the recovery key; the next milestone step follows the
  roadmap.
