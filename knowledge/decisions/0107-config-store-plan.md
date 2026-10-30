# 0107: The Plan for 9c, the Config Store

Status: accepted
Date: 2026-10-30
Related: `0092` (M9's plan), `0097` (lessons adopted), `0096` (R4), `0044` (system configuration), `0046` (typed
files), `0040` and `0071` (schemas and validators), `../design/software.md` §4, `../roadmap.md` M9

## Context
`0092` made 9c the config store: typed values validated by their schemas, defaults from the bundle and overrides apart,
versions and rollback, watching, `Config[T]`, and the system configuration at run time. `0097` added benchmarks with
baselines (Perf), memory pressure with evictable pager pages, and slopfs refusing invisible characters in names, with
typed files in `Dir`; `0096` put R4, storage faults, with it. Left open: where values are kept, how many versions,
where the system configuration lives before 9d's generations, and who may read and write what.

## Decision
Chosen with the project's owner:
- **Values are typed files** (`0046`): a config service on the system volume keeps each value in a directory of its
  own, a typed file per kept version, validated with the protocol validators on every read and write.
- **The newest 16 versions of each value are kept**, each with its author's connection label and time; a value can be
  rolled back to any of them. Older versions are dropped as new ones are written.
- **The system configuration lives in the boot set and the store**: the build serializes `system_config` with its
  schema into the boot set; the root task validates it at boot with the same code the build runs (the wiring check)
  and gives it to the supervisor and the scheduler service, which stop linking it in. Changes made at run time go
  through the config store as overrides, validated the same way, and apply at the next boot; 9d makes them generations.
- **A value is named by its owner and its name, and reached by connection**: a program's `Config[T]` connection reaches
  only its own values, to read, watch and write its own overrides. The system configuration and other owners' values
  are writable only through a connection the supervisor holds and hands out deliberately.
- **In five parts**, each with an as-built record, on both architectures:
  - **9c1, typed files and names**: a file carries an optional schema hash (`0046`), set when it's made, and `std`'s
    typed open validates its bytes before giving a typed view; slopfs and the FAT server keep it; slopfs refuses names
    with C0 or C1 controls, bidirectional controls or UTS #39's invisible formatting characters (`0097`).
  - **9c2, the config store and `Config[T]`**: the config service, defaults from the bundle (the program's compile-time
    value) with the system's override field by field, versions and rollback, watching by waiting on the connection for
    the next version, writes as transactions over several values; `Config[T]` as an entry parameter, with its manifest
    kind (`0044`).
  - **9c3, the system configuration at run time**: serialized into the boot set, validated by the root task with the
    build's code, given to the supervisor and the scheduler service, its overrides kept in the config store.
  - **9c4, memory pressure**: a pressure signal on memory budgets, raised at a threshold the holder sets and bound to a
    port, and clean pages of pager-backed memory objects given back to their pager under pressure (`0097`).
  - **9c5, numbers and storage faults**: the Perf benchmarks with recorded baselines (`0097`), and R4's faulty block
    connection with slopfs and the FAT server reporting a failed write to every `Sync` after it (`0096`).

## Alternatives considered
- **One record file for every value**: one transaction for everything, but values not readable as files.
- **Every version kept until collected**: nothing lost by default, at the cost of a collector for configuration.
- **The system configuration only in the store**: the root task would need storage up before it knows how to start it.
- **Every value readable by every program**: configuration isn't usually secret, but a reach no wider than needed
  (`0017`) is the rule elsewhere.

## Consequences
- `../roadmap.md` lists 9c's five parts; 9c1 is next.
- `0044`'s manifests gain a `Config[T]` kind; the supervisor and the scheduler service stop linking `system_config`.
