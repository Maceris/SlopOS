# 0117: 9d4, Installations, as Built

Status: accepted
Date: 2026-10-31
Related: `0113` (9d's plan), `0109` (the config store, `Config[T]`), `0110` (the system records), `0094` (bundles),
`../design/software.md` §6

## Context
`0113` made installations the system's only until there are sessions: entries in its configuration, each with its data
as `data: AppData` and its configuration as `Config[T]`, updated to another bundle with its data kept, and uninstalled
with its data and configuration. The supervisor launches a program with its entry's type known when it's built.

## Decision
- **What an installation can run** (with the project's owner): a bundle whose manifest is an entry the supervisor was
  built with, for now `counter_app`'s. A bundle of another entry is refused before anything is launched: its program
  couldn't be given what it takes. Launching any program from its manifest alone waits for sessions (M10).
- **`AppData`** (`src/installations`): an entry parameter's kind, one end speaking `dir`, as Hemera's base checks it
  (`protocol_of`: `AppData` speaks `Dir`). It's the installation's data directory, the system volume's
  `apps/<name>`, which the supervisor opens, made if it isn't there.
- **An installation** (`system_records.InstallationRecord`):
  - Its name, which names its data directory and its configuration's owner; its program, the name the store's boot
    root gives a bundle; and the bundle it runs instead, by hash, all zeros for the one the root names.
  - The build's list is `system_config.INSTALLATIONS`, in the system records.
  - At run time, the list is the config store's value `installations` of owner `system`, once it's been written (its
    `set` flag), and the build's until then.
- **The supervisor** starts every installation once the bundle store, the config store and the system volume are up,
  with its data directory and its `Config[T]` (owner its name, name `settings`), on a budget of 4 MiB. It's started
  again into the same entry, by a restart or an update.
- **Updating** writes the list with the installation's bundle replaced and starts it again, its data kept.
  **Uninstalling** writes the list without it, removes its data directory's files and the directory, and has the config
  store forget its owner's values (the new `Forget`, on the supervisor's connection only, which removes every version
  and directory of an owner's values; a value written again after makes its directories again).
- **The test app**: `counter` and `counter_next`, two versions of `counter_app`'s run, which counts itself in its data
  directory's `count` and says which run and which version.
- **Tests**:
  - Every boot from the image builder's disk runs the counter installation once.
  - `test_installations`: an update to hello's bundle refused; the counter updated to `counter_next`, which counts on
    to 2; uninstalled whole; installed again, counting from 1.
  - A hosted check of installation lists.

## Alternatives considered
- **Launching from a bundle's manifest**: any bundle could be installed, at the cost of a launch in `std` that builds
  grants from a schema at run time; left for sessions.
- **Installations as services in `system_config`**: their list couldn't change at run time, which updating and
  uninstalling need.

## Consequences
- Sessions' app lists (M10) and launching by manifest build on these records.
- 9d5 next: the recovery generation.
