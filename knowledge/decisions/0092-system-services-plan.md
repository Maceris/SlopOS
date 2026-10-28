# 0092: The Plan for System Services and Software (M9)

Status: accepted
Date: 2026-10-27
Related: `0037` (scheduling in user space), `0040` (schemas), `0044` (program interfaces), `0045` (content-addressed
libraries), `0072` (the order after M7), `0091` (M8 done), `../design/software.md`, `../design/observability.md` §2,
`../open-questions.md` *Software* and *Observability*, `../roadmap.md` M9

## Context
M8 is done (`0091`): programs outside the boot set are read from the system volume, and volumes are encrypted,
snapshotted and linked. M9 builds what every later milestone assumes: the scheduler, clock and events services, and
the software model of `../design/software.md`: the bundle store, the config store, generations and updates,
installations, and shared libraries. The design left open where the bundle store lives, how the system configuration
works at run time, whether B (the bootloader) comes with M9, and how log records are written; the roadmap proposed
five stages.

## Decision
Chosen with the project's owner:
- **One bundle store, on the system volume**, for every user's apps: code shared by hash, and collection from every
  root. Which bundles exist is visible to the administrator; whose data isn't. A store per user can come later if
  privacy calls for it.
- **Log records as a format string and typed arguments** (`observability.md` §2): the arguments in their protocol
  layout with their schemas' hashes, rendered when read. Hemera's logger already hands a log function the format
  string and the arguments as `any` (`base/runtime/logger.hsc`), so its interface stays; what Hemera needs is in
  `../hemera-proposals/typed-log-records.md`.
- **The system configuration serialized per generation** (`software.md` §4): still written in Hemera and checked by
  the build, which serializes it with its schema into each generation; the root task validates it at boot with the
  same validator and wiring check the build runs. A change at run time goes through the config store and becomes the
  next generation.
- **B after M9**, as the roadmap orders it: M9's updates work with Limine, whose menu is the way back to the previous
  generation; B adds automatic fallback.
- **App data and configuration as entry parameters**, `data: AppData` and `config: Config[T]`, belonging to the
  installation rather than the bundle hash (`software.md` §6): two new parameter kinds in the manifest.
- **The scheduler service splits budgets as configured**: it takes the root CPU budget from the root task and splits
  it into the budgets the system configuration names for each service, adjusting nothing on its own yet; the kernel
  keeps running on the last parameters if it ends (`0037`).
- **Hemera's side proposed now**, before 9a, so its work can be planned across the milestone: reproducible output
  (`../hemera-proposals/reproducible-builds.md`), separately compiled libraries with typed imports
  (`../hemera-proposals/typed-linking.md`), and typed log records (above). Each is for the owner to decide.
- **The roadmap's five stages**, each with its as-built record, on both architectures:
  - **9a, the first system services**: the scheduler service, the clock service (the MC146818 on x86-64, the PL031 on
    AArch64 `virt`), the events service, which takes every program's log records but the root task's, and restarts
    for the services the supervisor starts other than drivers.
  - **9b, the bundle store**: content-addressed objects and bundles, collected from roots; pager-backed memory objects
    in the kernel, and read-only memory objects shared between processes at different addresses; the process manager
    loading from the store; the system booting with the boot set from the ESP and everything else from the store.
    Hemera's reproducible output is checked here, where hashes first matter.
  - **9c, the config store**: typed values validated by their schemas, defaults from the bundle and overrides apart,
    versions and rollback, watching; `Config[T]`; the system configuration at run time.
  - **9d, generations, updates and installations**: a generation's record and its boot set on the ESP, updates
    written beside the running generation and chosen at boot, rollback, boot assessment by the supervisor;
    installations with `AppData` and `Config[T]`.
  - **9e, shared libraries**: Hemera's separately compiled libraries, the loader binding typed imports, shared text,
    and substitution by policy (`0045`).

## Alternatives considered
- **A bundle store per user's volume**: which apps a user installed stays encrypted with their data, but identical
  code is stored once per user and the process manager reads from every user's volume.
- **Formatted text lines in the events service**: no Hemera work, but no typed queries, formatting paid for every
  record, and a value that holds a newline can forge a line.
- **B within M9**: automatic fallback from the first update, at the cost of a UEFI bootloader for both architectures
  inside this milestone.
- **The system configuration compiled in until later**: less now, but the config store's first real value would
  wait, and the wiring check would stay compile-time only.
- **Installations' directories and values as ordinary grants named by convention**: no new kinds, but nothing checks
  that an app gets its own and only its own.
- **An adaptive scheduler service from the start**: nothing measures what it would adapt to yet.
- **Shared libraries before generations**: the first generations would link libraries, but would wait on the
  compiler's largest M9 piece.

## Consequences
- `../open-questions.md` *Software* is answered, and *Observability*'s first question; `../design/software.md` stands
  as M9's design, its §8 decided here.
- Each stage's details are settled with the owner as it starts, and recorded in its as-built record.
- B (`../roadmap.md`) follows M9, and its boot counting reads the generations 9d writes.
