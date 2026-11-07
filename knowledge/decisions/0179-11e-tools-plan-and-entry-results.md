# 0179: 11e, the Tools and Scripts, and What a Program's Entry Gives Back

Status: accepted; 11e1 to 11e4 built (below)
Date: 2026-11-06
Related: `0162` (M11's plan), `0169` to `0172` (the shell, calls through manifests), `0176` (11d, documentation),
`../design/shell.md`, Hemera's `docs/compilation.md` (Entry Parameters, Entry Results)

## Context
11e is the last of M11's stages (`0162`): the tools and scripts as programs. A tool that fails today says so only by
its exit code, a number, or by a log line the shell doesn't show; the shell can't say which argument was wrong or what
to do about it, though the program's documentation has an `@error` line for each of its errors (`0176`). The tools
need that first, so it's 11e's first part.

## Decision
11e in six parts:
- **11e1, what an entry gives back**: a program's `main` can give back a value, most usefully a `Result`, which the
  shell shows: an `Ok`'s value as the call's, an `Error` by its variant, the parameter it names and its `@error` hint.
- **11e2, files**: listing, copying, moving and removing, with automatic snapshots before what removes or overwrites,
  and recovering from them; a path that matches only after normalizing (case, separators) gets "did you mean".
- **11e3, reading values**: search, and a viewer and pager for any typed value.
- **11e4, the system**: the process tree, grants, installing.
- **11e5, the editor**.
- **11e6, scripts**: `param` lines, so a script has a manifest and runs with only its grants.

**Entry results** (11e1):
- **The program writes it**: on SlopOS a `main` whose result isn't an integer has its value handed by the generated
  entry to base's `runtime.os_entry_result`, which writes it in the memory the launcher gave as the grant `result`:
  a header, `SlopOsResultHeader` (a magic number, whether it's an `Error`, the size, the type's schema hash), then the
  value as `schema.write_value` writes it. The exit code is 1 for an `Error`, 0 otherwise, so a launcher that doesn't
  give the grant still learns which. A program without the grant writes nothing.
- **The launcher reads it**: `std/os`'s `LaunchOptions.result` grants it; `entry_result` reads it back once the
  program has ended, at most 1 MiB, null when nothing was written.
- **The shell**: a call whose program's entry gives back a value (its manifest says so) gets 64 KiB of memory, made by
  the shell, granted write-only. When the program ends (not killed), the shell checks the schema hash against the
  manifest's, decodes it as it decodes any record, and unwraps the `Result`: an `Ok`'s value becomes the call's value
  when the call is the last of a pipeline with no output of its own; an `Error` becomes the call's error, which `try`,
  `or` and `?` handle like any other.
- **An error names its parameter with `os.ParameterName`**: a field of that type in the error variant's payload holds
  the parameter's name. The message is `name --parameter: Variant: hint`, the hint from the `@error` line for the
  variant in the program's documentation; each part left out when it isn't there.

**Files and recovering them** (11e2, chosen with the project's owner: snapshots through `dir`, as
`../design/storage.md` §6 sketches them):
- **`dir` gains `Snapshot`, `Snapshots` and `OpenSnapshot`**: a snapshot of the whole volume taken now, durable, which
  any writable connection may ask for; the volume's snapshots listed, by name and when they were taken; and a
  `read_only_dir` onto the same directory in a snapshot, so what's seen of the past is only what's beneath the handle.
  `Features.snapshots` says a server has them. A connection reached through a stored link has none of them
  (`ReadOnly`), as it has no grants or links.
- **By the volume server itself**, which holds the volume's keys: a user's home is encrypted (`0090`), and the
  storage manager, which never holds a passphrase, couldn't open its snapshots. The container protocol gains a
  volume's own requests, on its own connection, which reach only its snapshots: `TakeOwnSnapshot` (the volume commits
  first; named `asked-<nanoseconds>`), `OwnSnapshotAt` and `OpenOwnSnapshot`, a connection that reads only what the
  snapshot holds. The volume server attaches the snapshot's tree beside the live one, with the live one's keys, and
  serves the asker's directory by its object, whose number a snapshot shares with the volume.
- **A volume's connection reaches only its volume**: the container service answered the listener's requests, which
  name a volume, on any connection, so a volume server could open another volume's; they're `NotYours` there now, and
  a `Connect` on one is closed.
- **Automatic snapshots**: every hour the storage manager takes `auto-<seconds>` of each writable volume it serves,
  and deletes the `auto-` and `asked-` snapshots older than a day, stopping a read-only server on one first. Others,
  an administrator's or an update's, are left alone. The kernel command line's `test_snapshot_seconds=N` makes the hour
  N seconds and the day 10 N, for tests.
- **The tools**, programs each, taking the shell's directory as `here`, which the shell gives without asking, and
  paths beneath it: `list`, its entries as records; `copy` and `move` (a file or a tree, with `Progress`); `remove`,
  which takes a snapshot first; and `recover`, which looks for what's in a recent snapshot and not here now, newest
  first, and copies it back. So no record of removals is kept: `recover` finds what any removal took, if a snapshot
  has it, which `remove`'s own does, and sees only beneath the directory it's given. Errors are `Result`s naming the
  parameter (11e1).
- **"Did you mean"**: a path the shell can't find, whose name matches an entry of its directory once both are
  compared without case and with spaces at their ends dropped, is answered with that entry's name. Unicode
  normalization waits for `std` to have it.

**Reading values** (11e3, chosen with the project's owner: the pager in the shell, schemas from manifests):
- **`search`**, a program: the lines of the text files beneath a directory (or in a file) that a regular expression
  matches, as records of their path, line number and text; with `--names`, the names that match instead. A typed
  file, a file with a 0 byte, and what's past a file's first 4 MiB aren't searched.
- **`view`, the shell's**: a file as a value. A typed file's value is read by its type's schema, found by its schema
  hash among the types of the manifests of the programs the shell can run: any typed file a program writes is of a
  type its manifest has, so nothing new is stored. A text file is its text; anything else its bytes in hexadecimal.
- **`page`, a built-in stage**: what comes before it, as the shell writes it, a screen at a time on a screen of the
  pager's own, a line under it saying where it is and which keys move it. A value that fits is written as any other.
  It's the shell's because the shell is what reads any type: a program would need a stream of one type.

**The system, as a session sees it** (11e4, chosen with the project's owner: the session's own processes, kept grants
listed and revoked, a user's own list of installations):
- **`processes`**: the session's programs (the shell, the powerbox, its installations), from the session manager,
  each with its budget's use and limit and whether it answered a ping, and the shell's jobs' programs beneath the
  shell. Nothing of other sessions or the system's services; `end name` ends one of the session's installations, which
  starts again with the session's next start.
- **A user's own installations**: `install program --as name` adds to a list of the user's, the config store's value
  "installations" of their owner, of the system list's type, which each of the user's sessions runs beside the
  system's; it starts at once in each. A name is unique across both lists. `uninstall name` takes a snapshot of the
  home first, so `recover` brings `apps/name` back, then stops it, takes it off the list and removes its data and
  settings; the system's can't be. `installations` lists both. A program installs only if its entry is the one
  installations are started with (a data directory and settings), as for the system's.
- **`grants`**: the links the home has issued, the grants kept through the powerbox, as the trusted path's G view
  lists them; `grants --revoke n` revokes one. Revoking takes authority away, never gives it, so the shell may.
- **Built-ins**, as `view` and `page` are: the process tree needs the shell's jobs, which only it knows, and the rest
  ask the session manager on the shell's own connection, which a program would need granted.

## Alternatives
- **A removed area in the file system**, kept for a day: simpler, but a recycle bin rather than snapshots, and no view
  of the past for anything else.
- **Records of removals in the session's data** (`../design/lessons.md` §4.1): a file the tools would need granted,
  and a record that could disagree with what a snapshot has; `recover` looking finds the truth.
- **A read-only volume server per snapshot, through the storage manager**, as `volume@snapshot` is served now: the
  first plan, with the volume protocol's `OpenObject`; it can't open an encrypted volume's snapshot without the
  passphrase, and each snapshot looked in would start a process.
- **Errors as log lines**: the shell would parse text, and nothing would check that a program's errors are what its
  documentation says.
- **A typed result over the lifecycle channel**: needs the program to keep its channel open to the end, and a message
  size limit; memory is written once, after `main`, and needs nothing from the program but its return.
- **Exit codes mapped through the documentation**: numbers, without what the error holds.
- **The parameter's name as a string field by convention**: any `string` would do, so nothing tells a name from a
  message; a type of its own says it's a parameter.
- **A pager program** taking the terminal and a stream: isolated, but it could page only the type it was built for,
  unless programs could read streams of any type.
- **A schema store in the bundle store**, every schema published by its hash when a program is installed, as
  `../design/protocols.md` §5 sketches: new records and a request, for what the manifests already hold.
- **Every process on the system**, services too, through a new listing of the kernel's or the process manager's: more
  like `top`, but it needs a rule for who may see and stop what; a session's are its user's.
- **Installing into the system's list**: every user would run it, so it needs the administrator, on the trusted path.
- **Kept grants listed but revoked only on the trusted path**: safer against a program revoking one, but revoking
  never gives authority, and the user at the shell is the one who kept them.
- **The system tools as programs**, given a connection of the session manager's: the process tree would miss the
  shell's jobs.

## Consequences
- Tools give back `Result`s and the shell shows their errors with no code of their own for it.
- Hemera's compiler gains the entry's side (and Hemera's docs Entry Results); `std/os` the launcher's.

## As Built, 11e1 (2026-11-06)
- **Hemera**: the generated SlopOS entry calls `os_entry_result` for a non-integer result, making the memory a result
  too large for registers is given back through itself, since the entry has no function state of its own (the first
  build stopped at E5002 there; a freestanding test, `BuildsSlopOSProgramGivingAResult`, covers it). Base's
  `os_entry_result` writes the header last, after the value, so a program that ends partway leaves no header.
  `std/os`: `LaunchOptions.result`, `EntryResult`, `entry_result`, `MAX_ENTRY_RESULT`, `ParameterName`.
- **The shell**: `src/apps/shell/results.hsc` (`result_place`, `result_grant`, `read_result`, `error_message`,
  `parameter_named`); a call keeps the memory and closes it at its end, and a failed launch closes the grant's copy.
- **Test**: `test_shell_results`, a `main` giving back `Result[Summary, ResultsError]`, one error holding an
  `os.ParameterName`; a boot test runs it fine, with each error, and inside `try`, on both architectures.

## As Built, 11e2 (2026-11-06)
- **std (Hemera)**: `dir`'s `Snapshot`, `Snapshots(cursor)` and `OpenSnapshot(name)`, answered `Snapshotted`,
  `SnapshotListed` and `Narrowed`, appended to the unions; `files.Snapshot`.
- **The container service**: `TakeOwnSnapshot`, `OwnSnapshotAt` and `OpenOwnSnapshot` on a volume's live connection,
  sharing the listener's code by the volume's ID; the listener's requests and `Connect` refused on a volume's.
- **The volume server** (`snapshots.hsc`): a `Reach` (container connection, block connection, buffer) for the live tree
  and each snapshot's, up to `MAX_PASTS`, 4, attached on `OpenSnapshot` with the live keys lent, and let go of with the
  last connection open in it, or when a slot's needed and nothing has one open. A snapshot's connections are
  `ReadOnlyDir` and `ReadOnlyFile` with a `past`; they follow no links, and list no changes or sets. `Features` says
  snapshots.
- **The storage manager**: `automatic_snapshots`, every `SNAPSHOT_EVERY` (an hour; `test_snapshot_seconds=N` makes it
  N seconds and the day 10 N), deleting `auto-` and `asked-` snapshots older than `SNAPSHOTS_KEPT`, a day; nothing
  without a wall clock. A snapshot a volume server is serving when it's deleted reads nothing more.
- **The shell**: a `dir` parameter named `here` is the shell's directory, given without asking (`Giving.Here`); "did
  you mean" in `paths.hsc`, for a grant's path with nothing there; a last program with an output it wrote nothing to
  gives what its entry gave back, as `recover` with a name does.
- **The tools**: `list`, `copy`, `move`, `remove` (`--forever` without a snapshot) and `recover` in `src/apps`, sharing
  `src/file_tools` (snapshots through `dir`, and a tree copied from a directory or a snapshot's, with `Progress`).
  `recover` looks in the 8 newest snapshots.
- **Tests**: `test_file_tree` makes files to work on; a boot test lists, copies, moves, removes, lists what's
  recoverable, recovers and lists it again, and gets "did you mean"; another sees automatic snapshots taken and
  deleted; both on both architectures.
- **Found on the way**: `os.begin(&out)^ = .Variant(os.append(&out, ...))` struck again, in four places; Hemera now
  warns of it (W4003, an assignment whose right side's call is given `&x` as its left side's is). And `test_settle` has
  to outlast the typing: each character waits for its echo.

## As Built, 11e3 (2026-11-06)
- **`search`** (`src/apps/search`): `pattern`, `path`, `--ignore-case`, `--names`, and an output of `Found` records
  (path beneath `here`, line from 1 or 0 for a name, the line cut at 200 bytes); a `BadPattern` error names `pattern`
  and where it's wrong. Directories are gone into 32 deep at most.
- **The shell** (`viewing.hsc`): `view`, a built-in giving a typed file's value (`typed_value`, each program's manifest
  read and each of its types hashed until one matches), a text file's text, or a hex dump of the first 64 KiB of
  another, of the file's first 1 MiB; `page`, a built-in stage on a `Screen` of its own, sized by `Describe` and
  `Resize`, drawing a line at a time and an inverse status line, with Space, f, Page Down, b, Page Up, Enter, j, Down,
  k, Up, g, Home, G and End, and q, Escape or Ctrl-C to leave; a value shorter than the screen is written as usual.
  A `--name` typed with `-` names a parameter with `_` (`--ignore-case`, `ignore_case`), and completion offers it so.
- **Tests**: `test_file_tree --reading` makes a long file, one with a TODO, 32 bytes and a typed file of its own
  `Made`; a boot test searches lines and names, gets a pattern's error, views the three kinds of file, and pages the
  long one on, to its end and back a line; on both architectures.
- **Found on the way**: `file_tools.names_at` listed a directory itself as `"."`, which `os.list_directory_in` refuses
  (it takes `""`), so a walk from `here` itself found nothing; `copy`'s and `recover`'s from a snapshot weren't
  affected, as a snapshot's is listed on its own connection. And `search` made 65 programs, past a generation's boot
  set of 64 files (`0135`), so the image couldn't be built: `MAX_BOOT_FILES` is 128 now, as `MAX_MODULES` and
  `MAX_ROOT_GRANTS` are (`0180`), which makes a generation's record larger, a format change no stored record survives.

## As Built, 11e4 (2026-11-06)
- **The programs protocol** gains, for the asking shell's own session: `Running` (`RunningPrograms`, each with its
  name, budget's use and limit, whether it answered a ping, and whether it's an installation), `EndInstallation`,
  `Install`, `Uninstall` and `Installation` (`Listed`, the system's then the user's), answered `Done`, or `Refused`
  with an `InstallProblem`.
- **The session manager** (`users_installations.hsc`): a user's list is the config store's "installations" of
  `user:<name>`, declared, of the system list's type, so 8 at most; it's started after the system's at each session's
  start. `install` checks the name across both lists and that the program's manifest is the installations' entry, then
  starts it in each of the user's sessions; `uninstall` takes a `Snapshot` through the session's apps directory's
  connection first, then stops it in each session and removes its data and settings, as the system's uninstall does
  (`remove_installation_data`, split out of it).
- **The shell** (`system.hsc`): `processes`, a list of records (name, parent, state, memory, limit), the session's
  programs then the jobs' programs beneath the shell; `end`, `install` (`--as`), `uninstall`, `installations`; and
  `grants`, the home's `Links`, or `--revoke n` its `Revoke`.
- **Test**: a boot test lists the installations, installs the counter as `tally` and sees it listed and running, gets
  both refusals (a program that isn't installable, a name that's taken), ends it, uninstalls it, recovers its data
  directory from `apps`, and lists kept grants, of which there are none, and revokes one that isn't there; on both
  architectures. Revoking a kept grant is the trusted path's test's.
- **Left**: an installation runs only the installations' entry, a data directory and settings; any entry, given what
  its manifest asks for, is for later, with the shell's grants for a guide. The session manager's log lines after it
  ends a program didn't reach the serial line in the test (a line was repeated once instead), though what it did was
  done: a separate question, for the events service's rings.
