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
