# 0181: Before P, What M10 and M11 Left

Status: accepted, chosen with the project's owner; not started
Date: 2026-11-07
Related: `0155` (installations stopped under pressure), `0161` (shared volumes), `0172` (rendering), `0176` (jobs),
`0179` (11e), `0096` (R), `0134` (the generation's command line), `../roadmap.md` (P, R)

## Context
M11 is done, and P is next. The decisions of M10 and M11, R and B left work for "later" that comes before P, by the
order they gave it or because it's a gap in what the first usable system does:
- **11e** (`0179`): an installation runs only the installations' fixed entry, a data directory and settings; "did you
  mean" compares names without Unicode normalization, which `std` hasn't; and `grants --revoke` has no test of its
  own on a grant actually kept, as the shell's sessions don't use the powerbox.
- **10c** (`0155`): an installation stopped under memory pressure isn't started again when its session is shown, which
  waited for something that starts a user's apps, the shell.
- **10d** (`0161`, `../open-questions.md`): a member taken out of a shared volume could still unwrap its new data's key
  with the share's secret, if they kept it and got the disk.
- **11d** (`0176`): a background job's output isn't read as it's written, so one that writes more than its stream holds
  waits for `wait`, and a job with output is never said to have ended at the prompt.
- **11c** (`0172`): a record's values lose their type when the shell decodes them (an enum's member is text, a size
  a whole number), and a table is as wide as its cells, past the terminal's width.
- **R** (`0096`): R5, chaos, was to come after 10a: services killed at random while the system runs, and budgets checked
  after. (R6 waits for Hemera's atomics to be interceptable, so it stays where it is.)
- **B** (`0134`): editing a development generation's kernel command line before it boots was left for when there's a
  console to edit it on; B4's bootloader has one.

## Decision
Seven parts, before P, each with an as-built record:
- **F1, the shell's jobs and rendering**: a background job's output read as it's written, kept up to a limit, and its
  end said at the prompt with how much it wrote; a record's values rendered by their manifest types (an enum's member
  by name, a field whose type is a size, a duration or an instant shown as one); tables cut to the terminal's width,
  the widest column first, with what's cut marked.
- **F2, Unicode normalization**: Hemera's `std/unicode` gains canonical decomposition and composition (NFD, NFC) and
  default case folding, from the Unicode data `std` already generates its tables from; "did you mean" compares names
  normalized to NFC and case folded.
- **F3, installing any program**: an installation is given what any installation gets, its data directory, its
  settings, the clock and the locale, by its manifest; every other parameter has to be optional, and is given nothing,
  so the program asks the powerbox for more as it runs. `install` refuses a program with another parameter it can't go
  without, naming it. An installation stopped under memory pressure is started again when its session is next shown.
- **F4, kept grants end to end**: a test program that asks its session's powerbox for a file and keeps it, the chooser
  answered on the trusted path, then `grants` lists it in the shell and `grants --revoke` revokes it, and the kept
  link opens nothing after.
- **F5, a shared volume's key after a member leaves** (chosen with the project's owner: a new volume key, then the
  old blocks sealed again): taking a member out makes the volume a new volume key, wraps the new key generation with
  it, and seals a new secret to the members left. What's written after, edits included, is in new blocks
  (copy-on-write), sealed with the new generation. Then, in the background, the volume server copies each block still
  sealed with an older generation into one sealed with the new, a few at a time, so it can stop and go on at any point
  and needs room only for the blocks in flight; snapshots taken before are sealed again too. Once no block names an
  older generation, those generations' keys are deleted, and nothing on the disk opens with what the member had. New
  slopfs operations, tested hosted (with a crash-state test of the sealing again) and through the sharing boot test.
- **F6, chaos (R5)**: under `robustness=on`, a boot test kills services at random while sessions run and programs
  work, then checks every one is started again, nothing is lost that was committed, and budgets come back to what
  they were.
- **F7, the generation's command line**: the bootloader lets a development generation's command line be edited before
  it boots, from its menu; a permanent generation's stays as it was built.

## Alternatives
- **Asking at install time for each other parameter**, through the powerbox, kept as links: more capable, but `install`
  becomes an interactive flow; a program can ask the powerbox itself when it needs more.
- **Re-encrypting a shared volume at once when a member leaves**: the same end, but slow for a large volume and twice
  its size while it runs; sealed again in the background, block by block, it gets there without either.
- **Only a new volume key**: protects what's written after, but what was there stays under keys the member had, for
  anyone with the disk and the secret they kept.
- **Recording the shared volume's gap and leaving it**: honest, but it's the one place sharing's protection isn't what
  `0042` meant.
- **These after P**: P's AML interpreter is the larger, riskier work; these are smaller, and close what the first usable
  system already does.

## Consequences
- `../open-questions.md`'s question on shared volumes is answered by F5.
- P follows F7.

## As Built, F1 (2026-11-07)
- **Jobs**: `0177` had already read a background job's output as it's written and said its end at the prompt, so
  what was left was its limit: a job's records are kept up to `MAX_JOB_RECORDS`, 10,000, the rest read and dropped
  and counted, and its end says how many it wrote: `[1] ended, with 2 records: wait 1 for them`.
- **Types**: Hemera's `std/memory` gains `ByteCount`, a distinct alias of `u64` its schema keeps by name; the shell
  reads a field of it as a size, and a word given for one as a size too (`4MiB`), and `std`'s `time.Instant` as a new
  value, an instant, shown in UTC to the second (`2026-11-07T02:23:03Z`) and ordered by `sort`. An enum's member was
  already shown by its name. `list`'s sizes, `edit`'s, `recover`'s and the copies' bytes are `ByteCount`s, so `17 B`.
- **Tables**: `render` takes how wide a table may be; one wider has its widest column narrowed a column at a time,
  down to 4, and what doesn't fit cut, ending in `…`. The shell asks its terminal's width for each list it shows, so
  a resize is followed.
- **Tests**: the shell language's host tests show instants, cut a table to 10 columns, and read a `ByteCount` and an
  `Instant` back as a size and an instant; the boot tests expecting bare sizes and the old line for a job's end now
  expect `17 B` and its count of records.

## As Built, F2 (2026-11-07)
- **Hemera's `std/unicode`**: `normalize` (NFD, NFC), `case_fold` (CaseFolding.txt's C and F), and `decompose`,
  `compose`, `fold` and `combining_class` beneath them, from tables a second generator writes
  (`_generator/generate_normalization.py`, from UnicodeData.txt, DerivedNormalizationProps.txt and CaseFolding.txt of
  Unicode 17.0.0): 2,081 decompositions, whole; 961 compositions, without those excluded; 1,585 foldings; Hangul's
  worked out. Nothing allocates: the caller gives a code point scratch and an output, sized by `SCRATCH_PER_BYTE` (4)
  and `OUTPUT_PER_BYTE` (3). Hemera's unicode scenario checks NFC and NFD against NormalizationTest.txt's parts 0 and 2
  to 5 and a line in ten of part 1, kept beside the tables, and case folding and canonical caseless matching.
- **"Did you mean"**: two names match when their canonical caseless keys do (NFD, case folded, NFD again), spaces at
  their ends dropped, up to 128 bytes each. The reading boot test types `view reading/CAFE` with a combining accent and
  is offered `reading/Café.txt`, its é one code point.

## As Built, F3 (2026-11-07)
- **The session manager** (`entries.hsc`): a bundle's manifest read for its entry's parameters: an `AppData` given the
  installation's data directory, a `Config[T]` its value of the parameter's name, an optional anything else nothing,
  and any other refused, by its name (`programs`' new answer `NeedsParameter`, which the shell shows: `list: its program
  needs its here, which an installation isn't given`). Installations are launched by name with those grants, as the
  shell launches programs; the fixed counter entry, `InstallationGrants` and `installation_program` are gone, and
  `test_installations` checks `list` is refused, as `hello`, all optional now, would be taken.
- **After memory pressure**: an installation stopped under pressure is remembered (up to 16), and started again when its
  session's next shown; the pressure boot test switches back to the first session (the secure attention key, then S)
  and sees its counter started again.

## As Built, F4 (2026-11-07)
- **The shell gives the powerbox**: a parameter of `Channel[Powerbox]` is given a connection the session manager makes
  for it, under the program's name, which the powerbox shows (`programs`' new request `Powerbox`, from the shell's
  connection or a script's finding one). Before, programs in the shell's sessions couldn't reach the powerbox at all.
- **Test**: `test_kept_grant` asks for a file to keep and writes a line in it, or reopens it; a boot test keeps it
  through the chooser (Tab, Enter), reopens it, lists and revokes it with `grants`, and is refused reopening it after;
  on both architectures.

## As Built, F7 (2026-11-07)
- **A generation says whether it's for development**: `generations.Generation` gains `development` (0 or 1, from a
  byte of what was its padding), which `generation_builder --development` sets; a generation without it is a release
  one.
- **The bootloader** (`bootloader.hsc`): E pressed as it starts (as R asks for recovery) edits the chosen generation's
  command line, a development one's only: it's shown, keys typed are added and Backspace takes them away, Enter boots
  with it, for that boot only, and Escape keeps it as built. Keys pressed before the editor shows are dropped for half a
  second, so the E held down isn't typed. A release generation's isn't edited, and that's said.
- **Tests**: `boot.py` gains `--release-generation` and `--bootloader-edit TEXT`, which presses E until the bootloader
  answers, then types the text and Enter; a boot test adds `test_clock` to a development generation's command line and
  sees its clock test run, and another sees a release generation refuse; on both architectures.

## As Built, F6 (2026-11-07)
- **The chaos test** (`supervisor/chaos.hsc`): `test_chaos=N` has the supervisor, once everything has started and the
  root task is told so, kill N services and drivers it starts again, one at a time, chosen from a seed it logs
  (`test_chaos_seed=S` repeats one); each has to be running again within 10 seconds and, a service, answer a lifecycle
  Ping within 10 more (a driver has no lifecycle channel, so running again is its answer), and the supervisor's budget
  has to end no more than 256 KiB above where it was. A boot test kills 6, on both architectures.
- **What it found, fixed**:
  - **A thread's unresolved fault ends its process** (decided with the project's owner): with no debugger stopping
    it, the process is destroyed, killed, not only the thread. A service whose code the bundle store paged, killed
    with the store, lost the threads that ran and lingered with the rest, never started again (`0104` only ended a
    process with its last thread). `test_memory`'s writer that faults is a copy of the test now, whose end it watches.
  - **Programs from the bundle store are got again** once the store is started again (`forget_stored`): the
    supervisor kept the old store's memory, gone with it, and couldn't launch them (BadGrants).
  - **A service the store paged can end before the store's own end is handled**, and then was started again from the
    dead store's memory, BadGrants, the root task ending on the account service not starting: `loaded_module` checks
    a kept program from the store can still be duplicated (`is_alive`) and gets it again, from the system volume if the
    store isn't back yet. And a restart whose launch fails is tried again 200 ms later (`retry_restarts`), counting as
    a restart, rather than reported to the root task as not started while it has restarts left.
  - **No service maps memory another process owns** (decided with the project's owner, extending `0098`): a client
    or a driver that ended took down the server touching its memory (killing the events service ended the system
    volume's server, which was writing its records from a buffer the events service lent it). `memory_read` reads any
    memory but device memory now: DMA, contiguous and boot module memory, windows, and paged memory, whose pages not
    there are waited for from the pager, the call made again once one's supplied (`want_page_locked`, with
    `restart_syscall`); `memory_write` writes anonymous, DMA and contiguous memory and writable windows. The volume
    server, its transactions, the FAT server, the partition server, the container service and the disk check copy
    through the driver's buffer and their clients' buffers; the process manager reads the executable it loads, and the
    supervisor, the session manager and the update service the store's objects, into the heap (`service_kit.read_pages`,
    a page at a time, so a read under pressure isn't started over for ever); the bundle store reads a Put's memory in
    64 KiB pieces; and `std`'s stream reader copies each record out of its writer's ring, so a writer that ends ends
    its stream, not its reader. A program's own code, mapped from the store, and the terminal's framebuffer, from the
    platform service, are still mapped: the first ends with the store, as `0094` says, and the second is drawn on too
    often to copy.
- **Tests**: `test_pager` reads paged memory across two pages not yet supplied, is refused writing it, and once its
  pager's port is gone reads `ObjectGone`; `test_memory` sees the faulting writer's process end killed.

## As Built, F5 (2026-11-07)
- **Snapshots let expire, not sealed again** (chosen with the project's owner, in place of sealing snapshots again as
  planned): only the live tree is sealed again; the generations before the floor are kept while a snapshot from
  before may hold blocks sealed with them, and deleted once it's gone. The automatic and asked snapshots go within a
  day (`0179`), so they're deleted then; a snapshot named otherwise keeps them until it's deleted, and a clone of the
  volume keeps them for as long as it's there.
- **slopfs** (`keys.hsc`, `volume.hsc`, `tree.hsc`, `reseal.hsc`): `rekey` makes a new volume key, wraps it by a new
  passphrase, wraps every generation's key again by it, and makes the next generation, the floor; `replace_keys`
  keeps all of it in place of the volume's key records, every old wrap deleted, with a new record, the key floor
  (`RecordKind.KeyFloor`, `KeyFloorRecord`: the floor, Sealing or Sealed, and the transaction it was Sealed at), all
  durable with one commit, so a crash leaves the old records or the new. `reseal_step` walks the live tree in key order
  from where the last step stopped, a few blocks at a time: a leaf sealed before the floor is made writable with the
  branches above it (`tree_touch_older`, which reads first, so what's done costs only reads), and a chunk sealed
  before it is read and written anew; a branch sealed before the floor has only such leaves beneath it, so touching
  them seals it again too. `sealed_again` marks the floor Sealed; `drop_old_generations` deletes the generations before
  it, and the floor, once it's Sealed, no snapshot is older than that, and no volume is a clone of it.
  `generation_from` lists generations across the gaps that leaves. `rekey_volume` does it all in the container's own
  process, for the hosted tests.
- **The container protocol** gains `GenerationFrom`, `Rekey`, `KeyFloor`, `SealedAgain` and `DropOldGenerations`; the
  container service deletes the old generations after a snapshot's deletion too, so the last snapshot from before
  expiring is what lets them go.
- **The volume server**: `Rekey`, on the volume protocol and the storage manager's (`storage.Rekey`), commits what's
  changed, makes the keys again, has the container service keep them, takes them, and commits before it answers;
  then, between clients' requests, it seals a step of 16 blocks again every 2 ms or so, each step committed, goes on
  from the start after a restart (`resume_floor`), and once done marks the floor Sealed and deletes the old
  generations if nothing needs them, its keys forgetting them. Its unlocking and rotating list generations across
  gaps, and its own copy of the volume's record names the newest generation, which a passphrase checked again is
  checked against.
- **The account service's `unshare`**: the members left are sealed a new secret in the share's next record,
  `<name>.next`, written and synced; the volume is given a new key wrapped by that secret (Rekey); then the next
  record is renamed over the share's and synced, the secret kept, and every link into the volume revoked. A crash
  between leaves the old record opening the volume, whose next record the next member to log in drops, or the next
  record opening it, which that login puts in place (`join_share`). A member taken out has nothing that opens the
  volume once its old generations are deleted.
- **Tests**: hosted, a volume given a new key opens with the new passphrase and not the old, a new key not committed
  leaves the old passphrase opening it, a step of sealing again not committed loses nothing, sealing again takes many
  steps and leaves every chunk sealed with the floor, and with the old generation's record deleted the volume opens and
  reads whole; a snapshot from before keeps the old generations until it's deleted. The sharing boot test sees bob
  taken out, the volume sealed again and its old generation deleted, on both architectures.
